import CoreGraphics
import Foundation

/// Whether the operator is too close for an accurate reading. Reported on the measuring screen,
/// enforced nowhere.
///
/// THE RULE, exactly. The framing study measured each object once at five *screen fill* levels —
/// 25, 30, 38, 53 and 65% of the shorter viewport dimension — and found accuracy broadly stable across
/// the first three and clearly worse at the last two. Fill is the independent variable the protocol
/// controlled (`FramingCalibrationProtocol.targetFillPercentages`); the distances usually quoted
/// alongside it — about 650, 550, 450, 350 and 300 mm — are an *observed result* of following those
/// five guides, and hold only for the objects that were tested.
///
/// So the criterion is stated in fill, not in millimetres:
///
///     too close  ⇔  fill ≥ 53%,  releasing below 45.5%
///
/// Why this is not the same rule as "closer than 350 mm", which is what this file used to say. That
/// number is 53% fill *for a study object*. Applied to a different object it silently rescales: a
/// 400 mm crate overflows the frame at 600 mm and would have been told it was fine, while a 40 mm part
/// held at 300 mm to get any pixels on it at all would have been told it was too close when it occupies
/// a fifth of the screen. Reading the study in the variable it controlled removes that dependence — the
/// same rule now applies to any object, because the object's own image is what it is measured against.
///
/// **The threshold and the release are both from the study's levels, and neither is rounder than the
/// data.** 53% is the first tested level at which the loss appears, so it is the first level that can
/// honestly be called too close. The cliff itself is somewhere in the untested interval between 38% and
/// 53%; the study does not resolve where. The release is the midpoint of that interval, which is the
/// centre of the region the cliff is known to lie in and the least committal point that still gives the
/// hysteresis a real width. Without a band the message flickers on and off while fill hovers at the
/// threshold, which is the same lesson `ObjectCaptureEngine.refreshFramingGuidance` already records.
///
/// **Nothing is gated**, and the warning now being visible does not change that. Measuring starts
/// whenever an object is masked and finishes wherever the operator is standing. A gate used to exist
/// and was removed: the band cannot be met for every object, so it produced an object that was masked,
/// obviously ready, and refused, with an instruction the operator could not act on. A reading taken slightly too close is worth more than a reading that was
/// never allowed to happen, and the framing every measurement was taken at is in the study data either
/// way. Being too far is not reported at all — the study found no loss there.
nonisolated enum MeasurementFramingRule {
    /// The first tested fill level showing the accuracy loss.
    static let tooCloseFillPercent: Double = 53
    /// Midpoint of the untested interval the cliff lies in, 38–53%.
    static let releaseFillPercent: Double = 45.5

    /// The distances the study's *accurate* fill levels were observed at, for the objects it used.
    ///
    /// 38% fill came out at about 450 mm and 25% at about 650 mm, and accuracy held across that whole
    /// span. 53% — about 350 mm — is the first level where the loss appears. So 450 mm is the nearest
    /// distance any tested framing was observed to be accurate at, and the recommendation does not
    /// reach below it.
    ///
    /// This band replaces "40–50 cm", which was quoted all over the measuring screen and straddles the
    /// cliff: 40 cm is nearer than any framing the study found accurate, and the study cannot say
    /// anything in its favour. As before, the distances describe *those objects* — the warning itself
    /// is decided in fill, which is object-independent. This is retained for the one job fill cannot
    /// do: telling an operator who has nothing on screen yet where to stand.
    static let observedAccurateDistanceMetres = 0.45 ... 0.65

    /// The same band, as the operator reads it. One constant so the banner, the guide and the
    /// accessibility hints cannot drift apart or from the data.
    static let recommendedDistanceText = "45–65 cm"

    /// How much of the frame this object occupies, by the study's own definition — its longest projected
    /// side over the shorter viewport dimension. Deliberately the *same function* the protocol scored its
    /// readings with, not a reimplementation of it: a threshold read off one measure and applied to
    /// another is not supported by the data, however close the two look.
    static func fillPercent(
        objectBoundingBox: CGRect?,
        viewportSize: CGSize
    ) -> Double? {
        guard let objectBoundingBox else { return nil }
        return FramingCalibrationProtocol.fillPercent(
            boundingBox: objectBoundingBox,
            viewportSize: viewportSize
        )
    }

    /// Whether to warn, given what is being shown now. `wasTooClose` carries the hysteresis: the answer
    /// depends on whether the warning is already up, which is what stops it flickering at the boundary.
    static func isTooClose(fillPercent: Double?, wasTooClose: Bool) -> Bool {
        guard let fillPercent, fillPercent.isFinite, fillPercent > 0 else {
            return false
        }
        return wasTooClose
            ? fillPercent > releaseFillPercent
            : fillPercent >= tooCloseFillPercent
    }
}
