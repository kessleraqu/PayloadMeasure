import XCTest
import simd
@testable import PayloadMeasure

@MainActor
final class PackingStoreComparisonTests: XCTestCase {
    func testStorePublishesPaperAndCentredResultsTogether() async {
        let store = PackingStore()
        store.baldiOptions.heuristic.timeLimitSeconds = 0.05
        let problem = BaldiTestFixtures.problem(
            items: [BaldiTestFixtures.item(size: SIMD3(10, 10, 10))],
            knapsack: BaldiTestFixtures.knapsack(size: SIMD3(30, 30, 30))
        )

        store.solveBaldi(problem: problem)
        await waitForBaldiSolve(in: store)

        guard let comparison = store.baldiComparison else {
            XCTFail("The two-mode solve did not publish a comparison.")
            return
        }
        XCTAssertEqual(comparison.paper.status, .feasible)
        XCTAssertEqual(comparison.centred.status, .feasible)
        XCTAssertEqual(comparison.result(for: .paper).status, comparison.paper.status)
        XCTAssertEqual(comparison.result(for: .centred).status, comparison.centred.status)
        XCTAssertFalse(store.isBaldiStale(for: problem))

        if let paper = comparison.paper.solution,
           let centred = comparison.centred.solution {
            XCTAssertEqual(paper.loadedCount, centred.loadedCount)
            XCTAssertLessThanOrEqual(
                centred.centreOfMassDistanceToIdeal,
                paper.centreOfMassDistanceToIdeal + 1e-9
            )
        } else {
            XCTFail("A feasible comparison must contain both solutions.")
        }
    }

    func testCancelledComparisonCannotPublishLate() async {
        let store = PackingStore()
        store.baldiOptions.heuristic.timeLimitSeconds = 0.1
        let items = (0..<20).map { index in
            BaldiTestFixtures.item(
                name: "Package \(index)",
                size: SIMD3(10 + index % 3, 10 + index % 4, 10 + index % 5)
            )
        }
        let problem = BaldiTestFixtures.problem(
            items: items,
            knapsack: BaldiTestFixtures.knapsack(size: SIMD3(60, 60, 60))
        )

        store.solveBaldi(problem: problem)
        XCTAssertTrue(store.isSolving)
        store.cancel()

        XCTAssertFalse(store.isSolving)
        XCTAssertNil(store.baldiComparison)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(
            store.baldiComparison,
            "A cancelled comparison generation must not overwrite store state."
        )
    }

    func testComparisonSignatureIncludesBothModesAndInvalidatesOnInputChange() async {
        let store = PackingStore()
        store.baldiOptions.heuristic.timeLimitSeconds = 0.05
        let item = BaldiTestFixtures.item(size: SIMD3(10, 10, 10), mass: 1)
        let problem = BaldiTestFixtures.problem(items: [item])
        let signature = store.baldiSignature(for: problem)

        XCTAssertTrue(signature.contains("v3-paper-stop-and-centred"))
        XCTAssertTrue(signature.contains("paper-stop"))
        XCTAssertTrue(signature.contains("dual-mode"))

        store.solveBaldi(problem: problem)
        await waitForBaldiSolve(in: store)
        XCTAssertNotNil(store.baldiComparison)

        var changed = problem
        changed.items[0].mass = 2
        XCTAssertTrue(store.isBaldiStale(for: changed))
        XCTAssertNotEqual(signature, store.baldiSignature(for: changed))
    }

    private func waitForBaldiSolve(
        in store: PackingStore,
        timeout: Duration = .seconds(2)
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while store.isSolving, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.isSolving, "The comparison solve exceeded the test timeout.")
    }
}
