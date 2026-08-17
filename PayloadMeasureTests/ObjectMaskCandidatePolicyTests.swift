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

    /// The fallback is the aim window and nothing wider. An instance Vision found somewhere else in
    /// the frame is not a candidate at all, which is what stopped the preview jumping to an object at
    /// the edge of the screen.
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

    /// A small object's mask does not always sit under a hand-held crosshair, so a little slack has
    /// to count as pointing at it.
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
