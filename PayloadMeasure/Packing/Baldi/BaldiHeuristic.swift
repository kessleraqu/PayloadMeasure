import Foundation
import simd

/// 3BKP-H, the heuristic of paper §5, following the scheme of Fig. 6:
///
///   * build an initial solution with PCH and set the best solution `BS` to it;
///   * scoring phase — initialise the scores, then, while the stopping conditions are not met:
///       – sort the items by their scores and apply EP-BPH to the sorted list, obtaining `CS`;
///       – if a given number of successive non-improving iterations is reached, reinitialise the
///         scoring with Long-term Score Reinitialization, otherwise update the scores with Score
///         Update according to `CS`;
///       – if `CS` is better than `BS`, set `BS` to `CS`;
///       – Parameter Update adjusts the parameters internally.
///
/// Every project item has `p_i = 1`. The merit coefficient in equation (24) is fixed to zero, so
/// the search ranks solutions by loaded-package count while balance remains a hard feasibility
/// condition. Exploratory unbalanced solutions are kept separate from the best reportable result.
nonisolated struct BaldiHeuristicOptions: Sendable, Equatable {
    /// Paper §5.3.4: "The overall process stops after 5 s."
    var timeLimitSeconds: Double = 5
    /// Paper §5.3.4: `α = β = 0.1`, the score decrease and increase percentages of §5.3.2.
    var scoreDecrease: Double = 0.1
    var scoreIncrease: Double = 0.1
    /// Paper §5.3.1: the initial score of a loaded item is `k · p_i`, with `k` experimentally set to 3.
    var loadedScoreFactor: Double = 3
    /// Paper §5.3.4: "Long-term Score Reinitialization every 1000 iterations", used by Fig. 6 as
    /// the successive non-improving iteration limit.
    var nonImprovingLimit = 1000
    /// Paper §5.3.4: "number of item pairs: 5% of the items".
    var reinitialisationPairFraction: Double = 0.05
    /// Cluster width `θ` of eqs. (22)–(23); the paper defines it but never states its value.
    var clusterTheta: Double = BaldiSorting.defaultTheta
    var centreOfMass = BaldiCentreOfMassOptimisation.Options()
    /// Seed for the random pair selection of §5.3.3, so a run is reproducible.
    var randomSeed: UInt64 = 0x3B_C0_5EED

    init() {}
}

nonisolated struct BaldiHeuristicResult: Sendable {
    var solution: BaldiSolution
    var initialSolution: BaldiSolution
    var initialCriterion: BaldiSortingCriterion
    var iterations: Int
    var improvements: Int
    var reinitialisations: Int
    var runtimeSeconds: Double
}

