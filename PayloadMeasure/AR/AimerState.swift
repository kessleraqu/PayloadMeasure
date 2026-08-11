import Foundation
import Observation
import simd

// Shape of the centre aimer, driven by whatever surface the camera is pointing at.
//
// In:  updateAimerSurface, called each frame by the AR coordinator with the raycast result.
// Out: observable values the overlay reads to squash, rotate and scale the aimer ring so it lies
//      flat on the surface. Small changes are ignored so the ring does not jitter.

@MainActor
@Observable
final class AimerState {
    private(set) var surfaceScaleY: Double = 1
    private(set) var surfaceRotationDegrees: Double = 0
    private(set) var distanceScale: Double = 1
    private(set) var isOnSurface = false

    func updateAimerSurface(
        scaleY: Double,
        rotationDegrees: Double,
        distanceScale: Double,
        isDetected: Bool
    ) {
        let rotationChange = abs(shortestAngleDelta(from: surfaceRotationDegrees, to: rotationDegrees))
        if abs(scaleY - surfaceScaleY) > 0.01
            || rotationChange > 1
            || abs(distanceScale - self.distanceScale) > 0.01
            || isOnSurface != isDetected {
            surfaceScaleY = scaleY
            surfaceRotationDegrees = rotationDegrees
            self.distanceScale = distanceScale
            isOnSurface = isDetected
        }
    }

    private func shortestAngleDelta(from start: Double, to end: Double) -> Double {
        var delta = (end - start).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }
}
