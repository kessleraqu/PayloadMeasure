import CoreGraphics
import Foundation
import simd
import SwiftUI

// Places a mask image rendered a moment ago onto the current camera frame.
//
// Three points on a plane through the object (its anchor and two gauge points) are reprojected
// by ARKit every frame. We fit a 2D similarity (rotation, uniform scale, translation) to where
// they were and where they are now, using the closed-form least-squares solution from
// Umeyama (1991). For a roughly planar object this approximates the plane-induced homography
// (Hartley & Zisserman, Multiple View Geometry, 13.1).
//
// The fit is exact for pan, dolly and roll. Out-of-plane rotation can't be represented, and the
// residual of the fit measures how far off it is. ObjectMaskPreviewHold uses that residual to
// decide when a held mask is too stale to show.

/// Screen positions of the anchor and the two gauge points (one baseline along the reference
/// camera's right and up axes), in unit viewport coordinates. Three points leave a residual to
/// measure; two would fit exactly.
nonisolated struct MaskGaugeFrame: Equatable, Sendable {
    let origin: CGPoint
    let right: CGPoint
    let up: CGPoint

    var points: [CGPoint] {
        [origin, right, up]
    }

    var isFinite: Bool {
        points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
    }
}

nonisolated struct MaskDisplayTransform: Equatable {
    var scale: CGSize
    /// Pivot for scale and rotation, in unit viewport coordinates.
    var anchor: UnitPoint
    var translation: CGPoint
    /// Positive is clockwise on screen, matching SwiftUI.
    var rotation: Angle = .zero
    /// RMS error of the fit in viewport heights. Zero for transforms that don't come from a fit.
    var residual: CGFloat = 0

    static let minimumBoxSide: CGFloat = 0.005
    static let minimumDistanceMetres: Float = 0.05
    /// Clamp so one bad depth sample can't make the mask vanish or fill the screen.
    static let scaleLimit: ClosedRange<CGFloat> = 0.4 ... 2.5
    /// Shorter gauge legs give a noisy rotation estimate, so the fit isn't trusted below this.
    static let minimumGaugeLeg: CGFloat = 0.01

    /// Least-squares similarity from the three reference points to their current positions.
    ///
    /// Used instead of Vision's tracker, which loses small objects at the recommended distance.
    /// The fit is done in height-normalised units (`viewportAspect` is width / height) because
    /// rotation only makes sense in an isotropic space.
    static func following(
        reference: MaskGaugeFrame?,
        current: MaskGaugeFrame?,
        viewportAspect: CGFloat
    ) -> MaskDisplayTransform? {
        guard let reference,
              let current,
              reference.isFinite,
              current.isFinite,
              viewportAspect.isFinite,
              viewportAspect > 0 else {
            return nil
        }

        let referencePoints = reference.points.map { isotropic($0, aspect: viewportAspect) }
        let currentPoints = current.points.map { isotropic($0, aspect: viewportAspect) }

        let firstLeg = hypot(
            referencePoints[1].x - referencePoints[0].x,
            referencePoints[1].y - referencePoints[0].y
        )
        let secondLeg = hypot(
            referencePoints[2].x - referencePoints[0].x,
            referencePoints[2].y - referencePoints[0].y
        )
        guard min(firstLeg, secondLeg) >= minimumGaugeLeg else {
            return nil
        }

        guard let fit = similarity(from: referencePoints, to: currentPoints) else {
            return nil
        }
        let clampedScale = clampedScale(fit.scale)
        let anchorPoint = reference.origin
        let anchorIsotropic = referencePoints[0]
        // Scale and rotation pivot on the anchor, so the remaining translation is how far it moved.
        let movedAnchor = fit.apply(anchorIsotropic)
        let translation = CGPoint(
            x: (movedAnchor.x - anchorIsotropic.x) / viewportAspect,
            y: movedAnchor.y - anchorIsotropic.y
        )
        guard translation.x.isFinite,
              translation.y.isFinite,
              fit.rotation.isFinite else {
            return nil
        }

        var squaredError: CGFloat = 0
        for (referencePoint, currentPoint) in zip(referencePoints, currentPoints) {
            let mapped = fit.apply(referencePoint)
            squaredError += (mapped.x - currentPoint.x) * (mapped.x - currentPoint.x)
                + (mapped.y - currentPoint.y) * (mapped.y - currentPoint.y)
        }
        let residual = (squaredError / CGFloat(referencePoints.count)).squareRoot()

        return MaskDisplayTransform(
            scale: CGSize(width: clampedScale, height: clampedScale),
            anchor: UnitPoint(x: anchorPoint.x, y: anchorPoint.y),
            translation: translation,
            rotation: .radians(Double(fit.rotation)),
            residual: residual.isFinite ? residual : 0
        )
    }

    /// Fallback when there is no gauge frame: move the mask with the tracked box but ignore its
    /// size and angle, which Vision gets wrong for small targets.
    static func sliding(
        reference: CGRect?,
        current: CGRect?
    ) -> MaskDisplayTransform? {
        guard let reference,
              let current,
              isUsable(reference),
              isUsable(current) else {
            return nil
        }
        return MaskDisplayTransform(
            scale: CGSize(width: 1, height: 1),
            anchor: UnitPoint(x: reference.midX, y: reference.midY),
            translation: CGPoint(
                x: current.midX - reference.midX,
                y: current.midY - reference.midY
            )
        )
    }

    /// 2D Umeyama (1991) without reflection. With centred points the rotation is the atan2 of the
    /// summed cross and dot products, and the scale follows eq. (42).
    struct Similarity {
        var rotation: CGFloat
        var scale: CGFloat
        var offset: CGPoint

        func apply(_ point: CGPoint) -> CGPoint {
            let cosine = cos(rotation)
            let sine = sin(rotation)
            return CGPoint(
                x: scale * (cosine * point.x - sine * point.y) + offset.x,
                y: scale * (sine * point.x + cosine * point.y) + offset.y
            )
        }
    }

    static func similarity(
        from reference: [CGPoint],
        to current: [CGPoint]
    ) -> Similarity? {
        guard reference.count == current.count, reference.count >= 2 else {
            return nil
        }
        let count = CGFloat(reference.count)
        let referenceCentroid = centroid(of: reference)
        let currentCentroid = centroid(of: current)

        var dot: CGFloat = 0
        var cross: CGFloat = 0
        var referenceVariance: CGFloat = 0
        for index in reference.indices {
            let a = CGPoint(
                x: reference[index].x - referenceCentroid.x,
                y: reference[index].y - referenceCentroid.y
            )
            let b = CGPoint(
                x: current[index].x - currentCentroid.x,
                y: current[index].y - currentCentroid.y
            )
            dot += a.x * b.x + a.y * b.y
            cross += a.x * b.y - a.y * b.x
            referenceVariance += a.x * a.x + a.y * a.y
        }
        guard referenceVariance > 0, count > 0 else {
            return nil
        }

        let rotation = atan2(cross, dot)
        let scale = (dot * dot + cross * cross).squareRoot() / referenceVariance
        guard rotation.isFinite, scale.isFinite, scale > 0 else {
            return nil
        }

        let cosine = cos(rotation)
        let sine = sin(rotation)
        let rotatedCentroid = CGPoint(
            x: scale * (cosine * referenceCentroid.x - sine * referenceCentroid.y),
            y: scale * (sine * referenceCentroid.x + cosine * referenceCentroid.y)
        )
        return Similarity(
            rotation: rotation,
            scale: scale,
            offset: CGPoint(
                x: currentCentroid.x - rotatedCentroid.x,
                y: currentCentroid.y - rotatedCentroid.y
            )
        )
    }

    private static func centroid(of points: [CGPoint]) -> CGPoint {
        let count = CGFloat(points.count)
        var sum = CGPoint.zero
        for point in points {
            sum.x += point.x
            sum.y += point.y
        }
        return CGPoint(x: sum.x / count, y: sum.y / count)
    }

    /// Converts to height-normalised coordinates so x and y units are the same on screen.
    private static func isotropic(_ point: CGPoint, aspect: CGFloat) -> CGPoint {
        CGPoint(x: point.x * aspect, y: point.y)
    }

    private static func isUsable(_ box: CGRect) -> Bool {
        box.width >= minimumBoxSide
            && box.height >= minimumBoxSide
            && box.midX.isFinite
            && box.midY.isFinite
    }

    private static func clampedScale(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 1 }
        return min(max(value, scaleLimit.lowerBound), scaleLimit.upperBound)
    }
}

