import XCTest
import simd
@testable import PayloadMeasure

// The orientation search reservoir-samples the stable points with a fixed seed, so the result
// depends on their order. Removing points must keep the survivors in their original order;
// a swap-remove made the fitted box rotate between frames.
final class PointAccumulatorOrderingTests: XCTestCase {
    private func point(_ index: Int) -> SIMD3<Float> {
        // Spaced well beyond voxelSize so each lands in its own voxel.
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

        // Remove from the middle, where a swap-remove would move the last element into the gap.
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

        // Batch removal, as done by silhouette carving.
        accumulator.removeVoxels(containing: [2, 5, 9, 10, 17].map(point))

        let after = order(of: accumulator.stablePointsSnapshot())
        let removed: Set<Float> = Set([2, 5, 9, 10, 17].map { Float($0) * 0.05 })
        let expected = before.filter { !removed.contains($0) }
        XCTAssertEqual(after, expected)
    }

    func testRemovingTheLastPointStillPreservesOrderOfTheRest() {
        // Removing the last element; included so the general case can't regress unnoticed.
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

    /// The same snapshot must reservoir-sample the same way twice.
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

// Rebasing the accumulated points into a corrected world frame after ARKit adjusts an anchor,
// instead of throwing them away.
final class PointAccumulatorRebasingTests: XCTestCase {
    private func point(_ index: Int) -> SIMD3<Float> {
        SIMD3<Float>(Float(index) * 0.05, 0, 0)
    }

    private func makeAccumulator(
        count: Int,
        observations: Int = 1
    ) -> PointAccumulator {
        var accumulator = PointAccumulator(voxelSize: 0.005, maxVoxels: 10_000)
        for _ in 0 ..< max(observations, 1) {
            for index in 0 ..< count {
                accumulator.add([point(index)], stabilizationObservations: 1)
            }
        }
        return accumulator
    }

    private func translation(_ offset: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4<Float>(offset, 1)
        return matrix
    }

    func testEveryPointMovesByTheCorrectionAndNoneIsLost() {
        let accumulator = makeAccumulator(count: 40)
        let offset = SIMD3<Float>(0.013, -0.004, 0.007)
        let rebased = accumulator.transformed(by: translation(offset))

        let before = accumulator.stablePointsSnapshot()
        let after = rebased.stablePointsSnapshot()
        XCTAssertEqual(after.count, before.count, "A rebase is not a filter.")
        for (original, moved) in zip(before, after) {
            XCTAssertEqual(
                simd_distance(moved.position, original.position + offset),
                0,
                accuracy: 1e-5
            )
        }
    }

    /// Rebasing keeps the stable point order (see `PointAccumulatorOrderingTests`).
    func testRebasingPreservesTheOrderOfTheStablePoints() {
        let accumulator = makeAccumulator(count: 60)
        let rebased = accumulator.transformed(
            by: translation(SIMD3<Float>(0.02, 0.01, -0.01))
        )
        let before = accumulator.stablePointsSnapshot().map(\.position.x)
        let after = rebased.stablePointsSnapshot().map(\.position.x)
        XCTAssertEqual(
            after.map { ($0 - 0.02).rounded(toPlaces: 4) },
            before.map { $0.rounded(toPlaces: 4) }
        )
    }

    /// Points keep their observation counts, so the next fit doesn't have to wait for
    /// `minObservations` again.
    func testObservationCountsAndStableStatusSurvive() {
        let accumulator = makeAccumulator(count: 20, observations: 4)
        XCTAssertEqual(accumulator.stablePointCount, 20, "Fixture check.")
        let rebased = accumulator.transformed(
            by: translation(SIMD3<Float>(0.006, 0, 0))
        )
        XCTAssertEqual(rebased.stablePointCount, 20)
        XCTAssertEqual(
            rebased.points(minObservations: 4).count,
            accumulator.points(minObservations: 4).count,
            "Four observations before the correction are still four after it."
        )
    }

    func testARotationCarriesThePointsRoundWithIt() {
        var accumulator = PointAccumulator(voxelSize: 0.005, maxVoxels: 10_000)
        accumulator.add([SIMD3<Float>(0.1, 0, 0)], stabilizationObservations: 1)
        var rotation = matrix_identity_float4x4
        // A quarter turn about +y takes +x to -z.
        rotation.columns.0 = SIMD4<Float>(0, 0, -1, 0)
        rotation.columns.2 = SIMD4<Float>(1, 0, 0, 0)

        let moved = accumulator.transformed(by: rotation).stablePointsSnapshot()
        XCTAssertEqual(moved.count, 1)
        XCTAssertEqual(
            simd_distance(moved[0].position, SIMD3<Float>(0, 0, -0.1)),
            0,
            accuracy: 1e-5
        )
    }

    /// Voxels that land in the same cell after the transform are merged, not dropped.
    func testVoxelsThatCollideAfterTheCorrectionAreMergedNotDropped() {
        var accumulator = PointAccumulator(voxelSize: 0.01, maxVoxels: 10_000)
        // Two points in adjacent voxels, each seen twice.
        for _ in 0 ..< 2 {
            accumulator.add(
                [SIMD3<Float>(0.001, 0, 0), SIMD3<Float>(0.011, 0, 0)],
                stabilizationObservations: 1
            )
        }
        XCTAssertEqual(accumulator.stablePointCount, 2, "Fixture check: two distinct voxels.")

        // Squash the axis so both land in the same voxel.
        var squash = matrix_identity_float4x4
        squash.columns.0 = SIMD4<Float>(0.01, 0, 0, 0)
        let rebased = accumulator.transformed(by: squash)

        XCTAssertEqual(rebased.stablePointCount, 1, "They occupy one voxel now.")
        XCTAssertEqual(
            rebased.points(minObservations: 4).count,
            1,
            "Both voxels' observations are carried into the survivor, not discarded with it."
        )
    }

    func testAnIdentityCorrectionChangesNothing() {
        let accumulator = makeAccumulator(count: 25, observations: 3)
        let rebased = accumulator.transformed(by: matrix_identity_float4x4)
        XCTAssertEqual(
            rebased.stablePointsSnapshot().map(\.position),
            accumulator.stablePointsSnapshot().map(\.position)
        )
    }
}

private extension Float {
    func rounded(toPlaces places: Int) -> Float {
        let scale = powf(10, Float(places))
        return (self * scale).rounded() / scale
    }
}
