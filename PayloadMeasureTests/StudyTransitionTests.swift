import XCTest
import ARKit
@testable import PayloadMeasure

// Moving to the next payload rebuilds the view hierarchy, so the packing sheet's onDismiss never
// runs. The suspension reason it set has to be cleared anyway, or the AR session stays paused.

@MainActor
final class StudyTransitionTests: XCTestCase {
    func testEachRoomScaleAROpeningHasFreshPresentationIdentity() {
        let solution = BaldiTestFixtures.solution(placements: [])

        let firstPayload = PackingARPresentation(solution: solution)
        let secondPayload = PackingARPresentation(solution: solution)

        XCTAssertNotEqual(
            firstPayload.id,
            secondPayload.id,
            "Each opening needs fresh placement/coordinator state while sharing the camera renderer."
        )
    }

    func testConfiguringAFreshSessionClearsAStalePackingSuspension() {
        let manager = ARSessionManager()
        manager.setPackingArrangementPresented(true)
        XCTAssertTrue(manager.isTrackingSuspended)

        // No dismissal, the view is just gone.
        manager.configure(ARSession())

        XCTAssertFalse(
            manager.isTrackingSuspended,
            "A rebuilt hierarchy has no packing sheet, so the session must not stay paused."
        )
    }

    func testApplicationInactivitySurvivesAReconfigure() {
        // This reason reflects real app state, so it must stay.
        let manager = ARSessionManager()
        manager.setApplicationActive(false)
        XCTAssertTrue(manager.isTrackingSuspended)

        manager.configure(ARSession())

        XCTAssertTrue(
            manager.isTrackingSuspended,
            "Being backgrounded is not something a view rebuild can resolve."
        )
    }

    func testBoxOrderAndSizesMatchTheStudyDesign() {
        XCTAssertEqual(StudyBox.big.sizeMillimetres, SIMD3(600, 200, 100))
        XCTAssertEqual(StudyBox.small.sizeMillimetres, SIMD3(200, 200, 100))
        XCTAssertEqual(StudyBox.big.other, .small)
        XCTAssertEqual(StudyBox.small.other, .big)

        let store = StudyStore()
        store.startRun(
            participantName: "P01",
            studyDate: Date(),
            flow: .sequential,
            firstBox: .small
        )
        XCTAssertTrue(store.isAwaitingParticipantStart)
        XCTAssertNil(store.currentBox)
        store.beginParticipantSession()
        XCTAssertEqual(store.currentBox, .small)
        XCTAssertFalse(store.isOnLastBox)

        store.advanceToNextBox()
        XCTAssertNil(store.currentBox, "The second payload waits behind a neutral Start screen.")
        XCTAssertEqual(store.scheduledBox, .big)
        XCTAssertTrue(store.isAwaitingParticipantStart)
        XCTAssertNil(store.currentPhase)
        store.beginParticipantSession()
        XCTAssertEqual(store.currentBox, .big, "The second box is always the other one.")
        XCTAssertTrue(store.isOnLastBox)

        store.finishRun()
        XCTAssertTrue(store.hasFinishedAllBoxes)
        let run = try! XCTUnwrap(store.activeRun)
        XCTAssertEqual(run.boxOrder, [.small, .big])
        XCTAssertTrue(store.saved.contains { $0.id == run.id }, "A finished run must be archived.")
    }

    func testSinglePayloadRunsFromThePreviousVersionKeepTheirOriginalMeaning() {
        var previousRun = StudyRun(
            id: UUID(),
            participantName: "Legacy single payload",
            studyDate: Date(),
            createdAt: Date(),
            flow: MeasurementFlow.batch.rawValue,
            firstBox: .big
        )
        previousRun.inputPlan = .manualOnly
        previousRun.firstInputMode = .manual

        XCTAssertNil(previousRun.includesBothPayloads)
        XCTAssertEqual(previousRun.boxOrder, [.big])
        XCTAssertEqual(previousRun.inputModeOrder, [.manual])

        previousRun.includesBothPayloads = true
        XCTAssertEqual(previousRun.boxOrder, [.big, .small])
        XCTAssertEqual(previousRun.inputModeOrder, [.manual, .manual])
    }

