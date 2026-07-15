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
                    if isScanning, isAutomaticCaptureSupported {
                        HStack(spacing: 8) {
                            if sessionManager.isSceneReconstructionSupported {
                                meshToggleButton
                            }
                            selectionToggleButton
                        }
                    }
                    Spacer()
                    modeMenu
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }

            VStack {
                Spacer()
                if isScanning, isAutomaticCaptureSupported {
                    captureButton
                        .padding(.bottom, 28)
                } else {
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
    }

    @ViewBuilder
    private var objectMaskMarkers: some View {
        if isScanning, !captureEngine.objectMaskMarkers.isEmpty {
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
            GeometryReader { proxy in
                Image(decorative: preview.image, scale: 1, orientation: .up)
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
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
                Text(scanStatusHeadline)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

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
                .accessibilityLabel("Clear captured object")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 240, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var scanStatusHeadline: String {
        if captureEngine.lockedObjectMaskCount > 0 {
            let visible = captureEngine.visibleObjectMaskCount
            let total = captureEngine.lockedObjectMaskCount
            return visible == total
                ? "\(total) object\(total == 1 ? "" : "s") locked"
                : "\(visible) of \(total) locks visible"
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
            return captureEngine.lockedObjectMaskCount == 1
                ? "1 colored mask"
                : "\(captureEngine.lockedObjectMaskCount) colored masks"
        }

        return captureEngine.hasObjectMaskPreview ? "RGB mask selected" : "--"
    }

    private var scanStatusText: String {
        if let feedback = captureEngine.objectMaskFeedbackText {
            return "\(feedback) Tap a new object to add it, or tap its colored marker to remove it."
        }

        if isAutomaticCaptureSupported {
            if captureEngine.lockedObjectMaskCount > 0 {
                return "\(captureEngine.statusText) Tap another object to add it, or a colored object again to remove it."
            }
            return "\(captureEngine.statusText) Tap a highlighted object to lock and track it."
        }

        if captureEngine.lockedObjectMaskCount > 0 {
            return "Tap another object to add it, or tap a colored object again to remove it."
        }

        return "Tap a distinct object to add a colored mask. Tap it again to remove it."
    }

    private var meshToggleButton: some View {
        Button {
            captureEngine.toggleMesh()
        } label: {
            Image(systemName: captureEngine.isMeshVisible ? "circle.hexagongrid.fill" : "circle.hexagongrid")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 42)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(captureEngine.isMeshVisible ? .yellow : .primary)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel(captureEngine.isMeshVisible ? "Hide scan mesh" : "Show scan mesh")
    }

    private var selectionToggleButton: some View {
        Button {
            captureEngine.toggleSelectedPoints()
        } label: {
            Image(systemName: captureEngine.showsSelectedPoints ? "circle.grid.3x3.fill" : "circle.grid.3x3")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 42)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(captureEngine.showsSelectedPoints ? .cyan : .primary)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel(captureEngine.showsSelectedPoints ? "Hide selected points" : "Show selected points")
    }

    private var captureButton: some View {
        Button {
            captureEngine.requestCapture()
        } label: {
            Label(
                captureEngine.isCapturing ? "Capturing…" : "Capture",
                systemImage: "cube.transparent"
            )
                .font(.headline.weight(.semibold))
                .foregroundStyle(
                    sessionManager.isTrackingReady
                        ? .primary
                        : .secondary
                )
                .padding(.horizontal, 22)
                .frame(height: 52)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
        .disabled(
            !sessionManager.isTrackingReady
                || captureEngine.isCapturing
        )
        .accessibilityLabel("Capture object dimensions")
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
