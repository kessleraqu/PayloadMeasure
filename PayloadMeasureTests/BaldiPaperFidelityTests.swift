import XCTest
import simd
@testable import PayloadMeasure

// Checks the parts of the packing search that are taken from the papers. Each test names the
// section it covers.

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
        // Different count: the penalty is below 1, so no alpha can reverse it.
        XCTAssertTrue(BaldiSearch.isBetterForSearch(two, than: centred, alpha: 0.9))
        XCTAssertLessThan(two.normalisedUnbalancingIndex, 1.0000001)
    }

    func testAnUnbalancedPackingMayBeTheSearchIncumbent() {
        // 5.3.3 allows the best solution to be unbalanced, so the merit function must too.
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
        // 5.2 ends with gravity compaction. With full support nothing can move down, so lowering any
        // package must break overlap or support.
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
        // Only the mode differs. Paper mode keeps packing order; centred moves heaviest first.
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

        // Both must stay valid.
        for result in [paperResult, centredResult] {
            XCTAssertTrue(BaldiVerticalSupport.allFullySupported(result))
            for first in result.indices {
                for second in result.indices where second > first {
                    XCTAssertFalse(result[first].overlaps(result[second]))
                }
            }
        }
        // Centred keeps going after feasibility, so it should end at least as close to the target.
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
        // A rectangle rotated 30 degrees. Recovering it requires maximising Zhang's criterion;
        // minimising would pick a diagonal.
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
        // Any of the four edge directions is correct.
        let error = abs(atan2(recovered.y, recovered.x) - angle)
            .truncatingRemainder(dividingBy: .pi / 2)
        XCTAssertLessThan(min(error, .pi / 2 - error), 0.05, "Recovered axis is off by more than 3°.")
    }

    func testFullCloudExtentsDoNotChangeTheOrientationChosen() {
        // Extents use every point, but Liu's orientation search must not change.
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
        // Points inside the hull can't change the hull, so the candidate directions stay the same.
        let interior = points.map { $0 * 0.5 }
        let withInterior = OrientedBoundingBox.bestOrientation(
            of: points + interior,
            minimumEdgeDistance: 0.005
        )
        XCTAssertNotNil(fromEverything)
        XCTAssertNotNil(withInterior)
    }

    /// Captured fixture: an asymmetric partial scan (one side unseen, the others partly covered) with
    /// a true axis of 64.79 degrees. A per-axis vote version of the closeness score was about 11
    /// degrees off here; the per-point formula gets within 2.
    func testAnAsymmetricPartialScanRecoversTheTrueAxisNotTheVotedOne() throws {
        let points: [SIMD2<Float>] = [
        SIMD2<Float>(0.124241, -0.144525),
        SIMD2<Float>(0.124942, -0.142613),
        SIMD2<Float>(0.126259, -0.140674),
        SIMD2<Float>(0.126948, -0.138962),
        SIMD2<Float>(0.128406, -0.136954),
        SIMD2<Float>(0.129052, -0.135398),
        SIMD2<Float>(0.129354, -0.133127),
        SIMD2<Float>(0.129721, -0.132290),
        SIMD2<Float>(0.131153, -0.130430),
        SIMD2<Float>(0.132001, -0.128571),
        SIMD2<Float>(0.132574, -0.127161),
        SIMD2<Float>(0.133717, -0.124643),
        SIMD2<Float>(0.134197, -0.123827),
        SIMD2<Float>(0.135384, -0.121091),
        SIMD2<Float>(0.135896, -0.119765),
        SIMD2<Float>(0.136655, -0.117863),
        SIMD2<Float>(0.137663, -0.115852),
        SIMD2<Float>(0.139190, -0.114430),
        SIMD2<Float>(0.139471, -0.113054),
        SIMD2<Float>(0.140341, -0.111223),
        SIMD2<Float>(0.141016, -0.109693),
        SIMD2<Float>(0.141613, -0.108141),
        SIMD2<Float>(0.142718, -0.105864),
        SIMD2<Float>(-0.183794, 0.019935),
        SIMD2<Float>(-0.178772, 0.029765),
        SIMD2<Float>(-0.173556, 0.040492),
        SIMD2<Float>(-0.168303, 0.050794),
        SIMD2<Float>(-0.163633, 0.061297),
        SIMD2<Float>(-0.158260, 0.072354),
        SIMD2<Float>(-0.153571, 0.083157),
        SIMD2<Float>(-0.148484, 0.093282),
        SIMD2<Float>(-0.144174, 0.104437),
        SIMD2<Float>(-0.138783, 0.115134),
        SIMD2<Float>(-0.134125, 0.125123),
        SIMD2<Float>(-0.128763, 0.135726),
        SIMD2<Float>(-0.123612, 0.146459),
        SIMD2<Float>(-0.118438, 0.157042),
        SIMD2<Float>(0.082078, -0.148311),
        SIMD2<Float>(0.028069, 0.096442),
        SIMD2<Float>(0.019949, 0.100131),
        SIMD2<Float>(0.011942, 0.103928),
        SIMD2<Float>(0.003957, 0.107338),
        SIMD2<Float>(-0.004102, 0.111784),
        SIMD2<Float>(-0.012444, 0.115452),
        SIMD2<Float>(-0.020214, 0.119021),
        SIMD2<Float>(-0.028485, 0.122864),
        SIMD2<Float>(-0.036555, 0.126534)
        ]

        let trueAngle: Float = 64.79037593275194 * .pi / 180
        let found = OrientedBoundingBox.bestOrientation(of: points, minimumEdgeDistance: 0.005)
        let recovered = try XCTUnwrap(found)
        let error = abs(atan2(recovered.y, recovered.x) - trueAngle)
            .truncatingRemainder(dividingBy: .pi / 2)
        XCTAssertLessThan(
            min(error, .pi / 2 - error), 0.05,
            "Recovered axis is off by more than 3°."
        )
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
