import ARKit
import CoreVideo
import Foundation
import simd
import UIKit

// Turns LiDAR depth samples into a measured box. Pure computation, no ARKit session or UI.
//
// Pipeline: accumulate points, voxelise, cluster, fit a box. Full 3D fits a convex hull over all
// visible surfaces; Top does the same from a single overhead view.

nonisolated struct CapturedObject: Sendable {
    let dimensions: SIMD3<Float>
    let center: SIMD3<Float>
    let axes: (width: SIMD3<Float>, depth: SIMD3<Float>, height: SIMD3<Float>)
    let corners: [SIMD3<Float>]
    let volume: Float
    let sampleCount: Int

    var widthInMeters: Float { dimensions.x }
    var depthInMeters: Float { dimensions.y }
    var heightInMeters: Float { dimensions.z }

    /// Size in millimetres, rounded to the micrometre so float noise (400.000006 mm) doesn't push a
    /// later ceiling up by a whole millimetre. Packing and the accuracy test both use this.
    var sizeMillimetres: SIMD3<Double> {
        let raw = SIMD3(
            Double(widthInMeters) * 1000,
            Double(depthInMeters) * 1000,
            Double(heightInMeters) * 1000
        )
        return SIMD3(
            (raw.x * 1000).rounded() / 1000,
            (raw.y * 1000).rounded() / 1000,
            (raw.z * 1000).rounded() / 1000
        )
    }

    func contains(_ point: SIMD3<Float>, tolerance: Float = 0) -> Bool {
        let relative = point - center
        return abs(simd_dot(relative, axes.width)) <= dimensions.x / 2 + tolerance
            && abs(simd_dot(relative, axes.depth)) <= dimensions.y / 2 + tolerance
            && abs(simd_dot(relative, axes.height)) <= dimensions.z / 2 + tolerance
    }
}

nonisolated struct CaptureResult: Sendable {
    let object: CapturedObject
    let selectionPoints: [SIMD3<Float>]
    let surfacePoints: [SIMD3<Float>]
}

nonisolated struct AccumulatedDepthPoint: Sendable {
    let position: SIMD3<Float>
    let observedPosition: SIMD3<Float>
}

nonisolated enum CaptureOutcome: Sendable {
    case success(CaptureResult)
    case noSupport
    case notEnoughMesh
}

nonisolated struct SupportPlaneMatch: Sendable {
    let anchorIdentifier: UUID
    let height: Float
    let anchorTransform: simd_float4x4
}

nonisolated struct SupportFootprint: Sendable {
    let widthAxis: SIMD3<Float>
    let depthAxis: SIMD3<Float>
    let halfWidth: Float
    let halfDepth: Float
    let centerXZ: SIMD2<Float>

    init(widthAxis: SIMD3<Float>, width: Float, depth: Float, centerXZ: SIMD2<Float>) {
        var axis = SIMD3<Float>(widthAxis.x, 0, widthAxis.z)
        if simd_length(axis) < 1e-4 {
            axis = SIMD3<Float>(1, 0, 0)
        }
        axis = simd_normalize(axis)
        self.widthAxis = axis
        depthAxis = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), axis))
        halfWidth = max(width, 0) / 2
        halfDepth = max(depth, 0) / 2
        self.centerXZ = centerXZ
    }

    var circumscribedRadius: Float {
        (halfWidth * halfWidth + halfDepth * halfDepth).squareRoot()
    }

    func contains(x: Float, z: Float, margin: Float) -> Bool {
        let relative = SIMD3<Float>(x - centerXZ.x, 0, z - centerXZ.y)
        return abs(simd_dot(relative, widthAxis)) <= halfWidth + margin
            && abs(simd_dot(relative, depthAxis)) <= halfDepth + margin
    }

    func perimeterPoints(
        y: Float,
        margin: Float,
        minimumDistance: Float = 0.04
    ) -> [SIMD3<Float>] {
        let widthOffset = widthAxis * max(halfWidth + margin, minimumDistance)
        let depthOffset = depthAxis * max(halfDepth + margin, minimumDistance)
        let center = SIMD3<Float>(centerXZ.x, y, centerXZ.y)
        return [
            center + widthOffset,
            center - widthOffset,
            center + depthOffset,
            center - depthOffset,
            center + widthOffset + depthOffset,
            center + widthOffset - depthOffset,
            center - widthOffset + depthOffset,
            center - widthOffset - depthOffset
        ]
    }
}

