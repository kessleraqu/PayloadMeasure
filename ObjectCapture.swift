//
//  ObjectCapture.swift
//  PayloadMeasure
//
//  Created by Alexandre on 29/06/2026.
//

import ARKit
import simd

/// An object captured from the LiDAR scene mesh.
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
    /// Number of mesh points that contributed to the capture — a rough confidence signal.
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

/// Orchestrates a single object capture from the LiDAR scene mesh:
/// support-plane removal → classification filtering → connected-component clustering seeded at the
/// reticle → oriented-box fit. The clustering is what isolates a single object: once the support
/// surface is removed, an object resting on it becomes a spatially disconnected blob, so growing
/// the connected component from the aimed point keeps the object and drops everything else.
enum ObjectCapturePipeline {
    /// Horizontal voxel/cluster resolution. ~4 cm matches the LiDAR mesh density: large enough to
    /// bridge gaps across the object's own surface, small enough to keep it separate from nearby
    /// clutter that is more than one voxel away.
    static let voxelSize: Float = 0.04
    /// Loose horizontal bound on candidate points purely to cap work in large rooms. The real
    /// isolation comes from clustering, so this is far larger than the previous hard radius.
    static let maxRadius: Float = 2.0
    /// Tallest object we consider, above the support surface.
    static let maxHeight: Float = 1.5
    /// Points within this height of the support surface are treated as the surface and dropped.
    static let floorClearance: Float = 0.02
    /// Minimum cluster size before we trust a fit.
    static let minimumClusterPoints = 24

    static func capture(
        meshAnchors: [ARMeshAnchor],
        planes: [ARPlaneAnchor],
        seed: SIMD3<Float>,
        up: SIMD3<Float>
    ) -> CaptureOutcome {
        guard let supportHeight = MeshGeometryReader.supportHeight(below: seed, planes: planes) else {
            return .noSupport
        }

        let candidates = MeshGeometryReader.candidatePoints(
            from: meshAnchors,
            around: seed,
            supportHeight: supportHeight,
            maxRadius: maxRadius,
            maxHeight: maxHeight,
            floorClearance: floorClearance
        )

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

        guard let object = ObjectBoundingBox.make(from: cluster.points, up: up) else {
            return .notEnoughMesh
        }

        return .success(CaptureResult(object: object, selectionPoints: cluster.voxelCenters))
    }
}

/// Reads world-space geometry out of ARKit scene-reconstruction mesh anchors.
enum MeshGeometryReader {
    /// ARKit mesh-face classifications that belong to the room, not to a placed object.
    private static func isEnvironment(_ classification: ARMeshClassification) -> Bool {
        switch classification {
        case .wall, .floor, .ceiling, .window, .door:
            return true
        case .none, .table, .seat:
            return false
        @unknown default:
            return false
        }
    }

    /// Collects world-space vertices of mesh faces that:
    /// - are not classified as room structure (when classification is available),
    /// - sit above the support surface (dropping the surface itself), below `maxHeight`, and
    /// - lie within a loose horizontal radius of the seed (a compute bound, not the isolation step).
    static func candidatePoints(
        from meshAnchors: [ARMeshAnchor],
        around seed: SIMD3<Float>,
        supportHeight: Float,
        maxRadius: Float,
        maxHeight: Float,
        floorClearance: Float
    ) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        let radiusSquared = maxRadius * maxRadius

        for anchor in meshAnchors {
            let geometry = anchor.geometry
            let vertices = geometry.vertices
            let faces = geometry.faces
            let transform = anchor.transform

            let vertexBuffer = vertices.buffer.contents()
            let vertexStride = vertices.stride
            let vertexOffset = vertices.offset

            let faceBuffer = faces.buffer.contents()
            let bytesPerIndex = faces.bytesPerIndex
            let indicesPerFace = faces.indexCountPerPrimitive

            // Classification is one value per face, present only with `.meshWithClassification`.
            let classification = geometry.classification
            let classificationBuffer = classification?.buffer.contents()
            let classificationStride = classification?.stride ?? 0
            let classificationOffset = classification?.offset ?? 0

            func worldVertex(_ index: Int) -> SIMD3<Float> {
                // Read x, y, z as individual floats. ARKit packs the buffer as tightly packed
                // float3 (stride 12), so reading a 16-byte SIMD3<Float> could overrun the buffer.
                let pointer = vertexBuffer
                    .advanced(by: vertexOffset + vertexStride * index)
                    .assumingMemoryBound(to: Float.self)
                let local = SIMD3<Float>(pointer[0], pointer[1], pointer[2])
                let world = transform * SIMD4<Float>(local, 1)
                return SIMD3<Float>(world.x, world.y, world.z)
            }

            func faceVertexIndex(_ linearIndex: Int) -> Int {
                if bytesPerIndex == 2 {
                    return Int(faceBuffer
                        .advanced(by: linearIndex * 2)
                        .assumingMemoryBound(to: UInt16.self)
                        .pointee)
                }
                return Int(faceBuffer
                    .advanced(by: linearIndex * 4)
                    .assumingMemoryBound(to: UInt32.self)
                    .pointee)
            }

            for faceIndex in 0..<faces.count {
                if let classificationBuffer {
                    let raw = classificationBuffer
                        .advanced(by: classificationOffset + classificationStride * faceIndex)
                        .assumingMemoryBound(to: UInt8.self)
                        .pointee
                    if let classification = ARMeshClassification(rawValue: Int(raw)),
                       isEnvironment(classification) {
                        continue
                    }
                }

                for corner in 0..<indicesPerFace {
                    let vertexIndex = faceVertexIndex(faceIndex * indicesPerFace + corner)
                    let world = worldVertex(vertexIndex)

                    let heightAboveSupport = world.y - supportHeight
                    guard heightAboveSupport > floorClearance, heightAboveSupport < maxHeight else {
                        continue
                    }

                    let deltaX = world.x - seed.x
                    let deltaZ = world.z - seed.z
                    guard deltaX * deltaX + deltaZ * deltaZ < radiusSquared else {
                        continue
                    }

                    result.append(world)
                }
            }
        }

        return result
    }

    /// Picks the support surface height for an object: the highest horizontal plane that sits
    /// below the aimed point. Returns `nil` when no horizontal plane has been detected yet.
    static func supportHeight(below point: SIMD3<Float>, planes: [ARPlaneAnchor]) -> Float? {
        var support: Float?
        for plane in planes where plane.alignment == .horizontal {
            let planeHeight = plane.transform.columns.3.y
            guard planeHeight <= point.y - 0.02 else {
                continue
            }
            if let current = support {
                support = max(current, planeHeight)
            } else {
                support = planeHeight
            }
        }
        return support
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
    /// - Returns: the oriented box, or `nil` if there are too few points or the box is degenerate.
    static func make(from points: [SIMD3<Float>], up: SIMD3<Float>) -> CapturedObject? {
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
        let heightExtent = extent(of: points, around: centroid, along: upAxis)

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

    /// Projects points onto an axis and returns the span and the midpoint offset from the centroid.
    private static func extent(
        of points: [SIMD3<Float>],
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
        return (highest - lowest, (lowest + highest) / 2)
    }
}
