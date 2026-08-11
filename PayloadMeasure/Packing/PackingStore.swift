import Foundation
import Observation
import SwiftUI
import simd

/// Which arrangement method the screen is running.
enum PackingApproach: String, CaseIterable, Identifiable, Sendable {
    /// Kaluzny & Shaw (2009) as adapted in the project chapter: load every package on the module
    /// floor and minimise the deviation of the centre of mass from a target.
    case loadBalanced
    /// Baldi's three-dimensional knapsack heuristic with a continuous-coordinate evaluation of
    /// Junqueira's complete vertical-support condition.
    case knapsack3D

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loadBalanced: "Balance"
        case .knapsack3D: "3D knapsack"
        }
    }

    var citation: String {
        switch self {
        case .loadBalanced: "Kaluzny & Shaw (2009), adapted"
        case .knapsack3D: "Baldi et al. (2012) + Junqueira et al. (2012)"
        }
    }
}

/// Bridges the measured objects into the packing optimisers and holds the arrangement for the UI.
///
/// A solve runs off the main actor. It is pure computation on value types with a hard time limit,
/// so it cannot block the AR session, and a superseded solve is cancelled rather than left to
/// finish and overwrite a newer one.
@MainActor
@Observable
final class PackingStore {
    /// Which method to run. Both are kept so they can be compared on the same measurements.
    var approach: PackingApproach = .knapsack3D
    var baldiOptions = Baldi3BKPOptions()
    /// The physical outer box selected for each measured object during preparation.
    private(set) var selectedBoxPresetIDsByObjectID: [UUID: String] = [:]
    /// Explicit operator decisions to exclude an object because no stocked outer box fits.
    /// The recorded dimensions bind the decision to that measurement; remeasurement cannot
    /// silently inherit an old exclusion.
    private var noStockedBoxFitExclusionSizesByObjectID: [UUID: SIMD3<Double>] = [:]
    /// Central stocked-box catalogue used by the preparation screen and both optimisers.
    let boxPresets: [PackingBoxPreset] = PackingBoxPreset.standardCatalog
    /// The Paper-mode placement and the optional centre-refined placement for the same input.
    /// Publishing them together prevents the result screen from mixing generations.
    private(set) var baldiComparison: Baldi3BKPComparison?

    /// Geometry and mass properties of the payload module, editable in the arrangement settings.
    var module: PayloadModule = .standard
    var options = PackingOptions()
    /// Clearance applied to every package unless it has its own override, in millimetres.
    var defaultPackageClearance: Double = 5
    /// Packages the operator marked as "this way up".
    var uprightPackageIDs: Set<UUID> = []
    /// Restricts the achieved centre of mass to a box around the target, chapter eq. (adapted COM
    /// envelope). Expressed to the operator as a tolerance rather than absolute bounds.
    var restrictsCentreOfMass = false
    var centreOfMassTolerance = SIMD3<Double>(20, 10, 50)
    var limitsPayloadMass = false
    var maximumPayloadMass: Double = 5
    /// Uses the paper's own centre-of-mass domain, `L = (W/4, D/4, 0)`, `U = (3W/4, 3D/4, H/2)`.
    var usesStandardDomain = true
    var domainLower = SIMD3<Double>(200, 50, 0)
    var domainUpper = SIMD3<Double>(600, 150, 50)

    private(set) var result: PackingResult?
    private(set) var isSolving = false
    /// Identifies the inputs the current result was produced from, so the sheet can say when the
    /// arrangement no longer matches what has been measured.
    private(set) var solvedSignature: String?

    private var solveTask: Task<Void, Never>?
    private var solveWork: Task<PackingResult, Never>?
    private var baldiWork: Task<Baldi3BKPComparison, Never>?

    /// The module as the optimiser sees it, with the operator's envelope and mass limit folded in.
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

    /// Builds optimiser input only from fully prepared packages. Raw measured geometry and a
    /// placeholder mass are never submitted as a physical package.
    func packages(from engine: ObjectCaptureEngine) -> [PackingItem] {
        engine.measuredObjectIDs.compactMap { id in
            guard preparationState(for: id, in: engine).isSubmittedToOptimizer,
                  let preset = validSelectedBoxPreset(for: id, in: engine),
                  let name = trimmedName(for: id, in: engine),
                  let mass = validPackedMass(for: id, in: engine) else {
                return nil
            }
            return PackingItem(
                id: id,
                name: name,
                size: preset.outerSizeMillimetres,
                massKilograms: mass,
                horizontalClearance: defaultPackageClearance,
                keepsUpright: uprightPackageIDs.contains(id)
            )
        }
    }

    // MARK: - 3BKP inputs

    /// Builds the 3BKP instance. The paper assumes integral knapsack and item sizes, so physical
    /// package millimetres are rounded: item sizes up and the knapsack down. The discretisation can
    /// therefore only make packing more conservative, never claim a fit that does not exist.
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

