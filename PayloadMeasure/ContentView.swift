import SwiftUI

// Root view. Picks a working method, then puts the HUD over the AR camera and owns the objects both
// of them share.
//
// A full reset drops back to the start screen and rebuilds the whole hierarchy, so every piece of
// per-session state — including the packing store the HUD owns — is genuinely thrown away.

struct ContentView: View {
    @AppStorage("measurementWorkflowMode")
    private var workflowMode: MeasurementWorkflowMode = .spatial3D
    @State private var sessionManager = ARSessionManager()
    @State private var aimerState = AimerState()
    @State private var captureEngine = ObjectCaptureEngine()
    @State private var flow: MeasurementFlow?
    @State private var sessionToken = 0

    var body: some View {
        if let flow {
            ZStack {
                ARCameraView(
                    sessionManager: sessionManager,
                    aimerState: aimerState,
                    captureEngine: captureEngine,
                    workflowMode: workflowMode
                )
                .ignoresSafeArea()

                MesOverlayView(
                    sessionManager: sessionManager,
                    aimerState: aimerState,
                    captureEngine: captureEngine,
                    workflowMode: $workflowMode,
                    flow: flow,
                    onFullReset: fullReset
                )
            }
            .id(sessionToken)
        } else {
            StartView { chosen in
                flow = chosen
            }
        }
    }

    private func fullReset() {
        captureEngine.reset()
        sessionToken &+= 1
        flow = nil
    }
}

#Preview {
    ContentView()
}
