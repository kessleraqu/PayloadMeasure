import XCTest
@testable import PayloadMeasure

// Checks the stopping rule described at the top of MeasurementConvergence.swift.

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

        // Small dimension: the 5 mm floor applies, since 1% of 100 mm is only 1 mm.
        XCTAssertEqual(configuration.halfWidthTolerance(forMean: 0.100), 0.0025, accuracy: 1e-9)
        // Large dimension: the relative term applies above 500 mm.
        XCTAssertEqual(configuration.halfWidthTolerance(forMean: 0.800), 0.004, accuracy: 1e-9)
        // Crossover where 1% equals the floor.
        XCTAssertEqual(configuration.halfWidthTolerance(forMean: 0.500), 0.0025, accuracy: 1e-9)
    }

    // MARK: - n is a sliding window and a minimum, not a maximum

    func testWindowSlidesAndTheMinimumBlocksAnEarlyFinish() {
        var monitor = MeasurementConvergenceMonitor()
        let configuration = MeasurementConvergenceMonitor.Configuration.default

        // Noiseless samples meet the precision test at once, so only the sample count can hold it back.
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

        // Well past the window size, still only reporting the window.
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
        // +-20 mm alternating: far too noisy for a 2.5 mm half-width at 24 samples.
        for index in 0..<48 {
            record(&monitor, value: index.isMultiple(of: 2) ? 0.180 : 0.220, at: Double(index) * 0.05)
        }
        let state = monitor.evaluate(coverage: coverage, now: 3.0)

        XCTAssertFalse(state.isConverged)
        XCTAssertEqual(state.limitingFactor, .precision)
        let halfWidth = try! XCTUnwrap(state.deviationInMeters)
        let tolerance = try! XCTUnwrap(state.toleranceInMeters)
        XCTAssertGreaterThan(halfWidth, tolerance)
        // t * s / sqrt(n) with s = 20 mm and n = 24 is about 8 mm; only check the order of magnitude.
        XCTAssertGreaterThan(halfWidth, 0.005)
        XCTAssertLessThan(halfWidth, 0.015)
    }

    // MARK: - The drift test is separate from the precision test

    /// For a ramp of step k the drift between window halves is k * n / 2. At n = 24 the tolerance is
    /// max(5 mm, 1% of 200 mm) / 2 = 2.5 mm, so the cut-off is about 0.208 mm per frame. Both sides
    /// are checked.
    func testASteadyRampIsRejectedOnlyOnceItsDriftExceedsTheTolerance() {
        func state(stepInMetres: Float) -> MeasurementConvergence {
            var monitor = MeasurementConvergenceMonitor()
            for index in 0..<24 {
                record(&monitor, value: 0.200 + Float(index) * stepInMetres, at: Double(index) * 0.05)
            }
            return monitor.evaluate(coverage: coverage, now: 1.2)
        }

        // 0.3 mm per frame: halves 3.6 mm apart, over the tolerance.
        let drifting = state(stepInMetres: 0.0003)
        XCTAssertFalse(
            drifting.isConverged,
            "A dimension still marching in one direction must not finish."
        )
        XCTAssertEqual(drifting.limitingFactor, .drifting)

        // 0.1 mm per frame: 1.2 mm apart, within tolerance, so accepted.
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

    /// The time limit must not report convergence without a support plane, otherwise the finish is
    /// refused and the measurement is stuck at 100%.
    func testTheTimeLimitDoesNotFinishAScanThatHasNoSupportPlane() {
        var monitor = MeasurementConvergenceMonitor()
        let configuration = MeasurementConvergenceMonitor.Configuration.default
        let withoutPlane = MeasurementConvergenceMonitor.Coverage(
            isMeasuring: true,
            hasSupportPlane: false,
            reportsSideViewSeparately: true
        )
        // Noisy and still arriving, so only the clock could end it.
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

    /// Noisy observations every 50 ms until past the time limit. Returns the last timestamp.
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
        // A few noisy samples, so precision is nowhere near met.
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
