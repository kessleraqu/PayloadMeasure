import simd
import SwiftUI
import XCTest
@testable import PayloadMeasure

// The mask follows three world points per object, fitted with a least-squares similarity. These
// cover the four motions a similarity represents exactly (still, slide, dolly, roll) and the one
// it can't (out-of-plane rotation), where the residual should show up.

final class MaskDisplayTransformTests: XCTestCase {
    private let origin = CGPoint(x: 0.5, y: 0.5)
    private let legLength: CGFloat = 0.1

    /// Builds a gauge from height-normalised offsets and converts to unit viewport coordinates.
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

    /// One leg right and one leg up. Screen y points down, so up is negative.
    private func referenceGauge(aspect: CGFloat = 1) -> MaskGaugeFrame {
        gauge(
            right: CGPoint(x: legLength, y: 0),
            up: CGPoint(x: 0, y: -legLength),
            aspect: aspect
        )
    }

    /// Clockwise rotation, matching SwiftUI's rotationEffect for positive angles.
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

    /// Twice the distance halves the gauge and the mask, pivoting on the object's point.
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

    /// Rolling the phone turns the object in the image, so the mask has to turn too.
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

    /// Unit viewport coordinates aren't isotropic, so the angle must come out the same on a tall screen.
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

    /// Tilting foreshortens one axis only, which a similarity can't model. The residual should be
    /// large enough to end a hold.
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

    /// Large motion that is a similarity leaves no residual, so the mask isn't refreshed needlessly.
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

    /// Gauge legs only a few pixels long can't give a reliable angle.
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

    /// The tracker box only moves the mask, never resizes or rotates it.
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

    /// The baseline scales with distance so the gauge covers the same angle at any range.
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

        // The legs stay perpendicular, so the fit is equally conditioned in both directions.
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

    /// An anchor correction moves all three gauge points together.
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
        // The small study object at the recommended distance.
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
