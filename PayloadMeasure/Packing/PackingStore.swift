import Foundation
import Observation
import SwiftUI
import simd

// Shared state for the packing screens. Turns locked measurements into packing inputs, runs
// whichever method is selected off the main actor, and holds the result the views read.
//
// In:  the measured objects from ObjectCaptureEngine, the operator's outer-box choices, and the
//      module and solver settings.
// Out: observable state — a PackingResult for Balance, a BaldiComparison for the 3D knapsack,
//      plus a solving flag and a signature so a stale answer is never shown as current.
//
// A superseded solve is cancelled rather than left running; the AR session shares the CPU.

enum PackingApproach: String, CaseIterable, Identifiable, Sendable {
    case loadBalanced
    case knapsack3D

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loadBalanced: "Balance"
        case .knapsack3D: "3D knapsack"
        }
    }

}

@MainActor
@Observable
final class PackingStore {
    var approach: PackingApproach = .knapsack3D
    var baldiOptions = BaldiOptions()
    private(set) var selectedBoxPresetIDsByObjectID: [UUID: String] = [:]
    private var noStockedBoxFitExclusionSizesByObjectID: [UUID: SIMD3<Double>] = [:]
    /// Objects that are already boxed, so their measured size is the package size.
    private(set) var objectsThatAreTheirOwnBox: Set<UUID> = []
    /// Sizes typed in by hand, overriding both the measurement and the assigned box.
    private(set) var forcedSizesByObjectID: [UUID: SIMD3<Double>] = [:]
    private(set) var boxPresets: [PackingBoxPreset] = PackingStore.loadBoxPresets()
    private(set) var baldiComparison: BaldiComparison?

    var module: PayloadModule = .standard
    var options = PackingOptions()
    var defaultPackageClearance: Double = 5
    var uprightPackageIDs: Set<UUID> = []
    var restrictsCentreOfMass = false
    var centreOfMassTolerance = SIMD3<Double>(20, 10, 50)
    var limitsPayloadMass = false
    var maximumPayloadMass: Double = 5
    var usesStandardDomain = true
    var domainLower = SIMD3<Double>(150, 50, 0)
    var domainUpper = SIMD3<Double>(450, 150, 50)

    private(set) var result: PackingResult?
    private(set) var isSolving = false
    private(set) var solvedSignature: String?

    private var solveTask: Task<Void, Never>?
    private var solveWork: Task<PackingResult, Never>?
    private var baldiWork: Task<BaldiComparison, Never>?

    var effectiveModule: PayloadModule {
        var configured = module
        configured.centreOfMassEnvelope = restrictsCentreOfMass
            ? CentreOfMassEnvelope(
                minimum: module.targetCentreOfMass - centreOfMassTolerance,
                maximum: module.targetCentreOfMass + centreOfMassTolerance
            )
            : .unbounded
        configured.maximumPayloadMassKilograms = limitsPayloadMass ? maximumPayloadMass : nil
        return configured
    }

    // MARK: - Inputs

    func packages(from engine: ObjectCaptureEngine) -> [PackingItem] {
        engine.measuredObjectIDs.compactMap { id in
            guard preparationState(for: id, in: engine).isSubmittedToOptimizer,
                  let size = packagedSizeMillimetres(for: id, in: engine),
                  let name = trimmedName(for: id, in: engine),
                  let mass = validPackedMass(for: id, in: engine) else {
                return nil
            }
            return PackingItem(
                id: id,
                name: name,
                size: size,
                massKilograms: mass,
                horizontalClearance: defaultPackageClearance,
                keepsUpright: uprightPackageIDs.contains(id)
            )
        }
    }

    /// What the object occupies once packed: the assigned box outside, or the object itself when it
    /// is already a box. The single answer both methods and the preparation screen work from.
    func packagedSizeMillimetres(
        for objectID: UUID,
        in engine: ObjectCaptureEngine
    ) -> SIMD3<Double>? {
        if let forced = forcedSize(for: objectID, in: engine) {
            return forced
        }
        if isItsOwnBox(objectID, in: engine) {
            return measuredSizeMillimetres(for: objectID, in: engine)
        }
        return validSelectedBoxPreset(for: objectID, in: engine)?.outerSizeMillimetres
    }

