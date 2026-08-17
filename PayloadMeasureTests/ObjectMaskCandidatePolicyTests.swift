import XCTest
@testable import PayloadMeasure

final class ObjectMaskCandidatePolicyTests: XCTestCase {
    func testCentreCandidatesRemainThePreferredFastPath() {
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.previewInstances(
                nearby: IndexSet([4, 2]),
                all: IndexSet([1, 2, 3, 4]),
                excluding: []
            ),
            [2, 4]
        )
    }

    func testSmallObjectIsStillConsideredWhenCentreProbesMissIt() {
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.previewInstances(
                nearby: IndexSet(),
                all: IndexSet([3, 7]),
                excluding: []
            ),
            [3, 7]
        )
    }

    func testFinishedObjectsAreExcludedFromBothCandidatePaths() {
        XCTAssertEqual(
            ObjectMaskCandidatePolicy.previewInstances(
                nearby: IndexSet(integer: 3),
                all: IndexSet([3, 7]),
                excluding: [3]
            ),
            [7]
        )
    }
}
