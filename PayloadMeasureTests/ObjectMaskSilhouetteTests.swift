import XCTest
import simd
@testable import PayloadMeasure

// ObjectMaskSilhouette tests: projecting world points into a frame's mask, and the carving
// predicate that removes points outside it.
final class ObjectMaskSilhouetteTests: XCTestCase {
    private let width = 64
    private let height = 48
    private let focal: Float = 60

    /// Camera at the origin looking down -z, as in `maskedWorldSurface`.
    private func silhouette(
        objectRect: (xRange: Range<Int>, yRange: Range<Int>)?,
        depthEverywhere: Float,
        cameraTransform: simd_float4x4 = matrix_identity_float4x4
    ) -> ObjectMaskSilhouette {
        var isObject = [Bool](repeating: false, count: width * height)
        if let objectRect {
            for y in objectRect.yRange {
                for x in objectRect.xRange {
                    isObject[y * width + x] = true
                }
            }
        }
        return ObjectMaskSilhouette(
            width: width,
            height: height,
            isObject: isObject,
            depths: [Float](repeating: depthEverywhere, count: width * height),
            cameraTransform: cameraTransform,
            focalX: focal,
            focalY: focal,
            principalX: Float(width) / 2,
            principalY: Float(height) / 2
        )
    }

    /// A point straight ahead lands on the principal point, with depth along the view axis.
    func testAPointStraightAheadProjectsToThePrincipalPoint() throws {
        let target = silhouette(objectRect: nil, depthEverywhere: 0)
        let hit = try XCTUnwrap(target.pixel(for: SIMD3<Float>(0, 0, -0.5)))
        XCTAssertEqual(hit.column, width / 2)
        XCTAssertEqual(hit.row, height / 2)
        XCTAssertEqual(hit.depth, 0.5, accuracy: 1e-5)
    }

    func testOffAxisPointsProjectToTheExpectedSideOfTheImage() throws {
        let target = silhouette(objectRect: nil, depthEverywhere: 0)
        // +x is right; +y is up, which is a smaller row index.
        let right = try XCTUnwrap(target.pixel(for: SIMD3<Float>(0.1, 0, -0.5)))
        let up = try XCTUnwrap(target.pixel(for: SIMD3<Float>(0, 0.1, -0.5)))
        XCTAssertGreaterThan(right.column, width / 2)
        XCTAssertEqual(right.row, height / 2)
        XCTAssertLessThan(up.row, height / 2)
        XCTAssertEqual(up.column, width / 2)
    }

    func testAPointBehindTheCameraOrOutsideTheFrameHasNoPixel() {
        let target = silhouette(objectRect: nil, depthEverywhere: 0)
        XCTAssertNil(target.pixel(for: SIMD3<Float>(0, 0, 0.5)), "Behind the camera.")
        XCTAssertNil(target.pixel(for: SIMD3<Float>(0, 0, 0)), "On the camera plane.")
        XCTAssertNil(target.pixel(for: SIMD3<Float>(10, 0, -0.5)), "Far off to the side.")
    }

    /// The projection must use the camera pose, not assume the origin.
    func testProjectionRespectsTheCameraPose() throws {
        var translated = matrix_identity_float4x4
        translated.columns.3 = SIMD4<Float>(1, 0, 0, 1)
        let target = silhouette(
            objectRect: nil, depthEverywhere: 0, cameraTransform: translated
        )
        // The camera moved +1 in x, so x = 1 is now straight ahead.
        let hit = try XCTUnwrap(target.pixel(for: SIMD3<Float>(1, 0, -0.5)))
        XCTAssertEqual(hit.column, width / 2)
        XCTAssertEqual(hit.row, height / 2)
    }

    // MARK: - The carve predicate

    func testAPixelInsideTheObjectIsNotOutside() {
        let target = silhouette(
            objectRect: (20 ..< 40, 15 ..< 30), depthEverywhere: 0.5
        )
        XCTAssertFalse(target.isClearlyOutside(column: 30, row: 22))
    }

    /// A point on the mask boundary must not be carvable, since edges wobble by a pixel between frames.
    func testAPixelOnTheBoundaryIsNotClearlyOutside() {
        let target = silhouette(
            objectRect: (20 ..< 40, 15 ..< 30), depthEverywhere: 0.5
        )
        // Just outside the left edge: its +x neighbour is inside, so it's on the boundary and kept.
        XCTAssertTrue(target.isObject[22 * width + 20], "Fixture check: 20 is inside.")
        XCTAssertFalse(target.isObject[22 * width + 19], "Fixture check: 19 is outside.")
        XCTAssertFalse(
            target.isClearlyOutside(column: 19, row: 22),
            "A pixel touching the object must not be carveable."
        )
    }

    func testAPixelWellAwayFromTheObjectIsClearlyOutside() {
        let target = silhouette(
            objectRect: (20 ..< 40, 15 ..< 30), depthEverywhere: 0.5
        )
        XCTAssertTrue(target.isClearlyOutside(column: 5, row: 5))
        XCTAssertTrue(
            target.isClearlyOutside(column: 17, row: 22),
            "Two pixels clear of the edge is outside the dilated silhouette."
        )
    }

    /// An empty mask still works: every pixel is outside.
    func testAnEmptySilhouetteReportsEverythingOutside() {
        let target = silhouette(objectRect: nil, depthEverywhere: 0.5)
        XCTAssertTrue(target.isClearlyOutside(column: 0, row: 0))
        XCTAssertTrue(target.isClearlyOutside(column: width - 1, row: height - 1))
    }
}
