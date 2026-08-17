import XCTest
@testable import PayloadMeasure

// Pins the stopping rule to the condition written at the top of MeasurementConvergence.swift and
// repeated in PSEUDOCODE.md Part 5. If one of these fails, the documentation is now wrong.

final class MeasurementConvergenceRuleTests: XCTestCase {
    private let coverage = MeasurementConvergenceMonitor.Coverage(
        isMeasuring: true,
        hasSupportPlane: true,
        reportsSideViewSeparately: true
    )

    // MARK: - The tolerance is one combined threshold, not two alternative tests

    func testToleranceIsHalfOfMaxOfFloorAndRelativeTerm() {
        let configuration = MeasurementConvergenceMonitor.Configuration.default
        XCTAssertEqual(configuration.intervalWidthFloorInMeters, 0.005, accuracy: 1e-9)
        XCTAssertEqual(configuration.intervalWidthRelative, 0.01, accuracy: 1e-9)

        // Small dimension: the 5 mm floor governs, because 1% of 100 mm is only 1 mm.
        XCTAssertEqual(configuration.halfWidthTolerance(forMean: 0.100), 0.0025, accuracy: 1e-9)
        // Large dimension: the relative term takes over above 500 mm.
        XCTAssertEqual(configuration.halfWidthTolerance(forMean: 0.800), 0.004, accuracy: 1e-9)
        // The crossover is exactly where 1% equals the floor.
        XCTAssertEqual(configuration.halfWidthTolerance(forMean: 0.500), 0.0025, accuracy: 1e-9)
    }

    // MARK: - n is a sliding window and a minimum, not a maximum

    func testWindowSlidesAndTheMinimumBlocksAnEarlyFinish() {
        var monitor = MeasurementConvergenceMonitor()
        let configuration = MeasurementConvergenceMonitor.Configuration.default

        // Perfectly noiseless samples: the precision test is satisfied immediately, so anything
        // stopping this before the minimum could only be the sample count.
        for index in 0..<(configuration.minimumSampleCount - 1) {
            record(&monitor, value: 0.200, at: Double(index) * 0.05)
        }
        var state = monitor.evaluate(coverage: coverage, now: 1.0)
        XCTAssertFalse(state.isConverged)
        XCTAssertEqual(state.limitingFactor, .collectingSamples)

        record(&monitor, value: 0.200, at: 5.0)
        state = monitor.evaluate(coverage: coverage, now: 5.0)
        XCTAssertTrue(state.isConverged)
        XCTAssertEqual(state.basis, .precisionTarget)

        // Far more than the window: still fine, and still reporting only the window's worth.
        for index in 0..<200 {
            record(&monitor, value: 0.200, at: 6.0 + Double(index) * 0.05)
        }
        state = monitor.evaluate(coverage: coverage, now: 20.0)
        XCTAssertEqual(state.sampleCount, configuration.windowSize, "n is capped by the window.")
        XCTAssertTrue(state.isConverged)
    }

    // MARK: - The precision test is the CI half-width

    func testNoisyMeasurementsDoNotFinishAndTheirHalfWidthIsReported() {
        var monitor = MeasurementConvergenceMonitor()
        // ±20 mm alternating: s is far too large for a 2.5 mm half-width at 24 samples.
        for index in 0..<48 {
            record(&monitor, value: index.isMultiple(of: 2) ? 0.180 : 0.220, at: Double(index) * 0.05)
        }
        let state = monitor.evaluate(coverage: coverage, now: 3.0)

        XCTAssertFalse(state.isConverged)
        XCTAssertEqual(state.limitingFactor, .precision)
        let halfWidth = try! XCTUnwrap(state.deviationInMeters)
        let tolerance = try! XCTUnwrap(state.toleranceInMeters)
        XCTAssertGreaterThan(halfWidth, tolerance)
        // t·s/√n with s = 20 mm and n = 24 lands near 8 mm; assert the order of magnitude only.
        XCTAssertGreaterThan(halfWidth, 0.005)
        XCTAssertLessThan(halfWidth, 0.015)
    }

    // MARK: - The drift test is separate from the precision test

    /// δₙ is the gap between the two halves of the window, and for a ramp of step `k` over n samples
    /// that is exactly k·n/2. At n = 24 the tolerance dₙ is max(5 mm, 1%·200 mm)/2 = 2.5 mm, so the
    /// drift test turns over at a step of 2.5/12 ≈ 0.208 mm per frame. Both sides of that are checked,
    /// because a threshold nobody has stood on either side of is not really tested.
    func testASteadyRampIsRejectedOnlyOnceItsDriftExceedsTheTolerance() {
        func state(stepInMetres: Float) -> MeasurementConvergence {
            var monitor = MeasurementConvergenceMonitor()
            for index in 0..<24 {
                record(&monitor, value: 0.200 + Float(index) * stepInMetres, at: Double(index) * 0.05)
            }
            return monitor.evaluate(coverage: coverage, now: 1.2)
        }

        // 0.3 mm per frame: the halves are 3.6 mm apart, past the 2.5 mm tolerance.
        let drifting = state(stepInMetres: 0.0003)
        XCTAssertFalse(
            drifting.isConverged,
            "A dimension still marching in one direction must not finish."
        )
        XCTAssertEqual(drifting.limitingFactor, .drifting)

        // 0.1 mm per frame: 1.2 mm apart, inside the tolerance. Still a ramp, but a ramp small enough
        // that the rule has declared it does not care — accepting it is the documented behaviour.
        let settled = state(stepInMetres: 0.0001)
        XCTAssertTrue(
            settled.isConverged,
            "Drift within the declared interval is what the rule says is good enough."
        )
    }

