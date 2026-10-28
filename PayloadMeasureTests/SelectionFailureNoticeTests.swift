import XCTest
@testable import PayloadMeasure

// Every path that ends a selection without starting a measurement must leave a reason for the
// operator, and every path that answers one must clear it.

@MainActor
final class SelectionFailureNoticeTests: XCTestCase {
    private let crosshair = CGPoint(x: 0.5, y: 0.5)

    private func pressMeasure(on engine: ObjectCaptureEngine) {
        engine.requestObjectMaskToggle(at: crosshair)
    }

    func testEveryWayASelectionCanEndWithoutAMeasurementExplainsItself() {
        let endings: [(name: String, end: (ObjectCaptureEngine) -> Void)] = [
            ("no mask found", { $0.reportObjectLockNotFound() }),
            ("no surface", { $0.reportObjectLockNeedsSurface() }),
            ("recognition failed", { $0.reportObjectRecognitionFailure() }),
            ("recognition warming up", { $0.reportObjectRecognitionPreparing() }),
            ("environment not ready", { $0.reportObjectSelectionNotReady() }),
            ("object limit", { $0.reportObjectLimitReached() }),
            ("interrupted", { $0.cancelObjectSelection() })
        ]
        for ending in endings {
            let engine = ObjectCaptureEngine()
            pressMeasure(on: engine)
            ending.end(engine)
            XCTAssertFalse(
                engine.isObjectSelectionPending,
                "\(ending.name): the button comes back, so the press is over."
            )
            XCTAssertNotNil(
                engine.lastSelectionFailure,
                """
                \(ending.name) gave the Measure button back without a reason.
                """
            )
            XCTAssertNil(engine.activeObjectID)
        }
    }

    func testPressingAgainRetiresTheReason() {
        let engine = ObjectCaptureEngine()
        pressMeasure(on: engine)
        engine.reportObjectLockNotFound()
        XCTAssertNotNil(engine.lastSelectionFailure)

        pressMeasure(on: engine)
        XCTAssertTrue(engine.isObjectSelectionPending)
        XCTAssertNil(
            engine.lastSelectionFailure,
            "A new press should clear the previous failure notice."
        )
    }

    func testAMeasurementStartingRetiresTheReason() {
        let engine = ObjectCaptureEngine()
        pressMeasure(on: engine)
        engine.reportObjectLockNotFound()
        XCTAssertNotNil(engine.lastSelectionFailure)

        let id = UUID()
        pressMeasure(on: engine)
        engine.beginObjectMeasurement(id: id)
        XCTAssertEqual(engine.activeObjectID, id)
        XCTAssertNil(
            engine.lastSelectionFailure,
            "Nothing failed: this is the measurement the operator asked for."
        )
    }

    func testTheReasonSurvivesTheSegmentationTicksItIsMeantToBeReadAcross() {
        let engine = ObjectCaptureEngine()
        pressMeasure(on: engine)
        engine.reportObjectLockNotFound()
        let reason = engine.lastSelectionFailure
        XCTAssertNotNil(reason)

        // The notice clears itself here, but only once it's old enough to have been read.
        for _ in 0 ..< 12 {
            engine.updateObjectMaskTracking(visibleCount: 0, markers: [])
        }
        XCTAssertEqual(engine.lastSelectionFailure, reason)
    }
}
