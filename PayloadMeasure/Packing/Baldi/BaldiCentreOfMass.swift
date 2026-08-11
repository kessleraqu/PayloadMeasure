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
/// Finally, "the algorithm simulates the force of gravity by compacting all items along the z axis
/// towards the (x, y) plan", and stops when the packing is balanced, no item can be moved any more,
/// or a maximum number of iterations has been reached.
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
        // Gravity is applied before the first balance test as well as after every round of
        // movements. EP-BPH on its own does leave items unsupported — measured at 3 of 239 items
        // over 40 random instances — and the paper calls a state that ignores gravity a "faulty
        // solution for many real-life applications", so the balance decision is always taken on the
        // settled packing rather than on a floating one.
        var current = applyGravity(to: placements, knapsack: knapsack)
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
                guard item.mass > 0, totalMass > 0 else { continue }

                // (28) then (29): where this item's origin would have to go to put the packing
                // centre of mass exactly on the target.
                let desiredItemCentre = item.centreOfMass + (target - centre) * totalMass / item.mass
                let halfSize = SIMD3<Double>(
                    Double(item.size.x) / 2,
                    Double(item.size.y) / 2,
                    Double(item.size.z) / 2
                )
                let desiredOrigin = desiredItemCentre - halfSize

                guard let domain = freeDomain(for: index, in: current, knapsack: knapsack) else {
                    continue // D_i = ∅: the item cannot move.
                }
                // The point of D_i that better approximates r'_i on each axis.
                var clamped = simd_clamp(desiredOrigin, domain.lower, domain.upper)
                if simd_distance_squared(clamped, item.origin) < 1e-12 { continue }

                // D_i is built axis by axis, exactly as the residual space of an Extreme Point is,
                // so a move along a single axis is always safe but a diagonal one need not be.
                // The combined move is verified and, if it collides, applied one axis at a time.
                if !isFree(size: item.size, at: clamped, in: current, excluding: index, knapsack: knapsack) {
                    var stepped = item.origin
                    for axis in 0..<3 {
                        var candidate = stepped
                        candidate[axis] = clamped[axis]
                        if isFree(size: item.size, at: candidate, in: current, excluding: index, knapsack: knapsack) {
                            stepped = candidate
                        }
                    }
                    clamped = stepped
                }
                if simd_distance_squared(clamped, item.origin) < 1e-12 { continue }

                current[index].origin = clamped
                movedAnything = true
            }

            // §5.2: "Items movements may lead to a state that does not take gravity effects into
            // account ... so the algorithm simulates the force of gravity by compacting all items
            // along the z axis towards the (x, y) plan." The paper places this paragraph before the
            // stopping conditions, so it runs inside the iteration and the next balance test sees
            // the settled packing.
            current = applyGravity(to: current, knapsack: knapsack)

            if !movedAnything { break } // no item can be moved any more
        }

        return current
    }

    /// `r_CM`, eq. (2).
    static func centreOfMass(of placements: [BaldiPlacement]) -> SIMD3<Double> {
        let mass = placements.reduce(0) { $0 + $1.mass }
        guard mass > 0 else { return .zero }
        var moment = SIMD3<Double>.zero
        for placement in placements {
            moment += placement.centreOfMass * placement.mass
        }
        return moment / mass
    }

    /// "The algorithm simulates the force of gravity by compacting all items along the z axis
    /// towards the (x, y) plan." Each item is dropped as far as it can go, lowest first.
    static func applyGravity(
        to placements: [BaldiPlacement],
        knapsack: BaldiKnapsack
    ) -> [BaldiPlacement] {
        var current = placements
        let tolerance = 1e-6
        let order = current.indices.sorted { current[$0].origin.z < current[$1].origin.z }
        for index in order {
            let item = current[index]
            // The item comes to rest on the highest face beneath it that its footprint overlaps,
            // or on the floor. Solving for the resting height directly is exact and avoids
            // stepping down one unit at a time.
            var resting = 0.0
            for (other, placed) in current.enumerated() where other != index {
                guard placed.maximum.z <= item.origin.z + tolerance else { continue }
                let overlapsX = item.origin.x < placed.maximum.x - tolerance
                    && placed.origin.x < item.maximum.x - tolerance
                let overlapsY = item.origin.y < placed.maximum.y - tolerance
                    && placed.origin.y < item.maximum.y - tolerance
                guard overlapsX, overlapsY else { continue }
                resting = max(resting, placed.maximum.z)
            }
            current[index].origin.z = min(item.origin.z, resting)
        }
        return current
    }

    // MARK: - The domain D_i

    private struct Domain {
        var lower: SIMD3<Double>
        var upper: SIMD3<Double>
    }

    /// The positions the origin of item `index` may take, computed axis by axis in the same way as
    /// the residual space of an Extreme Point: along each axis, how far the item can slide in each
    /// direction before it meets another item that overlaps it on the other two axes.
    private static func freeDomain(
        for index: Int,
        in placements: [BaldiPlacement],
        knapsack: BaldiKnapsack
    ) -> Domain? {
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
        return Domain(lower: lower, upper: upper)
    }

    private static func isFree(
        size: SIMD3<Int>,
        at origin: SIMD3<Double>,
        in placements: [BaldiPlacement],
        excluding index: Int,
        knapsack: BaldiKnapsack
    ) -> Bool {
        let tolerance = 1e-6
        let body = SIMD3<Double>(Double(size.x), Double(size.y), Double(size.z))
        for axis in 0..<3 {
            if origin[axis] < -tolerance { return false }
            if origin[axis] + body[axis] > Double(knapsack.size[axis]) + tolerance { return false }
        }
        let maximum = origin + body
        for (other, placed) in placements.enumerated() where other != index {
            var separated = false
            for axis in 0..<3
            where origin[axis] >= placed.maximum[axis] - tolerance
                || placed.origin[axis] >= maximum[axis] - tolerance {
                separated = true
                break
            }
            if !separated { return false }
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