    func measuredSizeMillimetres(
        for objectID: UUID,
        in engine: ObjectCaptureEngine
    ) -> SIMD3<Double>? {
        guard let captured = engine.capturedObjectsByID[objectID] else { return nil }
        let size = measuredSizeMillimetres(captured)
        return size.allFiniteAndPositive ? size : nil
    }

    /// A size the operator typed in. Wins over everything else, so a bad measurement does not stop
    /// the load being planned.
    func forcedSize(for objectID: UUID, in engine: ObjectCaptureEngine) -> SIMD3<Double>? {
        guard engine.measuredObjectIDs.contains(objectID),
              let forced = forcedSizesByObjectID[objectID],
              forced.allFiniteAndPositive else {
            return nil
        }
        return forced
    }

    func setForcedSize(_ size: SIMD3<Double>?, for objectID: UUID, in engine: ObjectCaptureEngine) {
        guard engine.measuredObjectIDs.contains(objectID) else { return }
        if let size, size.allFiniteAndPositive {
            guard forcedSizesByObjectID[objectID] != size else { return }
            forcedSizesByObjectID[objectID] = size
            selectedBoxPresetIDsByObjectID.removeValue(forKey: objectID)
            noStockedBoxFitExclusionSizesByObjectID.removeValue(forKey: objectID)
        } else {
            guard forcedSizesByObjectID.removeValue(forKey: objectID) != nil else { return }
        }
        invalidateResults()
    }

    func isItsOwnBox(_ objectID: UUID, in engine: ObjectCaptureEngine) -> Bool {
        objectsThatAreTheirOwnBox.contains(objectID)
            && engine.measuredObjectIDs.contains(objectID)
            && engine.capturedObjectsByID[objectID] != nil
    }

    func setIsItsOwnBox(_ isOwnBox: Bool, for objectID: UUID, in engine: ObjectCaptureEngine) {
        guard engine.measuredObjectIDs.contains(objectID) else { return }
        let changed = isOwnBox
            ? objectsThatAreTheirOwnBox.insert(objectID).inserted
            : objectsThatAreTheirOwnBox.remove(objectID) != nil
        guard changed else { return }
        if isOwnBox {
            selectedBoxPresetIDsByObjectID.removeValue(forKey: objectID)
            noStockedBoxFitExclusionSizesByObjectID.removeValue(forKey: objectID)
        }
        invalidateResults()
    }

    // MARK: - Box catalogue

    @discardableResult
    func addBox(outerSizeMillimetres: SIMD3<Double>) -> PackingBoxPreset? {
        guard let preset = PackingBoxPreset.sized(outerSizeMillimetres: outerSizeMillimetres),
              // A box is its size, so the same size twice is the same box.
              !boxPresets.contains(where: { $0.outerSizeMillimetres == outerSizeMillimetres }) else {
            return nil
        }
        boxPresets.append(preset)
        persistBoxPresets()
        invalidateResults()
        return preset
    }

    func removeBox(id presetID: String) {
        guard boxPresets.contains(where: { $0.id == presetID }) else { return }
        boxPresets.removeAll { $0.id == presetID }
        for (objectID, selectedID) in selectedBoxPresetIDsByObjectID where selectedID == presetID {
            selectedBoxPresetIDsByObjectID.removeValue(forKey: objectID)
        }
        persistBoxPresets()
        invalidateResults()
    }

    private static let boxDefaultsKey = "packing.boxPresets"

    /// Seeded from the default list only when nothing has been stored yet. An empty stored list is a
    /// decision — the operator deleted everything — not a reason to put the defaults back.
    private static func loadBoxPresets() -> [PackingBoxPreset] {
        guard let data = UserDefaults.standard.data(forKey: boxDefaultsKey),
              let stored = try? JSONDecoder().decode([PackingBoxPreset].self, from: data) else {
            return PackingBoxPreset.defaultCatalog
        }
        return stored
    }

    private func persistBoxPresets() {
        guard let data = try? JSONEncoder().encode(boxPresets) else { return }
        UserDefaults.standard.set(data, forKey: Self.boxDefaultsKey)
    }

    // MARK: - 3BKP inputs

