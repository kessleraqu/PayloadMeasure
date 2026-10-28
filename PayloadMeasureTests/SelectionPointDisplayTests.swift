import XCTest
@testable import PayloadMeasure

// Point display selection: a drawn dot stays drawn as the cloud grows, and a dropped dot never
// comes back. The old every-k-th stride is included for comparison.

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

    /// A dropped point never comes back as the cloud grows.
    func testAPointThatDropsOutNeverComesBack() {
        var everDropped: Set<Int> = []
        var previous = Set(subset(Array(0..<700), limit: 600))

        // The cloud grows like a real one: same points plus new ones.
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

    /// Array order doesn't affect which points are drawn.
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

    /// For comparison, the old stride changes the whole display as the cloud grows.
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

    /// The drawn points should be spread evenly over a face, not in stripes. Without the splitmix
    /// finaliser the low hash bits follow the voxel key and whole rows come out empty. Measured as
    /// density per row, column and diagonal against a binomial: row sd was 7.5 before the fix and
    /// 2.6 after, against an expected 2.65.
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
        // Twice the binomial sd: above normal noise, well below the 2.8x of the unmixed hash.
        let limit = 2 * binomial

        let rows = drawn.map { $0.count { $0 } }
        let columns = (0..<side).map { z in drawn.count { $0[z] } }
        let diagonals = (0..<side).map { offset in
            (0..<side).count { x in drawn[x][(x + offset) % side] }
        }

        XCTAssertLessThan(standardDeviation(rows), limit, "Banding along the rows of the face.")
        XCTAssertLessThan(standardDeviation(columns), limit, "Banding along the columns.")
        XCTAssertLessThan(standardDeviation(diagonals), limit, "Banding along the diagonals.")

        // The budget should be roughly met, not biased low.
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

    func testRenderedCloudKeepsEveryCoordinateExtremeThatCanDefineItsBox() {
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(1_006)
        for index in 0..<1_000 {
            let x = Float(index % 10) / 1_000
            let y = Float((index / 10) % 10) / 1_000
            let z = Float((index / 100) % 10) / 1_000
            points.append(SIMD3<Float>(x, y, z))
        }
        let extremes = [
            SIMD3<Float>(-1, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, -1, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, -1),
            SIMD3<Float>(0, 0, 1)
        ]
        points.append(contentsOf: extremes)

        let drawn = SelectionPointDisplay.subsetPreservingCoordinateExtrema(
            points,
            limit: 20
        ) { point in
            SelectionPointDisplay.hash(
                x: Int32((point.x * 1_000).rounded()),
                y: Int32((point.y * 1_000).rounded()),
                z: Int32((point.z * 1_000).rounded())
            )
        }

        XCTAssertLessThanOrEqual(drawn.count, 20)
        for extreme in extremes {
            XCTAssertTrue(drawn.contains(extreme), "The rendered cloud dropped extreme \(extreme).")
        }
    }
}
