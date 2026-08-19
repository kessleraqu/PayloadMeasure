import XCTest
@testable import PayloadMeasure

// When a freshly segmented live mask replaces the one on screen, and when it is left alone.
//
// The policy is to show the most complete recent silhouette of whatever is at the aim point. Vision does
// not segment a complex object the same way twice — one frame it is one instance, the next it is the body
// and the handle separately — so a good half of new masks are a *fragment* of what is already drawn.
// Taking them is what made the preview pulse between the whole object and a piece of it. Nothing is lost
// by holding: the mask is positioned and sized through the world every frame, so a slightly old silhouette
// is still drawn in the right place at the right size. It is the same trade a *selected* object already
// makes — one tracked instance, held while the phone moves — and that case is rock steady.

final class ObjectMaskPreviewHoldTests: XCTestCase {
    private let onScreen = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)

    func testAFragmentOfWhatIsOnScreenDoesNotReplaceIt() {
        // Vision split the object: this is its lower half, centred inside what is already drawn.
        XCTAssertTrue(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: CGRect(x: 0.42, y: 0.50, width: 0.16, height: 0.09),
                secondsHeld: 0.3
            )
        )
    }

    func testSilhouetteNoiseInEitherDirectionIsStillTheSameView() {
        XCTAssertTrue(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: CGRect(x: 0.4025, y: 0.4025, width: 0.195, height: 0.195),
                secondsHeld: 0.1
            )
        )
        XCTAssertTrue(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: CGRect(x: 0.3975, y: 0.3975, width: 0.205, height: 0.205),
                secondsHeld: 0.1
            )
        )
    }

    /// More of the object has been found: that is a better silhouette and worth showing at once.
    func testAMateriallyLargerMaskReplacesIt() {
        XCTAssertFalse(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: CGRect(x: 0.36, y: 0.36, width: 0.28, height: 0.28),
                secondsHeld: 0.3
            )
        )
    }

    /// The aim has moved to another object: take the new mask even though it is smaller.
    func testAMaskCentredElsewhereReplacesIt() {
        XCTAssertFalse(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: CGRect(x: 0.72, y: 0.70, width: 0.10, height: 0.10),
                secondsHeld: 0.3
            )
        )
    }

    /// However steady the scene, the picture is refreshed regularly: holding for ever would leave a
    /// silhouette that no longer describes the object.
    func testTheHoldExpires() {
        XCTAssertTrue(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: onScreen,
                secondsHeld: ObjectMaskPreviewHold.maximumHoldSeconds - 0.01
            )
        )
        XCTAssertFalse(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: onScreen,
                secondsHeld: ObjectMaskPreviewHold.maximumHoldSeconds
            )
        )
    }

    /// First mask of a scan, or one arriving after the mask was cleared: nothing to hold on to.
    func testNothingIsHeldWhenThereIsNoMaskOnScreenYet() {
        XCTAssertFalse(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: nil,
                incoming: onScreen,
                secondsHeld: 0
            )
        )
        XCTAssertFalse(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: nil,
                secondsHeld: 0
            )
        )
    }

    // MARK: - What actually ends a hold

    /// Elapsed time is a poor proxy for staleness, and it was the only test there used to be. The picture
    /// is drawn by the best similarity through three of the object's points; the residual of that fit is
    /// how much of the motion it is failing to draw, and it is measured, not guessed. Past the limit the
    /// silhouette is no longer a fair drawing of the object whatever else argues for keeping it.
    func testAPictureThatCanNoLongerBeDrawnFairlyIsReplaced() {
        XCTAssertFalse(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: onScreen,
                secondsHeld: 0.05,
                displayResidual: ObjectMaskPreviewHold.maximumDisplayResidual + 0.001
            ),
            "A fifth of the time budget is no defence once the drawing has gone wrong."
        )
        XCTAssertTrue(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: onScreen,
                secondsHeld: 0.05,
                displayResidual: ObjectMaskPreviewHold.maximumDisplayResidual - 0.001
            )
        )
    }

    /// The other half of the same argument: a phone that has barely moved keeps its picture for the full
    /// budget, which is what stops the shimmer the hold exists for.
    func testAStillPhoneKeepsItsPictureForTheWholeBudget() {
        XCTAssertTrue(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: onScreen,
                secondsHeld: ObjectMaskPreviewHold.maximumHoldSeconds - 0.01,
                displayResidual: 0
            )
        )
    }

    /// No gauge, no measurement: the time backstop is then the only rule there is, and it still applies.
    func testWithoutAResidualTheTimeBackstopStillEndsTheHold() {
        XCTAssertTrue(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: onScreen,
                secondsHeld: 0.3,
                displayResidual: nil
            )
        )
        XCTAssertFalse(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: onScreen,
                secondsHeld: ObjectMaskPreviewHold.maximumHoldSeconds,
                displayResidual: nil
            )
        )
    }

    func testANonsenseResidualIsNotEvidenceTheDrawingIsFine() {
        XCTAssertFalse(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: onScreen,
                secondsHeld: 0.1,
                displayResidual: .nan
            )
        )
    }

    /// A hold age computed against the sentinel start value is enormous; it must read as "no hold".
    func testAnAbsurdHoldAgeIsNotAHold() {
        XCTAssertFalse(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: onScreen,
                secondsHeld: .greatestFiniteMagnitude
            )
        )
        XCTAssertFalse(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: onScreen,
                secondsHeld: .nan
            )
        )
    }
}
