import CoreGraphics
import Foundation

/// Warns the operator when they are too close for an accurate reading. It is only a warning,
/// measuring is never blocked.
///
/// The framing study measured objects at five screen-fill levels (25, 30, 38, 53 and 65% of the
/// shorter viewport side). Accuracy was stable up to 38% and dropped from 53%. The rule uses fill
/// rather than distance so it works for objects of any size:
///
///     too close when fill >= 53%, cleared again below 45.5%
///
/// 45.5% is the midpoint of the untested 38-53% gap; the band stops the warning flickering.
/// Being too far is not reported, the study found no accuracy loss there.
nonisolated enum MeasurementFramingRule {
    static let tooCloseFillPercent: Double = 53
    static let releaseFillPercent: Double = 45.5

    /// Distances at which the accurate fill levels were observed for the study objects (38% fill at
    /// about 450 mm, 25% at about 650 mm). Only used to tell the operator where to stand before
    /// anything is on screen.
    static let observedAccurateDistanceMetres = 0.45 ... 0.65

    static let recommendedDistanceText = "45–65 cm"

    /// Longest projected side over the shorter viewport side. Uses the same function the framing
    /// study used, so the thresholds stay comparable.
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

    /// `wasTooClose` provides the hysteresis.
    static func isTooClose(fillPercent: Double?, wasTooClose: Bool) -> Bool {
        guard let fillPercent, fillPercent.isFinite, fillPercent > 0 else {
            return false
        }
        return wasTooClose
            ? fillPercent > releaseFillPercent
            : fillPercent >= tooCloseFillPercent
    }
}
