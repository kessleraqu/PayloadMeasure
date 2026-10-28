import XCTest
import SwiftUI
@testable import PayloadMeasure

// The overlay's body type once got deep enough to overflow the 1 MB main thread stack on device
// (the simulator has 8 MB). The length of the printed type name is used as a proxy for that depth.

@MainActor
final class OverlayBodyComplexityTests: XCTestCase {
    func testMeasurementOverlayBodyTypeStaysWalkable() {
        let view = MeasurementOverlayView(
            sessionManager: ARSessionManager(),
            aimerState: AimerState(),
            captureEngine: ObjectCaptureEngine(),
            workflowMode: .constant(.spatial3D),
            flow: .batch,
            study: StudyStore(),
            onFullReset: {},
            onPayloadFinished: {},
            onRunCancelled: {}
        )
        let name = String(reflecting: type(of: view.body))
        XCTAssertLessThan(
            name.count,
            100,
            """
            The overlay body type is too deep. Keep lifecycle, sheet and alert modifiers in the \
            named AnyView layers inside MeasurementOverlayView.
            """
        )
    }
}
