import simd
import SwiftUI
import XCTest
@testable import PayloadMeasure

// Placing a mask picture taken a moment ago onto the camera image now.
//
// The mask is followed through the world: three of the object's own points, reprojected by ARKit each
// frame, and the least-squares similarity fitted to where they were against where they are. Vision's
// object tracker cannot do this job — it has a minimum target size in frame and a small object at the
// 40–50 cm the accuracy rule asks for is under it — so it survives only as a position-only fallback.
//
// The cases below are the four motions a similarity can represent exactly (still, slide, dolly, roll),
// then the one it cannot (out-of-plane rotation), which is the case the residual exists to report.

final class MaskDisplayTransformTests: XCTestCase {
    private let origin = CGPoint(x: 0.5, y: 0.5)
    private let legLength: CGFloat = 0.1

    /// A gauge frame from height-normalised offsets, so a test can be written in the isotropic units the
    /// fit works in and still hand over the anisotropic unit-viewport coordinates the type carries.
    private func gauge(
        originOffset: CGPoint = .zero,
        right: CGPoint,
        up: CGPoint,
        aspect: CGFloat = 1
    ) -> MaskGaugeFrame {
        func point(_ offset: CGPoint) -> CGPoint {
            CGPoint(
                x: origin.x + (originOffset.x + offset.x) / aspect,
                y: origin.y + originOffset.y + offset.y
            )
        }
        return MaskGaugeFrame(
            origin: point(.zero),
            right: point(right),
            up: point(up)
        )
    }

    /// The frame as it is when the picture is taken: one leg to the right, one leg up the screen. Screen
    /// coordinates put y downwards, so "up" is negative.
    private func referenceGauge(aspect: CGFloat = 1) -> MaskGaugeFrame {
        gauge(
            right: CGPoint(x: legLength, y: 0),
            up: CGPoint(x: 0, y: -legLength),
            aspect: aspect
        )
    }

