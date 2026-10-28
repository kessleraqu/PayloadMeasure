import Foundation
import Observation
import simd

// Shape of the centre aimer. The AR coordinator feeds it the raycast result each frame and the
// overlay uses it to tilt and scale the ring to lie on the surface. Small changes are ignored to
// avoid jitter.

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
