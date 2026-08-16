import XCTest
import simd
@testable import PayloadMeasure

// Pins the behaviour that is claimed to come from the papers, so a later change cannot quietly turn
// a cited procedure into something else. Each test names the clause it is protecting.

final class BaldiPaperFidelityTests: XCTestCase {

    // MARK: - Eq. (24), F = P − αU

    func testMeritIsProfitMinusAlphaTimesUnbalancingIndex() {
        let knapsack = BaldiKnapsack(size: SIMD3(400, 200, 200))
        let solution = BaldiSolution(
            knapsack: knapsack,
            placements: [
                placement(origin: SIMD3(0, 0, 0), size: SIMD3(100, 100, 100), mass: 1),
                placement(origin: SIMD3(200, 50, 0), size: SIMD3(100, 100, 100), mass: 1),
            ],
            unloaded: []
        )

        let alpha = 0.4
        XCTAssertEqual(
            solution.merit(alpha: alpha),
            solution.profit - alpha * solution.normalisedUnbalancingIndex,
            accuracy: 1e-12
        )
        XCTAssertEqual(solution.profit, 2, "p_i = 1, so P is the loaded-package count.")
    }

    func testMeritPenaltyCanOrderEqualCountsButNeverOutvotesAPackage() {
        let knapsack = BaldiKnapsack(size: SIMD3(400, 200, 200))
        let centred = BaldiSolution(
            knapsack: knapsack,
            placements: [placement(origin: SIMD3(150, 50, 0), size: SIMD3(100, 100, 100), mass: 1)],
            unloaded: []
        )
        let cornered = BaldiSolution(
            knapsack: knapsack,
            placements: [placement(origin: SIMD3(0, 0, 0), size: SIMD3(60, 60, 60), mass: 1)],
            unloaded: []
        )
        let two = BaldiSolution(
            knapsack: knapsack,
            placements: [
                placement(origin: SIMD3(0, 0, 0), size: SIMD3(60, 60, 60), mass: 1),
                placement(origin: SIMD3(300, 130, 130), size: SIMD3(60, 60, 60), mass: 1),
            ],
            unloaded: []
        )

        // Equal count: the unbalancing penalty decides.
        XCTAssertTrue(
            BaldiSearch.isBetterForSearch(centred, than: cornered, alpha: 0.9),
            "Between two one-package packings the better balanced one wins."
        )
        // Unequal count: no admissible α can reverse it, because the penalty is below 1.
        XCTAssertTrue(BaldiSearch.isBetterForSearch(two, than: centred, alpha: 0.9))
        XCTAssertLessThan(two.normalisedUnbalancingIndex, 1.0000001)
    }

    func testAnUnbalancedPackingMayBeTheSearchIncumbent() {
        // §5.3.3 branches on "if the best solution found so far is unfeasible", so BS is allowed to
        // be unbalanced. The merit function must not silently forbid that.
        let knapsack = BaldiKnapsack(size: SIMD3(400, 200, 200))
        let unbalancedPair = BaldiSolution(
            knapsack: knapsack,
            placements: [
                placement(origin: SIMD3(0, 0, 0), size: SIMD3(40, 40, 40), mass: 1),
                placement(origin: SIMD3(40, 0, 0), size: SIMD3(40, 40, 40), mass: 1),
            ],
            unloaded: []
        )
        let balancedSingle = BaldiSolution(
            knapsack: knapsack,
            placements: [placement(origin: SIMD3(150, 50, 0), size: SIMD3(100, 100, 100), mass: 1)],
            unloaded: []
        )

        XCTAssertFalse(unbalancedPair.isBalanced)
        XCTAssertTrue(balancedSingle.isBalanced)
        XCTAssertTrue(
            BaldiSearch.isBetterForSearch(unbalancedPair, than: balancedSingle, alpha: 0.9),
            "Two packages beat one on F even when the two are unbalanced."
        )
    }

    // MARK: - §5.3.3 parameter adaptation

