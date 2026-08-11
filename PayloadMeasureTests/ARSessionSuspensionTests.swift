import XCTest
@testable import PayloadMeasure

@MainActor
final class ARSessionSuspensionTests: XCTestCase {
    func testOverlappingArrangementAndLifecycleReasonsResumeOnlyAfterBothClear() {
        let manager = ARSessionManager()
        let initialEpoch = manager.frameEpoch

        manager.setPackingArrangementPresented(true)
        XCTAssertTrue(manager.isTrackingSuspended)
        XCTAssertEqual(manager.frameEpoch, initialEpoch + 1)

        manager.setApplicationActive(false)
        manager.setPackingArrangementPresented(false)
        XCTAssertTrue(manager.isTrackingSuspended)
        XCTAssertEqual(
            manager.frameEpoch,
            initialEpoch + 1,
            "Changing overlapping reasons must not create an intermediate resume."
        )

        manager.setApplicationActive(true)
        XCTAssertFalse(manager.isTrackingSuspended)
        XCTAssertEqual(manager.frameEpoch, initialEpoch + 2)
    }

    func testRepeatedPresentationCallbacksAreIdempotent() {
        let manager = ARSessionManager()

        manager.setPackingArrangementPresented(true)
        let suspendedEpoch = manager.frameEpoch
        manager.setPackingArrangementPresented(true)

        XCTAssertTrue(manager.isTrackingSuspended)
        XCTAssertEqual(manager.frameEpoch, suspendedEpoch)

        manager.setPackingArrangementPresented(false)
        let resumedEpoch = manager.frameEpoch
        manager.setPackingArrangementPresented(false)

        XCTAssertFalse(manager.isTrackingSuspended)
        XCTAssertEqual(manager.frameEpoch, resumedEpoch)
    }

    func testArrangementStillOwnsSuspensionAfterSceneBecomesActive() {
        let manager = ARSessionManager()

        manager.setApplicationActive(false)
        manager.setPackingArrangementPresented(true)
        manager.setApplicationActive(true)

        XCTAssertTrue(manager.isTrackingSuspended)
        XCTAssertFalse(manager.isTrackingReady)
        XCTAssertFalse(manager.isObjectTrackingEnvironmentReady)

        manager.setPackingArrangementPresented(false)
        XCTAssertFalse(manager.isTrackingSuspended)
    }
}
