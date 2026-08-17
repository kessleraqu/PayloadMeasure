import Testing
@testable import PayloadMeasure

struct MeasurementFramingRuleTests {
    @Test func distancesBelowTheStudyThresholdAreRejected() {
        #expect(MeasurementFramingRule.isTooClose(distanceMetres: 0.291))
        #expect(MeasurementFramingRule.isTooClose(distanceMetres: 0.349))
        #expect(!MeasurementFramingRule.isTooClose(distanceMetres: 0.350))
        #expect(!MeasurementFramingRule.isTooClose(distanceMetres: 0.450))
        #expect(!MeasurementFramingRule.isTooClose(distanceMetres: 0.632))
    }

    @Test func missingOrInvalidDepthDoesNotBlockTheStudy() {
        #expect(!MeasurementFramingRule.isTooClose(distanceMetres: nil))
        #expect(!MeasurementFramingRule.isTooClose(distanceMetres: 0))
        #expect(!MeasurementFramingRule.isTooClose(distanceMetres: .nan))
    }

    @Test func everyObjectUsesTheSamePreferredDistanceBand() {
        #expect(MeasurementFramingRule.guidance(distanceMetres: nil) == .unavailable)
        #expect(MeasurementFramingRule.guidance(distanceMetres: 0.399) == .moveFarther)
        #expect(MeasurementFramingRule.guidance(distanceMetres: 0.400) == .ready)
        #expect(MeasurementFramingRule.guidance(distanceMetres: 0.450) == .ready)
        #expect(MeasurementFramingRule.guidance(distanceMetres: 0.500) == .ready)
        #expect(MeasurementFramingRule.guidance(distanceMetres: 0.501) == .moveCloser)
    }
}
