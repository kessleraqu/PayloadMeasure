//
//  MeasurementOverlayView.swift
//  PayloadMeasure
//
//  Created by Alexandre on 29/06/2026.
//

import SwiftUI

struct MeasurementOverlayView: View {
    let sessionManager: ARSessionManager
    let measurementEngine: MeasurementEngine
    let captureEngine: ObjectCaptureEngine

    @State private var showsPanel = false
    @State private var showsLiDARLimitations = false

    private var isScanning: Bool {
        measurementEngine.mode == .scan
    }

    private var isAutomaticCaptureSupported: Bool {
        sessionManager.isAutomaticObjectCaptureSupported
    }

    var body: some View {
        ZStack {
            objectMaskPreview
            objectMaskMarkers
            objectMaskInteractionLayer
            aimer

            VStack {
                HStack(alignment: .top) {
                    if isScanning {
                        captureReadout
                    } else {
                        measurementReadout
                    }

                    Spacer(minLength: 12)

                    if showsPanel {
                        infoPanel
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Button {
                        showsPanel.toggle()
                    } label: {
                        Image(systemName: showsPanel ? "xmark" : "info")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 42, height: 42)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel(showsPanel ? "Hide controls" : "Show controls")
                }
                .padding(.top, 16)
                .padding(.horizontal, 16)

                Spacer()
            }

            VStack {
                Spacer()

                HStack(alignment: .bottom) {
                    if isScanning {
                        scanQuickVisualControls
                    }
                    Spacer()
                    modeMenu
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }

            VStack {
                Spacer()
                if !isScanning {
                    addPointButton
                        .padding(.bottom, 28)
                }
            }

            VStack {
                if isScanning,
                   sessionManager.isLiDARAvailable,
                   !sessionManager.isObjectTrackingEnvironmentReady {
                    environmentReadinessBanner
                        .padding(.top, 86)
                }
                Spacer()
            }
        }
        .animation(.snappy(duration: 0.22), value: showsPanel)
        .animation(.snappy(duration: 0.18), value: measurementEngine.mode)
        .animation(.snappy(duration: 0.2), value: captureEngine.hasCapture)
        .sheet(isPresented: $showsLiDARLimitations) {
            nonLiDARLimitationsSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var objectMaskMarkers: some View {
        if isScanning,
           captureEngine.showsObjectMaskMarkers,
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
                            .fill(color.opacity(marker.isMaskVisible ? 0.92 : 0.28))
                        Circle()
                            .stroke(color, style: StrokeStyle(
                                lineWidth: marker.isMaskVisible ? 2 : 3,
                                dash: marker.isMaskVisible ? [] : [4, 3]
                            ))
                        Image(systemName: marker.isMaskVisible ? "lock.fill" : "location.fill")
                            .font(.system(size: marker.isMaskVisible ? 8 : 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(
                        width: marker.isMaskVisible ? 18 : 28,
                        height: marker.isMaskVisible ? 18 : 28
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

    private var environmentReadinessBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(sessionManager.environmentReadiness.title)
                    .font(.caption.weight(.semibold))
                Text(sessionManager.environmentReadiness.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 310, alignment: .leading)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var objectMaskInteractionLayer: some View {
        if isScanning {
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { value in
                                guard proxy.size.width > 0, proxy.size.height > 0 else {
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
                    .accessibilityLabel("Tap an object to lock or remove its mask")
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var objectMaskPreview: some View {
        if isScanning, let preview = captureEngine.objectMaskPreview {
            ZStack {
                ForEach(Array(preview.layers.enumerated()), id: \.offset) { _, layer in
                    if let trackedObjectID = layer.trackedObjectID {
                        if captureEngine.showsLockedMaskPreviews,
                           let marker = captureEngine.objectMaskMarkers.first(where: {
                            $0.id == trackedObjectID
                        }) {
                            trackedObjectMaskPreview(layer, marker: marker)
                        }
                    } else if captureEngine.showsLiveMaskPreview {
                        trackedObjectMaskPreview(layer, marker: nil)
                    }
                }
            }
        }
    }

    /// A fresh segmentation image may finish after the phone has already moved. Reprojecting its
    /// world anchor translates and scales the visual mask to the current camera pose immediately.
    /// Metric depth never uses this visual prediction; it stays tied to the exact source frame.
    private func trackedObjectMaskPreview(
        _ layer: ObjectMaskPreviewLayer,
        marker: ObjectMaskMarker?
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

            ZStack {
                Image(decorative: layer.image, scale: 1, orientation: .up)
                    .resizable()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .scaleEffect(
                        distanceScale,
                        anchor: UnitPoint(x: referencePoint.x, y: referencePoint.y)
                    )
                    .offset(
                        x: (currentPoint.x - referencePoint.x) * proxy.size.width,
                        y: (currentPoint.y - referencePoint.y) * proxy.size.height
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: statusColor.opacity(0.55), radius: 4)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Payload Measure")
                        .font(.headline)
                    Text(sessionManager.trackingStatus.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(sessionManager.trackingStatus.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isAutomaticCaptureSupported {
                    statusLine("Depth", sessionManager.depthStatusText)
                    statusLine("Depth map", sessionManager.sceneDepthResolutionText)
                    statusLine("Object cloud", "1 cm confirmed voxels")
                    statusLine("Mesh", sessionManager.sceneReconstructionStatusText)
                }
                statusLine("Planes", sessionManager.planeStatusText)
                statusLine("Tracking", sessionManager.trackingHardwareText)
                statusLine("Map", sessionManager.environmentReadiness.title)
            }
            .font(.caption)

        }
        .padding(14)
        .frame(maxWidth: 275, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var measurementReadout: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(measurementEngine.measurementStatusText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(measurementEngine.primaryMeasurementText)
                    .font(primaryValueFont)
                    .monospacedDigit()
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                if let secondaryMeasurementText = measurementEngine.secondaryMeasurementText {
                    Text(secondaryMeasurementText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if measurementEngine.canReset {
                Button {
                    measurementEngine.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Reset measurement")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 220, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var captureReadout: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(scanStatusHeadline)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

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
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                if isAutomaticCaptureSupported, let secondaryText = captureEngine.secondaryText {
                    Text(secondaryText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Text(
                    scanStatusText
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if captureEngine.canReset {
                Button {
                    captureEngine.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel("Clear all locked objects and boxes")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 270, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var scanStatusHeadline: String {
        if captureEngine.lockedObjectMaskCount > 0 {
            let count = captureEngine.lockedObjectMaskCount
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

        if captureEngine.lockedObjectMaskCount > 0 {
            return "\(captureEngine.lockedObjectMaskCount) colored RGB mask\(captureEngine.lockedObjectMaskCount == 1 ? "" : "s")"
        }

        return captureEngine.hasObjectMaskPreview ? "RGB mask selected" : "--"
    }

    private var scanStatusText: String {
        if let feedback = captureEngine.objectMaskFeedbackText {
            return feedback
        }

        if isAutomaticCaptureSupported {
            if captureEngine.isCapturing, captureEngine.lockedObjectMaskCount == 0 {
                return "Selecting the object under the center point…"
            }
            if captureEngine.lockedObjectMaskCount > 0 {
                return "\(captureEngine.statusText) Move around it and vary phone height to capture more than one visible face."
            }
            return "\(captureEngine.statusText) Tap a highlighted object to add or remove it."
        }

        if captureEngine.lockedObjectMaskCount > 0 {
            return "Locked masks persist in the AR map. Point at another colored preview and tap to add it."
        }

        return "Center an object to preview its next color, then tap it to lock."
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
        .glassEffect(.regular, in: Capsule())
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
                    title: "Locked masks",
                    systemImage: "paintpalette",
                    isVisible: captureEngine.showsLockedMaskPreviews,
                    action: captureEngine.toggleLockedMaskPreviews
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

    private var modeMenu: some View {
        Menu {
            ForEach(MeasurementMode.allCases) { mode in
                Button {
                    measurementEngine.mode = mode
                } label: {
                    HStack {
                        Label(mode.title, systemImage: mode.systemImageName)
                        Spacer()

                        if measurementEngine.mode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: measurementEngine.mode.systemImageName)
                    .font(.system(size: 14, weight: .semibold))

                Text("Mode")
                    .font(.caption.weight(.semibold))

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .contentShape(Capsule())
            .background {
                if measurementEngine.mode == .scan {
                    Capsule()
                        .fill(.white.opacity(0.08))
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Measurement mode, \(measurementEngine.mode.title)")
    }

    private var aimer: some View {
        ZStack {
            Ellipse()
                .fill(.white.opacity(measurementEngine.isAimerOnSurface ? 0.24 : 0.12))
                .frame(width: 22, height: 22)

            Ellipse()
                .stroke(.white.opacity(measurementEngine.isAimerOnSurface ? 1 : 0.62), lineWidth: 1.5)
                .frame(width: 15, height: 15)

            Ellipse()
                .fill(.white)
                .frame(width: 7, height: 7)
        }
        .scaleEffect(
            x: 1,
            y: CGFloat(measurementEngine.aimerSurfaceScaleY),
            anchor: .center
        )
        .scaleEffect(CGFloat(measurementEngine.aimerDistanceScale), anchor: .center)
        .rotationEffect(.degrees(measurementEngine.aimerSurfaceRotationDegrees))
        .shadow(color: .white.opacity(0.55), radius: 5)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var addPointButton: some View {
        Button {
            measurementEngine.requestPointPlacement()
        } label: {
            Label("Add Point", systemImage: "plus")
                .font(.headline.weight(.semibold))
                .foregroundStyle(sessionManager.isTrackingReady ? .primary : .secondary)
                .padding(.horizontal, 22)
                .frame(height: 52)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
        .disabled(!sessionManager.isTrackingReady)
        .accessibilityLabel("Add measurement point")
    }

    private var primaryValueFont: Font {
        switch measurementEngine.mode {
        case .line:
            .system(.callout, design: .rounded).weight(.semibold)
        case .boundingBox, .scan:
            .system(.caption, design: .rounded).weight(.semibold)
        }
    }

    private func statusLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label + ":")
                .fontWeight(.semibold)
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch sessionManager.trackingStatus {
        case .normal:
            .green
        case .starting, .limited:
            .yellow
        case .unavailable, .interrupted, .failed:
            .red
        }
    }
}

#Preview {
    MeasurementOverlayView(
        sessionManager: ARSessionManager(),
        measurementEngine: MeasurementEngine(),
        captureEngine: ObjectCaptureEngine()
    )
}
