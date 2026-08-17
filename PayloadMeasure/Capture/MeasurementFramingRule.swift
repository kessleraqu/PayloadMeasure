import Foundation

/// Where measurements are most accurate, reported to the operator and enforced nowhere.
///
/// The framing study found a clear loss of accuracy below 350 mm, while readings above that point
/// remained broadly stable, and 400–500 mm is the band the study recommends. That is now advice on the
/// screen and nothing more: measuring starts whenever an object is masked, and finishes wherever the
/// operator happens to be standing.
///
/// It used to gate both. The band cannot be met for every object — a small object has to be held closer
/// before there is enough of it on screen to work with at all — so the gate produced an object that was
/// masked, obviously ready, and refused, with an instruction the operator could not act on. A reading
/// taken slightly too close is worth more than a reading that was never allowed to happen, and the
/// distance every measurement was taken at is in the study data either way.
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

    /// Inside the range where the study measured accuracy falling off. Used to word the recommendation
    /// more firmly; it stops nothing.
    static func isBelowAccuracyThreshold(distanceMetres: Double?) -> Bool {
        guard let distanceMetres,
              distanceMetres.isFinite,
              distanceMetres > 0 else {
            return false
        }
        return distanceMetres < minimumDistanceMetres
    }
}
