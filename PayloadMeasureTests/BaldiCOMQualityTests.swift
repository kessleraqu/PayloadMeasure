import XCTest
import simd
@testable import PayloadMeasure

final class BaldiCOMQualityTests: XCTestCase {
    private func options(for mode: BaldiPackingMode) -> BaldiBalancer.Options {
        var options = BaldiBalancer.Options()
        options.mode = mode
        return options
    }

    func testEmptyPackingHasNoFiniteCOMQuality() {
        let empty = BaldiTestFixtures.solution(placements: [])

        XCTAssertEqual(empty.centreOfMassDistanceToIdeal, .infinity)
        XCTAssertEqual(BaldiBalancer.Options().mode, .paper)
        XCTAssertEqual(BaldiPackingMode.allCases, [.paper, .centred])
    }

    func testPaperStopsWhenAdmissibleWhileCentredMovesCloserToIdealCentre() {
        let item = BaldiTestFixtures.item(size: SIMD3(10, 10, 10))
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(30, 10, 10))
        let original = BaldiTestFixtures.placement(
            id: item.id,
            name: item.name,
            origin: .zero,
            size: item.size,
            mass: item.mass
        )
        let before = BaldiTestFixtures.solution(
            placements: [original],
            knapsack: knapsack
        )

        let paperPlacements = BaldiBalancer.optimise(
            placements: before.placements,
            knapsack: knapsack
        )
        let adjustedPlacements = BaldiBalancer.optimise(
            placements: before.placements,
            knapsack: knapsack,
            options: options(for: .centred)
        )
        let after = BaldiTestFixtures.solution(
            placements: adjustedPlacements,
            knapsack: knapsack
        )

