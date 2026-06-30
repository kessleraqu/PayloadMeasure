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

    var body: some View {
        ZStack {
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
                        HStack(spacing: 8) {
                            meshToggleButton
                            selectionToggleButton
                        }
                    }
                    Spacer()
                    modeToggle
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
                Text(captureEngine.statusHeadline)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(captureEngine.primaryText)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)

                if let secondaryText = captureEngine.secondaryText {
                    Text(secondaryText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Text(captureEngine.statusText)
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
            Label(captureEngine.isCapturing ? "Capturing…" : "Capture", systemImage: "cube.transparent")
                .font(.headline.weight(.semibold))
                .foregroundStyle(sessionManager.isTrackingReady ? .primary : .secondary)
                .padding(.horizontal, 22)
                .frame(height: 52)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
        .disabled(!sessionManager.isTrackingReady || captureEngine.isCapturing)
        .accessibilityLabel("Capture object dimensions")
    }

    private var modeToggle: some View {
        HStack(spacing: 4) {
            ForEach(MeasurementMode.allCases) { mode in
                Button {
                    measurementEngine.mode = mode
                } label: {
                    Image(systemName: mode.systemImageName)
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 38, height: 34)
                        .contentShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(measurementEngine.mode == mode ? .yellow : .primary)
                .background {
                    if measurementEngine.mode == mode {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .fill(.white.opacity(0.18))
                    }
                }
                .accessibilityLabel(mode.title)
            }
        }
        .padding(4)
        .glassEffect(.regular.interactive(), in: Capsule())
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
