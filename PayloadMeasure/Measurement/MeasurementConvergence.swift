import Foundation

// Decides when a measurement has settled enough to finish automatically.
//
// Over a sliding window of the last N = 24 observations of each dimension:
//
//     mean   x = (1/n) * sum(x_i)
//     sd     s = sqrt(sum((x_i - x)^2) / (n - 1))
//     CI     h = t(0.975, n-1) * s / sqrt(n)          95% half-width
//     drift  d = |mean(second half) - mean(first half)|
//     tol    e = max(5 mm, 1% of |x|) / 2
//
// The scan finishes when n >= 24, h <= e and d <= e hold for width, depth and height at once.
// It also finishes if no new observation arrives for 2.5 s (with at least 4 samples), or after
// 10 s regardless. All three exits need a support plane, since height is measured from it.
//
// The h <= e test is the fixed-width stopping rule from Chow and Robbins (1965), but applied to
// a fixed window instead of the full sample, because the estimate shifts as new faces of the
// object come into view. The window size, tolerance and timeouts are our own choices.

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
        /// The 10 s limit was reached; the current reading is used.
        case timeLimit
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
        case .drifting, .precision:
            parts.append("Keep it in view while the size settles")
        case .converged:
            parts.append(
                basis == .evidenceExhausted
                    ? "No new detail arriving"
                    : "Converged"
            )
        }
        // The HUD only gets a short hint. The per-axis numbers are kept for the info panel and tests.
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
        /// Window length, and the minimum sample count before the rule can fire.
        var windowSize = 24
        var minimumSampleCount = 24
        /// Minimum samples before the timeout exit is allowed.
        var pilotSampleCount = 4
        var evidenceTimeout: TimeInterval = 2.5
        /// Hard limit on a measurement, whatever the statistics say.
        var timeLimit: TimeInterval = 10

        /// Full width of the allowed confidence interval. The rule compares the half-width against
        /// half of this.
        var intervalWidthFloorInMeters: Float = 0.005
        var intervalWidthRelative: Float = 0.01

        /// max(floor, relative * |mean|) / 2. The relative term matters for large dimensions, the floor
        /// for small ones.
        func halfWidthTolerance(forMean mean: Float) -> Float {
            max(intervalWidthFloorInMeters, intervalWidthRelative * abs(mean)) / 2
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
    /// Progress is capped here until a support plane exists.
    private static let progressCeilingWithoutSupport = 0.9

    private static func wholePercent(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (min(max(value, 0), 1) * 100).rounded(.down) / 100
    }

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
    private var firstSampleTimestamp: TimeInterval?
    /// Published progress never goes backwards, otherwise it looks like the app lost work.
    private var highWaterProgress: Double = 0

    init(configuration: Configuration = .default) {
        self.configuration = configuration
        axes = Array(repeating: AxisState(), count: MeasurementAxis.allCases.count)
    }

    mutating func reset() {
        axes = Array(repeating: AxisState(), count: MeasurementAxis.allCases.count)
        lastSampleTimestamp = nil
        firstSampleTimestamp = nil
        highWaterProgress = 0
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
        firstSampleTimestamp = min(firstSampleTimestamp ?? timestamp, timestamp)
    }

    mutating func evaluate(coverage: Coverage, now: TimeInterval) -> MeasurementConvergence {
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
        // Progress is the furthest of: how much of the rule is met, how much of the time limit has
        // passed, and the previous high-water mark.
        let elapsedFraction = firstSampleTimestamp.map {
            configuration.timeLimit > 0
                ? min(max((now - $0) / configuration.timeLimit, 0), 1)
                : 0
        } ?? 0
        highWaterProgress = max(
            highWaterProgress,
            max(min(coverageProgress, dimensionProgress), elapsedFraction)
        )
        // Without a support plane no exit can fire, so don't show the bar as full.
        // Rounded to whole percent so the overlay isn't redrawn on every frame.
        result.progress = Self.wholePercent(
            coverage.hasSupportPlane
                ? highWaterProgress
                : min(highWaterProgress, Self.progressCeilingWithoutSupport)
        )

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
        // Time limit reached. Still needs the support plane, like the other exits.
        if coverage.hasSupportPlane,
           let firstSampleTimestamp,
           now - firstSampleTimestamp >= configuration.timeLimit {
            return converged(result, basis: .timeLimit)
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
                tolerance: configuration.halfWidthTolerance(forMean: 0),
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
        let tolerance = configuration.halfWidthTolerance(forMean: mean)

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
