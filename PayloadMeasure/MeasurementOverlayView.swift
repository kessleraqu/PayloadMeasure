import SwiftUI
import UIKit

// The HUD over the camera: status, guidance, saved objects, and the controls that drive a scan.
//
// In:  session manager, aimer state and capture engine.
// Out: on screen only. Operator actions go back through the capture engine.

/// A measured object's id, made presentable by `sheet(item:)`.
struct IdentifiedObjectID: Identifiable, Hashable {
    let id: UUID
}

struct MesOverlayView: View {
    private enum ObjectDetailsContext {
        case finalize(UUID)
        case edit(UUID)
    }

    private enum MeasurementInstruction: Equatable {
        case preparing
        case findObject
        case findNextObject
        case moveFarther
        case moveCloser
        case readyToMeasure
        case holdStill
        case pointDown
        case useSideView
        case findSurface
    }

    private struct AutomaticMeasurementCandidate: Hashable {
        let id: UUID
        let point: CGPoint
    }

    let sessionManager: ARSessionManager
    let aimerState: AimerState
    let captureEngine: ObjectCaptureEngine
    @Binding var workflowMode: MeasurementWorkflowMode
    let flow: MeasurementFlow
    let study: StudyStore
    /// Clears everything and starts this same payload again. Does not move the study on: pressing
    /// Reset must never take a participant to the next box, and must never skip the password.
    let onFullReset: () -> Void
    /// Called from inside the loading plan, behind the study password, when this payload is done.
    let onPayloadFinished: () -> Void
    /// Abandons the whole run and goes back to the start screen. Behind the study password.
    let onRunCancelled: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsPanel = false
    @State private var showsCancelRunPassword = false
    @State private var showsLiDARLimitations = false
    @State private var objectDetailsContext: ObjectDetailsContext?
    @State private var objectNameText = ""
    @State private var pendingRemovalObjectID: UUID?
    @State private var showsResetConfirmation = false
    @State private var showsFinishLoadConfirmation = false
    @State private var packageDetails: IdentifiedObjectID?
    @State private var showsSavedObjects = false
    @State private var pendingWorkflowMode: MeasurementWorkflowMode?
    @State private var showsModeChangeConfirmation = false
    @State private var showsTrackingDetails = false
    @State private var pendingDetailsObjectID: UUID?
    @State private var lockFeedback = UINotificationFeedbackGenerator()
    @State private var packingStore = PackingStore()
    @State private var showsPackingWorkflow = false
    @State private var showsPackingConfirmation = false

    private var isAutomaticCaptureSupported: Bool {
        sessionManager.isAutomaticObjectCaptureSupported
    }

    private var showsLiveOverlay: Bool {
        !sessionManager.isCoachingActive
    }

    // Each group below is deliberately type-erased before another group of modifiers is attached.
    // One continuous expression made Xcode's editor type-checker time out even when a command-line
    // build succeeded. The timeout then produced misleading follow-on errors such as "Cannot find
    // StudyStore in scope". These named boundaries also keep the runtime view type shallow enough for
    // an iPhone's smaller main-thread stack.
    private var animatedLayers: AnyView {
        AnyView(
            ZStack {
                liveContentLayer
                topLayer
                bottomLayer
            }
            .animation(.snappy(duration: 0.22), value: showsPanel)
            .animation(.snappy(duration: 0.22), value: showsSavedObjects)
            .animation(.snappy(duration: 0.2), value: captureEngine.hasCapture)
            .animation(
                .snappy(duration: 0.2),
                value: captureEngine.hasCompletedObjectRecognitionWarmup
            )
            .animation(
                .snappy(duration: 0.25),
                value: sessionManager.isObjectTrackingEnvironmentReady
            )
            .animation(.snappy(duration: 0.2), value: isTooCloseForMeasurement)
        )
    }

    // MARK: - Lifecycle and presentation layers

    private var overlayObservationLayer: AnyView {
        AnyView(animatedLayers
        .onChange(of: captureEngine.resetRevision) { _, _ in
            showsSavedObjects = false
            packingStore.clear()
        }
        .onChange(of: finalizedMeasuredObjectIDs.count) { _, count in
            if count == 0 {
                showsSavedObjects = false
            }
        }
        .onChange(of: sessionManager.isCoachingActive) { _, isActive in
            if isActive {
                showsSavedObjects = false
            }
        }
        .onChange(of: showsModeChangeConfirmation) { _, isPresented in
            if !isPresented {
                pendingWorkflowMode = nil
            }
        }
        )
    }

    private var measurementEventLayer: AnyView {
        AnyView(overlayObservationLayer
        .onChange(of: captureEngine.automaticLockRequestRevision) { _, _ in
            presentAutomaticLockIfRequested()
        }
        .onChange(of: isTooCloseForMeasurement) { wasTooClose, isTooClose in
            // Auto-lock may have become ready while the operator was inside the unsafe range. The
            // engine will not issue a second request, so honour the existing one upon moving back.
            if wasTooClose, !isTooClose {
                presentAutomaticLockIfRequested()
            }
        }
        .onChange(of: captureEngine.canFinalizeActiveObject) { _, canLock in
            if canLock {
                lockFeedback.prepare()
            }
        }
        )
    }

    private var applicationLifecycleLayer: AnyView {
        AnyView(measurementEventLayer
        .task {
            await prepareForAppearance()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onChange(of: showsPackingWorkflow) { _, isPresented in
            handlePackingWorkflowPresentationChange(isPresented)
        }
        )
    }

    private var objectSheetLayer: AnyView {
        AnyView(applicationLifecycleLayer
        .sheet(item: $packageDetails) { entry in
            PackageDetailsSheet(
                objectID: entry.id,
                captureEngine: captureEngine,
                store: packingStore,
                onRescan: { rescan(entry.id) }
            )
            // In the one-by-one method this sheet *is* the boxing and weighing step, so it is timed
            // as such and the clock goes back to measuring when it closes.
            .onAppear { study.beginPhase(.pack) }
            .onDisappear { study.beginPhase(.measure) }
        }
        .sheet(isPresented: $showsCancelRunPassword) {
            StudyPasswordSheet(
                title: "Cancel this run",
                message: "Returns to the start screen. Anything already saved for this participant stays in Saved runs; the payload in progress is not recorded.",
                password: StudyStore.nextBoxPassword,
                confirmTitle: "Cancel the run"
            ) {
                onRunCancelled()
            }
        }
        )
    }

    private var workflowSheetLayer: AnyView {
        AnyView(objectSheetLayer
        .confirmationDialog(
            "Did you scan all the objects?",
            isPresented: $showsPackingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Continue to packing") {
                beginPackingHandoff()
            }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("Check that every object has been scanned and saved before continuing.")
        }
        .sheet(isPresented: $showsLiDARLimitations) {
            nonLiDARLimitationsSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(
            isPresented: $showsPackingWorkflow,
            onDismiss: handlePackingWorkflowDismissal
        ) {
            PreparationView(
                captureEngine: captureEngine,
                store: packingStore,
                study: study,
                onBoxFinished: onPayloadFinished
            )
        }
        )
    }

    private var objectDetailsAlertLayer: AnyView {
        // Names belong to the packing/weight phase. Keeping this explicit wrapper preserves the
        // shallow view type without allowing measurement completion to present a naming alert.
        AnyView(workflowSheetLayer)
    }

    private var removalConfirmationLayer: AnyView {
        AnyView(objectDetailsAlertLayer
        .confirmationDialog(
            removalConfirmationTitle,
            isPresented: removalConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            if let id = pendingRemovalObjectID {
                Button(removalButtonTitle(for: id), role: .destructive) {
                    packingStore.clearPreparation(for: id)
                    captureEngine.removeFinalizedObject(id: id)
                    if finalizedMeasuredObjectIDs.isEmpty {
                        showsSavedObjects = false
                    }
                    pendingRemovalObjectID = nil
                }
                .disabled(captureEngine.isObjectSelectionPending)
            }
            Button("Cancel", role: .cancel) {
                pendingRemovalObjectID = nil
            }
        } message: {
            if let id = pendingRemovalObjectID {
                Text("\(boxSummary(for: id)) and its saved measurement data will be removed.")
            }
        }
        )
    }

    private var resetConfirmationLayer: AnyView {
        AnyView(removalConfirmationLayer
        .confirmationDialog(
            "Reset all measurements?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset everything", role: .destructive) {
                showsSavedObjects = false
                onFullReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears every measurement, name, box, weight and loading plan, restarts the AR session and returns to the start screen. It cannot be undone.")
        }
        )
    }

    private var finishLoadConfirmationLayer: AnyView {
        AnyView(resetConfirmationLayer
        .confirmationDialog(
            "Finished with this load?",
            isPresented: $showsFinishLoadConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start a new load", role: .destructive) {
                onFullReset()
            }
            Button("Keep working", role: .cancel) {
                showsPackingWorkflow = true
            }
        } message: {
            Text("Closing the loading plan clears every measurement and starts again from the beginning. Choose Keep working to go back to the plan.")
        }
        )
    }

