import Foundation

// Decides when a measurement has settled enough to offer an automatic lock.
//
// In:  raw per-axis observations from each fit, with timestamps, plus what the current viewpoint
//      can actually see.
// Out: a convergence state with progress for the HUD, and whether the stopping rule has fired.

nonisolated enum MeasurementAxis: Int, CaseIterable, Sendable {
    case width
    case depth
    case height

    var label: String {
        switch self {
        case .width:
            "width"
        case .depth:
            "length"
        case .height:
            "height"
        }
    }
}

nonisolated struct MeasurementConvergence: Equatable, Sendable {
    enum LimitingFactor: Equatable, Sendable {
        case noActiveMeasurement
        case waitingForSupportPlane
        case needsTopView
        case needsSideView
        case collectingSamples
        case drifting
        case precision
        case converged
    }

    enum Basis: Equatable, Sendable {
        case none
        case precisionTarget
        case evidenceExhausted
    }

    var progress: Double = 0
    var isConverged = false
    var basis: Basis = .none
    var limitingFactor: LimitingFactor = .noActiveMeasurement
    var limitingAxis: MeasurementAxis?
    var sampleCount = 0
    var minimumSampleCount = 0
    var deviationInMeters: Float?
    var toleranceInMeters: Float?
    var estimatedSecondsRemaining: Int?

    static let idle = MeasurementConvergence()

    var isActive: Bool {
        limitingFactor != .noActiveMeasurement
    }

    var headline: String {
        switch limitingFactor {
        case .noActiveMeasurement:
            "Auto-lock"
        case .waitingForSupportPlane:
            "Waiting for the surface"
        case .needsTopView:
            "Show the top"
        case .needsSideView:
            "Show a side"
        case .collectingSamples, .drifting, .precision:
            "Hold steady"
        case .converged:
            "Locking"
        }
    }

    var detail: String {
        var parts: [String] = []
        switch limitingFactor {
        case .noActiveMeasurement:
            return "Select an object to measure"
        case .waitingForSupportPlane:
            parts.append("Scan the surface beneath it")
        case .needsTopView:
            parts.append("Point straight down")
        case .needsSideView:
            parts.append("Move to the side")
        case .collectingSamples:
            parts.append("Keep it in view")
        case .drifting:
            parts.append("\(axisLabel.capitalized) still changing")
        case .precision:
            parts.append("\(axisLabel.capitalized) still noisy")
        case .converged:
            parts.append(
                basis == .evidenceExhausted
                    ? "No new detail arriving"
                    : "Converged"
            )
        }
        if let precisionText {
            parts.append(precisionText)
        }
        if let timeText {
            parts.append(timeText)
        }
        return parts.joined(separator: " · ")
    }

    var precisionText: String? {
        guard let deviationInMeters,
              let toleranceInMeters,
              deviationInMeters.isFinite else {
            return nil
        }
        return "±\(millimetres(deviationInMeters)) → ±\(millimetres(toleranceInMeters)) mm"
    }

    mutating func report(_ deviation: Float, tolerance: Float) {
        deviationInMeters = deviation
        toleranceInMeters = tolerance
    }

    var timeText: String? {
        guard !isConverged,
              limitingFactor == .collectingSamples || limitingFactor == .precision,
              let estimatedSecondsRemaining,
              estimatedSecondsRemaining > 0 else {
            return nil
        }
        return "~\(estimatedSecondsRemaining) s"
    }

    private var axisLabel: String {
        limitingAxis?.label ?? "measurement"
    }

    private func millimetres(_ meters: Float) -> String {
        String(format: "%.1f", meters * 1000)
    }
}

