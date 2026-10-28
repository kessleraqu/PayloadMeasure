import ARKit
import CoreImage
import CoreVideo
import Observation
import Vision

// Touches ARKit, the Vision segmentation model and Metal once while the start screen is up,
// so their first-use cost doesn't land on the main thread during the first measurement.

@MainActor
@Observable
final class AppWarmup {
    private(set) var progress: Double = 0
    private(set) var isReady = false

    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                _ = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
                _ = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
                _ = ARWorldTrackingConfiguration.supportedVideoFormats
            }.value
            guard !Task.isCancelled else { return }
            self?.progress = 0.35

            // Running the segmentation request once on a blank frame loads and compiles the model.
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
