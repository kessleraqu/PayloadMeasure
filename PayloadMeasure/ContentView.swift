import SwiftUI

// Root view. Puts the HUD over the AR camera and owns the objects both of them share.

struct ContentView: View {
    @AppStorage("measurementWorkflowMode")
    private var workflowMode: MeasurementWorkflowMode = .spatial3D
    @State private var sessionManager = ARSessionManager()
    @State private var aimerState = AimerState()
    @State private var captureEngine = ObjectCaptureEngine()

    var body: some View {
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
                workflowMode: $workflowMode
            )
        }
    }
}

#Preview {
    ContentView()
}
