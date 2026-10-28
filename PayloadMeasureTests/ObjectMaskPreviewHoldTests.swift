import XCTest
@testable import PayloadMeasure

// When a new live mask replaces the one on screen. Vision often returns only part of an object, so
// smaller or similar masks are held; the held mask is still positioned through the world each frame.

final class ObjectMaskPreviewHoldTests: XCTestCase {
    private let onScreen = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)

    func testAFragmentOfWhatIsOnScreenDoesNotReplaceIt() {
        // Vision split the object: this is the lower half, inside what's already drawn.
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

    /// A materially larger mask is a better view and replaces it straight away.
    func testAMateriallyLargerMaskReplacesIt() {
        XCTAssertFalse(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: CGRect(x: 0.36, y: 0.36, width: 0.28, height: 0.28),
                secondsHeld: 0.3
            )
        )
    }

    /// The aim moved to another object, so take the new mask even if it's smaller.
    func testAMaskCentredElsewhereReplacesIt() {
        XCTAssertFalse(
            ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen,
                incoming: CGRect(x: 0.72, y: 0.70, width: 0.10, height: 0.10),
                secondsHeld: 0.3
            )
        )
    }

    /// Even a perfectly still scene refreshes the mask after the time limit.
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

    /// Nothing to hold when no mask is on screen yet.
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

    /// Once the fit residual passes the limit, the held mask is replaced.
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

    /// A phone that has barely moved keeps the mask for the full time limit.
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

    /// Without a gauge the time limit still applies.
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

    /// A hold age computed from the sentinel start value must count as no hold.
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