    func knapsack() -> BaldiKnapsack {
        let size = SIMD3<Int>(
            Int(module.lengthMillimetres.rounded(.down)),
            Int(module.widthMillimetres.rounded(.down)),
            Int(module.heightMillimetres.rounded(.down))
        )
        return BaldiKnapsack(
            size: size,
            domainLower: centreOfMassDomainLower(for: size),
            domainUpper: centreOfMassDomainUpper(for: size)
        )
    }

    func centreOfMassDomainLower(for size: SIMD3<Int>) -> SIMD3<Double> {
        usesStandardDomain
            ? BaldiKnapsack.standardDomain(size: size).lower
            : domainLower
    }

    func centreOfMassDomainUpper(for size: SIMD3<Int>) -> SIMD3<Double> {
        usesStandardDomain
            ? BaldiKnapsack.standardDomain(size: size).upper
            : domainUpper
    }

    func baldiItems(from engine: ObjectCaptureEngine) -> [BaldiItem] {
        engine.measuredObjectIDs.compactMap { id in
            guard preparationState(for: id, in: engine).isSubmittedToOptimizer,
                  let packageSize = packagedSizeMillimetres(for: id, in: engine),
                  let name = trimmedName(for: id, in: engine),
                  let mass = validPackedMass(for: id, in: engine) else {
                return nil
            }
            let size = SIMD3<Int>(
                Int(packageSize.x.rounded(.up)),
                Int(packageSize.y.rounded(.up)),
                Int(packageSize.z.rounded(.up))
            )
            return BaldiItem(
                id: id,
                name: name,
                size: size,
                mass: mass
            )
        }
    }

    func baldiProblem(from engine: ObjectCaptureEngine) -> BaldiProblem {
        BaldiProblem(knapsack: knapsack(), items: baldiItems(from: engine))
    }

    func packagesMissingWeight(from engine: ObjectCaptureEngine) -> [UUID] {
        engine.measuredObjectIDs.filter { id in
            guard !isExcludedBecauseNoStockedBoxFits(id, in: engine) else {
                return false
            }
            return validPackedMass(for: id, in: engine) == nil
        }
    }

    func packagesMissingPreparation(from engine: ObjectCaptureEngine) -> [UUID] {
        engine.measuredObjectIDs.filter {
            !preparationState(for: $0, in: engine).isComplete
        }
    }

    func preparationState(
        for objectID: UUID,
        in engine: ObjectCaptureEngine
    ) -> PackagePreparationState {
        guard engine.measuredObjectIDs.contains(objectID),
              engine.capturedObjectsByID[objectID] != nil else {
            return .unavailable
        }

        let needsNoBox = isItsOwnBox(objectID, in: engine)
            || forcedSize(for: objectID, in: engine) != nil
        if !needsNoBox {
            if fittingBoxPresets(for: objectID, in: engine).isEmpty {
                return isExcludedBecauseNoStockedBoxFits(objectID, in: engine)
                    ? .excludedBecauseNoStockedBoxFits
                    : .noStockedBoxFits
            }
            guard validSelectedBoxPreset(for: objectID, in: engine) != nil else {
                return .needsFittingBox
            }
        }
        guard packagedSizeMillimetres(for: objectID, in: engine) != nil else {
            return .needsFittingBox
        }
        guard trimmedName(for: objectID, in: engine) != nil else {
            return .needsName
        }
        guard validPackedMass(for: objectID, in: engine) != nil else {
            return .needsPackedWeight
        }
        return needsNoBox ? .readyAsItsOwnBox : .ready
    }

    /// Assigns the smallest fitting box to every object that has not been given one. The operator
    /// does not choose a box; they are told which one to use.
    func assignBoxesAutomatically(in engine: ObjectCaptureEngine) {
        var changed = false
        for objectID in engine.measuredObjectIDs {
            guard !isItsOwnBox(objectID, in: engine),
                  forcedSize(for: objectID, in: engine) == nil,
                  validSelectedBoxPreset(for: objectID, in: engine) == nil,
                  let recommended = recommendedBoxPreset(for: objectID, in: engine) else {
                continue
            }
            noStockedBoxFitExclusionSizesByObjectID.removeValue(forKey: objectID)
            selectedBoxPresetIDsByObjectID[objectID] = recommended.id
            changed = true
        }
        if changed { invalidateResults() }
    }

