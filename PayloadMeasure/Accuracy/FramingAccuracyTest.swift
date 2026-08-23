import CoreGraphics
import Foundation
import simd

// A controlled framing calibration: each object is measured once at five apparent sizes. Unlike the normal
// accuracy test, every reading retains the independent variable that matters here — how much of the
// viewport the object actually occupied — plus camera distance when ARKit can supply it.

enum FramingCalibrationProtocol {
    /// Screen-occupancy targets calibrated from the previous run's observed fill/distance pairs.
    /// They predict approximately 650, 550, 450, 350 and 300 mm for the same objects. Distance is
    /// deliberately not an admission criterion; it remains an observed result of following these
    /// five progressively larger guides. Older saved tests retain their stored schedule through
    /// `FramingAccuracyRun.protocolFillPercentages`.
    static let targetFillPercentages: [Double] = [25, 30, 38, 53, 65]
    static let legacyTargetFillPercentages: [Double] = [20, 35, 50, 65, 80]

    /// Where following those five guides actually put the phone, for the objects the study used, in the
    /// same order as the levels above. An *observed result* and not a controlled variable — which is why
    /// every threshold in `MeasurementFramingRule` is stated in fill and none of them in millimetres.
    ///
    /// It is written down rather than left in prose because one thing genuinely is decided on it: the
    /// distance an operator is told to stand at before there is any mask on screen to compute a fill
    /// from. `MeasurementFramingRuleTests` checks that recommendation against these numbers.
    static let observedDistanceMillimetres: [Double] = [650, 550, 450, 350, 300]

