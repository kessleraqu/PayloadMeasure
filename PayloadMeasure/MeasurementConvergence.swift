import Foundation

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

/// The state of the sequential stopping rule for the object currently being measured.
///
/// `progress` is the fraction of the rule that is satisfied, taken as the *minimum* over its
/// individual conditions, so the bar always shows the limiting one and can never read 100 % while
/// something still blocks the lock. `limitingFactor` names that condition.
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

    /// Why the rule stopped. Both bases are legitimate terminations of a sequential procedure:
    /// the interval reached its target width, or the scan stopped producing new evidence at all.
    enum Basis: Equatable, Sendable {
        case none
        case precisionTarget
        case evidenceExhausted
    }

    var progress: Double = 0
    var isConverged = false
    var basis: Basis = .none
    var limitingFactor: LimitingFactor = .noActiveMeasurement
    /// Which dimension is holding the rule back, when a statistical condition is the limit.
    var limitingAxis: MeasurementAxis?
    var sampleCount = 0
    var minimumSampleCount = 0
    /// How far the limiting dimension currently is from settled, in metres: its 95 %
    /// confidence-interval half-width, or its residual drift when drift is what is limiting.
    var deviationInMeters: Float?
    /// The figure that deviation has to reach, in metres.
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

    /// The instruction, then the live precision, then the time estimate — each part included only
    /// when it tells the operator something they can act on.
    ///
    /// Kept terse deliberately: this sits on one line of a heads-up card over the camera, and a
    /// sentence that wraps to three lines costs more of the view than it is worth.
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

    /// Where the limiting dimension currently sits against the figure it has to reach.
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

    /// Only shown while the wait really is a matter of collecting more samples. The sequential
    /// sample-size formula it comes from models random spread, not drift, so quoting a time while
    /// the estimate is still moving would be a number the rule cannot stand behind.
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

