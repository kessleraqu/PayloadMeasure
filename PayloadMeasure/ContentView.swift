
import SwiftUI

struct ContentView: View {
    @State private var sessionManager = ARSessionManager()
    @State private var mesEngine = MesEngine()
    @State private var captureEngine = ObjectCaptureEngine()

    var body: some View {
        ZStack {
            ARCameraView(
                sessionManager: sessionManager,
                mesEngine: mesEngine,
                captureEngine: captureEngine
            )
            .ignoresSafeArea()

            MesOverlayView(
                sessionManager: sessionManager,
                mesEngine: mesEngine,
                captureEngine: captureEngine
            )
        }
    }
}

#Preview {
    ContentView()
}