    /// A run always waits on the Start screen; nothing opens or is timed before the participant taps.
    func testTheFirstBoxOpensOnlyWhenTheParticipantStarts() {
        let store = StudyStore()
        store.startRun(
            participantName: "P04",
            studyDate: Date(),
            flow: .sequential,
            firstBox: .small
        )

        XCTAssertFalse(store.isTestMode)
        XCTAssertTrue(store.isAwaitingParticipantStart)
        XCTAssertFalse(store.hasActiveSession, "The admin handoff must not start the workflow or timer.")
        XCTAssertNil(store.currentBox, "The payload must stay closed until the participant taps Start.")
        store.beginParticipantSession()
        XCTAssertEqual(store.currentBox, .small)
        XCTAssertEqual(store.activeRun?.boxes.count, 1)
    }

    /// Test mode uses the chosen condition and payload, skips the handoff, and writes nothing to disk.
    func testTestModeRunsTheChosenPayloadAndIsNeverWrittenToDisk() throws {
        let store = StudyStore()
        let savedBefore = store.saved.map(\.id)

        store.startTestRun(box: .big, inputMode: .manual)

        XCTAssertTrue(store.isTestMode)
        XCTAssertFalse(
            store.isAwaitingParticipantStart,
            "Test mode goes straight into the workflow: there is no participant to hand over to."
        )
        XCTAssertTrue(store.hasActiveSession)
        XCTAssertEqual(store.currentBox, .big, "It takes the payload size chosen on the setup screen.")
        XCTAssertEqual(store.currentInputMode, .manual, "It takes the condition chosen on the setup screen.")
        XCTAssertEqual(store.activeModuleSizeMillimetres, StudyBox.big.sizeMillimetres)
        XCTAssertEqual(store.activeRun?.boxOrder, [.big], "A test is one payload, not the pair.")
        XCTAssertTrue(store.isOnLastBox)
        XCTAssertEqual(store.activeRun?.participantName, "")

        // Nothing a real run would record is accepted.
        let testRunID = try XCTUnwrap(store.activeRun?.id)
        store.beginPhase(.pack)
        store.recordCurrentBox(
            objects: [],
            loadedObjectIDs: [],
            unloadedObjectNames: ["test object"],
            packingMode: "test",
            centreOfMass: nil,
            unbalancingIndex: nil
        )
        XCTAssertNil(store.storePhoto(Data([0x01]), objectID: UUID()))
        XCTAssertEqual(store.saved.map(\.id), savedBefore, "A test run must not join the archive.")

        store.clearActiveRun()

        XCTAssertNil(store.activeRun)
        XCTAssertFalse(store.isTestMode)
        XCTAssertNotEqual(
            store.resumableRun?.id,
            testRunID,
            "A test run is not something to be offered back."
        )

        // Read back from disk, since persistence is what's being checked.
        let reloaded = StudyStore()
        XCTAssertFalse(
            reloaded.saved.contains { $0.id == testRunID },
            "Nothing from a test run may survive on disk."
        )
    }

    /// All three phases have to be timed and saved for both payloads.
    func testEveryPhaseIsTimedForBothBoxes() throws {
        let store = StudyStore()
        store.startRun(
            participantName: "P02",
            studyDate: Date(),
            flow: .batch,
            firstBox: .big
        )
        store.beginParticipantSession()

        for _ in 0..<2 {
            // Same order as the screens: measure, prepare, arrange.
            store.beginPhase(.pack)
            store.beginPhase(.payload)
            if store.isOnLastBox {
                store.finishRun()
            } else {
                store.advanceToNextBox()
                XCTAssertTrue(store.isAwaitingParticipantStart)
                XCTAssertNil(store.currentPhase)
                store.beginParticipantSession()
            }
        }

        let run = try XCTUnwrap(store.activeRun)
        for box in run.boxOrder {
            let result = try XCTUnwrap(run.result(for: box))
            for phase in StudyPhase.allCases {
                XCTAssertNotNil(
                    result.seconds(for: phase),
                    "\(box.shortTitle) is missing a time for \(phase.title)."
                )
            }
        }

        // Missing times show up as a dash in the report. Only check timing lines, since headings
        // contain a dash too.
        let timingLines = run.reportText()
            .components(separatedBy: "\n")
            .filter { line in
                StudyPhase.allCases.contains { line.hasPrefix("  \($0.title)") }
            }
        XCTAssertEqual(
            timingLines.count,
            StudyPhase.allCases.count * 2,
            "Every phase of both boxes must appear in the report."
        )
        for line in timingLines {
            XCTAssertFalse(line.contains("—"), "No timing was recorded for: \(line)")
        }
    }