nonisolated enum ObjectCapturePipeline {
    static let voxelSize: Float = 0.005
    static let supportVoxelSize: Float = 0.02
    static let accumulationRadius: Float = 0.4
    static let maxHeight: Float = 1.5
    static let minimumClusterPoints = 30
    private static let connectivityRadiusInVoxels = 2
    private static let surfaceBridgeRadiusInVoxels = 4
    private static let minimumBridgedSurfacePoints = 12
    private static let minimumSurfaceBridgeContacts = 6
    static let minObservations = 2
    static let selectionTolerance: Float = voxelSize * 0.5
    static let maxObjectVoxels = 64_000
    private static let supportRadius: Float = 0.24
    static let supportExclusionMargin: Float = 0.025
    private static let supportRingWidth: Float = 0.22

    static func capture(
        objectPoints: [AccumulatedDepthPoint],
        supportPoints: [SIMD3<Float>],
        seed: SIMD3<Float>,
        up: SIMD3<Float>,
        supportHeight: Float? = nil,
        footprint: SupportFootprint? = nil
    ) -> CaptureOutcome {
        guard !Task.isCancelled,
              objectPoints.count >= minimumClusterPoints else {
            return .notEnoughMesh
        }

        guard let resolvedSupportHeight = supportHeight
            ?? estimateSupportHeight(
                points: supportPoints,
                seed: seed,
                footprint: footprint
            ) else {
            return .noSupport
        }

        let candidates = objectPoints.filter { point in
            let heightAboveSupport = point.position.y - resolvedSupportHeight
            return heightAboveSupport > 0 && heightAboveSupport < maxHeight
        }

        guard !Task.isCancelled,
              candidates.count >= minimumClusterPoints else {
            return .notEnoughMesh
        }

        guard let cluster = VoxelCluster.connectedComponent(
            points: candidates.map(\.position),
            seed: seed,
            voxelSize: voxelSize,
            neighborRadius: connectivityRadiusInVoxels,
            bridgeRadius: surfaceBridgeRadiusInVoxels,
            minimumBridgedPointCount: minimumBridgedSurfacePoints,
            minimumBridgeContactCount: minimumSurfaceBridgeContacts
        ), cluster.points.count >= minimumClusterPoints else {
            return .notEnoughMesh
        }

        guard !Task.isCancelled else {
            return .notEnoughMesh
        }
        let selectedPoints = cluster.pointIndices.map { candidates[$0].position }
        let surfacePoints = cluster.pointIndices.map { candidates[$0].observedPosition }
        guard let object = OrientedBoundingBox.make(
            from: cluster.points,
            enclosing: surfacePoints,
            up: up,
            groundHeight: resolvedSupportHeight,
            minimumEdgeDistance: voxelSize
        ) ?? ObjectBoundingBox.make(
            from: cluster.points,
            enclosing: surfacePoints,
            up: up,
            groundHeight: resolvedSupportHeight
        ) else {
            return .notEnoughMesh
        }

        return .success(CaptureResult(
            object: object,
            selectionPoints: selectedPoints,
            surfacePoints: surfacePoints
        ))
    }

    static func captureTopView(
        objectPoints: [AccumulatedDepthPoint],
        supportPoints: [SIMD3<Float>],
        seed: SIMD3<Float>,
        up: SIMD3<Float>,
        supportHeight: Float? = nil,
        footprint: SupportFootprint? = nil
    ) -> CaptureOutcome {
        guard !Task.isCancelled,
              objectPoints.count >= minimumClusterPoints else {
            return .notEnoughMesh
        }

        guard let resolvedSupportHeight = supportHeight
            ?? estimateSupportHeight(
                points: supportPoints,
                seed: seed,
                footprint: footprint
            ) else {
            return .noSupport
        }

        let candidates = objectPoints.filter { point in
            let heightAboveSupport = point.position.y - resolvedSupportHeight
            return heightAboveSupport > 0 && heightAboveSupport < maxHeight
        }

        guard !Task.isCancelled,
              candidates.count >= minimumClusterPoints else {
            return .notEnoughMesh
        }

        guard let cluster = VoxelCluster.connectedComponent(
            points: candidates.map(\.position),
            seed: seed,
            voxelSize: voxelSize,
            neighborRadius: connectivityRadiusInVoxels,
            bridgeRadius: surfaceBridgeRadiusInVoxels,
            minimumBridgedPointCount: minimumBridgedSurfacePoints,
            minimumBridgeContactCount: minimumSurfaceBridgeContacts
        ), cluster.points.count >= minimumClusterPoints else {
            return .notEnoughMesh
        }

        guard !Task.isCancelled else {
            return .notEnoughMesh
        }
        let selectedPoints = cluster.pointIndices.map { candidates[$0].position }
        let surfacePoints = cluster.pointIndices.map { candidates[$0].observedPosition }
        guard let object = OrientedBoundingBox.make(
            from: cluster.points,
            enclosing: surfacePoints,
            up: up,
            groundHeight: resolvedSupportHeight,
            minimumEdgeDistance: voxelSize
        ) else {
            return .notEnoughMesh
        }

        return .success(CaptureResult(
            object: object,
            selectionPoints: selectedPoints,
            surfacePoints: surfacePoints
        ))
    }

    static func supportPlaneMatch(
        from anchors: [ARAnchor],
        beneath referencePoint: SIMD3<Float>,
        validating samplePoints: [SIMD3<Float>],
        preferredAnchorIdentifier: UUID?
    ) -> SupportPlaneMatch? {
        struct Candidate {
            let match: SupportPlaneMatch
            let coveredSampleCount: Int
            let classificationPriority: Int
        }

        let validationPoints = samplePoints.isEmpty ? [referencePoint] : samplePoints
        let minimumCoveredSamples = min(3, max(1, validationPoints.count / 2))
        var candidates: [Candidate] = []

        for case let anchor as ARPlaneAnchor in anchors where anchor.alignment == .horizontal {
            if anchor.classification == .ceiling {
                continue
            }
            let local = anchor.transform.inverse * SIMD4<Float>(referencePoint, 1)
            let boundary = anchor.geometry.boundaryVertices
            let coveredSampleCount = validationPoints.count { point in
                let localPoint = anchor.transform.inverse * SIMD4<Float>(point, 1)
                return boundaryContains(
                    SIMD2<Float>(localPoint.x, localPoint.z),
                    vertices: boundary,
                    tolerance: 0.012
                )
            }
            guard coveredSampleCount >= minimumCoveredSamples else {
                continue
            }

            let worldPlanePoint = anchor.transform * SIMD4<Float>(local.x, 0, local.z, 1)
            let height = worldPlanePoint.y
            let distanceBelowReference = referencePoint.y - height
            guard distanceBelowReference >= 0.005,
                  distanceBelowReference <= maxHeight + 0.1 else {
                continue
            }
            candidates.append(Candidate(
                match: SupportPlaneMatch(
                    anchorIdentifier: anchor.identifier,
                    height: height,
                    anchorTransform: anchor.transform
                ),
                coveredSampleCount: coveredSampleCount,
                classificationPriority: supportClassificationPriority(anchor.classification)
            ))
        }

        let bestCandidate = candidates.max { first, second in
            if abs(first.match.height - second.match.height) > 0.01 {
                return first.match.height < second.match.height
            }
            if first.classificationPriority != second.classificationPriority {
                return first.classificationPriority < second.classificationPriority
            }
            if first.coveredSampleCount != second.coveredSampleCount {
                return first.coveredSampleCount < second.coveredSampleCount
            }
            return first.match.height < second.match.height
        }

        if let preferredAnchorIdentifier,
           let preferred = candidates.first(where: {
               $0.match.anchorIdentifier == preferredAnchorIdentifier
           }), let bestCandidate,
           bestCandidate.match.height - preferred.match.height <= 0.015 {
            return preferred.match
        }

        return bestCandidate?.match
    }

    static func resolvedSupportHeight(
        planeHeight: Float?,
        raycastHeight: Float?,
        supportPoints: [SIMD3<Float>],
        seed: SIMD3<Float>,
        footprint: SupportFootprint?
    ) -> Float? {
        planeHeight
            ?? raycastHeight
            ?? estimateSupportHeight(
                points: supportPoints,
                seed: seed,
                footprint: footprint
            )
    }

    private static func supportClassificationPriority(
        _ classification: ARPlaneAnchor.Classification
    ) -> Int {
        switch classification {
        case .floor, .table:
            3
        case .seat:
            2
        case .none:
            1
        case .ceiling, .wall, .door, .window:
            0
        @unknown default:
            1
        }
    }

    private static func estimateSupportHeight(
        points: [SIMD3<Float>],
        seed: SIMD3<Float>,
        footprint: SupportFootprint?
    ) -> Float? {
        let innerRadius = (footprint?.circumscribedRadius ?? 0) + supportExclusionMargin
        let outerRadius = max(supportRadius, innerRadius + supportRingWidth)
        let outerRadiusSquared = outerRadius * outerRadius
        let innerRadiusSquared = innerRadius * innerRadius

        var nearbyHeights: [Float] = []
        for point in points {
            let deltaX = point.x - seed.x
            let deltaZ = point.z - seed.z
            let distanceSquared = deltaX * deltaX + deltaZ * deltaZ
            guard distanceSquared < outerRadiusSquared,
                  point.y <= seed.y + 0.04 else {
                continue
            }
            if let footprint {
                if footprint.contains(
                    x: point.x,
                    z: point.z,
                    margin: supportExclusionMargin
                ) {
                    continue
                }
            } else if distanceSquared < innerRadiusSquared {
                continue
            }
            nearbyHeights.append(point.y)
        }

        guard nearbyHeights.count >= 20 else {
            return nil
        }

        let binSize: Float = 0.004
        var histogram: [Int: Int] = [:]
        for height in nearbyHeights {
            histogram[Int((height / binSize).rounded()), default: 0] += 1
        }
        guard let strongestCount = histogram.values.max() else {
            return nil
        }

        let minimumBinCount = max(12, Int(Float(strongestCount) * 0.35))
        guard let supportBin = histogram.keys.filter({ key in
            histogram[key, default: 0] >= minimumBinCount
        }).max() else {
            return nil
        }

        let centerHeight = Float(supportBin) * binSize
        var inliers = nearbyHeights.filter { abs($0 - centerHeight) <= binSize * 1.5 }
        guard inliers.count >= 12 else {
            return nil
        }
        inliers.sort()
        return inliers[inliers.count / 2]
    }

    private static func boundaryContains(
        _ point: SIMD2<Float>,
        vertices: [SIMD3<Float>],
        tolerance: Float
    ) -> Bool {
        guard vertices.count >= 3 else {
            return false
        }

        var isInside = false
        var previous = vertices[vertices.count - 1]
        var minimumDistanceSquared = Float.greatestFiniteMagnitude
        for current in vertices {
            let first = SIMD2<Float>(previous.x, previous.z)
            let second = SIMD2<Float>(current.x, current.z)
            let edge = second - first
            let edgeLengthSquared = simd_length_squared(edge)
            if edgeLengthSquared > 0 {
                let projection = min(
                    max(simd_dot(point - first, edge) / edgeLengthSquared, 0),
                    1
                )
                minimumDistanceSquared = min(
                    minimumDistanceSquared,
                    simd_length_squared(point - (first + edge * projection))
                )
            }
            if (current.z > point.y) != (previous.z > point.y) {
                let intersectionX = (previous.x - current.x)
                    * (point.y - current.z)
                    / (previous.z - current.z)
                    + current.x
                if point.x < intersectionX {
                    isInside.toggle()
                }
            }
            previous = current
        }
        return isInside || minimumDistanceSquared <= tolerance * tolerance
    }
}

