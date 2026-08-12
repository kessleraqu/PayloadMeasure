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
            onFullReset: {}
        )
        let name = String(reflecting: type(of: view.body))
        print("MesOverlayView.body type length: \(name.count)")
        XCTAssertLessThan(
            name.count,
            7_000,
            """
            The overlay's body type has grown again. This is a watermark, not a proven-safe bound: \
            the device crash happened at some unknown depth above it, so treat any growth as \
            dangerous. Do not fix it by trimming the UI — put an AnyView boundary around whichever \
            layer grew, as liveContentLayer / topLayer / bottomLayer already do.
            """
        )
    }
}