/// Decides when a live LiDAR measurement has converged well enough to lock itself.
///
/// The scan republishes a box fit many times a second, so "is it done?" is a sequential
/// estimation problem, and this uses the textbook answer to it — the *fixed-width sequential
/// confidence interval* rule: keep sampling until the half-width of the confidence interval for
/// the mean falls within a prescribed tolerance `d`.
///
///   Chow, Y. S. and Robbins, H. (1965). "On the asymptotic theory of fixed-width sequential
///   confidence intervals for the mean." *Annals of Mathematical Statistics* 36(2), 457–462.
///   Mukhopadhyay, N. and de Silva, B. M. (2009). *Sequential Methods and Their Applications*.
///
/// Applied independently to each dimension x over a sliding window of its last `windowSize`
/// observations, with n the number of observations in that window:
///
///   h_x = t(0.975, n−1) · s_x / √n   ≤   d_x ,      d_x = max(d_abs, d_rel · x̄)
///
/// Two properties of this particular estimator shape the rest of the rule.
///
/// A dimension is only informative from a viewpoint that can see it — width and length from
/// above, height from the side — so each dimension keeps its own window and is only sampled from
/// its own viewpoint. Sampling the published box instead would be wrong twice over: it carries a
/// remembered value for whichever dimension the current view cannot measure, and it passes
/// through a display deadband that would report a variance of exactly zero for a still camera.
///
/// And while new surface is still being discovered the estimate is not drawn from a stationary
/// population — it grows — so a slow monotone growth can show a small standard error while being
/// plainly unconverged. The rule therefore also requires a plateau: the difference between the
/// means of the two halves of the window, a two-sample mean-shift check, must also be within
/// `d_x`.
///
/// Those two conditions bound different components of the error — random spread and residual
/// systematic drift — so, as in an ordinary uncertainty budget, the declared measurement
/// tolerance is split between them rather than granted to each in full. The declared tolerance is
/// ±5 mm or 1 % of the dimension, whichever is larger; `d_x` above is half of it, so the two
/// components can sum to the declared figure in the worst case.
///
/// Both tolerances are therefore declared measurement tolerances rather than tuning constants:
/// the absolute one is the smallest difference the instrument is claimed to resolve, the relative
/// one the same as a fraction of the dimension.
nonisolated struct MeasurementConvergenceMonitor: Sendable {
    struct Configuration: Sendable {
        /// The sliding window each dimension is evaluated over. It also bounds n, so a dimension
        /// whose projected sample requirement exceeds it converges by `s` falling, not by n
        /// growing.
        var windowSize = 24
        /// A full window. Both tests get sharper as n grows — the plateau test especially, since
        /// it compares two halves and short halves are blind to exactly the slow drift it exists
        /// to catch — so allowing a stop at a partial window would let the rule fire at its least
        /// sensitive moment. Requiring the full window also makes its sensitivity constant and
        /// stateable: every stop is judged over the same 24 observations.
        var minimumSampleCount = 24
        /// Pilot sample required before the evidence-exhaustion termination may be used.
        var pilotSampleCount = 4
        /// How long the scan may produce no new observation before the estimator is treated as
        /// having run out of evidence. The point cloud only publishes a fit when it gains newly
        /// stable voxels, so silence this long means the fit can no longer change.
        var evidenceTimeout: TimeInterval = 2.5
        /// The declared measurement tolerance: the largest error the app claims for a locked
        /// dimension, and the only number in this rule that is a policy choice rather than a
        /// consequence of one. Everything else follows from it.
        var declaredAbsoluteToleranceInMeters: Float = 0.005
        var declaredRelativeTolerance: Float = 0.01

        /// Half the declared tolerance. The interval condition and the plateau condition bound
        /// different error components, so each gets half of the budget and the two together
        /// cannot exceed what is claimed.
        var absoluteToleranceInMeters: Float {
            declaredAbsoluteToleranceInMeters / 2
        }

        var relativeTolerance: Float {
            declaredRelativeTolerance / 2
        }

        static let `default` = Configuration()
    }

    /// The one condition the statistics cannot see: whether the box has a real support plane to
    /// stand on.
    ///
    /// "Has the operator shown each viewpoint" is deliberately *not* a separate condition. A
    /// dimension is only sampled from a view that can measure it, so a starved window already
    /// says the view has not been held, and it says so as a count rather than a flag. Deriving it
    /// that way also keeps the reported progress continuous: the app's other convergence flags
    /// are "held steady for six consecutive fits", which sit at false for a long time and then
    /// flip, and a bar driven off those does nothing and then finishes.
    struct Coverage: Equatable, Sendable {
        var isMeasuring = false
        var hasSupportPlane = false
        /// `.top` measures every dimension from one overhead view, so a starved window there
        /// always means "point straight down" rather than "show a side".
        var reportsSideViewSeparately = true
    }

    /// Two-sided 95 % Student-t quantiles by degrees of freedom, index 0 being df = 1. Beyond the
    /// table the t distribution is within 1 % of the normal, so the normal quantile is used.
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

        // Averaged over the dimensions rather than taken as the worst of them. Each dimension has
        // to clear the same bar independently, so the mean is the fraction of the total work
        // done — and since every term is capped at 1, the mean still only reaches 1 when all
        // three are finished, so it cannot promise a lock it will not deliver. Reporting the
        // worst instead leaves the bar pinned at zero for the whole first half of a 3D scan,
        // while the height window is empty and the operator is busy measuring the footprint.
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
        // The point cloud only republishes a fit when it gains newly stable voxels. When it has
        // been silent this long the estimator can no longer change, so no amount of further
        // waiting would tighten the interval — the sequential procedure has to terminate on
        // exhausted evidence rather than on its precision target.
        if coverage.hasSupportPlane,
           result.sampleCount >= configuration.pilotSampleCount,
           let lastSampleTimestamp,
           now - lastSampleTimestamp >= configuration.evidenceTimeout {
            return converged(result, basis: .evidenceExhausted)
        }

        if !coverage.hasSupportPlane {
            result.limitingFactor = .waitingForSupportPlane
        } else if let starved = starvedAxis {
            // A window that is not filling is a viewpoint the operator has not held, so name the
            // view rather than reporting an anonymous sample count.
            result.limitingFactor = starved == .height && coverage.reportsSideViewSeparately
                ? .needsSideView
                : .needsTopView
            result.limitingAxis = starved
        } else if !hasFullWindows {
            result.limitingFactor = .collectingSamples
        } else if precisionProgress < 1 {
            // Reported before the plateau because a mean shift only measures drift once the
            // interval is tight; while the spread is still wide it mostly measures the spread.
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

    /// Difference between the means of the two halves of the window: the plateau test that stops
    /// a slow monotone growth from passing on a small standard error alone.
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

    /// The sequential sample-size formula behind the same rule: the n at which the half-width
    /// reaches `d` if the current spread holds, `n ≈ (t · s / d)²`. Used only to tell the operator
    /// roughly how much longer to hold, never to decide the stop.
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

    /// The dimension whose window is being left behind, if one clearly is. Windows filling
    /// together is ordinary progress; one stuck at nothing while another fills means the operator
    /// is holding a view that cannot measure it.
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

    /// Mean interval between observations of the *slowest* dimension — the one the rule will be
    /// waiting on. Used only to turn a remaining sample count into a rough number of seconds.
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
