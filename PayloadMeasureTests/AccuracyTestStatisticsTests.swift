import XCTest
import simd
@testable import PayloadMeasure

// The accuracy test's arithmetic, against figures worked out by hand.
//
// The two things worth guarding are the order the readings are asked for — object 1…X, then round
// again — and the sorted axis matching, which is what stops an object being turned between rounds
// from showing up as an error.

@MainActor
final class AccuracyTestStatisticsTests: XCTestCase {
    private func run(
        objectCount: Int,
        passes: Int,
        readings: [(object: Int, pass: Int, size: [Double])],
        references: [Int: [Double]]
    ) -> AccuracyTestRun {
        var test = AccuracyTestRun(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            label: "test",
            objectCount: objectCount,
            passes: passes
        )
        test.readings = readings.map {
            AccuracyReading(
                id: UUID(),
                objectNumber: $0.object,
                pass: $0.pass,
                sizeMillimetres: $0.size,
                recordedAt: Date(timeIntervalSince1970: 0)
            )
        }
        for (number, size) in references {
            test.referenceSizesMillimetres["\(number)"] = size
        }
        return test
    }

    // MARK: - Order

    func testReadingsAreAskedForObjectByObjectThenRoundAgain() {
        var test = run(objectCount: 3, passes: 2, readings: [], references: [:])
        var order: [(Int, Int)] = []
        while let slot = test.nextSlot {
            order.append((slot.objectNumber, slot.pass))
            test.readings.append(
                AccuracyReading(
                    id: UUID(),
                    objectNumber: slot.objectNumber,
                    pass: slot.pass,
                    sizeMillimetres: [1, 1, 1],
                    recordedAt: Date(timeIntervalSince1970: 0)
                )
            )
        }

        XCTAssertEqual(
            order.map { "\($0.0)/\($0.1)" },
            ["1/1", "2/1", "3/1", "1/2", "2/2", "3/2"],
            "Every object once per round, in the same order, then round again."
        )
        XCTAssertTrue(test.isComplete)
        XCTAssertNil(test.nextSlot, "A full test asks for nothing more.")
    }

    // MARK: - Per-axis figures

    /// Reference 100 × 50 × 25, measured 1 mm over then 1 mm under on every side.
    /// Per axis: mean = reference, bias 0, sd = √(2/1) = 1.4142, MAE 1, RMSE 1, r = 2.8 · sd.
    func testPerAxisFiguresMatchHandCalculation() throws {
        let test = run(
            objectCount: 1,
            passes: 2,
            readings: [
                (1, 1, [101, 51, 26]),
                (1, 2, [99, 49, 24])
            ],
            references: [1: [100, 50, 25]]
        )
        let summary = AccuracyStatistics.summarise(test)
        let object = try XCTUnwrap(summary.objects.first)
        XCTAssertEqual(object.axes.count, 3)

        for axis in object.axes {
            XCTAssertEqual(axis.count, 2)
            XCTAssertEqual(axis.mean, axis.reference, accuracy: 1e-9)
            XCTAssertEqual(axis.bias, 0, accuracy: 1e-9)
            XCTAssertEqual(axis.standardDeviation, 2.0.squareRoot(), accuracy: 1e-9)
            XCTAssertEqual(axis.meanAbsoluteError, 1, accuracy: 1e-9)
            XCTAssertEqual(axis.rootMeanSquareError, 1, accuracy: 1e-9)
            XCTAssertEqual(axis.maximumAbsoluteError, 1, accuracy: 1e-9)
            XCTAssertEqual(axis.repeatabilityLimit, 2.8 * 2.0.squareRoot(), accuracy: 1e-9)
        }

        // Longest side first, whatever order the reference was typed in.
        XCTAssertEqual(object.axes.map(\.reference), [100, 50, 25])
        XCTAssertEqual(object.bias, 0, accuracy: 1e-9)
        XCTAssertEqual(object.rootMeanSquareError, 1, accuracy: 1e-9)
    }

    /// A steady 2 mm over-read: bias 2, no scatter, RMSE equal to the bias.
    func testSystematicOverReadingShowsAsBiasWithNoScatter() throws {
        let test = run(
            objectCount: 1,
            passes: 3,
            readings: [
                (1, 1, [102, 52, 27]),
                (1, 2, [102, 52, 27]),
                (1, 3, [102, 52, 27])
            ],
            references: [1: [100, 50, 25]]
        )
        let object = try XCTUnwrap(AccuracyStatistics.summarise(test).objects.first)
        for axis in object.axes {
            XCTAssertEqual(axis.bias, 2, accuracy: 1e-9)
            XCTAssertEqual(axis.standardDeviation, 0, accuracy: 1e-9)
            XCTAssertEqual(axis.rootMeanSquareError, 2, accuracy: 1e-9)
        }
        XCTAssertEqual(object.axes[0].relativeBiasPercent, 2, accuracy: 1e-9)
        XCTAssertEqual(object.axes[1].relativeBiasPercent, 4, accuracy: 1e-9)
    }

    /// The reason sides are sorted: the same object measured from a different side is not an error.
    func testTurningTheObjectBetweenRoundsIsNotAnError() throws {
        let test = run(
            objectCount: 1,
            passes: 3,
            readings: [
                (1, 1, [100, 50, 25]),
                (1, 2, [25, 100, 50]),
                (1, 3, [50, 25, 100])
            ],
            references: [1: [25, 100, 50]]
        )
        let summary = AccuracyStatistics.summarise(test)
        XCTAssertEqual(summary.rootMeanSquareError, 0, accuracy: 1e-9)
        XCTAssertEqual(summary.maximumAbsoluteError, 0, accuracy: 1e-9)
        XCTAssertEqual(summary.bias, 0, accuracy: 1e-9)
    }

