import ARKit
import CoreImage
import CoreVideo
import Observation
import Vision

// Loads the expensive frameworks before the operator needs them.
//
// Three things cost real time the first time they are touched: ARKit's capability queries, the
// Vision segmentation model, and Metal's shader compilation behind RealityKit. Left alone they land
// on the main thread at the worst moments — choosing a method, and the first measurement. This does
// them off the main thread while the start screen is up.
//
// In:  start(), called when the app appears.
// Out: progress from 0 to 1 and an isReady flag the start screen reads.

@MainActor
@Observable
final class AppWarmup {
    private(set) var progress: Double = 0
    private(set) var isReady = false

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            // ARKit: the first touch of these links the framework and queries the device.
            await Task.detached(priority: .userInitiated) {
                _ = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
                _ = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
                _ = ARWorldTrackingConfiguration.supportedVideoFormats
            }.value
            guard !Task.isCancelled else { return }
            self?.progress = 0.35

            // Vision: the first request loads and compiles the segmentation model. Running it once
            // on a scratch image moves that cost off the first real frame.
            await Task.detached(priority: .userInitiated) {
                guard let buffer = Self.scratchPixelBuffer() else { return }
                let handler = ImageRequestHandler(CIImage(cvPixelBuffer: buffer))
                _ = try? await handler.perform(GenerateForegroundInstanceMaskRequest())
            }.value
            guard !Task.isCancelled else { return }
            self?.progress = 1
            self?.isReady = true
        }
    }

    /// A mid-grey frame, large enough to exercise the real code path and small enough to be quick.
    private nonisolated static func scratchPixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            640,
            480,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else {
            return nil
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 128, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
