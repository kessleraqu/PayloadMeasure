//
//  ObjectCapture.swift
//  PayloadMeasure
//
//  Created by Alexandre on 29/06/2026.
//

import ARKit
import CoreVideo
import simd
import UIKit

/// An object captured from the LiDAR depth map.
///
/// The box is aligned to gravity on the vertical axis (ARKit's world Y, since the session uses
/// `.gravity` world alignment) and to the object's dominant horizontal footprint direction on the
/// two base axes. This gives an oriented box that follows the object instead of the world axes.
struct CapturedObject {
    /// Edge lengths in meters: `x` and `y` are the two horizontal extents, `z` is the vertical height.
    let dimensions: SIMD3<Float>
    /// World-space center of the box.
    let center: SIMD3<Float>
    /// The three orthonormal box axes in world space: (width, depth, height).
    let axes: (width: SIMD3<Float>, depth: SIMD3<Float>, height: SIMD3<Float>)
    /// Eight world-space corners, indexed `i + 2*j + 4*k` along (width, depth, height).
    let corners: [SIMD3<Float>]
    /// Volume in cubic meters.
    let volume: Float
    /// Number of depth points that contributed to the capture — a rough confidence signal.
    let sampleCount: Int

    var widthInMeters: Float { dimensions.x }
    var depthInMeters: Float { dimensions.y }
    var heightInMeters: Float { dimensions.z }
}

/// The result of a successful capture: the fitted box plus the cluster's voxel centers so the AR
/// layer can show the operator exactly which points were selected.
struct CaptureResult {
    let object: CapturedObject
    let selectionPoints: [SIMD3<Float>]
}

/// Outcome of a capture attempt, so the UI can explain failures precisely.
enum CaptureOutcome {
    case success(CaptureResult)
    case noSupport
    case notEnoughMesh
}

/// Orchestrates a single object capture from a set of world-space depth points:
/// support-height estimation → support/height gating → connected-component clustering seeded at the
/// reticle → oriented-box fit. The clustering isolates a single object: once points near the
/// support surface are dropped, an object resting on it becomes a spatially disconnected blob, so
/// growing the connected component from the aimed point keeps the object and drops everything else.
enum ObjectCapturePipeline {
    /// Voxel/cluster resolution. ~2 cm suits the dense depth map: fine enough to resolve a small
    /// object, coarse enough to bridge depth noise across its surface.
    static let voxelSize: Float = 0.02
    /// 3D radius (a sphere) gathered around the reticle each frame. Kept tight so accumulation only
    /// covers the aimed object and its immediate surroundings — not a tall column of the whole room,
    /// which is what previously let the buffer explode.
    static let accumulationRadius: Float = 0.4
    /// Tallest object we consider, above the support surface.
    static let maxHeight: Float = 1.5
    /// Points within this height of the support surface are treated as the surface and dropped.
    static let floorClearance: Float = 0.02
    /// Minimum cluster size before we trust a fit.
    static let minimumClusterPoints = 30
    /// How many times a voxel must be observed before it counts toward the box. This is what makes
    /// the box converge and refine instead of growing: transient depth noise (seen once or twice)
    /// is ignored, while real surfaces — re-observed as the operator moves around — solidify.
    static let minObservations = 3
    /// Radius around the reticle used to estimate the local support height.
    private static let supportRadius: Float = 0.35