    // MARK: - Every dimension must clear it, and a support plane is required

    func testOneUnsettledDimensionBlocksTheWholeMeasurement() {
        var monitor = MeasurementConvergenceMonitor()
        for index in 0..<24 {
            let time = Double(index) * 0.05
            monitor.record(.width, value: 0.200, at: time)
            monitor.record(.depth, value: 0.150, at: time)
            monitor.record(.height, value: index.isMultiple(of: 2) ? 0.080 : 0.120, at: time)
        }
        let state = monitor.evaluate(coverage: coverage, now: 1.2)
        XCTAssertFalse(state.isConverged)
        XCTAssertEqual(state.limitingAxis, .height)
    }

    func testWithoutASupportPlaneNothingFinishes() {
        var monitor = MeasurementConvergenceMonitor()
        for index in 0..<40 {
            record(&monitor, value: 0.200, at: Double(index) * 0.05)
        }
        let withoutPlane = MeasurementConvergenceMonitor.Coverage(
            isMeasuring: true,
            hasSupportPlane: false,
            reportsSideViewSeparately: true
        )
        let state = monitor.evaluate(coverage: withoutPlane, now: 2.0)
        XCTAssertFalse(state.isConverged)
        XCTAssertEqual(state.limitingFactor, .waitingForSupportPlane)
    }

    /// The ten-second limit is an exit, not an exception: it may not declare a measurement converged
    /// while the missing support plane would make the finish be refused. That combination is what left
    /// small objects reading 100% for ever.
    func testTheTimeLimitDoesNotFinishAScanThatHasNoSupportPlane() {
        var monitor = MeasurementConvergenceMonitor()
        let configuration = MeasurementConvergenceMonitor.Configuration.default
        let withoutPlane = MeasurementConvergenceMonitor.Coverage(
            isMeasuring: true,
            hasSupportPlane: false,
            reportsSideViewSeparately: true
        )
        // Deliberately noisy, and still arriving, so nothing but the clock could ever end this.
        let elapsed = recordPastTheTimeLimit(&monitor)
        let state = monitor.evaluate(coverage: withoutPlane, now: elapsed)
        XCTAssertGreaterThanOrEqual(elapsed, configuration.timeLimit)

        XCTAssertFalse(state.isConverged)
        XCTAssertEqual(state.limitingFactor, .waitingForSupportPlane)
        XCTAssertLessThan(
            state.progress,
            1,
            "A full bar promises the measurement is over, and here it cannot be."
        )
    }

    func testTheTimeLimitStillFinishesAScanThatHasOne() {
        var monitor = MeasurementConvergenceMonitor()
        let elapsed = recordPastTheTimeLimit(&monitor)
        let state = monitor.evaluate(coverage: coverage, now: elapsed)

        XCTAssertTrue(state.isConverged)
        XCTAssertEqual(state.basis, .timeLimit)
        XCTAssertEqual(state.progress, 1, accuracy: 1e-9)
    }

    /// Noisy observations arriving every 50 ms until past the ten-second limit: the precision test can
    /// never be met and the stale-evidence exit can never fire, so the clock is the only exit left.
    /// Returns the timestamp of the last observation.
    private func recordPastTheTimeLimit(
        _ monitor: inout MeasurementConvergenceMonitor
    ) -> TimeInterval {
        let interval = 0.05
        let count = Int(
            (MeasurementConvergenceMonitor.Configuration.default.timeLimit / interval).rounded(.up)
        ) + 2
        for index in 0..<count {
            record(
                &monitor,
                value: index.isMultiple(of: 2) ? 0.180 : 0.230,
                at: Double(index) * interval
            )
        }
        return Double(count - 1) * interval
    }

    // MARK: - The second exit

    func testStaleEvidenceFinishesTheScanWithoutThePrecisionTest() {
        var monitor = MeasurementConvergenceMonitor()
        let configuration = MeasurementConvergenceMonitor.Configuration.default
        // Only a handful of samples, and deliberately noisy, so precision is nowhere near met.
        for index in 0..<configuration.pilotSampleCount {
            record(&monitor, value: index.isMultiple(of: 2) ? 0.180 : 0.230, at: Double(index) * 0.05)
        }
        let lastSample = Double(configuration.pilotSampleCount - 1) * 0.05

        var state = monitor.evaluate(coverage: coverage, now: lastSample + 1.0)
        XCTAssertFalse(state.isConverged, "Still inside the timeout.")

        state = monitor.evaluate(
            coverage: coverage,
            now: lastSample + configuration.evidenceTimeout + 0.1
        )
        XCTAssertTrue(state.isConverged)
        XCTAssertEqual(
            state.basis,
            .evidenceExhausted,
            "This exit is a project safeguard, not part of any sequential stopping rule."
        )
    }

    private func record(
        _ monitor: inout MeasurementConvergenceMonitor,
        value: Float,
        at time: TimeInterval
    ) {
        for axis in MeasurementAxis.allCases {
            monitor.record(axis, value: value, at: time)
        }
    }
}
