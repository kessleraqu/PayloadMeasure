import XCTest
import simd
@testable import PayloadMeasure

final class BaldiLoadingGuideTests: XCTestCase {
    func testOpeningMarkerFollowsOriginalAxisZeroThroughEveryRotation() {
        let expectedContainerAxes = [0, 0, 1, 2, 1, 2]
        let expectedFaceAxes = [
            (normal: 2, length: 0, width: 1),
            (normal: 1, length: 0, width: 2),
            (normal: 2, length: 1, width: 0),
            (normal: 1, length: 2, width: 0),
            (normal: 0, length: 1, width: 2),
            (normal: 0, length: 2, width: 1),
        ]
        let expectedDescriptions = [
            "Opening and length along the container",
            "Opening and length along the container",
            "Opening and length across the container",
            "Opening and length vertical",
            "Opening and length across the container",
            "Opening and length vertical",
        ]

        for (index, rotation) in BaldiRotation.all.enumerated() {
            let placement = BaldiTestFixtures.placement(origin: .zero, rotation: rotation)

            XCTAssertEqual(BaldiOpeningMarker.containerAxis(for: placement), expectedContainerAxes[index])
            XCTAssertEqual(BaldiOpeningMarker.description(for: placement), expectedDescriptions[index])
            let faceAxes = BaldiOpeningMarker.faceAxes(for: placement)
            XCTAssertEqual(faceAxes?.normal, expectedFaceAxes[index].normal)
            XCTAssertEqual(faceAxes?.length, expectedFaceAxes[index].length)
            XCTAssertEqual(faceAxes?.width, expectedFaceAxes[index].width)
        }
    }

    /// An object that already arrived as its own box was never given an opening to match: the length
    /// axis is still meaningful for placement, but nothing chose it to line up with a real opening,
    /// so the description must not claim one.
    func testDescriptionOmitsTheOpeningForAnObjectThatIsItsOwnBox() {
        let placement = BaldiTestFixtures.placement(origin: .zero, isOwnBox: true)
        XCTAssertEqual(
            BaldiOpeningMarker.description(for: placement),
            "Already its own box — no catalogue opening to line up"
        )
    }

    /// The flag on the item the solver was given must survive into the placement it produces, since
    /// that is the only copy the loading guide ever sees.
    func testIsOwnBoxSurvivesFromItemIntoItsPlacement() {
        let item = BaldiTestFixtures.item(isOwnBox: true)
        let solution = BaldiConstruction.pack(
            order: [item],
            knapsack: BaldiTestFixtures.knapsack()
        )
        XCTAssertEqual(solution.placements.first?.isOwnBox, true)
    }

    func testOpeningLineIsMarkedCoveredOnlyOnTheTouchingLWFace() {
        let package = BaldiTestFixtures.placement(
            name: "Lower",
            origin: .zero,
            size: SIMD3(20, 20, 10)
        )
        let upper = BaldiTestFixtures.placement(
            name: "Upper",
            origin: SIMD3(5, 5, 10),
            size: SIMD3(10, 10, 5)
        )

        XCTAssertEqual(
            BaldiOpeningMarker.coveredFaceSigns(
                for: package,
                among: [package, upper]
            ),
            Set([1])
        )
        XCTAssertEqual(
            BaldiOpeningMarker.coveredFaceSigns(
                for: upper,
                among: [package, upper]
            ),
            Set([-1])
        )
    }

    func testSideContactDoesNotDotANonTouchingLWFace() {
        let first = BaldiTestFixtures.placement(origin: .zero)
        let beside = BaldiTestFixtures.placement(origin: SIMD3(10, 0, 0))
        XCTAssertTrue(
            BaldiOpeningMarker.coveredFaceSigns(
                for: first,
                among: [first, beside]
            ).isEmpty
        )
    }

