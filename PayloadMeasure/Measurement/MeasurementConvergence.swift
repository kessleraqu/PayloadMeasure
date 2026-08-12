import Foundation

// Decides when a measurement has settled enough to offer an automatic finish.
//
// In:  raw per-axis observations from each fit, with timestamps, plus what the current viewpoint
//      can actually see.
// Out: a convergence state with progress for the HUD, and whether the stopping rule has fired.
//
// THE RULE, exactly. Over the sliding window of the last N = 24 observations of one dimension:
//
//     x̄ₙ = (1/n) Σ xᵢ
//     sₙ = √( Σ(xᵢ − x̄ₙ)² / (n − 1) )                       Bessel-corrected sample s.d.
//     hₙ = t₀.₉₇₅,ₙ₋₁ · sₙ / √n                              95% two-sided CI half-width
//     δₙ = | mean(second half of window) − mean(first half) |
//     dₙ = max(5 mm, 1% · |x̄ₙ|) / 2                          half of the declared interval width
//
// and the scan finishes when, for width, depth AND height simultaneously:
//
//     n ≥ 24            ∧   hₙ ≤ dₙ            ∧   δₙ ≤ dₙ            ∧   a support plane exists
//
// There is a second exit: if no new observation has arrived for 2.5 s and at least 4 exist, the
// measurement finishes on the grounds that no further waiting can tighten it.
//
// PROVENANCE. Only the middle condition, hₙ ≤ dₙ, has a literature source: it is the fixed-width
// sequential stopping form of Chow and Robbins (1965). It is *not* their procedure. They accumulate
// every sample, which is what drives hₙ → 0 and gives the method its guarantee; this uses a fixed
// 24-frame window, over which hₙ does not shrink with time but instead measures how consistent the
// last 24 fits are. The window is deliberate — the quantity being estimated genuinely moves as new
// faces of the object come into view, so a growing sample would average across a changing mean —
// but it means the guarantee does not carry over. Chow and Robbins are the origin of the stopping
// form, not of the rule implemented here.
//
// Everything else is project-defined: N = 24, the 95% level, the Student-t finite-sample quantile,
// the 5 mm / 1% tolerance, the drift test δₙ, and the 2.5 s timeout.

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
        /// Length of the sliding window, and also the minimum before the rule may fire. Both are
        /// project-defined engineering choices, not values from any paper.
        var windowSize = 24
        var minimumSampleCount = 24
        /// Below this the second exit is not offered at all.
        var pilotSampleCount = 4
        /// No new observation for this long means the estimator can no longer change.
        var evidenceTimeout: TimeInterval = 2.5

        /// Declared as the **total width** of the confidence interval, which is how it reads to an
        /// operator: "this dimension is known to within 5 mm". The half-width tolerance the rule
        /// actually tests against is half of it, because hₙ is one side of the interval.
        var intervalWidthFloorInMeters: Float = 0.005
        var intervalWidthRelative: Float = 0.01

        /// dₙ = max(floor, relative · |x̄ₙ|) / 2. One combined tolerance, never two alternative
        /// tests: the relative term governs large dimensions, the floor governs small ones.
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
