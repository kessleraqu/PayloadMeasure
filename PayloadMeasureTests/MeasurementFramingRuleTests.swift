import CoreGraphics
import Testing
@testable import PayloadMeasure

// Being too close is advice. Nothing on the measuring screen is gated on it: an object with a mask on
// screen can be measured, and a measurement can finish, from wherever the operator is standing. These
// tests pin the criterion the on-screen warning is derived from, and — the point of the rule — that it
// is a property of the object's own image rather than of how far away some surface is.

struct MeasurementFramingRuleTests {
    private let portraitViewport = CGSize(width: 400, height: 800)

    /// A mask filling the given percentage of the shorter viewport dimension, which is the study's own
    /// definition of fill.
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

    /// Fill sits near a threshold for much of a scan, so a bare comparison turns the message on and off
    /// several times a second. The release is the midpoint of the untested 38–53% interval the cliff
    /// lies in — wide enough to settle, and not a number invented to make the flicker stop.
    @Test func theWarningHasToBeClearedNotJustGrazed() {
        #expect(MeasurementFramingRule.isTooClose(fillPercent: fill(52), wasTooClose: true))
        #expect(MeasurementFramingRule.isTooClose(fillPercent: fill(46), wasTooClose: true))
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: fill(45), wasTooClose: true))
        // And having cleared it, the operator is not warned again until the full threshold is crossed.
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: fill(52), wasTooClose: false))
    }

    /// The study found accuracy broadly stable across its three wider framings, so there is nothing to
    /// tell an operator who is standing further back. There is deliberately no API to ask.
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

    /// The rule has to score the operator's framing with the identical function the study scored its own
    /// readings with. A threshold read off one measure and applied to a lookalike is not supported by the
    /// data, however close the two look — and the two do look close.
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

    /// The reason this is not "closer than 350 mm".
    ///
    /// 350 mm is where 53% fill landed *for the objects the study used*. Under a pinhole camera the
    /// projected size goes as size ÷ distance, so the same 53% arrives at a completely different
    /// distance for an object of a different size. Both cases below are ones the distance rule got
    /// backwards, and both come out right when the study is read in the variable it controlled.
    private func fillOfObject(
        sizeRelativeToStudyObject size: Double,
        distanceRelativeToTheCliff distance: Double
    ) -> Double {
        MeasurementFramingRule.tooCloseFillPercent * size / distance
    }

    @Test func aLargeObjectIsWarnedAtADistanceTheOldRuleCalledSafe() {
        // Three and a half times the size, at two and a half times the distance: 2.6 m for a study
        // object measured at 350 mm at the cliff, so far outside any "too close" the millimetres could
        // express — and filling 74% of the screen, well past where accuracy was lost.
        let percent = fillOfObject(
            sizeRelativeToStudyObject: 3.5,
            distanceRelativeToTheCliff: 2.5
        )
        #expect(percent > MeasurementFramingRule.tooCloseFillPercent)
        #expect(MeasurementFramingRule.isTooClose(fillPercent: percent, wasTooClose: false))
    }

    @Test func aSmallObjectIsNotWarnedWhereTheOldRuleWouldHaveBeen() {
        // A third of the size, held at 86% of the cliff distance — inside 350 mm, so the distance rule
        // warned — and occupying 21% of the screen, which is less than the widest framing the study
        // tested and found accurate. Bringing a small part closer is how it gets enough pixels to
        // measure at all, and it is the framing that decides accuracy, not the range.
        let percent = fillOfObject(
            sizeRelativeToStudyObject: 1.0 / 3,
            distanceRelativeToTheCliff: 0.86
        )
        #expect(percent < MeasurementFramingRule.releaseFillPercent)
        #expect(!MeasurementFramingRule.isTooClose(fillPercent: percent, wasTooClose: true))
    }
}