actor ObjectCaptureFitter {
    func capture(
        objectPoints: [AccumulatedDepthPoint],
        supportPoints: [SIMD3<Float>],
        seed: SIMD3<Float>,
        supportHeight: Float?,
        footprint: SupportFootprint?,
        mode: MeasurementWorkflowMode
    ) -> CaptureOutcome {
        switch mode {
        case .spatial3D:
            return ObjectCapturePipeline.capture(
                objectPoints: objectPoints,
                supportPoints: supportPoints,
                seed: seed,
                up: SIMD3<Float>(0, 1, 0),
                supportHeight: supportHeight,
                footprint: footprint
            )
        case .top:
            return ObjectCapturePipeline.captureTopView(
                objectPoints: objectPoints,
                supportPoints: supportPoints,
                seed: seed,
                up: SIMD3<Float>(0, 1, 0),
                supportHeight: supportHeight,
                footprint: footprint
            )
        }
    }
}

enum DepthPointCloud {
    static func worldPoint(
        from frame: ARFrame,
        normalizedViewportPoint: CGPoint,
        interfaceOrientation: UIInterfaceOrientation,
        viewportSize: CGSize
    ) -> SIMD3<Float>? {
        guard let sceneDepth = frame.sceneDepth,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return nil
        }

        let viewportToImage = frame.displayTransform(
            for: interfaceOrientation,
            viewportSize: viewportSize
        ).inverted()
        let imagePoint = normalizedViewportPoint.applying(viewportToImage)
        guard (0 ... 1).contains(imagePoint.x), (0 ... 1).contains(imagePoint.y) else {
            return nil
        }

        let depthMap = sceneDepth.depthMap
        let confidenceMap = sceneDepth.confidenceMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let centerX = min(max(Int(imagePoint.x * CGFloat(width)), 0), width - 1)
        let centerY = min(max(Int(imagePoint.y * CGFloat(height)), 0), height - 1)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return nil
        }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        var validSamples: [(depth: Float, x: Int, y: Int)] = []

        for y in max(centerY - 2, 0) ... min(centerY + 2, height - 1) {
            let depthRow = depthBase
                .advanced(by: y * depthRowBytes)
                .assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase?
                .advanced(by: y * confidenceRowBytes)
                .assumingMemoryBound(to: UInt8.self)
            for x in max(centerX - 2, 0) ... min(centerX + 2, width - 1) {
                let depth = depthRow[x]
                if depth > 0.12, depth < 3.5, (confidenceRow?[x] ?? 2) >= 1 {
                    validSamples.append((depth, x, y))
                }
            }
        }

        guard !validSamples.isEmpty else {
            return nil
        }
        validSamples.sort { $0.depth < $1.depth }
        let sample = validSamples[validSamples.count / 2]

        let imageResolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let scaleX = Float(width) / Float(imageResolution.width)
        let scaleY = Float(height) / Float(imageResolution.height)
        let fx = intrinsics.columns.0.x * scaleX
        let fy = intrinsics.columns.1.y * scaleY
        let cx = intrinsics.columns.2.x * scaleX
        let cy = intrinsics.columns.2.y * scaleY
        guard fx > 0, fy > 0 else {
            return nil
        }

        let x = (Float(sample.x) - cx) * sample.depth / fx
        let y = (Float(sample.y) - cy) * sample.depth / fy
        let cameraPoint = SIMD4<Float>(x, -y, -sample.depth, 1)
        let worldPoint = frame.camera.transform * cameraPoint
        guard worldPoint.x.isFinite, worldPoint.y.isFinite, worldPoint.z.isFinite else {
            return nil
        }
        return SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)
    }

    static func worldPoints(
        from frame: ARFrame,
        near seeds: [UUID: SIMD3<Float>],
        radius: Float,
        pixelStride: Int = 2
    ) -> [UUID: [SIMD3<Float>]] {
        guard !seeds.isEmpty,
              let sceneDepth = frame.sceneDepth else {
            return [:]
        }

        let depthMap = sceneDepth.depthMap
        let confidenceMap = sceneDepth.confidenceMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let imageResolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let scaleX = Float(width) / Float(imageResolution.width)
        let scaleY = Float(height) / Float(imageResolution.height)
        let fx = intrinsics.columns.0.x * scaleX
        let fy = intrinsics.columns.1.y * scaleY
        let cx = intrinsics.columns.2.x * scaleX
        let cy = intrinsics.columns.2.y * scaleY
        guard fx > 0, fy > 0 else {
            return [:]
        }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return [:]
        }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let cameraTransform = frame.camera.transform
        let radiusSquared = radius * radius
        let seedList = Array(seeds)
        var pointsByObject = Dictionary(
            uniqueKeysWithValues: seedList.map { ($0.key, [SIMD3<Float>]()) }
        )

        var row = 0
        while row < height {
            let depthRow = depthBase
                .advanced(by: row * depthRowBytes)
                .assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase?
                .advanced(by: row * confidenceRowBytes)
                .assumingMemoryBound(to: UInt8.self)

            var column = 0
            while column < width {
                let depth = depthRow[column]
                if depth > 0.15, depth < 2.5, (confidenceRow?[column] ?? 2) >= 1 {
                    let x = (Float(column) - cx) * depth / fx
                    let y = (Float(row) - cy) * depth / fy
                    let world = cameraTransform * SIMD4<Float>(x, -y, -depth, 1)
                    if world.x.isFinite, world.y.isFinite, world.z.isFinite {
                        let point = SIMD3<Float>(world.x, world.y, world.z)
                        for (id, seed) in seedList {
                            if simd_length_squared(point - seed) < radiusSquared {
                                pointsByObject[id, default: []].append(point)
                            }
                        }
                    }
                }
                column += pixelStride
            }
            row += pixelStride
        }

        return pointsByObject
    }
}

