import ARKit
import XCTest
@testable import PayloadMeasure

// When measuring is allowed to begin. ARKit reports normal tracking within a frame or two of starting,
// while anchors and planes are still being corrected — measure then and the measurement is taken against
// a coordinate system that is quietly moving.

final class WorldSettlingRuleTests: XCTestCase {
    func testNormalTrackingAloneIsNotEnoughAtFirst() {
        XCTAssertFalse(
            WorldSettlingRule.isSettled(
                normalTrackingSeconds: 0.2,
                mappingStatus: .extending
            ),
            "A fraction of a second of good tracking is not a settled world."
        )
        XCTAssertFalse(
            WorldSettlingRule.isSettled(
                normalTrackingSeconds: 0.2,
                mappingStatus: .mapped
            )
        )
    }

    func testSettlesOnceTrackingHasHeldAndTheMapHasGrown() {
        XCTAssertTrue(
            WorldSettlingRule.isSettled(
                normalTrackingSeconds: WorldSettlingRule.minimumNormalTrackingSeconds,
                mappingStatus: .extending
            )
        )
        XCTAssertTrue(
            WorldSettlingRule.isSettled(
                normalTrackingSeconds: 3,
                mappingStatus: .mapped
            )
        )
    }

    /// The map only grows if the operator moves. A phone held perfectly still must not be locked out for
    /// ever, so time alone is accepted eventually.
    func testTimeAloneIsAcceptedAfterTheWaiver() {
        XCTAssertFalse(
            WorldSettlingRule.isSettled(
                normalTrackingSeconds: WorldSettlingRule.mappingWaiverSeconds - 0.1,
                mappingStatus: .limited
            )
        )
        XCTAssertTrue(
            WorldSettlingRule.isSettled(
                normalTrackingSeconds: WorldSettlingRule.mappingWaiverSeconds,
                mappingStatus: .limited
            )
        )
        XCTAssertTrue(
            WorldSettlingRule.isSettled(
                normalTrackingSeconds: 30,
                mappingStatus: .notAvailable
            )
        )
    }

    func testANonNumberIsNeverSettled() {
        XCTAssertFalse(
            WorldSettlingRule.isSettled(
                normalTrackingSeconds: .nan,
                mappingStatus: .mapped
            )
        )
    }

    /// The waiting message has to say which of the two things is being waited on, because they need
    /// opposite behaviour from the operator: hold still, then move around.
    func testTheWaitingMessageAsksForTheRightThing() {
        XCTAssertTrue(
            WorldSettlingRule.waitingDetail(
                normalTrackingSeconds: 0.3,
                mappingStatus: .limited
            ).lowercased().contains("still")
        )
        XCTAssertTrue(
            WorldSettlingRule.waitingDetail(
                normalTrackingSeconds: 3,
                mappingStatus: .limited
            ).lowercased().contains("slowly")
        )
    }
}
