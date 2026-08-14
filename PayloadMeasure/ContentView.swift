import SwiftUI

// Root view. Runs a user study: set the participant up, measure and pack the first payload box,
// then the second, then show the data.
//
// The study owns the flow now — the method and the box order come from StudySetupView rather than
// being picked ad hoc, so a session cannot start without being recorded.

struct ContentView: View {
    @AppStorage("measurementWorkflowMode")
    private var workflowMode: MeasurementWorkflowMode = .spatial3D
    @State private var sessionManager = ARSessionManager()
    @State private var aimerState = AimerState()
    @State private var captureEngine = ObjectCaptureEngine()
    @State private var sessionToken = 0
    @State private var warmup = AppWarmup()
    @State private var study = StudyStore()

    var body: some View {
        if let run = study.activeRun, study.hasFinishedAllBoxes {
            NavigationStack {
                StudyResultsView(run: run, store: study, onRestart: restartForNextParticipant)
            }
        } else if let flow = study.flow, study.currentBox != nil {
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
                    study: study,
                    onFullReset: startNextBox
                )
            }
            .id(sessionToken)
        } else {
            StudySetupView(warmup: warmup, store: study)
        }
    }

    /// Between boxes: the measurements belong to the box just finished, so the capture session is
    /// cleared and the view hierarchy rebuilt, exactly as a full reset does.
    private func startNextBox() {
        captureEngine.reset()
        sessionToken &+= 1
        if study.isOnLastBox {
            study.finishRun()
        } else {
            study.advanceToNextBox()
        }
    }

    /// From the results screen. Keeps every saved run; only clears the screen.
    private func restartForNextParticipant() {
        captureEngine.reset()
        sessionToken &+= 1
        study.clearActiveRun()
    }
}

#Preview {
    ContentView()
}
