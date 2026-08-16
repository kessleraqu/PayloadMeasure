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
    /// Owned here rather than by the setup screen, so an accuracy test survives that screen being
    /// rebuilt and can be left and returned to.
    @State private var accuracy = AccuracyStore()

    var body: some View {
        if let run = study.activeRun, study.hasFinishedAllBoxes {
            NavigationStack {
                StudyResultsView(run: run, store: study, onRestart: restartForNextParticipant)
            }
        } else if let flow = study.flow, study.hasActiveSession {
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
                    onFullReset: restartCurrentPayload,
                    onPayloadFinished: startNextBox,
                    onRunCancelled: cancelRun
                )
            }
            .id(sessionToken)
        } else {
            StudySetupView(warmup: warmup, store: study, accuracy: accuracy)
        }
    }

    /// Reset: throw away everything measured and start this same payload over. The study does not
    /// move on, so a participant cannot reach the next box — or leave the practice payload — without
    /// the operator entering the password.
    private func restartCurrentPayload() {
        captureEngine.reset()
        sessionToken &+= 1
    }

    /// Between payloads: the measurements belong to the one just finished, so the capture session is
    /// cleared and the view hierarchy rebuilt, exactly as a full reset does. The practice payload
    /// leaves by the same door — it just leads to the first box instead of the second.
    private func startNextBox() {
        captureEngine.reset()
        sessionToken &+= 1
        if study.isPractice {
            study.startRealStudy()
        } else if study.isOnLastBox {
            study.finishRun()
        } else {
            study.advanceToNextBox()
        }
    }

    /// Abandons the run from the info panel, behind the study password. Whatever was already recorded
    /// for finished payloads stays on disk; the payload in progress simply never completes.
    private func cancelRun() {
        captureEngine.reset()
        sessionToken &+= 1
        study.clearActiveRun()
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
