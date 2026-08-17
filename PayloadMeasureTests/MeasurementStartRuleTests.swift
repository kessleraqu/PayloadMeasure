import XCTest
@testable import PayloadMeasure

// The first seconds after an object is selected: when the app gives up on a measurement that never
// started, and when the operator is allowed to give up on one by hand.

final class MeasurementStartRuleTests: XCTestCase {
    func testTheThresholdsAreThreeAndFourSeconds() {
        XCTAssertEqual(MeasurementStartRule.startGraceSeconds, 3, accuracy: 1e-9)
        XCTAssertEqual(MeasurementStartRule.cancelLockoutSeconds, 4, accuracy: 1e-9)
        XCTAssertLessThan(
            MeasurementStartRule.startGraceSeconds,
            MeasurementStartRule.cancelLockoutSeconds,
            "A measurement that is not starting must be restarted before Cancel is even offered."
        )
    }

    func testAMeasurementThatProducedNothingIsAbandonedAfterThreeSeconds() {
        XCTAssertFalse(
            MeasurementStartRule.abandonsMeasurement(
                secondsActive: 2.9,
                hasMeasurement: false
            )
        )
        XCTAssertTrue(
            MeasurementStartRule.abandonsMeasurement(
                secondsActive: 3.0,
                hasMeasurement: false
            )
        )
    }

    /// Once there is a measurement, however rough, the scan is under way and the stopping rule owns it.
    func testAMeasurementThatStartedIsNeverAbandonedByThisRule() {
        XCTAssertFalse(
            MeasurementStartRule.abandonsMeasurement(
                secondsActive: 30,
                hasMeasurement: true
            )
        )
    }

    func testCancelIsWithheldForFourSecondsAndThenOffered() {
        XCTAssertFalse(MeasurementStartRule.allowsCancel(secondsActive: 0))
        XCTAssertFalse(MeasurementStartRule.allowsCancel(secondsActive: 3.9))
        XCTAssertTrue(MeasurementStartRule.allowsCancel(secondsActive: 4))
        XCTAssertTrue(MeasurementStartRule.allowsCancel(secondsActive: 12))
    }

    /// The button says how long is left, and it never says "0 s" while still refusing to work.
    func testTheCountdownCountsWholeSecondsAndDisappearsWhenCancelIsAllowed() {
        XCTAssertEqual(MeasurementStartRule.cancelCountdown(secondsActive: 0), 4)
        XCTAssertEqual(MeasurementStartRule.cancelCountdown(secondsActive: 1.2), 3)
        XCTAssertEqual(MeasurementStartRule.cancelCountdown(secondsActive: 3.95), 1)
        XCTAssertNil(MeasurementStartRule.cancelCountdown(secondsActive: 4))
    }

    /// A clock that has gone backwards, or a value that is not a number at all, must not reach an Int
    /// conversion: that traps, and trapping in the middle of a measurement is a crash.
    func testAbsurdElapsedTimesAreSurvivedRatherThanConverted() {
        XCTAssertNil(MeasurementStartRule.cancelCountdown(secondsActive: .nan))
        XCTAssertNil(MeasurementStartRule.cancelCountdown(secondsActive: .infinity))
        XCTAssertEqual(MeasurementStartRule.cancelCountdown(secondsActive: -1e30), 4)
        XCTAssertFalse(
            MeasurementStartRule.abandonsMeasurement(
                secondsActive: .nan,
                hasMeasurement: false
            )
        )
    }
}
