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
    private(set) var baldiResult: Baldi3BKPResult?

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
    private var baldiWork: Task<Baldi3BKPResult, Never>?

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

    /// Builds the optimiser's package list from every locked measurement.
    func packages(from engine: ObjectCaptureEngine) -> [PackingItem] {
        engine.measuredObjectIDs.compactMap { id in
            guard let captured = engine.capturedObjectsByID[id] else { return nil }
            return PackingItem(
                id: id,
                name: engine.name(for: id) ?? "Object \(engine.objectNumber(for: id) ?? 0)",
                size: SIMD3(
                    Double(captured.widthInMeters) * 1000,
                    Double(captured.depthInMeters) * 1000,
                    Double(captured.heightInMeters) * 1000
                ),
                massKilograms: engine.weightInKilograms(for: id) ?? 0,
                horizontalClearance: defaultPackageClearance,
                keepsUpright: uprightPackageIDs.contains(id)
            )
        }
    }

    // MARK: - 3BKP inputs

    /// Builds the 3BKP instance. The paper assumes integral knapsack and item sizes, so measured
    /// millimetres are rounded: item sizes up and the knapsack down, so the discretisation can only
    /// make the packing more conservative, never claim a fit that does not exist.
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
            guard let captured = engine.capturedObjectsByID[id] else { return nil }
            let size = SIMD3<Int>(
                Int((Double(captured.widthInMeters) * 1000).rounded(.up)),
                Int((Double(captured.depthInMeters) * 1000).rounded(.up)),
                Int((Double(captured.heightInMeters) * 1000).rounded(.up))
            )
            return BaldiItem(
                id: id,
                name: engine.name(for: id) ?? "Object \(engine.objectNumber(for: id) ?? 0)",
                size: size,
                mass: engine.weightInKilograms(for: id) ?? 0
            )
        }
    }

    func baldiProblem(from engine: ObjectCaptureEngine) -> BaldiProblem {
        BaldiProblem(knapsack: knapsack(), items: baldiItems(from: engine))
    }

    /// Locked measurements that cannot be arranged yet because no weight has been entered.
    func packagesMissingWeight(from engine: ObjectCaptureEngine) -> [UUID] {
        engine.measuredObjectIDs.filter { engine.weightInKilograms(for: $0) == nil }
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

    /// Runs the support-aware 3BKP-H heuristic.
    func solveBaldi(problem: BaldiProblem) {
        cancel()
        guard !problem.items.isEmpty else {
            baldiResult = nil
            solvedSignature = nil
            return
        }

        isSolving = true
        let options = baldiOptions
        let expected = baldiSignature(for: problem)

        let work = Task.detached(priority: .userInitiated) {
            Baldi3BKPSolver.solve(problem, options: options)
        }
        baldiWork = work

        solveTask = Task { [weak self] in
            let outcome = await work.value
            guard !Task.isCancelled else { return }
            self?.baldiResult = outcome
            self?.solvedSignature = expected
            self?.isSolving = false
        }
    }

    /// True when the measurements or settings have changed since the displayed 3BKP packing.
    func isBaldiStale(for problem: BaldiProblem) -> Bool {
        baldiResult != nil && solvedSignature != baldiSignature(for: problem)
    }

    func baldiSignature(for problem: BaldiProblem) -> String {
        var parts: [String] = [
            "baldi-junqueira-v1",
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
            "equal-priority|centred-com|support-alpha-1",
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
        baldiResult = nil
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
