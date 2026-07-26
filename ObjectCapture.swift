
import ARKit
import CoreVideo
import simd
import UIKit

struct CapturedObject {
    let dimensions: SIMD3<Float>
    let center: SIMD3<Float>
    let axes: (width: SIMD3<Float>, depth: SIMD3<Float>, height: SIMD3<Float>)
    let corners: [SIMD3<Float>]
    let volume: Float
    let sampleCount: Int

    var widthInMeters: Float { dimensions.x }
    var depthInMeters: Float { dimensions.y }
    var heightInMeters: Float { dimensions.z }

    func contains(_ point: SIMD3<Float>, tolerance: Float = 0) -> Bool {
        let relative = point - center
        return abs(simd_dot(relative, axes.width)) <= dimensions.x / 2 + tolerance
            && abs(simd_dot(relative, axes.depth)) <= dimensions.y / 2 + tolerance
            && abs(simd_dot(relative, axes.height)) <= dimensions.z / 2 + tolerance
    }
}

struct CaptureResult {
    let object: CapturedObject
    let selectionPoints: [SIMD3<Float>]
    let surfacePoints: [SIMD3<Float>]
}

struct AccumulatedDepthPoint {
    let position: SIMD3<Float>
    let observedPosition: SIMD3<Float>
}

enum CaptureOutcome {
    case success(CaptureResult)
    case noSupport
    case notEnoughMesh
}

enum ObjectCapturePipeline {
    static let voxelSize: Float = 0.005
    static let supportVoxelSize: Float = 0.02
    static let accumulationRadius: Float = 0.4
    static let maxHeight: Float = 1.5
    static let floorClearance: Float = 0.005
    static let minimumClusterPoints = 30
    private static let connectivityRadiusInVoxels = 2
    private static let surfaceBridgeRadiusInVoxels = 4
    private static let minimumBridgedSurfacePoints = 12
    private static let minimumSurfaceBridgeContacts = 6
    static let minObservations = 2
    static let selectionTolerance: Float = voxelSize * 0.5
    static let maxObjectVoxels = 64_000
    private static let supportRadius: Float = 0.24

    static func capture(
        objectPoints: [AccumulatedDepthPoint],
        supportPoints: [SIMD3<Float>],
        seed: SIMD3<Float>,
        up: SIMD3<Float>,
        supportHeight: Float? = nil
    ) -> CaptureOutcome {
        guard objectPoints.count >= minimumClusterPoints else {
            return .notEnoughMesh
        }

        guard let resolvedSupportHeight = supportHeight
            ?? estimateSupportHeight(points: supportPoints, seed: seed) else {
            return .noSupport
        }

        let candidates = objectPoints.filter { point in
            let heightAboveSupport = point.position.y - resolvedSupportHeight
            return heightAboveSupport > floorClearance && heightAboveSupport < maxHeight
        }

        guard candidates.count >= minimumClusterPoints else {
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

        let selectedPoints = cluster.pointIndices.map { candidates[$0].position }
        let surfacePoints = cluster.pointIndices.map { candidates[$0].observedPosition }
        guard let object = ObjectBoundingBox.make(
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

    static func supportPlaneHeight(
        from anchors: [ARAnchor],
        beneath referencePoint: SIMD3<Float>
    ) -> Float? {
        var bestHeight: Float?
        for case let anchor as ARPlaneAnchor in anchors where anchor.alignment == .horizontal {
            let local = anchor.transform.inverse * SIMD4<Float>(referencePoint, 1)
            let boundary = anchor.geometry.boundaryVertices
            guard boundaryContains(
                SIMD2<Float>(local.x, local.z),
                vertices: boundary,
                tolerance: 0.03
            ) else {
                continue
            }

            let worldPlanePoint = anchor.transform * SIMD4<Float>(local.x, 0, local.z, 1)
            let height = worldPlanePoint.y
            let distanceBelowReference = referencePoint.y - height
            guard distanceBelowReference >= 0.008,
                  distanceBelowReference <= 0.5 else {
                continue
            }
            if bestHeight == nil || height > bestHeight! {
                bestHeight = height
            }
        }
        return bestHeight
    }

    private static func estimateSupportHeight(points: [SIMD3<Float>], seed: SIMD3<Float>) -> Float? {
        let radiusSquared = supportRadius * supportRadius
        var nearbyHeights: [Float] = []
        for point in points {
            let deltaX = point.x - seed.x
            let deltaZ = point.z - seed.z
            if deltaX * deltaX + deltaZ * deltaZ < radiusSquared,
               point.y <= seed.y + 0.04 {
                nearbyHeights.append(point.y)
            }
        }

        guard nearbyHeights.count >= 20 else {
            return nil
        }

        let binSize: Float = 0.01
        var histogram: [Int: Int] = [:]
        for height in nearbyHeights {
            histogram[Int((height / binSize).rounded()), default: 0] += 1
        }
        guard let strongestBin = histogram.max(by: { lhs, rhs in
            if lhs.value == rhs.value {
                return lhs.key < rhs.key
            }
            return lhs.value < rhs.value
        })?.key else {
            return nil
        }

        let centerHeight = Float(strongestBin) * binSize
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

struct PointAccumulator {
    private struct Key: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    private struct FrameSample {
        var sum: SIMD3<Float>
        var count: Int32
        var observedPoint: SIMD3<Float>
    }

    private struct Sample {
        var sum: SIMD3<Float>
        var observationCount: Int32
        var lastSeenGeneration: Int32
        var stablePoint: SIMD3<Float>?
        var observedPoint: SIMD3<Float>
        var stableObservedPoint: SIMD3<Float>?
    }

    private var samples: [Key: Sample] = [:]
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

    func confirmedPoints(minObservations: Int = 1) -> [AccumulatedDepthPoint] {
        var result: [AccumulatedDepthPoint] = []
        result.reserveCapacity(samples.count)
        for sample in samples.values where sample.observationCount >= Int32(minObservations) {
            result.append(
                AccumulatedDepthPoint(
                    position: sample.stablePoint
                        ?? sample.sum / Float(sample.observationCount),
                    observedPosition: sample.stableObservedPoint
                        ?? sample.observedPoint
                )
            )
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

    private mutating func remove(_ keys: [Key]) {
        for key in keys {
            samples[key] = nil
        }
    }

}

enum VoxelCluster {
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
        var secondaryComponents: [[Key]] = []
        while let start = remaining.first {
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
        for voxel in orderedVoxels {
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

enum ObjectBoundingBox {
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
        var lowest = Float.greatestFiniteMagnitude
        var highest = -Float.greatestFiniteMagnitude
        for point in points {
            let projection = simd_dot(point - centroid, axis)
            lowest = min(lowest, projection)
            highest = max(highest, projection)
        }
        for point in enclosurePoints {
            let projection = simd_dot(point - centroid, axis)
            lowest = min(lowest, projection)
            highest = max(highest, projection)
        }
        return (highest - lowest, (lowest + highest) / 2)
    }
}
