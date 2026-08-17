import Foundation

/// Distance guidance for ordinary measurements. The framing study found a clear loss of accuracy
/// below 350 mm, while readings above that point remained broadly stable. The final safety block is
/// deliberately one-sided even though preflight guides users toward a preferred band.
/// A common 400–500 mm band now controls the pre-measurement instructions for every object; unlike
/// a fixed screen rectangle, that band does not silently change with the object's physical size.
nonisolated enum MeasurementFramingRule {
    enum Guidance: Equatable, Sendable {
        case unavailable
        case moveFarther
        case ready
        case moveCloser
    }

    static let minimumDistanceMetres = 0.35
    static let preferredDistanceMetres = 0.40 ... 0.50

    static func guidance(distanceMetres: Double?) -> Guidance {
        guard let distanceMetres,
              distanceMetres.isFinite,
              distanceMetres > 0 else {
            return .unavailable
        }
        if distanceMetres < preferredDistanceMetres.lowerBound {
            return .moveFarther
        }
        if distanceMetres > preferredDistanceMetres.upperBound {
            return .moveCloser
        }
        return .ready
    }

    static func isTooClose(distanceMetres: Double?) -> Bool {
        guard let distanceMetres,
              distanceMetres.isFinite,
              distanceMetres > 0 else {
            // Missing depth must not stop a study participant after capture has already begun.
            return false
        }
        return distanceMetres < minimumDistanceMetres
    }
}
