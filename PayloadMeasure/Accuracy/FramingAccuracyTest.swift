import CoreGraphics
import Foundation
import simd

// A controlled framing calibration: one object, measured at five apparent sizes. Unlike the normal
// accuracy test, every reading retains the independent variable that matters here — how much of the
// viewport the object actually occupied — plus camera distance when ARKit can supply it.

enum FramingCalibrationProtocol {
    /// Covers clearly too-small through close-to-clipping without asking the object to touch an edge.
    static let targetFillPercentages: [Double] = [20, 35, 50, 65, 80]
    static let allowedFillErrorPercentagePoints = 5.0

    /// Both the guide and this calculation use the shorter viewport dimension. This keeps the five
    /// physical squares square in portrait and landscape, instead of silently changing the protocol
    /// when the phone rotates.
    static func fillPercent(
        boundingBox: CGRect,
        viewportSize: CGSize
    ) -> Double? {
        guard viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0,
              boundingBox.width.isFinite,
              boundingBox.height.isFinite,
              boundingBox.width > 0,
              boundingBox.height > 0 else {
            return nil
        }
        let longestSideInPoints = max(
            boundingBox.width * viewportSize.width,
            boundingBox.height * viewportSize.height
        )
        return Double(longestSideInPoints / min(viewportSize.width, viewportSize.height) * 100)
    }
}

struct FramingViewportBox: Codable, Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var nearestEdgeMarginPercent: Double {
        min(min(x, y), min(1 - (x + width), 1 - (y + height))) * 100
    }
}

struct FramingAccuracyReading: Codable, Identifiable, Sendable {
    var id: UUID
    var round: Int
    var targetFillPercent: Double
    var actualFillPercent: Double
    var viewportBoundingBox: FramingViewportBox
    var viewportWidthPoints: Double
    var viewportHeightPoints: Double
    var cameraDistanceMillimetres: Double?
    var sizeMillimetres: [Double]
    var recordedAt: Date

    var sortedSizeMillimetres: [Double] { sizeMillimetres.sorted(by: >) }
    var fillErrorPercentagePoints: Double { actualFillPercent - targetFillPercent }
    var sizeText: String { AccuracyTestRun.sizeText(sizeMillimetres) }
}

struct FramingAccuracyFailure: Codable, Identifiable, Sendable {
    var id: UUID
    var round: Int
    var targetFillPercent: Double
    var reason: String
    var recordedAt: Date
}

struct FramingAccuracySlot: Sendable, Equatable {
    var round: Int
    var levelPosition: Int
    var targetFillPercent: Double
}

struct FramingAccuracyRun: Codable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var label: String
    var rounds: Int
    var workflowMode: MeasurementWorkflowMode
    var readings: [FramingAccuracyReading] = []
    var failures: [FramingAccuracyFailure] = []
    var referenceSizeMillimetres: [Double]? = nil

    var totalExpectedReadings: Int {
        max(rounds, 1) * FramingCalibrationProtocol.targetFillPercentages.count
    }

    var completedAttemptCount: Int { readings.count + failures.count }
    var isComplete: Bool { completedAttemptCount >= totalExpectedReadings }

    /// Alternating direction prevents every small-frame reading being taken before every large-frame
    /// reading. It is deterministic, so an exported protocol can still be reproduced exactly.
    var nextSlot: FramingAccuracySlot? {
        guard completedAttemptCount < totalExpectedReadings else { return nil }
        let levelCount = FramingCalibrationProtocol.targetFillPercentages.count
        let roundIndex = completedAttemptCount / levelCount
        let levelPosition = completedAttemptCount % levelCount
        let levels = roundIndex.isMultiple(of: 2)
            ? FramingCalibrationProtocol.targetFillPercentages
            : Array(FramingCalibrationProtocol.targetFillPercentages.reversed())
        return FramingAccuracySlot(
            round: roundIndex + 1,
            levelPosition: levelPosition + 1,
            targetFillPercent: levels[levelPosition]
        )
    }

    var referenceSize: [Double]? {
        guard let referenceSizeMillimetres,
              referenceSizeMillimetres.count == 3,
              referenceSizeMillimetres.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }
        return referenceSizeMillimetres
    }

    func readings(targetFillPercent: Double) -> [FramingAccuracyReading] {
        readings
            .filter { abs($0.targetFillPercent - targetFillPercent) < 0.001 }
            .sorted { $0.round < $1.round }
    }

    func failures(targetFillPercent: Double) -> [FramingAccuracyFailure] {
        failures
            .filter { abs($0.targetFillPercent - targetFillPercent) < 0.001 }
            .sorted { $0.round < $1.round }
    }
}

struct FramingLevelStatistics: Sendable {
    var targetFillPercent: Double
    var readings: [FramingAccuracyReading]
    var reference: [Double]

    var allErrors: [Double] {
        let sortedReference = reference.sorted(by: >)
        return readings.flatMap { reading in
            zip(reading.sortedSizeMillimetres, sortedReference).map { $0.0 - $0.1 }
        }
    }

    var bias: Double { AccuracyStatistics.mean(allErrors) }
    var meanAbsoluteError: Double { AccuracyStatistics.mean(allErrors.map(abs)) }
    var rootMeanSquareError: Double { AccuracyStatistics.rootMeanSquare(allErrors) }
    var maximumAbsoluteError: Double { allErrors.map(abs).max() ?? .nan }
    var meanActualFillPercent: Double {
        AccuracyStatistics.mean(readings.map(\.actualFillPercent))
    }
    var meanCameraDistanceMillimetres: Double {
        AccuracyStatistics.mean(readings.compactMap(\.cameraDistanceMillimetres))
    }
}