nonisolated struct PointAccumulator: Sendable {
    private struct Key: Hashable, Sendable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    private struct FrameSample: Sendable {
        var sum: SIMD3<Float>
        var count: Int32
        var observedPoint: SIMD3<Float>
    }

    private struct Sample: Sendable {
        var sum: SIMD3<Float>
        var observationCount: Int32
        var lastSeenGeneration: Int32
        var stablePoint: SIMD3<Float>?
        var observedPoint: SIMD3<Float>
        var stableObservedPoint: SIMD3<Float>?
    }

    private var samples: [Key: Sample] = [:]
    private var stableKeys: [Key] = []
    private var stablePoints: [AccumulatedDepthPoint] = []
    private var stablePointIndices: [Key: Int] = [:]
    private var generation: Int32 = 0
    private var lastAddedTimestamp: TimeInterval?
    private let voxelSize: Float
    private let maxVoxels: Int?

    private func key(for point: SIMD3<Float>) -> Key {
        Key(
            x: Int32(floor(point.x / voxelSize)),
            y: Int32(floor(point.y / voxelSize)),
            z: Int32(floor(point.z / voxelSize))
        )
    }

    private func center(for key: Key) -> SIMD3<Float> {
        SIMD3<Float>(
            (Float(key.x) + 0.5) * voxelSize,
            (Float(key.y) + 0.5) * voxelSize,
            (Float(key.z) + 0.5) * voxelSize
        )
    }

    private static func stablePriority(for key: Key) -> UInt64 {
        let prime: UInt64 = 1_099_511_628_211
        var hash: UInt64 = 14_695_981_039_346_656_037
        hash = (hash ^ UInt64(UInt32(bitPattern: key.x))) &* prime
        hash = (hash ^ UInt64(UInt32(bitPattern: key.y))) &* prime
        hash = (hash ^ UInt64(UInt32(bitPattern: key.z))) &* prime
        return hash
    }

    init(voxelSize: Float, maxVoxels: Int? = 8_000) {
        self.voxelSize = voxelSize
        self.maxVoxels = maxVoxels
    }

    var isAtCapacity: Bool {
        guard let maxVoxels else {
            return false
        }
        return samples.count >= maxVoxels
    }

    var stablePointCount: Int {
        stablePoints.count
    }

    @discardableResult
    mutating func add(
        _ points: [SIMD3<Float>],
        timestamp: TimeInterval? = nil,
        stabilizationObservations: Int? = nil
    ) -> Int {
        if let timestamp {
            guard timestamp > (lastAddedTimestamp ?? -.greatestFiniteMagnitude) else {
                return 0
            }
            lastAddedTimestamp = timestamp
        }
        generation &+= 1

        var frameSamples: [Key: FrameSample] = [:]
        var frameKeyOrder: [Key] = []
        let frameCapacity = min(points.count, maxVoxels ?? points.count)
        frameSamples.reserveCapacity(frameCapacity)
        frameKeyOrder.reserveCapacity(frameCapacity)

        for point in points {
            let key = key(for: point)
            if var frameSample = frameSamples[key] {
                frameSample.sum += point
                frameSample.count &+= 1
                let voxelCenter = center(for: key)
                if simd_length_squared(point - voxelCenter)
                    < simd_length_squared(frameSample.observedPoint - voxelCenter) {
                    frameSample.observedPoint = point
                }
                frameSamples[key] = frameSample
            } else {
                frameSamples[key] = FrameSample(
                    sum: point,
                    count: 1,
                    observedPoint: point
                )
                frameKeyOrder.append(key)
            }
        }

        let stabilizationThreshold = stabilizationObservations.map {
            Int32(max($0, 1))
        }

        var newlyStabilizedCount = 0
        for key in frameKeyOrder {
            guard var sample = samples[key],
                  let frameSample = frameSamples[key] else {
                continue
            }
            let framePoint = frameSample.sum / Float(frameSample.count)
            sample.sum += framePoint
            sample.observationCount &+= 1
            sample.lastSeenGeneration = generation
            let runningMean = sample.sum / Float(sample.observationCount)
            if simd_length_squared(frameSample.observedPoint - runningMean)
                < simd_length_squared(sample.observedPoint - runningMean) {
                sample.observedPoint = frameSample.observedPoint
            }
            if sample.stablePoint == nil,
               let stabilizationThreshold,
               sample.observationCount >= stabilizationThreshold {
                sample.stablePoint = runningMean
                sample.stableObservedPoint = sample.observedPoint
                newlyStabilizedCount += 1
            }
            samples[key] = sample
            if sample.stablePoint != nil {
                recordStablePointIfNeeded(for: key, sample: sample)
            }
        }

        let unsortedNewKeys = frameKeyOrder.filter { samples[$0] == nil }
        let newKeys: [Key]
        if let maxVoxels,
           samples.count + unsortedNewKeys.count > maxVoxels {
            newKeys = unsortedNewKeys.sorted { left, right in
                let leftPriority = Self.stablePriority(for: left)
                let rightPriority = Self.stablePriority(for: right)
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                if left.x != right.x { return left.x < right.x }
                if left.y != right.y { return left.y < right.y }
                return left.z < right.z
            }
        } else {
            newKeys = unsortedNewKeys
        }
        if stabilizationThreshold != nil, let maxVoxels {
            var requiredSlots = max(samples.count + newKeys.count - maxVoxels, 0)
            if requiredSlots > 0 {
                let removableUnconfirmed = samples.compactMap { entry in
                    entry.value.stablePoint == nil
                        && entry.value.lastSeenGeneration < generation
                        ? (key: entry.key, sample: entry.value)
                        : nil
                }.sorted { left, right in
                    if left.sample.observationCount != right.sample.observationCount {
                        return left.sample.observationCount < right.sample.observationCount
                    }
                    if left.sample.lastSeenGeneration != right.sample.lastSeenGeneration {
                        return left.sample.lastSeenGeneration < right.sample.lastSeenGeneration
                    }
                    if left.key.x != right.key.x { return left.key.x < right.key.x }
                    if left.key.y != right.key.y { return left.key.y < right.key.y }
                    return left.key.z < right.key.z
                }
                let unconfirmedKeys = removableUnconfirmed.prefix(requiredSlots).map(\.key)
                remove(unconfirmedKeys)
                requiredSlots -= unconfirmedKeys.count

                if requiredSlots > 0 {
                    let removableStable = samples.compactMap { entry in
                        entry.value.stablePoint != nil
                            && entry.value.lastSeenGeneration < generation
                            ? (key: entry.key, sample: entry.value)
                            : nil
                    }.sorted { left, right in
                        if left.sample.lastSeenGeneration != right.sample.lastSeenGeneration {
                            return left.sample.lastSeenGeneration < right.sample.lastSeenGeneration
                        }
                        if left.sample.observationCount != right.sample.observationCount {
                            return left.sample.observationCount < right.sample.observationCount
                        }
                        if left.key.x != right.key.x { return left.key.x < right.key.x }
                        if left.key.y != right.key.y { return left.key.y < right.key.y }
                        return left.key.z < right.key.z
                    }
                    let maximumStableReplacementsPerFrame = 256
                    remove(
                        removableStable
                            .prefix(min(requiredSlots, maximumStableReplacementsPerFrame))
                            .map(\.key)
                    )
                }
            }
        }

        for key in newKeys {
            if let maxVoxels, samples.count >= maxVoxels {
                break
            }
            guard let frameSample = frameSamples[key] else {
                continue
            }
            let framePoint = frameSample.sum / Float(frameSample.count)
            let stablePoint = stabilizationThreshold == 1 ? framePoint : nil
            samples[key] = Sample(
                sum: framePoint,
                observationCount: 1,
                lastSeenGeneration: generation,
                stablePoint: stablePoint,
                observedPoint: frameSample.observedPoint,
                stableObservedPoint: stablePoint == nil ? nil : frameSample.observedPoint
            )
            if stablePoint != nil {
                newlyStabilizedCount += 1
                if let sample = samples[key] {
                    recordStablePointIfNeeded(for: key, sample: sample)
                }
            }
        }
        return newlyStabilizedCount
    }

    func points(minObservations: Int = 1) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(samples.count)
        for sample in samples.values {
            if sample.observationCount >= Int32(minObservations) {
                result.append(
                    sample.stablePoint
                        ?? sample.sum / Float(sample.observationCount)
                )
            }
        }
        return result
    }
    func stablePointsSnapshot() -> [AccumulatedDepthPoint] {
        stablePoints
    }

    /// Re-expresses the accumulated points in a corrected world frame.
    ///
    /// When ARKit refines an anchor the points are still valid, just in the old frame, so they are
    /// transformed rather than thrown away. The correction is rigid, so the running means carry over
    /// exactly. Voxels that land in the same cell are merged. `stableKeys` keeps its order because
    /// the reservoir sample in the box fitter depends on it (see `remove(_:)`).
    func transformed(by matrix: simd_float4x4) -> PointAccumulator {
        var result = PointAccumulator(voxelSize: voxelSize, maxVoxels: maxVoxels)
        result.generation = generation
        result.lastAddedTimestamp = lastAddedTimestamp

        func moved(_ point: SIMD3<Float>) -> SIMD3<Float> {
            let value = matrix * SIMD4<Float>(point, 1)
            return SIMD3<Float>(value.x, value.y, value.z)
        }

        func carry(_ key: Key, _ sample: Sample) {
            let count = Float(max(sample.observationCount, 1))
            let movedMean = moved(sample.sum / count)
            let newKey = result.key(for: movedMean)
            let movedObserved = moved(sample.observedPoint)
            let movedStable = sample.stablePoint.map(moved)
            let movedStableObserved = sample.stableObservedPoint.map(moved)

            if var existing = result.samples[newKey] {
                existing.sum += movedMean * count
                existing.observationCount += sample.observationCount
                existing.lastSeenGeneration = max(
                    existing.lastSeenGeneration,
                    sample.lastSeenGeneration
                )
                if existing.stablePoint == nil, let movedStable {
                    existing.stablePoint = movedStable
                    existing.stableObservedPoint = movedStableObserved ?? movedObserved
                }
                result.samples[newKey] = existing
            } else {
                result.samples[newKey] = Sample(
                    sum: movedMean * count,
                    observationCount: sample.observationCount,
                    lastSeenGeneration: sample.lastSeenGeneration,
                    stablePoint: movedStable,
                    observedPoint: movedObserved,
                    stableObservedPoint: movedStableObserved
                )
            }
            if let sample = result.samples[newKey], sample.stablePoint != nil {
                result.recordStablePointIfNeeded(for: newKey, sample: sample)
            }
        }

        var carried = Set<Key>()
        for key in stableKeys {
            guard let sample = samples[key] else { continue }
            carry(key, sample)
            carried.insert(key)
        }
        for (key, sample) in samples where !carried.contains(key) {
            carry(key, sample)
        }
        return result
    }

    mutating func pruneTransient(below minCount: Int, olderThan minimumAge: Int = 0) {
        let oldestRecentGeneration = generation - Int32(max(minimumAge, 0))
        let stale: [Key] = samples.compactMap { entry in
            let (key, sample) = entry
            guard sample.observationCount < Int32(minCount),
                  sample.lastSeenGeneration <= oldestRecentGeneration else {
                return nil
            }
            return key
        }
        remove(stale)
    }

    mutating func pruneStale(olderThan maximumAge: Int) {
        let oldestAllowedGeneration = generation - Int32(max(maximumAge, 1))
        let stale: [Key] = samples.compactMap {
            $0.value.lastSeenGeneration < oldestAllowedGeneration ? $0.key : nil
        }
        remove(stale)
    }

    @discardableResult
    mutating func removeVoxels(containing points: [SIMD3<Float>]) -> Int {
        let keys = Set(points.map(key(for:)))
        let removedCount = keys.count(where: { samples[$0] != nil })
        remove(Array(keys))
        return removedCount
    }

    /// Removes a batch of voxels while keeping the remaining stable points in their original order.
    ///
    /// The orientation search reservoir-samples the stable points with a fixed seed, so the result
    /// depends on array order. A swap-remove reshuffles the array and made the fitted box rotate from
    /// frame to frame. One compaction pass per batch keeps the order and is O(n).
    private mutating func remove(_ keys: [Key]) {
        for key in keys {
            samples[key] = nil
        }
        let victims = Set(keys)
        guard victims.contains(where: { stablePointIndices[$0] != nil }) else {
            return
        }
        var newStableKeys: [Key] = []
        var newStablePoints: [AccumulatedDepthPoint] = []
        newStableKeys.reserveCapacity(stableKeys.count)
        newStablePoints.reserveCapacity(stablePoints.count)
        for index in stableKeys.indices where !victims.contains(stableKeys[index]) {
            newStableKeys.append(stableKeys[index])
            newStablePoints.append(stablePoints[index])
        }
        stableKeys = newStableKeys
        stablePoints = newStablePoints
        stablePointIndices.removeAll(keepingCapacity: true)
        for (index, key) in stableKeys.enumerated() {
            stablePointIndices[key] = index
        }
    }

    private mutating func recordStablePointIfNeeded(
        for key: Key,
        sample: Sample
    ) {
        guard stablePointIndices[key] == nil,
              let position = sample.stablePoint else {
            return
        }
        stablePointIndices[key] = stablePoints.count
        stableKeys.append(key)
        stablePoints.append(
            AccumulatedDepthPoint(
                position: position,
                observedPosition: sample.stableObservedPoint
                    ?? sample.observedPoint
            )
        )
    }
}