        XCTAssertTrue(before.isBalanced)
        XCTAssertEqual(paperPlacements[0].origin, original.origin)
        XCTAssertTrue(after.isBalanced)
        XCTAssertTrue(after.isFullySupported)
        XCTAssertLessThan(after.centreOfMassDistanceToIdeal, before.centreOfMassDistanceToIdeal)
        XCTAssertEqual(after.centreOfMass, knapsack.idealCentreOfMass)
        XCTAssertEqual(after.placements[0].origin, SIMD3(10, 0, 0))
    }

    func testImprovingMovePreservesWholePackingSupportAndGeometry() {
        let knapsack = BaldiTestFixtures.knapsack(
            size: SIMD3(30, 10, 10),
            domainLower: SIMD3(0, 0, 4),
            domainUpper: SIMD3(28, 10, 10)
        )
        let supportItem = BaldiTestFixtures.item(
            name: "Support",
            size: SIMD3(20, 10, 5),
            mass: 1
        )
        let topItem = BaldiTestFixtures.item(
            name: "Top",
            size: SIMD3(10, 10, 5),
            mass: 9
        )
        let support = BaldiTestFixtures.placement(
            id: supportItem.id,
            name: supportItem.name,
            origin: .zero,
            size: supportItem.size,
            mass: supportItem.mass
        )
        let top = BaldiTestFixtures.placement(
            id: topItem.id,
            name: topItem.name,
            origin: SIMD3(0, 0, 5),
            size: topItem.size,
            mass: topItem.mass
        )
        let before = BaldiTestFixtures.solution(
            placements: [support, top],
            knapsack: knapsack
        )

        let adjusted = BaldiBalancer.optimise(
            placements: before.placements,
            knapsack: knapsack,
            options: options(for: .centred)
        )
        let after = BaldiTestFixtures.solution(placements: adjusted, knapsack: knapsack)
        let problem = BaldiTestFixtures.problem(
            items: [supportItem, topItem],
            knapsack: knapsack
        )
        let verification = BaldiVerifier.verify(after, against: problem)

        XCTAssertLessThan(after.centreOfMassDistanceToIdeal, before.centreOfMassDistanceToIdeal)
        XCTAssertTrue(verification.isValid, verification.violations.joined(separator: "\n"))
        XCTAssertTrue(verification.isFullySupported)
        XCTAssertTrue(verification.isBalanced)
    }

    func testBalancedPackingCannotBeRefinedOutsideRectangularDomain() {
        let knapsack = BaldiTestFixtures.knapsack(
            size: SIMD3(200, 10, 30),
            domainLower: SIMD3(10, 0, 14.8),
            domainUpper: SIMD3(128.33333333333334, 10, 16.033333333333335)
        )
        let tallSupport = BaldiTestFixtures.placement(
            name: "Tall support",
            origin: .zero,
            size: SIMD3(10, 10, 15),
            mass: 1
        )
        let movable = BaldiTestFixtures.placement(
            name: "Movable",
            origin: SIMD3(0, 0, 15),
            size: SIMD3(10, 10, 5),
            mass: 10
        )
        let lowSupport = BaldiTestFixtures.placement(
            name: "Low support",
            origin: SIMD3(70, 0, 0),
            size: SIMD3(10, 10, 5),
            mass: 1
        )
        let before = BaldiTestFixtures.solution(
            placements: [tallSupport, movable, lowSupport],
            knapsack: knapsack
        )

        let adjusted = BaldiBalancer.optimise(
            placements: before.placements,
            knapsack: knapsack,
            options: options(for: .centred)
        )
        let after = BaldiTestFixtures.solution(placements: adjusted, knapsack: knapsack)

        XCTAssertTrue(before.isBalanced)
        XCTAssertTrue(after.isBalanced)
        XCTAssertTrue(after.isFullySupported)
        XCTAssertLessThanOrEqual(
            after.centreOfMassDistanceToIdeal,
            before.centreOfMassDistanceToIdeal
        )
    }

    func testHeavyStackedPackageCanRelocateIntoOpenFloorRegion() throws {
        let supportItem = BaldiTestFixtures.item(
            name: "Tall support",
            size: SIMD3(10, 10, 10),
            mass: 1
        )
        let heavyItem = BaldiTestFixtures.item(
            name: "Heavy top",
            size: SIMD3(10, 10, 10),
            mass: 10
        )
        let idealX = 255.0 / 11.0
        let knapsack = BaldiTestFixtures.knapsack(
            size: SIMD3(40, 10, 20),
            domainLower: SIMD3(20, 0, 0),
            domainUpper: SIMD3(2 * idealX - 20, 10, 10)
        )
        let support = BaldiTestFixtures.placement(
            id: supportItem.id,
            name: supportItem.name,
            origin: .zero,
            size: supportItem.size,
            mass: supportItem.mass
        )
        let heavyTop = BaldiTestFixtures.placement(
            id: heavyItem.id,
            name: heavyItem.name,
            origin: SIMD3(0, 0, 10),
            size: heavyItem.size,
            mass: heavyItem.mass
        )
        let before = BaldiTestFixtures.solution(
            placements: [support, heavyTop],
            knapsack: knapsack
        )

        let paperAdjusted = BaldiBalancer.optimise(
            placements: before.placements,
            knapsack: knapsack
        )
        let adjusted = BaldiBalancer.optimise(
            placements: before.placements,
            knapsack: knapsack,
            options: options(for: .centred)
        )
        let after = BaldiTestFixtures.solution(placements: adjusted, knapsack: knapsack)
        let problem = BaldiTestFixtures.problem(
            items: [supportItem, heavyItem],
            knapsack: knapsack
        )
        let verification = BaldiVerifier.verify(after, against: problem)
        let relocated = try XCTUnwrap(after.placements.first(where: { $0.id == heavyItem.id }))
        let paperTop = try XCTUnwrap(paperAdjusted.first(where: { $0.id == heavyItem.id }))

        XCTAssertFalse(before.isBalanced)
        XCTAssertEqual(paperTop.origin, heavyTop.origin)
        XCTAssertEqual(relocated.origin.x, 20, accuracy: 1e-9)
        XCTAssertEqual(relocated.origin.z, 0, accuracy: 1e-9)
        XCTAssertLessThan(after.centreOfMassDistanceToIdeal, before.centreOfMassDistanceToIdeal)
        XCTAssertTrue(verification.isValid, verification.violations.joined(separator: "\n"))
        XCTAssertTrue(verification.isBalanced)
        XCTAssertTrue(verification.isFullySupported)
    }

    func testSameCardinalityFeasibleTiePrefersCargoCOMCloserToIdeal() {
        let item = BaldiTestFixtures.item(size: SIMD3(10, 10, 10))
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(30, 10, 10))
        let offCentre = BaldiTestFixtures.solution(
            placements: [
                BaldiTestFixtures.placement(
                    id: item.id,
                    name: item.name,
                    origin: .zero,
                    size: item.size,
                    mass: item.mass
                ),
            ],
            knapsack: knapsack
        )
        let centred = BaldiTestFixtures.solution(
            placements: [
                BaldiTestFixtures.placement(
                    id: item.id,
                    name: item.name,
                    origin: SIMD3(10, 0, 0),
                    size: item.size,
                    mass: item.mass
                ),
            ],
            knapsack: knapsack
        )
        let problem = BaldiTestFixtures.problem(items: [item], knapsack: knapsack)

        XCTAssertTrue(BaldiVerifier.verify(offCentre, against: problem).isValid)
        XCTAssertTrue(BaldiVerifier.verify(centred, against: problem).isValid)
        // Paper mode ranks by eq. (24), so the better balanced packing wins at equal count. Centred mode
        // differs by continuing after the centre of mass is admissible and ranking by distance to the
        // domain centre.
        XCTAssertTrue(BaldiSearch.isBetterFeasible(centred, than: offCentre, alpha: 0.1, mode: .paper))
        XCTAssertFalse(BaldiSearch.isBetterFeasible(centred, than: offCentre, alpha: 0, mode: .paper))
        XCTAssertTrue(BaldiSearch.isBetterFeasible(centred, than: offCentre, alpha: 0.1, mode: .centred))
        XCTAssertFalse(BaldiSearch.isBetterFeasible(offCentre, than: centred, alpha: 0.1, mode: .centred))
    }

    func testLoadedCountRemainsPrimaryOverCOMQuality() {
        let first = BaldiTestFixtures.item(name: "First", size: SIMD3(10, 10, 10))
        let second = BaldiTestFixtures.item(name: "Second", size: SIMD3(10, 10, 10))
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(40, 10, 10))
        let perfectlyCentred = BaldiTestFixtures.solution(
            placements: [
                BaldiTestFixtures.placement(
                    id: first.id,
                    name: first.name,
                    origin: SIMD3(15, 0, 0),
                    size: first.size,
                    mass: first.mass
                ),
            ],
            unloaded: [second],
            knapsack: knapsack
        )
        let morePackages = BaldiTestFixtures.solution(
            placements: [
                BaldiTestFixtures.placement(
                    id: first.id,
                    name: first.name,
                    origin: .zero,
                    size: first.size,
                    mass: first.mass
                ),
                BaldiTestFixtures.placement(
                    id: second.id,
                    name: second.name,
                    origin: SIMD3(10, 0, 0),
                    size: second.size,
                    mass: second.mass
                ),
            ],
            knapsack: knapsack
        )

        XCTAssertEqual(perfectlyCentred.centreOfMassDistanceToIdeal, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(morePackages.centreOfMassDistanceToIdeal, 0)
        for mode in BaldiPackingMode.allCases {
            XCTAssertTrue(
                BaldiSearch.isBetterForSearch(
                    morePackages,
                    than: perfectlyCentred,
                    alpha: 0.9,
                    mode: mode
                )
            )
            XCTAssertTrue(
                BaldiSearch.isBetterFeasible(
                    morePackages,
                    than: perfectlyCentred,
                    alpha: 0.9,
                    mode: mode
                )
            )
        }
    }

    func testSolveBothReturnsExplicitPaperAndCentredResults() async throws {
        let item = BaldiTestFixtures.item(size: SIMD3(10, 10, 10))
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(30, 10, 10))
        let problem = BaldiTestFixtures.problem(items: [item], knapsack: knapsack)
        var options = BaldiOptions()
        options.heuristic.timeLimitSeconds = 1e-6

        let comparison = await BaldiSolver.solveBoth(problem, options: options)
        let paper = comparison.result(for: .paper)
        let centred = comparison.result(for: .centred)
        let paperPlacement = try XCTUnwrap(paper.solution?.placements.first)
        let centredPlacement = try XCTUnwrap(centred.solution?.placements.first)

        XCTAssertEqual(paper.status, .feasible)
        XCTAssertEqual(centred.status, .feasible)
        XCTAssertEqual(paperPlacement.origin, .zero)
        XCTAssertEqual(centredPlacement.origin, SIMD3(10, 0, 0))
        XCTAssertGreaterThan(
            paper.solution?.centreOfMassDistanceToIdeal ?? 0,
            centred.solution?.centreOfMassDistanceToIdeal ?? .infinity
        )
    }
}
