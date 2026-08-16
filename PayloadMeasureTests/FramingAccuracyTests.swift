import CoreGraphics
import XCTest
import simd
@testable import PayloadMeasure

@MainActor
final class FramingAccuracyTests: XCTestCase {
    func testFillUsesLongestProjectedSideAgainstShorterViewportDimension() throws {
        let portrait = try XCTUnwrap(
            FramingCalibrationProtocol.fillPercent(
                boundingBox: CGRect(x: 0.25, y: 0.4, width: 0.5, height: 0.1),
                viewportSize: CGSize(width: 400, height: 800)
            )
        )
        XCTAssertEqual(portrait, 50, accuracy: 1e-9)

        let landscape = try XCTUnwrap(
            FramingCalibrationProtocol.fillPercent(
                boundingBox: CGRect(x: 0.4, y: 0.25, width: 0.1, height: 0.5),
                viewportSize: CGSize(width: 800, height: 400)
            )
        )
        XCTAssertEqual(landscape, 50, accuracy: 1e-9)
    }

    func testRoundsAlternateDirectionToReduceOrderBias() {
        var run = FramingAccuracyRun(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            label: "sequence",
            rounds: 2,
            workflowMode: .top
        )
        var targets: [Double] = []
        while let slot = run.nextSlot {
            targets.append(slot.targetFillPercent)
            run.readings.append(reading(round: slot.round, target: slot.targetFillPercent))
        }
        XCTAssertEqual(targets, [20, 35, 50, 65, 80, 80, 65, 50, 35, 20])
        XCTAssertTrue(run.isComplete)
    }

    func testStoreRejectsAMislabeledFillAndRetainsCalibrationMetadata() throws {
        let store = FramingAccuracyStore()
        store.startTest(label: "metadata", rounds: 1, workflowMode: .top)

        XCTAssertFalse(
            store.record(
                sizeMillimetres: SIMD3(100, 50, 25),
                viewportBoundingBox: CGRect(x: 0.25, y: 0.4, width: 0.5, height: 0.1),
                viewportSize: CGSize(width: 400, height: 800),
                cameraDistanceMetres: 0.75
            ),
            "The first 20% slot must not accept an actual 50% reading."
        )

        XCTAssertTrue(
            store.record(
                sizeMillimetres: SIMD3(100, 50, 25),
                viewportBoundingBox: CGRect(x: 0.4, y: 0.45, width: 0.2, height: 0.05),
                viewportSize: CGSize(width: 400, height: 800),
                cameraDistanceMetres: 0.75
            )
        )
        let saved = try XCTUnwrap(store.activeTest?.readings.first)
        XCTAssertEqual(saved.targetFillPercent, 20, accuracy: 1e-9)
        XCTAssertEqual(saved.actualFillPercent, 20, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(saved.cameraDistanceMillimetres), 750, accuracy: 1e-9)
        XCTAssertEqual(saved.viewportBoundingBox.width, 0.2, accuracy: 1e-9)
    }

    func testFailedMeasurementAdvancesAndCanBeUndone() {
        let store = FramingAccuracyStore()
        store.startTest(label: "failure", rounds: 1, workflowMode: .top)
        XCTAssertTrue(store.recordFailure(reason: "No stable fit"))
        XCTAssertEqual(store.activeTest?.failures.count, 1)
        XCTAssertEqual(store.nextSlot?.targetFillPercent, 35)

        store.undoLastReading()
        XCTAssertEqual(store.activeTest?.failures.count, 0)
        XCTAssertEqual(store.nextSlot?.targetFillPercent, 20)
    }

    func testPerLevelErrorsCompareSortedSides() throws {
        var run = FramingAccuracyRun(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            label: "statistics",
            rounds: 2,
            workflowMode: .top,
            referenceSizeMillimetres: [100, 50, 25]
        )
        var first = reading(round: 1, target: 20)
        first.sizeMillimetres = [101, 51, 26]
        var second = reading(round: 2, target: 20)
        second.sizeMillimetres = [24, 49, 99]
        run.readings = [first, second]

        let level = try XCTUnwrap(FramingAccuracyStatistics.summarise(run)?.levels.first)
        XCTAssertEqual(level.bias, 0, accuracy: 1e-9)
        XCTAssertEqual(level.meanAbsoluteError, 1, accuracy: 1e-9)
        XCTAssertEqual(level.rootMeanSquareError, 1, accuracy: 1e-9)
        XCTAssertEqual(level.maximumAbsoluteError, 1, accuracy: 1e-9)
    }

    func testReportIncludesActualFillDistanceAndNoAutomaticThresholdClaim() {
        var run = FramingAccuracyRun(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            label: "report",
            rounds: 1,
            workflowMode: .top,
            referenceSizeMillimetres: [100, 50, 25]
        )
        run.readings = [reading(round: 1, target: 20)]
        let report = run.reportText()
        XCTAssertTrue(report.contains("actual 20.00%"))
        XCTAssertTrue(report.contains("distance 750.00 mm"))
        XCTAssertTrue(report.contains("No framing interval is selected automatically"))
    }

    private func reading(round: Int, target: Double) -> FramingAccuracyReading {
        FramingAccuracyReading(
            id: UUID(),
            round: round,
            targetFillPercent: target,
            actualFillPercent: target,
            viewportBoundingBox: FramingViewportBox(
                CGRect(x: 0.4, y: 0.45, width: target / 100, height: 0.05)
            ),
            viewportWidthPoints: 400,
            viewportHeightPoints: 800,
            cameraDistanceMillimetres: 750,
            sizeMillimetres: [100, 50, 25],
            recordedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
