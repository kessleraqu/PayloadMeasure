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
/// Baldi finally applies gravity because its construction may leave packages floating. This hybrid
/// never admits such a package: Junqueira's full-support rule is enforced during construction and
/// after every tentative movement. Consequently there is no separate gravity repair that could
/// turn a partial contact into an invalid "resting" position.
nonisolated enum BaldiCentreOfMassOptimisation {
    nonisolated struct Options: Sendable, Equatable {
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
            if knapsack.containsCentreOfMass(centreOfMass(of: current)) { break }
            var movedAnything = false

            // The paper does not fix the order in which items are considered. Eq. (28) shows that
            // the displacement needed of item i to correct the centre of mass is inversely
            // proportional to its mass, so the heaviest items are tried first: they need to travel
            // the shortest distance and are therefore the most likely to fit inside their D_i.
            let order = current.indices.sorted { current[$0].mass > current[$1].mass }

            for index in order {
                let centre = centreOfMass(of: current)
                if knapsack.containsCentreOfMass(centre) { break }
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

                guard let domain = candidateDomain(for: index, in: current, knapsack: knapsack) else {
                    continue
                }
                let clamped = simd_clamp(desiredOrigin, domain.lower, domain.upper)
                let candidates = candidateOrigins(
                    for: index,
                    desired: clamped,
                    in: current,
                    domain: domain
                )
                guard let accepted = candidates.first(where: {
                    isAcceptableMove(
                        of: index,
                        to: $0,
                        in: current,
                        knapsack: knapsack
                    )
                }) else { continue }

                current[index].origin = accepted
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

    /// Axis-wise movement bounds inspired by Baldi's `D_i`. This box is only a source of candidate
    /// positions: every candidate is still checked for collision and full support before use.
    private static func candidateDomain(
        for index: Int,
        in placements: [BaldiPlacement],
        knapsack: BaldiKnapsack
    ) -> CandidateDomain? {
        let item = placements[index]
        let tolerance = 1e-6
        var lower = SIMD3<Double>.zero
        var upper = SIMD3<Double>(
            Double(knapsack.size.x), Double(knapsack.size.y), Double(knapsack.size.z)
        ) - item.extent
        for axis in 0..<3 where upper[axis] < -tolerance { return nil }

        for axis in 0..<3 {
            let (first, second) = otherAxes(of: axis)
            for (other, placed) in placements.enumerated() where other != index {
                // Only items that overlap on the other two axes can block this slide.
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

    /// Tries the desired point, the same horizontal point on every available support plane, and
    /// safe one-axis moves. Ordering by distance keeps the accepted move as close as possible to
    /// Baldi equation (29).
    private static func candidateOrigins(
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
                simd_distance_squared($0, desired) < simd_distance_squared($1, desired)
            }
    }

    /// A movement is accepted only when the moved package remains contained and non-overlapping
    /// and the complete packing still satisfies Junqueira's full-support rule. The whole-packing
    /// check is necessary because moving a lower package can strand packages above it.
    private static func isAcceptableMove(
        of index: Int,
        to origin: SIMD3<Double>,
        in placements: [BaldiPlacement],
        knapsack: BaldiKnapsack
    ) -> Bool {
        var proposed = placements
        proposed[index].origin = origin
        return isSpatiallyValid(proposed, in: knapsack)
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
