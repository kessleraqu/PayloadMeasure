import SwiftUI
import XCTest
@testable import PayloadMeasure

// Placing a mask picture taken a moment ago onto the camera image now.
//
// The mask is followed through the world — its own point in the room, reprojected each frame, with the
// apparent size taken from how far away that point is. Vision's object tracker cannot do this job: it has
// a minimum target size in frame, and a small object at the 40–50 cm the accuracy rule asks for is under
// it. Believing that tracker's box is what made small objects' masks lag behind and pulse between two
// sizes, so it is now a position-only fallback.

final class MaskDisplayTransformTests: XCTestCase {
    private let referencePoint = CGPoint(x: 0.5, y: 0.5)

    // MARK: - Following a point through the world

    func testAMaskOnAStillObjectIsDrawnUntouched() {
        let transform = try! XCTUnwrap(
            MaskDisplayTransform.following(
                referencePoint: referencePoint,
                referenceDistanceMetres: 0.45,
                currentPoint: referencePoint,
                currentDistanceMetres: 0.45
            )
        )
        XCTAssertEqual(transform.scale.width, 1, accuracy: 1e-9)
        XCTAssertEqual(transform.translation.x, 0, accuracy: 1e-9)
        XCTAssertEqual(transform.translation.y, 0, accuracy: 1e-9)
    }

    /// Backing away doubles the distance, so the object is half the size on screen and so is its mask —
    /// scaled about the tracked point, which is where the object actually is.
    func testMovingAwayHalvesTheMaskAboutTheTrackedPoint() {
        let transform = try! XCTUnwrap(
            MaskDisplayTransform.following(
                referencePoint: referencePoint,
                referenceDistanceMetres: 0.40,
                currentPoint: CGPoint(x: 0.55, y: 0.48),
                currentDistanceMetres: 0.80
            )
        )
        XCTAssertEqual(transform.scale.width, 0.5, accuracy: 1e-6)
        XCTAssertEqual(transform.scale.height, 0.5, accuracy: 1e-6)
        XCTAssertEqual(transform.anchor.x, referencePoint.x, accuracy: 1e-9)
        XCTAssertEqual(transform.anchor.y, referencePoint.y, accuracy: 1e-9)
        XCTAssertEqual(transform.translation.x, 0.05, accuracy: 1e-9)
        XCTAssertEqual(transform.translation.y, -0.02, accuracy: 1e-9)
    }

    func testMovingCloserEnlargesTheMask() {
        let transform = try! XCTUnwrap(
            MaskDisplayTransform.following(
                referencePoint: referencePoint,
                referenceDistanceMetres: 0.60,
                currentPoint: referencePoint,
                currentDistanceMetres: 0.40
            )
        )
        XCTAssertEqual(transform.scale.width, 1.5, accuracy: 1e-6)
    }

    /// Position still works when there is no depth to compare: the mask follows, at the size it was.
    func testPositionIsStillFollowedWithoutDistances() {
        let transform = try! XCTUnwrap(
            MaskDisplayTransform.following(
                referencePoint: referencePoint,
                referenceDistanceMetres: nil,
                currentPoint: CGPoint(x: 0.6, y: 0.5),
                currentDistanceMetres: nil
            )
        )
        XCTAssertEqual(transform.scale.width, 1, accuracy: 1e-9)
        XCTAssertEqual(transform.translation.x, 0.1, accuracy: 1e-9)
    }

    func testOneBadDepthReadingCannotDistortTheMaskWithoutLimit() {
        let vanishing = try! XCTUnwrap(
            MaskDisplayTransform.following(
                referencePoint: referencePoint,
                referenceDistanceMetres: 0.45,
                currentPoint: referencePoint,
                currentDistanceMetres: 40
            )
        )
        XCTAssertEqual(
            vanishing.scale.width,
            MaskDisplayTransform.scaleLimit.lowerBound,
            accuracy: 1e-9
        )

        let swallowing = try! XCTUnwrap(
            MaskDisplayTransform.following(
                referencePoint: referencePoint,
                referenceDistanceMetres: 4,
                currentPoint: referencePoint,
                currentDistanceMetres: 0.30
            )
        )
        XCTAssertEqual(
            swallowing.scale.width,
            MaskDisplayTransform.scaleLimit.upperBound,
            accuracy: 1e-9
        )

        // Depth of zero is not a reading. It must not divide anything.
        let noDepth = try! XCTUnwrap(
            MaskDisplayTransform.following(
                referencePoint: referencePoint,
                referenceDistanceMetres: 0.45,
                currentPoint: referencePoint,
                currentDistanceMetres: 0
            )
        )
        XCTAssertEqual(noDepth.scale.width, 1, accuracy: 1e-9)
    }

    func testNothingIsFollowedWithoutAPointOnBothSides() {
        XCTAssertNil(
            MaskDisplayTransform.following(
                referencePoint: nil,
                referenceDistanceMetres: 0.45,
                currentPoint: referencePoint,
                currentDistanceMetres: 0.45
            )
        )
        XCTAssertNil(
            MaskDisplayTransform.following(
                referencePoint: referencePoint,
                referenceDistanceMetres: 0.45,
                currentPoint: nil,
                currentDistanceMetres: 0.45
            )
        )
        XCTAssertNil(
            MaskDisplayTransform.following(
                referencePoint: referencePoint,
                referenceDistanceMetres: 0.45,
                currentPoint: CGPoint(x: .nan, y: 0.5),
                currentDistanceMetres: 0.45
            )
        )
    }

    // MARK: - The fallback

    /// The tracker box moves the mask and never resizes it. Its size is the thing Vision gets wrong as a
    /// target gets small, and scaling by it is what produced the appear-shrink-reappear pulse.
    func testTheTrackerBoxFallbackMovesButNeverResizes() {
        let transform = try! XCTUnwrap(
            MaskDisplayTransform.sliding(
                reference: CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20),
                current: CGRect(x: 0.50, y: 0.36, width: 0.10, height: 0.10)
            )
        )
        XCTAssertEqual(transform.scale.width, 1, accuracy: 1e-9)
        XCTAssertEqual(transform.scale.height, 1, accuracy: 1e-9)
        XCTAssertEqual(transform.translation.x, 0.05, accuracy: 1e-9)
        XCTAssertEqual(transform.translation.y, -0.09, accuracy: 1e-9)
    }

    func testNoFallbackWithoutTwoUsableBoxes() {
        let box = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)
        XCTAssertNil(MaskDisplayTransform.sliding(reference: nil, current: box))
        XCTAssertNil(
            MaskDisplayTransform.sliding(
                reference: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.2),
                current: box
            ),
            "A box thinner than the minimum is noise, not information."
        )
    }

    // MARK: - Which masks the tracker is asked about

    func testOnlyMasksBigEnoughToTrackAreGivenToTheTracker() {
        let side = MaskTrackerEligibility.minimumTrackableSide
        XCTAssertTrue(
            MaskTrackerEligibility.isTrackable(
                boundingBox: CGRect(x: 0.4, y: 0.4, width: side, height: side)
            )
        )
        // The small object in the study, at the distance the accuracy rule asks for.
        XCTAssertFalse(
            MaskTrackerEligibility.isTrackable(
                boundingBox: CGRect(x: 0.47, y: 0.47, width: 0.06, height: side - 0.01)
            )
        )
        XCTAssertFalse(MaskTrackerEligibility.isTrackable(boundingBox: nil))
        XCTAssertFalse(
            MaskTrackerEligibility.isTrackable(
                boundingBox: CGRect(x: 0, y: 0, width: .nan, height: 0.5)
            )
        )
    }
}
