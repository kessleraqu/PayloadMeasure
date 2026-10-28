import Foundation
import simd

// Picks which of the measured surface points to draw.
//
// Points are chosen by a hash of their voxel rather than every k-th element, so the drawn set
// stays stable while the cloud grows. Since the per-point budget only shrinks, a dot that
// disappears never comes back. Hashing the voxel instead of the raw position stops depth noise
// from making dots flicker.

nonisolated enum SelectionPointDisplay {
    /// Fixed-point scale for the hash threshold.
    static let scale: UInt64 = 1 << 16

    static func hash(x: Int32, y: Int32, z: Int32) -> UInt64 {
        let prime: UInt64 = 1_099_511_628_211
        var value: UInt64 = 14_695_981_039_346_656_037
        for component in [x, y, z] {
            value = (value ^ UInt64(UInt32(bitPattern: component))) &* prime
        }
        return finalised(value)
    }

    /// splitmix64 finaliser. Plain FNV ends on a multiply, so its low bits follow the input's low
    /// bits and the selection came out in stripes; this mixes all bits.
    private static func finalised(_ value: UInt64) -> UInt64 {
        var mixed = value
        mixed ^= mixed >> 33
        mixed = mixed &* 0xFF51_AFD7_ED55_8CCD
        mixed ^= mixed >> 33
        mixed = mixed &* 0xC4CE_B9FE_1A85_EC53
        mixed ^= mixed >> 33
        return mixed
    }

    /// Up to `limit` items, the ones with the lowest hash rank. The rank is a total order per item,
    /// so array order never affects which items are kept.
    static func subset<Item>(
        _ items: [Item],
        limit: Int,
        hash: (Item) -> UInt64
    ) -> [Item] {
        guard limit > 0 else { return [] }
        guard items.count > limit else { return items }

        // Cheap first pass that drops most items that can't make the budget.
        let threshold = UInt64(
            (Double(limit) / Double(items.count) * Double(scale)).rounded()
        )
        var kept = items.filter { hash($0) % scale < threshold }

        if kept.count > limit {
            kept.sort { rank(hash($0), precedes: hash($1)) }
            kept.removeLast(kept.count - limit)
        }
        return kept
    }

    /// Like `subset`, but always keeps the points at the coordinate extremes so the visible dots
    /// still show what sets the box boundary.
    static func subsetPreservingCoordinateExtrema(
        _ points: [SIMD3<Float>],
        limit: Int,
        hash: (SIMD3<Float>) -> UInt64
    ) -> [SIMD3<Float>] {
        guard limit > 0 else { return [] }
        guard points.count > limit else { return points }

        func component(_ point: SIMD3<Float>, _ axis: Int) -> Float {
            switch axis {
            case 0: point.x
            case 1: point.y
            default: point.z
            }
        }

        func extremeIndex(axis: Int, maximum: Bool) -> Int {
            points.indices.dropFirst().reduce(points.startIndex) { best, candidate in
                let bestValue = component(points[best], axis)
                let candidateValue = component(points[candidate], axis)
                if maximum ? candidateValue > bestValue : candidateValue < bestValue {
                    return candidate
                }
                if candidateValue == bestValue,
                   rank(hash(points[candidate]), precedes: hash(points[best])) {
                    return candidate
                }
                return best
            }
        }

        // Height first, it's the boundary most easily lost when the cloud is thinned.
        var requiredIndices: [Int] = []
        for descriptor in [
            (axis: 1, maximum: true),
            (axis: 1, maximum: false),
            (axis: 0, maximum: true),
            (axis: 0, maximum: false),
            (axis: 2, maximum: true),
            (axis: 2, maximum: false)
        ] {
            let index = extremeIndex(axis: descriptor.axis, maximum: descriptor.maximum)
            if !requiredIndices.contains(index) {
                requiredIndices.append(index)
            }
        }
        if requiredIndices.count >= limit {
            return requiredIndices.prefix(limit).map { points[$0] }
        }

        let required = Set(requiredIndices)
        let candidates = points.indices.filter { !required.contains($0) }
        let additional = subset(
            candidates,
            limit: limit - required.count,
            hash: { hash(points[$0]) }
        )
        let selected = required.union(additional)
        return points.indices.compactMap { selected.contains($0) ? points[$0] : nil }
    }

    /// Remainder first, full hash as tie-break. Without it two dots near the cut-off could swap
    /// between updates because sort isn't stable.
    static func rank(_ left: UInt64, precedes right: UInt64) -> Bool {
        let leftRemainder = left % scale
        let rightRemainder = right % scale
        return leftRemainder == rightRemainder
            ? left < right
            : leftRemainder < rightRemainder
    }
}