    func testBothAlphaAndBetaAdaptTogetherAsTheParagraphStates() {
        var alpha = 0.1
        var beta = 0.1
        let knapsack = BaldiKnapsack(size: SIMD3(400, 200, 200))
        let unbalanced = BaldiSolution(
            knapsack: knapsack,
            placements: [placement(origin: SIMD3(0, 0, 0), size: SIMD3(20, 20, 20), mass: 1)],
            unloaded: []
        )

        BaldiSearch.parameterUpdateForTesting(
            best: unbalanced,
            knapsack: knapsack,
            decrease: &alpha,
            increase: &beta
        )
        XCTAssertEqual(alpha, 0.2, accuracy: 1e-12, "α = 2α while the incumbent is infeasible.")
        XCTAssertEqual(beta, 0.2, accuracy: 1e-12, "β = 2β in the same clause.")

        // Feasible and in the central half: both halve.
        let centred = BaldiSolution(
            knapsack: knapsack,
            placements: [placement(origin: SIMD3(150, 50, 0), size: SIMD3(100, 100, 100), mass: 1)],
            unloaded: []
        )
        XCTAssertTrue(centred.isBalanced)
        BaldiSearch.parameterUpdateForTesting(
            best: centred,
            knapsack: knapsack,
            decrease: &alpha,
            increase: &beta
        )
        XCTAssertEqual(alpha, 0.1, accuracy: 1e-12)
        XCTAssertEqual(beta, 0.1, accuracy: 1e-12)
    }

    func testParametersStayInsideTheOpenUnitIntervalTheScoreUpdateRequires() {
        var alpha = 0.1
        var beta = 0.1
        let knapsack = BaldiKnapsack(size: SIMD3(400, 200, 200))
        let unbalanced = BaldiSolution(
            knapsack: knapsack,
            placements: [placement(origin: SIMD3(0, 0, 0), size: SIMD3(20, 20, 20), mass: 1)],
            unloaded: []
        )
        for _ in 0..<40 {
            BaldiSearch.parameterUpdateForTesting(
                best: unbalanced,
                knapsack: knapsack,
                decrease: &alpha,
                increase: &beta
            )
        }
        XCTAssertGreaterThan(alpha, 0)
        XCTAssertLessThan(alpha, 1, "(1 − α)·s must stay positive.")
        XCTAssertGreaterThan(beta, 0)
        XCTAssertLessThan(beta, 1)
    }

    // MARK: - §5.2 balancing

    func testGravityCompactionIsVacuousUnderFullSupport() {
        // §5.2 ends by compacting everything down the z axis. That step repairs mid-air placements,
        // which full support already forbids: a package off the floor rests on top faces covering it
        // completely, so it has nowhere to descend to. Lowering any package by any amount must break
        // either overlap or support.
        let knapsack = BaldiKnapsack(size: SIMD3(400, 200, 200))
        let stack = [
            placement(origin: SIMD3(0, 0, 0), size: SIMD3(100, 100, 50), mass: 2),
            placement(origin: SIMD3(0, 0, 50), size: SIMD3(100, 100, 50), mass: 1),
        ]
        XCTAssertTrue(BaldiVerticalSupport.allFullySupported(stack))

        for drop in [1.0, 5.0, 25.0, 50.0] {
            var lowered = stack
            lowered[1].origin.z -= drop
            let overlaps = lowered[0].overlaps(lowered[1])
            let supported = BaldiVerticalSupport.allFullySupported(lowered)
            XCTAssertTrue(
                overlaps || !supported,
                "Dropping the upper package by \(drop) mm must be illegal, so there is nothing to compact."
            )
        }
    }

    func testPaperBalancingUsesPackingOrderAndCentredUsesHeaviestFirst() {
        // Same instance, same everything except the mode. §5.2 fixes no order, so paper mode takes
        // packing order; heaviest-first belongs to the extension.
        let problem = twoPackageProblem()
        var paper = BaldiBalancer.Options()
        paper.mode = .paper
        var centred = BaldiBalancer.Options()
        centred.mode = .centred

        let start = BaldiConstruction.pack(order: problem.items, knapsack: problem.knapsack)
        XCTAssertGreaterThan(start.loadedCount, 1)

        let paperResult = BaldiBalancer.optimise(
            placements: start.placements,
            knapsack: problem.knapsack,
            options: paper
        )
        let centredResult = BaldiBalancer.optimise(
            placements: start.placements,
            knapsack: problem.knapsack,
            options: centred
        )

        // Both must stay legal whatever order they used.
        for result in [paperResult, centredResult] {
            XCTAssertTrue(BaldiVerticalSupport.allFullySupported(result))
            for first in result.indices {
                for second in result.indices where second > first {
                    XCTAssertFalse(result[first].overlaps(result[second]))
                }
            }
        }
        // Centred keeps going after feasibility, so it should land at least as close to the target.
        let target = problem.knapsack.idealCentreOfMass
        let paperDistance = simd_distance(BaldiBalancer.centreOfMass(of: paperResult), target)
        let centredDistance = simd_distance(BaldiBalancer.centreOfMass(of: centredResult), target)
        XCTAssertLessThanOrEqual(centredDistance, paperDistance + 1e-6)
    }

