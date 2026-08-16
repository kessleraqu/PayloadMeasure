import XCTest
@testable import PayloadMeasure

// The cyan dots looked like they were being scattered at random. They were not: the cloud is
// accumulated and deterministic, but the display took every k-th point of it, and k changes every
// time the cloud grows — so the whole drawn subset changed several times a second.
//
// What matters is that a dot which is being drawn keeps being drawn, and that one which has dropped
// out does not come back. These tests hold the new selection to that, and show that the stride it
// replaced fails it.

final class SelectionPointDisplayTests: XCTestCase {
    private func hash(_ value: Int) -> UInt64 {
        SelectionPointDisplay.hash(x: Int32(value), y: 0, z: 0)
    }

    private func subset(_ items: [Int], limit: Int) -> [Int] {
        SelectionPointDisplay.subset(items, limit: limit, hash: hash)
    }

    func testEverythingIsDrawnWhileTheCloudFitsInTheBudget() {
        let points = Array(0..<50)
        XCTAssertEqual(subset(points, limit: 600), points)
    }

    func testTheBudgetIsNeverExceeded() {
        for count in [601, 1_000, 4_000, 8_000] {
            let drawn = subset(Array(0..<count), limit: 600)
            XCTAssertLessThanOrEqual(drawn.count, 600, "\(count) points overflowed the budget.")
            XCTAssertFalse(drawn.isEmpty, "\(count) points drew nothing at all.")
        }
    }

    /// The property the old stride broke: growth must not bring a dropped point back.
    func testAPointThatDropsOutNeverComesBack() {
        var everDropped: Set<Int> = []
        var previous = Set(subset(Array(0..<700), limit: 600))

        // The cloud fills in the way a real one does: the same points, plus new ones.
        for count in stride(from: 800, through: 8_000, by: 200) {
            let drawn = Set(subset(Array(0..<count), limit: 600))
            everDropped.formUnion(previous.subtracting(drawn))
            let returned = drawn.intersection(everDropped)
            XCTAssertTrue(
                returned.isEmpty,
                "At \(count) points, \(returned.count) dots that had already dropped out came back."
            )
            previous = drawn
        }
    }

    /// Selection depends on the point, not on where it sits in the array, so the order the cloud
    /// happens to arrive in cannot change what is on screen.
    func testOrderOfTheCloudDoesNotChangeWhatIsDrawn() {
        let points = Array(0..<2_000)
        let forwards = Set(subset(points, limit: 600))
        let backwards = Set(subset(points.reversed(), limit: 600))
        let shuffled = Set(subset(points.sorted { hash($0) < hash($1) }, limit: 600))

        XCTAssertEqual(forwards, backwards)
        XCTAssertEqual(forwards, shuffled)
    }

    func testTheSameCloudAlwaysDrawsTheSameDots() {
        let points = Array(0..<3_000)
        XCTAssertEqual(subset(points, limit: 600), subset(points, limit: 600))
    }

    /// For contrast: the stride this replaced churns the whole display as the cloud grows. Without
    /// this, the fix above looks like an arbitrary preference rather than a repair.
    func testTheOldStrideChurnedTheDisplay() {
        func stride(_ items: [Int], limit: Int) -> [Int] {
            guard items.count > limit else { return items }
            let step = Double(items.count) / Double(limit)
            return (0..<limit).map { items[min(Int(Double($0) * step), items.count - 1)] }
        }

        let before = Set(stride(Array(0..<700), limit: 600))
        let after = Set(stride(Array(0..<900), limit: 600))
        let churn = before.subtracting(after).count
        XCTAssertGreaterThan(
            churn,
            100,
            "The stride is being blamed for churn it does not cause; recheck the diagnosis."
        )
    }

    /// The dots came out in stripes, and this is the shape of that fault.
    ///
    /// FNV ends on a multiply, so the low bits of the hash are a near-linear function of the low bits of
    /// the voxel key. Taking the remainder modulo a power of two therefore made "is this point drawn" a
    /// periodic function of position — across a flat face, whole rows of voxels came out drawn and whole
    /// rows came out empty.
    ///
    /// So what is measured is the density per row, per column and per diagonal of one face, against what
    /// independent coin flips would give. A 1-D walk was tried first and is useless here: the unmixed
    /// hash scores *better* than chance on neighbour agreement while still banding badly, so that test
    /// passed on the broken hash. Measured over a face, the two are unmistakable — row sd 7.5 before the
    /// avalanche step, 2.6 after, against a binomial 2.65.
    func testDrawnPointsAreEvenlySpreadAcrossAFaceRatherThanBanded() {
        let side = 64
        let keepOneIn = 8
        let threshold = SelectionPointDisplay.scale / UInt64(keepOneIn)
        let drawn = (0..<side).map { x in
            (0..<side).map { z in
                SelectionPointDisplay.hash(x: Int32(x), y: 5, z: Int32(z))
                    % SelectionPointDisplay.scale < threshold
            }
        }

        func standardDeviation(_ counts: [Int]) -> Double {
            let mean = Double(counts.reduce(0, +)) / Double(counts.count)
            let variance = counts.reduce(0.0) { $0 + pow(Double($1) - mean, 2) }
                / Double(counts.count)
            return variance.squareRoot()
        }

        let share = 1.0 / Double(keepOneIn)
        let binomial = (Double(side) * share * (1 - share)).squareRoot()
        // Twice binomial: comfortably above the noise of an even spread, far below the 2.8× the
        // unmixed hash produced.
        let limit = 2 * binomial

        let rows = drawn.map { $0.count { $0 } }
        let columns = (0..<side).map { z in drawn.count { $0[z] } }
        let diagonals = (0..<side).map { offset in
            (0..<side).count { x in drawn[x][(x + offset) % side] }
        }

        XCTAssertLessThan(standardDeviation(rows), limit, "Banding along the rows of the face.")
        XCTAssertLessThan(standardDeviation(columns), limit, "Banding along the columns.")
        XCTAssertLessThan(standardDeviation(diagonals), limit, "Banding along the diagonals.")

        // And the budget has to be roughly honoured, not quietly biased low as the unmixed hash was.
        let total = rows.reduce(0, +)
        XCTAssertEqual(
            Double(total),
            Double(side * side) * share,
            accuracy: Double(side * side) * share * 0.25
        )
    }

    func testAZeroBudgetDrawsNothingRatherThanCrashing() {
        XCTAssertTrue(subset(Array(0..<10), limit: 0).isEmpty)
    }
}
