import Foundation
import simd

/// Centre-of-mass optimisation, paper §5.2.
///
/// From the paper: "Given a three-dimensional convex domain inside the knapsack, the balancing
/// procedure tries to adjust the packed items position so that the packing center of mass lies
/// inside the domain. The heuristic just moves already packed items, therefore neither items are
/// added or removed from the knapsack, nor the overall profit is modified by the procedure."
///
/// The procedure computes `r_CM` from eq. (2) and then moves one item after another so that
/// `r_CM` moves towards the desired position:
///
///   (25)  r_CM  = Σ_{j≠i} m_j r_CMj / M + m_i r_CMi / M
///   (26)  r'_CM = Σ_{j≠i} m_j r_CMj / M + m_i r'_CMi / M
///   (27)  r'_CM − r_CM = m_i (r'_CMi − r_CMi) / M
///   (28)  r'_CMi = r_CMi + (r'_CM − r_CM) M / m_i
///   (29)  r'_i = (r'¹_CMi − γ¹_ir̄, r'²_CMi − γ²_ir̄, r'³_CMi − γ³_ir̄)
///
/// A domain `D_i` of positions the origin of item `i` may take without overlapping the other items
/// or the bin is then computed "with an algorithm similar to the one used to calculate the RS of an
/// EP", and one of three cases applies: `D_i` empty and the item cannot move; `r'_i ∈ D_i` and the
/// item moves there; `r'_i ∉ D_i` and the item moves to the point of `D_i` that better approximates
/// `r'_i` on each axis.
///
/// Paper mode approximates `D_i` locally from blockers around the old position and stops when the
/// CoM first enters `[L,U]`. Centred mode samples a bounded set of static placements across the
/// container and continues toward the domain centre. The latter is a rearrangement, not a claim of
/// a collision-free physical motion path.
///
/// Baldi finally applies gravity because its construction may leave packages floating. This hybrid
/// never admits such a package: Junqueira's full-support rule is enforced during construction and
/// after every tentative movement. Consequently there is no separate gravity repair that could
/// turn a partial contact into an invalid "resting" position.
///
/// Both modes recheck containment, non-overlap and full support on the complete proposed packing,
/// and commit only a strict CoM-distance improvement. Centred mode additionally requires every
/// post-feasibility refinement to remain inside `[L,U]`.
nonisolated enum BaldiCentreOfMassOptimisation {
    nonisolated struct Options: Sendable, Equatable {
        /// `.paper` is the academically conservative default. `.centred` is an explicit
        /// post-feasibility quality refinement and is reported separately from paper mode.
        var mode: BaldiPackingMode = .paper
        /// The paper states a maximum number of iterations as a stopping condition but does not
        /// give its value.
        var maximumIterations = 50

        init() {}
    }

    /// Runs the procedure on a packing and returns the adjusted placements.
    static func optimise(
        placements: [BaldiPlacement],
        knapsack: BaldiKnapsack,
        options: Options = Options()
    ) -> [BaldiPlacement] {
        guard !placements.isEmpty else { return placements }
        guard options.maximumIterations > 0 else { return placements }
        guard hasValidDomain(knapsack) else { return placements }
        guard isSpatiallyValid(placements, in: knapsack) else { return placements }
        var current = placements
        let target = knapsack.idealCentreOfMass

        for _ in 0..<options.maximumIterations {
            if options.mode == .paper,
               knapsack.containsCentreOfMass(centreOfMass(of: current)) { break }
            var movedAnything = false

            // The paper does not fix the order in which items are considered. Eq. (28) shows that
            // the displacement needed of item i to correct the centre of mass is inversely
            // proportional to its mass, so the heaviest items are tried first: they need to travel
            // the shortest distance and are therefore the most likely to fit inside their D_i.
            let order = current.indices.sorted { current[$0].mass > current[$1].mass }

            for index in order {
                let centre = centreOfMass(of: current)
                if options.mode == .paper,
                   knapsack.containsCentreOfMass(centre) { break }
                let currentQuality = simd_distance_squared(centre, target)
                guard currentQuality.isFinite, currentQuality > 0 else { continue }
                let mustRemainBalanced = knapsack.containsCentreOfMass(centre)
                let totalMass = current.reduce(0) { $0 + $1.mass }
                let item = current[index]
                guard item.mass.isFinite, item.mass > 0,
                      totalMass.isFinite, totalMass > 0 else { continue }

                // (28) then (29): where this item's origin would have to go to put the packing
                // centre of mass exactly on the target.
                let desiredItemCentre = item.centreOfMass + (target - centre) * totalMass / item.mass
                let halfSize = SIMD3<Double>(
                    Double(item.size.x) / 2,
                    Double(item.size.y) / 2,
                    Double(item.size.z) / 2
                )
                let desiredOrigin = desiredItemCentre - halfSize

                let domain: CandidateDomain?
                switch options.mode {
                case .paper:
                    domain = localCandidateDomain(
                        for: index,
                        in: current,
                        knapsack: knapsack
                    )
                case .centred:
                    domain = containerDomain(for: item, knapsack: knapsack)
                }
                guard let domain else {
                    continue
                }
                let clamped = simd_clamp(desiredOrigin, domain.lower, domain.upper)
                let candidates: [SIMD3<Double>]
                switch options.mode {
                case .paper:
                    candidates = localCandidateOrigins(
                        for: index,
                        desired: clamped,
                        in: current,
                        domain: domain
                    )
                case .centred:
                    candidates = centredCandidateOrigins(
                        for: index,
                        desired: clamped,
                        in: current,
                        domain: domain
                    )
                }
                guard let improvement = bestImprovingMove(
                    of: index,
                    toOneOf: candidates,
                    in: current,
                    knapsack: knapsack,
                    target: target,
                    currentQuality: currentQuality,
                    mustRemainBalanced: mustRemainBalanced
                ) else { continue }

                current = improvement
                movedAnything = true
            }

            if !movedAnything { break } // no item can be moved any more
        }

        return current
    }

    /// `r_CM`, eq. (2).
    static func centreOfMass(of placements: [BaldiPlacement]) -> SIMD3<Double> {
        guard !placements.isEmpty else { return .zero }
        guard placements.allSatisfy({
            $0.mass.isFinite
                && $0.mass > 0
                && $0.origin.x.isFinite
                && $0.origin.y.isFinite
                && $0.origin.z.isFinite
        }) else { return SIMD3<Double>(repeating: .nan) }
        let mass = placements.reduce(0) { $0 + $1.mass }
        guard mass.isFinite, mass > 0 else { return SIMD3<Double>(repeating: .nan) }
        var moment = SIMD3<Double>.zero
        for placement in placements {
            moment += placement.centreOfMass * placement.mass
        }
        return moment / mass
    }

    // MARK: - Candidate movement region

    private struct CandidateDomain {
        var lower: SIMD3<Double>
        var upper: SIMD3<Double>
    }

    /// Baldi's local `D_i` approximation: packages intersecting the moving package's current
    /// projection bound each axis. This intentionally models a local collision-free-ish move and
    /// can exclude a valid static relocation elsewhere; centred mode exists for that separate use.
    private static func localCandidateDomain(
        for index: Int,
        in placements: [BaldiPlacement],
        knapsack: BaldiKnapsack
    ) -> CandidateDomain? {
        let item = placements[index]
        let tolerance = BaldiVerticalSupport.contactTolerance
        var lower = SIMD3<Double>.zero
        var upper = SIMD3<Double>(
            Double(knapsack.size.x), Double(knapsack.size.y), Double(knapsack.size.z)
        ) - item.extent
        for axis in 0..<3 where upper[axis] < -tolerance { return nil }

        for axis in 0..<3 {
            let (first, second) = otherAxes(of: axis)
            for (other, placed) in placements.enumerated() where other != index {
                let overlapsFirst = item.origin[first] < placed.maximum[first] - tolerance
                    && placed.origin[first] < item.maximum[first] - tolerance
                let overlapsSecond = item.origin[second] < placed.maximum[second] - tolerance
                    && placed.origin[second] < item.maximum[second] - tolerance
                guard overlapsFirst, overlapsSecond else { continue }

                if placed.maximum[axis] <= item.origin[axis] + tolerance {
                    lower[axis] = max(lower[axis], placed.maximum[axis])
                } else if placed.origin[axis] >= item.maximum[axis] - tolerance {
                    upper[axis] = min(upper[axis], placed.origin[axis] - item.extent[axis])
                }
            }
            if lower[axis] > upper[axis] + tolerance { return nil }
        }
        return CandidateDomain(lower: lower, upper: upper)
    }

    /// The complete container bounds for a package origin. Blockers around the package's old
    /// position are deliberately not folded into these bounds: the optimisation computes a new
    /// static arrangement, not a collision-free motion path. Every proposed final arrangement is
    /// checked independently for overlap, containment and whole-packing support before commitment.
    private static func containerDomain(
        for item: BaldiPlacement,
        knapsack: BaldiKnapsack
    ) -> CandidateDomain? {
        let tolerance = 1e-6
        let lower = SIMD3<Double>.zero
        let upper = SIMD3<Double>(
            Double(knapsack.size.x), Double(knapsack.size.y), Double(knapsack.size.z)
        ) - item.extent
        for axis in 0..<3 where upper[axis] < -tolerance { return nil }
        return CandidateDomain(lower: lower, upper: upper)
    }

    /// Builds a deterministic bounded neighbourhood containing the desired point, floor and
    /// support-plane variants, one-axis refinements, and positions adjacent to existing package
    /// faces. The edge coordinates let the search find open gaps when the exact desired point is
    /// occupied. Candidate count is capped because each one receives a whole-packing validation.
    private static func centredCandidateOrigins(
        for index: Int,
        desired: SIMD3<Double>,
        in placements: [BaldiPlacement],
        domain: CandidateDomain
    ) -> [SIMD3<Double>] {
        let maximumAxisCoordinates = 8
        let maximumCandidates = 48
        let item = placements[index]
        let original = placements[index].origin
        let others = placements.indices.filter { $0 != index }.map { placements[$0] }

        let xCoordinates = boundedCoordinates(
            required: [desired.x, original.x, domain.lower.x, domain.upper.x],
            alternatives: others.flatMap { [$0.origin.x - item.extent.x, $0.maximum.x] },
            lower: domain.lower.x,
            upper: domain.upper.x,
            desired: desired.x,
            limit: maximumAxisCoordinates
        )
        let yCoordinates = boundedCoordinates(
            required: [desired.y, original.y, domain.lower.y, domain.upper.y],
            alternatives: others.flatMap { [$0.origin.y - item.extent.y, $0.maximum.y] },
            lower: domain.lower.y,
            upper: domain.upper.y,
            desired: desired.y,
            limit: maximumAxisCoordinates
        )
        let supportHeights = boundedCoordinates(
            required: [desired.z, original.z, domain.lower.z, domain.upper.z],
            alternatives: others.map(\.maximum.z),
            lower: domain.lower.z,
            upper: domain.upper.z,
            desired: desired.z,
            limit: maximumAxisCoordinates
        )

        var priority: [SIMD3<Double>] = [desired]
        for height in supportHeights {
            priority.append(SIMD3(desired.x, desired.y, height))
        }

        for axis in 0..<3 {
            var candidate = original
            candidate[axis] = desired[axis]
            priority.append(candidate)
        }

        var neighbourhood: [SIMD3<Double>] = []
        for x in xCoordinates {
            for y in yCoordinates {
                for z in supportHeights {
                    neighbourhood.append(SIMD3(x, y, z))
                }
            }
        }
        neighbourhood.sort { first, second in
            let firstDistance = simd_distance_squared(first, desired)
            let secondDistance = simd_distance_squared(second, desired)
            if firstDistance != secondDistance { return firstDistance < secondDistance }
            if first.x != second.x { return first.x < second.x }
            if first.y != second.y { return first.y < second.y }
            return first.z < second.z
        }

        var seen: Set<SIMD3<Double>> = []
        var result: [SIMD3<Double>] = []
        for candidate in priority + neighbourhood {
            guard simd_distance_squared(candidate, original) >= 1e-12 else { continue }
            guard seen.insert(candidate).inserted else { continue }
            result.append(candidate)
            if result.count == maximumCandidates { break }
        }
        return result
    }

    /// The smaller paper-mode neighbourhood approximates the desired local origin on available
    /// support planes and one axis at a time. Final whole-packing validation still enforces the
    /// Junqueira support rule, which is the documented addition to Baldi.
    private static func localCandidateOrigins(
        for index: Int,
        desired: SIMD3<Double>,
        in placements: [BaldiPlacement],
        domain: CandidateDomain
    ) -> [SIMD3<Double>] {
        let original = placements[index].origin
        var candidates: [SIMD3<Double>] = [desired]

        let supportHeights = [0.0] + placements.indices
            .filter { $0 != index }
            .map { placements[$0].maximum.z }
        for height in supportHeights where height >= domain.lower.z && height <= domain.upper.z {
            var candidate = desired
            candidate.z = height
            candidates.append(candidate)
        }

        for axis in 0..<3 {
            var candidate = original
            candidate[axis] = desired[axis]
            candidates.append(candidate)
        }

        var seen: Set<SIMD3<Double>> = []
        return candidates
            .filter { simd_distance_squared($0, original) >= 1e-12 }
            .filter { seen.insert($0).inserted }
            .sorted {
                let firstDistance = simd_distance_squared($0, desired)
                let secondDistance = simd_distance_squared($1, desired)
                if firstDistance != secondDistance { return firstDistance < secondDistance }
                if $0.x != $1.x { return $0.x < $1.x }
                if $0.y != $1.y { return $0.y < $1.y }
                return $0.z < $1.z
            }
    }

    private static func boundedCoordinates(
        required: [Double],
        alternatives: [Double],
        lower: Double,
        upper: Double,
        desired: Double,
        limit: Int
    ) -> [Double] {
        func clamped(_ value: Double) -> Double {
            min(max(value, lower), upper)
        }

        var seen: Set<Double> = []
        var result: [Double] = []
        for value in required where value.isFinite {
            let value = clamped(value)
            if seen.insert(value).inserted { result.append(value) }
        }

        let orderedAlternatives = alternatives
            .filter(\.isFinite)
            .map(clamped)
            .sorted { first, second in
                let firstDistance = abs(first - desired)
                let secondDistance = abs(second - desired)
                return firstDistance == secondDistance
                    ? first < second
                    : firstDistance < secondDistance
            }
        for value in orderedAlternatives where result.count < limit {
            if seen.insert(value).inserted { result.append(value) }
        }
        return Array(result.prefix(limit))
    }

    /// Selects the spatially valid candidate that puts the overall cargo centre of mass closest to
    /// the ideal point. A move is returned only for a strict numerical improvement. Evaluating the
    /// complete proposed packing is necessary because moving a lower package can strand packages
    /// above it. With one package moving, minimising this aggregate distance is algebraically
    /// equivalent to choosing the candidate origin closest to Baldi's equation (29) target.
    private static func bestImprovingMove(
        of index: Int,
        toOneOf origins: [SIMD3<Double>],
        in placements: [BaldiPlacement],
        knapsack: BaldiKnapsack,
        target: SIMD3<Double>,
        currentQuality: Double,
        mustRemainBalanced: Bool
    ) -> [BaldiPlacement]? {
        var best: [BaldiPlacement]?
        var bestQuality = currentQuality

        for origin in origins {
            var proposed = placements
            proposed[index].origin = origin
            guard isSpatiallyValid(proposed, in: knapsack) else { continue }

            let proposedCentre = centreOfMass(of: proposed)
            if mustRemainBalanced,
               !knapsack.containsCentreOfMass(proposedCentre) { continue }
            let proposedQuality = simd_distance_squared(proposedCentre, target)
            guard isStrictImprovement(proposedQuality, over: bestQuality) else { continue }
            best = proposed
            bestQuality = proposedQuality
        }
        return best
    }

    /// Ignores changes at floating-point noise scale, while requiring a genuinely smaller squared
    /// distance for every committed move.
    private static func isStrictImprovement(_ candidate: Double, over incumbent: Double) -> Bool {
        guard candidate.isFinite, incumbent.isFinite else { return false }
        let scale = max(1, max(abs(candidate), abs(incumbent)))
        return candidate < incumbent - scale * 1e-12
    }

    /// Whole-packing validation used at entry and after every tentative movement. Checking the
    /// complete array makes the support dependency explicit: moving one lower package can make a
    /// different package above it invalid even when the moved package itself still fits.
    private static func isSpatiallyValid(
        _ placements: [BaldiPlacement],
        in knapsack: BaldiKnapsack
    ) -> Bool {
        let tolerance = BaldiVerticalSupport.contactTolerance
        for placement in placements {
            guard placement.mass.isFinite,
                  placement.mass > 0,
                  placement.size.x > 0,
                  placement.size.y > 0,
                  placement.size.z > 0 else { return false }
            for axis in 0..<3 {
                guard placement.origin[axis].isFinite else { return false }
                if placement.origin[axis] < -tolerance { return false }
                if placement.maximum[axis] > Double(knapsack.size[axis]) + tolerance {
                    return false
                }
            }
        }

        for first in placements.indices {
            for second in placements.indices where second > first {
                if placements[first].overlaps(placements[second], tolerance: tolerance) {
                    return false
                }
            }
        }
        return BaldiVerticalSupport.allFullySupported(placements, tolerance: tolerance)
    }

    private static func hasValidDomain(_ knapsack: BaldiKnapsack) -> Bool {
        guard knapsack.size.x > 0, knapsack.size.y > 0, knapsack.size.z > 0 else {
            return false
        }
        for axis in 0..<3 {
            let lower = knapsack.domainLower[axis]
            let upper = knapsack.domainUpper[axis]
            guard lower.isFinite,
                  upper.isFinite,
                  lower >= 0,
                  lower <= upper,
                  upper <= Double(knapsack.size[axis]) else { return false }
        }
        return true
    }

    private static func otherAxes(of axis: Int) -> (Int, Int) {
        switch axis {
        case 0: (1, 2)
        case 1: (0, 2)
        default: (0, 1)
        }
    }

}
