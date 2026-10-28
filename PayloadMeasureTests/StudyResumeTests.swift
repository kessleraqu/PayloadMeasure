import XCTest
@testable import PayloadMeasure

// Resuming a run after the app quit mid-session (crash, force quit, battery).

@MainActor
final class StudyResumeTests: XCTestCase {
    /// Each test uses its own participant name and deletes the run afterwards, since the store uses
    /// the real Documents folder.
    private var startedRunIDs: [UUID] = []

    override func tearDown() {
        let store = StudyStore()
        for id in startedRunIDs {
            store.delete(runID: id)
        }
        startedRunIDs = []
        super.tearDown()
    }

    private func makeStartedRun(named name: String) -> (store: StudyStore, run: StudyRun) {
        let store = StudyStore()
        store.startRun(
            participantName: name,
            studyDate: Date(),
            flow: .batch,
            firstBox: .big,
            inputPlan: .arOnly,
            firstInputMode: .augmentedReality
        )
        store.beginParticipantSession()
        let run = store.activeRun!
        startedRunIDs.append(run.id)
        return (store, run)
    }

    /// After a crash the run is on disk, unfinished, and nothing is active.
    func testAnUnfinishedRunOnDiskIsOfferedForResuming() {
        let name = "resume-\(UUID().uuidString.prefix(8))"
        let started = makeStartedRun(named: name)
        XCTAssertNil(
            started.store.resumableRun,
            "A run already in progress is not something to resume."
        )

        let afterRelaunch = StudyStore()
        // Other tests can leave unfinished runs in the simulator, so only check that something is offered,
        // this run is a candidate, and finished or abandoned runs never are.
        let offered = try! XCTUnwrap(afterRelaunch.resumableRun)
        XCTAssertFalse(offered.isComplete)
        XCTAssertNil(offered.abandonedAt)
        let mine = try! XCTUnwrap(afterRelaunch.saved.first { $0.id == started.run.id })
        XCTAssertFalse(mine.isComplete)
        XCTAssertNil(mine.abandonedAt)
        XCTAssertFalse(mine.boxes.isEmpty)
    }

    func testResumingRestoresTheRunOnItsUnfinishedPayloadAwaitingTheParticipant() {
        let name = "resume-\(UUID().uuidString.prefix(8))"
        let started = makeStartedRun(named: name)
        // Some time spent measuring, then the app goes away.
        started.store.endCurrentPhase()

        let afterRelaunch = StudyStore()
        XCTAssertNotNil(afterRelaunch.resumableRun, "An unfinished run must be offered.")
        let resumable = try! XCTUnwrap(
            afterRelaunch.saved.first { $0.id == started.run.id }
        )
        XCTAssertTrue(afterRelaunch.resumeRun(resumable))

        XCTAssertEqual(afterRelaunch.activeRun?.id, started.run.id)
        XCTAssertEqual(afterRelaunch.scheduledBox, started.run.firstBox)
        XCTAssertTrue(
            afterRelaunch.isAwaitingParticipantStart,
            "The participant taps Start again rather than landing straight in the camera."
        )
        XCTAssertFalse(afterRelaunch.isTestMode)
        XCTAssertNil(afterRelaunch.currentPhase, "No timer runs until Start is tapped.")
    }

    /// Time already recorded is kept when resuming.
    func testResumingKeepsTheTimeAlreadyRecorded() {
        let name = "resume-\(UUID().uuidString.prefix(8))"
        let started = makeStartedRun(named: name)
        let box = try! XCTUnwrap(started.store.currentBox)
        // Measuring already started with the participant's Start tap; end it and record 30 s of packing.
        started.store.endCurrentPhase()
        started.store.beginPhase(.pack, at: Date(timeIntervalSinceNow: -30))
        started.store.endCurrentPhase()
        let recorded = try! XCTUnwrap(
            started.store.activeRun?.result(for: box)?.seconds(for: .pack)
        )
        XCTAssertGreaterThan(recorded, 25)

        let afterRelaunch = StudyStore()
        let mine = try! XCTUnwrap(afterRelaunch.saved.first { $0.id == started.run.id })
        XCTAssertTrue(afterRelaunch.resumeRun(mine))

        XCTAssertEqual(
            afterRelaunch.activeRun?.result(for: box)?.seconds(for: .pack) ?? 0,
            recorded,
            accuracy: 0.01
        )
    }