    /// Rotating a screen offset clockwise, which is the direction SwiftUI's `rotationEffect` turns for a
    /// positive angle and therefore the direction this transform has to report.
    private func rotatedClockwise(_ point: CGPoint, by radians: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x * cos(radians) - point.y * sin(radians),
            y: point.x * sin(radians) + point.y * cos(radians)
        )
    }

    // MARK: - The motions a similarity represents exactly

    func testAMaskOnAStillObjectIsDrawnUntouched() throws {
        let transform = try XCTUnwrap(
            MaskDisplayTransform.following(
                reference: referenceGauge(),
                current: referenceGauge(),
                viewportAspect: 1
            )
        )
        XCTAssertEqual(transform.scale.width, 1, accuracy: 1e-6)
        XCTAssertEqual(transform.rotation.radians, 0, accuracy: 1e-6)
        XCTAssertEqual(transform.translation.x, 0, accuracy: 1e-6)
        XCTAssertEqual(transform.translation.y, 0, accuracy: 1e-6)
        XCTAssertEqual(transform.residual, 0, accuracy: 1e-6)
    }

    func testSlidingTheObjectMovesThePictureAndNothingElse() throws {
        let transform = try XCTUnwrap(
            MaskDisplayTransform.following(
                reference: referenceGauge(),
                current: gauge(
                    originOffset: CGPoint(x: 0.05, y: -0.02),
                    right: CGPoint(x: legLength, y: 0),
                    up: CGPoint(x: 0, y: -legLength)
                ),
                viewportAspect: 1
            )
        )
        XCTAssertEqual(transform.translation.x, 0.05, accuracy: 1e-6)
        XCTAssertEqual(transform.translation.y, -0.02, accuracy: 1e-6)
        XCTAssertEqual(transform.scale.width, 1, accuracy: 1e-6)
        XCTAssertEqual(transform.rotation.radians, 0, accuracy: 1e-6)
        XCTAssertEqual(transform.residual, 0, accuracy: 1e-6)
    }

    /// Backing away to twice the distance halves the object on screen, so the gauge legs halve, and so
    /// does the mask — pivoted on the object's own point, which is where the object actually is.
    func testBackingAwayHalvesTheMaskAboutTheObjectsOwnPoint() throws {
        let transform = try XCTUnwrap(
            MaskDisplayTransform.following(
                reference: referenceGauge(),
                current: gauge(
                    right: CGPoint(x: legLength / 2, y: 0),
                    up: CGPoint(x: 0, y: -legLength / 2)
                ),
                viewportAspect: 1
            )
        )
        XCTAssertEqual(transform.scale.width, 0.5, accuracy: 1e-6)
        XCTAssertEqual(transform.scale.height, 0.5, accuracy: 1e-6)
        XCTAssertEqual(transform.anchor.x, origin.x, accuracy: 1e-9)
        XCTAssertEqual(transform.anchor.y, origin.y, accuracy: 1e-9)
        XCTAssertEqual(transform.translation.x, 0, accuracy: 1e-6)
        XCTAssertEqual(transform.translation.y, 0, accuracy: 1e-6)
        XCTAssertEqual(transform.residual, 0, accuracy: 1e-6)
    }

    /// The case the old model could not represent at all. Rolling the phone turns the object in the
    /// image, and with no rotation term the picture kept its old angle over a turned object — which is
    /// what "the mask looks rotated" was.
    func testRollingThePhoneTurnsTheMaskWithTheObject() throws {
        let angle: CGFloat = .pi / 6
        let transform = try XCTUnwrap(
            MaskDisplayTransform.following(
                reference: referenceGauge(),
                current: gauge(
                    right: rotatedClockwise(CGPoint(x: legLength, y: 0), by: angle),
                    up: rotatedClockwise(CGPoint(x: 0, y: -legLength), by: angle)
                ),
                viewportAspect: 1
            )
        )
        XCTAssertEqual(transform.rotation.radians, Double(angle), accuracy: 1e-6)
        XCTAssertEqual(transform.scale.width, 1, accuracy: 1e-6)
        XCTAssertEqual(transform.residual, 0, accuracy: 1e-6)
    }

    func testRollScaleAndSlideAreRecoveredTogether() throws {
        let angle: CGFloat = -.pi / 5
        let scale: CGFloat = 1.4
        let shift = CGPoint(x: -0.06, y: 0.03)
        let transform = try XCTUnwrap(
            MaskDisplayTransform.following(
                reference: referenceGauge(),
                current: gauge(
                    originOffset: shift,
                    right: rotatedClockwise(
                        CGPoint(x: legLength * scale, y: 0),
                        by: angle
                    ),
                    up: rotatedClockwise(
                        CGPoint(x: 0, y: -legLength * scale),
                        by: angle
                    )
                ),
                viewportAspect: 1
            )
        )
        XCTAssertEqual(transform.rotation.radians, Double(angle), accuracy: 1e-6)
        XCTAssertEqual(transform.scale.width, scale, accuracy: 1e-6)
        XCTAssertEqual(transform.translation.x, shift.x, accuracy: 1e-6)
        XCTAssertEqual(transform.translation.y, shift.y, accuracy: 1e-6)
        XCTAssertEqual(transform.residual, 0, accuracy: 1e-6)
    }

    /// Unit viewport coordinates are anisotropic — a unit of x is a different distance on screen from a
    /// unit of y — so the fit has to be done in a metric where they are not, or a rotation on a tall
    /// phone screen would be read as a rotation of some other size.
    func testARotationIsTheSameAngleOnANonSquareScreen() throws {
        let aspect: CGFloat = 9.0 / 19.5
        let angle: CGFloat = .pi / 4
        let transform = try XCTUnwrap(
            MaskDisplayTransform.following(
                reference: referenceGauge(aspect: aspect),
                current: gauge(
                    right: rotatedClockwise(CGPoint(x: legLength, y: 0), by: angle),
                    up: rotatedClockwise(CGPoint(x: 0, y: -legLength), by: angle),
                    aspect: aspect
                ),
                viewportAspect: aspect
            )
        )
        XCTAssertEqual(transform.rotation.radians, Double(angle), accuracy: 1e-6)
        XCTAssertEqual(transform.scale.width, 1, accuracy: 1e-6)
        XCTAssertEqual(transform.residual, 0, accuracy: 1e-6)
    }

    // MARK: - The motion it cannot represent, and says so

    /// Tilting the phone foreshortens one axis and not the other. No similarity can do that, so the fit
    /// splits the difference and the residual is what is left over. This is the quantity that ends a
    /// hold: a wall clock cannot tell this frame from a still one, and this can.
    func testOutOfPlaneTiltLeavesAResidualLargeEnoughToEndAHold() throws {
        let transform = try XCTUnwrap(
            MaskDisplayTransform.following(
                reference: referenceGauge(),
                current: gauge(
                    right: CGPoint(x: legLength, y: 0),
                    up: CGPoint(x: 0, y: -legLength * 0.7)
                ),
                viewportAspect: 1
            )
        )
        XCTAssertGreaterThan(
            transform.residual,
            ObjectMaskPreviewHold.maximumDisplayResidual,
            "A 30% foreshortening of one axis is exactly the motion a similarity cannot draw."
        )
    }

    /// The counterpart: motion that *is* a similarity, however large, leaves nothing over, so a steady
    /// hand sweeping across a table does not cost the picture a needless refresh.
    func testLargeButSimilarMotionLeavesNoResidual() throws {
        let transform = try XCTUnwrap(
            MaskDisplayTransform.following(
                reference: referenceGauge(),
                current: gauge(
                    originOffset: CGPoint(x: 0.2, y: 0.25),
                    right: rotatedClockwise(
                        CGPoint(x: legLength * 1.8, y: 0),
                        by: .pi / 3
                    ),
                    up: rotatedClockwise(
                        CGPoint(x: 0, y: -legLength * 1.8),
                        by: .pi / 3
                    )
                ),
                viewportAspect: 1
            )
        )
        XCTAssertLessThan(
            transform.residual,
            ObjectMaskPreviewHold.maximumDisplayResidual
        )
    }

    // MARK: - Refusals

    func testOneBadReadingCannotDistortTheMaskWithoutLimit() throws {
        let vanishing = try XCTUnwrap(
            MaskDisplayTransform.following(
                reference: referenceGauge(),
                current: gauge(
                    right: CGPoint(x: legLength * 0.01, y: 0),
                    up: CGPoint(x: 0, y: -legLength * 0.01)
                ),
                viewportAspect: 1
            )
        )
        XCTAssertEqual(
            vanishing.scale.width,
            MaskDisplayTransform.scaleLimit.lowerBound,
            accuracy: 1e-9
        )

        let swallowing = try XCTUnwrap(
            MaskDisplayTransform.following(
                reference: referenceGauge(),
                current: gauge(
                    right: CGPoint(x: legLength * 12, y: 0),
                    up: CGPoint(x: 0, y: -legLength * 12)
                ),
                viewportAspect: 1
            )
        )
        XCTAssertEqual(
            swallowing.scale.width,
            MaskDisplayTransform.scaleLimit.upperBound,
            accuracy: 1e-9
        )
    }

    /// A gauge whose legs are a few pixels long cannot resolve an angle: the variance of the estimate
    /// goes as one over the leg length squared, so reprojection noise would arrive on screen as spin.
    func testAGaugeTooSmallToCarryAnAngleIsRefused() {
        let shortLeg = MaskDisplayTransform.minimumGaugeLeg / 2
        XCTAssertNil(
            MaskDisplayTransform.following(
                reference: gauge(
                    right: CGPoint(x: shortLeg, y: 0),
                    up: CGPoint(x: 0, y: -shortLeg)
                ),
                current: gauge(
                    right: CGPoint(x: shortLeg, y: 0),
                    up: CGPoint(x: 0, y: -shortLeg)
                ),
                viewportAspect: 1
            )
        )
    }

    func testNothingIsFollowedWithoutAGaugeOnBothSides() {
        XCTAssertNil(
            MaskDisplayTransform.following(
                reference: nil,
                current: referenceGauge(),
                viewportAspect: 1
            )
        )
        XCTAssertNil(
            MaskDisplayTransform.following(
                reference: referenceGauge(),
                current: nil,
                viewportAspect: 1
            )
        )
        XCTAssertNil(
            MaskDisplayTransform.following(
                reference: referenceGauge(),
                current: MaskGaugeFrame(
                    origin: CGPoint(x: .nan, y: 0.5),
                    right: CGPoint(x: 0.6, y: 0.5),
                    up: CGPoint(x: 0.5, y: 0.4)
                ),
                viewportAspect: 1
            )
        )
        XCTAssertNil(
            MaskDisplayTransform.following(
                reference: referenceGauge(),
                current: referenceGauge(),
                viewportAspect: 0
            )
        )
    }

    // MARK: - The fallback

    /// The tracker box moves the mask and never resizes or turns it. Its size is the thing Vision gets
    /// wrong as a target gets small — scaling by it produced the appear-shrink-reappear pulse — and an
    /// axis-aligned box has no angle in it to take.
    func testTheTrackerBoxFallbackMovesButNeverResizes() throws {
        let transform = try XCTUnwrap(
            MaskDisplayTransform.sliding(
                reference: CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20),
                current: CGRect(x: 0.50, y: 0.36, width: 0.10, height: 0.10)
            )
        )
        XCTAssertEqual(transform.scale.width, 1, accuracy: 1e-9)
        XCTAssertEqual(transform.scale.height, 1, accuracy: 1e-9)
        XCTAssertEqual(transform.rotation.radians, 0, accuracy: 1e-9)
        XCTAssertEqual(transform.translation.x, 0.05, accuracy: 1e-9)
        XCTAssertEqual(transform.translation.y, -0.09, accuracy: 1e-9)
    }

    func testNoFallbackWithoutTwoUsableBoxes() {
        let box = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)
        XCTAssertNil(MaskDisplayTransform.sliding(reference: nil, current: box))
        XCTAssertNil(
            MaskDisplayTransform.sliding(
                reference: CGRect(x: 0.5, y: 0.5, width: 0.001, height: 0.2),
                current: box
            ),
            "A box thinner than the minimum is noise, not information."
        )
    }

    // MARK: - The gauge in the room

    /// The baseline is a fraction of the distance, so the gauge subtends the same angle at any range and
    /// the rotation estimate does not degrade with distance for no reason but the choice of a constant.
    func testTheGaugeBaselineGrowsWithDistance() throws {
        var cameraTransform = matrix_identity_float4x4
        let nearBasis = try XCTUnwrap(
            MaskGaugeBasis(
                origin: SIMD3<Float>(0, 0, -0.4),
                cameraTransform: cameraTransform,
                distanceMetres: 0.4
            )
        )
        let farBasis = try XCTUnwrap(
            MaskGaugeBasis(
                origin: SIMD3<Float>(0, 0, -1.2),
                cameraTransform: cameraTransform,
                distanceMetres: 1.2
            )
        )
        let nearLeg = simd_length(nearBasis.right - nearBasis.origin)
        let farLeg = simd_length(farBasis.right - farBasis.origin)
        XCTAssertEqual(Double(farLeg / nearLeg), 3, accuracy: 1e-4)

        // And the legs stay square to each other, so the fit is equally well conditioned in every
        // direction rather than favouring whichever axis happened to be longer.
        XCTAssertEqual(
            simd_dot(nearBasis.right - nearBasis.origin, nearBasis.up - nearBasis.origin),
            0,
            accuracy: 1e-6
        )
        cameraTransform.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        XCTAssertNil(
            MaskGaugeBasis(
                origin: SIMD3<Float>(0, 0, -0.4),
                cameraTransform: cameraTransform,
                distanceMetres: 0.01
            ),
            "A distance below the depth floor is not a reading and must not size a gauge."
        )
    }

    /// ARKit refines an anchor's pose for as long as it exists. That correction moves the object, so it
    /// moves all three gauge points equally; applying it to the anchor alone would read a map
    /// optimisation as the object turning, and draw it.
    func testRebasingMovesTheWholeGaugeRigidly() throws {
        let basis = try XCTUnwrap(
            MaskGaugeBasis(
                origin: SIMD3<Float>(0, 0, -0.5),
                cameraTransform: matrix_identity_float4x4,
                distanceMetres: 0.5
            )
        )
        let delta = SIMD3<Float>(0.01, -0.004, 0.002)
        let moved = basis.rebased(to: basis.origin + delta)
        XCTAssertEqual(simd_distance(moved.origin, basis.origin + delta), 0, accuracy: 1e-6)
        XCTAssertEqual(simd_distance(moved.right, basis.right + delta), 0, accuracy: 1e-6)
        XCTAssertEqual(simd_distance(moved.up, basis.up + delta), 0, accuracy: 1e-6)
    }

    // MARK: - Which masks the tracker is asked about

    func testOnlyMasksBigEnoughToTrackAreGivenToTheTracker() {
        let side = MaskTrackerEligibility.minimumTrackableSide
        XCTAssertTrue(
            MaskTrackerEligibility.isTrackable(
                boundingBox: CGRect(x: 0.4, y: 0.4, width: side, height: side)
            )
        )
        // The small object in the study, at the distance the accuracy rule asks for.
        XCTAssertFalse(
            MaskTrackerEligibility.isTrackable(
                boundingBox: CGRect(x: 0.47, y: 0.47, width: 0.06, height: side - 0.01)
            )
        )
        XCTAssertFalse(MaskTrackerEligibility.isTrackable(boundingBox: nil))
        XCTAssertFalse(
            MaskTrackerEligibility.isTrackable(
                boundingBox: CGRect(x: 0, y: 0, width: .nan, height: 0.5)
            )
        )
    }
}
