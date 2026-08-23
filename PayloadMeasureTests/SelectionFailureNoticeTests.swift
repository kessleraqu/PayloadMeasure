import XCTest
@testable import PayloadMeasure

// Pressing Measure and having the button come back is the whole reported failure, and the part of it
// that is the app's fault twice over: once for not starting, and once for not saying so. Every path
// that ends a pending selection without a measurement has to leave a reason behind, and every path that
// answers one has to take the reason away again.

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
                \(ending.name): the operator watched the Measure button disappear and reappear. \
                Handing it back without a reason is the failure they reported as the app doing nothing.
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
            "The last press has been answered by this one; the banner must not still be arguing about it."
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

        // The notice retires itself on this tick, but only once it is old. Retiring on the very next
        // segmentation would put it back to being invisible, which is the bug.
        for _ in 0 ..< 12 {
            engine.updateObjectMaskTracking(visibleCount: 0, markers: [])
        }
        XCTAssertEqual(engine.lastSelectionFailure, reason)
    }
}
