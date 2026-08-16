import Foundation
import simd

// An accuracy test: the same objects measured over and over, then compared against sizes you type in.
//
// In:  how many objects and how many passes; one reading per object per pass; a reference size per
//      object, entered afterwards.
// Out: per-object and overall trueness, precision and accuracy figures, and a plain-text report.
//
// AXIS MATCHING. A reading is compared against its reference by sorting both triples largest first
// and pairing them off. The app has no way of knowing which of an object's sides the operator called
// "width", and it can come out differently from one pass to the next depending on how the object was
// approached, so pairing raw axes would report rotations as errors. Sorted comparison measures what is
// actually being asked — whether the three side lengths are right — and is the only way the numbers
// mean the same thing across passes. The raw triple is kept as recorded.
//
// STATISTICS. Standard measurement-system terms, all in millimetres unless marked otherwise:
//
//   errorᵢ  = measuredᵢ − reference                  signed, per reading
//   bias    = mean(errorᵢ)                           trueness: systematic over- or under-reading
//   sᵣ      = √( Σ(measuredᵢ − mean)² / (n − 1) )    repeatability standard deviation, ISO 5725-2
//   CV      = sᵣ / mean × 100                        relative precision, per cent
//   r       = 2.8 · sᵣ                               repeatability limit, ISO 5725-6 §4.1.4
//   MAE     = mean(|errorᵢ|)
//   RMSE    = √( mean(errorᵢ²) )                     accuracy: bias and scatter together
//   CI₉₅    = t₀.₉₇₅,ₙ₋₁ · sᵣ / √n                   half-width on the mean
//   LoA     = bias ± 1.96 · s(error)                 Bland–Altman limits of agreement
//
// RMSE is the headline: it is the only one of these that answers "how far out is a single reading
// likely to be", because bias and scatter both feed into it.

// MARK: - Recording

struct AccuracyReading: Codable, Identifiable, Sendable {
    var id: UUID
    /// One-based, as shown to the operator.
    var objectNumber: Int
    var pass: Int
    /// As measured, in the app's own width/length/height order.
    var sizeMillimetres: [Double]
    var recordedAt: Date
    /// Nil is retained for tests recorded by versions that only measured the 3D workflow.
    var workflowMode: MeasurementWorkflowMode? = nil

    /// Largest side first. What every comparison uses.
    var sortedSizeMillimetres: [Double] {
        sizeMillimetres.sorted(by: >)
    }

    var sizeText: String {
        AccuracyTestRun.sizeText(sizeMillimetres)
    }
}

struct AccuracyTestRun: Codable, Identifiable, Sendable {
    var id: UUID
    var createdAt: Date
    var label: String
    /// How many different objects are in the test.
    var objectCount: Int
    /// How many times each object is measured.
    var passes: Int
    var readings: [AccuracyReading] = []
    /// Keyed by object number as a string, because JSON object keys cannot be integers.
    var referenceSizesMillimetres: [String: [Double]] = [:]
    /// New tests compare both methods. Nil identifies a legacy, 3D-only test and keeps old files
    /// decodable without a migration step.
    var workflowModes: [MeasurementWorkflowMode]? = nil

    var measurementModes: [MeasurementWorkflowMode] {
        guard let workflowModes, !workflowModes.isEmpty else { return [.spatial3D] }
        return workflowModes.reduce(into: []) { modes, mode in
            if !modes.contains(mode) { modes.append(mode) }
        }
    }

    var objectNumbers: [Int] { Array(1...max(objectCount, 1)) }

    var totalExpectedReadings: Int { objectCount * passes * measurementModes.count }

    var isComplete: Bool { readings.count >= totalExpectedReadings }

    func readings(forObject objectNumber: Int) -> [AccuracyReading] {
        readings
            .filter { $0.objectNumber == objectNumber }
            .sorted {
                if $0.pass != $1.pass { return $0.pass < $1.pass }
                let firstMode = $0.workflowMode ?? .spatial3D
                let secondMode = $1.workflowMode ?? .spatial3D
                return (measurementModes.firstIndex(of: firstMode) ?? 0)
                    < (measurementModes.firstIndex(of: secondMode) ?? 0)
            }
    }

