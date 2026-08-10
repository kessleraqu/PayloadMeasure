import Foundation

/// Valid inequalities — Kaluzny & Shaw §3, restated for the adaptation's one-hot orientation
/// variables and four-indicator separation encoding.
///
/// Everything here is kept out of the core formulation so each family can be switched off on its
/// own. None of it changes the optimal objective value: each family removes either provably
/// impossible assignments or duplicate encodings of an arrangement the model can still express.
nonisolated extension PackingModel {
    /// Applies the enabled cut families in priority order, stopping when the row budget runs out.
    /// Returns `nil` on success, or the infeasibility a cut proved along the way.
    mutating func applyStrengthening(_ flags: PackingStrengthening) -> PackingInfeasibility? {
        var budget = flags.maximumAdditionalRows
        // `exactlyOneSeparation` is applied in the builder as a row bound, not an extra row.

        if flags.usesIdenticalPackageSymmetry {
            addIdenticalPackageSymmetry(budget: &budget)
        }
        if flags.usesFittingCuts {
            if let infeasibility = addFittingPairCuts(budget: &budget) { return infeasibility }
            addFittingTripleCuts(budget: &budget)
        }
        if flags.usesTransitivity {
            addTransitivityCuts(budget: &budget)
        }
        strengtheningWasTruncated = budget <= 0
        return nil
    }

    // MARK: - Identical packages

    /// Interchanging two packages that are identical in every respect gives a different solution
    /// with the same objective, so the tree holds `k!` copies of every layout for each group of `k`
    /// identical packages. Ordering the group along the module length keeps exactly one of them.
    private mutating func addIdenticalPackageSymmetry(budget: inout Int) {
        var classes: [String: [Int]] = [:]
        for (index, prepared) in problem.items.enumerated() {
            let item = prepared.item
            let key = [
                item.size.x, item.size.y, item.size.z,
                item.massKilograms,
                item.horizontalClearance, item.verticalClearance,
                item.comOffset.x, item.comOffset.y, item.comOffset.z,
            ]
            .map { String(format: "%.6f", $0) }
            .joined(separator: "|") + (item.keepsUpright ? "|upright" : "|free")
            classes[key, default: []].append(index)
        }

        for members in classes.values where members.count > 1 {
            for first in 0..<members.count {
                for second in (first + 1)..<members.count {
                    guard budget >= 2 else { return }
                    let a = members[first]
                    let b = members[second]
                    // Any arrangement can be relabelled so that the group is ordered along x.
                    program.addLessOrEqual(
                        name: "symOrder_\(a)_\(b)",
                        terms: [(xVariables[a], 1), (xVariables[b], -1)],
                        value: 0
                    )
                    budget -= 1
                    appliedCuts.identicalPackageSymmetry += 1
                    // With x_a ≤ x_b, "a strictly ahead of b along x" can never hold.
                    if let pair = pair(a, b) {
                        program.addLessOrEqual(
                            name: "symAhead_\(a)_\(b)",
                            terms: [(pair.separation[relationIndex(pair: pair, ahead: a, axis: 0)], 1)],
                            value: 0
                        )
                        budget -= 1
                        appliedCuts.identicalPackageSymmetry += 1
                    }
                }
            }
        }
    }

    // MARK: - Fitting cuts

    /// Two packages can only be separated along an axis if the module is long enough for both
    /// bodies, the clearance between them and the wall clearance on each outer side — the paper's
    /// `S₂ᵂ` / `S₂ᴸ` test (26)–(28). Because the required extent depends on the chosen orientation
    /// the test is evaluated per orientation group and aggregated: if no combination fits, the axis
    /// itself is excluded for the pair (43)–(44).
    private mutating func addFittingPairCuts(budget: inout Int) -> PackingInfeasibility? {
        let spans = [module.lengthMillimetres, module.widthMillimetres]

        for pairIndex in pairs.indices {
            let pair = pairs[pairIndex]
            let first = pair.first
            let second = pair.second
            var excludedAxes = 0

            for axis in 0..<2 {
                let groupsA = orientationGroups(of: first, axis: axis)
                let groupsB = orientationGroups(of: second, axis: axis)
                let required = pair.requiredClearance
                    + problem.items[first].wallClearance
                    + problem.items[second].wallClearance
                let span = spans[axis]

                var anyCombinationFits = false
                var impossible: [(a: [Int], b: [Int])] = []
                for groupA in groupsA {
                    for groupB in groupsB {
                        let needed = 2 * groupA.halfExtent + 2 * groupB.halfExtent + required
                        if needed <= span + 1e-9 {
                            anyCombinationFits = true
                        } else {
                            impossible.append((groupA.variables, groupB.variables))
                        }
                    }
                }

                let axisRelations = [pair.separation[axis * 2], pair.separation[axis * 2 + 1]]
                if !anyCombinationFits {
                    excludedAxes += 1
                    if excludedAxes == 2 {
                        return PackingInfeasibility(
                            reason: .noFeasibleArrangement,
                            detail: "“\(problem.items[first].item.name)” and “\(problem.items[second].item.name)” cannot be placed side by side along either module axis with their required clearances, so no arrangement contains both."
                        )
                    }
                    guard budget >= 1 else { continue }
                    program.addLessOrEqual(
                        name: "fitAxis\(axis)_\(first)_\(second)",
                        terms: axisRelations.map { ($0, 1.0) },
                        value: 0
                    )
                    budget -= 1
                    appliedCuts.fittingPairs += 1
                    continue
                }

                // Oriented variant: forbid the individual impossible orientation combinations.
                // "Not all of these at once" over k indicators is Σ I ≤ k − 1; an indicator whose
                // orientation is fixed is identically 1 and is folded into the right-hand side.
                for combination in impossible {
                    guard budget >= 1 else { return nil }
                    var terms: [(Int, Double)] = axisRelations.map { ($0, 1.0) }
                    var indicators = 1 // the axis indicator, γ_axis1 + γ_axis2
                    if !combination.a.isEmpty {
                        terms.append(contentsOf: combination.a.map { ($0, 1.0) })
                        indicators += 1
                    }
                    if !combination.b.isEmpty {
                        terms.append(contentsOf: combination.b.map { ($0, 1.0) })
                        indicators += 1
                    }
                    guard indicators >= 2 else { continue }
                    program.addLessOrEqual(
                        name: "fitPair\(axis)_\(first)_\(second)_\(appliedCuts.orientedFittingPairs)",
                        terms: terms,
                        value: Double(indicators - 1)
                    )
                    budget -= 1
                    appliedCuts.orientedFittingPairs += 1
                }
            }
        }
        return nil
    }

    /// Three packages pairwise separated along one axis lie in a row along it, so the axis has to
    /// accommodate all three bodies, two clearances between neighbours and two wall clearances.
    /// Using the smallest possible value for every term keeps the test a valid implication.
    private mutating func addFittingTripleCuts(budget: inout Int) {
        let count = problem.items.count
        guard count >= 3 else { return }
        let spans = [module.lengthMillimetres, module.widthMillimetres]

        for first in 0..<count {
            for second in (first + 1)..<count {
                for third in (second + 1)..<count {
                    let trio = [first, second, third]
                    guard
                        let pairA = pair(first, second),
                        let pairB = pair(first, third),
                        let pairC = pair(second, third)
                    else { continue }

                    let smallestClearance = min(
                        pairA.requiredClearance,
                        min(pairB.requiredClearance, pairC.requiredClearance)
                    )
                    let smallestWallClearance = trio.map { problem.items[$0].wallClearance }.min() ?? 0

                    for axis in 0..<2 {
                        let bodies = trio.reduce(0.0) { $0 + 2 * problem.items[$1].minimumHalfExtents[axis] }
                        let needed = bodies + 2 * smallestClearance + 2 * smallestWallClearance
                        if needed <= spans[axis] + 1e-9 { continue }
                        guard budget >= 1 else { return }
                        // Not all three pairs may choose this axis.
                        var terms: [(Int, Double)] = []
                        for pair in [pairA, pairB, pairC] {
                            terms.append((pair.separation[axis * 2], 1))
                            terms.append((pair.separation[axis * 2 + 1], 1))
                        }
                        program.addLessOrEqual(
                            name: "fitTriple\(axis)_\(first)_\(second)_\(third)",
                            terms: terms,
                            value: 2
                        )
                        budget -= 1
                        appliedCuts.fittingTriples += 1
                    }
                }
            }
        }
    }

    // MARK: - Transitivity

    /// Paper §3.1. If `i` is ahead of `j` and `j` is ahead of `k` along one axis, then `k` cannot
    /// be ahead of `i` along that axis — the separation relations along an axis induce a strict
    /// order, and a cycle in a strict order is impossible. Each cut forbids one three-cycle.
    private mutating func addTransitivityCuts(budget: inout Int) {
        let count = problem.items.count
        guard count >= 3 else { return }

        for first in 0..<count {
            for second in (first + 1)..<count {
                for third in (second + 1)..<count {
                    guard
                        let pairA = pair(first, second),
                        let pairB = pair(second, third),
                        let pairC = pair(first, third)
                    else { continue }

                    for axis in 0..<2 {
                        // i → j → k → i
                        let forward = [
                            pairA.separation[relationIndex(pair: pairA, ahead: first, axis: axis)],
                            pairB.separation[relationIndex(pair: pairB, ahead: second, axis: axis)],
                            pairC.separation[relationIndex(pair: pairC, ahead: third, axis: axis)],
                        ]
                        // and the reverse cycle.
                        let backward = [
                            pairA.separation[relationIndex(pair: pairA, ahead: second, axis: axis)],
                            pairB.separation[relationIndex(pair: pairB, ahead: third, axis: axis)],
                            pairC.separation[relationIndex(pair: pairC, ahead: first, axis: axis)],
                        ]
                        for (name, cycle) in [("fwd", forward), ("bwd", backward)] {
                            guard budget >= 1 else { return }
                            program.addLessOrEqual(
                                name: "cycle\(axis)\(name)_\(first)_\(second)_\(third)",
                                terms: cycle.map { ($0, 1.0) },
                                value: 2
                            )
                            budget -= 1
                            appliedCuts.transitivity += 1
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    var module: PayloadModule { problem.module }

    func pair(_ first: Int, _ second: Int) -> PairVariables? {
        let low = min(first, second)
        let high = max(first, second)
        return pairs.first { $0.first == low && $0.second == high }
    }

    /// Index into `pair.separation` of the relation "`ahead` is at the larger coordinate on `axis`".
    private func relationIndex(pair: PairVariables, ahead: Int, axis: Int) -> Int {
        let base = axis * 2
        return ahead == pair.first ? base : base + 1
    }

    /// Orientations grouped by their half-extent on one axis. Grouping keeps the fitting cuts to
    /// one row per distinct extent pair rather than one per orientation pair.
    private func orientationGroups(of index: Int, axis: Int) -> [(halfExtent: Double, variables: [Int])] {
        let prepared = problem.items[index]
        let variables = orientationVariables[index]
        var order: [Int64] = []
        var grouped: [Int64: (Double, [Int])] = [:]
        for (position, orientation) in prepared.orientations.enumerated() {
            let value = orientation.halfExtents[axis]
            let key = Int64((value * 1e6).rounded())
            if grouped[key] == nil {
                grouped[key] = (value, [])
                order.append(key)
            }
            if !variables.isEmpty {
                grouped[key]!.1.append(variables[position])
            }
        }
        return order.compactMap { grouped[$0] }.map { (halfExtent: $0.0, variables: $0.1) }
    }
}
