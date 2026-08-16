import XCTest
import simd
@testable import PayloadMeasure

@MainActor
final class ManualStudyWorkflowTests: XCTestCase {
    func testBothConditionOrdersFollowTheTwoPayloadBoxes() {
        let manualFirst = StudyStore()
        manualFirst.startRun(
            participantName: "manual-first",
            studyDate: Date(),
            flow: .batch,
            firstBox: .big,
            includesPractice: false,
            inputPlan: .both,
            firstInputMode: .manual
        )
        XCTAssertEqual(manualFirst.currentBox, .big)
        XCTAssertEqual(manualFirst.currentInputMode, .manual)
        XCTAssertEqual(manualFirst.nextInputMode, .augmentedReality)
        XCTAssertTrue(manualFirst.switchesInputModeAfterCurrentBox)
        XCTAssertEqual(StudyStore.nextBoxPassword, "130802")
        let runID = manualFirst.activeRun?.id

        manualFirst.advanceToNextBox()
        XCTAssertEqual(manualFirst.activeRun?.id, runID, "The second condition stays inside the same study run.")
        XCTAssertEqual(manualFirst.currentBox, .small)
        XCTAssertEqual(manualFirst.currentInputMode, .augmentedReality)

        let arFirst = StudyStore()
        arFirst.startRun(
            participantName: "ar-first",
            studyDate: Date(),
            flow: .batch,
            firstBox: .small,
            includesPractice: false,
            inputPlan: .both,
            firstInputMode: .augmentedReality
        )
        XCTAssertEqual(arFirst.currentInputMode, .augmentedReality)
        arFirst.advanceToNextBox()
        XCTAssertEqual(arFirst.currentInputMode, .manual)
    }

    func testSingleConditionPlansUseOneStandalonePayload() {
        let cases: [(StudyInputPlan, StudyInputMode)] = [
            (.arOnly, .augmentedReality),
            (.manualOnly, .manual)
        ]
        for (plan, expected) in cases {
            let store = StudyStore()
            store.startRun(
                participantName: plan.rawValue,
                studyDate: Date(),
                flow: .batch,
                firstBox: .big,
                includesPractice: false,
                inputPlan: plan,
                firstInputMode: expected.other
            )
            XCTAssertEqual(store.currentInputMode, expected)
            XCTAssertNil(store.nextInputMode)
            XCTAssertFalse(store.switchesInputModeAfterCurrentBox)
            XCTAssertTrue(store.isOnLastBox)
            XCTAssertEqual(store.activeRun?.boxOrder, [.big])
            store.finishRun()
            XCTAssertTrue(store.hasFinishedAllBoxes)
        }
    }

    func testPracticeUsesTheFirstInputConditionWithoutOpeningAResult() {
        let store = StudyStore()
        store.startRun(
            participantName: "practice-manual",
            studyDate: Date(),
            flow: .batch,
            firstBox: .small,
            includesPractice: true,
            inputPlan: .both,
            firstInputMode: .manual
        )
        XCTAssertTrue(store.isPractice)
        XCTAssertEqual(store.currentInputMode, .manual)
        XCTAssertTrue(store.activeRun?.boxes.isEmpty == true)

        store.startRealStudy()
        XCTAssertEqual(store.currentInputMode, .manual)
        XCTAssertEqual(store.activeRun?.boxes.first?.inputMode, .manual)
    }

    func testManualMeasurementsUseTheSharedPackingPipelineWithoutPhotos() throws {
        let engine = ObjectCaptureEngine()
        let packing = PackingStore()

        let id = try XCTUnwrap(
            engine.addManualMeasurement(
                name: "Power bank",
                sizeMillimetres: SIMD3(96, 65, 15)
            )
        )
        XCTAssertEqual(engine.measuredObjectIDs, [id])
        XCTAssertTrue(engine.finalizedObjectIDs.contains(id))
        XCTAssertEqual(engine.name(for: id), "Power bank")
        XCTAssertNil(engine.snapshotJPEGData(for: id), "Manual objects must not manufacture photos.")
        XCTAssertEqual(engine.capturedObjectsByID[id]?.sizeMillimetres, SIMD3(96, 65, 15))
        XCTAssertEqual(engine.capturedObjectsByID[id]?.sampleCount, 0)
        XCTAssertNotNil(engine.objectColor(for: id))

        XCTAssertTrue(
            engine.updateManualMeasurement(
                id: id,
                name: "Power bank edited",
                sizeMillimetres: SIMD3(97, 66, 16)
            )
        )
        XCTAssertEqual(engine.capturedObjectsByID[id]?.sizeMillimetres, SIMD3(97, 66, 16))

        packing.setIsItsOwnBox(true, for: id, in: engine)
        engine.updatePackedWeight(id: id, weightInGrams: 250)
        let packages = packing.packages(from: engine)
        XCTAssertEqual(packages.count, 1)
        XCTAssertEqual(packages.first?.id, id)
        XCTAssertEqual(packages.first?.name, "Power bank edited")
        XCTAssertEqual(packages.first?.size, SIMD3(97, 66, 16))
        XCTAssertEqual(try XCTUnwrap(packages.first?.massKilograms), 0.25, accuracy: 1e-12)
    }

    func testManualMeasurementValidationAndUniqueNames() {
        let engine = ObjectCaptureEngine()
        XCTAssertNil(
            engine.addManualMeasurement(name: "Invalid", sizeMillimetres: SIMD3(100, 0, 20))
        )
        XCTAssertNil(
            engine.addManualMeasurement(name: "", sizeMillimetres: SIMD3(100, 50, 20))
        )
        XCTAssertNotNil(
            engine.addManualMeasurement(name: "Mug", sizeMillimetres: SIMD3(100, 80, 80))
        )
        XCTAssertNil(
            engine.addManualMeasurement(name: " mug ", sizeMillimetres: SIMD3(100, 80, 80))
        )
    }

    func testReportRecordsTheToolUsedForEachPayload() throws {
        let store = StudyStore()
        store.startRun(
            participantName: "report",
            studyDate: Date(),
            flow: .batch,
            firstBox: .big,
            includesPractice: false,
            inputPlan: .both,
            firstInputMode: .manual
        )
        store.advanceToNextBox()
        store.finishRun()
        let report = try XCTUnwrap(store.activeRun).reportText()
        XCTAssertTrue(report.contains("Input tools : Manual measurement then AR measurement"))
        XCTAssertTrue(report.contains("Input     : Manual measurement"))
        XCTAssertTrue(report.contains("Input     : AR measurement"))
    }

    func testLegacyRunsRemainTwoBoxARStudies() throws {
        let legacy = StudyRun(
            id: UUID(),
            participantName: "legacy",
            studyDate: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            flow: MeasurementFlow.batch.rawValue,
            firstBox: .small
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(StudyRun.self, from: data)
        XCTAssertEqual(decoded.boxOrder, [.small, .big])
        XCTAssertEqual(decoded.inputModeOrder, [.augmentedReality, .augmentedReality])
    }
}