    func readings(
        forObject objectNumber: Int,
        workflowMode: MeasurementWorkflowMode
    ) -> [AccuracyReading] {
        readings(forObject: objectNumber).filter {
            ($0.workflowMode ?? .spatial3D) == workflowMode
        }
    }

    func reference(forObject objectNumber: Int) -> [Double]? {
        guard let values = referenceSizesMillimetres["\(objectNumber)"],
              values.count == 3,
              values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }
        return values
    }

    var hasEveryReference: Bool {
        objectNumbers.allSatisfy { reference(forObject: $0) != nil }
    }

    // MARK: Position in the test

    /// Where the next reading goes: all passes for one method, then the next method. Inside a method,
    /// every object is measured once per pass in the same order.
    var nextSlot: (objectNumber: Int, pass: Int, workflowMode: MeasurementWorkflowMode)? {
        guard objectCount > 0, passes > 0 else { return nil }
        let done = readings.count
        guard done < totalExpectedReadings else { return nil }
        let modes = measurementModes
        // Keep each method in one block. Changing mode deliberately clears the AR fit, so alternating
        // Top/3D for every object would repeatedly restart recognition and make a long test painful.
        let measurementsPerMode = objectCount * passes
        let positionInMode = done % measurementsPerMode
        return (
            objectNumber: positionInMode % objectCount + 1,
            pass: positionInMode / objectCount + 1,
            workflowMode: modes[done / measurementsPerMode]
        )
    }

    static func sizeText(_ values: [Double]) -> String {
        guard values.count == 3 else { return "—" }
        return String(format: "%.1f × %.1f × %.1f mm", values[0], values[1], values[2])
    }
}

// MARK: - Statistics

/// One axis of one object: the reference side length, and every measurement of it.
struct AccuracyAxisStatistics: Sendable {
    /// 0 is the longest side, 2 the shortest.
    var axisIndex: Int
    var reference: Double
    var values: [Double]

    var count: Int { values.count }
    var errors: [Double] { values.map { $0 - reference } }

    var mean: Double {
        guard !values.isEmpty else { return .nan }
        return values.reduce(0, +) / Double(count)
    }

    /// Repeatability standard deviation. Needs at least two readings to exist at all.
    var standardDeviation: Double {
        guard count > 1 else { return .nan }
        let m = mean
        let sumOfSquares = values.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        return (sumOfSquares / Double(count - 1)).squareRoot()
    }

    var bias: Double { mean - reference }

    var relativeBiasPercent: Double {
        reference == 0 ? .nan : bias / reference * 100
    }

    var coefficientOfVariationPercent: Double {
        let m = mean
        guard m != 0, standardDeviation.isFinite else { return .nan }
        return standardDeviation / m * 100
    }

    var repeatabilityLimit: Double {
        standardDeviation.isFinite ? 2.8 * standardDeviation : .nan
    }

    var meanAbsoluteError: Double {
        guard !values.isEmpty else { return .nan }
        return errors.reduce(0) { $0 + abs($1) } / Double(count)
    }

    var rootMeanSquareError: Double {
        guard !values.isEmpty else { return .nan }
        return (errors.reduce(0) { $0 + $1 * $1 } / Double(count)).squareRoot()
    }

    var maximumAbsoluteError: Double {
        errors.map(abs).max() ?? .nan
    }

    /// Half-width of the 95% confidence interval on the mean.
    var meanConfidenceHalfWidth: Double {
        guard count > 1, standardDeviation.isFinite else { return .nan }
        return AccuracyStatistics.tQuantile975(degreesOfFreedom: count - 1)
            * standardDeviation / Double(count).squareRoot()
    }

    var axisLabel: String {
        switch axisIndex {
        case 0: "longest"
        case 1: "middle"
        default: "shortest"
        }
    }
}

struct AccuracyObjectStatistics: Sendable {
    var objectNumber: Int
    var reference: [Double]
    var axes: [AccuracyAxisStatistics]

    var readingCount: Int { axes.first?.count ?? 0 }

    /// Over all three axes together.
    var allErrors: [Double] { axes.flatMap(\.errors) }

    var rootMeanSquareError: Double {
        AccuracyStatistics.rootMeanSquare(allErrors)
    }

    var meanAbsoluteError: Double {
        AccuracyStatistics.mean(allErrors.map(abs))
    }

