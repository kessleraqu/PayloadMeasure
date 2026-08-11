import XCTest
import simd
@testable import PayloadMeasure

final class BaldiPipelineTests: XCTestCase {
    func testBaldiDefinesExactlySixDistinctAxisPermutations() {
        XCTAssertEqual(BaldiRotation.all.count, 6)
        XCTAssertEqual(Set(BaldiRotation.all).count, 6)
        XCTAssertEqual(
            Set(BaldiRotation.all.map(\.sourceAxis)),
            Set([
                [0, 1, 2], [0, 2, 1], [1, 0, 2],
                [1, 2, 0], [2, 0, 1], [2, 1, 0],
            ])
        )
    }

    func testEveryRotationUsesTheGeometricCentreAsPackageCOM() {
        let sourceSize = SIMD3(2, 4, 6)

        for rotation in BaldiRotation.all {
            let rotated = rotation.size(of: sourceSize)
            let expected = SIMD3(
                Double(rotated.x) / 2,
                Double(rotated.y) / 2,
                Double(rotated.z) / 2
            )
            XCTAssertEqual(rotation.centreOfMassOffset(of: sourceSize), expected)
        }
    }

    func testPackingGateRejectsPartialSupportAndAcceptsCompleteSupport() {
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(10, 10, 15))
        let supporter = BaldiTestFixtures.item(
            name: "Supporter",
            size: SIMD3(5, 10, 5)
        )
        let target = BaldiTestFixtures.item(
            name: "Target",
            size: SIMD3(10, 10, 5)
        )
        var packing = BaldiPacking(knapsack: knapsack)
        packing.place(
            item: supporter,
            rotation: BaldiTestFixtures.upright,
            at: BaldiExtremePoint(position: .zero, residualSpace: SIMD3(10, 10, 15))
        )
        let stackedPoint = BaldiExtremePoint(
            position: SIMD3(0, 0, 5),
            residualSpace: SIMD3(10, 10, 10)
        )

        XCTAssertFalse(
            packing.canPlace(
                item: target,
                rotation: BaldiTestFixtures.upright,
                at: stackedPoint
            )
        )

