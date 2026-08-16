import XCTest
import simd
@testable import PayloadMeasure

// What the box's height means, so the drawn box can be held to it.
//
// The complaint was that the top of the box floated above the point cloud. The fitter was not the
// cause — it puts the top on the highest reading, as these check. The drawn box had come adrift from
// it: its height was seeded on the first frame and then only refreshed while the view counted as a
// side view, so hovering over an object left the first frame's guess on screen while the cloud settled
// underneath. These tests fix the definition; the drawn box now follows the fit every frame.

final class BoundingBoxHeightTests: XCTestCase {
    private let up = SIMD3<Float>(0, 1, 0)

    /// A slab of points from `base` to `top`, wide enough to fit a rectangle to.
    private func slab(base: Float, top: Float, halfWidth: Float = 0.05) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for xStep in 0...10 {
            for zStep in 0...10 {
                let x = -halfWidth + Float(xStep) / 10 * halfWidth * 2
                let z = -halfWidth + Float(zStep) / 10 * halfWidth * 2
                points.append(SIMD3(x, base, z))
                points.append(SIMD3(x, top, z))
            }
        }
        return points
    }

    private func make(
        _ points: [SIMD3<Float>],
        groundHeight: Float,
        enclosing: [SIMD3<Float>] = []
    ) -> CapturedObject? {
        OrientedBoundingBox.make(
            from: points,
            enclosing: enclosing,
            up: up,
            groundHeight: groundHeight,
            minimumEdgeDistance: 0.005
        )
    }

    func testTheTopSitsOnTheHighestReadingAndTheBottomOnTheSupportPlane() throws {
        let object = try XCTUnwrap(make(slab(base: 0.02, top: 0.14), groundHeight: 0))

        let top = object.center.y + object.dimensions.z / 2
        let bottom = object.center.y - object.dimensions.z / 2
        XCTAssertEqual(top, 0.14, accuracy: 1e-5, "The top must be the highest reading, not above it.")
        XCTAssertEqual(bottom, 0, accuracy: 1e-5, "The box stands on the support plane.")
        XCTAssertEqual(object.heightInMeters, 0.14, accuracy: 1e-5)
    }

    /// Height is measured from the plane, so points below it cannot lift the top.
    func testAnObjectStandingProudOfThePlaneIsStillMeasuredFromThePlane() throws {
        let object = try XCTUnwrap(make(slab(base: 0.05, top: 0.2), groundHeight: 0))
        XCTAssertEqual(object.heightInMeters, 0.2, accuracy: 1e-5)
        XCTAssertEqual(object.center.y - object.dimensions.z / 2, 0, accuracy: 1e-5)
    }

    func testASupportPlaneAboveTheFloorShiftsTheWholeBox() throws {
        let object = try XCTUnwrap(make(slab(base: 0.72, top: 0.8), groundHeight: 0.7))
        XCTAssertEqual(object.heightInMeters, 0.1, accuracy: 1e-5)
        XCTAssertEqual(object.center.y - object.dimensions.z / 2, 0.7, accuracy: 1e-5)
        XCTAssertEqual(object.center.y + object.dimensions.z / 2, 0.8, accuracy: 1e-5)
    }

    /// The enclosure set is the observed readings, which may reach higher than the voxel centres the
    /// rectangle is fitted to. The box has to cover those too, or it would cut through its own points.
    func testTheEnclosureSetCanRaiseTheTopButNothingLowersIt() throws {
        let points = slab(base: 0.02, top: 0.14)
        let higher = try XCTUnwrap(
            make(points, groundHeight: 0, enclosing: [SIMD3(0, 0.16, 0)])
        )
        XCTAssertEqual(higher.center.y + higher.dimensions.z / 2, 0.16, accuracy: 1e-5)

        let lower = try XCTUnwrap(
            make(points, groundHeight: 0, enclosing: [SIMD3(0, 0.05, 0)])
        )
        XCTAssertEqual(
            lower.center.y + lower.dimensions.z / 2,
            0.14,
            accuracy: 1e-5,
            "A lower observed reading must not pull the top down below the fitted points."
        )
    }
}
