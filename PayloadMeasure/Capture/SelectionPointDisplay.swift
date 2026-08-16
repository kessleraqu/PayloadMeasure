import Foundation
import simd

// Choosing which of the measured surface points to draw.
//
// In:  the accumulated points for one object, and how many dots may be drawn.
// Out: the subset to draw.
//
// The cloud grows all through a measurement, as more surface becomes stable. Picking every k-th
// element of it — which is what this used to do — changes k whenever the count changes, and so
// changes the entire drawn subset several times a second. The points were never random and the cloud
// underneath was not moving, but the display churned as if both were.
//
// Selection is by a hash of the point's own voxel instead. Membership then depends only on the point
// and the current budget, and because the budget's share can only shrink as the cloud grows, a dot
// that drops out cannot come back. The display thins as the cloud fills in, rather than reshuffling.
// The voxel, not the raw coordinate, is hashed so that depth jitter on the same bit of surface cannot
// make a dot flicker.

nonisolated enum SelectionPointDisplay {
    /// Fixed point of comparison for the hash split. Any power of two does; this one keeps the
    /// arithmetic well inside UInt64.
    static let scale: UInt64 = 1 << 16

    static func hash(x: Int32, y: Int32, z: Int32) -> UInt64 {
        let prime: UInt64 = 1_099_511_628_211
        var value: UInt64 = 14_695_981_039_346_656_037
        for component in [x, y, z] {
            value = (value ^ UInt64(UInt32(bitPattern: component))) &* prime
        }
        return finalised(value)
    }

    /// Avalanche step, and the reason the dots came out in stripes.
    ///
    /// FNV ends on a multiply, and the low bits of a product depend only on the low bits of its
    /// operands — bit 0 of the hash is bit 0 of the input, and so on up. Voxel keys march by one along
    /// each axis, so `hash % 2^16` marched with them: whether a point was drawn became a periodic
    /// function of its position, which is a set of stripes across the surface rather than a scatter.
    ///
    /// This is splitmix64's finaliser: two shift-xors around a multiply, which spreads every input bit
    /// across the whole word so the low bits are as good as any other.
    private static func finalised(_ value: UInt64) -> UInt64 {
        var mixed = value
        mixed ^= mixed >> 33
        mixed = mixed &* 0xFF51_AFD7_ED55_8CCD
        mixed ^= mixed >> 33
        mixed = mixed &* 0xC4CE_B9FE_1A85_EC53
        mixed ^= mixed >> 33
        return mixed
    }

    /// Up to `limit` items: the ones ranking lowest by hash, rather than the ones in the right places
    /// in the array.
    ///
    /// One ordering throughout, deliberately. Filtering on `hash % scale` and then trimming on the
    /// full hash — which is what this did first — are two different orders, so which item got trimmed
    /// depended on what else happened to be in the array, and a dropped dot could come back. The rank
    /// below is a total order fixed per item: the remainder decides, and the full hash only breaks
    /// ties, so no two items compare equal and array order never enters into it.
    static func subset<Item>(
        _ items: [Item],
        limit: Int,
        hash: (Item) -> UInt64
    ) -> [Item] {
        guard limit > 0 else { return [] }
        guard items.count > limit else { return items }

        // Cheap first pass: throw away most of what cannot make the budget, in one O(n) sweep. The
        // threshold can only fall as the cloud grows, so this pass alone can never re-admit anything.
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

    /// Remainder first, then the whole hash to settle ties. Two different items can share a remainder
    /// once there are thousands of them, and `sort` is not stable, so without the tie-break a pair of
    /// dots either side of the cut-off could swap places from one update to the next.
    static func rank(_ left: UInt64, precedes right: UInt64) -> Bool {
        let leftRemainder = left % scale
        let rightRemainder = right % scale
        return leftRemainder == rightRemainder
            ? left < right
            : leftRemainder < rightRemainder
    }
}
