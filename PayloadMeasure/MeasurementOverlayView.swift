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

    let sessionManager: ARSessionManager
    let aimerState: AimerState
    let captureEngine: ObjectCaptureEngine
    @Binding var workflowMode: MeasurementWorkflowMode
    let flow: MeasurementFlow
    let onFullReset: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsPanel = false
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

    private var isAutomaticCaptureSupported: Bool {
        sessionManager.isAutomaticObjectCaptureSupported
    }

    private var showsLiveOverlay: Bool {
        !sessionManager.isCoachingActive
    }

    var body: some View {
        ZStack {
            if showsLiveOverlay {
                objectMaskPreview
                objectMaskMarkers
                if !showsPanel {
                    objectMaskInteractionLayer
                    aimer
                }
            }

            if showsLiveOverlay {
                VStack {
                    GlassEffectContainer(spacing: 14) {
                        topHUD
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.top, 16)
                    .padding(.horizontal, 16)

                    Spacer()
                }
            }

            if showsLiveOverlay, !showsPanel {
                VStack {
                    Spacer()

                    VStack(alignment: .leading, spacing: 10) {
                        bottomStatusCard
                            .transition(
                                .opacity.combined(
                                    with: .move(edge: .bottom)
                                )
                            )

                        if showsSavedObjects,
                           !finalizedMeasuredObjectIDs.isEmpty {
                            savedObjectsPanel
                                .transition(
                                    .opacity.combined(
                                        with: .scale(scale: 0.96, anchor: .bottom)
                                    )
                                )
                        }

                        if !finalizedMeasuredObjectIDs.isEmpty
                            || captureEngine.canReset {
                            bottomActionRow
                        }

                        HStack {
                            scanQuickVisualControls
                            Spacer(minLength: 0)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
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
        .onChange(of: captureEngine.automaticLockRequestRevision) { _, _ in
            presentAutomaticLockIfRequested()
        }
        .task(id: pendingDetailsObjectID) {
            await presentPendingDetailsSheet()
        }
        .onChange(of: captureEngine.canFinalizeActiveObject) { _, canLock in
            if canLock {
                lockFeedback.prepare()
            }
        }
        .onAppear(perform: handleAppearance)
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onChange(of: showsPackingWorkflow) { _, isPresented in
            handlePackingWorkflowPresentationChange(isPresented)
        }
        .sheet(item: $packageDetails) { entry in
            PackageDetailsSheet(
                objectID: entry.id,
                captureEngine: captureEngine,
                store: packingStore,
                onRescan: { rescan(entry.id) }
            )
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
                store: packingStore
            )
        }
        .alert(
            objectDetailsTitle,
            isPresented: objectDetailsIsPresented
        ) {
            TextField("Object name", text: $objectNameText)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {
                cancelObjectDetailsEntry()
            }
            Button("Save") {
                saveObjectDetailsEntry()
            }
            .disabled(trimmedObjectName.isEmpty)
        } message: {
            Text(objectDetailsMessage)
        }
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
    }

    private func handleAppearance() {
        sessionManager.setApplicationActive(scenePhase == .active)
        if !isAutomaticCaptureSupported, workflowMode == .top {
            workflowMode = .spatial3D
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        sessionManager.setApplicationActive(phase == .active)
    }

    /// Leaving the loading plan means the load is done. Rather than drop back into a half-used
    /// session — which is what made the app feel worse afterwards — offer to clear everything.
    private func handlePackingWorkflowDismissal() {
        captureEngine.clearAllSnapshotJPEGData()
        showsFinishLoadConfirmation = true
    }

    private func handlePackingWorkflowPresentationChange(_ isPresented: Bool) {
        sessionManager.setPackingArrangementPresented(isPresented)
    }

    // MARK: - Top HUD

    @ViewBuilder
    private var topHUD: some View {
        if showsPanel {
            infoPanel
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 8)

                Button {
                    showsSavedObjects = false
                    showsPanel = true
                } label: {
                    Image(systemName: "info")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 38, height: 38)
                        .contentShape(Circle())
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .foregroundStyle(.primary)
                .accessibilityLabel("Show information")
            }
        }
    }

    private var isPreparingToMeasure: Bool {
        !sessionManager.isObjectTrackingEnvironmentReady
            || !captureEngine.hasCompletedObjectRecognitionWarmup
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

    @ViewBuilder
    private var objectMaskMarkers: some View {
        if captureEngine.showsObjectMaskMarkers,
           !captureEngine.objectMaskMarkers.isEmpty {
            GeometryReader { proxy in
                ForEach(captureEngine.objectMaskMarkers) { marker in
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

            framingGuidanceLine
            autoLockProgress
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
        let framing = captureEngine.framingGuidance.map {
            " \(framingGuidanceText(for: $0))."
        } ?? ""
        return "\(captureEngine.primaryText). Top view \(top). Side view \(side).\(framing)"
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

            framingGuidanceLine
            autoLockProgress
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var framingGuidanceLine: some View {
        if captureEngine.activeObjectID != nil,
           let guidance = captureEngine.framingGuidance {
            Label(
                framingGuidanceText(for: guidance),
                systemImage: framingGuidanceSystemImage(for: guidance)
            )
            .font(.footnote.weight(.bold))
            .foregroundStyle(framingGuidanceColor(for: guidance))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                framingGuidanceColor(for: guidance).opacity(0.16),
                in: RoundedRectangle(cornerRadius: 9)
            )
        }
    }

    private func framingGuidanceText(for guidance: ObjectFramingGuidance) -> String {
        switch guidance {
        case .moveCloser:
            "Move the phone closer"
        case .moveFarther:
            "Move the phone farther away"
        case .okay:
            "Distance looks good"
        }
    }

    private func framingGuidanceSystemImage(for guidance: ObjectFramingGuidance) -> String {
        switch guidance {
        case .moveCloser:
            "arrow.down.right.and.arrow.up.left"
        case .moveFarther:
            "arrow.up.left.and.arrow.down.right"
        case .okay:
            "checkmark.circle.fill"
        }
    }

    private func framingGuidanceColor(for guidance: ObjectFramingGuidance) -> Color {
        guidance == .okay ? .green : .orange
    }

    @ViewBuilder
    private var autoLockProgress: some View {
        let convergence = captureEngine.convergence
        if convergence.isActive {
            let progress = min(max(convergence.progress, 0), 1)
            let percent = Int((progress * 100).rounded())
            HStack(spacing: 10) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.22))
                        Capsule()
                            .fill(autoLockTint)
                            .frame(width: max(0, proxy.size.width * progress))
                    }
                }
                .frame(height: 8)

                Text("\(percent)%")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(radius: 1)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .frame(height: 20)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(autoLockHeadline)
            .accessibilityValue("\(percent) percent. \(convergence.detail)")
        }
    }

    private var autoLockHeadline: String {
        if !captureEngine.isAutomaticLockEnabled {
            return "Measurement quality"
        }
        if captureEngine.isAutomaticLockDisarmedForActiveObject {
            return "Automatic finish dismissed"
        }
        return captureEngine.convergence.headline
    }


    /// High contrast against the camera feed, which can be any colour at all.
    private var autoLockTint: Color {
        captureEngine.convergence.isConverged ? .green : .white
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
                ? "Hold this angle and tap the object."
                : "Hold the phone above the object with the camera facing the floor."
        }
        if captureEngine.topMeasurementStable {
            return "The overhead fit is stable. You can finish this object."
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
                    captureEngine.activeObjectID == nil
                        ? "Tap an object to select it for measurement"
                        : "Current object selected for measurement"
                )
                .accessibilityHint(
                    captureEngine.activeObjectID == nil
                        ? "Only one object can be measured at a time."
                        : "Finish the current object before selecting another."
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

                Toggle(isOn: automaticLockBinding) {
                    Text("Finish automatically")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .accessibilityHint("Finishes the measurement and asks for a name as soon as it reaches its precision target.")

                Text("Finishes when a 95% confidence interval over the last 24 fits is no wider than 5 mm, or 1% of the dimension for anything larger than 500 mm — whichever is the looser of the two — and the interval is no longer drifting. Every dimension must clear it, must have been seen from a viewpoint that can measure it, and must sit over a surface ARKit has confirmed.")
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
                return "\(captureEngine.statusText) Only this object is being measured. Move around all sides, then tap Finish."
            }
            if !captureEngine.finalizedObjectIDs.isEmpty {
                return "\(captureEngine.statusText) Finished measurements stay fixed. Tap another highlighted object to measure it."
            }
            return "\(captureEngine.statusText) Tap a highlighted object to select it for measurement."
        }

        if captureEngine.activeObjectID != nil {
            return "Only the selected object is active. Finish it before selecting another."
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
            VStack(alignment: .leading, spacing: 8) {
                if !finalizedMeasuredObjectIDs.isEmpty {
                    savedObjectsButton
                }

                ViewThatFits(in: .horizontal) {
                    accessibilityActionRow(showsTitles: true)
                    accessibilityActionRow(showsTitles: false)
                }
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
            workflowButtonIfAvailable(showsTitle: showsTitles)
            if captureEngine.canReset {
                resetButton(showsTitle: showsTitles)
            }
        }
    }

    private func actionRow(showsTitles: Bool) -> some View {
        HStack(spacing: 8) {
            if !finalizedMeasuredObjectIDs.isEmpty {
                savedObjectsButton
            }
            Spacer(minLength: 0)
            cancelMeasurementButton(showsTitle: showsTitles)
            workflowButtonIfAvailable(showsTitle: showsTitles)
            if captureEngine.canReset {
                resetButton(showsTitle: showsTitles)
            }
        }
    }

    @ViewBuilder
    private func workflowButtonIfAvailable(showsTitle: Bool) -> some View {
        if isAutomaticCaptureSupported,
           captureEngine.activeObjectID != nil
            || (flow.tracksFinishedObjects && captureEngine.canEditFocusedObject) {
            objectWorkflowButton(showsTitle: showsTitle)
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
    @ViewBuilder
    private func cancelMeasurementButton(showsTitle: Bool) -> some View {
        if isAutomaticCaptureSupported, captureEngine.activeObjectID != nil {
            Button {
                showsSavedObjects = false
                captureEngine.cancelActiveMeasurement()
            } label: {
                actionLabel("Cancel", systemImage: "xmark", tint: .red, showsTitle: showsTitle)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Cancel measurement")
            .accessibilityHint("Discards this measurement and deselects the object.")
        }
    }

    @ViewBuilder
    private func objectWorkflowButton(showsTitle: Bool) -> some View {
        if captureEngine.activeObjectID != nil {
            Button {
                guard sessionManager.isTrackingReady,
                      sessionManager.isObjectTrackingEnvironmentReady else {
                    return
                }
                showsSavedObjects = false
                lockAndPresentDetails()
            } label: {
                actionLabel("Finish", systemImage: "checkmark", tint: .green, showsTitle: showsTitle)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(
                !captureEngine.canFinalizeActiveObject
                    || !sessionManager.isTrackingReady
                    || !sessionManager.isObjectTrackingEnvironmentReady
            )
            .accessibilityLabel("Finish measuring this object")
            .accessibilityHint(
                !sessionManager.isTrackingReady
                    ? "Wait for normal camera tracking before finishing."
                    : !sessionManager.isObjectTrackingEnvironmentReady
                        ? "Scan the floor or table until its supporting plane is ready."
                    : !captureEngine.hasDefinitiveSupportPlaneForActiveObject
                        ? "Scan the floor or table directly beneath this object before finishing."
                    : captureEngine.canFinalizeActiveObject
                        ? "Saves the measurement so you can select another object."
                        : "Keep scanning until a LiDAR box is ready."
            )
        } else if flow.tracksFinishedObjects, captureEngine.canEditFocusedObject {
            Button {
                showsSavedObjects = false
                captureEngine.reactivateFocusedObject()
            } label: {
                actionLabel("Edit", systemImage: "pencil", tint: .orange, showsTitle: showsTitle)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Edit the object you are pointing at")
            .accessibilityHint("Resumes measuring it. Only one object can be edited at a time.")
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
                Text("Finish the object being measured before selecting a saved object.")
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

            arrangePayloadButton
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .contain)
    }

    private var arrangePayloadButton: some View {
        let isMeasuring = captureEngine.activeObjectID != nil
        let needsPreparation = packingStore
            .packagesMissingPreparation(from: captureEngine)
            .count
        let noFittingBoxCount = finalizedMeasuredObjectIDs.count(where: { id in
            packingStore.fittingBoxPresets(for: id, in: captureEngine).isEmpty
        })

        return VStack(alignment: .leading, spacing: 4) {
            Button {
                showsSavedObjects = false
                showsPackingWorkflow = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox.and.arrow.backward")
                        .foregroundStyle(.cyan)
                    Text("Prepare & arrange")
                        .foregroundStyle(.primary)
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(isMeasuring)
            .opacity(isMeasuring ? 0.5 : 1)
            .accessibilityLabel("Prepare packages and arrange the payload")
            .accessibilityHint(
                isMeasuring
                    ? "Finish the object being measured first."
                    : "Guides you through naming, choosing an outer box and weighing each package before creating the loading plan."
            )

            if noFittingBoxCount > 0 {
                Text("\(noFittingBoxCount) object\(noFittingBoxCount == 1 ? " does" : "s do") not fit available boxes and will be left out during preparation.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if needsPreparation > 0 {
                Text("You will choose a fitting outer box and enter the packed weight in grams for each object.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Review every prepared package before rebuilding the loading plan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
                    : "Finish the active object before selecting this one."
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
              objectDetailsContext == nil,
              sessionManager.isTrackingReady,
              sessionManager.isObjectTrackingEnvironmentReady else {
            return
        }
        showsSavedObjects = false
        showsPanel = false
        lockAndPresentDetails()
    }

    private func lockAndPresentDetails() {
        guard let id = captureEngine.lockActiveObject() else {
            return
        }
        lockFeedback.notificationOccurred(.success)
        pendingDetailsObjectID = id
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

    private func cancelObjectDetailsEntry() {
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
        onFullReset: {}
    )
}
