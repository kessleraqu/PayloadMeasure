import Foundation
import simd

/// Which of the paper's two solution methods to run.
///
/// The paper's own finding, §4 and §6.2: the MIP model "is not able to solve instances with more
/// than 20 items", is used mainly to compute bounds, and is outperformed by the heuristic from 40
/// items upwards, while being better on 20-item instances. Both are offered here for the same
/// reason.
nonisolated enum BaldiMethod: String, Sendable, CaseIterable, Identifiable {
    /// 3BKP-H, paper §5.
    case heuristic
    /// 3BKP-M, paper §2.1, solved exactly.
    case model

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heuristic: "3BKP-H heuristic"
        case .model: "3BKP-M exact model"
        }
    }
}

nonisolated struct Baldi3BKPOptions: Sendable, Equatable {
    var method: BaldiMethod = .heuristic
    var heuristic = BaldiHeuristicOptions()
    /// Time limit for the exact model. The paper uses 200 s on a workstation; the default here is
    /// shorter because this runs on a phone, and it is adjustable.
    var modelTimeLimitSeconds: Double = 20
    /// Largest dense tableau the device should be asked to hold, in matrix entries.
    var maximumTableauElements = 4_000_000
    /// Uses equation (16) exactly as printed rather than the repaired form. The printed equation
    /// makes any packing that leaves items out infeasible; see `Baldi3BKPModel`.
    var usesPrintedRotationEquality = false

    init() {}
}

nonisolated struct Baldi3BKPResult: Sendable {
    nonisolated enum Status: String, Sendable {
        /// A packing was found and, for the model, proven optimal.
        case optimal
        /// A packing was found; optimality was not proven.
        case feasible
        /// Nothing could be loaded.
        case empty
        case invalidInput
        case modelTooLarge
    }

    var status: Status
    var solution: BaldiSolution?
    var verification: BaldiVerification?
    var method: BaldiMethod
    var errors: [String] = []
    /// Items removed before solving because they do not fit in the knapsack in any rotation.
    var oversizedItems: [BaldiItem] = []

    /// `UB_1D`, paper §4.
    var upperBound: Double?
    var dualBound: Double?
    var provenOptimal = false
    /// Percentage gap of the reported profit against `UB_1D`, the figure the paper's tables report.
    var gapToUpperBound: Double? {
        guard let upperBound, upperBound > 0, let solution else { return nil }
        return (upperBound - solution.profit) / upperBound * 100
    }

    var runtimeSeconds: Double = 0
    var heuristicDetail: BaldiHeuristicResult?
    var modelStatistics: LinearProgram.Statistics?
    var modelNodeCount: Int?
}