    static func capture(
        points: [SIMD3<Float>],
        seed: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> CaptureOutcome {
        capture(
            objectPoints: points,
            supportPoints: points,
            seed: seed,
            up: up
        )
    }

    /// Fits geometry from mask-approved object points while estimating only the base height from
    /// the surrounding unmasked depth. The table can therefore support the object without ever
    /// becoming part of its width/depth/height bounds.
    static func capture(
        objectPoints: [SIMD3<Float>],
        supportPoints: [SIMD3<Float>],
        seed: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> CaptureOutcome {
        guard objectPoints.count >= minimumClusterPoints else {
            return .notEnoughMesh
        }

        guard let supportHeight = estimateSupportHeight(points: supportPoints, seed: seed) else {
            return .noSupport
        }

        let candidates = objectPoints.filter { point in
            let heightAboveSupport = point.y - supportHeight
            return heightAboveSupport > floorClearance && heightAboveSupport < maxHeight
        }

        guard candidates.count >= minimumClusterPoints else {
            return .notEnoughMesh
        }

        guard let cluster = VoxelCluster.connectedComponent(
            points: candidates,
            seed: seed,
            voxelSize: voxelSize
        ), cluster.points.count >= minimumClusterPoints else {
            return .notEnoughMesh
        }

        // The object rests on the support, so anchor the box's base to the support height rather
        // than to the lowest clustered point (we dropped the bottom `floorClearance` for isolation).
        guard let object = ObjectBoundingBox.make(
            from: cluster.points,
            up: up,
            groundHeight: supportHeight
        ) else {
            return .notEnoughMesh
        }

        return .success(CaptureResult(object: object, selectionPoints: cluster.voxelCenters))
    }

    /// Estimates the local support surface height as a low percentile of the heights of points
    /// near the reticle. This is robust when ARKit has not detected the tabletop as a plane: the
    /// surface the object rests on is the lowest dense layer of points around it.
    private static func estimateSupportHeight(points: [SIMD3<Float>], seed: SIMD3<Float>) -> Float? {
        let radiusSquared = supportRadius * supportRadius
        var nearbyHeights: [Float] = []
        for point in points {
            let deltaX = point.x - seed.x
            let deltaZ = point.z - seed.z
            if deltaX * deltaX + deltaZ * deltaZ < radiusSquared {
                nearbyHeights.append(point.y)
            }
        }

        guard nearbyHeights.count >= 20 else {
            return nil
        }

        nearbyHeights.sort()
        let percentileIndex = Int(Float(nearbyHeights.count) * 0.1)
        return nearbyHeights[min(percentileIndex, nearbyHeights.count - 1)]
    }
}

/// Back-projects the dense LiDAR depth map into world-space points near the reticle.
enum DepthPointCloud {
    /// Samples LiDAR at a viewport tap and returns the corresponding physical surface point. This
    /// gives mask locks on LiDAR devices an anchor on the object itself instead of the table plane
    /// that may lie behind it. Non-LiDAR devices simply return nil and use an ARKit plane raycast.
    static func worldPoint(
        from frame: ARFrame,
        normalizedViewportPoint: CGPoint,
        interfaceOrientation: UIInterfaceOrientation,
        viewportSize: CGSize
    ) -> SIMD3<Float>? {
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth,
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

    /// - Parameters:
    ///   - frame: the current AR frame (must carry scene depth).
    ///   - seed: world-space reticle position; only points within `radius` (a 3D sphere) are kept.
    ///   - radius: 3D gather radius in meters.
    ///   - pixelStride: sample every Nth depth pixel to bound the point count.
    static func worldPoints(
        from frame: ARFrame,
        near seed: SIMD3<Float>,
        radius: Float,
        pixelStride: Int = 2
    ) -> [SIMD3<Float>] {
        // Prefer the temporally smoothed depth: it is markedly less noisy frame to frame, which
        // keeps the fitted box from jittering and over-sizing on stray pixels.
        guard let sceneDepth = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            return []
        }

        let depthMap = sceneDepth.depthMap
        let confidenceMap = sceneDepth.confidenceMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        // Intrinsics are given at the captured-image resolution; scale them to the depth resolution.
        let imageResolution = frame.camera.imageResolution
        let intrinsics = frame.camera.intrinsics
        let scaleX = Float(width) / Float(imageResolution.width)
        let scaleY = Float(height) / Float(imageResolution.height)
        let fx = intrinsics.columns.0.x * scaleX
        let fy = intrinsics.columns.1.y * scaleY
        let cx = intrinsics.columns.2.x * scaleX
        let cy = intrinsics.columns.2.y * scaleY

        guard fx > 0, fy > 0 else {
            return []
        }

        let cameraTransform = frame.camera.transform

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
            return []
        }
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        var points: [SIMD3<Float>] = []
        let radiusSquared = radius * radius

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

                // Keep only valid, in-range, confident depth samples.
                if depth > 0.15, depth < 2.5, (confidenceRow?[column] ?? 2) >= 1 {
                    // Camera space: +x right, +y up, -z forward. Image v grows downward, so y is negated.
                    let x = (Float(column) - cx) * depth / fx
                    let y = (Float(row) - cy) * depth / fy
                    let cameraPoint = SIMD4<Float>(x, -y, -depth, 1)
                    let world = cameraTransform * cameraPoint

                    let deltaX = world.x - seed.x
                    let deltaY = world.y - seed.y
                    let deltaZ = world.z - seed.z
                    let distanceSquared = deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ
                    // Gather a 3D sphere around the reticle, and guard against any non-finite value
                    // (a NaN/Inf world coordinate would hard-trap the voxel Int() conversion later).
                    if distanceSquared < radiusSquared,
                       world.x.isFinite, world.y.isFinite, world.z.isFinite {
                        points.append(SIMD3<Float>(world.x, world.y, world.z))
                    }
                }

                column += pixelStride
            }

            row += pixelStride
        }

