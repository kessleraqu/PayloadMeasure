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

    func testAZeroBudgetDrawsNothingRatherThanCrashing() {
        XCTAssertTrue(subset(Array(0..<10), limit: 0).isEmpty)
    }
}