    /// A run the operator cancelled keeps its data but isn't offered again.
    func testARunTheOperatorCancelledIsNotOfferedForResuming() {
        let name = "resume-\(UUID().uuidString.prefix(8))"
        let started = makeStartedRun(named: name)
        started.store.clearActiveRun()

        let afterRelaunch = StudyStore()
        let mine = try! XCTUnwrap(afterRelaunch.saved.first { $0.id == started.run.id })
        XCTAssertNotNil(mine.abandonedAt)
        XCTAssertFalse(mine.boxes.isEmpty, "Everything it recorded is still there.")
        XCTAssertNotEqual(afterRelaunch.resumableRun?.id, mine.id)
    }

    /// Objects finished before the crash are saved, even though the payload is measured again.
    func testObjectsMeasuredBeforeTheCrashAreOnDisk() {
        let name = "resume-\(UUID().uuidString.prefix(8))"
        let started = makeStartedRun(named: name)
        let box = try! XCTUnwrap(started.store.currentBox)
        started.store.recordMeasurementProgress(
            objects: [
                StudyObjectRecord(
                    id: UUID(),
                    name: "Drum",
                    measuredSizeMillimetres: [120, 80, 60],
                    packagedSizeMillimetres: [],
                    assignedBoxName: nil,
                    isOwnBox: false,
                    hasEnforcedSize: false,
                    massKilograms: nil,
                    photoFileName: nil,
                    placementOriginMillimetres: nil
                )
            ]
        )

        let afterRelaunch = StudyStore()
        let resumable = try! XCTUnwrap(
            afterRelaunch.saved.first { $0.id == started.run.id }
        )
        XCTAssertEqual(resumable.result(for: box)?.objects.count, 1)
        XCTAssertEqual(resumable.result(for: box)?.objects.first?.name, "Drum")
        XCTAssertEqual(
            resumable.result(for: box)?.objects.first?.measuredSizeMillimetres,
            [120, 80, 60]
        )
    }

    /// The resumed payload starts with no objects, since the old ones belong to the lost AR session
    /// and would block `recordMeasurementProgress`.
    func testResumingClearsStaleObjectsOnTheBoxBeingResumed() {
        let name = "resume-\(UUID().uuidString.prefix(8))"
        let started = makeStartedRun(named: name)
        let box = try! XCTUnwrap(started.store.currentBox)
        started.store.recordMeasurementProgress(
            objects: [
                StudyObjectRecord(
                    id: UUID(),
                    name: "Drum",
                    measuredSizeMillimetres: [120, 80, 60],
                    packagedSizeMillimetres: [],
                    assignedBoxName: nil,
                    isOwnBox: false,
                    hasEnforcedSize: false,
                    massKilograms: nil,
                    photoFileName: nil,
                    placementOriginMillimetres: nil
                )
            ]
        )

        let afterRelaunch = StudyStore()
        let resumable = try! XCTUnwrap(
            afterRelaunch.saved.first { $0.id == started.run.id }
        )
        XCTAssertTrue(afterRelaunch.resumeRun(resumable))

        XCTAssertEqual(
            afterRelaunch.activeRun?.result(for: box)?.objects.count,
            0,
            "The stale object from before the crash must not linger into the resumed run."
        )
    }

    func testAFinishedRunIsNeverOfferedForResuming() {
        let name = "resume-\(UUID().uuidString.prefix(8))"
        let started = makeStartedRun(named: name)
        started.store.advanceToNextBox()
        started.store.beginParticipantSession()
        started.store.finishRun()
        XCTAssertTrue(started.store.activeRun?.isComplete == true)

        let afterRelaunch = StudyStore()
        XCTAssertNil(
            afterRelaunch.resumableRun.flatMap { $0.id == started.run.id ? $0 : nil },
            "A completed run has nothing left to continue."
        )
    }
}
