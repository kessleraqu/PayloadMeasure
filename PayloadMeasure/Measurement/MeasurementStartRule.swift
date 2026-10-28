import Foundation

// Timing rules for the first seconds after an object is selected.
//
// If no box has been fitted after 3 s the measurement is abandoned and the app goes back to
// looking for an object. Cancel is hidden for the first 4 s so it isn't pressed while a normal
// measurement is still starting up.

nonisolated enum MeasurementStartRule {
    static let startGraceSeconds: TimeInterval = 3
    static let cancelLockoutSeconds: TimeInterval = 4

    static func abandonsMeasurement(
        secondsActive: TimeInterval,
        hasMeasurement: Bool
    ) -> Bool {
        guard !hasMeasurement, secondsActive.isFinite else { return false }
        return secondsActive >= startGraceSeconds
    }

    static func allowsCancel(secondsActive: TimeInterval) -> Bool {
        guard secondsActive.isFinite else { return true }
        return secondsActive >= cancelLockoutSeconds
    }

    /// Seconds left before Cancel appears, or nil once it is available.
    static func cancelCountdown(secondsActive: TimeInterval) -> Int? {
        guard !allowsCancel(secondsActive: secondsActive) else { return nil }
        // Clamp before converting, a Double outside Int's range would trap.
        let remaining = (cancelLockoutSeconds - secondsActive).rounded(.up)
        return Int(min(max(remaining, 1), cancelLockoutSeconds.rounded(.up)))
    }
}
