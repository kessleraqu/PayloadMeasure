import XCTest
import simd
@testable import PayloadMeasure

// ObjectMaskSilhouette is the negative evidence a frame carries: which directions the object is *not*
// in, in a form a world point can be tested against by exact projection. It exists because points are
// only ever added to an accumulator, so a frame on which the mask jumped to the wrong segment leaves
// foreign points behind permanently — and the box, being the literal extent of the points, grows to
// contain them.
final class ObjectMaskSilhouetteTests: XCTestCase {
    private let width = 64
    private let height = 48
    private let focal: Float = 60

    /// Camera at the origin looking down −z, the convention `maskedWorldSurface` unprojects with.
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

    /// A world point straight ahead must land on the principal point, and its depth must come back as
    /// the distance along the view axis. If this is wrong every carve decision is wrong.
    func testAPointStraightAheadProjectsToThePrincipalPoint() throws {
        let target = silhouette(objectRect: nil, depthEverywhere: 0)
        let hit = try XCTUnwrap(target.pixel(for: SIMD3<Float>(0, 0, -0.5)))
        XCTAssertEqual(hit.column, width / 2)
        XCTAssertEqual(hit.row, height / 2)
        XCTAssertEqual(hit.depth, 0.5, accuracy: 1e-5)
    }

    func testOffAxisPointsProjectToTheExpectedSideOfTheImage() throws {
        let target = silhouette(objectRect: nil, depthEverywhere: 0)
        // +x in camera space is to the right; +y is up, which is a *smaller* row index.
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

    /// The projection has to follow the camera pose, not assume the origin — a silhouette is only ever
    /// used together with the pose of the frame it came from.
    func testProjectionRespectsTheCameraPose() throws {
        var translated = matrix_identity_float4x4
        translated.columns.3 = SIMD4<Float>(1, 0, 0, 1)
        let target = silhouette(
            objectRect: nil, depthEverywhere: 0, cameraTransform: translated
        )
        // The camera has moved +1 in x, so the world point at x = 1 is now straight ahead.
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

    /// The decisive property: a point exactly on the mask boundary must NOT be carveable, because a
    /// segmentation edge wobbles by a pixel between frames and would otherwise erase real surface.
    func testAPixelOnTheBoundaryIsNotClearlyOutside() {
        let target = silhouette(
            objectRect: (20 ..< 40, 15 ..< 30), depthEverywhere: 0.5
        )
        // Immediately outside the object on the left edge: its +x neighbour is object, so it is on the
        // boundary and must be spared.
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

    /// An empty mask must still be usable: every pixel is outside. (Whether a frame with no object at
    /// all should be trusted is the caller's decision, made by requiring repeated disagreement.)
    func testAnEmptySilhouetteReportsEverythingOutside() {
        let target = silhouette(objectRect: nil, depthEverywhere: 0.5)
        XCTAssertTrue(target.isClearlyOutside(column: 0, row: 0))
        XCTAssertTrue(target.isClearlyOutside(column: width - 1, row: height - 1))
    }
}
