import Foundation
import simd

/// Extreme Points and the Extreme-Point Best Positioning Heuristic, paper §5.1.
///
/// Extreme Points are Crainic, Perboli & Tadei's extension of Martello, Pisinger & Vigo's Corner
/// Points; the 3BKP paper uses them as-is and refers to [7] for the details. The generation rule it
/// states is: when an item with sizes `(w_j, d_j, h_j)` is placed with its left-back-down corner at
/// `(x_j, y_j, z_j)`, the points `(x_j+w_j, y_j, z_j)`, `(x_j, y_j+d_j, z_j)` and
/// `(x_j, y_j, z_j+h_j)` are projected on the orthogonal axes of the knapsack, each producing a new
/// Extreme Point.
nonisolated struct BaldiExtremePoint: Sendable, Hashable {
    var position: SIMD3<Double>
    /// `RS^x_e`, `RS^y_e`, `RS^z_e` — the free space around the point along each axis.
    var residualSpace: SIMD3<Double>
}

/// A packing under construction: placed items and the current Extreme Point set.
///
/// `canPlace` is the single construction gate. A candidate must be contained, non-overlapping and
/// completely supported before it can enter the packing.
nonisolated struct BaldiPacking: Sendable {
    let knapsack: BaldiKnapsack
    private(set) var placements: [BaldiPlacement] = []
    private(set) var extremePoints: [BaldiExtremePoint]

    /// The knapsack extent as a real vector, since placements carry continuous coordinates.
    let extent: SIMD3<Double>
    private let tolerance = 1e-6

    init(knapsack: BaldiKnapsack) {
        self.knapsack = knapsack
        self.extent = SIMD3(
            Double(knapsack.size.x),
            Double(knapsack.size.y),
            Double(knapsack.size.z)
        )
        // The empty knapsack offers one Extreme Point, its own origin, whose residual space is the
        // distance to the far side on each axis.
        self.extremePoints = [
            BaldiExtremePoint(
                position: .zero,
                residualSpace: SIMD3(
                    Double(knapsack.size.x),
                    Double(knapsack.size.y),
                    Double(knapsack.size.z)
                )
            )
        ]
    }

    // MARK: - Queries

    /// True when a box is inside the knapsack and clear of every item already placed.
    private func canPlaceGeometrically(size: SIMD3<Int>, at origin: SIMD3<Double>) -> Bool {
        guard size.x > 0, size.y > 0, size.z > 0 else { return false }
        let body = SIMD3<Double>(Double(size.x), Double(size.y), Double(size.z))
        for axis in 0..<3 {
            guard origin[axis].isFinite else { return false }
            if origin[axis] < -tolerance { return false }
            if origin[axis] + body[axis] > extent[axis] + tolerance { return false }
        }
        let maximum = origin + body
        for placed in placements {
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

    func canPlace(
        item: BaldiItem,
        rotation: BaldiRotation,
        at point: BaldiExtremePoint
    ) -> Bool {
        guard BaldiRotation.all.contains(rotation),
              item.mass.isFinite,
              item.mass > 0,
              !placements.contains(where: { $0.id == item.id }) else { return false }
        let placement = candidate(item: item, rotation: rotation, at: point)
        guard canPlaceGeometrically(size: placement.size, at: placement.origin) else { return false }
        return BaldiVerticalSupport.report(for: placement, among: placements).isFullySupported
    }

    // MARK: - Placement

    /// Places an item and refreshes the Extreme Point set. The check is repeated here so no caller
    /// can bypass the construction invariant after merely forgetting to call `canPlace` first.
    @discardableResult
    mutating func place(
        item: BaldiItem,
        rotation: BaldiRotation,
        at point: BaldiExtremePoint
    ) -> Bool {
        guard canPlace(item: item, rotation: rotation, at: point) else { return false }
        let placement = candidate(item: item, rotation: rotation, at: point)
        placements.append(placement)

        // The point just used is consumed, and any point now buried inside an item is dropped.
        extremePoints.removeAll { $0.position == point.position }
        appendGeneratedPoints(for: placement)
        pruneAndRefreshResidualSpace()
        return true
    }

    private func candidate(
        item: BaldiItem,
        rotation: BaldiRotation,
        at point: BaldiExtremePoint
    ) -> BaldiPlacement {
        BaldiPlacement(
            id: item.id,
            name: item.name,
            origin: point.position,
            rotation: rotation,
            size: rotation.size(of: item.size),
            mass: item.mass
        )
    }

    /// The six points the paper's rule produces for a newly placed item: each of the three corner
    /// points, projected on the two axes orthogonal to the one it extends along.
    private mutating func appendGeneratedPoints(for placement: BaldiPlacement) {
        let origin = placement.origin
        let maximum = placement.maximum
        let candidates: [(point: SIMD3<Double>, axes: [Int])] = [
            (SIMD3(maximum.x, origin.y, origin.z), [1, 2]),
            (SIMD3(origin.x, maximum.y, origin.z), [0, 2]),
            (SIMD3(origin.x, origin.y, maximum.z), [0, 1]),
        ]
        for candidate in candidates {
            for axis in candidate.axes {
                var projected = candidate.point
                projected[axis] = projection(of: candidate.point, along: axis)
                extremePoints.append(
                    BaldiExtremePoint(position: projected, residualSpace: .zero)
                )
            }
        }
    }

    /// Projects `point` in the negative direction of `axis` onto the nearest item face below it, or
    /// onto the knapsack wall at 0 when nothing is in the way.
    private func projection(of point: SIMD3<Double>, along axis: Int) -> Double {
        let (first, second) = otherAxes(of: axis)
        var best = 0.0
        for placed in placements {
            guard placed.origin[first] <= point[first] + tolerance,
                  point[first] < placed.maximum[first] - tolerance else { continue }
            guard placed.origin[second] <= point[second] + tolerance,
                  point[second] < placed.maximum[second] - tolerance else { continue }
            guard placed.maximum[axis] <= point[axis] + tolerance else { continue }
            best = max(best, placed.maximum[axis])
        }
        return best
    }

    /// Drops duplicate and buried points, then recomputes every residual space.
    ///
    /// The paper updates the residual spaces incrementally as each item is added; recomputing them
    /// from the current items gives the same values — the distance from the point to the knapsack
    /// side or to the nearest item along each axis — and cannot drift.
    private mutating func pruneAndRefreshResidualSpace() {
        var seen: Set<SIMD3<Double>> = []
        var kept: [BaldiExtremePoint] = []
        for point in extremePoints {
            let position = point.position
            var outside = false
            for axis in 0..<3 where position[axis] < -tolerance || position[axis] >= extent[axis] - tolerance {
                outside = true
                break
            }
            if outside { continue }
            if isBuried(position) { continue }
            guard seen.insert(position).inserted else { continue }
            kept.append(
                BaldiExtremePoint(position: position, residualSpace: residualSpace(at: position))
            )
        }
        extremePoints = kept
    }

    private func isBuried(_ position: SIMD3<Double>) -> Bool {
        for placed in placements {
            var inside = true
            for axis in 0..<3
            where !(placed.origin[axis] <= position[axis] + tolerance
                && position[axis] < placed.maximum[axis] - tolerance) {
                inside = false
                break
            }
            if inside { return true }
        }
        return false
    }

    /// `RS_e`: along each axis, the distance from `position` to the knapsack side, cut short by the
    /// nearest item the ray from `position` runs into.
    private func residualSpace(at position: SIMD3<Double>) -> SIMD3<Double> {
        var space = extent - position
        for axis in 0..<3 {
            let (first, second) = otherAxes(of: axis)
            for placed in placements {
                guard placed.origin[first] <= position[first] + tolerance,
                      position[first] < placed.maximum[first] - tolerance else { continue }
                guard placed.origin[second] <= position[second] + tolerance,
                      position[second] < placed.maximum[second] - tolerance else { continue }
                guard placed.origin[axis] >= position[axis] - tolerance else { continue }
                space[axis] = min(space[axis], placed.origin[axis] - position[axis])
            }
        }
        return space
    }

    private func otherAxes(of axis: Int) -> (Int, Int) {
        switch axis {
        case 0: (1, 2)
        case 1: (0, 2)
        default: (0, 1)
        }
    }

    func solution(unloaded: [BaldiItem]) -> BaldiSolution {
        BaldiSolution(knapsack: knapsack, placements: placements, unloaded: unloaded)
    }
}

// MARK: - EP-BPH

/// The Extreme-Point Best Positioning Heuristic, paper §5.1.
///
///   * Order the items according to a sorting criterion.
///   * For each item in the resulting sequence and each rotation `r`, find the best Extreme Point
///     of the best available bin where to load the item.
///   * If such a bin exists, load the item into it on the given EP.
///   * If the item cannot be loaded in any existing bin, a new bin is created if the total number
///     of bins does not exceed the given maximum, otherwise the item is discarded.
///
/// The 3BKP has exactly one bin, so the last step is always a discard.
///
/// The best Extreme Point is chosen by the Residual Space rule, eq. (21):
///
///   f = (RS^x_e − w_j) + (RS^y_e − d_j) + (RS^z_e − h_j)
///
/// minimised over the points where the item fits. The paper notes that for complex packings the
/// residual space is only an estimate of the free volume, so potential overlaps are checked
/// explicitly when accommodating the item on the chosen point. This adaptation also rejects any
/// non-floor candidate whose complete bottom face is not supported, following Junqueira equation
/// (11) with `alpha = 1`.
nonisolated enum BaldiEPBPH {
    static func pack(
        order: [BaldiItem],
        knapsack: BaldiKnapsack
    ) -> BaldiSolution {
        var packing = BaldiPacking(knapsack: knapsack)
        var discarded: [BaldiItem] = []

        for item in order {
            var bestPoint: BaldiExtremePoint?
            var bestRotation: BaldiRotation?
            var bestScore = Double.infinity

            for point in packing.extremePoints {
                for rotation in BaldiRotation.all {
                    let size = rotation.size(of: item.size)
                    // A residual space smaller than the item on any axis means the ray from the
                    // point runs into something before the item would end, so it cannot fit here.
                    let body = SIMD3<Double>(Double(size.x), Double(size.y), Double(size.z))
                    if point.residualSpace.x < body.x - 1e-6 { continue }
                    if point.residualSpace.y < body.y - 1e-6 { continue }
                    if point.residualSpace.z < body.z - 1e-6 { continue }
                    guard packing.canPlace(
                        item: item,
                        rotation: rotation,
                        at: point
                    ) else { continue }

                    let score = (point.residualSpace.x - body.x)
                        + (point.residualSpace.y - body.y)
                        + (point.residualSpace.z - body.z)
                    if score < bestScore {
                        bestScore = score
                        bestPoint = point
                        bestRotation = rotation
                    }
                }
            }

            if let bestPoint, let bestRotation {
                let placed = packing.place(
                    item: item,
                    rotation: bestRotation,
                    at: bestPoint
                )
                if !placed { discarded.append(item) }
            } else {
                discarded.append(item)
            }
        }

        return packing.solution(unloaded: discarded)
    }
}
