
import CoreImage
import CoreML
import CoreVideo
import Foundation
import ImageIO
import Vision

nonisolated struct EdgeTAMFrameFeatures: @unchecked Sendable {
    let visionFeatures: MLMultiArray
    let highResolutionFeature0: MLMultiArray
    let highResolutionFeature1: MLMultiArray
}

nonisolated struct EdgeTAMMask: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let predictedIoU: Float
}

nonisolated enum EdgeTAMSegmenterError: LocalizedError {
    case modelsMissing
    case inputBufferCreationFailed
    case missingOutput(String)
    case noPlausibleMask

    var errorDescription: String? {
        switch self {
        case .modelsMissing:
            "The EdgeTAM Core ML models are not present in the app bundle."
        case .inputBufferCreationFailed:
            "EdgeTAM could not create its 1024-pixel image input."
        case .missingOutput(let name):
            "The EdgeTAM model did not return its expected \(name) output."
        case .noPlausibleMask:
            "EdgeTAM did not produce a plausible object mask for that prompt."
        }
    }
}

nonisolated final class EdgeTAMSegmenter: @unchecked Sendable {
    static let inputSize = 1024
    static let maskSize = 256

    private let imageEncoder: MLModel
    private let promptEncoder: MLModel
    private let maskDecoder: MLModel
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let zeroImagePositionEncoding: MLMultiArray

    static func loadIfAvailable(bundle: Bundle = .main) -> EdgeTAMSegmenter? {
        try? EdgeTAMSegmenter(bundle: bundle)
    }

    init(bundle: Bundle = .main) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        guard let imageEncoderURL = bundle.url(
            forResource: "edgetam_image_encoder",
            withExtension: "mlmodelc"
        ), let promptEncoderURL = bundle.url(
            forResource: "edgetam_prompt_encoder",
            withExtension: "mlmodelc"
        ), let maskDecoderURL = bundle.url(
            forResource: "edgetam_mask_decoder",
            withExtension: "mlmodelc"
        ) else {
            throw EdgeTAMSegmenterError.modelsMissing
        }

        imageEncoder = try MLModel(contentsOf: imageEncoderURL, configuration: configuration)
        promptEncoder = try MLModel(contentsOf: promptEncoderURL, configuration: configuration)
        maskDecoder = try MLModel(contentsOf: maskDecoderURL, configuration: configuration)
        zeroImagePositionEncoding = try MLMultiArray(
            shape: [1, 256, 64, 64],
            dataType: .float16
        )
    }

    func encode(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) throws -> EdgeTAMFrameFeatures {
        guard let modelInput = makeModelImage(pixelBuffer, orientation: orientation) else {
            throw EdgeTAMSegmenterError.inputBufferCreationFailed
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: modelInput)
        ])
        let output = try imageEncoder.prediction(from: input)
        guard let visionFeatures = output.featureValue(for: "vision_features")?.multiArrayValue else {
            throw EdgeTAMSegmenterError.missingOutput("vision_features")
        }
        guard let highResolutionFeature0 = output.featureValue(
            for: "high_res_feat_0"
        )?.multiArrayValue else {
            throw EdgeTAMSegmenterError.missingOutput("high_res_feat_0")
        }
        guard let highResolutionFeature1 = output.featureValue(
            for: "high_res_feat_1"
        )?.multiArrayValue else {
            throw EdgeTAMSegmenterError.missingOutput("high_res_feat_1")
        }
        return EdgeTAMFrameFeatures(
            visionFeatures: visionFeatures,
            highResolutionFeature0: highResolutionFeature0,
            highResolutionFeature1: highResolutionFeature1
        )
    }

    func segment(
        features: EdgeTAMFrameFeatures,
        at point: NormalizedPoint,
        negativePoints: [NormalizedPoint] = [],
        expectedArea: CGFloat? = nil
    ) throws -> EdgeTAMMask {
        let pointCoordinates = try MLMultiArray(shape: [1, 4, 2], dataType: .float16)
        let pointLabels = try MLMultiArray(shape: [1, 4], dataType: .float16)
        let boxes = try MLMultiArray(shape: [1, 4], dataType: .float16)
        let maskInput = try MLMultiArray(shape: [1, 1, 256, 256], dataType: .float16)

        let coordinates = pointCoordinates.dataPointer.bindMemory(
            to: Float16.self,
            capacity: pointCoordinates.count
        )
        coordinates[0] = Float16(min(max(point.x, 0), 1) * CGFloat(Self.inputSize))
        coordinates[1] = Float16((1 - min(max(point.y, 0), 1)) * CGFloat(Self.inputSize))

        let labels = pointLabels.dataPointer.bindMemory(
            to: Float16.self,
            capacity: pointLabels.count
        )
        for index in 0 ..< pointLabels.count {
            labels[index] = -1
        }
        labels[0] = 1
        for (offset, negativePoint) in negativePoints.prefix(3).enumerated() {
            let promptIndex = offset + 1
            coordinates[promptIndex * 2] = Float16(
                min(max(negativePoint.x, 0), 1) * CGFloat(Self.inputSize)
            )
            coordinates[promptIndex * 2 + 1] = Float16(
                (1 - min(max(negativePoint.y, 0), 1)) * CGFloat(Self.inputSize)
            )
            labels[promptIndex] = 0
        }

        let promptInput = try MLDictionaryFeatureProvider(dictionary: [
            "point_coords": MLFeatureValue(multiArray: pointCoordinates),
            "point_labels": MLFeatureValue(multiArray: pointLabels),
            "boxes": MLFeatureValue(multiArray: boxes),
            "mask_input": MLFeatureValue(multiArray: maskInput)
        ])
        let promptOutput = try promptEncoder.prediction(from: promptInput)
        guard let sparseEmbeddings = promptOutput.featureValue(
            for: "sparse_embeddings"
        )?.multiArrayValue else {
            throw EdgeTAMSegmenterError.missingOutput("sparse_embeddings")
        }
        guard let denseEmbeddings = promptOutput.featureValue(
            for: "dense_embeddings"
        )?.multiArrayValue else {
            throw EdgeTAMSegmenterError.missingOutput("dense_embeddings")
        }

        let multimaskOutput = try MLMultiArray(shape: [1], dataType: .float16)
        multimaskOutput.dataPointer.bindMemory(to: Float16.self, capacity: 1)[0] = 1
        let decoderInput = try MLDictionaryFeatureProvider(dictionary: [
            "image_embeddings": MLFeatureValue(multiArray: features.visionFeatures),
            "image_pe": MLFeatureValue(multiArray: zeroImagePositionEncoding),
            "sparse_prompt_embeddings": MLFeatureValue(multiArray: sparseEmbeddings),
            "dense_prompt_embeddings": MLFeatureValue(multiArray: denseEmbeddings),
            "high_res_feat_0": MLFeatureValue(multiArray: features.highResolutionFeature0),
            "high_res_feat_1": MLFeatureValue(multiArray: features.highResolutionFeature1),
            "multimask_output": MLFeatureValue(multiArray: multimaskOutput)
        ])
        let decoderOutput = try maskDecoder.prediction(from: decoderInput)
        guard let masks = decoderOutput.featureValue(for: "masks")?.multiArrayValue else {
            throw EdgeTAMSegmenterError.missingOutput("masks")
        }
        guard let scores = decoderOutput.featureValue(for: "iou_pred")?.multiArrayValue else {
            throw EdgeTAMSegmenterError.missingOutput("iou_pred")
        }
        return try selectMask(
            masks,
            scores: scores,
            prompt: point,
            expectedArea: expectedArea
        )
    }

    private func makeModelImage(
        _ source: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.inputSize,
            Self.inputSize,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &output
        ) == kCVReturnSuccess, let output else {
            return nil
        }

        let upright = CIImage(cvPixelBuffer: source).oriented(orientation)
        let extent = upright.extent
        guard extent.width > 0, extent.height > 0 else {
            return nil
        }
        let normalized = upright.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        let square = normalized.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(Self.inputSize) / extent.width,
                y: CGFloat(Self.inputSize) / extent.height
            )
        )
        ciContext.render(
            square,
            to: output,
            bounds: CGRect(x: 0, y: 0, width: Self.inputSize, height: Self.inputSize),
            colorSpace: colorSpace
        )
        return output
    }

    private func selectMask(
        _ masks: MLMultiArray,
        scores: MLMultiArray,
        prompt: NormalizedPoint,
        expectedArea: CGFloat?
    ) throws -> EdgeTAMMask {
        let maskCount = masks.shape.count > 1 ? masks.shape[1].intValue : 1
        let promptX = min(max(Int(prompt.x * CGFloat(Self.maskSize)), 0), Self.maskSize - 1)
        let promptY = min(
            max(Int((1 - prompt.y) * CGFloat(Self.maskSize)), 0),
            Self.maskSize - 1
        )
        var candidates = [(index: Int, score: Float, containsPrompt: Bool, area: Int)]()

        for maskIndex in 0 ..< maskCount {
            var area = 0
            for row in 0 ..< Self.maskSize {
                for column in 0 ..< Self.maskSize where value(
                    in: masks,
                    indices: [0, maskIndex, row, column]
                ) > 0 {
                    area += 1
                }
            }
            var containsPrompt = false
            for row in max(promptY - 2, 0) ... min(promptY + 2, Self.maskSize - 1) {
                for column in max(promptX - 2, 0) ... min(promptX + 2, Self.maskSize - 1)
                where value(in: masks, indices: [0, maskIndex, row, column]) > 0 {
                    containsPrompt = true
                    break
                }
                if containsPrompt { break }
            }
            let score = value(in: scores, indices: [0, maskIndex])
            candidates.append((maskIndex, score, containsPrompt, area))
        }

        let pixelCount = Self.maskSize * Self.maskSize
        let maximumAreaFraction = expectedArea == nil ? 0.60 : 0.82
        let maximumArea = Int(Double(pixelCount) * maximumAreaFraction)
        let plausible = candidates.filter {
            guard $0.containsPrompt,
                  $0.score.isFinite,
                  $0.area > 8,
                  $0.area < maximumArea else {
                return false
            }
            guard let expectedArea, expectedArea > 0.0001 else {
                return true
            }
            let area = CGFloat($0.area) / CGFloat(pixelCount)
            let ratio = area / expectedArea
            return (0.45 ... 2.20).contains(ratio)
        }
        let selected: (index: Int, score: Float, containsPrompt: Bool, area: Int)?
        if expectedArea == nil, let primaryMask = plausible.first(where: { $0.index == 0 }) {
            selected = primaryMask
        } else {
            selected = plausible.max(by: { left, right in
                adjustedScore(left, pixelCount: pixelCount, expectedArea: expectedArea)
                    < adjustedScore(right, pixelCount: pixelCount, expectedArea: expectedArea)
            })
        }
        guard let selected else {
            throw EdgeTAMSegmenterError.noPlausibleMask
        }

        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            Self.maskSize,
            Self.maskSize,
            kCVPixelFormatType_OneComponent32Float,
            attributes as CFDictionary,
            &output
        ) == kCVReturnSuccess, let output else {
            throw EdgeTAMSegmenterError.inputBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(output) else {
            throw EdgeTAMSegmenterError.inputBufferCreationFailed
        }
        let stride = CVPixelBufferGetBytesPerRow(output) / MemoryLayout<Float>.stride
        let pixels = baseAddress.assumingMemoryBound(to: Float.self)
        for row in 0 ..< Self.maskSize {
            let outputRow = pixels.advanced(by: row * stride)
            for column in 0 ..< Self.maskSize {
                outputRow[column] = value(
                    in: masks,
                    indices: [0, selected.index, row, column]
                ) > 0 ? 1 : 0
            }
        }
        return EdgeTAMMask(pixelBuffer: output, predictedIoU: selected.score)
    }

    private func adjustedScore(
        _ candidate: (index: Int, score: Float, containsPrompt: Bool, area: Int),
        pixelCount: Int,
        expectedArea: CGFloat?
    ) -> Float {
        let area = CGFloat(candidate.area) / CGFloat(pixelCount)
        let largeRegionPenalty = Float(area * 0.10)
        guard let expectedArea, expectedArea > 0.0001 else {
            return candidate.score - largeRegionPenalty
        }
        let scalePenalty = Float(min(abs(log(max(area / expectedArea, 0.0001))), 2) * 0.18)
        return candidate.score - largeRegionPenalty - scalePenalty
    }

    private func value(in array: MLMultiArray, indices: [Int]) -> Float {
        let offset = zip(indices, array.strides).reduce(0) {
            $0 + $1.0 * $1.1.intValue
        }
        switch array.dataType {
        case .float16:
            return Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
        case .float32:
            return array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        case .double:
            return Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
        default:
            return array[offset].floatValue
        }
    }
}
