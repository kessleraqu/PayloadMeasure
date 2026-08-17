import XCTest
import simd
@testable import PayloadMeasure

@MainActor
final class ManualStudyWorkflowTests: XCTestCase {
    func testARAndManualAreSeparateTwoPayloadRuns() {
        let participant = "separate-\(UUID().uuidString)"
        let store = StudyStore()
        store.startRun(
            participantName: participant,
            studyDate: Date(),
            flow: .batch,
            firstBox: .big,
            includesPractice: false,
            inputPlan: .manualOnly,
            firstInputMode: .manual
        )
        XCTAssertTrue(store.isAwaitingParticipantStart)
        store.beginParticipantSession()
        XCTAssertEqual(store.currentBox, .big)
        XCTAssertEqual(store.currentInputMode, .manual)
        XCTAssertEqual(store.nextInputMode, .manual)
        XCTAssertFalse(store.isOnLastBox)
        XCTAssertEqual(StudyStore.nextBoxPassword, "130802")
        store.advanceToNextBox()
        XCTAssertTrue(store.isAwaitingParticipantStart)
        store.beginParticipantSession()
        XCTAssertEqual(store.currentBox, .small)
        XCTAssertEqual(store.currentInputMode, .manual)
        XCTAssertTrue(store.isOnLastBox)
        store.finishRun()
        store.returnToSetupAfterCompletion()
        XCTAssertNil(store.activeRun, "Finishing returns to setup instead of opening another condition.")
        XCTAssertNotNil(store.savedRun(named: participant, inputMode: .manual))
        XCTAssertNil(
            store.savedRun(named: participant, inputMode: .augmentedReality),
            "The first condition must not block setup for the same participant's other condition."
        )

        store.startRun(
            participantName: participant,
            studyDate: Date(),
            flow: .batch,
            firstBox: .small,
            includesPractice: false,
            inputPlan: .arOnly,
            firstInputMode: .augmentedReality
        )
        store.beginParticipantSession()
        XCTAssertEqual(store.currentBox, .small)
        XCTAssertEqual(store.currentInputMode, .augmentedReality)
        XCTAssertFalse(store.isOnLastBox)
        store.advanceToNextBox()
        store.beginParticipantSession()
        XCTAssertEqual(store.currentBox, .big)
        XCTAssertTrue(store.isOnLastBox)
        store.finishRun()
        XCTAssertNotNil(store.savedRun(named: participant, inputMode: .manual))
        XCTAssertNotNil(store.savedRun(named: participant, inputMode: .augmentedReality))
    }

    func testSelectedConditionRepeatsAcrossBothPayloads() {
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
            XCTAssertTrue(store.isAwaitingParticipantStart)
            XCTAssertFalse(store.hasActiveSession)
            store.beginParticipantSession()
            XCTAssertEqual(store.currentInputMode, expected)
            XCTAssertEqual(store.nextInputMode, expected)
            XCTAssertFalse(store.switchesInputModeAfterCurrentBox)
            XCTAssertFalse(store.isOnLastBox)
            XCTAssertEqual(store.activeRun?.boxOrder, [.big, .small])
            store.advanceToNextBox()
            XCTAssertTrue(store.isAwaitingParticipantStart)
            XCTAssertNil(store.currentPhase)
            store.beginParticipantSession()
            XCTAssertEqual(store.currentInputMode, expected)
            XCTAssertTrue(store.isOnLastBox)
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
            inputPlan: .manualOnly,
            firstInputMode: .manual
        )
        XCTAssertTrue(store.isPractice)
        XCTAssertEqual(store.currentInputMode, .manual)
        XCTAssertTrue(store.activeRun?.boxes.isEmpty == true)

        store.beginParticipantSession()
        store.startRealStudy()
        XCTAssertTrue(store.isAwaitingParticipantStart)
        store.beginParticipantSession()
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

    func testManualMeasurementCanRemainUnnamedUntilPacking() throws {
        let engine = ObjectCaptureEngine()
        let id = try XCTUnwrap(
            engine.addManualMeasurement(sizeMillimetres: SIMD3(123, 70, 37))
        )
        XCTAssertNil(engine.name(for: id))
        engine.updateName(id: id, name: "Mouse")
        XCTAssertEqual(engine.name(for: id), "Mouse")
        XCTAssertTrue(
            engine.updateManualMeasurement(id: id, sizeMillimetres: SIMD3(124, 71, 38))
        )
        XCTAssertEqual(engine.name(for: id), "Mouse")
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

    func testReportAndFilenameRecordTheSelectedStandaloneCondition() throws {
        let store = StudyStore()
        store.startRun(
            participantName: "report",
            studyDate: Date(),
            flow: .batch,
            firstBox: .big,
            includesPractice: false,
            inputPlan: .manualOnly,
            firstInputMode: .manual
        )
        store.beginParticipantSession()
        store.finishRun()
        let run = try XCTUnwrap(store.activeRun)
        let report = run.reportText()
        XCTAssertTrue(report.contains("Input tools : Manual measurement"))
        XCTAssertTrue(report.contains("Input     : Manual measurement"))
        XCTAssertFalse(report.contains("Input     : AR measurement"))
        // The condition is part of the run's name, so it is part of its folder and its report.
        XCTAssertEqual(run.exportBaseName, "report no AR")
        XCTAssertTrue(run.reportFileName.hasPrefix("report no AR"))
        XCTAssertTrue(run.reportFileName.hasSuffix(".txt"))
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
