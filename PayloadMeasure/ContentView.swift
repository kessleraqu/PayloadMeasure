import SwiftUI

// Root view. Runs one input condition through both payload sizes, then returns to the study setup
// so the other condition can be configured.

struct ContentView: View {
    @AppStorage("measurementWorkflowMode")
    private var workflowMode: MeasurementWorkflowMode = .spatial3D
    @State private var sessionManager = ARSessionManager()
    @State private var aimerState = AimerState()
    @State private var captureEngine = ObjectCaptureEngine()
    @State private var sessionToken = 0
    /// Measurement and packing share one ARView. Creating a second one inside a full-screen cover
    /// can leave its camera background frozen on iOS 26.
    @State private var sharedARViewHost = SharedARViewHost()
    @State private var warmup = AppWarmup()
    @State private var study = StudyStore()
    /// Kept here so a running accuracy test survives the setup screen being rebuilt.
    @State private var accuracy = AccuracyStore()
    @State private var framingAccuracy = FramingAccuracyStore()
    @State private var isShowingFinalConnectStep = false

    var body: some View {
        Group {
            if isShowingFinalConnectStep {
                StudyConnectView(
                    onConnectStarted: { study.endCurrentPhase() },
                    onConnectFinished: completeFinalConnectStep
                )
            } else if study.isAwaitingParticipantStart {
                StudyParticipantStartView(store: study) {
                    study.beginParticipantSession()
                }
            } else if let run = study.activeRun, study.hasFinishedAllBoxes {
                NavigationStack {
                    StudyResultsView(run: run, store: study, onRestart: restartForNextParticipant)
                }
            } else if let flow = study.flow, study.hasActiveSession {
                Group {
                    if study.currentInputMode == .manual {
                        ManualMeasurementView(
                            captureEngine: captureEngine,
                            study: study,
                            onFullReset: restartCurrentPayload,
                            onPayloadFinished: startNextBox,
                            onRunCancelled: cancelRun
                        )
                    } else {
                        ZStack {
                            // Pausing isn't enough: a paused ARView keeps its renderer and camera texture alive.
                            if !sessionManager.isPackingArrangementPresented {
                                ARCameraView(
                                    sessionManager: sessionManager,
                                    aimerState: aimerState,
                                    captureEngine: captureEngine,
                                    workflowMode: workflowMode,
                                    sharedViewHost: sharedARViewHost
                                )
                                .ignoresSafeArea()
                            } else {
                                Color.black.ignoresSafeArea()
                            }

                            MeasurementOverlayView(
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
                    }
                }
                .id(sessionToken)
            } else {
                StudySetupView(
                    warmup: warmup,
                    store: study,
                    accuracy: accuracy,
                    framingAccuracy: framingAccuracy
                )
            }
        }
        .environment(\.sharedARViewHost, sharedARViewHost)
    }

    /// Discards this payload's measurements and starts it again. The study does not advance.
    private func restartCurrentPayload() {
        isShowingFinalConnectStep = false
        sharedARViewHost.requestNewMeasurementWorld()
        sessionManager.setPackingArrangementPresented(false)
        captureEngine.reset()
        sessionToken &+= 1
    }

    /// Clears the capture session and rebuilds the view hierarchy for the next payload.
    private func startNextBox() {
        // The overlay is replaced in this transition, so don't wait for its onDismiss.
        sharedARViewHost.requestNewMeasurementWorld()
        sessionManager.setPackingArrangementPresented(false)
        captureEngine.reset()
        sessionToken &+= 1
        if study.isTestMode {
            // A test run has a single payload and nothing to save, so finishing it just returns to setup.
            study.clearActiveRun()
        } else if study.isOnLastBox {
            study.endCurrentPhase()
            isShowingFinalConnectStep = true
        } else {
            study.advanceToNextBox()
        }
    }

    private func completeFinalConnectStep(elapsed: TimeInterval) {
        study.recordFinalConnection(seconds: elapsed)
        study.finishRun()
        study.returnToSetupAfterCompletion()
        isShowingFinalConnectStep = false
    }

    /// Cancels the run (password protected). Payloads already finished stay saved.
    private func cancelRun() {
        isShowingFinalConnectStep = false
        sharedARViewHost.requestNewMeasurementWorld()
        sessionManager.setPackingArrangementPresented(false)
        captureEngine.reset()
        sessionToken &+= 1
        study.clearActiveRun()
    }

    /// Clears the results screen. Saved runs are kept.
    private func restartForNextParticipant() {
        isShowingFinalConnectStep = false
        sharedARViewHost.requestNewMeasurementWorld()
        sessionManager.setPackingArrangementPresented(false)
        captureEngine.reset()
        sessionToken &+= 1
        study.clearActiveRun()
    }
}

#Preview {
    ContentView()
}
