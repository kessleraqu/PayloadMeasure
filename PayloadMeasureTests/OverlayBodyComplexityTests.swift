import XCTest
import SwiftUI
@testable import PayloadMeasure

// The HUD once grew a `body` whose static type was nested deeply enough that the Swift runtime
// overflowed the stack merely walking its metadata — a crash inside
// SubstGenericParametersFromMetadata with a shallow call stack, on device only, because the
// simulator's main thread gets 8 MB against 1 MB on iOS.
//
// The type's printed name is a fair proxy for how deep that tree is, so this fails long before a
// device would.

@MainActor
final class OverlayBodyComplexityTests: XCTestCase {
    func testMeasurementOverlayBodyTypeStaysWalkable() {
        let view = MesOverlayView(
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
        print("MesOverlayView.body type length: \(name.count)")
        XCTAssertLessThan(
            name.count,
            100,
            """
            The overlay's public body must remain one shallow type-erasure boundary. Lifecycle, \
            sheet, alert and confirmation modifiers belong in the named AnyView layers inside \
            MesOverlayView; joining them back into body can overwhelm Xcode's editor type-checker \
            and previously overflowed the smaller device main-thread stack.
            """
        )
    }
}