nonisolated enum VoxelCluster {
    private struct Key: Hashable {
        let x: Int
        let y: Int
        let z: Int
    }

    static func connectedComponent(
        points: [SIMD3<Float>],
        seed: SIMD3<Float>,
        voxelSize: Float,
        neighborRadius: Int = 1,
        bridgeRadius: Int? = nil,
        minimumBridgedPointCount: Int = 0,
        minimumBridgeContactCount: Int = 1
    ) -> (points: [SIMD3<Float>], pointIndices: [Int])? {
        guard !points.isEmpty, voxelSize > 0 else {
            return nil
        }

        func key(_ point: SIMD3<Float>) -> Key {
            Key(
                x: Int(floor(point.x / voxelSize)),
                y: Int(floor(point.y / voxelSize)),
                z: Int(floor(point.z / voxelSize))
            )
        }

        var voxelToPoints: [Key: [Int]] = [:]
        for (index, point) in points.enumerated() {
            if index.isMultiple(of: 1_024), Task.isCancelled {
                return nil
            }
            voxelToPoints[key(point), default: []].append(index)
        }

        let occupied = Set(voxelToPoints.keys)
        guard let seedKey = seedVoxel(for: key(seed), in: occupied) else {
            return nil
        }

        let neighborRadius = max(neighborRadius, 1)
        let neighborRadiusSquared = neighborRadius * neighborRadius
        var neighborOffsets: [(x: Int, y: Int, z: Int)] = []
        for dx in -neighborRadius...neighborRadius {
            for dy in -neighborRadius...neighborRadius {
                for dz in -neighborRadius...neighborRadius {
                    let distanceSquared = dx * dx + dy * dy + dz * dz
                    if distanceSquared > 0, distanceSquared <= neighborRadiusSquared {
                        neighborOffsets.append((dx, dy, dz))
                    }
                }
            }
        }

        func takeComponent(start: Key, from remaining: inout Set<Key>) -> [Key] {
            var component: [Key] = [start]
            var head = 0
            remaining.remove(start)
            while head < component.count {
                if head.isMultiple(of: 512), Task.isCancelled {
                    remaining.removeAll()
                    return []
                }
                let voxel = component[head]
                head += 1
                for offset in neighborOffsets {
                    let neighbour = Key(
                        x: voxel.x + offset.x,
                        y: voxel.y + offset.y,
                        z: voxel.z + offset.z
                    )
                    if remaining.remove(neighbour) != nil {
                        component.append(neighbour)
                    }
                }
            }
            return component
        }

        var remaining = occupied
        var selected = Set(takeComponent(start: seedKey, from: &remaining))
        guard !Task.isCancelled, !selected.isEmpty else {
            return nil
        }
        var secondaryComponents: [[Key]] = []
        while let start = remaining.first {
            guard !Task.isCancelled else {
                return nil
            }
            let component = takeComponent(start: start, from: &remaining)
            let pointCount = component.reduce(into: 0) { count, voxel in
                count += voxelToPoints[voxel]?.count ?? 0
            }
            if pointCount >= max(minimumBridgedPointCount, 1) {
                secondaryComponents.append(component)
            }
        }

        let bridgeRadius = max(bridgeRadius ?? neighborRadius, neighborRadius)
        if bridgeRadius > neighborRadius, !secondaryComponents.isEmpty {
            let bridgeRadiusSquared = bridgeRadius * bridgeRadius
            var bridgeOffsets: [(x: Int, y: Int, z: Int)] = []
            for dx in -bridgeRadius...bridgeRadius {
                for dy in -bridgeRadius...bridgeRadius {
                    for dz in -bridgeRadius...bridgeRadius {
                        let distanceSquared = dx * dx + dy * dy + dz * dz
                        if distanceSquared > neighborRadiusSquared,
                           distanceSquared <= bridgeRadiusSquared {
                            bridgeOffsets.append((dx, dy, dz))
                        }
                    }
                }
            }

            let requiredContacts = max(minimumBridgeContactCount, 1)
            var pendingComponents = secondaryComponents
            var addedComponent = true
            while addedComponent, !pendingComponents.isEmpty {
                guard !Task.isCancelled else {
                    return nil
                }
                addedComponent = false
                var remainingComponents: [[Key]] = []
                for component in pendingComponents {
                    var contactCount = 0
                    for voxel in component {
                        var touchesSelection = false
                        for offset in bridgeOffsets {
                            if selected.contains(
                                Key(
                                    x: voxel.x + offset.x,
                                    y: voxel.y + offset.y,
                                    z: voxel.z + offset.z
                                )
                            ) {
                                touchesSelection = true
                                break
                            }
                        }
                        if touchesSelection {
                            contactCount += 1
                            if contactCount >= requiredContacts {
                                selected.formUnion(component)
                                addedComponent = true
                                break
                            }
                        }
                    }
                    if contactCount < requiredContacts {
                        remainingComponents.append(component)
                    }
                }
                pendingComponents = remainingComponents
            }
        }

        var componentPoints: [SIMD3<Float>] = []
        var pointIndices: [Int] = []
        let orderedVoxels = selected.sorted { left, right in
            if left.x != right.x { return left.x < right.x }
            if left.y != right.y { return left.y < right.y }
            return left.z < right.z
        }
        for (voxelIndex, voxel) in orderedVoxels.enumerated() {
            if voxelIndex.isMultiple(of: 512), Task.isCancelled {
                return nil
            }
            guard let indices = voxelToPoints[voxel] else {
                continue
            }
            for index in indices {
                componentPoints.append(points[index])
                pointIndices.append(index)
            }
        }

        return (componentPoints, pointIndices)
    }

    private static func seedVoxel(for key: Key, in occupied: Set<Key>) -> Key? {
        if occupied.contains(key) {
            return key
        }

        let maxRing = 5
        for ring in 1...maxRing {
            for dx in -ring...ring {
                for dy in -ring...ring {
                    for dz in -ring...ring where max(abs(dx), max(abs(dy), abs(dz))) == ring {
                        let neighbour = Key(x: key.x + dx, y: key.y + dy, z: key.z + dz)
                        if occupied.contains(neighbour) {
                            return neighbour
                        }
                    }
                }
            }
        }

        return nil
    }
}