        return points
    }
}

/// Accumulates depth points across frames into a voxel grid, averaging the points that fall in
/// each voxel. This gives multi-viewpoint coverage as the operator walks around the object (so the
/// box is not biased toward the side facing the camera) and averages out per-frame depth noise.
struct PointAccumulator {
    private struct Key: Hashable {
        let x: Int
        let y: Int
        let z: Int
    }

    private var sums: [Key: SIMD3<Float>] = [:]
    private var counts: [Key: Int] = [:]
    private let voxelSize: Float
    /// Hard cap on distinct voxels so the buffer can never grow without bound (which would
    /// eventually exhaust memory and crash). Once reached, existing voxels keep averaging but no
    /// new ones are added.
    private let maxVoxels: Int

    init(voxelSize: Float, maxVoxels: Int = 12000) {
        self.voxelSize = voxelSize
        self.maxVoxels = maxVoxels
    }

    var isEmpty: Bool {
        sums.isEmpty
    }

    mutating func add(_ points: [SIMD3<Float>]) {
        for point in points {
            let key = Key(
                x: Int(floor(point.x / voxelSize)),
                y: Int(floor(point.y / voxelSize)),
                z: Int(floor(point.z / voxelSize))
            )
            if counts[key] != nil {
                sums[key, default: SIMD3<Float>(repeating: 0)] += point
                counts[key]! += 1
            } else if sums.count < maxVoxels {
                sums[key] = point
                counts[key] = 1
            }
        }
    }

    /// One averaged point per occupied voxel that has been observed at least `minObservations` times.
    func points(minObservations: Int = 1) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(sums.count)
        for (key, sum) in sums {
            let count = counts[key] ?? 1
            if count >= minObservations {
                result.append(sum / Float(count))
            }
        }
        return result
    }

    /// Drops voxels observed fewer than `minCount` times — transient noise that was never
    /// reconfirmed. Keeps the buffer lean and stops the box creeping outward from stray points.
    mutating func pruneTransient(below minCount: Int) {
        let stale = counts.compactMap { $0.value < minCount ? $0.key : nil }
        for key in stale {
            counts[key] = nil
            sums[key] = nil
        }
    }

    mutating func reset() {
        sums.removeAll(keepingCapacity: true)
        counts.removeAll(keepingCapacity: true)
    }
}

/// Connected-component extraction over a voxel grid. Occupied voxels are nodes; 26-connected
/// neighbours are edges. Growing the component from the seed voxel keeps only points that are
/// spatially connected to the aimed object.
enum VoxelCluster {
    private struct Key: Hashable {
        let x: Int
        let y: Int
        let z: Int
    }

