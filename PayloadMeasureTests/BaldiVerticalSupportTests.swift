import XCTest
import simd
@testable import PayloadMeasure

final class BaldiVerticalSupportTests: XCTestCase {
    func testFloorPackageIsFullySupported() {
        let target = BaldiTestFixtures.placement(origin: .zero)

        let report = BaldiVerticalSupport.report(for: target, among: [target])

        XCTAssertTrue(report.isFloorSupported)
        XCTAssertTrue(report.isFullySupported)
        XCTAssertEqual(report.supportedArea, 100, accuracy: 1e-9)
        XCTAssertEqual(report.requiredArea, 100, accuracy: 1e-9)
        XCTAssertEqual(report.fraction, 1, accuracy: 1e-9)
        XCTAssertTrue(report.supporterIDs.isEmpty)
    }

    func testOneSupporterCoveringTheWholeBottomFacePasses() {
        let supporter = BaldiTestFixtures.placement(
            name: "Supporter",
            origin: .zero,
            size: SIMD3(10, 10, 5)
        )
        let target = BaldiTestFixtures.placement(
            name: "Target",
            origin: SIMD3(0, 0, 5),
            size: SIMD3(10, 10, 4)
        )

        let report = BaldiVerticalSupport.report(for: target, among: [supporter, target])

        XCTAssertFalse(report.isFloorSupported)
        XCTAssertTrue(report.isFullySupported)
        XCTAssertEqual(report.supportedArea, 100, accuracy: 1e-9)
        XCTAssertEqual(report.supporterIDs, [supporter.id])
    }

    func testAdjacentSupportersCanTileTheWholeBottomFace() {
        let left = BaldiTestFixtures.placement(
            name: "Left",
            origin: .zero,
            size: SIMD3(5, 10, 5)
        )
        let right = BaldiTestFixtures.placement(
            name: "Right",
            origin: SIMD3(5, 0, 0),
            size: SIMD3(5, 10, 5)
        )
        let target = BaldiTestFixtures.placement(
            name: "Target",
            origin: SIMD3(0, 0, 5),
            size: SIMD3(10, 10, 5)
        )

        let report = BaldiVerticalSupport.report(for: target, among: [left, right, target])

        XCTAssertTrue(report.isFullySupported)
        XCTAssertEqual(report.supportedArea, 100, accuracy: 1e-9)
        XCTAssertEqual(Set(report.supporterIDs), Set([left.id, right.id]))
    }

    func testNinetyNinePercentSupportFails() {
        let supporter = BaldiTestFixtures.placement(
            origin: .zero,
            size: SIMD3(99, 100, 5)
        )
        let target = BaldiTestFixtures.placement(
            origin: SIMD3(0, 0, 5),
            size: SIMD3(100, 100, 5)
        )

        let report = BaldiVerticalSupport.report(for: target, among: [supporter, target])

        XCTAssertFalse(report.isFullySupported)
        XCTAssertEqual(report.supportedArea, 9_900, accuracy: 1e-9)
        XCTAssertEqual(report.fraction, 0.99, accuracy: 1e-9)
    }

    func testOverhangFailsEvenWhenMostOfTheFootprintTouches() {
        let supporter = BaldiTestFixtures.placement(
            origin: .zero,
            size: SIMD3(10, 10, 5)
        )
        let target = BaldiTestFixtures.placement(
            origin: SIMD3(1, 0, 5),
            size: SIMD3(10, 10, 5)
        )

        let report = BaldiVerticalSupport.report(for: target, among: [supporter, target])

        XCTAssertFalse(report.isFullySupported)
        XCTAssertEqual(report.fraction, 0.9, accuracy: 1e-9)
    }

    func testFloatingPackageAndMaterialVerticalGapFail() {
        let supporter = BaldiTestFixtures.placement(
            origin: .zero,
            size: SIMD3(10, 10, 5)
        )
        let floating = BaldiTestFixtures.placement(
            origin: SIMD3(0, 0, 20),
            size: SIMD3(10, 10, 5)
        )
        let gapped = BaldiTestFixtures.placement(
            origin: SIMD3(0, 0, 5.001),
            size: SIMD3(10, 10, 5)
        )

        let floatingReport = BaldiVerticalSupport.report(for: floating, among: [supporter, floating])
        let gappedReport = BaldiVerticalSupport.report(for: gapped, among: [supporter, gapped])

        XCTAssertFalse(floatingReport.isFullySupported)
        XCTAssertEqual(floatingReport.supportedArea, 0, accuracy: 1e-9)
        XCTAssertFalse(gappedReport.isFullySupported)
        XCTAssertEqual(gappedReport.supportedArea, 0, accuracy: 1e-9)
    }