nonisolated enum BaldiHeuristic {
    /// A small deterministic generator so the random pair swaps of §5.3.3 are reproducible.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - PCH

    /// The Packing Constructive Heuristic of §5.1: apply EP-BPH under each sorting criterion and
    /// retain the best resulting solution.
    static func constructInitialSolution(
        _ problem: BaldiProblem,
        options: BaldiHeuristicOptions
    ) -> (
        solution: BaldiSolution,
        criterion: BaldiSortingCriterion,
        feasibleSolution: BaldiSolution?
    ) {
        var bestForSearch: BaldiSolution?
        var bestFeasible: BaldiSolution?
        var bestCriterion = BaldiSortingCriterion.areaSpecificWeight

        for criterion in BaldiSortingCriterion.allCases {
            let order = BaldiSorting.order(
                problem.items,
                by: criterion,
                knapsack: problem.knapsack,
                theta: options.clusterTheta
            )
            let packed = balance(
                BaldiEPBPH.pack(order: order, knapsack: problem.knapsack),
                options: options
            )
            if bestForSearch == nil || isBetterForSearch(packed, than: bestForSearch!) {
                bestForSearch = packed
                bestCriterion = criterion
            }
            if isFeasible(packed),
               bestFeasible == nil || packed.loadedCount > bestFeasible!.loadedCount {
                bestFeasible = packed
            }
        }
        return (
            bestForSearch
                ?? BaldiSolution(knapsack: problem.knapsack, placements: [], unloaded: problem.items),
            bestCriterion,
            bestFeasible
        )
    }

    // MARK: - 3BKP-H

    static func solve(
        _ problem: BaldiProblem,
        options: BaldiHeuristicOptions = BaldiHeuristicOptions()
    ) -> BaldiHeuristicResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: .seconds(options.timeLimitSeconds))
        let items = problem.items

        let initial = constructInitialSolution(problem, options: options)
        var searchBest = initial.solution
        var bestFeasible = initial.feasibleSolution

        // §5.3.1 Score initialisation.
        var scores = initialScores(for: items, loadedIn: searchBest, options: options)
        // Long-term memory: how many iterations each item has been loaded / not loaded (§5.3.2).
        var loadedCount = [Int](repeating: 0, count: items.count)
        var unloadedCount = [Int](repeating: 0, count: items.count)

        var scoreDecrease = options.scoreDecrease
        var scoreIncrease = options.scoreIncrease
        var generator = SeededGenerator(state: options.randomSeed == 0 ? 1 : options.randomSeed)

        var iterations = 0
        var improvements = 0
        var reinitialisations = 0
        var nonImproving = 0

        while ContinuousClock.now < deadline {
            if Task.isCancelled { break }
            iterations += 1

            // Sort the items by their scores and apply EP-BPH to the sorted list.
            let order = items.indices
                .sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
                .map { items[$0] }
            let current = balance(
                BaldiEPBPH.pack(order: order, knapsack: problem.knapsack),
                options: options
            )

            let loadedIDs = Set(current.placements.map(\.id))
            for (index, item) in items.enumerated() {
                if loadedIDs.contains(item.id) { loadedCount[index] += 1 } else { unloadedCount[index] += 1 }
            }

            if nonImproving >= options.nonImprovingLimit {
                longTermReinitialisation(
                    scores: &scores,
                    items: items,
                    best: searchBest,
                    options: options,
                    generator: &generator
                )
                reinitialisations += 1
                nonImproving = 0
            } else {
                scoreUpdate(
                    scores: &scores,
                    items: items,
                    loadedIDs: loadedIDs,
                    loadedCount: loadedCount,
                    unloadedCount: unloadedCount,
                    decrease: scoreDecrease,
                    increase: scoreIncrease
                )
            }

            if isBetterForSearch(current, than: searchBest) {
                searchBest = current
                nonImproving = 0
            } else {
                nonImproving += 1
            }

            if isFeasible(current), bestFeasible == nil || current.loadedCount > bestFeasible!.loadedCount {
                bestFeasible = current
                improvements += 1
            }

            parameterUpdate(
                best: searchBest,
                knapsack: problem.knapsack,
                decrease: &scoreDecrease,
                increase: &scoreIncrease
            )
        }

        let elapsed = clock.now - startedAt
        let reported = bestFeasible ?? BaldiSolution(
            knapsack: problem.knapsack,
            placements: [],
            unloaded: problem.items
        )
        return BaldiHeuristicResult(
            solution: reported,
            initialSolution: initial.solution,
            initialCriterion: initial.criterion,
            iterations: iterations,
            improvements: improvements,
            reinitialisations: reinitialisations,
            runtimeSeconds: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) * 1e-18
        )
    }

    // MARK: - Pieces

    /// Applies the centre-of-mass optimisation of §5.2 to a freshly built packing.
    ///
    /// Fig. 6 does not show this step as a box of its own, but §5.2 describes it as operating on a
    /// calculated packing, and eq. (24) speaks of attention being paid to balancing "even before
    /// the center of mass optimization procedure". It is therefore applied to every solution
    /// EP-BPH produces, including the PCH initial one.
    private static func balance(
        _ solution: BaldiSolution,
        options: BaldiHeuristicOptions
    ) -> BaldiSolution {
        guard !solution.placements.isEmpty else { return solution }
        let adjusted = BaldiCentreOfMassOptimisation.optimise(
            placements: solution.placements,
            knapsack: solution.knapsack,
            options: options.centreOfMass
        )
        return BaldiSolution(
            knapsack: solution.knapsack,
            placements: adjusted,
            unloaded: solution.unloaded
        )
    }

    /// §5.3.1: `s_i = k·p_i` for an item loaded in the reference solution, `s_i = p_i` otherwise.
    private static func initialScores(
        for items: [BaldiItem],
        loadedIn solution: BaldiSolution,
        options: BaldiHeuristicOptions
    ) -> [Double] {
        let loaded = Set(solution.placements.map(\.id))
        return items.map { loaded.contains($0.id) ? options.loadedScoreFactor * $0.profit : $0.profit }
    }

    /// §5.3.2 Score update.
    private static func scoreUpdate(
        scores: inout [Double],
        items: [BaldiItem],
        loadedIDs: Set<UUID>,
        loadedCount: [Int],
        unloadedCount: [Int],
        decrease: Double,
        increase: Double
    ) {
        var worstLoaded: Int?
        var worstLoadedValue = Double.infinity
        var bestUnloaded: Int?
        var bestUnloadedValue = -Double.infinity

        for (index, item) in items.enumerated() {
            let volume = Double(max(item.volume, 1))
            if loadedIDs.contains(item.id) {
                // μ_i = (1 + f^l_i) p_i / (w_i d_i h_i)
                let mu = (1 + Double(loadedCount[index])) * item.profit / volume
                if mu < worstLoadedValue {
                    worstLoadedValue = mu
                    worstLoaded = index
                }
            } else {
                // θ_i = p_i / (w_i d_i h_i (1 + f^u_i))
                let theta = item.profit / (volume * (1 + Double(unloadedCount[index])))
                if theta > bestUnloadedValue {
                    bestUnloadedValue = theta
                    bestUnloaded = index
                }
            }
        }

        guard let k = worstLoaded, let l = bestUnloaded else { return }
        scores[k] = (1 - decrease) * scores[k]
        scores[l] = (1 + increase) * scores[l]
        scores.swapAt(k, l)
    }

    /// §5.3.3 Long-term score reinitialisation: score every item by the initialisation rule against
    /// the best solution found so far, then swap the scores of a fixed number of random pairs.
    private static func longTermReinitialisation(
        scores: inout [Double],
        items: [BaldiItem],
        best: BaldiSolution,
        options: BaldiHeuristicOptions,
        generator: inout SeededGenerator
    ) {
        scores = initialScores(for: items, loadedIn: best, options: options)
        guard items.count > 1 else { return }
        let pairs = max(1, Int((Double(items.count) * options.reinitialisationPairFraction).rounded()))
        for _ in 0..<pairs {
            let first = Int.random(in: 0..<items.count, using: &generator)
            let offset = Int.random(in: 0..<(items.count - 1), using: &generator)
            let second = offset >= first ? offset + 1 : offset
            scores.swapAt(first, second)
        }
    }

    /// §5.3.3, second paragraph — the Parameter Update box of Fig. 6.
    ///
    /// "If the best solution found so far is unfeasible, α = 2α and β = 2β. If the best solution is
    /// feasible, α = α/2 and β = β/2, if the center of mass lies into the central half of its
    /// feasibility domain, while they are unchanged otherwise."
    ///
    /// The paper states `α, β ∈ (0,1)`; repeated doubling would leave that interval and make the
    /// factor `1 − α` negative, so the values are held inside it.
    private static func parameterUpdate(
        best: BaldiSolution,
        knapsack: BaldiKnapsack,
        decrease: inout Double,
        increase: inout Double
    ) {
        if !best.isBalanced {
            decrease = min(0.9, 2 * decrease)
            increase = min(0.9, 2 * increase)
            return
        }
        let centre = best.centreOfMass
        var inCentralHalf = true
        for axis in 0..<3 {
            let low = knapsack.domainLower[axis]
            let high = knapsack.domainUpper[axis]
            let quarter = (high - low) / 4
            if centre[axis] < low + quarter || centre[axis] > high - quarter {
                inCentralHalf = false
                break
            }
        }
        if inCentralHalf {
            decrease = max(1e-4, decrease / 2)
            increase = max(1e-4, increase / 2)
        }
    }

    /// Search comparison for the paper's "CS better than BS" step. Full support is a construction
    /// invariant. With `p_i = 1` and the equation (24) coefficient fixed to zero, its primary merit
    /// is loaded-package count. Balance is only a deterministic tie-break here; a separate
    /// `bestFeasible` incumbent ensures that an exploratory unbalanced packing is never reported.
    private static func isBetterForSearch(_ candidate: BaldiSolution, than incumbent: BaldiSolution) -> Bool {
        if candidate.isFullySupported != incumbent.isFullySupported { return candidate.isFullySupported }
        if candidate.loadedCount != incumbent.loadedCount {
            return candidate.loadedCount > incumbent.loadedCount
        }
        if candidate.isBalanced != incumbent.isBalanced { return candidate.isBalanced }
        return false
    }

    private static func isFeasible(_ solution: BaldiSolution) -> Bool {
        solution.loadedCount > 0 && solution.isBalanced && solution.isFullySupported
    }

}