    // MARK: - Overall figures

    func testLimitsOfAgreementFollowBiasAndErrorSpread() {
        let test = run(
            objectCount: 1,
            passes: 2,
            readings: [
                (1, 1, [103, 53, 28]),
                (1, 2, [101, 51, 26])
            ],
            references: [1: [100, 50, 25]]
        )
        let summary = AccuracyStatistics.summarise(test)
        // Six errors, three of +3 and three of +1: mean 2, sd √(6/5) = 1.0954.
        XCTAssertEqual(summary.readingCount, 2, "Two whole measurements.")
        XCTAssertEqual(
            summary.comparisonCount,
            6,
            "Three side lengths per reading, and that is the n behind the spread."
        )
        XCTAssertEqual(summary.bias, 2, accuracy: 1e-9)
        XCTAssertEqual(summary.errorStandardDeviation, (6.0 / 5.0).squareRoot(), accuracy: 1e-9)
        XCTAssertEqual(summary.meanAbsoluteError, 2, accuracy: 1e-9)

        let spread = 1.96 * (6.0 / 5.0).squareRoot()
        XCTAssertEqual(summary.limitsOfAgreement.lower, 2 - spread, accuracy: 1e-9)
        XCTAssertEqual(summary.limitsOfAgreement.upper, 2 + spread, accuracy: 1e-9)
    }

    func testObjectsWithoutAReferenceOrWithoutReadingsAreLeftOut() {
        let test = run(
            objectCount: 3,
            passes: 1,
            readings: [
                (1, 1, [100, 50, 25]),
                (2, 1, [100, 50, 25])
            ],
            references: [1: [100, 50, 25], 3: [10, 10, 10]]
        )
        let summary = AccuracyStatistics.summarise(test)
        XCTAssertEqual(
            summary.objects.map(\.objectNumber),
            [1],
            "Object 2 has no reference and object 3 has no readings; neither may be reported as perfect."
        )
        XCTAssertFalse(test.hasEveryReference)
    }

    func testASingleReadingHasNoStandardDeviationRatherThanZero() throws {
        let test = run(
            objectCount: 1,
            passes: 1,
            readings: [(1, 1, [100, 50, 25])],
            references: [1: [100, 50, 25]]
        )
        let object = try XCTUnwrap(AccuracyStatistics.summarise(test).objects.first)
        for axis in object.axes {
            XCTAssertFalse(
                axis.standardDeviation.isFinite,
                "One reading cannot show repeatability, and must not claim perfect precision."
            )
            XCTAssertFalse(axis.meanConfidenceHalfWidth.isFinite)
        }
    }

    func testReportCarriesTheHeadlineFigures() {
        let test = run(
            objectCount: 1,
            passes: 2,
            readings: [(1, 1, [101, 51, 26]), (1, 2, [99, 49, 24])],
            references: [1: [100, 50, 25]]
        )
        let report = test.reportText()
        for expected in ["Bias (trueness)", "RMSE", "limits of agreement", "repeatability"] {
            XCTAssertTrue(report.contains(expected), "The report is missing \(expected).")
        }
        XCTAssertTrue(report.contains("pass 1: 101.0 × 51.0 × 26.0 mm"), "Raw readings are kept as measured.")
    }

    // MARK: - Store

    func testStoreFillsSlotsInOrderRefusesExtrasAndCanUndo() {
        let store = AccuracyStore()
        store.startTest(label: "unit", objectCount: 2, passes: 2)

        XCTAssertEqual(store.nextSlot?.objectNumber, 1)
        XCTAssertEqual(store.nextSlot?.pass, 1)

        XCTAssertTrue(store.record(sizeMillimetres: SIMD3(10, 20, 30)))
        XCTAssertEqual(store.nextSlot?.objectNumber, 2, "The next reading is the next object.")
        XCTAssertTrue(store.record(sizeMillimetres: SIMD3(10, 20, 30)))
        XCTAssertEqual(store.nextSlot?.pass, 2, "After the last object the round starts again.")

        XCTAssertTrue(store.record(sizeMillimetres: SIMD3(10, 20, 30)))
        XCTAssertTrue(store.record(sizeMillimetres: SIMD3(10, 20, 30)))
        XCTAssertNil(store.nextSlot)
        XCTAssertFalse(
            store.record(sizeMillimetres: SIMD3(10, 20, 30)),
            "A full test must not take a fifth reading."
        )
        XCTAssertEqual(store.activeTest?.readings.count, 4)

        store.undoLastReading()
        XCTAssertEqual(store.activeTest?.readings.count, 3)
        XCTAssertEqual(store.nextSlot?.objectNumber, 2, "Undo puts the test back where it was.")

        XCTAssertFalse(
            store.record(sizeMillimetres: SIMD3(0, 20, 30)),
            "A zero side is not a measurement."
        )
    }

    func testLeavingAndReopeningKeepsTheTest() {
        let store = AccuracyStore()
        store.startTest(label: "resumable", objectCount: 1, passes: 3)
        XCTAssertTrue(store.record(sizeMillimetres: SIMD3(10, 20, 30)))
        let id = store.activeTest?.id

        store.closeActiveTest()
        XCTAssertNil(store.activeTest, "Going back to the main page clears the screen.")

        let saved = store.saved.first { $0.id == id }
        XCTAssertEqual(saved?.readings.count, 1, "The reading is kept even though the test is unfinished.")
        store.resume(try! XCTUnwrap(saved))
        XCTAssertEqual(store.nextSlot?.pass, 2, "It picks up where it left off.")
    }
}
