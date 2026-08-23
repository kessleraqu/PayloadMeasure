import CoreGraphics
import Foundation
import simd
import SwiftUI

// How a mask picture, taken a moment ago, is placed on the camera image now.
//
// In:  where three points of the object were on screen when the mask was rendered, and where the same
//      three points are now.
// Out: the rotation, scale, anchor and translation to draw the picture with, and the residual of that
//      fit — how much of the true motion the drawn transform could not represent.
//
// THE MODEL, exactly. The mask is a raster of the object's silhouette captured at a reference frame.
// Placing it in a later frame means knowing how the object's image moved. For a rigid scene under
// camera motion the exact image-to-image map of a *plane* is a homography — Hartley and Zisserman,
// *Multiple View Geometry*, §13.1, the plane-induced homography H = K(R − tnᵀ/d)K⁻¹. A silhouette is
// not a plane, but an object subtends a depth range small beside its distance, so the fronto-parallel
// plane through the object at its measured depth is the natural first-order surrogate.
//
// The homography is not composed algebraically here — that would need the plane normal and the
// inter-frame pose. It is *sampled*: three points are placed on that plane in the room — the object's
// own anchor and two gauge points offset along the reference camera's image-plane axes — and ARKit
// reprojects all three every frame under its own calibrated camera model. The transform drawn with is
// then the least-squares similarity (rotation, isotropic scale, translation) fitted to those three
// correspondences in closed form: Umeyama, "Least-Squares Estimation of Transformation Parameters
// Between Two Point Patterns", IEEE PAMI 13(4), 1991, eqs. (34)–(42), specialised to two dimensions
// where the SVD reduces to one `atan2`.
//
// Two properties are why it is worth doing this way rather than approximating:
//
//   1. It is *exact* whenever the true image motion is a similarity — translation parallel to the image
//      plane, dolly along the optical axis, roll about it — which is most of hand-held motion. The
//      previous model was a similarity with the rotation term dropped, so roll and orbit were drawn as
//      no motion at all: the picture kept its old angle while the object turned underneath it.
//
//   2. The *residual* of the fit — RMS reprojection error of the three correspondences after the best
//      similarity — measures precisely what the picture cannot represent, which is the out-of-plane
//      rotation and perspective the similarity has no terms for. That is a computed quantity, in units
//      of viewport height, and it is what decides when a held silhouette has gone stale
//      (`ObjectMaskPreviewHold`). A wall clock cannot tell a phone held still for a second from a phone
//      swung through 40° in a fifth of one; this can.
//
// What is deliberately *not* claimed: this is not a homography and does not become one. Under genuine
// out-of-plane rotation the drawn mask is the best similarity approximation to the true motion, and the
// residual says by how much it is wrong rather than hiding it.

