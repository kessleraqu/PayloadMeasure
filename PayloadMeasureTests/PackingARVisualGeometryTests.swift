import XCTest
import CoreGraphics
import simd
@testable import PayloadMeasure

final class PackingARVisualGeometryTests: XCTestCase {
    func testPackageFrameAndBothMarkersRemainInsideExactPackageBounds() {
        let size = SIMD3<Float>(0.20, 0.08, 0.12)
        let thickness: Float = 0.004
        let markerDepth: Float = 0.002
        let inset = PackingARVisualGeometry.packageInset(
            for: thickness
        )
        let visibleFrame = PackingARVisualGeometry.insetFrameSize(
            size,
            by: inset
        )

        XCTAssertEqual(inset, 0.00075, accuracy: 0.000_001)
        XCTAssertEqual(
            visibleFrame.x / 2,
            size.x / 2 - inset,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            visibleFrame.y / 2,
            size.y / 2 - inset,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            visibleFrame.z / 2,
            size.z / 2 - inset,
            accuracy: 0.000_001
        )

        for face in [Float(-1), Float(1)] {
            let centre = PackingARVisualGeometry.markerCentre(
                face: face,
                normalExtent: size.z,
                markerDepth: markerDepth,
                inset: inset
            )
            XCTAssertEqual(
                abs(centre) + markerDepth / 2,
                size.z / 2 - inset,
                accuracy: 0.000_001
            )
        }
    }

    func testInsetIsClampedForThinAndThickOutlines() {
        XCTAssertEqual(
            PackingARVisualGeometry.packageInset(for: 0.0001),
            0.00035,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PackingARVisualGeometry.packageInset(for: 0.010),
            0.00075,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PackingARVisualGeometry.faceInset(for: 0.0001),
            0.00070,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            PackingARVisualGeometry.faceInset(for: 0.010),
            0.00225,
            accuracy: 0.000_001
        )
    }

    /// A drag is a nudge across a table. Without a bound, one unlucky gesture put the module somewhere
    /// it could not be seen or recovered from.
    func testDragOffsetIsBoundedAndNeverCarriesANonNumber() {
        let limit = PackingARVisualGeometry.maximumDragOffsetMetres
        let clamped = PackingARVisualGeometry.clampedDragOffset(
            SIMD3(20, -0.5, -40)
        )
        XCTAssertEqual(clamped.x, limit, accuracy: 0.000_001)
        XCTAssertEqual(clamped.y, -0.5, accuracy: 0.000_001)
        XCTAssertEqual(clamped.z, -limit, accuracy: 0.000_001)

        let nonNumbers = PackingARVisualGeometry.clampedDragOffset(
            SIMD3(.nan, .infinity, 0.25)
        )
        XCTAssertEqual(nonNumbers.x, 0, accuracy: 0.000_001)
        XCTAssertEqual(nonNumbers.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(nonNumbers.z, 0.25, accuracy: 0.000_001)
    }

    func testOneFingerDragMovesAtConstantSurfaceHeightWithoutARaycast() {
        let moved = PackingARVisualGeometry.draggedPosition(
            from: SIMD3(1, 0.7, 2),
            screenRight: SIMD2(1, 0),
            screenUp: SIMD2(0, -1),
            screenDelta: CGPoint(x: 80, y: 40),
            cameraDistance: 0.5,
            surfaceHeight: 0.7
        )
        XCTAssertEqual(moved.x, 1.05, accuracy: 0.000_001)
        XCTAssertEqual(moved.y, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(moved.z, 2.025, accuracy: 0.000_001)
    }
}