    func testFloorPackagesAtTheSameBaseShareLayerOne() {
        let first = BaldiTestFixtures.placement(
            name: "First",
            origin: SIMD3(0, 0, 0)
        )
        let second = BaldiTestFixtures.placement(
            name: "Second",
            origin: SIMD3(20, 0, 0)
        )
        let solution = BaldiTestFixtures.solution(placements: [second, first])

        let layers = BaldiLoadingGuide.layers(for: solution)

        XCTAssertEqual(layers.count, 1)
        XCTAssertEqual(layers[0].index, 0)
        XCTAssertEqual(layers[0].baseHeight, 0, accuracy: 1e-12)
        XCTAssertTrue(layers[0].isFloorLayer)
        XCTAssertEqual(layers[0].placements.map(\.id), [first.id, second.id])
    }

    func testNumericallyEqualBaseHeightsShareALayerWithinContactTolerance() {
        let tolerance = BaldiVerticalSupport.contactTolerance
        let first = BaldiTestFixtures.placement(
            name: "First",
            origin: SIMD3(0, 0, 10)
        )
        let withinTolerance = BaldiTestFixtures.placement(
            name: "Within tolerance",
            origin: SIMD3(20, 0, 10 + tolerance / 2)
        )
        let aboveTolerance = BaldiTestFixtures.placement(
            name: "Above tolerance",
            origin: SIMD3(40, 0, 10 + tolerance * 2)
        )
        let solution = BaldiTestFixtures.solution(
            placements: [aboveTolerance, withinTolerance, first]
        )

        let layers = BaldiLoadingGuide.layers(for: solution)

        XCTAssertEqual(layers.count, 2)
        XCTAssertEqual(layers[0].placements.map(\.id), [first.id, withinTolerance.id])
        XCTAssertEqual(layers[1].placements.map(\.id), [aboveTolerance.id])
    }

    func testHigherBaseIsOrderedAfterItsSupporter() {
        let supporter = BaldiTestFixtures.placement(
            name: "Supporter",
            origin: .zero,
            size: SIMD3(10, 10, 5)
        )
        let upper = BaldiTestFixtures.placement(
            name: "Upper",
            origin: SIMD3(0, 0, 5),
            size: SIMD3(10, 10, 5)
        )
        let solution = BaldiTestFixtures.solution(placements: [upper, supporter])

        let layers = BaldiLoadingGuide.layers(for: solution)

        XCTAssertEqual(layers.map(\.baseHeight), [0, 5])
        XCTAssertEqual(layers[0].placements.map(\.id), [supporter.id])
        XCTAssertEqual(layers[1].placements.map(\.id), [upper.id])
    }

    func testXYUUIDOrderingAndGuideNumberingAreDeterministic() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let first = BaldiTestFixtures.placement(
            id: firstID,
            name: "First",
            origin: SIMD3(0, 0, 0)
        )
        let second = BaldiTestFixtures.placement(
            id: secondID,
            name: "Second",
            origin: SIMD3(0, 0, 0)
        )
        let third = BaldiTestFixtures.placement(
            name: "Third",
            origin: SIMD3(0, 10, 0)
        )
        let fourth = BaldiTestFixtures.placement(
            name: "Fourth",
            origin: SIMD3(10, 0, 0)
        )
        let solution = BaldiTestFixtures.solution(
            placements: [fourth, third, second, first]
        )

        let ordered = BaldiLoadingGuide.orderedPlacements(in: solution)
        let flattenedLayers = BaldiLoadingGuide.layers(for: solution).flatMap(\.placements)
        let numbering = BaldiLoadingGuide.numbering(for: solution)

        XCTAssertEqual(ordered.map(\.id), [first.id, second.id, third.id, fourth.id])
        XCTAssertEqual(flattenedLayers.map(\.id), ordered.map(\.id))
        XCTAssertEqual(numbering[first.id], 1)
        XCTAssertEqual(numbering[second.id], 2)
        XCTAssertEqual(numbering[third.id], 3)
        XCTAssertEqual(numbering[fourth.id], 4)
    }
}