    /// The on-screen guide is a physical square even when the renderer is rectangular. Returning it
    /// in renderer-normalized coordinates lets the live mask and the visible guide use one test.
    static func guideRect(
        targetFillPercent: Double,
        viewportSize: CGSize
    ) -> CGRect? {
        guard targetFillPercent.isFinite,
              targetFillPercent > 0,
              targetFillPercent < 100,
              viewportSize.width.isFinite,
              viewportSize.height.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return nil
        }
        let side = min(viewportSize.width, viewportSize.height)
            * CGFloat(targetFillPercent / 100)
        let width = side / viewportSize.width
        let height = side / viewportSize.height
        return CGRect(
            x: (1 - width) / 2,
            y: (1 - height) / 2,
            width: width,
            height: height
        )
    }

    static func frameName(
        targetFillPercent: Double,
        levels: [Double] = targetFillPercentages
    ) -> String {
        guard let index = levels.firstIndex(where: {
            abs($0 - targetFillPercent) < 0.001
        }) else {
            return "Guide frame"
        }
        return "Frame size \(index + 1) of \(levels.count)"
    }

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
    /// Present for the current protocol. `rounds` remains stored so older test files still decode.
    var objectCount: Int? = nil
    /// Nil identifies tests saved before the larger-guide protocol was introduced.
    var protocolFillPercentages: [Double]? = nil
    var readings: [FramingAccuracyReading] = []
    var failures: [FramingAccuracyFailure] = []
    var referenceSizeMillimetres: [Double]? = nil
    var objectReferenceSizesMillimetres: [Int: [Double]]? = nil

    var usesObjectProtocol: Bool { objectCount != nil }
    var configuredObjectCount: Int { max(objectCount ?? rounds, 1) }

    var resolvedTargetFillPercentages: [Double] {
        guard let protocolFillPercentages,
              protocolFillPercentages.count == 5,
              protocolFillPercentages.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 100 }) else {
            return FramingCalibrationProtocol.legacyTargetFillPercentages
        }
        return protocolFillPercentages
    }

    var totalExpectedReadings: Int {
        configuredObjectCount * resolvedTargetFillPercentages.count
    }

    var completedAttemptCount: Int { readings.count + failures.count }
    var isComplete: Bool { completedAttemptCount >= totalExpectedReadings }

    /// Current tests run the five sizes in the same order once per object. Legacy repeated-round
    /// tests retain their alternating order so saved protocols remain reproducible.
    var nextSlot: FramingAccuracySlot? {
        guard completedAttemptCount < totalExpectedReadings else { return nil }
        let levelsForTest = resolvedTargetFillPercentages
        let levelCount = levelsForTest.count
        let objectIndex = completedAttemptCount / levelCount
        let levelPosition = completedAttemptCount % levelCount
        let levels = usesObjectProtocol || objectIndex.isMultiple(of: 2)
            ? levelsForTest
            : Array(levelsForTest.reversed())
        return FramingAccuracySlot(
            round: objectIndex + 1,
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

    func referenceSize(forObject objectNumber: Int) -> [Double]? {
        if usesObjectProtocol {
            guard let values = objectReferenceSizesMillimetres?[objectNumber],
                  values.count == 3,
                  values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                return nil
            }
            return values
        }
        return referenceSize
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

    func frameName(targetFillPercent: Double) -> String {
        FramingCalibrationProtocol.frameName(
            targetFillPercent: targetFillPercent,
            levels: resolvedTargetFillPercentages
        )
    }
}

struct FramingLevelStatistics: Sendable {
    var targetFillPercent: Double
    var readings: [FramingAccuracyReading]
    var referencesByObject: [Int: [Double]]

    var allErrors: [Double] {
        return readings.flatMap { reading -> [Double] in
            guard let reference = referencesByObject[reading.round] else { return [] }
            return AccuracySideMatching.minimumErrorPairs(
                measured: reading.sizeMillimetres,
                reference: reference
            ).map { $0.measured - $0.reference }
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
        let references = Dictionary(uniqueKeysWithValues: (1...run.configuredObjectCount).compactMap {
            objectNumber in
            run.referenceSize(forObject: objectNumber).map { (objectNumber, $0) }
        })
        guard !references.isEmpty else { return nil }
        let levels: [FramingLevelStatistics] = run.resolvedTargetFillPercentages
            .compactMap { target -> FramingLevelStatistics? in
            let readings = run.readings(targetFillPercent: target).filter {
                references[$0.round] != nil
            }
            guard !readings.isEmpty else { return nil }
            return FramingLevelStatistics(
                targetFillPercent: target,
                readings: readings,
                referencesByObject: references
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
            usesObjectProtocol
                ? "Objects   : \(configuredObjectCount)"
                : "Rounds    : \(rounds)",
            "Levels    : \(resolvedTargetFillPercentages.map { AccuracyTestRun.number($0) }.joined(separator: ", "))%",
            "Attempts  : \(completedAttemptCount) of \(totalExpectedReadings)",
            "Successful: \(readings.count)",
            "Failed    : \(failures.count)",
            "Test id   : \(id.uuidString)",
            "",
            "Target fill is the detected object's longest projected side divided by the",
            "shorter viewport dimension. Guide placement is controlled by the operator; it does",
            "not lock or reject Start. Every reading starts from",
            "reset AR tracking. Percentages below are retained as audit data, not user prompts.",
            ""
        ]

        if usesObjectProtocol {
            for objectNumber in 1...configuredObjectCount {
                if let reference = referenceSize(forObject: objectNumber) {
                    lines.append("Object \(objectNumber) reference: \(AccuracyTestRun.sizeText(reference))")
                } else {
                    lines.append("Object \(objectNumber) reference: not entered")
                }
            }
        } else if let referenceSize {
            lines.append("Reference : \(AccuracyTestRun.sizeText(referenceSize))")
        } else {
            lines.append("Reference : not entered")
        }
        lines.append("")

        for target in resolvedTargetFillPercentages {
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
                    "  \(usesObjectProtocol ? "object" : "round") \(reading.round): actual \(AccuracyTestRun.number(reading.actualFillPercent))%, distance \(distance), measured \(reading.sizeText)"
                )
                lines.append(
                    "    mask x \(AccuracyTestRun.number(reading.viewportBoundingBox.x * 100))%, y \(AccuracyTestRun.number(reading.viewportBoundingBox.y * 100))%, width \(AccuracyTestRun.number(reading.viewportBoundingBox.width * 100))%, height \(AccuracyTestRun.number(reading.viewportBoundingBox.height * 100))%, nearest edge \(AccuracyTestRun.number(reading.viewportBoundingBox.nearestEdgeMarginPercent))%"
                )
            }
            for failure in targetFailures {
                lines.append("  \(usesObjectProtocol ? "object" : "round") \(failure.round): NO STABLE READING — \(failure.reason)")
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
            let hasAnyReference = (1...configuredObjectCount).contains {
                referenceSize(forObject: $0) != nil
            }
            lines.append(!hasAnyReference
                ? "Enter the true sizes to calculate errors."
                : "No successful readings are available to compare.")
        }
        lines.append("")
        lines.append("No framing interval is selected automatically. Choose it against a declared")
        lines.append("accuracy requirement, then confirm it on different objects.")
        return lines.joined(separator: "\n")
    }
}