    /// - Returns: the points of the connected component containing (or nearest) the seed, plus the
    ///   center of each occupied voxel in that component (for lightweight visualization). `nil` when
    ///   there are no points or no occupied voxel can be found near the seed.
    static func connectedComponent(
        points: [SIMD3<Float>],
        seed: SIMD3<Float>,
        voxelSize: Float
    ) -> (points: [SIMD3<Float>], voxelCenters: [SIMD3<Float>])? {
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

        // Breadth-first flood fill across occupied 26-neighbours.
        var visited: Set<Key> = [seedKey]
        var queue: [Key] = [seedKey]
        var head = 0
        while head < queue.count {
            let voxel = queue[head]
            head += 1
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 where !(dx == 0 && dy == 0 && dz == 0) {
                        let neighbour = Key(x: voxel.x + dx, y: voxel.y + dy, z: voxel.z + dz)
                        if occupied.contains(neighbour), !visited.contains(neighbour) {
                            visited.insert(neighbour)
                            queue.append(neighbour)
                        }
                    }
                }
            }
        }

        var componentPoints: [SIMD3<Float>] = []
        var voxelCenters: [SIMD3<Float>] = []
        for voxel in visited {
            guard let indices = voxelToPoints[voxel] else {
                continue
            }
            for index in indices {
                componentPoints.append(points[index])
            }
            voxelCenters.append(SIMD3<Float>(
                (Float(voxel.x) + 0.5) * voxelSize,
                (Float(voxel.y) + 0.5) * voxelSize,
                (Float(voxel.z) + 0.5) * voxelSize
            ))
        }

        return (componentPoints, voxelCenters)
    }

    /// The seed voxel if it is occupied, otherwise the nearest occupied voxel within a small ring
    /// (handles the aimer landing slightly off the object, or on the just-removed support surface).
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

/// Builds a gravity-aligned oriented bounding box from a set of world-space points.
enum ObjectBoundingBox {
    /// - Parameters:
    ///   - points: world-space points belonging to the object.
    ///   - up: world up (gravity) unit vector; height is measured along this axis.
    ///   - groundHeight: if provided, the box's base along `up` is anchored to this height (the
    ///     support surface), so the height reflects the full object even though points near the
    ///     surface were dropped during isolation.
    /// - Returns: the oriented box, or `nil` if there are too few points or the box is degenerate.
    static func make(
        from points: [SIMD3<Float>],
        up: SIMD3<Float>,
        groundHeight: Float? = nil
    ) -> CapturedObject? {
        guard points.count >= 12 else {
            return nil
        }

        let upAxis = simd_length(up) > 0 ? simd_normalize(up) : SIMD3<Float>(0, 1, 0)

        // Horizontal reference basis (e1, e2) spanning the plane perpendicular to `up`.
        var e1 = projectOntoPlane(SIMD3<Float>(1, 0, 0), normal: upAxis)
        if simd_length(e1) < 1e-4 {
            // `up` was ~parallel to world X; fall back to world Z for the reference direction.
            e1 = projectOntoPlane(SIMD3<Float>(0, 0, 1), normal: upAxis)
        }
        e1 = simd_normalize(e1)
        let e2 = simd_normalize(simd_cross(upAxis, e1))

        // Centroid of the points.
        var centroid = SIMD3<Float>(repeating: 0)
        for point in points {
            centroid += point
        }
        centroid /= Float(points.count)

        // Symmetric 2x2 covariance of the horizontal projection (a along e1, b along e2).
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

        // Principal horizontal direction from the closed-form 2x2 symmetric eigenproblem.
        let theta = 0.5 * atan2(2 * cxy, cxx - cyy)
        let widthAxis = simd_normalize(e1 * cos(theta) + e2 * sin(theta))
        let depthAxis = simd_normalize(simd_cross(upAxis, widthAxis))

        let widthExtent = extent(of: points, around: centroid, along: widthAxis)
        let depthExtent = extent(of: points, around: centroid, along: depthAxis)
        var heightExtent = extent(of: points, around: centroid, along: upAxis)

        if let groundHeight {
            // Projection of the support height onto the up axis, relative to the centroid.
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

    private static func projectOntoPlane(_ vector: SIMD3<Float>, normal: SIMD3<Float>) -> SIMD3<Float> {
        vector - normal * simd_dot(vector, normal)
    }

    /// Projects points onto an axis and returns a robust span and midpoint offset from the
    /// centroid, trimming the extreme `trim` fraction at each end so a few noisy depth points can
    /// not stretch the box.
    private static func extent(
        of points: [SIMD3<Float>],
        around centroid: SIMD3<Float>,
        along axis: SIMD3<Float>,
        trim: Float = 0.02
    ) -> (span: Float, mid: Float) {
        var projections = points.map { simd_dot($0 - centroid, axis) }
        projections.sort()

        let lastIndex = projections.count - 1
        let lowIndex = min(lastIndex, Int(Float(projections.count) * trim))
        let highIndex = max(0, lastIndex - lowIndex)
        let lowest = projections[lowIndex]
        let highest = projections[highIndex]
        return (highest - lowest, (lowest + highest) / 2)
    }
}