nonisolated enum ObjectBoundingBox {
    static func make(
        from points: [SIMD3<Float>],
        enclosing enclosurePoints: [SIMD3<Float>] = [],
        up: SIMD3<Float>,
        groundHeight: Float? = nil
    ) -> CapturedObject? {
        guard points.count >= 12 else {
            return nil
        }

        let upAxis = simd_length(up) > 0 ? simd_normalize(up) : SIMD3<Float>(0, 1, 0)

        var e1 = projectOntoPlane(SIMD3<Float>(1, 0, 0), normal: upAxis)
        if simd_length(e1) < 1e-4 {
            e1 = projectOntoPlane(SIMD3<Float>(0, 0, 1), normal: upAxis)
        }
        e1 = simd_normalize(e1)
        let e2 = simd_normalize(simd_cross(upAxis, e1))

        var centroid = SIMD3<Float>(repeating: 0)
        for point in points {
            centroid += point
        }
        centroid /= Float(points.count)

        var cxx: Float = 0
        var cxy: Float = 0
        var cyy: Float = 0
        for point in points {
            let relative = point - centroid
            let a = simd_dot(relative, e1)
            let b = simd_dot(relative, e2)
            cxx += a * a
            cxy += a * b
            cyy += b * b
        }

        let theta = 0.5 * atan2(2 * cxy, cxx - cyy)
        let widthAxis = simd_normalize(e1 * cos(theta) + e2 * sin(theta))
        let depthAxis = simd_normalize(simd_cross(upAxis, widthAxis))

        let widthExtent = extent(
            of: points,
            enclosing: enclosurePoints,
            around: centroid,
            along: widthAxis
        )
        let depthExtent = extent(
            of: points,
            enclosing: enclosurePoints,
            around: centroid,
            along: depthAxis
        )
        var heightExtent = extent(
            of: points,
            enclosing: enclosurePoints,
            around: centroid,
            along: upAxis
        )

        if let groundHeight {
            let groundProjection = groundHeight - simd_dot(centroid, upAxis)
            let highest = heightExtent.mid + heightExtent.span / 2
            let lowest = min(groundProjection, heightExtent.mid - heightExtent.span / 2)
            heightExtent = (span: highest - lowest, mid: (lowest + highest) / 2)
        }

        let dimensions = SIMD3<Float>(
            widthExtent.span,
            depthExtent.span,
            heightExtent.span
        )

        guard dimensions.x > 0.005, dimensions.y > 0.005, dimensions.z > 0.005 else {
            return nil
        }

        let center = centroid
            + widthAxis * widthExtent.mid
            + depthAxis * depthExtent.mid
            + upAxis * heightExtent.mid

        let half = dimensions / 2
        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(8)
        for k in 0...1 {
            for j in 0...1 {
                for i in 0...1 {
                    let signX = Float(i) * 2 - 1
                    let signY = Float(j) * 2 - 1
                    let signZ = Float(k) * 2 - 1
                    corners.append(
                        center
                            + widthAxis * (signX * half.x)
                            + depthAxis * (signY * half.y)
                            + upAxis * (signZ * half.z)
                    )
                }
            }
        }

        return CapturedObject(
            dimensions: dimensions,
            center: center,
            axes: (widthAxis, depthAxis, upAxis),
            corners: corners,
            volume: dimensions.x * dimensions.y * dimensions.z,
            sampleCount: points.count
        )
    }

    static func enclosing(
        _ points: [SIMD3<Float>],
        around object: CapturedObject
    ) -> CapturedObject {
        guard !points.isEmpty else {
            return object
        }

        var minimum = -object.dimensions / 2
        var maximum = object.dimensions / 2
        for point in points {
            let relative = point - object.center
            let projection = SIMD3<Float>(
                simd_dot(relative, object.axes.width),
                simd_dot(relative, object.axes.depth),
                simd_dot(relative, object.axes.height)
            )
            minimum = simd_min(minimum, projection)
            maximum = simd_max(maximum, projection)
        }

        let dimensions = maximum - minimum
        let midpoint = (minimum + maximum) / 2
        let center = object.center
            + object.axes.width * midpoint.x
            + object.axes.depth * midpoint.y
            + object.axes.height * midpoint.z
        let half = dimensions / 2
        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(8)
        for k in 0...1 {
            for j in 0...1 {
                for i in 0...1 {
                    let signX = Float(i) * 2 - 1
                    let signY = Float(j) * 2 - 1
                    let signZ = Float(k) * 2 - 1
                    corners.append(
                        center
                            + object.axes.width * (signX * half.x)
                            + object.axes.depth * (signY * half.y)
                            + object.axes.height * (signZ * half.z)
                    )
                }
            }
        }

        return CapturedObject(
            dimensions: dimensions,
            center: center,
            axes: object.axes,
            corners: corners,
            volume: dimensions.x * dimensions.y * dimensions.z,
            sampleCount: max(object.sampleCount, points.count)
        )
    }

    private static func projectOntoPlane(_ vector: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float> {
        vector - normal * simd_dot(vector, normal)
    }

    private static func extent(
        of points: [SIMD3<Float>],
        enclosing enclosurePoints: [SIMD3<Float>],
        around centroid: SIMD3<Float>,
        along axis: SIMD3<Float>
    ) -> (span: Float, mid: Float) {
        var projections = [Float]()
        projections.reserveCapacity(points.count + enclosurePoints.count)
        for point in points {
            projections.append(simd_dot(point - centroid, axis))
        }
        for point in enclosurePoints {
            projections.append(simd_dot(point - centroid, axis))
        }
        guard let lowest = projections.min(), let highest = projections.max() else {
            return (0, 0)
        }
        return (highest - lowest, (lowest + highest) / 2)
    }
}

// Bounding-box fitting, in two parts:
//   bestOrientation  Liu, Liu and Zhang's Algorithm 2 with Zhang's closeness criterion. Only
//                    finds the box's rotation.
//   make             Builds the measured box from that rotation: extents from the full cloud,
//                    height from the support plane, longer horizontal side as width.
nonisolated enum OrientedBoundingBox {
    /// N_max in Algorithm 2.
    static let maximumOrientationPointCount = 100
    /// Collinearity tolerance, the value recommended by Liu et al.
    static let approximateCollinearitySine: Float = 0.01
    private static let geometricEpsilon: Float = 1e-6

    private struct RectangleFit {
        let widthAxis: SIMD2<Float>
        let depthAxis: SIMD2<Float>
        let widthMinimum: Float
        let widthMaximum: Float
        let depthMinimum: Float
        let depthMaximum: Float
    }

    static func make(
        from points: [SIMD3<Float>],
        enclosing enclosurePoints: [SIMD3<Float>],
        up: SIMD3<Float>,
        groundHeight: Float,
        minimumEdgeDistance: Float
    ) -> CapturedObject? {
        guard points.count >= 3 else {
            return nil
        }

        let upAxis = simd_length(up) > 0
            ? simd_normalize(up)
            : SIMD3<Float>(0, 1, 0)
        guard let basis = horizontalBasis(up: upAxis) else {
            return nil
        }

        let stablePoints2D = points.map {
            SIMD2<Float>(simd_dot($0, basis.first), simd_dot($0, basis.second))
        }

        guard let direction = bestOrientation(
            of: stablePoints2D,
            minimumEdgeDistance: max(minimumEdgeDistance, geometricEpsilon)
        ) else {
            return nil
        }

        // Extents come from all points, not the downsampled set, since downsampling tends to drop the
        // extreme points that define the size.
        guard var fit = rectangleFit(points: stablePoints2D, axis: direction) else {
            return nil
        }

        let firstSpan = fit.widthMaximum - fit.widthMinimum
        let secondSpan = fit.depthMaximum - fit.depthMinimum
        if secondSpan > firstSpan {
            fit = RectangleFit(
                widthAxis: fit.depthAxis,
                depthAxis: -fit.widthAxis,
                widthMinimum: fit.depthMinimum,
                widthMaximum: fit.depthMaximum,
                depthMinimum: -fit.widthMaximum,
                depthMaximum: -fit.widthMinimum
            )
        }

        let width = fit.widthMaximum - fit.widthMinimum
        let depth = fit.depthMaximum - fit.depthMinimum
        // The top is the highest measured point. Thin features have already been filtered in image space.
        var highestProjection = groundHeight
        for point in points {
            highestProjection = max(highestProjection, simd_dot(point, upAxis))
        }
        for point in enclosurePoints {
            highestProjection = max(highestProjection, simd_dot(point, upAxis))
        }
        let height = min(
            highestProjection - groundHeight,
            ObjectCapturePipeline.maxHeight
        )
        guard width > 0.005, depth > 0.005, height > 0.005 else {
            return nil
        }

        let widthAxis = simd_normalize(
            basis.first * fit.widthAxis.x + basis.second * fit.widthAxis.y
        )
        let depthAxis = simd_normalize(simd_cross(upAxis, widthAxis))
        let widthMidpoint = (fit.widthMinimum + fit.widthMaximum) / 2
        let depthMidpoint = (fit.depthMinimum + fit.depthMaximum) / 2
        let horizontalCenter = widthAxis * widthMidpoint
            + depthAxis * depthMidpoint
        let center = horizontalCenter
            + upAxis * (groundHeight + height / 2)
        let dimensions = SIMD3<Float>(width, depth, height)
        let corners = makeCorners(
            center: center,
            dimensions: dimensions,
            widthAxis: widthAxis,
            depthAxis: depthAxis,
            upAxis: upAxis
        )

        return CapturedObject(
            dimensions: dimensions,
            center: center,
            axes: (widthAxis, depthAxis, upAxis),
            corners: corners,
            volume: width * depth * height,
            sampleCount: points.count
        )
    }

    /// Liu, Liu and Zhang, Algorithm 2, using Zhang's closeness criterion. Returns a unit direction
    /// instead of an angle to avoid wrapping at +-pi.
    static func bestOrientation(
        of points2D: [SIMD2<Float>],
        minimumEdgeDistance: Float
    ) -> SIMD2<Float>? {
        guard points2D.count >= 3 else { return nil }
        let sample = uniformDownsample(points2D, maximumCount: maximumOrientationPointCount)
        let hull = convexHull(sample, collinearitySine: approximateCollinearitySine)
        guard hull.count >= 3 else { return nil }
        return bestDirection(
            hull: hull,
            points: sample,
            minimumEdgeDistance: max(minimumEdgeDistance, geometricEpsilon)
        )
    }

    private static func horizontalBasis(
        up: SIMD3<Float>
    ) -> (first: SIMD3<Float>, second: SIMD3<Float>)? {
        var first = SIMD3<Float>(1, 0, 0) - up * simd_dot(SIMD3<Float>(1, 0, 0), up)
        if simd_length(first) < 1e-4 {
            first = SIMD3<Float>(0, 0, 1) - up * simd_dot(SIMD3<Float>(0, 0, 1), up)
        }
        guard simd_length(first) >= 1e-4 else {
            return nil
        }
        first = simd_normalize(first)
        return (first, simd_normalize(simd_cross(up, first)))
    }

    /// Seeded reservoir sampling, so the same scan gives the same result.
    private static func uniformDownsample(
        _ points: [SIMD2<Float>],
        maximumCount: Int
    ) -> [SIMD2<Float>] {
        guard maximumCount > 0, points.count > maximumCount else {
            return points
        }

        var sample = Array(points.prefix(maximumCount))
        var randomState: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in maximumCount..<points.count {
            if index.isMultiple(of: 1_024), Task.isCancelled {
                return []
            }
            randomState = randomState &* 6_364_136_223_846_793_005 &+ 1
            let selectedIndex = Int(randomState % UInt64(index + 1))
            if selectedIndex < maximumCount {
                sample[selectedIndex] = points[index]
            }
        }
        return sample
    }

    private static func convexHull(
        _ points: [SIMD2<Float>],
        collinearitySine: Float
    ) -> [SIMD2<Float>] {
        guard points.count >= 3,
              let pivot = points.min(by: {
                if abs($0.y - $1.y) > geometricEpsilon {
                    return $0.y < $1.y
                }
                return $0.x < $1.x
              }) else {
            return []
        }

        let sorted = points.filter { $0 != pivot }.sorted { lhs, rhs in
            let left = lhs - pivot
            let right = rhs - pivot
            let leftAngle = atan2(left.y, left.x)
            let rightAngle = atan2(right.y, right.x)
            if leftAngle == rightAngle {
                return simd_length_squared(left) < simd_length_squared(right)
            }
            return leftAngle < rightAngle
        }

        var polarPoints: [SIMD2<Float>] = []
        var index = 0
        while index < sorted.count {
            var farthest = sorted[index]
            let referenceRayPoint = sorted[index]
            var next = index + 1
            while next < sorted.count,
                  raysAreApproximatelyCollinear(
                    from: pivot,
                    through: referenceRayPoint,
                    and: sorted[next],
                    tolerance: collinearitySine
                  ) {
                if simd_distance_squared(pivot, sorted[next])
                    >= simd_distance_squared(pivot, farthest) {
                    farthest = sorted[next]
                }
                next += 1
            }
            polarPoints.append(farthest)
            index = next
        }
        guard polarPoints.count >= 2 else {
            return []
        }

        var stack = [pivot, polarPoints[0], polarPoints[1]]
        for point in polarPoints.dropFirst(2) {
            while stack.count >= 2,
                  turnSine(stack[stack.count - 2], stack[stack.count - 1], point)
                    <= collinearitySine {
                stack.removeLast()
            }
            stack.append(point)
        }
        return stack.count >= 3 ? stack : []
    }

    private static func bestDirection(
        hull: [SIMD2<Float>],
        points: [SIMD2<Float>],
        minimumEdgeDistance: Float
    ) -> SIMD2<Float>? {
        var bestAxis: SIMD2<Float>?
        var bestScore = -Float.greatestFiniteMagnitude
        for firstIndex in 0..<(hull.count - 1) {
            if Task.isCancelled {
                return nil
            }
            for secondIndex in (firstIndex + 1)..<hull.count {
                let delta = hull[secondIndex] - hull[firstIndex]
                guard simd_length_squared(delta) > geometricEpsilon else {
                    continue
                }
                let axis = simd_normalize(delta)
                let score = closenessScore(
                    points: points,
                    axis: axis,
                    minimumEdgeDistance: minimumEdgeDistance
                )
                if score > bestScore {
                    bestScore = score
                    bestAxis = axis
                }
            }
        }
        return bestAxis
    }

    /// Closeness criterion from Zhang, Xu, Dong and Dolan:
    ///     beta = sum_i 1 / max(min(D1_i, D2_i), d0)
    /// where D1_i is point i's distance to the nearer edge along axis 1, and D2_i the same for
    /// axis 2. Higher is better, so this maximises (Liu's pseudocode minimises, but Zhang defines the
    /// criterion as a maximisation).
    private static func closenessScore(
        points: [SIMD2<Float>],
        axis: SIMD2<Float>,
        minimumEdgeDistance: Float
    ) -> Float {
        let perpendicular = SIMD2<Float>(-axis.y, axis.x)
        guard let firstPoint = points.first else {
            return -Float.greatestFiniteMagnitude
        }

        var firstMinimum = simd_dot(firstPoint, axis)
        var firstMaximum = firstMinimum
        var secondMinimum = simd_dot(firstPoint, perpendicular)
        var secondMaximum = secondMinimum
        for point in points.dropFirst() {
            let first = simd_dot(point, axis)
            let second = simd_dot(point, perpendicular)
            firstMinimum = min(firstMinimum, first)
            firstMaximum = max(firstMaximum, first)
            secondMinimum = min(secondMinimum, second)
            secondMaximum = max(secondMaximum, second)
        }

        var score: Float = 0
        for point in points {
            let first = simd_dot(point, axis)
            let second = simd_dot(point, perpendicular)
            let firstDistance = min(first - firstMinimum, firstMaximum - first)
            let secondDistance = min(second - secondMinimum, secondMaximum - second)
            score += 1 / max(
                min(firstDistance, secondDistance),
                minimumEdgeDistance
            )
        }
        return score
    }

    /// Smallest rectangle containing every projected point. No outlier rejection here: thin parts of
    /// real objects look like outliers once projected, so filtering happens earlier in image space
    /// (`ObjectMaskProcessor.maskedWorldSurface`).
    private static func rectangleFit(
        points: [SIMD2<Float>],
        axis: SIMD2<Float>
    ) -> RectangleFit? {
        let perpendicular = SIMD2<Float>(-axis.y, axis.x)
        let first = points.map { simd_dot($0, axis) }
        let second = points.map { simd_dot($0, perpendicular) }
        guard let widthMinimum = first.min(),
              let widthMaximum = first.max(),
              let depthMinimum = second.min(),
              let depthMaximum = second.max() else {
            return nil
        }
        return RectangleFit(
            widthAxis: axis,
            depthAxis: perpendicular,
            widthMinimum: widthMinimum,
            widthMaximum: widthMaximum,
            depthMinimum: depthMinimum,
            depthMaximum: depthMaximum
        )
    }

    private static func turnSine(
        _ first: SIMD2<Float>,
        _ second: SIMD2<Float>,
        _ third: SIMD2<Float>
    ) -> Float {
        let incoming = second - first
        let outgoing = third - second
        let denominator = simd_length(incoming) * simd_length(outgoing)
        guard denominator > geometricEpsilon else {
            return 0
        }
        return cross2D(incoming, outgoing) / denominator
    }

    private static func raysAreApproximatelyCollinear(
        from pivot: SIMD2<Float>,
        through first: SIMD2<Float>,
        and second: SIMD2<Float>,
        tolerance: Float
    ) -> Bool {
        let firstRay = first - pivot
        let secondRay = second - pivot
        let denominator = simd_length(firstRay) * simd_length(secondRay)
        guard denominator > geometricEpsilon else {
            return true
        }
        return simd_dot(firstRay, secondRay) > 0
            && abs(cross2D(firstRay, secondRay) / denominator) <= tolerance
    }

    private static func cross2D(
        _ first: SIMD2<Float>,
        _ second: SIMD2<Float>
    ) -> Float {
        first.x * second.y - first.y * second.x
    }

    private static func makeCorners(
        center: SIMD3<Float>,
        dimensions: SIMD3<Float>,
        widthAxis: SIMD3<Float>,
        depthAxis: SIMD3<Float>,
        upAxis: SIMD3<Float>
    ) -> [SIMD3<Float>] {
        let half = dimensions / 2
        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(8)
        for heightIndex in 0...1 {
            for depthIndex in 0...1 {
                for widthIndex in 0...1 {
                    let widthSign = Float(widthIndex) * 2 - 1
                    let depthSign = Float(depthIndex) * 2 - 1
                    let heightSign = Float(heightIndex) * 2 - 1
                    corners.append(
                        center
                            + widthAxis * (widthSign * half.x)
                            + depthAxis * (depthSign * half.y)
                            + upAxis * (heightSign * half.z)
                    )
                }
            }
        }
        return corners
    }
}
