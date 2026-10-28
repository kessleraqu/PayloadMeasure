import ARKit
import XCTest
@testable import PayloadMeasure

// When measuring may start. Tracking reports normal almost immediately, while anchors and planes
// are still shifting.

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

    /// A phone held still won't extend the map, so time alone is accepted eventually.
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

    /// The message says which condition is being waited on, since they need opposite actions.
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