/// Drives the paper's two methods and the `UB_1D` bound.
nonisolated enum Baldi3BKPSolver {
    static func solve(_ problem: BaldiProblem, options: Baldi3BKPOptions = Baldi3BKPOptions()) -> Baldi3BKPResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        func elapsed() -> Double {
            let duration = clock.now - startedAt
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
        }

        var errors: [String] = []
        if problem.knapsack.size.x <= 0 || problem.knapsack.size.y <= 0 || problem.knapsack.size.z <= 0 {
            errors.append("The knapsack must have a positive size on every axis.")
        }
        for item in problem.items {
            if item.size.x <= 0 || item.size.y <= 0 || item.size.z <= 0 {
                errors.append("“\(item.name)” has a non-positive dimension.")
            }
            if item.mass <= 0 {
                errors.append("“\(item.name)” has no weight. Enter its weight before arranging the load.")
            }
        }
        for axis in 0..<3 where problem.knapsack.domainLower[axis] > problem.knapsack.domainUpper[axis] {
            errors.append("The centre-of-mass domain is empty on axis \(axis + 1).")
        }
        if problem.items.isEmpty {
            errors.append("Add at least one measured package.")
        }
        guard errors.isEmpty else {
            var result = Baldi3BKPResult(status: .invalidInput, method: options.method, errors: errors)
            result.runtimeSeconds = elapsed()
            return result
        }

        // Items that cannot fit in any rotation are removed first; see `partitionByFit`.
        let (fitting, oversized) = problem.partitionByFit()
        let reduced = BaldiProblem(knapsack: problem.knapsack, items: fitting)
        let bound = BaldiUpperBound.oneDimensional(reduced)

        guard !fitting.isEmpty else {
            var result = Baldi3BKPResult(
                status: .empty,
                solution: BaldiSolution(knapsack: problem.knapsack, placements: [], unloaded: problem.items),
                method: options.method,
                oversizedItems: oversized,
                upperBound: bound
            )
            result.runtimeSeconds = elapsed()
            return result
        }

        switch options.method {
        case .heuristic:
            let detail = BaldiHeuristic.solve(reduced, options: options.heuristic)
            var solution = detail.solution
            solution.unloaded += oversized
            var result = Baldi3BKPResult(
                status: solution.placements.isEmpty ? .empty : .feasible,
                solution: solution,
                verification: BaldiGeometryCheck.verify(solution),
                method: .heuristic,
                oversizedItems: oversized,
                upperBound: bound
            )
            result.heuristicDetail = detail
            result.runtimeSeconds = elapsed()
            return result

        case .model:
            let model = Baldi3BKPModelBuilder.build(
                reduced,
                usesPrintedRotationEquality: options.usesPrintedRotationEquality
            )
            let statistics = model.program.statistics
            let elements = Simplex.tableauElementCount(
                rowCount: statistics.rowCount,
                structuralCount: statistics.variableCount
            )
            if elements > options.maximumTableauElements {
                var result = Baldi3BKPResult(
                    status: .modelTooLarge,
                    method: .model,
                    errors: [
                        "\(fitting.count) items produce a 3BKP-M model too large to solve on this device — \(statistics.rowCount) rows and \(statistics.variableCount) variables. The paper reports the same limit: the model cannot handle instances with more than about twenty items. Use the 3BKP-H heuristic instead.",
                    ],
                    oversizedItems: oversized,
                    upperBound: bound
                )
                result.modelStatistics = statistics
                result.runtimeSeconds = elapsed()
                return result
            }

            var branchOptions = BranchAndBound.Options()
            branchOptions.timeLimitSeconds = options.modelTimeLimitSeconds
            // The objective is −Σ p_j t_j, so it can never go below minus the total profit.
            branchOptions.objectiveLowerBound = -model.totalProfit / model.profitScale
            let search = BranchAndBound(program: model.program, options: branchOptions)
            var outcome = search.solve()

            guard !outcome.values.isEmpty else {
                var result = Baldi3BKPResult(
                    status: .empty,
                    solution: BaldiSolution(knapsack: problem.knapsack, placements: [], unloaded: problem.items),
                    method: .model,
                    oversizedItems: oversized,
                    upperBound: bound
                )
                result.modelStatistics = statistics
                result.modelNodeCount = outcome.nodeCount
                result.runtimeSeconds = elapsed()
                return result
            }

            if let polished = search.polishedSolution(for: outcome.values) {
                outcome.values = polished.values
            }
            var solution = Baldi3BKPModelBuilder.readSolution(model, values: outcome.values)
            solution.unloaded += oversized

            var result = Baldi3BKPResult(
                status: outcome.provenOptimal ? .optimal : .feasible,
                solution: solution,
                verification: BaldiGeometryCheck.verify(solution),
                method: .model,
                oversizedItems: oversized,
                upperBound: bound
            )
            // The model maximises, so the search's bounds are negated back into profit terms.
            result.dualBound = outcome.dualBound.isFinite ? -outcome.dualBound * model.profitScale : nil
            result.provenOptimal = outcome.provenOptimal
            result.modelStatistics = statistics
            result.modelNodeCount = outcome.nodeCount
            result.runtimeSeconds = elapsed()
            return result
        }
    }
}