    func testHandoffsStopOneTimerAndDoNotStartTheNextUntilExplicitStart() {
        let store = StudyStore()
        store.startRun(
            participantName: "timing-\(UUID().uuidString)",
            studyDate: Date(),
            flow: .batch,
            firstBox: .big,
            inputPlan: .arOnly,
            firstInputMode: .augmentedReality
        )

        XCTAssertNil(store.currentPhase, "Configuring the run must not start a timer.")
        XCTAssertEqual(store.elapsedSeconds(for: .measure), 0)
        store.beginParticipantSession()
        XCTAssertEqual(store.currentPhase, .measure, "Only the participant's Start tap begins measuring.")

        // End the short interval from beginParticipantSession, then use fixed dates.
        store.endCurrentPhase()
        let baseline = store.elapsedSeconds(for: .measure)
        let start = Date().addingTimeInterval(100)
        store.beginPhase(.measure, at: start)
        store.endCurrentPhase(at: start.addingTimeInterval(12))
        let stoppedMeasure = store.elapsedSeconds(for: .measure)
        XCTAssertEqual(stoppedMeasure - baseline, 12, accuracy: 0.0001)
        XCTAssertNil(store.currentPhase, "The packing handoff has no running timer.")
        XCTAssertEqual(
            store.elapsedSeconds(for: .measure, at: start.addingTimeInterval(1_000)),
            stoppedMeasure,
            accuracy: 0.0001,
            "Measuring must remain stopped while the white packing screen is waiting."
        )
        XCTAssertEqual(store.elapsedSeconds(for: .pack), 0)

        let packingStart = start.addingTimeInterval(200)
        store.beginPhase(.pack, at: packingStart)
        XCTAssertEqual(store.currentPhase, .pack)
        XCTAssertEqual(store.elapsedSeconds(for: .pack, at: packingStart), 0, accuracy: 0.0001)
        store.endCurrentPhase(at: packingStart.addingTimeInterval(7))
        XCTAssertEqual(store.elapsedSeconds(for: .pack), 7, accuracy: 0.0001)
        XCTAssertNil(store.currentPhase, "The loading handoff also has no running timer.")

        let loadingStart = packingStart.addingTimeInterval(100)
        store.beginPhase(.payload, at: loadingStart)
        XCTAssertEqual(store.currentPhase, .payload)
        XCTAssertEqual(store.elapsedSeconds(for: .payload, at: loadingStart), 0, accuracy: 0.0001)
    }

    func testSecondPayloadHasAWhiteHandoffAndIndependentTimers() {
        let store = StudyStore()
        store.startRun(
            participantName: "two-timers-\(UUID().uuidString)",
            studyDate: Date(),
            flow: .batch,
            firstBox: .small,
            inputPlan: .arOnly
        )
        store.beginParticipantSession()
        store.endCurrentPhase()
        let start = Date().addingTimeInterval(100)
        store.beginPhase(.measure, at: start)
        store.endCurrentPhase(at: start.addingTimeInterval(9))
        XCTAssertEqual(store.elapsedSeconds(for: .measure), 9, accuracy: 0.0001)

        store.advanceToNextBox()
        XCTAssertTrue(store.isAwaitingParticipantStart)
        XCTAssertEqual(store.scheduledBox, .big)
        XCTAssertNil(store.currentPhase)
        XCTAssertEqual(store.elapsedSeconds(for: .measure), 0)

        store.beginParticipantSession()
        XCTAssertEqual(store.currentBox, .big)
        XCTAssertEqual(store.currentPhase, .measure)
        XCTAssertEqual(store.elapsedSeconds(for: .measure), 0, accuracy: 0.05)
        XCTAssertEqual(
            store.activeRun?.result(for: .small)?.seconds(for: .measure) ?? -1,
            9,
            accuracy: 0.0001
        )
    }
}
