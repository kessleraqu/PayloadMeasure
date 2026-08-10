import Foundation
import simd

nonisolated struct PackingOptions: Sendable, Equatable {
    /// Time limit for the centre-of-mass phase. Nine packages prove optimal in about two seconds
    /// on a desktop-class machine; a phone is several times slower, so the default leaves room.
    var balanceTimeLimitSeconds: Double = 12
    /// Time limit for the hierarchical compactness phase.
    var compactnessTimeLimitSeconds: Double = 5
    /// Runs the second, compactness phase once the balance objective has been proven optimal.
    var minimisesFootprintAfterBalance = true
    var strengthening: PackingStrengthening = .all
    /// Largest dense tableau the device should be asked to hold, in matrix entries. Roughly
    /// 8 bytes each, so four million entries is about 32 MB.
    var maximumTableauElements = 4_000_000

    init() {}
}

nonisolated struct PackingPhaseReport: Sendable, Identifiable {
    var id = UUID()
    var name: String
    var status: String
    var objectiveValue: Double?
    var provenOptimal: Bool
    var nodeCount: Int
    var simplexIterationCount: Int
    var runtimeSeconds: Double
}

nonisolated struct PackingDiagnostics: Sendable {
    var variableCount = 0
    var integerVariableCount = 0
    var rowCount = 0
    var nonZeroCount = 0
    var cuts = PackingCutCounts()
    var strengtheningWasTruncated = false
    var phases: [PackingPhaseReport] = []
    var dualBound: Double?
    var absoluteGap: Double?
    var relativeGap: Double?
    var totalRuntimeSeconds: Double = 0
    var solverDescription = "Bounded-variable dual simplex with depth-first branch and bound"
}

nonisolated struct PackingSecondaryObjective: Sendable {
    var compactness: Double
    var provenOptimal: Bool
}

nonisolated struct PackingResult: Sendable {
    nonisolated enum Status: String, Sendable {
        case optimal
        case feasible
        case infeasible
        case noSolutionFound
        case invalidInput
    }

    var status: Status
    var solution: PackingSolution?
    var verification: PackingVerification?
    var infeasibility: PackingInfeasibility?
    var errors: [String] = []
    var secondaryObjective: PackingSecondaryObjective?
    var diagnostics = PackingDiagnostics()

    var provenOptimal: Bool { status == .optimal }
    var hasArrangement: Bool { solution != nil }
}