    /// `L^δ`. Defaults to the paper's instance domain, §6.1.
    func centreOfMassDomainLower(for size: SIMD3<Int>) -> SIMD3<Double> {
        usesStandardDomain
            ? BaldiKnapsack.standardDomain(size: size).lower
            : domainLower
    }

    /// `U^δ`.
    func centreOfMassDomainUpper(for size: SIMD3<Int>) -> SIMD3<Double> {
        usesStandardDomain
            ? BaldiKnapsack.standardDomain(size: size).upper
            : domainUpper
    }

    func baldiItems(from engine: ObjectCaptureEngine) -> [BaldiItem] {
        engine.measuredObjectIDs.compactMap { id in
            guard preparationState(for: id, in: engine).isSubmittedToOptimizer,
                  let preset = validSelectedBoxPreset(for: id, in: engine),
                  let name = trimmedName(for: id, in: engine),
                  let mass = validPackedMass(for: id, in: engine) else {
                return nil
            }
            let packageSize = preset.outerSizeMillimetres
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

    /// Locked measurements that cannot be arranged yet because no weight has been entered.
    func packagesMissingWeight(from engine: ObjectCaptureEngine) -> [UUID] {
        engine.measuredObjectIDs.filter { id in
            guard !isExcludedBecauseNoStockedBoxFits(id, in: engine) else {
                return false
            }
            return validPackedMass(for: id, in: engine) == nil
        }
    }

    /// Locked objects that have not either completed physical preparation or been explicitly
    /// excluded because no stocked box fits.
    func packagesMissingPreparation(from engine: ObjectCaptureEngine) -> [UUID] {
        engine.measuredObjectIDs.filter {
            !preparationState(for: $0, in: engine).isComplete
        }
    }

    /// Central preparation decision used by the workflow, guards and optimiser bridges.
    func preparationState(
        for objectID: UUID,
        in engine: ObjectCaptureEngine
    ) -> PackagePreparationState {
        guard engine.measuredObjectIDs.contains(objectID),
              engine.capturedObjectsByID[objectID] != nil else {
            return .unavailable
        }

        let fittingPresets = fittingBoxPresets(for: objectID, in: engine)
        if fittingPresets.isEmpty {
            return isExcludedBecauseNoStockedBoxFits(objectID, in: engine)
                ? .excludedBecauseNoStockedBoxFits
                : .noStockedBoxFits
        }
        guard validSelectedBoxPreset(for: objectID, in: engine) != nil else {
            return .needsFittingBox
        }
        guard trimmedName(for: objectID, in: engine) != nil else {
            return .needsName
        }
        guard validPackedMass(for: objectID, in: engine) != nil else {
            return .needsPackedWeight
        }
        return .ready
    }

    /// Marks a locked object as excluded from loading only when no stocked box fits its current
    /// measurement. This happens before either optimiser sees the package.
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

    /// Valid no-fit exclusions, in the same stable order as the captured measurements.
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

    /// Records a stocked box only if that box exists and the measured object can fit inside it.
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

    func clearBoxPreset(for objectID: UUID) {
        guard selectedBoxPresetIDsByObjectID.removeValue(forKey: objectID) != nil else {
            return
        }
        invalidateResults()
    }

    /// Clears every package-specific store value when a measured object is removed.
    func clearPreparation(for objectID: UUID) {
        let removedPreset = selectedBoxPresetIDsByObjectID.removeValue(forKey: objectID) != nil
        let removedExclusion = noStockedBoxFitExclusionSizesByObjectID
            .removeValue(forKey: objectID) != nil
        let removedUprightPreference = uprightPackageIDs.remove(objectID) != nil
        guard removedPreset || removedExclusion || removedUprightPreference else {
            return
        }
        invalidateResults()
    }

    /// Removes stale package-specific state after deletion or remeasurement. In particular, a
    /// no-fit exclusion never survives a changed measurement, even if the object is still large.
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

        if changed {
            invalidateResults()
        }
    }

    private func measuredSizeMillimetres(_ captured: CapturedObject) -> SIMD3<Double> {
        SIMD3(
            Double(captured.widthInMeters) * 1000,
            Double(captured.depthInMeters) * 1000,
            Double(captured.heightInMeters) * 1000
        )
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

    /// True when the measurements or settings have changed since the displayed arrangement.
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

        // The work itself is held separately so cancelling really stops it: cancelling a parent
        // task does not propagate into a detached one, and the branch-and-bound search polls its
        // own task's cancellation between nodes.
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

    /// Runs the Paper stopping-rule and centre-refined 3BKP-H modes concurrently.
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
            await Baldi3BKPSolver.solveBoth(problem, options: options)
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

    /// True when the measurements or settings have changed since the displayed 3BKP packing.
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
    }

    private func invalidateResults() {
        cancel()
        result = nil
        baldiComparison = nil
        solvedSignature = nil
    }

    /// Everything the arrangement depends on. Any change makes the displayed result stale, and the
    /// result screen uses it as the identity of the work it needs done.
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
