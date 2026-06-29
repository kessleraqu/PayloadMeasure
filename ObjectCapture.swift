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
    /// Number of mesh vertices that contributed to the capture — a rough confidence signal.
    let sampleCount: Int

    var widthInMeters: Float { dimensions.x }
    var depthInMeters: Float { dimensions.y }
    var heightInMeters: Float { dimensions.z }
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

/// Reads world-space vertices out of ARKit scene-reconstruction mesh anchors and isolates the
/// subset that belongs to an object resting on a support surface.
enum MeshGeometryReader {
    /// Collects world-space vertices that fall inside a horizontal radius around `center` and
    /// within a height band above the support surface. The height band drops the support surface
    /// itself (via `floorClearance`) and anything taller than `maxHeight`, which isolates a single
    /// object sitting on a floor or table from its surroundings.
    static func objectVertices(
        from meshAnchors: [ARMeshAnchor],
        around center: SIMD3<Float>,
        supportHeight: Float,
        radius: Float,
        maxHeight: Float,
        floorClearance: Float = 0.02
    ) -> [SIMD3<Float>] {
        var result: [SIMD3<Float>] = []
        let radiusSquared = radius * radius

        for anchor in meshAnchors {
            let vertices = anchor.geometry.vertices
            let buffer = vertices.buffer.contents()
            let stride = vertices.stride
            let offset = vertices.offset
            let transform = anchor.transform

            for index in 0..<vertices.count {
                // Read x, y, z as individual floats. ARKit packs the vertex buffer as tightly
                // packed float3 (stride 12), so reading a 16-byte SIMD3<Float> directly could
                // overrun the buffer on the final vertex.
                let componentPointer = buffer
                    .advanced(by: offset + stride * index)
                    .assumingMemoryBound(to: Float.self)
                let local = SIMD3<Float>(componentPointer[0], componentPointer[1], componentPointer[2])

                let world4 = transform * SIMD4<Float>(local, 1)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)

                let heightAboveSupport = world.y - supportHeight
                guard heightAboveSupport > floorClearance, heightAboveSupport < maxHeight else {
                    continue
                }

                let deltaX = world.x - center.x
                let deltaZ = world.z - center.z
                guard deltaX * deltaX + deltaZ * deltaZ < radiusSquared else {
                    continue
                }

                result.append(world)
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