    @discardableResult
    func markExcludedBecauseNoStockedBoxFits(
        _ objectID: UUID,
        in engine: ObjectCaptureEngine
    ) -> Bool {
        guard engine.measuredObjectIDs.contains(objectID),
              let captured = engine.capturedObjectsByID[objectID],
              fittingBoxPresets(for: objectID, in: engine).isEmpty else {
            return false
        }

        selectedBoxPresetIDsByObjectID.removeValue(forKey: objectID)
        noStockedBoxFitExclusionSizesByObjectID[objectID] = measuredSizeMillimetres(captured)
        invalidateResults()
        return true
    }

    func clearNoStockedBoxFitExclusion(for objectID: UUID) {
        guard noStockedBoxFitExclusionSizesByObjectID.removeValue(forKey: objectID) != nil else {
            return
        }
        invalidateResults()
    }

    func isExcludedBecauseNoStockedBoxFits(
        _ objectID: UUID,
        in engine: ObjectCaptureEngine
    ) -> Bool {
        guard let excludedSize = noStockedBoxFitExclusionSizesByObjectID[objectID],
              engine.measuredObjectIDs.contains(objectID),
              let captured = engine.capturedObjectsByID[objectID],
              measuredSizeMillimetres(captured) == excludedSize else {
            return false
        }
        return fittingBoxPresets(for: objectID, in: engine).isEmpty
    }

    func objectIDsExcludedBecauseNoStockedBoxFits(
        in engine: ObjectCaptureEngine
    ) -> [UUID] {
        engine.measuredObjectIDs.filter {
            isExcludedBecauseNoStockedBoxFits($0, in: engine)
        }
    }

    func selectedBoxPreset(for objectID: UUID) -> PackingBoxPreset? {
        guard let presetID = selectedBoxPresetIDsByObjectID[objectID] else {
            return nil
        }
        return boxPresets.first(where: { $0.id == presetID })
    }

    func fittingBoxPresets(
        for objectID: UUID,
        in engine: ObjectCaptureEngine
    ) -> [PackingBoxPreset] {
        guard let captured = engine.capturedObjectsByID[objectID] else {
            return []
        }
        return PackingBoxCatalog.fittingPresets(
            for: measuredSizeMillimetres(captured),
            in: boxPresets
        )
    }

    func recommendedBoxPreset(
        for objectID: UUID,
        in engine: ObjectCaptureEngine
    ) -> PackingBoxPreset? {
        fittingBoxPresets(for: objectID, in: engine).first
    }

    private func validSelectedBoxPreset(
        for objectID: UUID,
        in engine: ObjectCaptureEngine
    ) -> PackingBoxPreset? {
        guard let selected = selectedBoxPreset(for: objectID),
              fittingBoxPresets(for: objectID, in: engine).contains(where: {
                  $0.id == selected.id
              }) else {
            return nil
        }
        return selected
    }

    @discardableResult
    func selectBoxPreset(
        id presetID: String,
        for objectID: UUID,
        in engine: ObjectCaptureEngine
    ) -> Bool {
        guard let preset = boxPresets.first(where: { $0.id == presetID }),
              engine.measuredObjectIDs.contains(objectID),
              fittingBoxPresets(for: objectID, in: engine).contains(where: {
                  $0.id == preset.id
              }) else {
            return false
        }
        noStockedBoxFitExclusionSizesByObjectID.removeValue(forKey: objectID)
        selectedBoxPresetIDsByObjectID[objectID] = preset.id
        invalidateResults()
        return true
    }


    func clearPreparation(for objectID: UUID) {
        let removedPreset = selectedBoxPresetIDsByObjectID.removeValue(forKey: objectID) != nil
        let removedExclusion = noStockedBoxFitExclusionSizesByObjectID
            .removeValue(forKey: objectID) != nil
        let removedUprightPreference = uprightPackageIDs.remove(objectID) != nil
        let removedOwnBox = objectsThatAreTheirOwnBox.remove(objectID) != nil
        let removedForcedSize = forcedSizesByObjectID.removeValue(forKey: objectID) != nil
        guard removedPreset || removedExclusion || removedUprightPreference || removedOwnBox
            || removedForcedSize else {
            return
        }
        invalidateResults()
    }