    var bias: Double { AccuracyStatistics.mean(allErrors) }

    var maximumAbsoluteError: Double { allErrors.map(abs).max() ?? .nan }
}

struct AccuracySummary: Sendable {
    var objects: [AccuracyObjectStatistics]

    var allErrors: [Double] { objects.flatMap(\.allErrors) }

    /// Whole measurements compared.
    var readingCount: Int { objects.reduce(0) { $0 + $1.readingCount } }

    /// Individual side lengths compared — three per reading. This, not `readingCount`, is the n behind
    /// the bias, the spread and the limits of agreement, so both are reported.
    var comparisonCount: Int { allErrors.count }

    var bias: Double { AccuracyStatistics.mean(allErrors) }
    var errorStandardDeviation: Double { AccuracyStatistics.standardDeviation(allErrors) }
    var meanAbsoluteError: Double { AccuracyStatistics.mean(allErrors.map(abs)) }
    var rootMeanSquareError: Double { AccuracyStatistics.rootMeanSquare(allErrors) }
    var maximumAbsoluteError: Double { allErrors.map(abs).max() ?? .nan }

    /// Bland–Altman limits of agreement against the reference.
    var limitsOfAgreement: (lower: Double, upper: Double) {
        let spread = 1.96 * errorStandardDeviation
        return (bias - spread, bias + spread)
    }

    /// Worst repeatability standard deviation across every object and axis: the honest single number
    /// for "how much does a repeat measurement move".
    var worstRepeatabilityStandardDeviation: Double {
        objects
            .flatMap(\.axes)
            .map(\.standardDeviation)
            .filter(\.isFinite)
            .max() ?? .nan
    }
}

enum AccuracyStatistics {
    static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        return values.reduce(0, +) / Double(values.count)
    }

    static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return .nan }
        let m = mean(values)
        return (values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)).squareRoot()
    }

    static func rootMeanSquare(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        return (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    }

    /// Two-sided 95% Student-t quantiles, ν = 1…30, then the normal limit. Same table the measurement
    /// stopping rule uses.
    static func tQuantile975(degreesOfFreedom: Int) -> Double {
        let table: [Double] = [
            12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
            2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
            2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042
        ]
        guard degreesOfFreedom >= 1 else { return .nan }
        return degreesOfFreedom <= table.count ? table[degreesOfFreedom - 1] : 1.96
    }

    /// Builds the whole summary. Objects without a reference size, or with no readings, are left out
    /// rather than reported as zero error.
    static func summarise(
        _ run: AccuracyTestRun,
        workflowMode: MeasurementWorkflowMode? = nil
    ) -> AccuracySummary {
        var objects: [AccuracyObjectStatistics] = []
        for number in run.objectNumbers {
            guard let reference = run.reference(forObject: number) else { continue }
            let readings = workflowMode.map {
                run.readings(forObject: number, workflowMode: $0)
            } ?? run.readings(forObject: number)
            guard !readings.isEmpty else { continue }

            let sortedReference = reference.sorted(by: >)
            let axes = (0..<3).map { axisIndex in
                AccuracyAxisStatistics(
                    axisIndex: axisIndex,
                    reference: sortedReference[axisIndex],
                    values: readings.map { $0.sortedSizeMillimetres[axisIndex] }
                )
            }
            objects.append(
                AccuracyObjectStatistics(
                    objectNumber: number,
                    reference: sortedReference,
                    axes: axes
                )
            )
        }
        return AccuracySummary(objects: objects)
    }
}

// MARK: - Report

extension AccuracyTestRun {
    var reportFileName: String {
        let safe = label
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let stamp = StudyRun.fileDateFormatter.string(from: createdAt)
        return "payloadmeasure-accuracy-\(safe.isEmpty ? "test" : safe)-\(stamp).txt"
    }

