import XCTest
@testable import PayloadMeasure

final class ObjectMaskCandidatePolicyTests: XCTestCase {
    func testCentreCandidatesRemainThePreferredFastPath() {
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.previewInstances(
                nearby: IndexSet([4, 2]),
                withinAim: IndexSet([1, 2, 3, 4]),
                excluding: []
            ),
            [2, 4]
        )
    }

    func testSmallObjectIsStillConsideredWhenCentreProbesMissIt() {
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.previewInstances(
                nearby: IndexSet(),
                withinAim: IndexSet([3, 7]),
                excluding: []
            ),
            [3, 7]
        )
    }

    func testFinishedObjectsAreExcludedFromBothCandidatePaths() {
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.previewInstances(
                nearby: IndexSet(integer: 3),
                withinAim: IndexSet([3, 7]),
                excluding: [3]
            ),
            [7]
        )
    }

    /// The fallback only widens to the aim window, never to the whole frame.
    func testNothingIsOfferedWhenTheAimWindowIsEmpty() {
        XCTAssertTrue(
            ObjectMaskCandidatePolicy.previewInstances(
                nearby: IndexSet(),
                withinAim: IndexSet(),
                excluding: []
            ).isEmpty
        )
    }

    // MARK: - The aim gate

    func testCrosshairInsideTheMaskIsAimedAtIt() {
        XCTAssertTrue(
            ObjectMaskCandidatePolicy.isAimedAt(
                boundingBox: CGRect(x: 0.42, y: 0.44, width: 0.16, height: 0.14),
                aim: CGPoint(x: 0.5, y: 0.5)
            )
        )
    }

    /// Small masks don't always sit under a hand-held crosshair, so allow a little slack.
    func testMaskJustOutsideTheCrosshairStillCountsAsAimedAt() {
        let slack = ObjectMaskCandidatePolicy.aimBoundsSlack
        XCTAssertTrue(
            ObjectMaskCandidatePolicy.isAimedAt(
                boundingBox: CGRect(
                    x: 0.5 + slack * 0.5,
                    y: 0.47,
                    width: 0.06,
                    height: 0.06
                ),
                aim: CGPoint(x: 0.5, y: 0.5)
            )
        )
    }

    func testObjectAtTheEdgeOfTheFrameIsNotAimedAt() {
        XCTAssertFalse(
            ObjectMaskCandidatePolicy.isAimedAt(
                boundingBox: CGRect(x: 0.86, y: 0.05, width: 0.12, height: 0.2),
                aim: CGPoint(x: 0.5, y: 0.5)
            )
        )
    }

    // MARK: - Staying on the same object between segmentations

    /// Instances are renumbered every frame, so the mask on screen is matched by position.
    func testTheOverlappingCandidateContinuesTheMaskOnScreen() {
        let previous = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)
        let instance = ObjectMaskCandidatePolicy.continuation(
            of: previous,
            among: [
                (instance: 7, boundingBox: CGRect(x: 0.05, y: 0.05, width: 0.20, height: 0.20)),
                (instance: 2, boundingBox: CGRect(x: 0.42, y: 0.41, width: 0.20, height: 0.20))
            ]
        )
        XCTAssertEqual(instance, 2)
    }

    func testNothingContinuesAMaskWhenEveryCandidateIsSomewhereElse() {
        XCTAssertNil(
            ObjectMaskCandidatePolicy.continuation(
                of: CGRect(x: 0.40, y: 0.40, width: 0.10, height: 0.10),
                among: [
                    (instance: 1, boundingBox: CGRect(x: 0.70, y: 0.70, width: 0.10, height: 0.10))
                ]
            )
        )
    }

    /// Clipping a corner of the previous mask doesn't make it the same object.
    func testASlightOverlapDoesNotCountAsTheSameObject() {
        XCTAssertNil(
            ObjectMaskCandidatePolicy.continuation(
                of: CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20),
                among: [
                    (instance: 4, boundingBox: CGRect(x: 0.56, y: 0.56, width: 0.20, height: 0.20))
                ]
            )
        )
    }

    /// A piece of the mask on screen counts as the same object, even though its IoU is low.
    func testAPieceOfTheMaskOnScreenIsTheSameObject() {
        let onScreen = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)
        let piece = CGRect(x: 0.42, y: 0.50, width: 0.16, height: 0.09)
        XCTAssertLessThan(
            ObjectMaskCandidatePolicy.intersectionOverUnion(onScreen, piece),
            ObjectMaskCandidatePolicy.continuationOverlap
        )
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.continuation(
                of: onScreen,
                among: [(instance: 6, boundingBox: piece)]
            ),
            6
        )
    }

    /// When the object comes back in pieces, the largest one wins.
    func testTheMostCompletePieceWins() {
        let onScreen = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.20)
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.continuation(
                of: onScreen,
                among: [
                    (instance: 1, boundingBox: CGRect(x: 0.41, y: 0.41, width: 0.05, height: 0.05)),
                    (instance: 2, boundingBox: CGRect(x: 0.41, y: 0.47, width: 0.17, height: 0.12))
                ]
            ),
            2
        )
    }

    func testOverlapOfTheSmallerIsOneWhenContained() {
        let big = CGRect(x: 0, y: 0, width: 1, height: 1)
        let inside = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.overlapOfSmaller(big, inside),
            1,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.overlapOfSmaller(
                big,
                CGRect(x: 2, y: 2, width: 0.2, height: 0.2)
            ),
            0,
            accuracy: 1e-9
        )
    }

    func testOverlapIsIntersectionOverUnion() {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.intersectionOverUnion(unit, unit),
            1,
            accuracy: 1e-9
        )
        // Half-overlapping unit squares: intersection 0.5, union 1.5.
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.intersectionOverUnion(
                unit,
                CGRect(x: 0.5, y: 0, width: 1, height: 1)
            ),
            1.0 / 3.0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.intersectionOverUnion(
                unit,
                CGRect(x: 2, y: 0, width: 1, height: 1)
            ),
            0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.intersectionOverUnion(unit, .zero),
            0,
            accuracy: 1e-9
        )
    }

    /// The release threshold is looser than the acquire threshold, so the mask doesn't blink at an edge.
    func testAMaskIsHeldAtADistanceThatWouldNotHaveAcquiredIt() {
        let aim = CGPoint(x: 0.5, y: 0.5)
        let justOutside = CGRect(
            x: 0.5 + ObjectMaskCandidatePolicy.aimBoundsSlack + 0.01,
            y: 0.47,
            width: 0.08,
            height: 0.08
        )
        XCTAssertFalse(
            ObjectMaskCandidatePolicy.isAimedAt(boundingBox: justOutside, aim: aim)
        )
        XCTAssertTrue(
            ObjectMaskCandidatePolicy.isAimedAt(
                boundingBox: justOutside,
                aim: aim,
                slack: ObjectMaskCandidatePolicy.heldAimBoundsSlack
            )
        )
        XCTAssertGreaterThan(
            ObjectMaskCandidatePolicy.heldAimBoundsSlack,
            ObjectMaskCandidatePolicy.aimBoundsSlack
        )
    }

    // MARK: - When the held mask lets go

    func testHeldMaskWinsCloseCallsIncludingWhenTheCrosshairIsInsideBoth() {
        // Nothing else is aimed at.
        XCTAssertTrue(
            ObjectMaskCandidatePolicy.keepsHeldMask(
                heldAimDistance: 0.02,
                challengerAimDistance: nil
            )
        )
        // Crosshair inside both masks: ties go to the one on screen.
        XCTAssertTrue(
            ObjectMaskCandidatePolicy.keepsHeldMask(
                heldAimDistance: 0,
                challengerAimDistance: 0
            )
        )
        // Both slightly off the crosshair: no reason to switch.
        XCTAssertTrue(
            ObjectMaskCandidatePolicy.keepsHeldMask(
                heldAimDistance: 0.03,
                challengerAimDistance: 0.01
            )
        )
    }

    /// The hold only loses when the crosshair moves well inside another object.
    func testHeldMaskLetsGoWhenTheCrosshairIsInsideAnotherObject() {
        XCTAssertFalse(
            ObjectMaskCandidatePolicy.keepsHeldMask(
                heldAimDistance: 0.04,
                challengerAimDistance: 0
            )
        )
    }

    func testHeldMaskLetsGoOnceTheCrosshairIsWellClearOfIt() {
        XCTAssertFalse(
            ObjectMaskCandidatePolicy.keepsHeldMask(
                heldAimDistance: ObjectMaskCandidatePolicy.heldAimBoundsSlack + 0.01,
                challengerAimDistance: nil
            )
        )
    }

    func testDistanceIsZeroInsideTheBoundsAndGrowsOutside() {
        let box = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.distance(
                from: CGPoint(x: 0.3, y: 0.3),
                toBoundsOf: box
            ),
            0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.distance(
                from: CGPoint(x: 0.5, y: 0.3),
                toBoundsOf: box
            ),
            0.1,
            accuracy: 1e-6
        )
    }
}
