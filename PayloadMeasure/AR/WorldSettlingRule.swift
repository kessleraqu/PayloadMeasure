import ARKit
import Foundation

// Decides when ARKit's world is stable enough to measure against.
//
// Tracking reports .normal almost immediately, but anchors and planes keep shifting for a while.
// We also wait for the world-mapping status to reach .extending. Since that needs the phone to
// move, the mapping requirement is dropped after a few seconds so a still phone isn't stuck.

nonisolated enum WorldSettlingRule {
    /// Continuous normal tracking required before measuring.
    static let minimumNormalTrackingSeconds: TimeInterval = 1.5
    /// After this, normal tracking alone is enough.
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