        var fullyCoveredPacking = BaldiPacking(knapsack: knapsack)
        let fullSupporter = BaldiTestFixtures.item(
            name: "Full supporter",
            size: SIMD3(10, 10, 5)
        )
        fullyCoveredPacking.place(
            item: fullSupporter,
            rotation: BaldiTestFixtures.upright,
            at: BaldiExtremePoint(position: .zero, residualSpace: SIMD3(10, 10, 15))
        )
        XCTAssertTrue(
            fullyCoveredPacking.canPlace(
                item: target,
                rotation: BaldiTestFixtures.upright,
                at: stackedPoint
            )
        )
    }

    func testEPBPHRejectsOnlyAvailablePartialStack() {
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(10, 10, 15))
        let supporter = BaldiTestFixtures.item(
            name: "Supporter",
            size: SIMD3(5, 10, 5)
        )
        let target = BaldiTestFixtures.item(
            name: "Target",
            size: SIMD3(10, 10, 10)
        )

        let solution = BaldiEPBPH.pack(order: [supporter, target], knapsack: knapsack)

        XCTAssertEqual(solution.placements.map(\.id), [supporter.id])
        XCTAssertEqual(solution.unloaded.map(\.id), [target.id])
        XCTAssertTrue(solution.isFullySupported)
    }

    func testEPBPHAcceptsACompleteStack() {
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(10, 10, 10))
        let bottom = BaldiTestFixtures.item(
            name: "Bottom",
            size: SIMD3(10, 10, 5)
        )
        let top = BaldiTestFixtures.item(
            name: "Top",
            size: SIMD3(10, 10, 5)
        )

        let solution = BaldiEPBPH.pack(order: [bottom, top], knapsack: knapsack)

        XCTAssertEqual(solution.loadedCount, 2)
        XCTAssertTrue(solution.unloaded.isEmpty)
        XCTAssertTrue(solution.isFullySupported)
        XCTAssertEqual(solution.placements[1].origin.z, 5, accuracy: 1e-9)
    }

    func testEPBPHAcceptsAStackTiledByMultipleSupporters() {
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(10, 10, 10))
        let left = BaldiTestFixtures.item(
            name: "Left support",
            size: SIMD3(5, 10, 5)
        )
        let right = BaldiTestFixtures.item(
            name: "Right support",
            size: SIMD3(5, 10, 5)
        )
        let top = BaldiTestFixtures.item(
            name: "Top",
            size: SIMD3(10, 10, 5)
        )

        let solution = BaldiEPBPH.pack(order: [left, right, top], knapsack: knapsack)
        let topReport = solution.placements
            .first(where: { $0.id == top.id })
            .map { BaldiVerticalSupport.report(for: $0, among: solution.placements) }

        XCTAssertEqual(solution.loadedCount, 3)
        XCTAssertTrue(solution.isFullySupported)
        XCTAssertEqual(topReport?.supporterIDs.count, 2)
        XCTAssertEqual(topReport?.fraction ?? 0, 1, accuracy: 1e-9)
    }

    func testCOMOptimisationNeverBreaksAValidSupportChain() {
        let knapsack = BaldiTestFixtures.knapsack(
            size: SIMD3(30, 10, 20),
            domainLower: SIMD3(20, 0, 0),
            domainUpper: SIMD3(25, 10, 20)
        )
        let bottom = BaldiTestFixtures.placement(
            name: "Bottom",
            origin: .zero,
            size: SIMD3(10, 10, 5),
            mass: 10
        )
        let top = BaldiTestFixtures.placement(
            name: "Top",
            origin: SIMD3(0, 0, 5),
            size: SIMD3(10, 10, 5),
            mass: 1
        )
        var options = BaldiCentreOfMassOptimisation.Options()
        options.maximumIterations = 5

        let adjusted = BaldiCentreOfMassOptimisation.optimise(
            placements: [bottom, top],
            knapsack: knapsack,
            options: options
        )

        XCTAssertTrue(BaldiVerticalSupport.allFullySupported(adjusted))
        for first in 0..<adjusted.count {
            for second in (first + 1)..<adjusted.count {
                XCTAssertFalse(adjusted[first].overlaps(adjusted[second]))
            }
        }
    }

    func testIndependentVerifierAcceptsAValidBalancedStack() {
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(20, 10, 10))
        let bottomItem = BaldiTestFixtures.item(
            name: "Bottom",
            size: SIMD3(10, 10, 5),
            mass: 2
        )
        let topItem = BaldiTestFixtures.item(
            name: "Top",
            size: SIMD3(10, 10, 5),
            mass: 1
        )
        let bottom = BaldiTestFixtures.placement(
            id: bottomItem.id,
            name: bottomItem.name,
            origin: .zero,
            size: bottomItem.size,
            mass: bottomItem.mass
        )
        let top = BaldiTestFixtures.placement(
            id: topItem.id,
            name: topItem.name,
            origin: SIMD3(0, 0, 5),
            size: topItem.size,
            mass: topItem.mass
        )
        let problem = BaldiTestFixtures.problem(
            items: [bottomItem, topItem],
            knapsack: knapsack
        )
        let solution = BaldiTestFixtures.solution(
            placements: [bottom, top],
            knapsack: knapsack
        )

        let verification = BaldiGeometryCheck.verify(solution, against: problem)

        XCTAssertTrue(verification.isValid, verification.violations.joined(separator: "\n"))
        XCTAssertTrue(verification.isBalanced)
        XCTAssertTrue(verification.isFullySupported)
        XCTAssertEqual(verification.supportReports.count, 2)
    }

    func testIndependentVerifierRejectsPartialSupport() {
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(20, 10, 10))
        let bottomItem = BaldiTestFixtures.item(
            name: "Bottom",
            size: SIMD3(5, 10, 5)
        )
        let topItem = BaldiTestFixtures.item(
            name: "Top",
            size: SIMD3(10, 10, 5)
        )
        let bottom = BaldiTestFixtures.placement(
            id: bottomItem.id,
            name: bottomItem.name,
            origin: .zero,
            size: bottomItem.size
        )
        let top = BaldiTestFixtures.placement(
            id: topItem.id,
            name: topItem.name,
            origin: SIMD3(0, 0, 5),
            size: topItem.size
        )
        let problem = BaldiTestFixtures.problem(
            items: [bottomItem, topItem],
            knapsack: knapsack
        )
        let solution = BaldiTestFixtures.solution(
            placements: [bottom, top],
            knapsack: knapsack
        )

        let verification = BaldiGeometryCheck.verify(solution, against: problem)

        XCTAssertFalse(verification.isValid)
        XCTAssertFalse(verification.isFullySupported)
        XCTAssertTrue(verification.violations.contains(where: { $0.contains("bottom-face support") }))
    }

    func testIndependentVerifierRejectsDimensionsThatDoNotMatchRotation() {
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(20, 20, 20))
        let item = BaldiTestFixtures.item(size: SIMD3(10, 10, 10))
        let malformed = BaldiTestFixtures.placement(
            id: item.id,
            name: item.name,
            origin: .zero,
            size: SIMD3(9, 10, 10)
        )
        let problem = BaldiTestFixtures.problem(items: [item], knapsack: knapsack)
        let solution = BaldiTestFixtures.solution(
            placements: [malformed],
            knapsack: knapsack
        )

        let verification = BaldiGeometryCheck.verify(solution, against: problem)

        XCTAssertFalse(verification.isValid)
        XCTAssertTrue(verification.violations.contains(where: { $0.contains("inconsistent") }))
    }

    func testIndependentVerifierRejectsDuplicateLoadedIdentifiers() {
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(20, 10, 10))
        let item = BaldiTestFixtures.item(size: SIMD3(10, 10, 10))
        let first = BaldiTestFixtures.placement(
            id: item.id,
            name: item.name,
            origin: .zero,
            size: item.size
        )
        let duplicate = BaldiTestFixtures.placement(
            id: item.id,
            name: item.name,
            origin: SIMD3(10, 0, 0),
            size: item.size
        )
        let problem = BaldiTestFixtures.problem(items: [item], knapsack: knapsack)
        let solution = BaldiTestFixtures.solution(
            placements: [first, duplicate],
            knapsack: knapsack
        )

        let verification = BaldiGeometryCheck.verify(solution, against: problem)

        XCTAssertFalse(verification.isValid)
        XCTAssertTrue(verification.violations.contains(where: { $0.contains("more than once") }))
    }

    func testIndependentVerifierRejectsCentreOfMassOutsideDomain() {
        let knapsack = BaldiTestFixtures.knapsack(
            size: SIMD3(20, 10, 10),
            domainLower: SIMD3(15, 0, 0),
            domainUpper: SIMD3(20, 10, 10)
        )
        let item = BaldiTestFixtures.item(size: SIMD3(10, 10, 10))
        let placement = BaldiTestFixtures.placement(
            id: item.id,
            name: item.name,
            origin: .zero,
            size: item.size
        )
        let problem = BaldiTestFixtures.problem(items: [item], knapsack: knapsack)
        let solution = BaldiTestFixtures.solution(
            placements: [placement],
            knapsack: knapsack
        )

        let verification = BaldiGeometryCheck.verify(solution, against: problem)

        XCTAssertFalse(verification.isValid)
        XCTAssertFalse(verification.isBalanced)
        XCTAssertTrue(verification.violations.contains(where: { $0.contains("outside") }))
    }

    func testEmptySolutionIsNeitherBalancedSupportedNorValid() {
        let item = BaldiTestFixtures.item()
        let knapsack = BaldiTestFixtures.knapsack()
        let problem = BaldiTestFixtures.problem(items: [item], knapsack: knapsack)
        let solution = BaldiTestFixtures.solution(
            placements: [],
            unloaded: [item],
            knapsack: knapsack
        )

        let verification = BaldiGeometryCheck.verify(solution, against: problem)

        XCTAssertFalse(solution.isBalanced)
        XCTAssertFalse(solution.isFullySupported)
        XCTAssertFalse(verification.isValid)
        XCTAssertFalse(verification.isBalanced)
        XCTAssertFalse(verification.isFullySupported)
    }

    func testEqualPriorityMakesProfitExactlyLoadedPackageCount() {
        let small = BaldiTestFixtures.item(name: "Small", size: SIMD3(1, 1, 1))
        let large = BaldiTestFixtures.item(name: "Large", size: SIMD3(50, 50, 50))
        let placements = [
            BaldiTestFixtures.placement(
                id: small.id,
                name: small.name,
                origin: .zero,
                size: small.size
            ),
            BaldiTestFixtures.placement(
                id: large.id,
                name: large.name,
                origin: SIMD3(50, 0, 0),
                size: large.size
            ),
        ]
        let solution = BaldiTestFixtures.solution(placements: placements)

        XCTAssertEqual(small.profit, 1, accuracy: 1e-9)
        XCTAssertEqual(large.profit, 1, accuracy: 1e-9)
        XCTAssertEqual(solution.profit, 2, accuracy: 1e-9)
        XCTAssertEqual(solution.profit, Double(solution.loadedCount), accuracy: 1e-9)
    }

    func testHeuristicDefaultsRetainBaldiScoreUpdatesAndDeterministicSeed() {
        let options = BaldiHeuristicOptions()

        XCTAssertEqual(options.scoreDecrease, 0.1, accuracy: 1e-12)
        XCTAssertEqual(options.scoreIncrease, 0.1, accuracy: 1e-12)
        XCTAssertEqual(options.randomSeed, 0x3B_C0_5EED)
    }

    func testConstructiveHeuristicPrefersTwoSmallPackagesOverOneLargePackage() {
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(10, 10, 10))
        let large = BaldiTestFixtures.item(
            name: "Large",
            size: SIMD3(10, 10, 10),
            mass: 1
        )
        let firstSmall = BaldiTestFixtures.item(
            name: "Small A",
            size: SIMD3(5, 10, 10),
            mass: 1
        )
        let secondSmall = BaldiTestFixtures.item(
            name: "Small B",
            size: SIMD3(5, 10, 10),
            mass: 1
        )
        let problem = BaldiTestFixtures.problem(
            items: [large, firstSmall, secondSmall],
            knapsack: knapsack
        )

        let result = BaldiHeuristic.constructInitialSolution(
            problem,
            options: BaldiHeuristicOptions()
        )

        XCTAssertEqual(result.solution.loadedCount, 2)
        XCTAssertEqual(
            Set(result.solution.placements.map(\.id)),
            Set([firstSmall.id, secondSmall.id])
        )
    }

    func testConstructiveHeuristicIsDeterministic() {
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(20, 10, 10))
        let items = [
            BaldiTestFixtures.item(name: "A", size: SIMD3(10, 10, 5), mass: 3),
            BaldiTestFixtures.item(name: "B", size: SIMD3(10, 10, 5), mass: 2),
            BaldiTestFixtures.item(name: "C", size: SIMD3(10, 10, 5), mass: 1),
        ]
        let problem = BaldiTestFixtures.problem(items: items, knapsack: knapsack)
        let options = BaldiHeuristicOptions()

        let first = BaldiHeuristic.constructInitialSolution(problem, options: options).solution
        let second = BaldiHeuristic.constructInitialSolution(problem, options: options).solution

        XCTAssertEqual(first.placements.map(\.id), second.placements.map(\.id))
        XCTAssertEqual(first.placements.map(\.origin), second.placements.map(\.origin))
        XCTAssertEqual(first.placements.map { $0.rotation.sourceAxis }, second.placements.map { $0.rotation.sourceAxis })
    }

    func testSolverRejectsInvalidInput() {
        let result = Baldi3BKPSolver.solve(
            BaldiTestFixtures.problem(items: [])
        )

        XCTAssertEqual(result.status.rawValue, "invalidInput")
        XCTAssertNil(result.solution)
        XCTAssertTrue(result.errors.contains(where: { $0.contains("at least one") }))
    }

    func testSolverReportsNotFoundWhenNoPackageFits() {
        let item = BaldiTestFixtures.item(size: SIMD3(20, 20, 20))
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(10, 10, 10))

        let result = Baldi3BKPSolver.solve(
            BaldiTestFixtures.problem(items: [item], knapsack: knapsack)
        )

        XCTAssertEqual(result.status.rawValue, "notFound")
        XCTAssertNil(result.solution)
        XCTAssertEqual(result.oversizedItems.map(\.id), [item.id])
    }

    func testSolverReturnsOnlyAnIndependentlyVerifiedFeasibleSolution() {
        let item = BaldiTestFixtures.item(size: SIMD3(10, 10, 10))
        let knapsack = BaldiTestFixtures.knapsack(size: SIMD3(10, 10, 10))
        var options = Baldi3BKPOptions()
        options.heuristic.timeLimitSeconds = 1e-6

        let result = Baldi3BKPSolver.solve(
            BaldiTestFixtures.problem(items: [item], knapsack: knapsack),
            options: options
        )

        XCTAssertEqual(result.status.rawValue, "feasible")
        XCTAssertNotNil(result.solution)
        XCTAssertTrue(result.verification?.isValid == true)
        XCTAssertTrue(result.verification?.isBalanced == true)
        XCTAssertTrue(result.verification?.isFullySupported == true)
    }

    func testSolverDoesNotPresentAnUnbalanceablePackingAsFeasible() {
        let item = BaldiTestFixtures.item(size: SIMD3(10, 10, 10))
        let knapsack = BaldiTestFixtures.knapsack(
            size: SIMD3(10, 10, 10),
            domainLower: SIMD3(8, 0, 0),
            domainUpper: SIMD3(9, 10, 10)
        )
        var options = Baldi3BKPOptions()
        options.heuristic.timeLimitSeconds = 1e-6

        let result = Baldi3BKPSolver.solve(
            BaldiTestFixtures.problem(items: [item], knapsack: knapsack),
            options: options
        )

        XCTAssertEqual(result.status.rawValue, "notFound")
        XCTAssertNil(result.solution)
        XCTAssertTrue(result.errors.contains(where: { $0.contains("does not prove") }))
    }

    func testReferenceModelUsesRepairedRotationSelectionEquality() throws {
        let item = BaldiTestFixtures.item(size: SIMD3(2, 3, 4))
        let model = Baldi3BKPModelBuilder.build(
            BaldiTestFixtures.problem(items: [item])
        )
        let row = try XCTUnwrap(model.program.rows.first(where: { $0.name == "rotation_0" }))
        let coefficients = Dictionary(uniqueKeysWithValues: zip(row.indices, row.coefficients))

        XCTAssertEqual(row.lower, 0, accuracy: 1e-9)
        XCTAssertEqual(row.upper, 0, accuracy: 1e-9)
        XCTAssertEqual(coefficients[model.selection[0]], -1)
        for variable in model.rotation[0] {
            XCTAssertEqual(coefficients[variable], 1)
        }
    }

    func testReferenceModelEquationTenUsesThePrecedingItemsRotationVariables() throws {
        let first = BaldiTestFixtures.item(name: "First", size: SIMD3(2, 3, 4))
        let second = BaldiTestFixtures.item(name: "Second", size: SIMD3(5, 7, 11))
        let model = Baldi3BKPModelBuilder.build(
            BaldiTestFixtures.problem(items: [first, second])
        )
        let row = try XCTUnwrap(model.program.rows.first(where: { $0.name == "before_1_0_1" }))
        let indices = Set(row.indices)

        XCTAssertTrue(indices.isSuperset(of: Set(model.rotation[1])))
        XCTAssertTrue(indices.isDisjoint(with: Set(model.rotation[0])))
    }
}
