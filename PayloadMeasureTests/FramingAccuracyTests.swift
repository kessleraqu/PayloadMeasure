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

    func testGuideIsASquareBasedOnTheShorterViewportDimension() throws {
        let viewport = CGSize(width: 400, height: 800)
        let guide = try XCTUnwrap(
            FramingCalibrationProtocol.guideRect(
                targetFillPercent: 25,
                viewportSize: viewport
            )
        )
        XCTAssertEqual(guide, CGRect(x: 0.375, y: 0.4375, width: 0.25, height: 0.125))
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

    func testNewTestsMeasureEverySizeOncePerObject() {
        let store = FramingAccuracyStore()
        store.startTest(label: "objects", objectCount: 2, workflowMode: .top)
        var run = try! XCTUnwrap(store.activeTest)
        XCTAssertEqual(run.resolvedTargetFillPercentages, [25, 30, 38, 53, 65])
        var slots: [(Int, Double)] = []
        while let slot = run.nextSlot {
            slots.append((slot.round, slot.targetFillPercent))
            run.readings.append(reading(round: slot.round, target: slot.targetFillPercent))
        }
        XCTAssertEqual(slots.map(\.0), [1, 1, 1, 1, 1, 2, 2, 2, 2, 2])
        XCTAssertEqual(slots.map(\.1), [25, 30, 38, 53, 65, 25, 30, 38, 53, 65])
    }

    func testExistingRunsKeepTheirRecordedFramingSchedule() {
        let previousSchedule = [32.0, 41.0, 50.0, 60.0, 70.0]
        let run = FramingAccuracyRun(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            label: "previous protocol",
            rounds: 1,
            workflowMode: .top,
            objectCount: 1,
            protocolFillPercentages: previousSchedule
        )

        XCTAssertEqual(run.resolvedTargetFillPercentages, previousSchedule)
        XCTAssertEqual(run.nextSlot?.targetFillPercent, 32)
    }

    func testStoreAcceptsReadingOutsideGuideAndRetainsCalibrationMetadata() throws {
        let store = FramingAccuracyStore()
        store.startTest(label: "metadata", objectCount: 1, workflowMode: .top)

        XCTAssertTrue(
            store.record(
                sizeMillimetres: SIMD3(100, 50, 25),
                viewportBoundingBox: CGRect(x: 0.25, y: 0.4, width: 0.5, height: 0.1),
                viewportSize: CGSize(width: 400, height: 800),
                cameraDistanceMetres: 0.75
            ),
            "Guide containment is operator-controlled and must not reject a reading."
        )
        let saved = try XCTUnwrap(store.activeTest?.readings.first)
        XCTAssertEqual(saved.targetFillPercent, 25, accuracy: 1e-9)
        XCTAssertEqual(saved.actualFillPercent, 50, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(saved.cameraDistanceMillimetres), 750, accuracy: 1e-9)
        XCTAssertEqual(saved.viewportBoundingBox.width, 0.5, accuracy: 1e-9)
    }

    func testFailedMeasurementAdvancesAndCanBeUndone() {
        let store = FramingAccuracyStore()
        store.startTest(label: "failure", objectCount: 1, workflowMode: .top)
        XCTAssertTrue(store.recordFailure(reason: "No stable fit"))
        XCTAssertEqual(store.activeTest?.failures.count, 1)
        XCTAssertEqual(store.nextSlot?.targetFillPercent, 30)

        store.undoLastReading()
        XCTAssertEqual(store.activeTest?.failures.count, 0)
        XCTAssertEqual(store.nextSlot?.targetFillPercent, 25)
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

    func testObjectProtocolUsesEachObjectsOwnReferenceSize() throws {
        var run = FramingAccuracyRun(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 0),
            label: "object references",
            rounds: 2,
            workflowMode: .top,
            objectCount: 2,
            protocolFillPercentages: FramingCalibrationProtocol.targetFillPercentages,
            objectReferenceSizesMillimetres: [
                1: [100, 50, 25],
                2: [200, 80, 40]
            ]
        )
        var first = reading(round: 1, target: 25)
        first.sizeMillimetres = [101, 51, 26]
        var second = reading(round: 2, target: 25)
        second.sizeMillimetres = [199, 79, 39]
        run.readings = [first, second]

        let level = try XCTUnwrap(FramingAccuracyStatistics.summarise(run)?.levels.first)
        XCTAssertEqual(level.bias, 0, accuracy: 1e-9)
        XCTAssertEqual(level.meanAbsoluteError, 1, accuracy: 1e-9)
        XCTAssertEqual(level.rootMeanSquareError, 1, accuracy: 1e-9)
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