nonisolated struct MeasurementConvergenceMonitor: Sendable {
    struct Configuration: Sendable {
        var windowSize = 24
        var minimumSampleCount = 24
        var pilotSampleCount = 4
        var evidenceTimeout: TimeInterval = 2.5
        var declaredAbsoluteToleranceInMeters: Float = 0.005
        var declaredRelativeTolerance: Float = 0.01

        var absoluteToleranceInMeters: Float {
            declaredAbsoluteToleranceInMeters / 2
        }

        var relativeTolerance: Float {
            declaredRelativeTolerance / 2
        }

        static let `default` = Configuration()
    }

    struct Coverage: Equatable, Sendable {
        var isMeasuring = false
        var hasSupportPlane = false
        var reportsSideViewSeparately = true
    }

    private static let tQuantiles95: [Double] = [
        12.706, 4.303, 3.182, 2.776, 2.571, 2.447, 2.365, 2.306, 2.262, 2.228,
        2.201, 2.179, 2.160, 2.145, 2.131, 2.120, 2.110, 2.101, 2.093, 2.086,
        2.080, 2.074, 2.069, 2.064, 2.060, 2.056, 2.052, 2.048, 2.045, 2.042
    ]
    private static let normalQuantile95 = 1.960

    private struct AxisState: Sendable {
        var values: [Float] = []
        var timestamps: [TimeInterval] = []
    }

    private struct AxisAssessment {
        let precisionRatio: Double
        let plateauRatio: Double
        let halfWidth: Float
        let drift: Float
        let tolerance: Float
        let projectedRemaining: Int
        let sampleCount: Int

        func sampleProgress(minimum: Int) -> Double {
            min(Double(sampleCount) / Double(max(minimum, 1)), 1)
        }
    }

    let configuration: Configuration
    private var axes: [AxisState]
    private var lastSampleTimestamp: TimeInterval?

    init(configuration: Configuration = .default) {
        self.configuration = configuration
        axes = Array(repeating: AxisState(), count: MeasurementAxis.allCases.count)
    }

    mutating func reset() {
        axes = Array(repeating: AxisState(), count: MeasurementAxis.allCases.count)
        lastSampleTimestamp = nil
    }

    mutating func record(_ axis: MeasurementAxis, value: Float, at timestamp: TimeInterval) {
        guard value.isFinite, value > 0 else {
            return
        }
        var state = axes[axis.rawValue]
        state.values.append(value)
        state.timestamps.append(timestamp)
        if state.values.count > configuration.windowSize {
            let excess = state.values.count - configuration.windowSize
            state.values.removeFirst(excess)
            state.timestamps.removeFirst(excess)
        }
        axes[axis.rawValue] = state
        lastSampleTimestamp = max(lastSampleTimestamp ?? timestamp, timestamp)
    }

    func evaluate(coverage: Coverage, now: TimeInterval) -> MeasurementConvergence {
        var result = MeasurementConvergence()
        result.minimumSampleCount = configuration.minimumSampleCount
        result.sampleCount = axes.map(\.values.count).min() ?? 0

        guard coverage.isMeasuring else {
            return result
        }

        let coverageProgress: Double = coverage.hasSupportPlane ? 1 : 0

        var precisionProgress = 0.0
        var plateauProgress = 0.0
        var limitingPrecisionAxis = MeasurementAxis.width
        var limitingPlateauAxis = MeasurementAxis.width
        var largestRemaining = 0
        var assessments: [AxisAssessment] = []
        assessments.reserveCapacity(MeasurementAxis.allCases.count)

        for axis in MeasurementAxis.allCases {
            let assessment = assess(axis)
            assessments.append(assessment)
            if axis == .width || assessment.precisionRatio < precisionProgress {
                precisionProgress = assessment.precisionRatio
                limitingPrecisionAxis = axis
            }
            if axis == .width || assessment.plateauRatio < plateauProgress {
                plateauProgress = assessment.plateauRatio
                limitingPlateauAxis = axis
            }
            largestRemaining = max(largestRemaining, assessment.projectedRemaining)
        }

        let dimensionProgress = assessments.reduce(0.0) { partial, assessment in
            partial + min(
                assessment.sampleProgress(
                    minimum: configuration.minimumSampleCount
                ),
                min(assessment.precisionRatio, assessment.plateauRatio)
            )
        } / Double(assessments.count)
        result.progress = min(coverageProgress, dimensionProgress)

        let remaining = max(
            largestRemaining,
            configuration.minimumSampleCount - result.sampleCount
        )
        if remaining > 0 {
            if let interval = meanSampleInterval, interval > 0 {
                result.estimatedSecondsRemaining = max(
                    Int((Double(remaining) * interval).rounded()),
                    1
                )
            }
        }

        let hasFullWindows = result.sampleCount >= configuration.minimumSampleCount
        let precisionSatisfied = hasFullWindows
            && precisionProgress >= 1
            && plateauProgress >= 1

        let widest = assessments[limitingPrecisionAxis.rawValue]
        result.report(widest.halfWidth, tolerance: widest.tolerance)

        if coverage.hasSupportPlane, precisionSatisfied {
            return converged(result, basis: .precisionTarget)
        }
        if coverage.hasSupportPlane,
           result.sampleCount >= configuration.pilotSampleCount,
           let lastSampleTimestamp,
           now - lastSampleTimestamp >= configuration.evidenceTimeout {
            return converged(result, basis: .evidenceExhausted)
        }

        if !coverage.hasSupportPlane {
            result.limitingFactor = .waitingForSupportPlane
        } else if let starved = starvedAxis {
            result.limitingFactor = starved == .height && coverage.reportsSideViewSeparately
                ? .needsSideView
                : .needsTopView
            result.limitingAxis = starved
        } else if !hasFullWindows {
            result.limitingFactor = .collectingSamples
        } else if precisionProgress < 1 {
            result.limitingFactor = .precision
            result.limitingAxis = limitingPrecisionAxis
        } else {
            result.limitingFactor = .drifting
            result.limitingAxis = limitingPlateauAxis
            let drifting = assessments[limitingPlateauAxis.rawValue]
            result.report(drifting.drift, tolerance: drifting.tolerance)
        }
        return result
    }

    private func converged(
        _ base: MeasurementConvergence,
        basis: MeasurementConvergence.Basis
    ) -> MeasurementConvergence {
        var result = base
        result.limitingFactor = .converged
        result.limitingAxis = nil
        result.isConverged = true
        result.basis = basis
        result.progress = 1
        result.estimatedSecondsRemaining = nil
        return result
    }

    private func assess(_ axis: MeasurementAxis) -> AxisAssessment {
        let values = axes[axis.rawValue].values
        guard values.count >= 2 else {
            return AxisAssessment(
                precisionRatio: 0,
                plateauRatio: 0,
                halfWidth: .infinity,
                drift: .infinity,
                tolerance: configuration.absoluteToleranceInMeters,
                projectedRemaining: configuration.minimumSampleCount - values.count,
                sampleCount: values.count
            )
        }

        let count = values.count
        let mean = values.reduce(0, +) / Float(count)
        let sumOfSquares = values.reduce(Float(0)) { partial, value in
            let deviation = value - mean
            return partial + deviation * deviation
        }
        let standardDeviation = (sumOfSquares / Float(count - 1)).squareRoot()
        let quantile = Float(Self.tQuantile95(degreesOfFreedom: count - 1))
        let halfWidth = quantile * standardDeviation / Float(count).squareRoot()
        let tolerance = max(
            configuration.absoluteToleranceInMeters,
            configuration.relativeTolerance * abs(mean)
        )

        let precisionRatio = halfWidth <= 0 ? 1 : min(Double(tolerance / halfWidth), 1)
        let drift = meanShift(for: values)
        let plateauRatio = drift <= 0 ? 1 : min(Double(tolerance / drift), 1)

        return AxisAssessment(
            precisionRatio: precisionRatio,
            plateauRatio: plateauRatio,
            halfWidth: halfWidth,
            drift: drift,
            tolerance: tolerance,
            projectedRemaining: projectedRemainingSamples(
                standardDeviation: standardDeviation,
                tolerance: tolerance,
                sampleCount: count
            ),
            sampleCount: count
        )
    }

    private func meanShift(for values: [Float]) -> Float {
        guard values.count >= 4 else {
            return .infinity
        }
        let split = values.count / 2
        let earlier = values[..<split]
        let later = values[split...]
        let earlierMean = earlier.reduce(0, +) / Float(earlier.count)
        let laterMean = later.reduce(0, +) / Float(later.count)
        return abs(laterMean - earlierMean)
    }

    private func projectedRemainingSamples(
        standardDeviation: Float,
        tolerance: Float,
        sampleCount: Int
    ) -> Int {
        guard tolerance > 0, standardDeviation > 0 else {
            return 0
        }
        let quantile = Float(Self.tQuantile95(degreesOfFreedom: max(sampleCount - 1, 1)))
        let required = quantile * standardDeviation / tolerance
        let projected = Int((required * required).rounded(.up))
        return min(max(projected - sampleCount, 0), configuration.windowSize)
    }

    private var starvedAxis: MeasurementAxis? {
        let counts = axes.map(\.values.count)
        guard let fewest = counts.min(),
              let most = counts.max(),
              fewest < configuration.minimumSampleCount,
              most - fewest >= configuration.minimumSampleCount / 2,
              let index = counts.firstIndex(of: fewest) else {
            return nil
        }
        return MeasurementAxis(rawValue: index)
    }

    private var meanSampleInterval: TimeInterval? {
        var slowestInterval: TimeInterval?
        for state in axes {
            guard state.timestamps.count >= 2,
                  let first = state.timestamps.first,
                  let last = state.timestamps.last,
                  last > first else {
                continue
            }
            let interval = (last - first) / TimeInterval(state.timestamps.count - 1)
            slowestInterval = max(slowestInterval ?? interval, interval)
        }
        return slowestInterval
    }

    private static func tQuantile95(degreesOfFreedom: Int) -> Double {
        guard degreesOfFreedom >= 1 else {
            return tQuantiles95[0]
        }
        guard degreesOfFreedom <= tQuantiles95.count else {
            return normalQuantile95
        }
        return tQuantiles95[degreesOfFreedom - 1]
    }
}
