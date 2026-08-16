import XCTest
@testable import PayloadMeasure

final class SharedARViewOwnershipTests: XCTestCase {
    func testLateReleaseCannotTakeCameraFromNewOwner() {
        var ownership = SharedARRendererOwnership()
        let measurement = ownership.acquire(
            .measurement,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let packing = ownership.acquire(
            .packing,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )

        XCTAssertFalse(ownership.release(measurement))
        XCTAssertTrue(ownership.owns(packing))
    }

    func testCurrentOwnerCanReleaseCamera() {
        var ownership = SharedARRendererOwnership()
        let packing = ownership.acquire(.packing)

        XCTAssertTrue(ownership.release(packing))
        XCTAssertNil(ownership.activeLease)
    }

    func testMeasurementWorldResetsInitiallyAndOnlyAtPayloadBoundaries() {
        var request = MeasurementWorldResetRequest()

        XCTAssertTrue(request.consume(), "The first measurement session starts a new world.")
        XCTAssertFalse(
            request.consume(),
            "Returning from packing to the same payload must preserve its coordinate frame."
        )

        request.request()
        XCTAssertTrue(request.consume(), "A real payload boundary requests one fresh world.")
        XCTAssertFalse(request.consume(), "The boundary request is consumed exactly once.")
    }

    @MainActor
    func testPackingWorkflowRemovesMeasurementRendererForWholePresentation() {
        let manager = ARSessionManager()

        XCTAssertFalse(manager.isPackingArrangementPresented)
        manager.setPackingArrangementPresented(true)
        XCTAssertTrue(manager.isPackingArrangementPresented)
        XCTAssertTrue(manager.isTrackingSuspended)

        manager.setPackingArrangementPresented(false)
        XCTAssertFalse(manager.isPackingArrangementPresented)
        XCTAssertFalse(manager.isTrackingSuspended)
    }
}
