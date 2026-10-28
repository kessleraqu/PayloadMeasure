import ARKit
import AVFoundation
import CoreImage
import Observation
import RealityKit
import SwiftUI
import UIKit

// Standalone tool that captures a single ARFrame as RGB, LiDAR depth points, and both combined,
// and exports them as PDFs. It borrows the shared ARView while open and asks for a fresh AR
// world afterwards. It doesn't touch study, measurement or packing state.

// MARK: - Screen

struct LiDARCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sharedARViewHost) private var sharedARViewHost
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = LiDARCaptureController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let sharedARViewHost {
                LiDARCombinedCameraView(
                    controller: controller,
                    sharedViewHost: sharedARViewHost
                )
                .ignoresSafeArea()
            } else {
                ContentUnavailableView(
                    "Camera unavailable",
                    systemImage: "camera.fill",
                    description: Text("The shared camera renderer could not be opened.")
                )
                .foregroundStyle(.white)
            }

            VStack(spacing: 14) {
                header
                Spacer(minLength: 20)
                capturePanel
            }
            .padding(.horizontal, 18)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .persistentSystemOverlays(.hidden)
        .onChange(of: scenePhase) { _, phase in
            controller.setApplicationActive(phase == .active)
        }
        .onDisappear {
            controller.setApplicationActive(false)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close LiDAR snapshot")

            VStack(alignment: .leading, spacing: 3) {
                Text(controller.status.title)
                    .font(.headline)
                Text(controller.status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))

            Spacer(minLength: 0)
        }
        .foregroundStyle(.primary)
    }

    private var capturePanel: some View {
        VStack(spacing: 12) {
            if let message = controller.exportMessage {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(message.isError ? .red : .green)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 13))
            }

            Text("Live points come directly from ARKit's smoothed LiDAR depth map.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.82))
                .multilineTextAlignment(.center)
                .shadow(radius: 2)

            Button {
                controller.captureTriplet()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 76, height: 76)
                    Circle()
                        .stroke(.black.opacity(0.72), lineWidth: 3)
                        .frame(width: 66, height: 66)
                    if controller.isSaving {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: "camera.fill")
                            .font(.title2)
                            .foregroundStyle(.black)
                    }
                }
            }
            .disabled(!controller.canCapture)
            .opacity(controller.canCapture ? 1 : 0.45)
            .accessibilityLabel("Save RGB, LiDAR, and combined PDFs")

            Text("One press saves three matching PDFs in Files › PayloadMeasure › StudyRuns › lidar.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Session state

@MainActor
@Observable
final class LiDARCaptureController {
    struct ExportMessage: Equatable {
        let text: String
        let isError: Bool
    }

    enum Status: Equatable {
        case starting
        case waitingForDepth
        case ready(depthWidth: Int, depthHeight: Int)
        case trackingLimited(String)
        case unsupported
        case permissionDenied
        case failed(String)

        var title: String {
            switch self {
            case .starting: "Starting camera"
            case .waitingForDepth: "Starting LiDAR"
            case .ready: "LiDAR ready"
            case .trackingLimited: "Move the iPhone slowly"
            case .unsupported: "LiDAR unavailable"
            case .permissionDenied: "Camera access denied"
            case .failed: "Camera failed"
            }
        }

        var detail: String {
            switch self {
            case .starting:
                "Keep the camera pointed at the scene."
            case .waitingForDepth:
                "Waiting for a reliable depth frame."
            case .ready(let width, let height):
                "Live LiDAR points: \(width) × \(height) depth map"
            case .trackingLimited(let reason), .failed(let reason):
                reason
            case .unsupported:
                "This tool requires an iPhone or iPad that supports ARKit scene depth."
            case .permissionDenied:
                "Enable Camera for PayloadMeasure in Settings."
            }
        }
    }

    private weak var activeSession: ARSession?
    private var authorizationTask: Task<Void, Never>?
    private var applicationIsActive = true
    private(set) var status: Status = .starting
    private(set) var isSaving = false
    private(set) var exportMessage: ExportMessage?
    fileprivate var interfaceOrientation: UIInterfaceOrientation = .portrait

    var canCapture: Bool {
        guard !isSaving,
              case .ready = status,
              let frame = activeSession?.currentFrame,
              frame.denseSceneDepth != nil else {
            return false
        }
        return true
    }

    func attach(_ session: ARSession) {
        guard activeSession !== session else { return }
        authorizationTask?.cancel()
        activeSession = session
        status = Self.supportsDepth
            ? .starting
            : .unsupported
        startIfPossible()
    }

    func detach(_ session: ARSession) {
        guard activeSession === session else { return }
        authorizationTask?.cancel()
        authorizationTask = nil
        activeSession = nil
        isSaving = false
    }

    func setApplicationActive(_ isActive: Bool) {
        guard applicationIsActive != isActive else { return }
        applicationIsActive = isActive
        if isActive {
            startIfPossible()
        } else {
            activeSession?.pause()
        }
    }

    fileprivate func observe(_ frame: ARFrame, orientation: UIInterfaceOrientation) {
        interfaceOrientation = orientation
        guard !isSaving else { return }
        switch frame.camera.trackingState {
        case .normal:
            if let depth = frame.denseSceneDepth {
                let next = Status.ready(
                    depthWidth: CVPixelBufferGetWidth(depth.depthMap),
                    depthHeight: CVPixelBufferGetHeight(depth.depthMap)
                )
                if status != next { status = next }
            } else if status != .waitingForDepth {
                status = .waitingForDepth
            }
        case .limited(let reason):
            let detail: String
            switch reason {
            case .initializing: detail = "LiDAR tracking is initializing."
            case .excessiveMotion: detail = "The camera is moving too quickly."
            case .insufficientFeatures: detail = "Point at a textured, well-lit scene."
            case .relocalizing: detail = "ARKit is restoring tracking."
            @unknown default: detail = "ARKit tracking is temporarily limited."
            }
            let next = Status.trackingLimited(detail)
            if status != next { status = next }
        case .notAvailable:
            let next = Status.failed("ARKit tracking is unavailable.")
            if status != next { status = next }
        }
    }

    func captureTriplet() {
        guard canCapture,
              let frame = activeSession?.currentFrame else { return }
        isSaving = true
        exportMessage = nil
        let orientation = interfaceOrientation

        // Yield once so the shutter turns into a spinner before rendering starts.
        Task { @MainActor [weak self, frame] in
            await Task.yield()
            guard let self else { return }
            do {
                let images = try LiDARSnapshotRenderer.render(
                    frame: frame,
                    orientation: orientation
                )
                let export = try LiDARCaptureStorage.save(images, capturedAt: Date())
                exportMessage = ExportMessage(
                    text: "Saved \(export.baseName)-rgb.pdf, -lidar.pdf, and -combined.pdf.",
                    isError: false
                )
            } catch {
                exportMessage = ExportMessage(
                    text: "Could not save the PDFs: \(error.localizedDescription)",
                    isError: true
                )
            }
            isSaving = false
        }
    }

    private func startIfPossible() {
        guard let session = activeSession,
              applicationIsActive,
              Self.supportsDepth else {
            if !Self.supportsDepth {
                status = .unsupported
            }
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run(session)
        case .notDetermined:
            guard authorizationTask == nil else { return }
            status = .starting
            authorizationTask = Task { @MainActor [weak self, weak session] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard !Task.isCancelled,
                      let self,
                      let session,
                      self.activeSession === session else { return }
                self.authorizationTask = nil
                if granted {
                    self.run(session)
                } else {
                    self.status = .permissionDenied
                }
            }
        case .denied, .restricted:
            status = .permissionDenied
        @unknown default:
            status = .permissionDenied
        }
    }

    private func run(_ session: ARSession) {
        guard activeSession === session, applicationIsActive else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.environmentTexturing = .none
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        status = .waitingForDepth
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    private static var supportsDepth: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
            || ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }
}

// MARK: - Shared camera preview

private struct LiDARCombinedCameraView: UIViewRepresentable {
    let controller: LiDARCaptureController
    let sharedViewHost: SharedARViewHost

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, sharedViewHost: sharedViewHost)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView(frame: .zero)
        container.backgroundColor = .black
        context.coordinator.attach(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let controller: LiDARCaptureController
        private let sharedViewHost: SharedARViewHost
        private weak var container: UIView?
        private weak var arView: ARView?
        private var pointOverlay: LiDARPointOverlayView?
        private var priorDebugOptions: ARView.DebugOptions?
        private var lease: SharedARRendererOwnership.Lease?
        private var displayLink: CADisplayLink?
        private var lastPointUpdate: CFTimeInterval = 0
        private var startTask: Task<Void, Never>?

        init(controller: LiDARCaptureController, sharedViewHost: SharedARViewHost) {
            self.controller = controller
            self.sharedViewHost = sharedViewHost
        }

        func attach(to container: UIView) {
            self.container = container
            let lease = sharedViewHost.acquire(
                .lidarCapture,
                mountingIn: container
            ) { [weak self] in
                self?.detach()
            }
            self.lease = lease
            let arView = sharedViewHost.view
            self.arView = arView
            priorDebugOptions = arView.debugOptions
            // Hide any debug geometry from the previous owner; the original options are restored on close.
            arView.debugOptions.remove(.showSceneUnderstanding)
            arView.debugOptions.remove(.showAnchorGeometry)

            let pointOverlay = LiDARPointOverlayView(frame: .zero)
            pointOverlay.backgroundColor = .clear
            pointOverlay.isUserInteractionEnabled = false
            pointOverlay.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(pointOverlay)
            NSLayoutConstraint.activate([
                pointOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                pointOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                pointOverlay.topAnchor.constraint(equalTo: container.topAnchor),
                pointOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            self.pointOverlay = pointOverlay

            let displayLink = CADisplayLink(target: self, selector: #selector(updatePreview))
            displayLink.preferredFramesPerSecond = 10
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink

            startTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled,
                      let self,
                      self.lease == lease else { return }
                self.controller.attach(arView.session)
                self.sharedViewHost.activateCameraFeed(for: lease)
                self.startTask = nil
            }
        }

        func detach() {
            startTask?.cancel()
            startTask = nil
            displayLink?.invalidate()
            displayLink = nil
            pointOverlay?.removeFromSuperview()
            pointOverlay = nil
            if let arView {
                if let priorDebugOptions {
                    arView.debugOptions = priorDebugOptions
                }
                controller.detach(arView.session)
            }
            priorDebugOptions = nil
            arView = nil
            container = nil
            guard let lease else { return }
            self.lease = nil
            sharedViewHost.release(lease)
            // Don't let the next measurement reuse this world.
            sharedViewHost.requestNewMeasurementWorld()
        }

        @objc private func updatePreview() {
            guard let arView,
                  arView.bounds.width > 0,
                  arView.bounds.height > 0,
                  let frame = arView.session.currentFrame else { return }
            let orientation = arView.window?.windowScene?.effectiveGeometry.interfaceOrientation
                ?? .portrait
            controller.observe(frame, orientation: orientation)

            let now = CACurrentMediaTime()
            guard now - lastPointUpdate >= 0.12,
                  frame.denseSceneDepth != nil,
                  let pointOverlay else { return }
            lastPointUpdate = now
            pointOverlay.pointCloud = LiDARDepthPointProjector.project(
                frame: frame,
                orientation: orientation,
                viewportSize: arView.bounds.size,
                sampleStride: 2
            )
        }
    }
}

// MARK: - Depth point projection and drawing

nonisolated enum LiDARDepthPalette {
    static let bucketCount = 64
    static let displayRange: ClosedRange<Float> = 0.15 ... 0.60

    static func bucket(for depth: Float, range: ClosedRange<Float>) -> UInt8 {
        let span = max(range.upperBound - range.lowerBound, 0.0001)
        let normalized = min(max((depth - range.lowerBound) / span, 0), 1)
        return UInt8((normalized * Float(bucketCount - 1)).rounded())
    }

    @MainActor
    static func color(for bucket: Int, alpha: CGFloat) -> UIColor {
        let normalized = CGFloat(bucket) / CGFloat(bucketCount - 1)
        // Violet up to 15 cm, spectrum from 15 to 60 cm, red beyond.
        return UIColor(
            hue: 0.78 * (1 - normalized),
            saturation: 0.9,
            brightness: 0.96,
            alpha: alpha
        )
    }
}

nonisolated enum LiDARPointScatter {
    static let maximumCellFraction: Float = 0.32

    /// Small fixed jitter so the depth grid doesn't look like graph paper. Only the display position
    /// changes.
    static func offset(row: Int, column: Int, sampleStride: Int) -> SIMD2<Float> {
        let rowBits = UInt32(truncatingIfNeeded: row)
        let columnBits = UInt32(truncatingIfNeeded: column)
        let x = signedUnit(
            columnBits &* 0x9E37_79B1 ^ rowBits &* 0x85EB_CA77 ^ 0xA511_E9B3
        )
        let y = signedUnit(
            columnBits &* 0xC2B2_AE3D ^ rowBits &* 0x27D4_EB2F ^ 0x63D8_3595
        )
        let extent = Float(max(sampleStride, 1)) * maximumCellFraction
        return SIMD2<Float>(x * extent, y * extent)
    }

    private static func signedUnit(_ seed: UInt32) -> Float {
        var value = seed
        value ^= value >> 16
        value &*= 0x7FEB_352D
        value ^= value >> 15
        value &*= 0x846C_A68B
        value ^= value >> 16
        let normalized = Float(value & 0x00FF_FFFF) / Float(0x00FF_FFFF)
        return normalized * 2 - 1
    }
}

private struct LiDARPointCloud {
    let pointsByBucket: [[CGPoint]]
    let radius: CGFloat

    static let empty = LiDARPointCloud(
        pointsByBucket: Array(repeating: [], count: LiDARDepthPalette.bucketCount),
        radius: 1
    )

    var isEmpty: Bool { pointsByBucket.allSatisfy(\.isEmpty) }
}

private final class LiDARPointOverlayView: UIView {
    private let pointLayers = (0 ..< LiDARDepthPalette.bucketCount).map { bucket in
        let layer = CAShapeLayer()
        layer.fillColor = LiDARDepthPalette.color(for: bucket, alpha: 0.9).cgColor
        return layer
    }

    var pointCloud = LiDARPointCloud.empty {
        didSet { updatePointLayers() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        pointLayers.forEach(layer.addSublayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        pointLayers.forEach(layer.addSublayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pointLayers.forEach {
            $0.frame = bounds
            $0.contentsScale = traitCollection.displayScale
        }
        CATransaction.commit()
    }

    private func updatePointLayers() {
        let radius = pointCloud.radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (bucket, pointLayer) in pointLayers.enumerated() {
            let path = CGMutablePath()
            for point in pointCloud.pointsByBucket[bucket] {
                path.addEllipse(
                    in: CGRect(
                        x: point.x - radius,
                        y: point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
            }
            pointLayer.path = path
        }
        CATransaction.commit()
    }
}

@MainActor
private enum LiDARDepthPointProjector {

    static func project(
        frame: ARFrame,
        orientation: UIInterfaceOrientation,
        viewportSize: CGSize,
        sampleStride: Int
    ) -> LiDARPointCloud {
        guard viewportSize.width > 0,
              viewportSize.height > 0,
              let depthData = frame.denseSceneDepth else {
            return .empty
        }
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0,
              height > 0,
              CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            return .empty
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }
        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return .empty
        }

        let step = max(sampleStride, 1)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceWidth = confidenceMap.map(CVPixelBufferGetWidth) ?? 0
        let confidenceHeight = confidenceMap.map(CVPixelBufferGetHeight) ?? 0
        let confidenceRowBytes = confidenceMap.map(CVPixelBufferGetBytesPerRow) ?? 0
        let confidenceBase = confidenceMap.flatMap(CVPixelBufferGetBaseAddress)
        let imageToViewport = frame.displayTransform(
            for: orientation,
            viewportSize: viewportSize
        )

        var pointsByBucket = Array(
            repeating: [CGPoint](),
            count: LiDARDepthPalette.bucketCount
        )
        let estimatedPointCount = (width / step + 1) * (height / step + 1)
        for bucket in pointsByBucket.indices {
            pointsByBucket[bucket].reserveCapacity(estimatedPointCount / LiDARDepthPalette.bucketCount)
        }
        for row in Swift.stride(from: 0, to: height, by: step) {
            let values = depthBase
                .advanced(by: row * depthRowBytes)
                .assumingMemoryBound(to: Float32.self)
            for column in Swift.stride(from: 0, to: width, by: step) {
                let depth = values[column]
                guard depth.isFinite, (0.15 ... 5).contains(depth) else { continue }
                if let confidenceBase, confidenceWidth > 0, confidenceHeight > 0 {
                    let confidenceRow = min(row * confidenceHeight / height, confidenceHeight - 1)
                    let confidenceColumn = min(column * confidenceWidth / width, confidenceWidth - 1)
                    let confidenceValues = confidenceBase
                        .advanced(by: confidenceRow * confidenceRowBytes)
                        .assumingMemoryBound(to: UInt8.self)
                    guard confidenceValues[confidenceColumn] >= ARConfidenceLevel.medium.rawValue else {
                        continue
                    }
                }

                let scatter = LiDARPointScatter.offset(
                    row: row,
                    column: column,
                    sampleStride: step
                )
                let normalized = CGPoint(
                    x: (CGFloat(column) + 0.5 + CGFloat(scatter.x)) / CGFloat(width),
                    y: (CGFloat(row) + 0.5 + CGFloat(scatter.y)) / CGFloat(height)
                )
                let point = normalized.applying(imageToViewport)
                guard point.x.isFinite,
                      point.y.isFinite,
                      (-0.02 ... 1.02).contains(point.x),
                      (-0.02 ... 1.02).contains(point.y) else { continue }
                let bucket = Int(
                    LiDARDepthPalette.bucket(
                        for: depth,
                        range: LiDARDepthPalette.displayRange
                    )
                )
                pointsByBucket[bucket].append(
                    CGPoint(
                        x: point.x * viewportSize.width,
                        y: point.y * viewportSize.height
                    )
                )
            }
        }

        let horizontalSamples = orientation.isPortrait ? height : width
        let verticalSamples = orientation.isPortrait ? width : height
        let spacing = min(
            viewportSize.width / CGFloat(max(horizontalSamples, 1)),
            viewportSize.height / CGFloat(max(verticalSamples, 1))
        ) * CGFloat(step)
        return LiDARPointCloud(
            pointsByBucket: pointsByBucket,
            radius: max(spacing * 0.3, 0.8)
        )
    }
}

@MainActor
private enum LiDARPointDrawing {
    static func draw(
        _ pointCloud: LiDARPointCloud,
        in context: CGContext,
        alpha: CGFloat
    ) {
        guard !pointCloud.isEmpty else { return }
        context.saveGState()
        context.setShouldAntialias(true)
        let radius = pointCloud.radius
        for (bucket, points) in pointCloud.pointsByBucket.enumerated() where !points.isEmpty {
            let path = CGMutablePath()
            for point in points {
                path.addEllipse(
                    in: CGRect(
                        x: point.x - radius,
                        y: point.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
            }
            context.addPath(path)
            context.setFillColor(LiDARDepthPalette.color(for: bucket, alpha: alpha).cgColor)
            context.fillPath()
        }
        context.restoreGState()
    }
}

// MARK: - Still rendering

struct LiDARSnapshotImages {
    let rgb: UIImage
    let lidar: UIImage
    let combined: UIImage
}

enum LiDARSnapshotError: LocalizedError {
    case noDepth
    case cameraImageUnavailable
    case noVisiblePoints

    var errorDescription: String? {
        switch self {
        case .noDepth: "ARKit has not supplied a LiDAR depth frame yet."
        case .cameraImageUnavailable: "The RGB camera image could not be rendered."
        case .noVisiblePoints: "This frame contains no reliable LiDAR points."
        }
    }
}

@MainActor
enum LiDARSnapshotRenderer {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let maximumOutputDimension: CGFloat = 1_600

    static func render(
        frame: ARFrame,
        orientation: UIInterfaceOrientation
    ) throws -> LiDARSnapshotImages {
        guard frame.denseSceneDepth != nil else { throw LiDARSnapshotError.noDepth }
        let pixelBuffer = frame.capturedImage
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(source, from: source.extent) else {
            throw LiDARSnapshotError.cameraImageUnavailable
        }

        let imageOrientation = uiImageOrientation(for: orientation)
        let cameraImage = UIImage(cgImage: cgImage, scale: 1, orientation: imageOrientation)
        let rawSize = CGSize(width: cgImage.width, height: cgImage.height)
        let orientedSize = orientation.isPortrait
            ? CGSize(width: rawSize.height, height: rawSize.width)
            : rawSize
        let scale = min(maximumOutputDimension / max(orientedSize.width, orientedSize.height), 1)
        let outputSize = CGSize(
            width: max((orientedSize.width * scale).rounded(), 1),
            height: max((orientedSize.height * scale).rounded(), 1)
        )
        let pointCloud = LiDARDepthPointProjector.project(
            frame: frame,
            orientation: orientation,
            viewportSize: outputSize,
            sampleStride: 1
        )
        guard !pointCloud.isEmpty else { throw LiDARSnapshotError.noVisiblePoints }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        let bounds = CGRect(origin: .zero, size: outputSize)

        let rgb = renderer.image { context in
            UIColor.black.setFill()
            context.fill(bounds)
            cameraImage.draw(in: bounds)
        }
        let lidar = renderer.image { context in
            UIColor(red: 0.025, green: 0.035, blue: 0.055, alpha: 1).setFill()
            context.fill(bounds)
            LiDARPointDrawing.draw(pointCloud, in: context.cgContext, alpha: 1)
        }
        let combined = renderer.image { context in
            UIColor.black.setFill()
            context.fill(bounds)
            cameraImage.draw(in: bounds)
            LiDARPointDrawing.draw(pointCloud, in: context.cgContext, alpha: 0.9)
        }
        return LiDARSnapshotImages(rgb: rgb, lidar: lidar, combined: combined)
    }

    private static func uiImageOrientation(
        for orientation: UIInterfaceOrientation
    ) -> UIImage.Orientation {
        switch orientation {
        case .portraitUpsideDown: .left
        case .landscapeLeft: .up
        case .landscapeRight: .down
        case .portrait, .unknown: .right
        @unknown default: .right
        }
    }
}

private extension UIInterfaceOrientation {
    var isPortrait: Bool {
        self == .portrait || self == .portraitUpsideDown || self == .unknown
    }
}

private extension ARFrame {
    var denseSceneDepth: ARDepthData? {
        smoothedSceneDepth ?? sceneDepth
    }
}

// MARK: - Three matching PDF files

struct LiDARCaptureExport: Equatable {
    let baseName: String
    let urls: [URL]
}

enum LiDARCaptureStorage {
    static var rootFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudyRuns", isDirectory: true)
            .appendingPathComponent("lidar", isDirectory: true)
    }

    static func baseName(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date
        )
        let milliseconds = (components.nanosecond ?? 0) / 1_000_000
        return String(
            format: "%04d%02d%02d-%02d%02d%02d-%03d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0,
            milliseconds
        )
    }

    @MainActor
    static func save(
        _ images: LiDARSnapshotImages,
        capturedAt: Date
    ) throws -> LiDARCaptureExport {
        try save(images, capturedAt: capturedAt, folder: rootFolder)
    }

    @MainActor
    static func save(
        _ images: LiDARSnapshotImages,
        capturedAt: Date,
        folder: URL
    ) throws -> LiDARCaptureExport {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let initialBaseName = baseName(for: capturedAt)
        var baseName = initialBaseName
        var suffix = 2
        let outputSuffixes = ["rgb", "lidar", "combined"]
        while outputSuffixes.contains(where: {
            FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("\(baseName)-\($0).pdf").path
            )
        }) {
            baseName = "\(initialBaseName)-\(suffix)"
            suffix += 1
        }

        let outputs: [(suffix: String, image: UIImage)] = [
            ("rgb", images.rgb),
            ("lidar", images.lidar),
            ("combined", images.combined)
        ]
        let pageSize = matchingPageSize(for: images.rgb)
        let prepared = outputs.map { output in
            (
                url: folder.appendingPathComponent("\(baseName)-\(output.suffix).pdf"),
                data: pdfData(for: output.image, pageSize: pageSize)
            )
        }
        var written: [URL] = []
        do {
            for output in prepared {
                try output.data.write(to: output.url, options: .atomic)
                written.append(output.url)
            }
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return LiDARCaptureExport(baseName: baseName, urls: prepared.map(\.url))
    }

    @MainActor
    static func matchingPageSize(for image: UIImage) -> CGSize {
        let width: CGFloat = 540
        guard image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: width, height: 720)
        }
        return CGSize(width: width, height: width * image.size.height / image.size.width)
    }

    @MainActor
    static func pdfData(for image: UIImage, pageSize: CGSize) -> Data {
        let bounds = CGRect(origin: .zero, size: pageSize)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            image.draw(in: bounds)
        }
    }
}