    func testContactWithinNumericalTolerancePasses() {
        let supporter = BaldiTestFixtures.placement(
            origin: .zero,
            size: SIMD3(10, 10, 5)
        )
        let target = BaldiTestFixtures.placement(
            origin: SIMD3(0, 0, 5 + BaldiVerticalSupport.contactTolerance / 2),
            size: SIMD3(10, 10, 5)
        )

        let report = BaldiVerticalSupport.report(for: target, among: [supporter, target])

        XCTAssertTrue(report.isFullySupported)
        XCTAssertEqual(report.fraction, 1, accuracy: 1e-9)
    }

    func testSupportersAtDifferentTopHeightsAreNotCombined() {
        let contacting = BaldiTestFixtures.placement(
            name: "Contacting",
            origin: .zero,
            size: SIMD3(5, 10, 10)
        )
        let tooLow = BaldiTestFixtures.placement(
            name: "Too low",
            origin: SIMD3(5, 0, 0),
            size: SIMD3(5, 10, 9)
        )
        let target = BaldiTestFixtures.placement(
            origin: SIMD3(0, 0, 10),
            size: SIMD3(10, 10, 5)
        )

        let report = BaldiVerticalSupport.report(
            for: target,
            among: [contacting, tooLow, target]
        )

        XCTAssertFalse(report.isFullySupported)
        XCTAssertEqual(report.fraction, 0.5, accuracy: 1e-9)
        XCTAssertEqual(report.supporterIDs, [contacting.id])
    }

    func testRotatedFootprintDimensionsAreUsed() {
        let sourceSize = SIMD3(2, 3, 4)
        let rotation = BaldiRotation.all[4]
        let rotated = rotation.size(of: sourceSize)
        let supporter = BaldiTestFixtures.placement(
            origin: .zero,
            size: SIMD3(rotated.x, rotated.y, 2)
        )
        let target = BaldiTestFixtures.placement(
            origin: SIMD3(0, 0, 2),
            size: rotated,
            rotation: rotation
        )

        let report = BaldiVerticalSupport.report(for: target, among: [supporter, target])

        XCTAssertTrue(report.isFullySupported)
        XCTAssertEqual(report.requiredArea, Double(rotated.x * rotated.y), accuracy: 1e-9)
    }

    func testRectangleUnionDoesNotDoubleCountOverlappingSupporters() {
        let first = BaldiTestFixtures.placement(
            origin: .zero,
            size: SIMD3(5, 10, 5)
        )
        let duplicateFootprint = BaldiTestFixtures.placement(
            origin: .zero,
            size: SIMD3(5, 10, 5)
        )
        let target = BaldiTestFixtures.placement(
            origin: SIMD3(0, 0, 5),
            size: SIMD3(10, 10, 5)
        )

        let report = BaldiVerticalSupport.report(
            for: target,
            among: [first, duplicateFootprint, target]
        )

        XCTAssertFalse(report.isFullySupported)
        XCTAssertEqual(report.supportedArea, 50, accuracy: 1e-9)
        XCTAssertEqual(report.fraction, 0.5, accuracy: 1e-9)
    }

    func testCompleteSupportChainPasses() {
        let bottom = BaldiTestFixtures.placement(
            name: "Bottom",
            origin: .zero,
            size: SIMD3(10, 10, 5)
        )
        let middle = BaldiTestFixtures.placement(
            name: "Middle",
            origin: SIMD3(0, 0, 5),
            size: SIMD3(10, 10, 5)
        )
        let top = BaldiTestFixtures.placement(
            name: "Top",
            origin: SIMD3(0, 0, 10),
            size: SIMD3(10, 10, 5)
        )

        XCTAssertTrue(BaldiVerticalSupport.allFullySupported([bottom, middle, top]))
        XCTAssertTrue(
            BaldiVerticalSupport.reports(for: [bottom, middle, top])
                .allSatisfy(\.isFullySupported)
        )
    }

    func testUnsupportedMiddlePackageInvalidatesTheChain() {
        let bottom = BaldiTestFixtures.placement(
            name: "Bottom",
            origin: .zero,
            size: SIMD3(5, 10, 5)
        )
        let middle = BaldiTestFixtures.placement(
            name: "Middle",
            origin: SIMD3(0, 0, 5),
            size: SIMD3(10, 10, 5)
        )
        let top = BaldiTestFixtures.placement(
            name: "Top",
            origin: SIMD3(0, 0, 10),
            size: SIMD3(10, 10, 5)
        )

        let reports = BaldiVerticalSupport.reports(for: [bottom, middle, top])

        XCTAssertFalse(BaldiVerticalSupport.allFullySupported([bottom, middle, top]))
        XCTAssertFalse(reports[1].isFullySupported)
        XCTAssertTrue(reports[2].isFullySupported)
    }
}