struct FramingAccuracySummary: Sendable {
    var levels: [FramingLevelStatistics]

    var allErrors: [Double] { levels.flatMap(\.allErrors) }
    var bias: Double { AccuracyStatistics.mean(allErrors) }
    var meanAbsoluteError: Double { AccuracyStatistics.mean(allErrors.map(abs)) }
    var rootMeanSquareError: Double { AccuracyStatistics.rootMeanSquare(allErrors) }
    var maximumAbsoluteError: Double { allErrors.map(abs).max() ?? .nan }
}

enum FramingAccuracyStatistics {
    static func summarise(_ run: FramingAccuracyRun) -> FramingAccuracySummary? {
        guard let reference = run.referenceSize else { return nil }
        let levels: [FramingLevelStatistics] = FramingCalibrationProtocol
            .targetFillPercentages.compactMap { target -> FramingLevelStatistics? in
            let readings = run.readings(targetFillPercent: target)
            guard !readings.isEmpty else { return nil }
            return FramingLevelStatistics(
                targetFillPercent: target,
                readings: readings,
                reference: reference
            )
        }
        guard !levels.isEmpty else { return nil }
        return FramingAccuracySummary(levels: levels)
    }
}

extension FramingAccuracyRun {
    var reportFileName: String {
        let safe = label
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let stamp = StudyRun.fileDateFormatter.string(from: createdAt)
        return "payloadmeasure-framing-accuracy-\(safe.isEmpty ? "test" : safe)-\(stamp).txt"
    }

    func reportText() -> String {
        var lines = [
            "PayloadMeasure framing accuracy test",
            "====================================",
            "Label     : \(label)",
            "Recorded  : \(StudyRun.displayDateFormatter.string(from: createdAt))",
            "Method    : \(workflowMode.title)",
            "Rounds    : \(rounds)",
            "Levels    : \(FramingCalibrationProtocol.targetFillPercentages.map { AccuracyTestRun.number($0) }.joined(separator: ", "))%",
            "Tolerance : ±\(AccuracyTestRun.number(FramingCalibrationProtocol.allowedFillErrorPercentagePoints)) percentage points",
            "Attempts  : \(completedAttemptCount) of \(totalExpectedReadings)",
            "Successful: \(readings.count)",
            "Failed    : \(failures.count)",
            "Test id   : \(id.uuidString)",
            "",
            "Target fill is the detected object's longest projected side divided by the",
            "shorter viewport dimension. Every reading starts from reset AR tracking.",
            ""
        ]

        if let referenceSize {
            lines.append("Reference : \(AccuracyTestRun.sizeText(referenceSize))")
        } else {
            lines.append("Reference : not entered")
        }
        lines.append("")

        for target in FramingCalibrationProtocol.targetFillPercentages {
            let targetReadings = readings(targetFillPercent: target)
            let targetFailures = failures(targetFillPercent: target)
            guard !targetReadings.isEmpty || !targetFailures.isEmpty else { continue }
            lines.append("-------------------------------------------------------------")
            lines.append("Target \(AccuracyTestRun.number(target))%")
            for reading in targetReadings {
                let distance = reading.cameraDistanceMillimetres.map {
                    AccuracyTestRun.number($0) + " mm"
                } ?? "unavailable"
                lines.append(
                    "  round \(reading.round): actual \(AccuracyTestRun.number(reading.actualFillPercent))%, distance \(distance), measured \(reading.sizeText)"
                )
                lines.append(
                    "    mask x \(AccuracyTestRun.number(reading.viewportBoundingBox.x * 100))%, y \(AccuracyTestRun.number(reading.viewportBoundingBox.y * 100))%, width \(AccuracyTestRun.number(reading.viewportBoundingBox.width * 100))%, height \(AccuracyTestRun.number(reading.viewportBoundingBox.height * 100))%, nearest edge \(AccuracyTestRun.number(reading.viewportBoundingBox.nearestEdgeMarginPercent))%"
                )
            }
            for failure in targetFailures {
                lines.append("  round \(failure.round): NO STABLE READING — \(failure.reason)")
            }
            if let summary = FramingAccuracyStatistics.summarise(self),
               let level = summary.levels.first(where: { $0.targetFillPercent == target }) {
                lines.append(
                    "  bias \(AccuracyTestRun.number(level.bias)) mm, MAE \(AccuracyTestRun.number(level.meanAbsoluteError)) mm, RMSE \(AccuracyTestRun.number(level.rootMeanSquareError)) mm, worst \(AccuracyTestRun.number(level.maximumAbsoluteError)) mm"
                )
            }
            lines.append("")
        }

        if let summary = FramingAccuracyStatistics.summarise(self) {
            lines.append("Overall")
            lines.append("-------")
            lines.append("Bias                : \(AccuracyTestRun.number(summary.bias)) mm")
            lines.append("Mean absolute error : \(AccuracyTestRun.number(summary.meanAbsoluteError)) mm")
            lines.append("RMSE                : \(AccuracyTestRun.number(summary.rootMeanSquareError)) mm")
            lines.append("Largest error       : \(AccuracyTestRun.number(summary.maximumAbsoluteError)) mm")
        } else {
            lines.append(referenceSize == nil
                ? "Enter the true size to calculate errors."
                : "No successful readings are available to compare.")
        }
        lines.append("")
        lines.append("No framing interval is selected automatically. Choose it against a declared")
        lines.append("accuracy requirement, then confirm it on different objects.")
        return lines.joined(separator: "\n")
    }
}
