
import SwiftUI

struct ContentView: View {
    @AppStorage("measurementWorkflowMode")
    private var workflowMode: MeasurementWorkflowMode = .spatial3D
    @State private var sessionManager = ARSessionManager()
    @State private var mesEngine = MesEngine()
    @State private var captureEngine = ObjectCaptureEngine()

    var body: some View {
        ZStack {
            ARCameraView(
                sessionManager: sessionManager,
                mesEngine: mesEngine,
                captureEngine: captureEngine,
                workflowMode: workflowMode
            )
            .ignoresSafeArea()

            MesOverlayView(
                sessionManager: sessionManager,
                mesEngine: mesEngine,
                captureEngine: captureEngine,
                workflowMode: $workflowMode
            )
        }
    }
}

#Preview {
    ContentView()
}