/// Three points of one object on screen: its anchor, and two gauge points one baseline away along the
/// reference camera's right and up axes. Coordinates are unit viewport coordinates — x over the
/// viewport width, y over its height.
///
/// Three is the smallest set that pins a similarity in two dimensions with a residual left over to
/// measure. Two points determine rotation and scale exactly and leave nothing to check; three make the
/// system overdetermined, which is what turns the fit into an estimate with an error attached.
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
    /// Multiplier on the drawn picture, about `anchor`.
    var scale: CGSize
    /// The point the scale and the rotation both pivot around, in unit coordinates of the viewport.
    var anchor: UnitPoint
    /// Where to move the picture afterwards, in unit coordinates of the viewport.
    var translation: CGPoint
    /// In-plane rotation about `anchor`, positive clockwise on screen to match SwiftUI's convention.
    var rotation: Angle = .zero
    /// RMS reprojection error of the correspondences this transform was fitted to, in units of viewport
    /// height. Zero when the transform came from a path that fits nothing and so cannot report one.
    var residual: CGFloat = 0

    /// Below this a box is too small to be believed and is treated as no information.
    static let minimumBoxSide: CGFloat = 0.005
    /// Depth below this is not a reading, it is noise, and dividing by it would resize the mask wildly.
    static let minimumDistanceMetres: Float = 0.05
    /// However far the reading has moved, the drawn mask may not be resized past this either way, so one
    /// bad depth sample cannot make it vanish or swallow the screen.
    static let scaleLimit: ClosedRange<CGFloat> = 0.4 ... 2.5
    /// Shortest gauge leg, in viewport heights, that the fit is trusted on. Below it the two legs are
    /// too short to resolve an angle: the rotation estimate's variance goes as 1/L², so a leg a few
    /// pixels long turns reprojection noise into visible spin.
    static let minimumGaugeLeg: CGFloat = 0.01

    /// The least-squares similarity taking the object's three reference points to where they are now.
    ///
    /// This is the path that matters, and it is what keeps a mask on a small object at the 45–65 cm the
    /// accuracy rule asks for. Vision's object tracker has a minimum target size in frame and is under
    /// it at that range — its box decays or stops following, which is a mask that lags, sticks or
    /// pulses. Points in the room have no such limit: ARKit reprojects them at any distance and any
    /// apparent size, and three of them carry the rotation and the scale directly instead of inferring
    /// scale from distance.
    ///
    /// `viewportAspect` is width ÷ height. Unit viewport coordinates are anisotropic — x is divided by a
    /// different number from y — and a rotation is only meaningful in an isotropic metric, so the fit is
    /// done in height-normalised units and the translation converted back at the end.
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

        // Both legs of the reference frame have to be long enough to carry an angle.
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
        // Scale and rotation pivot on the anchor, so the translation left to apply is simply how far the
        // anchor itself moves under the fitted similarity.
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

    /// Fallback for a mask with no gauge frame of its own: slide it with the tracked box, and take no
    /// size and no angle from it. The box's size is the one thing Vision gets badly wrong as a target
    /// gets small — scaling by it is what produced a mask that appeared, shrank, reappeared and shrank
    /// again — and an axis-aligned box carries no rotation to take in the first place.
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

    /// Umeyama (1991) in two dimensions, without reflection.
    ///
    /// With centred correspondences α and β, the cross-covariance reduces to the pair
    /// Σ⟨α,β⟩ and Σ(α × β); the rotation is their `atan2` and the least-squares scale is
    /// ‖Σ‖ ÷ Σ‖α‖², which is eq. (42) once the SVD of a 2 × 2 matrix is written out. Returning the
    /// angle rather than a matrix keeps the caller free of a wrap at ±π.
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

    /// Unit viewport coordinates to height-normalised ones, where a unit of x and a unit of y are the
    /// same distance on screen and a rotation therefore means something.
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
    /// Unit-space offset to points, kept short so the call site reads as one line.
    func scaled(by extent: CGFloat) -> CGFloat {
        self * extent
    }
}

/// Whether Vision's object tracker is worth running on a mask at all.
///
/// It needs a target of some minimum size in the frame, and a small object at the 45–65 cm the accuracy
/// rule asks for is under it: the tracker either stops following or lets its box decay, and both look
/// like a broken mask. Below the threshold the mask is followed through the world instead, which has no
/// such limit, and the tracker is not asked to do a job it cannot do — which also saves its cost in
/// exactly the case where the pipeline is already working hardest.
nonisolated enum MaskTrackerEligibility {
    /// Fraction of the shorter frame side below which a target is too small for the tracker.
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

/// Where the gauge points sit in the room, so any later frame can reproject them.
///
/// Held as the anchor's world position plus the reference camera's right and up axes rather than as
/// three world points, because that is what makes them a *frame*: the two legs are perpendicular and
/// equal in the reference image, so the fit is equally well conditioned in every direction. One
/// baseline is carried rather than assumed, so the gauge subtends the same angle at any distance.
nonisolated struct MaskGaugeBasis: Equatable, Sendable {
    let origin: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>

    /// Baseline as a fraction of the distance to the object, so the gauge covers a constant angle —
    /// about 8.5° — whatever the range. A fixed metric baseline would be a large fraction of the frame
    /// up close and a few pixels far away, and the rotation estimate would degrade with distance for no
    /// reason other than the choice of constant.
    static let baselineFraction: Float = 0.15
    static let minimumBaselineMetres: Float = 0.02

    private init(origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>) {
        self.origin = origin
        self.right = right
        self.up = up
    }

    /// The same three points, moved rigidly to follow their anchor.
    ///
    /// ARKit refines an anchor's pose for as long as it exists — Apple's own note on `ARAnchor` is that
    /// it "might move that anchor when it optimizes its internal map". A refinement is a correction to
    /// where the *object* is, so it applies to all three points equally; leaving the gauge behind at the
    /// pose the anchor had when the picture was taken would read that correction as object rotation and
    /// draw it.
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
