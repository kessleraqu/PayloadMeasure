import Foundation

// What happens in the first seconds after an object is selected.
//
// In:  how long the measurement has been active, and whether it has produced anything yet.
// Out: whether to abandon it, and whether the operator may cancel it by hand.
//
// Two separate problems, one clock:
//
// A selected object that never starts measuring leaves the participant holding a phone over an object
// with nothing happening and nothing to press: the mask is locked, the guidance says hold still, and
// the fit never publishes a first box. Three seconds is long enough to tell the difference between a
// slow first fit and one that is not coming, and abandoning it puts the app straight back to looking
// for an object — which is the state the participant can act in.
//
// The manual cancel has the opposite failure: offered immediately, it gets pressed while the
// measurement is still perfectly normally getting started, and the participant learns to cancel rather
// than to hold the phone still. It is therefore withheld for the first four seconds — by which point a
// measurement that was not going to start has already been abandoned by the rule above.

nonisolated enum MeasurementStartRule {
    /// How long a selected object has to produce its first measurement.
    static let startGraceSeconds: TimeInterval = 3
    /// How long before the operator may cancel by hand.
    static let cancelLockoutSeconds: TimeInterval = 4

    /// True once a measurement that has produced nothing has had its three seconds.
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

    /// Whole seconds still to wait before Cancel appears, for the button's own label.
    static func cancelCountdown(secondsActive: TimeInterval) -> Int? {
        guard !allowsCancel(secondsActive: secondsActive) else { return nil }
        let remaining = Int((cancelLockoutSeconds - secondsActive).rounded(.up))
        return max(remaining, 1)
    }
}