/// Solve driver: validation → necessary-condition infeasibility → model construction →
/// strengthening → exact branch and bound → LP polish → hierarchical second objective →
/// independent geometric verification.
///
/// Optimisation is hierarchical, never a weighted blend of the two objectives:
///
///   Phase 1 — minimise `w_x e_x + w_y e_y + w_z e_z`, the weighted L1 deviation of the complete
///             system's centre of mass from its target.
///   Phase 2 — minimise the occupied floor rectangle, subject to phase 1 staying at its optimum.
///
/// Phase 2 only runs once phase 1 has been *proven* optimal, because otherwise "subject to the
/// phase-1 optimum" would not be a well-defined constraint.
nonisolated enum PackingOptimizer {
    static func solve(_ problem: PackingProblem, options: PackingOptions = PackingOptions()) -> PackingResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        func elapsed() -> Double { seconds(from: startedAt, to: clock.now) }

        // 1. Validation and orientation preparation.
        let prepared: PreparedProblem
        switch PackingPreparation.prepare(problem) {
        case .failure(let failure):
            var result = PackingResult(status: .invalidInput, errors: failure.messages)
            result.diagnostics.totalRuntimeSeconds = elapsed()
            return result
        case .success(let value):
            prepared = value
        }

        // 2. Necessary-condition infeasibility, established without building anything.
        if let trivial = PackingPreparation.detectTrivialInfeasibility(prepared) {
            var result = PackingResult(status: .infeasible, infeasibility: trivial)
            result.diagnostics.totalRuntimeSeconds = elapsed()
            return result
        }

        // 3. Model construction and strengthening, with a fallback to a leaner model when the
        //    dense tableau of the fully cut one would not fit in a sensible amount of memory.
        var strengthening = options.strengthening
        var model: PackingModel
        switch buildStrengthenedModel(prepared, strengthening: strengthening, builderOptions: PackingModelBuilder.Options()) {
        case .failure(let infeasibility):
            var result = PackingResult(status: .infeasible, infeasibility: infeasibility)
            result.diagnostics.totalRuntimeSeconds = elapsed()
            return result
        case .success(let built):
            model = built
        }

        if tableauElements(of: model) > options.maximumTableauElements {
            strengthening.usesTransitivity = false
            strengthening.usesFittingCuts = false
            strengthening.usesIdenticalPackageSymmetry = false
            switch buildStrengthenedModel(prepared, strengthening: strengthening, builderOptions: PackingModelBuilder.Options()) {
            case .failure(let infeasibility):
                var result = PackingResult(status: .infeasible, infeasibility: infeasibility)
                result.diagnostics.totalRuntimeSeconds = elapsed()
                return result
            case .success(let built):
                model = built
            }
        }
        if tableauElements(of: model) > options.maximumTableauElements {
            var result = PackingResult(
                status: .infeasible,
                infeasibility: PackingInfeasibility(
                    reason: .modelTooLarge,
                    detail: "\(prepared.items.count) packages produce a model too large to solve exactly on this device. Remove some packages and arrange the load in more than one pass."
                )
            )
            result.diagnostics.totalRuntimeSeconds = elapsed()
            return result
        }

        var diagnostics = PackingDiagnostics()
        let statistics = model.program.statistics
        diagnostics.variableCount = statistics.variableCount
        diagnostics.integerVariableCount = statistics.integerVariableCount
        diagnostics.rowCount = statistics.rowCount
        diagnostics.nonZeroCount = statistics.nonZeroCount
        diagnostics.cuts = model.appliedCuts
        diagnostics.strengtheningWasTruncated = model.strengtheningWasTruncated

        // 4. Phase 1 — the centre-of-mass objective.
        var branchOptions = BranchAndBound.Options()
        branchOptions.timeLimitSeconds = options.balanceTimeLimitSeconds
        branchOptions.branchingPriority = model.branchingPriority
        let balanceSearch = BranchAndBound(program: model.program, options: branchOptions)
        var balance = balanceSearch.solve()
        diagnostics.phases.append(report(name: "Centre of mass", result: balance))

        switch balance.status {
        case .infeasible:
            var result = PackingResult(
                status: .infeasible,
                infeasibility: PackingInfeasibility(
                    reason: .noFeasibleArrangement,
                    detail: "No arrangement of all \(prepared.items.count) packages satisfies the module, clearance and centre-of-mass constraints at the same time."
                ),
                diagnostics: diagnostics
            )
            result.diagnostics.totalRuntimeSeconds = elapsed()
            return result

        case .noSolutionFound, .numericalFailure:
            let detail = balance.status == .noSolutionFound
                ? "The solver reached its \(Int(options.balanceTimeLimitSeconds)) s limit without finding an arrangement, and without proving that none exists — so one may well fit. Exact optimisation is comfortable up to about nine packages; \(prepared.items.count) is beyond that. Raise the time limit in the settings, reduce the clearances, or arrange the load in two passes."
                : "The solver ran into a numerical problem on this model. Try again with slightly different clearances."
            var result = PackingResult(
                status: .noSolutionFound,
                infeasibility: PackingInfeasibility(reason: .timeLimitWithoutSolution, detail: detail),
                diagnostics: diagnostics
            )
            result.diagnostics.dualBound = balance.dualBound.isFinite ? balance.dualBound : nil
            result.diagnostics.totalRuntimeSeconds = elapsed()
            return result

        case .optimal, .feasible:
            break
        }

        // The same model re-solved as a pure LP with the integers pinned; see the method comment.
        if let polished = balanceSearch.polishedSolution(for: balance.values) {
            balance.values = polished.values
            balance.objectiveValue = min(balance.objectiveValue ?? polished.objectiveValue, polished.objectiveValue)
        }
        var solution = PackingSolutionReader.read(model, values: balance.values)
        let balanceObjective = balance.objectiveValue ?? solution.weightedDeviation

        diagnostics.dualBound = balance.dualBound.isFinite ? balance.dualBound : nil
        diagnostics.absoluteGap = balance.absoluteGap
        diagnostics.relativeGap = balance.relativeGap
        var provenOptimal = balance.provenOptimal || (balance.absoluteGap ?? .infinity) <= 1e-6

        // 5. Phase 2 — compactness, held at the proven balance optimum.
        var secondary: PackingSecondaryObjective?
        if options.minimisesFootprintAfterBalance, provenOptimal, prepared.items.count > 1 {
            var builderOptions = PackingModelBuilder.Options()
            builderOptions.minimisesFootprint = true
            builderOptions.primaryObjectiveBound = balanceObjective + 1e-6
            if case .success(let compactModel) = buildStrengthenedModel(
                prepared,
                strengthening: strengthening,
                builderOptions: builderOptions
            ), tableauElements(of: compactModel) <= options.maximumTableauElements {
                var compactOptions = BranchAndBound.Options()
                compactOptions.timeLimitSeconds = options.compactnessTimeLimitSeconds
                compactOptions.branchingPriority = compactModel.branchingPriority
                let compactSearch = BranchAndBound(program: compactModel.program, options: compactOptions)
                var compact = compactSearch.solve()
                diagnostics.phases.append(report(name: "Compactness", result: compact))

                if compact.status == .optimal || compact.status == .feasible {
                    if let polished = compactSearch.polishedSolution(for: compact.values) {
                        compact.values = polished.values
                    }
                    let candidate = PackingSolutionReader.read(compactModel, values: compact.values)
                    let candidateCompactness = candidate.boundingBox?.compactness ?? .infinity
                    let currentCompactness = solution.boundingBox?.compactness ?? .infinity
                    // A truncated phase 2 may be worse than phase 1, which never optimised
                    // compactness but may still have produced a tighter layout.
                    if compact.provenOptimal || candidateCompactness <= currentCompactness {
                        solution = candidate
                        secondary = PackingSecondaryObjective(
                            compactness: candidateCompactness,
                            provenOptimal: compact.provenOptimal
                        )
                    } else {
                        secondary = PackingSecondaryObjective(
                            compactness: currentCompactness,
                            provenOptimal: false
                        )
                    }
                }
            }
        }

        // 6. Independent geometric verification.
        let verification = PackingGeometryCheck.verify(solution, against: prepared)
        if !verification.isValid {
            // A verification failure means the reported arrangement is not trustworthy, so it must
            // not be presented as proven optimal even if the search says it explored everything.
            provenOptimal = false
        }
        diagnostics.totalRuntimeSeconds = elapsed()

        return PackingResult(
            status: provenOptimal ? .optimal : .feasible,
            solution: solution,
            verification: verification,
            secondaryObjective: secondary,
            diagnostics: diagnostics
        )
    }

    // MARK: - Helpers

    private static func buildStrengthenedModel(
        _ problem: PreparedProblem,
        strengthening: PackingStrengthening,
        builderOptions: PackingModelBuilder.Options
    ) -> Result<PackingModel, PackingInfeasibility> {
        var options = builderOptions
        options.strengthening = strengthening
        switch PackingModelBuilder.build(problem, options: options) {
        case .failure(let infeasibility):
            return .failure(infeasibility)
        case .success(var model):
            if let infeasibility = model.applyStrengthening(strengthening) {
                return .failure(infeasibility)
            }
            return .success(model)
        }
    }

    private static func tableauElements(of model: PackingModel) -> Int {
        let statistics = model.program.statistics
        return Simplex.tableauElementCount(
            rowCount: statistics.rowCount,
            structuralCount: statistics.variableCount
        )
    }

    private static func report(name: String, result: MixedIntegerResult) -> PackingPhaseReport {
        PackingPhaseReport(
            name: name,
            status: result.status.rawValue,
            objectiveValue: result.objectiveValue,
            provenOptimal: result.provenOptimal,
            nodeCount: result.nodeCount,
            simplexIterationCount: result.simplexIterationCount,
            runtimeSeconds: result.runtimeSeconds
        )
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = end - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
}
