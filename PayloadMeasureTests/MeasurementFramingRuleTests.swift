import Testing
@testable import PayloadMeasure

// The distance band is advice. Nothing in the measuring screen is gated on it: an object with a mask on
// screen can be measured, and a measurement can finish, from wherever the operator is standing. These
// tests pin the band itself, which is what the on-screen recommendation is derived from.

struct MeasurementFramingRuleTests {
    @Test func theBandIsTheSameForEveryObject() {
        #expect(MeasurementFramingRule.guidance(distanceMetres: nil) == .unavailable)
        #expect(MeasurementFramingRule.guidance(distanceMetres: 0.399) == .moveFarther)
        #expect(MeasurementFramingRule.guidance(distanceMetres: 0.400) == .ready)
        #expect(MeasurementFramingRule.guidance(distanceMetres: 0.450) == .ready)
        #expect(MeasurementFramingRule.guidance(distanceMetres: 0.500) == .ready)
        #expect(MeasurementFramingRule.guidance(distanceMetres: 0.501) == .moveCloser)
    }

    /// Kept as the description of where accuracy falls off, and reported as such. It no longer refuses
    /// anything: a small object has to be closer before there is enough of it to measure, and a rule the
    /// operator cannot satisfy is worse than a reading taken slightly too close.
    @Test func belowTheAccuracyThresholdIsReportedNotRefused() {
        #expect(MeasurementFramingRule.isBelowAccuracyThreshold(distanceMetres: 0.291))
        #expect(MeasurementFramingRule.isBelowAccuracyThreshold(distanceMetres: 0.349))
        #expect(!MeasurementFramingRule.isBelowAccuracyThreshold(distanceMetres: 0.350))
        #expect(!MeasurementFramingRule.isBelowAccuracyThreshold(distanceMetres: 0.632))
    }

    @Test func missingOrInvalidDepthSaysNothing() {
        #expect(!MeasurementFramingRule.isBelowAccuracyThreshold(distanceMetres: nil))
        #expect(!MeasurementFramingRule.isBelowAccuracyThreshold(distanceMetres: 0))
        #expect(!MeasurementFramingRule.isBelowAccuracyThreshold(distanceMetres: .nan))
    }
}