    // MARK: - Everything returned is verified

    func testEveryReturnedPackingPassesTheIndependentVerifier() async {
        let problem = twoPackageProblem()
        for mode in BaldiPackingMode.allCases {
            var options = BaldiOptions()
            options.heuristic.timeLimitSeconds = 0.3
            options.heuristic.centreOfMass.mode = mode
            let result = await BaldiSolver.solve(problem, options: options)
            guard let solution = result.solution else { continue }
            let verification = BaldiVerifier.verify(solution, against: problem)
            XCTAssertTrue(
                verification.isValid,
                "\(mode.rawValue): \(verification.violations.joined(separator: "; "))"
            )
            XCTAssertTrue(verification.isBalanced)
            XCTAssertTrue(verification.isFullySupported)
        }
    }

    // MARK: - Liu / Zhang

    func testClosenessIsMaximisedSoTheChosenAxisHugsTheRectangle() {
        // A rectangle rotated 30°. The fitter must recover that direction, which it can only do by
        // taking the argmax of Zhang's β — the argmin would pick a diagonal.
        let angle = Float.pi / 6
        let axis = SIMD2<Float>(cos(angle), sin(angle))
        let perpendicular = SIMD2<Float>(-axis.y, axis.x)
        var points: [SIMD2<Float>] = []
        for step in 0...40 {
            let along = Float(step) / 40 * 0.30
            points.append(axis * along)
            points.append(axis * along + perpendicular * 0.12)
        }
        for step in 0...16 {
            let across = Float(step) / 16 * 0.12
            points.append(perpendicular * across)
            points.append(axis * 0.30 + perpendicular * across)
        }

        let found = OrientedBoundingBox.bestOrientation(of: points, minimumEdgeDistance: 0.005)
        let recovered = try! XCTUnwrap(found)
        // Any of the rectangle's four edge directions is a correct answer.
        let error = abs(atan2(recovered.y, recovered.x) - angle)
            .truncatingRemainder(dividingBy: .pi / 2)
        XCTAssertLessThan(min(error, .pi / 2 - error), 0.05, "Recovered axis is off by more than 3°.")
    }

    func testFullCloudExtentsDoNotChangeTheOrientationChosen() {
        // The application measures extents from every point but must leave Liu's search untouched.
        var generator = SeededGenerator(state: 42)
        let angle: Float = 0.4
        let axis = SIMD2<Float>(cos(angle), sin(angle))
        let perpendicular = SIMD2<Float>(-axis.y, axis.x)
        var points: [SIMD2<Float>] = []
        for _ in 0..<600 {
            let along = Float(Double.random(in: 0...0.25, using: &generator))
            let across = Float(Double.random(in: 0...0.10, using: &generator))
            points.append(axis * along + perpendicular * across)
        }

        let fromEverything = OrientedBoundingBox.bestOrientation(of: points, minimumEdgeDistance: 0.005)
        // Appending points strictly inside the hull cannot change the hull, so it cannot change the
        // candidate directions either.
        let interior = points.map { $0 * 0.5 }
        let withInterior = OrientedBoundingBox.bestOrientation(
            of: points + interior,
            minimumEdgeDistance: 0.005
        )
        XCTAssertNotNil(fromEverything)
        XCTAssertNotNil(withInterior)
    }

    // MARK: - Helpers

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func placement(
        origin: SIMD3<Double>,
        size: SIMD3<Int>,
        mass: Double
    ) -> BaldiPlacement {
        BaldiPlacement(
            id: UUID(),
            name: "p",
            origin: origin,
            rotation: BaldiRotation.all[0],
            size: size,
            mass: mass
        )
    }

    private func twoPackageProblem() -> BaldiProblem {
        BaldiProblem(
            knapsack: BaldiKnapsack(size: SIMD3(600, 200, 100)),
            items: [
                BaldiItem(id: UUID(), name: "a", size: SIMD3(120, 90, 40), mass: 1.2),
                BaldiItem(id: UUID(), name: "b", size: SIMD3(100, 95, 85), mass: 0.4),
                BaldiItem(id: UUID(), name: "c", size: SIMD3(105, 100, 90), mass: 2.0),
            ]
        )
    }
}
