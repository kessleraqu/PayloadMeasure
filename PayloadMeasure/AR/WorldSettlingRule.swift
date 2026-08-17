import ARKit
import Foundation

// When ARKit's world is settled enough to measure against.
//
// In:  how long tracking has been continuously normal, and how far the world map has got.
// Out: whether measuring may begin.
//
// `trackingState == .normal` arrives within a frame or two of the session starting, long before the
// world is stable: anchors still shift, planes still move, and a measurement taken then is measured
// against a coordinate system that is quietly being corrected underneath it. That is what "things move
// at the start" is. ARKit's own signal for this is the world-mapping status, which reaches `.extending`
// once it has mapped more than the first glimpse of the scene.
//
// The mapping condition has a waiver on a timer, because it depends on the operator moving the phone
// and a stationary phone could otherwise wait for ever. After the waiver the settling time alone is
// taken as good enough — slightly worse evidence, but the alternative is a screen that never lets the
// participant start.

nonisolated enum WorldSettlingRule {
    /// Continuous normal tracking required before measuring, however good everything else looks.
    static let minimumNormalTrackingSeconds: TimeInterval = 1.5
    /// After this long, normal tracking on its own is accepted.
    static let mappingWaiverSeconds: TimeInterval = 6

    static func isSettled(
        normalTrackingSeconds: TimeInterval,
        mappingStatus: ARFrame.WorldMappingStatus
    ) -> Bool {
        guard normalTrackingSeconds.isFinite,
              normalTrackingSeconds >= minimumNormalTrackingSeconds else {
            return false
        }
        return hasMappedBeyondTheFirstGlimpse(mappingStatus)
            || normalTrackingSeconds >= mappingWaiverSeconds
    }

    static func hasMappedBeyondTheFirstGlimpse(
        _ status: ARFrame.WorldMappingStatus
    ) -> Bool {
        switch status {
        case .extending, .mapped:
            true
        case .notAvailable, .limited:
            false
        @unknown default:
            false
        }
    }

    /// What to tell the operator while waiting, given the same two inputs.
    static func waitingDetail(
        normalTrackingSeconds: TimeInterval,
        mappingStatus: ARFrame.WorldMappingStatus
    ) -> String {
        guard normalTrackingSeconds >= minimumNormalTrackingSeconds else {
            return "Hold the phone still for a moment while tracking settles."
        }
        return "Move the phone slowly around the payload area so the space is mapped before measuring."
    }
}