    func reportText() -> String {
        let summary = AccuracyStatistics.summarise(self)
        var lines: [String] = []

        lines.append("PayloadMeasure accuracy test")
        lines.append("============================")
        lines.append("Label     : \(label)")
        lines.append("Recorded  : \(StudyRun.displayDateFormatter.string(from: createdAt))")
        lines.append("Objects   : \(objectCount)")
        lines.append("Passes    : \(passes)")
        lines.append("Methods   : \(measurementModes.map(\.title).joined(separator: " + "))")
        lines.append("Readings  : \(readings.count) of \(totalExpectedReadings)")
        lines.append("Test id   : \(id.uuidString)")
        lines.append("")
        lines.append("Sides are compared largest-to-largest, so turning an object between passes is")
        lines.append("not counted as an error. All figures are millimetres unless marked otherwise.")
        lines.append("")

        if measurementModes.count > 1 {
            lines.append("Method comparison")
            lines.append("-----------------")
            for mode in measurementModes {
                let method = AccuracyStatistics.summarise(self, workflowMode: mode)
                guard !method.objects.isEmpty else { continue }
                lines.append(
                    "\(mode.title): bias \(Self.number(method.bias)), MAE \(Self.number(method.meanAbsoluteError)), RMSE \(Self.number(method.rootMeanSquareError)), worst \(Self.number(method.maximumAbsoluteError))"
                )
            }
            lines.append("")
        }

        for object in summary.objects {
            lines.append("-------------------------------------------------------------")
            lines.append("Object \(object.objectNumber)   reference \(Self.sizeText(object.reference))")
            lines.append("-------------------------------------------------------------")
            lines.append("Readings (\(object.readingCount)), as measured:")
            for reading in readings(forObject: object.objectNumber) {
                let methodPrefix = reading.workflowMode.map { "\($0.shortTitle) · " } ?? ""
                lines.append("  \(methodPrefix)pass \(reading.pass): \(reading.sizeText)")
            }
            lines.append("")
            lines.append("  side      ref     mean     bias     bias%      sd      CV%     r     MAE    RMSE   max|e|   ±95%")
            for axis in object.axes {
                lines.append(
                    "  "
                        + axis.axisLabel.padding(toLength: 9, withPad: " ", startingAt: 0)
                        + [
                            axis.reference, axis.mean, axis.bias, axis.relativeBiasPercent,
                            axis.standardDeviation, axis.coefficientOfVariationPercent,
                            axis.repeatabilityLimit, axis.meanAbsoluteError,
                            axis.rootMeanSquareError, axis.maximumAbsoluteError,
                            axis.meanConfidenceHalfWidth
                        ]
                        .map { Self.number($0, width: 8) }
                        .joined()
                )
            }
            lines.append("")
            lines.append(
                "  All three sides: bias \(Self.number(object.bias)), MAE \(Self.number(object.meanAbsoluteError)), RMSE \(Self.number(object.rootMeanSquareError)), worst \(Self.number(object.maximumAbsoluteError))"
            )
            lines.append("")
        }

        lines.append("-------------------------------------------------------------")
        lines.append("Overall")
        lines.append("-------------------------------------------------------------")
        if summary.objects.isEmpty {
            lines.append("Nothing to report: no object has both readings and a reference size.")
        } else {
            let loa = summary.limitsOfAgreement
            lines.append(
                "Readings compared     : \(summary.readingCount)  (\(summary.comparisonCount) side lengths)"
            )
            lines.append("Bias (trueness)       : \(Self.number(summary.bias))")
            lines.append("SD of errors          : \(Self.number(summary.errorStandardDeviation))")
            lines.append("Mean absolute error   : \(Self.number(summary.meanAbsoluteError))")
            lines.append("RMSE                  : \(Self.number(summary.rootMeanSquareError))")
            lines.append("Largest single error   : \(Self.number(summary.maximumAbsoluteError))")
            lines.append(
                "95% limits of agreement: \(Self.number(loa.lower)) to \(Self.number(loa.upper))"
            )
            lines.append(
                "Worst repeatability sd : \(Self.number(summary.worstRepeatabilityStandardDeviation))"
            )
            lines.append("")
            lines.append("Bias is the systematic part: a positive figure means the app reads large.")
            lines.append("RMSE is how far out one reading is likely to be, bias and scatter together.")
            lines.append("Limits of agreement are Bland–Altman: 95% of errors should fall inside them.")
        }
        lines.append("")
        lines.append("End of report")
        return lines.joined(separator: "\n")
    }

    static func number(_ value: Double, width: Int = 0) -> String {
        let text = value.isFinite ? String(format: "%.2f", value) : "—"
        guard width > text.count else { return text }
        return String(repeating: " ", count: width - text.count) + text
    }
}
