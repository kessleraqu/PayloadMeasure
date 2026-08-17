import SwiftUI

// Root view. Runs one selected input condition through both payload sizes, then returns to setup so
// the administrator can configure the other input condition separately.
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
    /// Measurement and room-scale packing take turns using this one RealityKit renderer. Creating a
    /// second ARView later in a full-screen-cover flow can leave its camera background stuck on an
    /// old texture even while tracking remains live on iOS 26.
    @State private var sharedARViewHost = SharedARViewHost()
    @State private var warmup = AppWarmup()
    @State private var study = StudyStore()
    /// Owned here rather than by the setup screen, so an accuracy test survives that screen being
    /// rebuilt and can be left and returned to.
    @State private var accuracy = AccuracyStore()
    @State private var framingAccuracy = FramingAccuracyStore()

    var body: some View {
        Group {
            if study.isAwaitingParticipantStart {
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
                            // Pausing is not enough here: a paused ARView keeps its RealityKit
                            // renderer and last camera texture alive under the packing workflow.
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

    /// Reset: throw away everything measured and start this same payload over. The study does not
    /// move on, so a participant cannot reach the next box — or leave the practice payload — without
    /// the operator entering the password.
    private func restartCurrentPayload() {
        sharedARViewHost.requestNewMeasurementWorld()
        sessionManager.setPackingArrangementPresented(false)
        captureEngine.reset()
        sessionToken &+= 1
    }

    /// At a payload boundary the measurements belong to the one just finished, so the capture
    /// session is cleared and the view hierarchy rebuilt. Practice and both real payloads are
    /// separated by neutral participant-controlled start screens.
    private func startNextBox() {
        // The presenting overlay is replaced as part of this transition, so do not wait for its
        // onDismiss callback to return camera ownership. Clear it before constructing the next box.
        sharedARViewHost.requestNewMeasurementWorld()
        sessionManager.setPackingArrangementPresented(false)
        captureEngine.reset()
        sessionToken &+= 1
        if study.isPractice {
            study.startRealStudy()
        } else if study.isOnLastBox {
            study.finishRun()
            study.returnToSetupAfterCompletion()
        } else {
            study.advanceToNextBox()
        }
    }

    /// Abandons the run from the info panel, behind the study password. Whatever was already recorded
    /// for finished payloads stays on disk; the payload in progress simply never completes.
    private func cancelRun() {
        sharedARViewHost.requestNewMeasurementWorld()
        sessionManager.setPackingArrangementPresented(false)
        captureEngine.reset()
        sessionToken &+= 1
        study.clearActiveRun()
    }

    /// From the results screen. Keeps every saved run; only clears the screen.
    private func restartForNextParticipant() {
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
