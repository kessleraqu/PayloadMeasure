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

    /// The drag offset is clamped and never NaN.
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

    /// The module moves exactly as far as the finger did across the table.
    func testTheModuleMovesExactlyAsFarAsTheFingerDidAcrossTheSurface() {
        let moved = PackingARVisualGeometry.draggedOffset(
            from: SIMD3(0.10, 0, -0.20),
            startingAt: SIMD3(1.00, 0.72, 2.00),
            following: SIMD3(1.18, 0.72, 1.85)
        )
        XCTAssertEqual(moved.x, 0.28, accuracy: 0.000_001)
        XCTAssertEqual(moved.z, -0.35, accuracy: 0.000_001)
    }

    /// Dragging never changes the height, even if the unprojected points differ slightly vertically.
    func testDraggingNeverLiftsOrSinksTheModule() {
        let moved = PackingARVisualGeometry.draggedOffset(
            from: SIMD3(0, 0, 0),
            startingAt: SIMD3(0, 0.72, 0),
            following: SIMD3(0.05, 0.90, 0)
        )
        XCTAssertEqual(moved.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(moved.x, 0.05, accuracy: 0.000_001)
    }

    func testADragBeyondTheLimitIsClamped() {
        let limit = PackingARVisualGeometry.maximumDragOffsetMetres
        let moved = PackingARVisualGeometry.draggedOffset(
            from: SIMD3(0, 0, 0),
            startingAt: SIMD3(0, 0.72, 0),
            following: SIMD3(50, 0.72, 0)
        )
        XCTAssertEqual(moved.x, limit, accuracy: 0.000_001)
    }
}
