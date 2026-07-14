//
//  ObjectMaskProcessor.swift
//  PayloadMeasure
//
//  Created by Codex on 14/07/2026.
//

import CoreImage
import CoreVideo
import ImageIO
import Vision

/// A display-ready RGB segmentation preview. The image is already oriented upright for the
/// interface orientation used when Vision processed the camera frame.
nonisolated struct ObjectMaskPreview: @unchecked Sendable {
    let image: CGImage
}

/// Retains an AR camera pixel buffer while it crosses from the main actor to the Vision worker.
/// ARKit camera frames are immutable for the duration of this processing request.
nonisolated struct ObjectMaskFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
}

/// Performs foreground-instance segmentation away from the main actor. The operator selects the
/// object implicitly by keeping the center aimer over it.
actor ObjectMaskProcessor {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func makePreview(from frame: ObjectMaskFrame) async -> ObjectMaskPreview? {
        let handler = ImageRequestHandler(frame.pixelBuffer, orientation: frame.orientation)

        do {
            guard let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()),
                  let selectedInstances = selectedInstances(in: observation) else {
                return nil
            }

            let selectedMask = try observation.generateScaledMask(
                for: selectedInstances,
                scaledToImageFrom: handler
            )
            guard let image = makeDisplayImage(
                from: selectedMask,
                orientation: frame.orientation
            ) else {
                return nil
            }

            return ObjectMaskPreview(image: image)
        } catch {
            return nil
        }
    }

    /// Prefer the exact aimer location, then search a small ring around it. This makes selection
    /// tolerant of the low-resolution instance mask missing the center by a few pixels.
    private func selectedInstances(in observation: InstanceMaskObservation) -> IndexSet? {
        let center = NormalizedPoint(x: 0.5, y: 0.5)
        let centeredInstances = observation.instanceAtPoint(center)
        if !centeredInstances.isEmpty {
            return centeredInstances
        }

        let offsets: [CGFloat] = [0.025, 0.05, 0.075, 0.1]
        for offset in offsets {
            let candidates = [
                NormalizedPoint(x: 0.5 - offset, y: 0.5),
                NormalizedPoint(x: 0.5 + offset, y: 0.5),
                NormalizedPoint(x: 0.5, y: 0.5 - offset),
                NormalizedPoint(x: 0.5, y: 0.5 + offset),
                NormalizedPoint(x: 0.5 - offset, y: 0.5 - offset),
                NormalizedPoint(x: 0.5 + offset, y: 0.5 - offset),
                NormalizedPoint(x: 0.5 - offset, y: 0.5 + offset),
                NormalizedPoint(x: 0.5 + offset, y: 0.5 + offset)
            ]

            for candidate in candidates {
                let instances = observation.instanceAtPoint(candidate)
                if !instances.isEmpty {
                    return instances
                }
            }
        }

        return nil
    }

    /// Converts the single-channel instance mask into a translucent cyan fill with a stronger edge.
    private func makeDisplayImage(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> CGImage? {
        let mask = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let fill = tint(mask, alpha: 0.2)
        let edgeMask = mask.applyingFilter(
            "CIMorphologyGradient",
            parameters: [kCIInputRadiusKey: 4.0]
        )
        let edge = tint(edgeMask, alpha: 0.95)
        let preview = edge.composited(over: fill).cropped(to: mask.extent)

        return ciContext.createCGImage(preview, from: mask.extent)
    }

    private func tint(_ image: CIImage, alpha: CGFloat) -> CIImage {
        image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0.08, y: 0.82, z: 1, w: 0)
            ]
        )
    }
}