    func reconcilePreparationState(with engine: ObjectCaptureEngine) {
        let measuredIDs = Set(engine.measuredObjectIDs)
        var changed = false

        for objectID in Array(noStockedBoxFitExclusionSizesByObjectID.keys) {
            guard let captured = engine.capturedObjectsByID[objectID],
                  measuredIDs.contains(objectID),
                  noStockedBoxFitExclusionSizesByObjectID[objectID]
                    == measuredSizeMillimetres(captured),
                  fittingBoxPresets(for: objectID, in: engine).isEmpty else {
                noStockedBoxFitExclusionSizesByObjectID.removeValue(forKey: objectID)
                changed = true
                continue
            }
        }

        for objectID in Array(selectedBoxPresetIDsByObjectID.keys)
        where !measuredIDs.contains(objectID)
            || validSelectedBoxPreset(for: objectID, in: engine) == nil {
            selectedBoxPresetIDsByObjectID.removeValue(forKey: objectID)
            changed = true
        }

        let staleUprightIDs = uprightPackageIDs.subtracting(measuredIDs)
        if !staleUprightIDs.isEmpty {
            uprightPackageIDs.subtract(staleUprightIDs)
            changed = true
        }

        for objectID in Array(forcedSizesByObjectID.keys) where !measuredIDs.contains(objectID) {
            forcedSizesByObjectID.removeValue(forKey: objectID)
            changed = true
        }

        let staleOwnBoxIDs = objectsThatAreTheirOwnBox.subtracting(measuredIDs)
        if !staleOwnBoxIDs.isEmpty {
            objectsThatAreTheirOwnBox.subtract(staleOwnBoxIDs)
            changed = true
        }

        if changed {
            invalidateResults()
        }
    }

    /// Rounded to the micrometre. The measurement arrives as Float metres, so 0.4 m reaches this as
    /// 400.000006 mm; package sizes are rounded up to whole millimetres, and without this every
    /// object that is its own box would grow a millimetre on every axis out of nothing.
    private func measuredSizeMillimetres(_ captured: CapturedObject) -> SIMD3<Double> {
        captured.sizeMillimetres
    }

    private func trimmedName(
        for objectID: UUID,
        in engine: ObjectCaptureEngine
    ) -> String? {
        guard let name = engine.name(for: objectID)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }

    private func validPackedMass(
        for objectID: UUID,
        in engine: ObjectCaptureEngine
    ) -> Double? {
        guard let mass = engine.weightInKilograms(for: objectID),
              mass.isFinite,
              mass > 0 else {
            return nil
        }
        return mass
    }

    func colour(for id: UUID, in engine: ObjectCaptureEngine) -> Color {
        guard let colour = engine.objectColor(for: id) else { return .accentColor }
        return Color(red: colour.red, green: colour.green, blue: colour.blue)
    }

    func isStale(for packages: [PackingItem]) -> Bool {
        result != nil && solvedSignature != signature(for: packages)
    }

    // MARK: - Solving

    func solve(packages: [PackingItem]) {
        cancel()
        guard !packages.isEmpty else {
            result = nil
            solvedSignature = nil
            return
        }

        isSolving = true
        let problem = PackingProblem(module: effectiveModule, items: packages)
        let options = options
        let expected = signature(for: packages)

        let work = Task.detached(priority: .userInitiated) {
            PackingOptimizer.solve(problem, options: options)
        }
        solveWork = work

        solveTask = Task { [weak self] in
            let outcome = await work.value
            guard !Task.isCancelled else { return }
            self?.result = outcome
            self?.solvedSignature = expected
            self?.isSolving = false
        }
    }

    func solveBaldi(problem: BaldiProblem) {
        cancel()
        guard !problem.items.isEmpty else {
            baldiComparison = nil
            solvedSignature = nil
            return
        }

        isSolving = true
        let options = baldiOptions
        let expected = baldiSignature(for: problem)

        let work = Task.detached(priority: .userInitiated) {
            await BaldiSolver.solveBoth(problem, options: options)
        }
        baldiWork = work

        solveTask = Task { [weak self] in
            let outcome = await work.value
            guard !Task.isCancelled else { return }
            self?.baldiComparison = outcome
            self?.solvedSignature = expected
            self?.isSolving = false
        }
    }

