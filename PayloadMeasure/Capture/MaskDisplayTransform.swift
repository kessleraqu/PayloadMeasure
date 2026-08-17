import CoreGraphics
import SwiftUI

// How a mask picture, taken a moment ago, is placed on the camera image now.
//
// In:  where the mask was when it was rendered, and where the display tracker says it is in this frame.
// Out: the scale, anchor and translation to draw it with.
//
// The mask is a full-viewport picture with the object's silhouette burned into it at the position it
// occupied when Vision segmented it. Between segmentations — a sixth of a second, sometimes more — the
// object moves and changes size on screen as the phone moves. Sliding the picture keeps the mask over
// the object; scaling it about the mask's own centre keeps it the same size *as* the object. Without the
// scale, backing away from something leaves its mask at the size it was, which looks like a mask that
// has locked on and refuses to let go.

nonisolated struct MaskDisplayTransform: Equatable {
    /// Multiplier on the drawn picture, about `anchor`.
    var scale: CGSize
    /// The point the scale pivots around, in unit coordinates of the viewport.
    var anchor: UnitPoint
    /// Where to move the picture afterwards, in unit coordinates of the viewport.
    var translation: CGPoint

    /// Below this a box is too small to be believed and is treated as no information.
    static let minimumBoxSide: CGFloat = 0.005
    /// Depth below this is not a reading, it is noise, and dividing by it would resize the mask wildly.
    static let minimumDistanceMetres: Float = 0.05
    /// However far the reading has moved, the drawn mask may not be resized past this either way, so one
    /// bad depth sample cannot make it vanish or swallow the screen.
    static let scaleLimit: ClosedRange<CGFloat> = 0.4 ... 2.5

    /// Tracks a point on the object through the world, not through the picture.
    ///
    /// This is the path that matters. Vision's object tracker has a minimum target size in frame, and a
    /// small object at the 40–50 cm the accuracy rule asks for is below it: the tracker's box decays or
    /// stops following, which is a mask that lags, sticks, or pulses between two sizes. A point in the
    /// world has no such limit. ARKit reprojects it every frame at any distance, and how far away it is
    /// gives the apparent size directly — under a pinhole camera, size on screen goes as 1/distance. So
    /// the mask follows the object because the *object's position in the room* is known, not because a
    /// tracker managed to keep hold of a handful of pixels.
    static func following(
        referencePoint: CGPoint?,
        referenceDistanceMetres: Float?,
        currentPoint: CGPoint?,
        currentDistanceMetres: Float?
    ) -> MaskDisplayTransform? {
        guard let referencePoint,
              let currentPoint,
              isUsable(referencePoint),
              isUsable(currentPoint) else {
            return nil
        }
        let translation = CGPoint(
            x: currentPoint.x - referencePoint.x,
            y: currentPoint.y - referencePoint.y
        )
        let ratio: CGFloat
        if let referenceDistanceMetres,
           let currentDistanceMetres,
           referenceDistanceMetres.isFinite,
           currentDistanceMetres.isFinite,
           referenceDistanceMetres > minimumDistanceMetres,
           currentDistanceMetres > minimumDistanceMetres {
            ratio = clampedScale(
                CGFloat(referenceDistanceMetres) / CGFloat(currentDistanceMetres)
            )
        } else {
            ratio = 1
        }
        return MaskDisplayTransform(
            scale: CGSize(width: ratio, height: ratio),
            anchor: UnitPoint(x: referencePoint.x, y: referencePoint.y),
            translation: translation
        )
    }

    /// Fallback for a mask with no world position of its own: slide it with the tracked box, and take no
    /// size from it. The box's size is the one thing Vision gets badly wrong as a target gets small —
    /// scaling by it is what produced a mask that appeared, shrank, reappeared and shrank again.
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

    private static func isUsable(_ box: CGRect) -> Bool {
        box.width >= minimumBoxSide
            && box.height >= minimumBoxSide
            && box.midX.isFinite
            && box.midY.isFinite
    }

    private static func isUsable(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
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
/// It needs a target of some minimum size in the frame, and a small object at the 40–50 cm the accuracy
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
