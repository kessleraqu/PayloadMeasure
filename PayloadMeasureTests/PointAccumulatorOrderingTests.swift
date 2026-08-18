import XCTest
import simd
@testable import PayloadMeasure

// OrientedBoundingBox.bestOrientation reservoir-samples PointAccumulator.stablePointsSnapshot() with a
// fixed seed, precisely so the same accumulated cloud reproduces the same orientation search: reservoir
// sampling's initial fill is a literal prefix of the array, so which points end up in the sample is a
// function of array *order*, not only array *content*. These tests exist because removal used to plug
// the gap left by a removed point with whichever point currently sat last (a classic swap-remove),
// which reshuffles survivors' relative order on every call — indistinguishable, downstream, from the
// orientation fit itself being unstable, and observed as the fitted box rotating between frames that
// removed nothing but a stray point.
final class PointAccumulatorOrderingTests: XCTestCase {
    private func point(_ index: Int) -> SIMD3<Float> {
        // Spaced well beyond voxelSize so each lands in a distinct voxel.
        SIMD3<Float>(Float(index) * 0.05, 0, 0)
    }

    private func makeAccumulator(count: Int) -> PointAccumulator {
        var accumulator = PointAccumulator(voxelSize: 0.005, maxVoxels: 10_000)
        for index in 0 ..< count {
            accumulator.add([point(index)], stabilizationObservations: 1)
        }
        return accumulator
    }

    private func order(of snapshot: [AccumulatedDepthPoint]) -> [Float] {
        snapshot.map(\.position.x)
    }

    func testRemovingOnePointPreservesTheRelativeOrderOfEveryOtherPoint() {
        var accumulator = makeAccumulator(count: 10)
        let before = order(of: accumulator.stablePointsSnapshot())
        XCTAssertEqual(before, (0 ..< 10).map { Float($0) * 0.05 }, "Fixture check: insertion order.")

        // Remove a point from the middle, not the end — the case a swap-remove handles by moving the
        // last element into the gap, silently reordering everything after it.
        accumulator.removeVoxels(containing: [point(3)])

        let after = order(of: accumulator.stablePointsSnapshot())
        let expected = before.filter { $0 != Float(3) * 0.05 }
        XCTAssertEqual(
            after, expected,
            "Removing one point must not change the relative order of the points that remain."
        )
    }

    func testRemovingSeveralPointsAtOncePreservesRelativeOrder() {
        var accumulator = makeAccumulator(count: 20)
        let before = order(of: accumulator.stablePointsSnapshot())

        // A batch removal, as silhouette carving performs when several voxels cross the disagreement
        // threshold in the same frame — the case most likely to compound a swap-remove's damage, since
        // each individual swap can relocate an element that a later swap in the same batch then moves
        // again.
        accumulator.removeVoxels(containing: [2, 5, 9, 10, 17].map(point))

        let after = order(of: accumulator.stablePointsSnapshot())
        let removed: Set<Float> = Set([2, 5, 9, 10, 17].map { Float($0) * 0.05 })
        let expected = before.filter { !removed.contains($0) }
        XCTAssertEqual(after, expected)
    }

    func testRemovingTheLastPointStillPreservesOrderOfTheRest() {
        // The one case a swap-remove happens to get right by accident (nothing needs to move) — pinned
        // so a future change can't regress the general case while this one keeps passing.
        var accumulator = makeAccumulator(count: 5)
        let before = order(of: accumulator.stablePointsSnapshot())
        accumulator.removeVoxels(containing: [point(4)])
        let after = order(of: accumulator.stablePointsSnapshot())
        XCTAssertEqual(after, Array(before.dropLast()))
    }

    func testANewlyAddedPointAppendsAfterExistingOnesEvenFollowingARemoval() {
        var accumulator = makeAccumulator(count: 5)
        accumulator.removeVoxels(containing: [point(2)])
        accumulator.add([point(100)], stabilizationObservations: 1)

        let after = order(of: accumulator.stablePointsSnapshot())
        XCTAssertEqual(after.last, Float(100) * 0.05, "A new point must append at the end, not fill the gap left by a removal.")
        XCTAssertEqual(after.count, 5, "4 survivors plus the 1 new point.")
    }

    /// States the property this whole file protects in the terms that actually matter: the same array
    /// fed to reservoir sampling twice must reservoir-sample the same way. `OrientedBoundingBox` uses a
    /// fixed seed for exactly this reason; the fix being tested is what makes that seed meaningful for
    /// an accumulator that has had points removed from it.
    func testTwoIdenticallyOrderedSnapshotsSampleIdentically() {
        var first = makeAccumulator(count: 150)
        first.removeVoxels(containing: [point(10), point(50), point(90)])
        let firstPoints = first.stablePointsSnapshot().map(\.position)

        var second = makeAccumulator(count: 150)
        second.removeVoxels(containing: [point(10), point(50), point(90)])
        let secondPoints = second.stablePointsSnapshot().map(\.position)

        XCTAssertEqual(
            firstPoints, secondPoints,
            "The same sequence of adds and removals must produce the same snapshot order."
        )
    }
}
