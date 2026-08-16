import XCTest
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
}
