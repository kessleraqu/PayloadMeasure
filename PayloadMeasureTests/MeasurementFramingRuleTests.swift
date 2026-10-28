import CoreGraphics
import Testing
@testable import PayloadMeasure

// The too-close warning is advisory and based on how much of the screen the object fills, not on
// distance.

struct MeasurementFramingRuleTests {
    private let portraitViewport = CGSize(width: 400, height: 800)

    /// A mask filling the given percentage of the shorter viewport side.
    private func box(fillingPercent percent: Double) -> CGRect {
        let width = CGFloat(percent / 100)
        return CGRect(
            x: (1 - width) / 2,
            y: 0.3,
            width: width,
            height: 0.1
        )
    }

    private func fill(_ percent: Double) -> Double? {
        MeasurementFramingRule.fillPercent(
            objectBoundingBox: box(fillingPercent: percent),
            viewportSize: portraitViewport
        )
    }

    // MARK: - The criterion

    @Test func theWarningStartsAtTheFirstTestedLevelShowingTheLoss() {
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: fill(52), wasTooClose: false))
        #expect(MeasurementFramingRule.isTooClose(fillPercent: fill(53), wasTooClose: false))
        #expect(MeasurementFramingRule.isTooClose(fillPercent: fill(65), wasTooClose: false))
    }

    /// The warning has hysteresis so it doesn't flicker around the threshold.
    @Test func theWarningHasToBeClearedNotJustGrazed() {
        #expect(MeasurementFramingRule.isTooClose(fillPercent: fill(52), wasTooClose: true))
        #expect(MeasurementFramingRule.isTooClose(fillPercent: fill(46), wasTooClose: true))
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: fill(45), wasTooClose: true))
        // Once cleared, it only comes back after crossing the full threshold again.
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: fill(52), wasTooClose: false))
    }

    /// The study found no loss further away, so being too far is never reported.
    @Test func beingTooFarAwayIsNeverReported() {
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: fill(25), wasTooClose: false))
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: fill(25), wasTooClose: true))
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: fill(5), wasTooClose: true))
    }

    @Test func nothingIsSaidWithoutAMaskToMeasure() {
        #expect(
            MeasurementFramingRule.fillPercent(
                objectBoundingBox: nil,
                viewportSize: portraitViewport
            ) == nil
        )
        #expect(
            MeasurementFramingRule.fillPercent(
                objectBoundingBox: box(fillingPercent: 60),
                viewportSize: .zero
            ) == nil
        )
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: nil, wasTooClose: false))
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: nil, wasTooClose: true))
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: .nan, wasTooClose: true))
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: 0, wasTooClose: true))
    }

    // MARK: - Why it is fill and not millimetres

    /// The rule must use exactly the same fill function as the framing study.
    @Test func theOnScreenMeasureIsTheStudysOwnMeasure() {
        let boundingBox = box(fillingPercent: 47)
        #expect(
            MeasurementFramingRule.fillPercent(
                objectBoundingBox: boundingBox,
                viewportSize: portraitViewport
            ) == FramingCalibrationProtocol.fillPercent(
                boundingBox: boundingBox,
                viewportSize: portraitViewport
            )
        )
    }

    /// Projected size scales with size / distance, so the same fill happens at different distances
    /// for different objects. These cases show why the rule uses fill rather than a distance.
    private func fillOfObject(
        sizeRelativeToStudyObject size: Double,
        distanceRelativeToTheCliff distance: Double
    ) -> Double {
        MeasurementFramingRule.tooCloseFillPercent * size / distance
    }

    @Test func aLargeObjectIsWarnedAtADistanceTheOldRuleCalledSafe() {
        // 3.5x the size at 2.5x the distance fills 74% of the screen: too close.
        let percent = fillOfObject(
            sizeRelativeToStudyObject: 3.5,
            distanceRelativeToTheCliff: 2.5
        )
        #expect(percent > MeasurementFramingRule.tooCloseFillPercent)
        #expect(MeasurementFramingRule.isTooClose(fillPercent: percent, wasTooClose: false))
    }

    @Test func aSmallObjectIsNotWarnedWhereTheOldRuleWouldHaveBeen() {
        // A third of the size at 86% of the distance fills 21%: fine, even though it's nearer than 350 mm.
        let percent = fillOfObject(
            sizeRelativeToStudyObject: 1.0 / 3,
            distanceRelativeToTheCliff: 0.86
        )
        #expect(percent < MeasurementFramingRule.releaseFillPercent)
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: percent, wasTooClose: true))
    }

    // MARK: - The distance the operator is told to stand at

    /// The recommended standing distance is the only value in millimetres, since it's shown before
    /// anything is on screen. Tied to the study's observed distances.
    private var accurateDistances: [Double] {
        zip(
            FramingCalibrationProtocol.targetFillPercentages,
            FramingCalibrationProtocol.observedDistanceMillimetres
        )
        .filter { $0.0 < MeasurementFramingRule.tooCloseFillPercent }
        .map(\.1)
    }

    private var degradedDistances: [Double] {
        zip(
            FramingCalibrationProtocol.targetFillPercentages,
            FramingCalibrationProtocol.observedDistanceMillimetres
        )
        .filter { $0.0 >= MeasurementFramingRule.tooCloseFillPercent }
        .map(\.1)
    }

    /// The recommendation is the span the study found accurate: about 450 to 650 mm.
    @Test func theRecommendedDistanceIsTheSpanTheStudyFoundAccurate() {
        let band = MeasurementFramingRule.observedAccurateDistanceMetres
        #expect(abs(band.lowerBound * 1000 - (accurateDistances.min() ?? .nan)) < 1e-9)
        #expect(abs(band.upperBound * 1000 - (accurateDistances.max() ?? .nan)) < 1e-9)
    }

    /// Framings that were less accurate were observed at 350 mm or nearer, so never recommend below
    /// 450 mm.
    @Test func theRecommendationNeverReachesIntoAFramingTheStudyFoundWorse() {
        #expect(!degradedDistances.isEmpty)
        for distance in degradedDistances {
            #expect(MeasurementFramingRule.observedAccurateDistanceMetres.lowerBound * 1000 > distance)
        }
    }

    /// The on-screen text has to match the band.
    @Test func theOperatorReadsTheBandTheDataGives() {
        let band = MeasurementFramingRule.observedAccurateDistanceMetres
        let near = Int((band.lowerBound * 100).rounded())
        let far = Int((band.upperBound * 100).rounded())
        #expect(MeasurementFramingRule.recommendedDistanceText == "\(near)–\(far) cm")
    }
}
