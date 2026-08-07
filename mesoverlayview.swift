import SwiftUI
import UIKit

struct MesOverlayView: View {
    private enum ObjectDetailsContext {
        case finalize(UUID)
        case edit(UUID)
    }

    let sessionManager: ARSessionManager
    let mesEngine: MesEngine
    let captureEngine: ObjectCaptureEngine
    @Binding var workflowMode: MeasurementWorkflowMode

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsPanel = false
    @State private var showsLiDARLimitations = false
    @State private var objectDetailsContext: ObjectDetailsContext?
    @State private var objectNameText = ""
    @State private var weightText = ""
    @State private var pendingRemovalObjectID: UUID?
    @State private var showsResetConfirmation = false
    @State private var showsSavedObjects = false
    @State private var pendingWorkflowMode: MeasurementWorkflowMode?
    @State private var showsModeChangeConfirmation = false
    @State private var showsTrackingDetails = false

    private var isAutomaticCaptureSupported: Bool {
        sessionManager.isAutomaticObjectCaptureSupported
    }

    var body: some View {
        ZStack {
            if !sessionManager.isCoachingActive {
                objectMaskPreview
                objectMaskMarkers
                if !showsPanel {
                    objectMaskInteractionLayer
                    aimer
                }
            }

            if !sessionManager.isCoachingActive {
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

            if !sessionManager.isCoachingActive, !showsPanel {
                VStack {
                    Spacer()

                    VStack(alignment: .leading, spacing: 10) {
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
        .onChange(of: captureEngine.resetRevision) { _, _ in
            showsSavedObjects = false
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
        .onChange(of: captureEngine.pendingFinalizationObjectID) {
            _, pendingObjectID in
            guard let context = objectDetailsContext else {
                return
            }
            if case .finalize(let id) = context,
               pendingObjectID != id {
                objectDetailsContext = nil
                objectNameText = ""
                weightText = ""
            }
        }
        .onChange(of: showsModeChangeConfirmation) { _, isPresented in
            if !isPresented {
                pendingWorkflowMode = nil
            }
        }
        .onAppear {
            if !isAutomaticCaptureSupported, workflowMode == .top {
                workflowMode = .spatial3D
            }
        }
        .sheet(isPresented: $showsLiDARLimitations) {
            nonLiDARLimitationsSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert(
            objectDetailsTitle,
            isPresented: objectDetailsIsPresented
        ) {
            TextField("Object name", text: $objectNameText)
                .textInputAutocapitalization(.words)
            TextField("Weight in kg", text: $weightText)
                .keyboardType(.decimalPad)
            Button("Cancel", role: .cancel) {
                cancelObjectDetailsEntry()
            }
            Button("Save") {
                saveObjectDetailsEntry()
            }
            .disabled(
                trimmedObjectName.isEmpty
                    || parsedWeightInKilograms == nil
            )
        } message: {
            Text("Give this object a name and enter a weight greater than zero in kilograms.")
        }
        .confirmationDialog(
            removalConfirmationTitle,
            isPresented: removalConfirmationIsPresented,
            titleVisibility: .visible
        ) {
            if let id = pendingRemovalObjectID {
                Button(removalButtonTitle(for: id), role: .destructive) {
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
            Button("Reset All", role: .destructive) {
                showsSavedObjects = false
                captureEngine.reset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the active object and every saved box, name, weight, point cloud and measurement.")
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

    @ViewBuilder
    private var topHUD: some View {
        if showsPanel {
            infoPanel
                .transition(.opacity.combined(with: .move(edge: .top)))
        } else {
            HStack(alignment: .top, spacing: 10) {
                topStatusCard

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

    @ViewBuilder
    private var topStatusCard: some View {
        if !sessionManager.isObjectTrackingEnvironmentReady {
            environmentReadinessBanner
        } else if !captureEngine.hasCompletedObjectRecognitionWarmup {
            objectRecognitionReadinessBanner
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
                    let isPendingFinalization =
                        captureEngine.pendingFinalizationObjectID == marker.id
                    let isActive = captureEngine.activeObjectID == marker.id
                        && !isPendingFinalization
                    let isLocked = isPendingFinalization
                        || captureEngine.finalizedObjectIDs.contains(marker.id)
                    let isMaskVisible = marker.isMaskVisible
                        && !isPendingFinalization
                    ZStack {
                        Circle()
                            .fill(color.opacity(isMaskVisible ? 0.92 : 0.28))
                        Circle()
                            .stroke(color, style: StrokeStyle(
                                lineWidth: isMaskVisible ? 2 : 3,
                                dash: isMaskVisible ? [] : [4, 3]
                            ))
                        Image(systemName: isActive
                            ? "viewfinder"
                            : isLocked ? "lock.fill" : "location.fill"
                        )
                            .font(.system(
                                size: isLocked ? 8 : 11,
                                weight: .bold
                            ))
                            .foregroundStyle(.white)
                    }
                    .frame(
                        width: isMaskVisible ? 18 : 28,
                        height: isMaskVisible ? 18 : 28
                    )
                    .position(
                        x: marker.normalizedViewportPoint.x * proxy.size.width,
                        y: marker.normalizedViewportPoint.y * proxy.size.height
                    )
                    .shadow(color: color.opacity(0.65), radius: 5)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private var faceCaptureGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                Text("Ready")
                Text("·")
                    .foregroundStyle(.secondary)
                Text(captureEngine.measurementSatisfied
                    ? "Measurement complete"
                    : "Measuring selected object")
                    .foregroundStyle(
                        captureEngine.measurementSatisfied ? .green : .secondary
                    )
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.green)
            if captureEngine.primaryText != "--" {
                Text(captureEngine.primaryText)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            faceGuideRow(
                icon: "arrow.down.to.line",
                label: "Top view",
                detail: "width × length",
                isActive: captureEngine.scanViewHint == .topDown,
                isDone: captureEngine.footprintSatisfied
            )
            faceGuideRow(
                icon: "arrow.right.to.line",
                label: "Side view",
                detail: "height",
                isActive: captureEngine.scanViewHint == .side,
                isDone: captureEngine.heightSatisfied
            )
            if captureEngine.measurementSatisfied {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("All faces captured — lock it in")
                        .font(.caption2.weight(.semibold))
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: 220, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var topCaptureGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: topGuideSystemImage)
                    .foregroundStyle(topGuideColor)
                Text(topGuideHeadline)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(topGuideColor)
            }

            if captureEngine.activeObjectID != nil,
               captureEngine.primaryText != "--" {
                Text(captureEngine.primaryText)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Text(topGuideDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: 230, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
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
            return "The overhead fit is stable. You can lock this object."
        }
        return captureEngine.isTopViewAligned
            ? "Hold still while the overhead points converge."
            : "Tilt toward vertical. Collection pauses until the angle is correct."
    }

    private func faceGuideRow(
        icon: String,
        label: String,
        detail: String,
        isActive: Bool,
        isDone: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: isDone ? "checkmark.circle.fill" : icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isDone ? .green : (isActive ? .yellow : .secondary))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if isActive {
                Text("capturing")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.yellow)
            } else if isDone {
                Text("saved")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            isActive ? Color.yellow.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private var environmentReadinessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text(sessionManager.environmentReadiness.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                Text(sessionManager.environmentReadiness.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: 265, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 15))
        .accessibilityElement(children: .combine)
    }

    private var objectRecognitionReadinessBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Environment ready")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Preparing object recognition…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: 265, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 15))
        .accessibilityElement(children: .combine)
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
                        : "Lock the current object before selecting another."
                )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var objectMaskPreview: some View {
        if !captureEngine.isFinalizationPending,
           let preview = captureEngine.objectMaskPreview {
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
            let distanceScale: CGFloat = {
                guard let referenceDistance = layer.referenceCameraDistance,
                      let currentDistance = marker?.cameraDistance,
                      referenceDistance > 0.05,
                      currentDistance > 0.05 else {
                    return 1
                }
                return min(max(CGFloat(referenceDistance / currentDistance), 0.4), 2.5)
            }()
            let trackedTransform: (
                anchor: UnitPoint,
                xScale: CGFloat,
                yScale: CGFloat,
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
                    UnitPoint(x: reference.midX, y: reference.midY),
                    min(max(current.width / reference.width, 0.4), 2.5),
                    min(max(current.height / reference.height, 0.4), 2.5),
                    (current.midX - reference.midX) * proxy.size.width,
                    (current.midY - reference.midY) * proxy.size.height
                )
            }()
            let fallbackScale = marker == nil ? 1 : distanceScale
            // Scale by camera distance only. The tracked bounding-box ratio
            // (current/reference) jitters between Vision frames and made the
            // highlight visibly "breathe" a couple times a second; use it for
            // position (offset) but not for size.
            let xScale = fallbackScale
            let yScale = fallbackScale
            let anchor = trackedTransform?.anchor
                ?? UnitPoint(x: referencePoint.x, y: referencePoint.y)
            let xOffset = trackedTransform?.xOffset
                ?? (currentPoint.x - referencePoint.x) * proxy.size.width
            let yOffset = trackedTransform?.yOffset
                ?? (currentPoint.y - referencePoint.y) * proxy.size.height

            ZStack {
                Image(decorative: layer.image, scale: 1, orientation: .up)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(
                        x: xScale,
                        y: yScale,
                        anchor: anchor
                    )
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
                        .font(.caption2.weight(.semibold))
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
            }

        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 225, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 15))
    }

    private var scanStatusHeadline: String {
        if captureEngine.activeObjectID != nil {
            return "Measuring selected object"
        }

        let count = captureEngine.finalizedObjectIDs.count
        if count > 0 {
            return "\(count) object\(count == 1 ? "" : "s") locked"
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
            return "\(count) locked RGB object\(count == 1 ? "" : "s")"
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
                return "\(captureEngine.statusText) Only this object is being measured. Move around all sides, then tap Lock."
            }
            if !captureEngine.finalizedObjectIDs.isEmpty {
                return "\(captureEngine.statusText) Locked measurements stay fixed. Tap another highlighted object to measure it."
            }
            return "\(captureEngine.statusText) Tap a highlighted object to select it for measurement."
        }

        if captureEngine.activeObjectID != nil {
            return "Only the selected object is active. Lock it before selecting another."
        }

        if !captureEngine.finalizedObjectIDs.isEmpty {
            return "Locked objects stay fixed. Point at another colored preview and tap to select it."
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

    @ViewBuilder
    private var bottomActionRow: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                if !finalizedMeasuredObjectIDs.isEmpty {
                    savedObjectsButton
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    workflowButtonIfAvailable
                    if captureEngine.canReset {
                        resetButton
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                if !finalizedMeasuredObjectIDs.isEmpty {
                    savedObjectsButton
                }
                Spacer(minLength: 0)
                workflowButtonIfAvailable
                if captureEngine.canReset {
                    resetButton
                }
            }
        }
    }

    @ViewBuilder
    private var workflowButtonIfAvailable: some View {
        if isAutomaticCaptureSupported,
           captureEngine.activeObjectID != nil
            || captureEngine.canReactivateFocusedObject {
            objectWorkflowButton
        }
    }

    @ViewBuilder
    private var objectWorkflowButton: some View {
        if captureEngine.activeObjectID != nil,
           !captureEngine.isFinalizationPending {
            Button {
                guard sessionManager.isTrackingReady,
                      sessionManager.isObjectTrackingEnvironmentReady else {
                    return
                }
                showsSavedObjects = false
                presentFinalizationDetailsEntry()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                    Text("Lock")
                        .foregroundStyle(.primary)
                }
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .frame(
                        width: dynamicTypeSize.isAccessibilitySize ? 164 : 116,
                        height: dynamicTypeSize.isAccessibilitySize ? 56 : 50
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .disabled(
                !captureEngine.canFinalizeActiveObject
                    || !sessionManager.isTrackingReady
                    || !sessionManager.isObjectTrackingEnvironmentReady
            )
            .accessibilityLabel("Finish and lock current object")
            .accessibilityHint(
                !sessionManager.isTrackingReady
                    ? "Wait for normal camera tracking before locking."
                    : !sessionManager.isObjectTrackingEnvironmentReady
                        ? "Scan the floor or table until its supporting plane is ready."
                    : !captureEngine.hasDefinitiveSupportPlaneForActiveObject
                        ? "Scan the floor or table directly beneath this object before locking."
                    : captureEngine.canFinalizeActiveObject
                        ? "Stops measurement updates so you can select another object."
                        : "Keep scanning until a LiDAR box is ready."
            )
        } else if captureEngine.canReactivateFocusedObject {
            Button {
                showsSavedObjects = false
                captureEngine.reactivateFocusedObject()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.open.fill")
                        .foregroundStyle(.orange)
                    Text("Unlock")
                        .foregroundStyle(.primary)
                }
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .frame(
                        width: dynamicTypeSize.isAccessibilitySize ? 164 : 116,
                        height: dynamicTypeSize.isAccessibilitySize ? 56 : 50
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Unlock focused object for measurement")
            .accessibilityHint("Only one object can be unlocked at a time.")
        }
    }

    private var resetButton: some View {
        Button {
            showsResetConfirmation = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .foregroundStyle(.red)
                Text("Reset")
                    .foregroundStyle(.primary)
            }
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(
                    width: dynamicTypeSize.isAccessibilitySize ? 124 : 80,
                    height: dynamicTypeSize.isAccessibilitySize ? 52 : 44
                )
                .contentShape(Capsule())
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
        .accessibilityHint("Shows names, weights and actions for locked objects.")
    }

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
                Text("Lock the object being measured before selecting a saved object.")
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

    private func savedObjectRow(for id: UUID) -> some View {
        let isFocused = captureEngine.focusedObjectID == id
        let canSelect = captureEngine.activeObjectID == nil
            && !captureEngine.isObjectSelectionPending
        let objectName = captureEngine.name(for: id) ?? "Unnamed object"

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

                        Text(objectWeightSummary(for: id))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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
                "\(objectName), \(objectWeightSummary(for: id))"
            )
            .accessibilityValue(isFocused ? "Selected" : "Not selected")
            .accessibilityHint(
                canSelect
                    ? "Selects this object for viewing or unlocking."
                    : "Lock the active object before selecting this one."
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
            .accessibilityLabel("Edit \(objectName)")
            .accessibilityHint("Changes this object's name and weight.")

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

    private func objectWeightSummary(for id: UUID) -> String {
        captureEngine.weightInKilograms(for: id)
            .map { "\(formattedWeight($0)) kg" }
            ?? "No weight"
    }

    private var objectDetailsIsPresented: Binding<Bool> {
        Binding(
            get: {
                guard let context = objectDetailsContext else {
                    return false
                }
                switch context {
                case .finalize(let id):
                    return captureEngine.pendingFinalizationObjectID == id
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

    private var parsedWeightInKilograms: Double? {
        let normalized = weightText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let weight = Double(normalized),
              weight.isFinite,
              weight > 0 else {
            return nil
        }
        return weight
    }

    private var trimmedObjectName: String {
        objectNameText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var objectDetailsTitle: String {
        guard let objectDetailsContext else {
            return "Object details"
        }
        switch objectDetailsContext {
        case .finalize:
            return "Lock object"
        case .edit:
            return "Edit object"
        }
    }

    private var removalConfirmationTitle: String {
        guard let id = pendingRemovalObjectID else {
            return "Remove box?"
        }
        return "Remove Box \(boxNumber(for: id))?"
    }

    private func presentFinalizationDetailsEntry() {
        guard let id = captureEngine.beginFinalization() else {
            return
        }
        objectNameText = captureEngine.name(for: id) ?? ""
        weightText = captureEngine.weightInKilograms(for: id).map(formattedWeight) ?? ""
        objectDetailsContext = .finalize(id)
    }

    private func presentDetailsEditor(for id: UUID) {
        objectNameText = captureEngine.name(for: id) ?? ""
        weightText = captureEngine.weightInKilograms(for: id).map(formattedWeight) ?? ""
        objectDetailsContext = .edit(id)
    }

    private func saveObjectDetailsEntry() {
        guard let objectDetailsContext,
              !trimmedObjectName.isEmpty,
              let weight = parsedWeightInKilograms else {
            return
        }
        switch objectDetailsContext {
        case .finalize(let id):
            guard captureEngine.activeObjectID == id,
                  captureEngine.pendingFinalizationObjectID == id else {
                cancelObjectDetailsEntry()
                return
            }
            captureEngine.finalizeActiveObject(
                name: trimmedObjectName,
                weightInKilograms: weight
            )
        case .edit(let id):
            captureEngine.updateDetails(
                id: id,
                name: trimmedObjectName,
                weightInKilograms: weight
            )
        }
        self.objectDetailsContext = nil
        objectNameText = ""
        weightText = ""
    }

    private func cancelObjectDetailsEntry() {
        if case .finalize? = objectDetailsContext {
            captureEngine.cancelPendingFinalization()
        }
        objectDetailsContext = nil
        objectNameText = ""
        weightText = ""
    }

    private func boxNumber(for id: UUID) -> String {
        captureEngine.objectNumber(for: id).map { String($0) } ?? "?"
    }

    private func boxSummary(for id: UUID) -> String {
        let name = captureEngine.name(for: id) ?? "Box \(boxNumber(for: id))"
        let weightText = captureEngine.weightInKilograms(for: id)
            .map { "\(formattedWeight($0)) kg" }
            ?? "No weight"
        return "\(name) · \(weightText)"
    }

    private func removalButtonTitle(for id: UUID) -> String {
        "Remove Box \(boxNumber(for: id))"
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

    private func formattedWeight(_ weight: Double) -> String {
        weight.formatted(
            .number
                .grouping(.never)
                .precision(.fractionLength(0...3))
        )
    }

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
                            detail: "Preview, lock, color and visually reacquire multiple RGB object masks."
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
                    title: "Lock markers",
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
                .fill(.white.opacity(mesEngine.isAimerOnSurface ? 0.24 : 0.12))
                .frame(width: 22, height: 22)

            Ellipse()
                .stroke(.white.opacity(mesEngine.isAimerOnSurface ? 1 : 0.62), lineWidth: 1.5)
                .frame(width: 15, height: 15)

            Ellipse()
                .fill(.white)
                .frame(width: 7, height: 7)
        }
        .scaleEffect(
            x: 1,
            y: CGFloat(mesEngine.aimerSurfaceScaleY),
            anchor: .center
        )
        .scaleEffect(CGFloat(mesEngine.aimerDistanceScale), anchor: .center)
        .rotationEffect(.degrees(mesEngine.aimerSurfaceRotationDegrees))
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
        mesEngine: MesEngine(),
        captureEngine: ObjectCaptureEngine(),
        workflowMode: .constant(.spatial3D)
    )
}
