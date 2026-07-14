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
                if isScanning {
                    captureButton
                        .padding(.bottom, 28)
                } else {
                    addPointButton
                        .padding(.bottom, 28)
                }
            }
        }
        .animation(.snappy(duration: 0.22), value: showsPanel)
        .animation(.snappy(duration: 0.18), value: measurementEngine.mode)
        .animation(.snappy(duration: 0.2), value: captureEngine.hasCapture)
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

                statusLine("Depth", sessionManager.depthStatusText)
                statusLine("Mesh", sessionManager.sceneReconstructionStatusText)
                statusLine("Planes", sessionManager.planeStatusText)
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
        if isAutomaticCaptureSupported {
            return captureEngine.statusHeadline
        }

        return captureEngine.hasObjectMaskPreview ? "Object detected" : "Finding object"
    }

    private var scanPrimaryText: String {
        if isAutomaticCaptureSupported {
            return captureEngine.primaryText
        }

        return captureEngine.hasObjectMaskPreview ? "RGB mask selected" : "--"
    }

    private var scanStatusText: String {
        if isAutomaticCaptureSupported {
            return captureEngine.statusText
        }

        if captureEngine.hasObjectMaskPreview {
            return sessionManager.automaticObjectCaptureAvailabilityText
        }

        return "Aim the center marker at a distinct object to preview its RGB boundary."
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
                isAutomaticCaptureSupported
                    ? (captureEngine.isCapturing ? "Capturing…" : "Capture")
                    : "LiDAR Required",
                systemImage: "cube.transparent"
            )
                .font(.headline.weight(.semibold))
                .foregroundStyle(
                    sessionManager.isTrackingReady && isAutomaticCaptureSupported
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
            !isAutomaticCaptureSupported
                || !sessionManager.isTrackingReady
                || captureEngine.isCapturing
        )
        .accessibilityLabel(
            isAutomaticCaptureSupported
                ? "Capture object dimensions"
                : "Automatic object capture requires LiDAR"
        )
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
