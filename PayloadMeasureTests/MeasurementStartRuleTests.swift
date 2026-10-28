import XCTest
@testable import PayloadMeasure

// When the app abandons a measurement that never starts, and when manual cancel becomes available.

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

    /// Once there's any measurement, the stopping rule takes over.
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

    /// The countdown never shows "0 s" while Cancel is still unavailable.
    func testTheCountdownCountsWholeSecondsAndDisappearsWhenCancelIsAllowed() {
        XCTAssertEqual(MeasurementStartRule.cancelCountdown(secondsActive: 0), 4)
        XCTAssertEqual(MeasurementStartRule.cancelCountdown(secondsActive: 1.2), 3)
        XCTAssertEqual(MeasurementStartRule.cancelCountdown(secondsActive: 3.95), 1)
        XCTAssertNil(MeasurementStartRule.cancelCountdown(secondsActive: 4))
    }

    /// Negative or NaN elapsed times must not reach the Int conversion.
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