    private var modeConfirmationLayer: AnyView {
        AnyView(finishLoadConfirmationLayer
        .confirmationDialog(
            "Switch measurement mode?",
            isPresented: $showsModeChangeConfirmation,
            titleVisibility: .visible
        ) {
            if let pendingWorkflowMode {
                Button(
                    "Switch to \(pendingWorkflowMode.title)",
                    role: .destructive
                ) {
                    showsSavedObjects = false
                    workflowMode = pendingWorkflowMode
                    self.pendingWorkflowMode = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingWorkflowMode = nil
            }
        } message: {
            Text("Changing the measurement method clears the current scan and all saved objects.")
        }
        )
    }

    var body: some View {
        modeConfirmationLayer
    }

    private func prepareForAppearance() async {
        // A SwiftUI `.task` may begin in the same run-loop turn in which its view is installed.
        // Yield once so these observable writes never occur inside the view-update transaction.
        await Task.yield()
        guard !Task.isCancelled else { return }

        handleAppearance()
        if let size = study.activeModuleSizeMillimetres {
            packingStore.module.lengthMillimetres = size.x
            packingStore.module.widthMillimetres = size.y
            packingStore.module.heightMillimetres = size.z
        }
        // Use the current payload's own catalogue and pick up edits made on the setup screen.
        packingStore.setPayload(study.catalogueOwner)
    }

    private func handleAppearance() {
        sessionManager.setApplicationActive(scenePhase == .active)
        if !isAutomaticCaptureSupported, workflowMode == .top {
            workflowMode = .spatial3D
        }
        // Measurements now finish only through the convergence rule; the manual Finish control has
        // deliberately been removed from the participant-facing camera screen.
        captureEngine.setAutomaticLockEnabled(true)
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        sessionManager.setApplicationActive(phase == .active)
    }

    private func beginPackingHandoff() {
        showsSavedObjects = false
        study.endCurrentPhase()
        showsPackingWorkflow = true
    }

    /// Leaving the loading plan means the load is done. Rather than drop back into a half-used
    /// session — which is what made the app feel worse afterwards — offer to clear everything.
    private func handlePackingWorkflowDismissal() {
        // Back to measuring for the same box. Moving on is done from inside the plan, behind a
        // password, so closing the sheet by accident cannot end a participant's box.
        study.beginPhase(.measure)
    }

    private func handlePackingWorkflowPresentationChange(_ isPresented: Bool) {
        // The phase is started by PreparationView's own stages rather than here, so that boxing and
        // loading the payload are timed separately.
        sessionManager.setPackingArrangementPresented(isPresented)
    }

    /// Camera-space content: masks, markers, the aimer and the levelling prompt.
    private var liveContentLayer: AnyView {
        guard showsLiveOverlay else { return AnyView(EmptyView()) }
        return AnyView(
            ZStack {
                objectMaskPreview
                objectMaskMarkers
                if !showsPanel {
                    aimer
                }
            }
        )
    }

    private var topLayer: AnyView {
        guard showsLiveOverlay else { return AnyView(EmptyView()) }
        return AnyView(
            VStack(spacing: 10) {
                StudyTimerStrip(study: study)
                    .padding(.top, 8)
                    .padding(.horizontal, 16)

                GlassEffectContainer(spacing: 14) {
                    topHUD
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.horizontal, 16)

                if !showsPanel {
                    measurementInstructionBanner
                        .padding(.horizontal, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                Spacer()
            }
        )
    }

    private var bottomLayer: AnyView {
        guard showsLiveOverlay, !showsPanel else { return AnyView(EmptyView()) }
        return AnyView(
            VStack {
                Spacer()

                VStack(alignment: .leading, spacing: 10) {
                    if automaticMeasurementCandidate != nil {
                        measureButton
                    }

                    if captureEngine.activeObjectID != nil {
                        activeMeasurementProgressCard
                        bottomActionRow
                    }

                    if !finalizedMeasuredObjectIDs.isEmpty,
                       captureEngine.activeObjectID == nil {
                        startPackingSection
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        )
    }

    // MARK: - Top HUD

    @ViewBuilder
    private var topHUD: some View {
        if showsPanel {
            infoPanel
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            HStack(alignment: .top, spacing: 10) {
                if study.isPractice {
                    // Nothing here is recorded, and it should be impossible to be confused about
                    // which payload the participant is on.
                    Label("Practice", systemImage: "graduationcap.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .glassEffect(.regular, in: .capsule)
                }

                Spacer(minLength: 8)

                Button {
                    showsSavedObjects = false
                    showsPanel = true
                } label: {
                    Image(systemName: "info")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .foregroundStyle(.primary)
                .accessibilityLabel("Show information")
            }
        }
    }

    /// Controls that are not part of the measuring flow itself.
    @ViewBuilder
    private var testingControls: some View {
        if captureEngine.activeObjectID != nil || captureEngine.canReset {
            VStack(alignment: .leading, spacing: 8) {
                Text("Controls")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if captureEngine.canReset {
                        resetButton(showsTitle: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var isPreparingToMeasure: Bool {
        !sessionManager.isObjectTrackingEnvironmentReady
            || !captureEngine.hasCompletedObjectRecognitionWarmup
    }

    /// Only what the crosshair is on may be offered for measurement. The mask processor already
    /// refuses to preview anything else, and this repeats the rule in viewport terms because it is
    /// the Measure button and the distance guide that act on it.
    private func isUnderCrosshair(_ layer: ObjectMaskPreviewLayer) -> Bool {
        let centre = CGPoint(x: 0.5, y: 0.5)
        // Deliberately looser than the image-space rule: viewport and image coordinates do not scale
        // alike, and this gate exists to reject the object at the edge, not to second-guess the mask.
        let slack = ObjectMaskCandidatePolicy.aimWindowRadius
        if let box = layer.referenceViewportBoundingBox {
            return ObjectMaskCandidatePolicy.isAimedAt(
                boundingBox: box,
                aim: centre,
                slack: slack
            )
        }
        guard let point = layer.referenceAnchorPoint else {
            return true
        }
        return hypot(point.x - centre.x, point.y - centre.y) <= slack
    }

    private var liveMeasurementCandidateLayer: ObjectMaskPreviewLayer? {
        let viewportCentre = CGPoint(x: 0.5, y: 0.5)
        return captureEngine.objectMaskPreview?.layers
            .filter { $0.trackedObjectID == nil && isUnderCrosshair($0) }
            .min {
                let lhs = $0.referenceAnchorPoint ?? viewportCentre
                let rhs = $1.referenceAnchorPoint ?? viewportCentre
                return hypot(lhs.x - viewportCentre.x, lhs.y - viewportCentre.y)
                    < hypot(rhs.x - viewportCentre.x, rhs.y - viewportCentre.y)
            }
    }

    /// Uses the fitted box centre once measuring has begun. Before selection, ARCameraView attaches
    /// the median LiDAR distance sampled inside the live mask so differently sized objects are all
    /// guided to the same physical range.
    private var estimatedCameraToObjectCentreDistanceMetres: Double? {
        if let activeID = captureEngine.activeObjectID {
            if let captured = captureEngine.capturedObjectsByID[activeID],
               let distance = sessionManager.cameraDistanceMetres(to: captured.center) {
                return distance
            }
            if let marker = captureEngine.objectMaskMarkers.first(where: { $0.id == activeID }) {
                return Double(marker.cameraDistance)
            }
            if let layer = captureEngine.objectMaskPreview?.layers.first(where: {
                $0.trackedObjectID == activeID
            }), let distance = layer.referenceCameraDistance {
                return Double(distance)
            }
        }

        return liveMeasurementCandidateLayer?.referenceCameraDistance.map(Double.init)
    }

    private var isTooCloseForMeasurement: Bool {
        MeasurementFramingRule.isTooClose(
            distanceMetres: estimatedCameraToObjectCentreDistanceMetres
        )
    }

    private var measurementDistanceGuidance: MeasurementFramingRule.Guidance {
        MeasurementFramingRule.guidance(
            distanceMetres: estimatedCameraToObjectCentreDistanceMetres
        )
    }

    private var automaticMeasurementCandidate: AutomaticMeasurementCandidate? {
        guard isAutomaticCaptureSupported,
              showsLiveOverlay,
              !showsPanel,
              captureEngine.activeObjectID == nil,
              !captureEngine.isObjectSelectionPending,
              finalizedMeasuredObjectIDs.count < 15,
              !captureEngine.isPointingAtFinishedObject,
              sessionManager.isTrackingReady,
              sessionManager.isObjectTrackingEnvironmentReady,
              captureEngine.hasCompletedObjectRecognitionWarmup,
              workflowMode == .spatial3D || captureEngine.isTopViewAligned,
              measurementDistanceGuidance == .ready,
              let layer = liveMeasurementCandidateLayer else {
            return nil
        }
        let point = layer.referenceAnchorPoint
            ?? layer.referenceViewportBoundingBox.map {
                CGPoint(x: $0.midX, y: $0.midY)
            }
            ?? CGPoint(x: 0.5, y: 0.5)
        return AutomaticMeasurementCandidate(id: layer.id, point: point)
    }

    private var measurementInstruction: MeasurementInstruction {
        if isPreparingToMeasure { return .preparing }
        if captureEngine.isObjectSelectionPending {
            return .holdStill
        }
        if automaticMeasurementCandidate != nil { return .readyToMeasure }
        if captureEngine.activeObjectID != nil {
            switch measurementDistanceGuidance {
            case .moveFarther: return .moveFarther
            case .moveCloser: return .moveCloser
            case .ready, .unavailable:
                if workflowMode == .top, !captureEngine.isTopViewAligned {
                    return .pointDown
                }
                switch captureEngine.convergence.limitingFactor {
                case .waitingForSupportPlane: return .findSurface
                case .needsTopView: return .pointDown
                case .needsSideView: return .useSideView
                default: return .holdStill
                }
            }
        }
        if captureEngine.isPointingAtFinishedObject {
            return .findNextObject
        }
        switch measurementDistanceGuidance {
        case .moveFarther: return .moveFarther
        case .moveCloser: return .moveCloser
        case .ready:
            if workflowMode == .top, !captureEngine.isTopViewAligned {
                return .pointDown
            }
            return finalizedMeasuredObjectIDs.isEmpty ? .findObject : .findNextObject
        case .unavailable:
            return finalizedMeasuredObjectIDs.isEmpty ? .findObject : .findNextObject
        }
    }

    private var measurementInstructionTitle: String {
        switch measurementInstruction {
        case .preparing: "Getting ready"
        case .findObject: "Look for an object"
        case .findNextObject: "Look for the next object"
        case .moveFarther: "Move farther away"
        case .moveCloser: "Move closer"
        case .readyToMeasure: "Ready to measure"
        case .holdStill: "DON’T MOVE"
        case .pointDown: "Point straight down"
        case .useSideView: "Use a side view"
        case .findSurface: "Find the surface"
        }
    }

    private var measurementInstructionDetail: String {
        let distance = estimatedCameraToObjectCentreDistanceMetres.map {
            " Estimated distance: \(Int(($0 * 100).rounded())) cm."
        } ?? ""
        switch measurementInstruction {
        case .preparing:
            return "The app is preparing the camera and object recognition."
        case .findObject:
            return workflowMode == .top
                ? "Aim at one complete object from above and point the phone straight down."
                : "Aim at one complete object and keep it fully visible."
        case .findNextObject:
            return "Aim at the next unmeasured object and keep it fully visible."
        case .moveFarther:
            return "The phone is too close. Move back toward 40–50 cm.\(distance)"
        case .moveCloser:
            return "The phone is too far away. Move toward the object until 40–50 cm.\(distance)"
        case .readyToMeasure:
            return "Keep the complete object visible, then tap Measure to begin."
        case .holdStill:
            return captureEngine.activeObjectID == nil
                ? "Distance is correct. Hold the phone still while the app starts measuring."
                : "Hold the phone steady while the app collects and stabilises the measurement."
        case .pointDown:
            if let degrees = captureEngine.topViewDeviationDegrees {
                return "Hold the phone above the object with the camera facing the floor. \(degrees)° to go."
            }
            return "Hold the phone above the object with the camera facing the floor."
        case .useSideView:
            return "Move to an isometric or lateral view while keeping the complete object visible."
        case .findSurface:
            return "Sweep slowly across the table beneath the object so the app can confirm its support."
        }
    }

    private var measurementInstructionColor: Color {
        switch measurementInstruction {
        case .holdStill: .red
        case .moveCloser, .moveFarther: .orange
        case .pointDown, .useSideView, .findSurface: .yellow
        case .readyToMeasure: .green
        case .findObject, .findNextObject: .blue
        case .preparing: .secondary
        }
    }

    private var measurementInstructionIcon: String {
        switch measurementInstruction {
        case .preparing: "camera.aperture"
        case .findObject, .findNextObject: "viewfinder"
        case .moveFarther: "arrow.up.left.and.arrow.down.right"
        case .moveCloser: "arrow.down.right.and.arrow.up.left"
        case .readyToMeasure: "ruler"
        case .holdStill: "hand.raised.fill"
        case .pointDown: "arrow.down.to.line"
        case .useSideView: "arrow.right.to.line"
        case .findSurface: "square.dashed"
        }
    }

    private var measurementInstructionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: measurementInstructionIcon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(
                    measurementInstruction == .holdStill
                        ? Color.white
                        : measurementInstructionColor
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(measurementInstructionTitle)
                    .font(.headline)
                    .foregroundStyle(measurementInstruction == .holdStill ? .white : .primary)
                Text(measurementInstructionDetail)
                    .font(.caption)
                    .foregroundStyle(
                        measurementInstruction == .holdStill
                            ? Color.white.opacity(0.9)
                            : Color.secondary
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(
            measurementInstruction == .holdStill
                ? Color.red.opacity(0.92)
                : measurementInstructionColor.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Bottom status

    @ViewBuilder
    private var bottomStatusCard: some View {
        if isPreparingToMeasure {
            startupStatusBanner
        } else if workflowMode == .top {
            topCaptureGuide
        } else if isAutomaticCaptureSupported,
                  captureEngine.activeObjectID != nil {
            faceCaptureGuide
        } else {
            captureReadout
        }
    }

    /// Only objects still being worked on. A finished object already has its box drawn in the scene,
    /// and a dot on top of it just adds clutter — the engine still keeps the marker, because that is
    /// how it knows whether a saved object is on screen and can be remeasured.
    private var liveObjectMaskMarkers: [ObjectMaskMarker] {
        captureEngine.objectMaskMarkers.filter {
            !captureEngine.finalizedObjectIDs.contains($0.id)
        }
    }

    @ViewBuilder
    private var objectMaskMarkers: some View {
        if captureEngine.showsObjectMaskMarkers,
           !liveObjectMaskMarkers.isEmpty {
            GeometryReader { proxy in
                ForEach(liveObjectMaskMarkers) { marker in
                    let color = Color(
                        red: marker.color.red,
                        green: marker.color.green,
                        blue: marker.color.blue
                    )
                    ZStack {
                        Circle()
                            .fill(color.opacity(0.9))
                        Circle()
                            .stroke(.white.opacity(0.9), lineWidth: 2)
                        Circle()
                            .fill(.white)
                            .frame(width: 6, height: 6)
                    }
                    .frame(width: 24, height: 24)
                    .position(
                        x: marker.normalizedViewportPoint.x * proxy.size.width,
                        y: marker.normalizedViewportPoint.y * proxy.size.height
                    )
                    .shadow(color: color.opacity(0.65), radius: 5)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var faceCaptureGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(captureEngine.primaryText == "--"
                    ? "Measuring"
                    : captureEngine.primaryText)
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Spacer(minLength: 4)

                faceCoverageChip(
                    "arrow.down.to.line",
                    isActive: captureEngine.scanViewHint == .topDown,
                    isDone: captureEngine.footprintSatisfied
                )
                faceCoverageChip(
                    "arrow.right.to.line",
                    isActive: captureEngine.scanViewHint == .side,
                    isDone: captureEngine.heightSatisfied
                )
            }

            measuringProgress
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(faceCoverageAccessibilityLabel)
    }

    private func faceCoverageChip(
        _ icon: String,
        isActive: Bool,
        isDone: Bool
    ) -> some View {
        Image(systemName: isDone ? "checkmark" : icon)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(isDone ? .green : (isActive ? .yellow : .secondary))
            .frame(width: 24, height: 20)
            .background(
                isDone
                    ? Color.green.opacity(0.16)
                    : (isActive ? Color.yellow.opacity(0.18) : Color.primary.opacity(0.06)),
                in: Capsule()
            )
    }

    private var faceCoverageAccessibilityLabel: String {
        let top = captureEngine.footprintSatisfied ? "captured" : "still needed"
        let side = captureEngine.heightSatisfied ? "captured" : "still needed"
        return "\(captureEngine.primaryText). Top view \(top). Isometric or side view \(side). \(measuringTitle)"
    }

    private var topCaptureGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: topGuideSystemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(topGuideColor)
                Text(topGuideHeadline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(topGuideColor)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if captureEngine.activeObjectID != nil,
                   captureEngine.primaryText != "--" {
                    Text(captureEngine.primaryText)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            if captureEngine.activeObjectID == nil {
                Text(topGuideDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            measuringProgress
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// How far along the measurement is, and what to do about it, as one thing instead of two.
    ///
    /// It used to be a thin bar with a percentage beside it and a separate "move closer" chip
    /// underneath. Two rows, both easy to miss, often saying the same thing. This is a ring with the
    /// percentage in the middle and a single instruction next to it, and it is the only place the
    /// distance advice appears.
    @ViewBuilder
    private var measuringProgress: some View {
        let convergence = captureEngine.convergence
        if convergence.isActive || measuringGuidance != nil {
            HStack(spacing: 14) {
                progressRing(convergence.isActive ? convergence.progress : nil)

                VStack(alignment: .leading, spacing: 2) {
                    Text(measuringTitle)
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(measuringColor)
                    Text(measuringAdvice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(.top, 2)
            .animation(.easeInOut(duration: 0.2), value: measuringTitle)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(measuringTitle)
            .accessibilityValue(measuringAdvice)
        }
    }

    /// Nil hides the number, which is what happens before there is anything to be a percentage of.
    private func progressRing(_ progress: Double?) -> some View {
        let clamped = min(max(progress ?? 0, 0), 1)
        return ZStack {
            Circle()
                .stroke(.white.opacity(0.22), lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(clamped, 0.001))
                .stroke(
                    measuringColor,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: clamped)
            if progress != nil {
                Text("\(Int((clamped * 100).rounded()))")
                    .font(.system(.subheadline, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            } else {
                Image(systemName: measuringIcon)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(measuringColor)
            }
        }
        .frame(width: 52, height: 52)
    }

    /// Distance advice, but only once a measurement is under way — before that the object is not
    /// being tracked and any advice would be guesswork.
    private var measuringGuidance: ObjectFramingGuidance? {
        guard captureEngine.activeObjectID != nil else { return nil }
        switch measurementDistanceGuidance {
        case .moveFarther:
            return .moveFarther
        case .moveCloser:
            return .moveCloser
        case .ready, .unavailable:
            // Keep centring advice, but do not turn screen occupancy back into a distance rule.
            return captureEngine.framingGuidance == .centre ? .centre : nil
        }
    }

    /// Distance first, because nothing else can be judged from the wrong distance; after that it is
    /// whatever the stopping rule is actually waiting for. Width and depth are only measured looking
    /// down and height only from the side, so a measurement can sit at the same percentage for a long
    /// time purely because the phone has not been where it needs to be — and saying "hold steady"
    /// then is worse than saying nothing.
    private var measuringTitle: String {
        switch measuringGuidance {
        case .moveCloser: "Move closer"
        case .moveFarther: "Move farther away"
        case .centre: "Aim at it"
        default:
            switch captureEngine.convergence.limitingFactor {
            case .needsTopView: "Point down at it"
            case .needsSideView: "Use a 3/4 or side view"
            case .waitingForSupportPlane: "Find the surface"
            case .converged: "Size settled"
            default: "Hold steady"
            }
        }
    }

    private var measuringAdvice: String {
        switch measuringGuidance {
        case .moveCloser: "Move toward the object until the phone is 40–50 cm away."
        case .moveFarther: "Move back until the phone is 40–50 cm away."
        case .centre: "The object runs off the edge. Point at the middle of it."
        default:
            switch captureEngine.convergence.limitingFactor {
            case .needsTopView:
                "Its width and length are measured from above. Hold the phone over it, pointing straight down."
            case .needsSideView:
                "Its height is measured from an isometric or lateral view. Lower the phone and keep the whole object visible."
            case .waitingForSupportPlane:
                "Sweep across the table under the object so the floor it stands on is known."
            case .converged:
                "The reading has stopped changing. You can finish."
            default:
                captureEngine.convergence.detail
            }
        }
    }

    private var measuringIcon: String {
        switch measuringGuidance {
        case .moveCloser: "arrow.down.right.and.arrow.up.left"
        case .moveFarther: "arrow.up.left.and.arrow.down.right"
        case .centre: "viewfinder"
        default:
            switch captureEngine.convergence.limitingFactor {
            case .needsTopView: "arrow.down.to.line"
            case .needsSideView: "arrow.right.to.line"
            case .waitingForSupportPlane: "square.dashed"
            case .converged: "checkmark"
            default: "dot.viewfinder"
            }
        }
    }

    private var measuringColor: Color {
        switch measuringGuidance {
        case .moveCloser, .moveFarther, .centre: .orange
        default:
            switch captureEngine.convergence.limitingFactor {
            case .needsTopView, .needsSideView, .waitingForSupportPlane: .yellow
            case .converged: .green
            default: .white
            }
        }
    }

    private var topGuideColor: Color {
        captureEngine.topMeasurementStable || captureEngine.isTopViewAligned
            ? .green
            : .red
    }

    private var topGuideSystemImage: String {
        if captureEngine.topMeasurementStable {
            return "checkmark.seal.fill"
        }
        return captureEngine.isTopViewAligned
            ? "checkmark.circle.fill"
            : "iphone.gen3.radiowaves.left.and.right"
    }

    private var topGuideHeadline: String {
        if captureEngine.topMeasurementStable {
            return "Top fit ready"
        }
        if captureEngine.isTopViewAligned {
            return "Top view aligned"
        }
        if let degrees = captureEngine.topViewDeviationDegrees {
            return "Point straight down · \(degrees)° off"
        }
        return "Point straight down"
    }

    private var topGuideDetail: String {
        if captureEngine.activeObjectID == nil {
            return captureEngine.isTopViewAligned
                ? "Hold this angle. At 40–50 cm, tap Measure when it appears."
                : "Hold the phone above the object with the camera facing the floor."
        }
        if captureEngine.topMeasurementStable {
            return "The overhead fit is stable. Keep still while measurement completes."
        }
        return captureEngine.isTopViewAligned
            ? "Hold still while the overhead points converge."
            : "Tilt toward vertical. Collection pauses until the angle is correct."
    }
    private var startupStatusBanner: some View {
        let isEnvironmentReady = sessionManager.isObjectTrackingEnvironmentReady
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(isEnvironmentReady
                    ? "Preparing object recognition"
                    : sessionManager.environmentReadiness.title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }

            Text(isEnvironmentReady
                ? "Almost ready. Keep the payload area in view."
                : sessionManager.environmentReadiness.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                startupStep(
                    "Reading the room",
                    isDone: isEnvironmentReady
                )
                startupStep(
                    "Object recognition",
                    isDone: captureEngine.hasCompletedObjectRecognitionWarmup
                )
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    private func startupStep(_ title: String, isDone: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isDone ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isDone ? .green : .secondary)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(isDone ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            isDone ? Color.green.opacity(0.14) : Color.primary.opacity(0.06),
            in: Capsule()
        )
    }

    @ViewBuilder
    private var objectMaskInteractionLayer: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            // LiDAR studies use the explicit Measure button after the 40–50 cm
                            // preflight. Direct tapping remains only for the RGB fallback, which has
                            // no depth-derived readiness state.
                            guard !isAutomaticCaptureSupported else { return }
                            guard captureEngine.activeObjectID == nil,
                                  !captureEngine.isObjectSelectionPending else {
                                return
                            }
                            guard sessionManager.isTrackingReady,
                                  sessionManager.isObjectTrackingEnvironmentReady else {
                                captureEngine.reportObjectSelectionNotReady()
                                return
                            }
                            guard captureEngine.hasCompletedObjectRecognitionWarmup else {
                                captureEngine.reportObjectRecognitionPreparing()
                                return
                            }
                            guard
                                  proxy.size.width > 0,
                                  proxy.size.height > 0 else {
                                return
                            }
                            captureEngine.requestObjectMaskToggle(
                                at: CGPoint(
                                    x: value.location.x / proxy.size.width,
                                    y: value.location.y / proxy.size.height
                                )
                            )
                        }
                )
                .accessibilityLabel(
                    isAutomaticCaptureSupported
                        ? "Object detection area"
                    : captureEngine.activeObjectID == nil
                        ? "Tap an object to select it for measurement"
                        : "Current object selected for measurement"
                )
                .accessibilityHint(
                    isAutomaticCaptureSupported
                        ? "Keep an unmeasured object in view at 40 to 50 centimetres."
                    : captureEngine.activeObjectID == nil
                        ? "Only one object can be measured at a time."
                        : "Wait for the current object to finish before selecting another."
                )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var objectMaskPreview: some View {
        if            let preview = captureEngine.objectMaskPreview {
            ZStack {
                ForEach(preview.layers, id: \.id) { layer in
                    if let trackedObjectID = layer.trackedObjectID {
                        if captureEngine.showsSelectedObjectMaskPreview,
                           captureEngine.activeObjectID == trackedObjectID,
                           !captureEngine.finalizedObjectIDs.contains(trackedObjectID),
                           let marker = captureEngine.objectMaskMarkers.first(where: {
                               $0.id == trackedObjectID
                           }) {
                            trackedObjectMaskPreview(
                                layer,
                                marker: marker,
                                currentBoundingBox: captureEngine
                                    .objectMaskDisplayBoundingBoxes[layer.id]
                            )
                        }
                    } else if captureEngine.showsLiveMaskPreview {
                        trackedObjectMaskPreview(
                            layer,
                            marker: nil,
                            currentBoundingBox: captureEngine
                                .objectMaskDisplayBoundingBoxes[layer.id]
                        )
                    }
                }
            }
        }
    }

    private func trackedObjectMaskPreview(
        _ layer: ObjectMaskPreviewLayer,
        marker: ObjectMaskMarker?,
        currentBoundingBox: CGRect?
    ) -> some View {
        GeometryReader { proxy in
            let referencePoint = layer.referenceAnchorPoint ?? CGPoint(x: 0.5, y: 0.5)
            let currentPoint = marker?.normalizedViewportPoint ?? referencePoint
            let trackedTransform: (
                xOffset: CGFloat,
                yOffset: CGFloat
            )? = {
                guard let reference = layer.referenceViewportBoundingBox,
                      let current = currentBoundingBox,
                      reference.width >= 0.005,
                      reference.height >= 0.005,
                      current.width >= 0.005,
                      current.height >= 0.005 else {
                    return nil
                }
                return (
                    (current.midX - reference.midX) * proxy.size.width,
                    (current.midY - reference.midY) * proxy.size.height
                )
            }()
            let xOffset = trackedTransform?.xOffset
                ?? (currentPoint.x - referencePoint.x) * proxy.size.width
            let yOffset = trackedTransform?.yOffset
                ?? (currentPoint.y - referencePoint.y) * proxy.size.height

            ZStack {
                Image(decorative: layer.image, scale: 1, orientation: .up)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .offset(
                        x: xOffset,
                        y: yOffset
                    )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var infoPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
            // Reset is destructive enough that it belongs behind this deliberate information view,
            // rather than alongside the participant's measuring controls.
            testingControls

            // Abandoning the run is the operator's decision, never the participant's, so it is behind
            // the study password like every other way out of a payload.
            Button {
                showsCancelRunPassword = true
            } label: {
                Label("Cancel the run", systemImage: "xmark.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
            }
            .accessibilityHint("Asks for the study password, then returns to the start screen.")

            HStack(spacing: 10) {
                Circle()
                    .fill(environmentStatusColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: environmentStatusColor.opacity(0.55), radius: 4)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Payload Measure")
                        .font(.headline)
                    Text(sessionManager.environmentReadiness.title)
                        .font(.caption2)
                        .foregroundStyle(environmentStatusColor)
                }

                Spacer(minLength: 12)

                Button {
                    showsPanel = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close information")
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Measurement method")
                    .font(.caption.weight(.semibold))
                Picker("Measurement method", selection: workflowModeSelection) {
                    ForEach(MeasurementWorkflowMode.allCases) { mode in
                        Text(mode.shortTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Measurement method")

                if !isAutomaticCaptureSupported {
                    Text("Top Fit requires LiDAR and is unavailable on this device.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Text(workflowMode.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("Measurement finishes automatically when every dimension is stable, the required viewpoints have been captured, and ARKit has confirmed the supporting surface.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                Text("Current step")
                    .font(.caption.weight(.semibold))
                Text(scanStatusText)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                DisclosureGroup("Scan visuals") {
                    VStack(alignment: .leading, spacing: 9) {
                        visualToggleButton(
                            title: "Mask",
                            systemImage: "viewfinder",
                            isVisible: captureEngine.showsSegmentationOverlays,
                            action: captureEngine.toggleSegmentationOverlays
                        )
                        visualToggleButton(
                            title: "Points",
                            systemImage: "circle.grid.3x3.fill",
                            isVisible: captureEngine.showsSelectedPoints,
                            action: captureEngine.toggleSelectedPoints
                        )
                        visualToggleButton(
                            title: "Box",
                            systemImage: "cube.transparent",
                            isVisible: captureEngine.showsBoundingBoxes,
                            action: captureEngine.toggleBoundingBoxes
                        )
                    }
                    .padding(.top, 7)
                }
                .accessibilityHint("Shows or hides measurement overlays on the camera view.")

                Divider()

                Text(sessionManager.trackingStatus.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup(
                    "Tracking details",
                    isExpanded: $showsTrackingDetails
                ) {
                    VStack(alignment: .leading, spacing: 5) {
                        if isAutomaticCaptureSupported {
                            statusLine("Depth", sessionManager.depthStatusText)
                            statusLine("Depth map", sessionManager.sceneDepthResolutionText)
                            statusLine("Object cloud", "5 mm confirmed voxels")
                            statusLine("Mesh", sessionManager.sceneReconstructionStatusText)
                        }
                        statusLine("Planes", sessionManager.planeStatusText)
                        statusLine("Tracking", sessionManager.trackingHardwareText)
                        statusLine("Map", sessionManager.worldMappingStatusText)
                    }
                    .padding(.top, 5)
                }
            }
            .font(.caption)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, maxHeight: 430, alignment: .topLeading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
    }

    private var captureReadout: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(scanStatusHeadline)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)

                    if !sessionManager.isLiDARAvailable {
                        Button {
                            showsLiDARLimitations = true
                        } label: {
                            Label("No LiDAR", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 6)
                                .frame(height: 20)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                        .background(.orange.opacity(0.14), in: Capsule())
                        .accessibilityLabel("No LiDAR. Show RGB-only limitations")
                    }
                }

                Text(scanPrimaryText)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var scanStatusHeadline: String {
        if captureEngine.activeObjectID != nil {
            return "Measuring selected object"
        }

        let count = captureEngine.finalizedObjectIDs.count
        if count > 0 {
            return "\(count) object\(count == 1 ? "" : "s") measured"
        }

        if isAutomaticCaptureSupported {
            return captureEngine.statusHeadline
        }

        return captureEngine.hasObjectMaskPreview ? "Object detected" : "Finding object"
    }

    private var scanPrimaryText: String {
        if isAutomaticCaptureSupported {
            return captureEngine.primaryText
        }

        if captureEngine.activeObjectID != nil {
            return "Selected RGB object"
        }

        let count = captureEngine.finalizedObjectIDs.count
        if count > 0 {
            return "\(count) measured RGB object\(count == 1 ? "" : "s")"
        }

        return captureEngine.hasObjectMaskPreview ? "RGB object detected" : "--"
    }

    private var scanStatusText: String {
        if let feedback = captureEngine.objectMaskFeedbackText {
            return feedback
        }

        if isAutomaticCaptureSupported {
            if captureEngine.activeObjectID != nil {
                if workflowMode == .top {
                    return "\(captureEngine.statusText) Hold the phone above it and point straight down; the fit uses world-space points, not the tilted camera image."
                }
                return "\(captureEngine.statusText) Only this object is being measured. Capture the requested views, then hold still while it finishes automatically."
            }
            if !captureEngine.finalizedObjectIDs.isEmpty {
                return "\(captureEngine.statusText) Finished measurements stay fixed. Aim at the next object and tap Measure at 40–50 cm."
            }
            return "\(captureEngine.statusText) Aim at a highlighted object and tap Measure at 40–50 cm."
        }

        if captureEngine.activeObjectID != nil {
            return "Only the selected object is active. Wait for it to finish before selecting another."
        }

        if !captureEngine.finalizedObjectIDs.isEmpty {
            return "Finished objects stay fixed. Point at another colored preview and tap to select it."
        }

        return "Center an object to preview its color, then tap it to start measuring."
    }

    private var workflowModeSelection: Binding<MeasurementWorkflowMode> {
        Binding(
            get: { workflowMode },
            set: requestWorkflowModeChange(to:)
        )
    }

    private func requestWorkflowModeChange(to mode: MeasurementWorkflowMode) {
        guard mode != workflowMode else {
            return
        }
        guard mode != .top || isAutomaticCaptureSupported else {
            showsLiDARLimitations = true
            return
        }
        guard captureEngine.canReset else {
            workflowMode = mode
            return
        }
        pendingWorkflowMode = mode
        showsModeChangeConfirmation = true
    }

    // MARK: - Bottom actions

    @ViewBuilder
    private var bottomActionRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ViewThatFits(in: .horizontal) {
                accessibilityActionRow(showsTitles: true)
                accessibilityActionRow(showsTitles: false)
            }
        } else {
            // Every button here is optional, so the row's width swings a lot. Rather than let it
            // run off the edge of the phone, drop the labels when the full set will not fit.
            ViewThatFits(in: .horizontal) {
                actionRow(showsTitles: true)
                actionRow(showsTitles: false)
            }
        }
    }

    private func accessibilityActionRow(showsTitles: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            cancelMeasurementButton(showsTitle: showsTitles)
        }
    }

    private func actionRow(showsTitles: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            cancelMeasurementButton(showsTitle: showsTitles)
        }
    }

    private var measureButton: some View {
        Button {
            guard let candidate = automaticMeasurementCandidate else { return }
            showsSavedObjects = false
            captureEngine.requestObjectMaskToggle(at: candidate.point)
        } label: {
            Label("Measure", systemImage: "ruler.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color.green, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Starts measuring the object currently in view.")
    }

    private var activeMeasurementProgressCard: some View {
        let progress = min(max(captureEngine.convergence.progress, 0), 1)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("MEASURING", systemImage: "waveform.path.ecg")
                    .font(.headline.weight(.heavy))
                Spacer()
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.headline.monospacedDigit().weight(.bold))
            }
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(.white)
                .scaleEffect(y: 1.8)
            Text(captureEngine.convergence.detail)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Measuring progress")
        .accessibilityValue("\(Int((progress * 100).rounded())) percent")
    }

    /// Shown over the live camera until the environment is ready. The camera is deliberately visible
    /// behind it: the instruction is something to do *with* the camera, and watching the scene move
    /// is what tells the operator the phone is actually working.
    @ViewBuilder
    private var preparingPrompt: some View {
        if isPreparingToMeasure, !showsPanel {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Getting ready")
                    .font(.headline)
                Text(preparingInstruction)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Measuring unlocks by itself when this finishes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: 330)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }

    private var preparingInstruction: String {
        if !sessionManager.isObjectTrackingEnvironmentReady {
            return "Point the phone at the table and move it slowly from side to side, so it can find the surface the objects are standing on."
        }
        return "Object detection is warming up. Keep the objects in view."
    }

    /// Shown while the phone is not level enough to measure. Nothing else appears until it is.
    @ViewBuilder
    private var levellingPrompt: some View {
        if isAutomaticCaptureSupported,
           captureEngine.activeObjectID == nil,
           !showsPanel,
           !isPreparingToMeasure,
           workflowMode == .top,
           !captureEngine.isTopViewAligned {
            VStack(spacing: 10) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 34, weight: .light))
                    .symbolEffect(.pulse)
                Text("Hold the phone flat over the object")
                    .font(.headline)
                if let degrees = captureEngine.topViewDeviationDegrees {
                    Text("\(degrees)° to go")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
            .accessibilityElement(children: .combine)
        }
    }

    /// Sized by its content, never by a hard width, so a row of these can shrink instead of being
    /// clipped by the screen.
    private func actionLabel(
        _ title: String,
        systemImage: String,
        tint: Color,
        showsTitle: Bool,
        isCompact: Bool = false
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            if showsTitle {
                Text(title)
                    .foregroundStyle(.primary)
            }
        }
        .font((isCompact ? Font.caption : Font.body).weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, showsTitle ? 15 : 0)
        .frame(
            minWidth: showsTitle
                ? (dynamicTypeSize.isAccessibilitySize ? 96 : 74)
                : (dynamicTypeSize.isAccessibilitySize ? 56 : 48),
            minHeight: dynamicTypeSize.isAccessibilitySize ? 56 : (isCompact ? 44 : 50)
        )
        .contentShape(Capsule())
    }

    /// Only offered while a measurement is running, and it discards that measurement outright.
    ///
    /// Withheld for the first seconds of one. Offered from the first frame, it was pressed while the
    /// measurement was still normally getting started, which taught cancelling instead of holding the
    /// phone still — and a measurement that really is not starting is restarted by the app before this
    /// button appears at all.
    @ViewBuilder
    private func cancelMeasurementButton(showsTitle: Bool) -> some View {
        if isAutomaticCaptureSupported, captureEngine.activeObjectID != nil {
            if captureEngine.canCancelActiveMeasurement {
                Button {
                    showsSavedObjects = false
                    captureEngine.cancelActiveMeasurement()
                } label: {
                    actionLabel(
                        "Cancel measurement",
                        systemImage: "xmark",
                        tint: .red,
                        showsTitle: showsTitle
                    )
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Cancel measurement")
                .accessibilityHint("Discards this measurement and deselects the object.")
            } else if let countdown = MeasurementStartRule.cancelCountdown(
                secondsActive: captureEngine.secondsSinceMeasurementStarted
            ) {
                actionLabel(
                    "Cancel in \(countdown) s",
                    systemImage: "clock",
                    tint: .secondary,
                    showsTitle: showsTitle
                )
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .glassEffect(.regular, in: .capsule)
                .accessibilityLabel("Cancel becomes available in \(countdown) seconds")
            }
        }
    }

    private func resetButton(showsTitle: Bool) -> some View {
        Button {
            showsResetConfirmation = true
        } label: {
            actionLabel(
                "Reset",
                systemImage: "arrow.counterclockwise",
                tint: .red,
                showsTitle: showsTitle,
                isCompact: true
            )
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Reset all measurements")
        .accessibilityHint("Asks for confirmation before clearing every object and measurement.")
    }

    private var finalizedMeasuredObjectIDs: [UUID] {
        captureEngine.measuredObjectIDs.filter {
            captureEngine.finalizedObjectIDs.contains($0)
        }
    }

    private var savedObjectsButton: some View {
        Button {
            showsSavedObjects.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.green)
                Text("\(finalizedMeasuredObjectIDs.count)")
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Image(systemName: showsSavedObjects ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .frame(
                width: dynamicTypeSize.isAccessibilitySize ? 96 : 74,
                height: dynamicTypeSize.isAccessibilitySize ? 52 : 44
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
        .accessibilityLabel(
            "\(finalizedMeasuredObjectIDs.count) saved object\(finalizedMeasuredObjectIDs.count == 1 ? "" : "s")"
        )
        .accessibilityValue(showsSavedObjects ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows names, outer-box choices, packed weights and actions for measured objects.")
    }

    // MARK: - Saved objects

    private var savedObjectsPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("Saved objects", systemImage: "shippingbox.fill")
                    .font(.subheadline.weight(.semibold))

                Text("\(finalizedMeasuredObjectIDs.count)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Button {
                    showsSavedObjects = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close saved objects")
            }

            if captureEngine.activeObjectID != nil {
                Text("Wait for the current measurement to finish before selecting a saved object.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView(.vertical) {
                LazyVStack(spacing: 8) {
                    ForEach(finalizedMeasuredObjectIDs, id: \.self) { id in
                        savedObjectRow(for: id)
                    }
                }
            }
            .scrollIndicators(
                finalizedMeasuredObjectIDs.count > 3
                    || dynamicTypeSize.isAccessibilitySize
                    ? .visible
                    : .hidden
            )
            .frame(height: savedObjectsListHeight)

        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }

    private var startPackingSection: some View {
        Button {
            showsSavedObjects = false
            showsPackingConfirmation = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox.fill")
                Text("Start packing")
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Color.accentColor, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start packing")
        .accessibilityHint("Confirms every object was scanned, then opens the untimed packing start screen.")
    }

    private func savedObjectRow(for id: UUID) -> some View {
        let isFocused = captureEngine.focusedObjectID == id
        let canSelect = captureEngine.activeObjectID == nil
            && !captureEngine.isObjectSelectionPending
        let objectName = captureEngine.name(for: id) ?? "Unnamed object"
        let doesNotFitAvailableBoxes = packingStore
            .fittingBoxPresets(for: id, in: captureEngine)
            .isEmpty

        return HStack(spacing: 4) {
            Button {
                captureEngine.focusCapture(id: id)
            } label: {
                HStack(spacing: 9) {
                    boxColorImage(for: id)
                        .font(.system(size: 12))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(objectName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                            .truncationMode(.tail)

                        Text(objectPreparationSummary(for: id))
                            .font(.caption)
                            .foregroundStyle(
                                doesNotFitAvailableBoxes ? Color.orange : Color.secondary
                            )
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: isFocused ? "checkmark.circle.fill" : "scope")
                        .foregroundStyle(isFocused ? .green : .secondary)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: savedObjectRowHeight,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSelect)
            .opacity(canSelect ? 1 : 0.55)
            .accessibilityLabel(
                "\(objectName), \(objectPreparationSummary(for: id))"
            )
            .accessibilityValue(isFocused ? "Selected" : "Not selected")
            .accessibilityHint(
                canSelect
                    ? "Selects this object for viewing or editing."
                    : "Wait for the active object to finish before selecting this one."
            )

            Button {
                showsSavedObjects = false
                presentDetailsEditor(for: id)
            } label: {
                Image(systemName: "pencil")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel("Rename \(objectName)")
            .accessibilityHint("Changes this object's name.")

            Button(role: .destructive) {
                pendingRemovalObjectID = id
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(captureEngine.isObjectSelectionPending)
            .opacity(captureEngine.isObjectSelectionPending ? 0.45 : 1)
            .accessibilityLabel(
                "Remove \(captureEngine.name(for: id) ?? "unnamed object")"
            )
            .accessibilityHint(
                captureEngine.isObjectSelectionPending
                    ? "Wait for the current object selection to finish."
                    : "Asks for confirmation before removing this object."
            )
        }
        .padding(.horizontal, 10)
        .background(.primary.opacity(0.07), in: .rect(cornerRadius: 14))
    }

    private var savedObjectsListHeight: CGFloat {
        let count = finalizedMeasuredObjectIDs.count
        guard count > 0 else { return 0 }
        let rowsHeight = CGFloat(count) * savedObjectRowHeight
        let spacingHeight = CGFloat(max(count - 1, 0)) * 8
        let maximumHeight: CGFloat = dynamicTypeSize.isAccessibilitySize ? 300 : 204
        return min(rowsHeight + spacingHeight, maximumHeight)
    }

    private var savedObjectRowHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 116 : 52
    }

    private func objectPreparationSummary(for id: UUID) -> String {
        if packingStore.fittingBoxPresets(for: id, in: captureEngine).isEmpty {
            return packingStore.isExcludedBecauseNoStockedBoxFits(id, in: captureEngine)
                ? "Excluded — does not fit available boxes"
                : "Does not fit available boxes"
        }
        let boxName = packingStore.selectedBoxPreset(for: id)?.name
            ?? "Choose outer box"
        let weight = captureEngine.weightInGrams(for: id)
            .flatMap { PositiveDecimalText.format($0, maximumFractionDigits: 3) }
            .map { "\($0) g" }
            ?? "Enter packed weight"
        return "\(boxName) · \(weight)"
    }

    private var objectDetailsIsPresented: Binding<Bool> {
        Binding(
            get: {
                guard let context = objectDetailsContext else {
                    return false
                }
                switch context {
                case .finalize(let id):
                    return captureEngine.finalizedObjectIDs.contains(id)
                case .edit:
                    return true
                }
            },
            set: { isPresented in
                if !isPresented {
                    cancelObjectDetailsEntry()
                }
            }
        )
    }

    private var automaticLockBinding: Binding<Bool> {
        Binding(
            get: { captureEngine.isAutomaticLockEnabled },
            set: { captureEngine.setAutomaticLockEnabled($0) }
        )
    }

    private var removalConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: {
                pendingRemovalObjectID != nil
            },
            set: { isPresented in
                if !isPresented {
                    pendingRemovalObjectID = nil
                }
            }
        )
    }

    private var trimmedObjectName: String {
        objectNameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var objectDetailsMessage: String {
        guard case .finalize = objectDetailsContext else {
            return "Enter the name the operator should see during packing."
        }
        return "Measurement saved. Add a short name you will recognise during packing."
    }

    private var objectDetailsTitle: String {
        guard let objectDetailsContext else {
            return "Object details"
        }
        switch objectDetailsContext {
        case .finalize:
            return "Object measured"
        case .edit:
            return "Edit object"
        }
    }

    private var removalConfirmationTitle: String {
        guard let id = pendingRemovalObjectID else {
            return "Remove object?"
        }
        guard let name = captureEngine.name(for: id),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Remove unnamed object?"
        }
        return "Remove \(name)?"
    }

    private func presentAutomaticLockIfRequested() {
        guard let id = captureEngine.automaticLockRequest,
              captureEngine.activeObjectID == id,
              sessionManager.isTrackingReady,
              sessionManager.isObjectTrackingEnvironmentReady,
              !isTooCloseForMeasurement else {
            return
        }
        showsSavedObjects = false
        showsPanel = false
        guard captureEngine.lockActiveObject() != nil else {
            return
        }
        lockFeedback.notificationOccurred(.success)
    }

    private func presentPendingDetailsSheet() async {
        guard let id = pendingDetailsObjectID else {
            return
        }
        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled,
              captureEngine.finalizedObjectIDs.contains(id) else {
            pendingDetailsObjectID = nil
            return
        }
        pendingDetailsObjectID = nil
        // Boxing happens per object in this flow, so the full sheet replaces the name-only alert.
        guard flow != .sequential else {
            packageDetails = IdentifiedObjectID(id: id)
            return
        }
        objectNameText = ""
        objectDetailsContext = .finalize(id)
    }

    /// Puts a finished object back into measurement. The review list and the details sheet both
    /// use it, so an object can be corrected without being deleted and measured from scratch.
    private func rescan(_ id: UUID) {
        showsSavedObjects = false
        captureEngine.focusFinalizedObject(id: id)
        captureEngine.reactivateFocusedObject()
    }

    private func presentDetailsEditor(for id: UUID) {
        objectNameText = captureEngine.name(for: id) ?? ""
        objectDetailsContext = .edit(id)
    }

    private func saveObjectDetailsEntry() {
        guard let objectDetailsContext,
              !trimmedObjectName.isEmpty else {
            return
        }
        switch objectDetailsContext {
        case .finalize(let id), .edit(let id):
            captureEngine.updateName(id: id, name: trimmedObjectName)
        }
        self.objectDetailsContext = nil
        objectNameText = ""
    }

    /// Backing out of the name prompt cancels the measurement it belongs to. Finishing commits the
    /// dimensions before the prompt appears, so without this the object would be kept unnamed and
    /// the operator would have no obvious way to be rid of it. Editing an existing object is
    /// different — there Cancel means "leave the name as it was".
    private func cancelObjectDetailsEntry() {
        if case .finalize(let id) = objectDetailsContext,
           captureEngine.finalizedObjectIDs.contains(id) {
            packingStore.clearPreparation(for: id)
            captureEngine.removeFinalizedObject(id: id)
        }
        objectDetailsContext = nil
        objectNameText = ""
    }

    private func boxSummary(for id: UUID) -> String {
        let name = captureEngine.name(for: id) ?? "Unnamed object"
        return "\(name) · \(objectPreparationSummary(for: id))"
    }

    private func removalButtonTitle(for id: UUID) -> String {
        captureEngine.name(for: id).map { "Remove \($0)" }
            ?? "Remove object"
    }

    private func boxColorImage(for id: UUID) -> Image {
        let color = captureEngine.objectColor(for: id)
            ?? ObjectMaskDisplayColor(red: 0.20, green: 0.95, blue: 0.42)
        let image = UIImage(systemName: "circle.fill")?.withTintColor(
            UIColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: 1
            ),
            renderingMode: .alwaysOriginal
        )
        return image.map(Image.init(uiImage:))
            ?? Image(systemName: "circle.fill")
    }

    // MARK: - Sheets and alerts

    private var nonLiDARLimitationsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label("RGB-only tracking", systemImage: "camera.fill")
                        .font(.title2.bold())

                    Text("This iPhone does not expose ARKit LiDAR scene depth or a reconstructed depth mesh. Object masks and visual tracking still run on-device, but automatic metric 3D measurement is not equivalent to the LiDAR workflow.")
                        .font(.body)

                    VStack(alignment: .leading, spacing: 12) {
                        capabilityRow(
                            icon: "checkmark.circle.fill",
                            color: .green,
                            title: "Available",
                            detail: "Preview, finish, color and visually reacquire multiple RGB object masks."
                        )
                        capabilityRow(
                            icon: "xmark.circle.fill",
                            color: .red,
                            title: "No automatic metric boxes",
                            detail: "Without per-frame depth, the app cannot produce reliable width, depth, height or volume automatically."
                        )
                        capabilityRow(
                            icon: "tablecells",
                            color: .orange,
                            title: "No depth-based table removal",
                            detail: "RGB masks cannot verify which pixels belong to the table in 3D or separate surfaces at different depths."
                        )
                        capabilityRow(
                            icon: "move.3d",
                            color: .orange,
                            title: "Estimated anchor distance",
                            detail: "Mask motion and scale use visual mapping and an estimated distance, so fast sideways motion, low texture and occlusion can cause more drift."
                        )
                    }
                }
                .padding(20)
            }
            .navigationTitle("No LiDAR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showsLiDARLimitations = false
                    }
                }
            }
        }
    }

    private func capabilityRow(
        icon: String,
        color: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.bold())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Visual toggles

    private var scanQuickVisualControls: some View {
        HStack(spacing: 0) {
            quickVisualButton(
                title: "Mask",
                systemImage: "viewfinder",
                activeColor: .mint,
                isVisible: captureEngine.showsSegmentationOverlays,
                action: captureEngine.toggleSegmentationOverlays
            )
            quickVisualDivider
            quickVisualButton(
                title: "Points",
                systemImage: "circle.grid.3x3.fill",
                activeColor: .cyan,
                isVisible: captureEngine.showsSelectedPoints,
                action: captureEngine.toggleSelectedPoints
            )
            quickVisualDivider
            quickVisualButton(
                title: "Box",
                systemImage: "cube.transparent",
                activeColor: .green,
                isVisible: captureEngine.showsBoundingBoxes,
                action: captureEngine.toggleBoundingBoxes
            )
            quickVisualDivider
            scanMoreVisualsMenu
        }
        .padding(.horizontal, 4)
        .frame(height: 48)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private func quickVisualButton(
        title: String,
        systemImage: String,
        activeColor: Color,
        isVisible: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
            }
            .frame(width: 52, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isVisible ? activeColor : .secondary)
        .accessibilityLabel(isVisible ? "Hide \(title)" : "Show \(title)")
    }

    private var quickVisualDivider: some View {
        Rectangle()
            .fill(.secondary.opacity(0.22))
            .frame(width: 1, height: 22)
            .accessibilityHidden(true)
    }

    private var scanMoreVisualsMenu: some View {
        Menu {
            Section("Mask details") {
                visualToggleButton(
                    title: "Live preview",
                    systemImage: "viewfinder",
                    isVisible: captureEngine.showsLiveMaskPreview,
                    action: captureEngine.toggleLiveMaskPreview
                )
                visualToggleButton(
                    title: "Selected object",
                    systemImage: "paintpalette",
                    isVisible: captureEngine.showsSelectedObjectMaskPreview,
                    action: captureEngine.toggleSelectedObjectMaskPreview
                )
            }

            Section("Other overlays") {
                visualToggleButton(
                    title: "Finish markers",
                    systemImage: "location.circle",
                    isVisible: captureEngine.showsObjectMaskMarkers,
                    action: captureEngine.toggleObjectMaskMarkers
                )
                if sessionManager.isSceneReconstructionSupported {
                    visualToggleButton(
                        title: "Scene mesh",
                        systemImage: "circle.hexagongrid",
                        isVisible: captureEngine.isMeshVisible,
                        action: captureEngine.toggleMesh
                    )
                }
            }

            Section("Presets") {
                Button {
                    captureEngine.showResultsOnly()
                } label: {
                    Label("Results only", systemImage: "shippingbox")
                }
                Button {
                    captureEngine.hideAllScanVisuals()
                } label: {
                    Label("Hide all overlays", systemImage: "eye.slash")
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                Text("More")
                    .font(.system(size: 9, weight: .semibold))
            }
            .frame(width: 46, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("More scan visualization options")
    }

    private func visualToggleButton(
        title: String,
        systemImage: String,
        isVisible: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(
                title,
                systemImage: isVisible ? "checkmark.circle.fill" : systemImage
            )
        }
    }

    private var aimer: some View {
        ZStack {
            Ellipse()
                .fill(.white.opacity(aimerState.isOnSurface ? 0.24 : 0.12))
                .frame(width: 22, height: 22)

            Ellipse()
                .stroke(.white.opacity(aimerState.isOnSurface ? 1 : 0.62), lineWidth: 1.5)
                .frame(width: 15, height: 15)

            Ellipse()
                .fill(.white)
                .frame(width: 7, height: 7)
        }
        .scaleEffect(
            x: 1,
            y: CGFloat(aimerState.surfaceScaleY),
            anchor: .center
        )
        .rotationEffect(.degrees(aimerState.surfaceRotationDegrees))
        .shadow(color: .white.opacity(0.55), radius: 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func statusLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label + ":")
                .fontWeight(.semibold)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private var environmentStatusColor: Color {
        sessionManager.isObjectTrackingEnvironmentReady ? .green : .red
    }
}

#Preview {
    MesOverlayView(
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
}