    func isBaldiStale(for problem: BaldiProblem) -> Bool {
        baldiComparison != nil && solvedSignature != baldiSignature(for: problem)
    }

    func baldiSignature(for problem: BaldiProblem) -> String {
        var parts: [String] = [
            "baldi-junqueira-v3-paper-stop-and-centred",
            "\(problem.knapsack.size.x)/\(problem.knapsack.size.y)/\(problem.knapsack.size.z)",
            String(
                format: "L%.2f,%.2f,%.2f U%.2f,%.2f,%.2f",
                problem.knapsack.domainLower.x, problem.knapsack.domainLower.y, problem.knapsack.domainLower.z,
                problem.knapsack.domainUpper.x, problem.knapsack.domainUpper.y, problem.knapsack.domainUpper.z
            ),
            String(
                format: "t%.6g|theta%.6g|score%.6g,%.6g|k%.6g|stall%d|pairs%.6g|com%d|seed%llu",
                baldiOptions.heuristic.timeLimitSeconds,
                baldiOptions.heuristic.clusterTheta,
                baldiOptions.heuristic.scoreDecrease,
                baldiOptions.heuristic.scoreIncrease,
                baldiOptions.heuristic.loadedScoreFactor,
                baldiOptions.heuristic.nonImprovingLimit,
                baldiOptions.heuristic.reinitialisationPairFraction,
                baldiOptions.heuristic.centreOfMass.maximumIterations,
                baldiOptions.heuristic.randomSeed
            ),
            "dual-mode|paper-stop|centred-refinement|equal-priority|support-alpha-1",
        ]
        for item in problem.items.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            parts.append(
                String(
                    format: "%@:%d,%d,%d,%.4f",
                    item.id.uuidString, item.size.x, item.size.y, item.size.z, item.mass
                )
            )
        }
        return parts.joined(separator: "|")
    }

    func cancel() {
        baldiWork?.cancel()
        baldiWork = nil
        solveWork?.cancel()
        solveWork = nil
        solveTask?.cancel()
        solveTask = nil
        isSolving = false
    }

    func clear() {
        cancel()
        result = nil
        baldiComparison = nil
        solvedSignature = nil
        selectedBoxPresetIDsByObjectID.removeAll()
        noStockedBoxFitExclusionSizesByObjectID.removeAll()
        uprightPackageIDs.removeAll()
        objectsThatAreTheirOwnBox.removeAll()
        forcedSizesByObjectID.removeAll()
    }

    private func invalidateResults() {
        cancel()
        result = nil
        baldiComparison = nil
        solvedSignature = nil
    }

    func signature(for packages: [PackingItem]) -> String {
        let module = effectiveModule
        var parts: [String] = [
            String(
                format: "%.2f/%.2f/%.2f/%.2f",
                module.lengthMillimetres,
                module.widthMillimetres,
                module.heightMillimetres,
                module.minimumWallClearance
            ),
            String(
                format: "t%.2f,%.2f,%.2f w%.2f,%.2f,%.2f",
                module.targetCentreOfMass.x, module.targetCentreOfMass.y, module.targetCentreOfMass.z,
                module.axisWeights.x, module.axisWeights.y, module.axisWeights.z
            ),
            String(
                format: "m%.3f,%.3f",
                module.emptyMassKilograms,
                module.airframeMassKilograms
            ),
            options.minimisesFootprintAfterBalance ? "compact" : "balance",
            String(format: "lim%.2f/%.2f", options.balanceTimeLimitSeconds, options.compactnessTimeLimitSeconds),
            restrictsCentreOfMass
                ? String(format: "env%.1f,%.1f,%.1f", centreOfMassTolerance.x, centreOfMassTolerance.y, centreOfMassTolerance.z)
                : "env-",
            limitsPayloadMass ? String(format: "cap%.2f", maximumPayloadMass) : "cap-",
        ]
        for package in packages.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            parts.append(
                String(
                    format: "%@:%.2f,%.2f,%.2f,%.4f,%.2f,%d",
                    package.id.uuidString,
                    package.size.x, package.size.y, package.size.z,
                    package.massKilograms,
                    package.horizontalClearance,
                    package.keepsUpright ? 1 : 0
                )
            )
        }
        return parts.joined(separator: "|")
    }
}