extension CGFloat {
    func scaled(by extent: CGFloat) -> CGFloat {
        self * extent
    }
}

/// Whether Vision's object tracker can follow the mask. Small targets fall below its minimum
/// size, in which case the mask follows the world-anchored gauge points instead.
nonisolated enum MaskTrackerEligibility {
    /// Fraction of the shorter frame side.
    static let minimumTrackableSide: CGFloat = 0.045

    static func isTrackable(boundingBox: CGRect?) -> Bool {
        guard let boundingBox,
              boundingBox.width.isFinite,
              boundingBox.height.isFinite else {
            return false
        }
        return min(boundingBox.width, boundingBox.height) >= minimumTrackableSide
    }
}

/// World-space gauge: anchor position plus the reference camera's right and up axes. The two
/// legs are perpendicular and equal in the reference image, so the fit is well conditioned.
nonisolated struct MaskGaugeBasis: Equatable, Sendable {
    let origin: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>

    /// Baseline relative to object distance, so the gauge covers the same angle (about 8.5 degrees)
    /// at any range.
    static let baselineFraction: Float = 0.15
    static let minimumBaselineMetres: Float = 0.02

    private init(origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>) {
        self.origin = origin
        self.right = right
        self.up = up
    }

    /// Moves the gauge with its anchor. ARKit keeps refining anchor poses, and leaving the gauge
    /// behind would show that correction as object rotation.
    func rebased(to trackedOrigin: SIMD3<Float>) -> MaskGaugeBasis {
        let delta = trackedOrigin - origin
        return MaskGaugeBasis(
            origin: trackedOrigin,
            right: right + delta,
            up: up + delta
        )
    }

    init?(
        origin: SIMD3<Float>,
        cameraTransform: simd_float4x4,
        distanceMetres: Float
    ) {
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
              distanceMetres.isFinite,
              distanceMetres > MaskDisplayTransform.minimumDistanceMetres else {
            return nil
        }
        let baseline = max(
            distanceMetres * Self.baselineFraction,
            Self.minimumBaselineMetres
        )
        let rightAxis = SIMD3<Float>(
            cameraTransform.columns.0.x,
            cameraTransform.columns.0.y,
            cameraTransform.columns.0.z
        )
        let upAxis = SIMD3<Float>(
            cameraTransform.columns.1.x,
            cameraTransform.columns.1.y,
            cameraTransform.columns.1.z
        )
        guard simd_length(rightAxis) > 1e-4, simd_length(upAxis) > 1e-4 else {
            return nil
        }
        self.origin = origin
        right = origin + simd_normalize(rightAxis) * baseline
        up = origin + simd_normalize(upAxis) * baseline
    }
}
