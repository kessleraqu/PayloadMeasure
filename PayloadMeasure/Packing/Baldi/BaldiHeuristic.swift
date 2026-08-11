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
/// Solutions are compared by the merit function of eq. (24), `F = P − αU`.
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
    /// `α` of the merit function eq. (24), a different parameter that shares the paper's symbol
    /// with the score decrease above. §5.2 refers to §5.3 for its value, but §5.3 only sets the
    /// scoring `α`. Zero — pure profit — is the default here, and it is exposed as a setting.
    var meritAlpha: Double = 0
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
    ) -> (solution: BaldiSolution, criterion: BaldiSortingCriterion) {
        let indexByID = indexMap(problem.items)
        var best: BaldiSolution?
        var bestCriterion = BaldiSortingCriterion.areaSpecificWeight

        for criterion in BaldiSortingCriterion.allCases {
            let order = BaldiSorting.order(
                problem.items,
                by: criterion,
                knapsack: problem.knapsack,
                theta: options.clusterTheta
            )
            let packed = balance(
                BaldiEPBPH.pack(order: order, instanceIndexByID: indexByID, knapsack: problem.knapsack),
                options: options
            )
            if best == nil || isBetter(packed, than: best!, alpha: options.meritAlpha) {
                best = packed
                bestCriterion = criterion
            }
        }
        return (best ?? BaldiSolution(knapsack: problem.knapsack, placements: [], unloaded: problem.items), bestCriterion)
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
        let indexByID = indexMap(items)

        let initial = constructInitialSolution(problem, options: options)
        var best = initial.solution
        var current = initial.solution

        // §5.3.1 Score initialisation.
        var scores = initialScores(for: items, loadedIn: best, options: options)
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
            current = balance(
                BaldiEPBPH.pack(order: order, instanceIndexByID: indexByID, knapsack: problem.knapsack),
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
                    best: best,
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

            if isBetter(current, than: best, alpha: options.meritAlpha) {
                best = current
                improvements += 1
                nonImproving = 0
            } else {
                nonImproving += 1
            }

            parameterUpdate(
                best: best,
                knapsack: problem.knapsack,
                decrease: &scoreDecrease,
                increase: &scoreIncrease
            )
        }

        let elapsed = clock.now - startedAt
        return BaldiHeuristicResult(
            solution: best,
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
            let second = Int.random(in: 0..<items.count, using: &generator)
            if first != second { scores.swapAt(first, second) }
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

    /// Comparison used for "if CS is better than BS".
    ///
    /// The paper compares by the merit function of eq. (24). It also allows the best solution to be
    /// unfeasible — the Parameter Update reacts to exactly that case — so a solution whose centre of
    /// mass is inside the allowable domain is preferred to one that is not, and the merit function
    /// decides between two of the same kind.
    static func isBetter(_ candidate: BaldiSolution, than incumbent: BaldiSolution, alpha: Double) -> Bool {
        if candidate.isBalanced != incumbent.isBalanced { return candidate.isBalanced }
        return candidate.merit(alpha: alpha) > incumbent.merit(alpha: alpha)
    }

    private static func indexMap(_ items: [BaldiItem]) -> [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (index, item) in items.enumerated() { map[item.id] = index }
        return map
    }
}
