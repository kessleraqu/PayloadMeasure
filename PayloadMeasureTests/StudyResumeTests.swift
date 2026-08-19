import XCTest
@testable import PayloadMeasure

// Picking a run back up after the app has gone away mid-session — a crash, a force-quit, a flat
// battery. A run is written to disk from the moment it is created, so the question is only whether the
// app offers to continue it instead of leaving the operator to start again from the beginning.

@MainActor
final class StudyResumeTests: XCTestCase {
    /// Every test starts a run under its own participant name and deletes it afterwards, because the
    /// store reads and writes the app's real Documents folder.
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
            includesPractice: false,
            inputPlan: .arOnly,
            firstInputMode: .augmentedReality
        )
        store.beginParticipantSession()
        let run = store.activeRun!
        startedRunIDs.append(run.id)
        return (store, run)
    }

    /// The state after a crash: the run is on disk, unfinished, and no run is active.
    func testAnUnfinishedRunOnDiskIsOfferedForResuming() {
        let name = "resume-\(UUID().uuidString.prefix(8))"
        let started = makeStartedRun(named: name)
        XCTAssertNil(
            started.store.resumableRun,
            "A run already in progress is not something to resume."
        )

        let afterRelaunch = StudyStore()
        // What is offered is whichever unfinished run is most recent, and other tests leave their own
        // behind in the simulator, so this asserts the property rather than the identity: something is
        // offered, this run is one of the candidates, and nothing finished or abandoned is ever offered.
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
        // Some time is spent measuring, then the app disappears.
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
        XCTAssertFalse(afterRelaunch.isPractice)
        XCTAssertNil(afterRelaunch.currentPhase, "No timer runs until Start is tapped.")
    }

    /// Time already recorded is time the participant actually spent; resuming must not throw it away.
    func testResumingKeepsTheTimeAlreadyRecorded() {
        let name = "resume-\(UUID().uuidString.prefix(8))"
        let started = makeStartedRun(named: name)
        let box = try! XCTUnwrap(started.store.currentBox)
        // The measuring phase is already running from the participant's Start tap; end it, then record
        // half a minute of packing.
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

    /// A run the operator ended on purpose keeps its data but is never offered again. Otherwise the
    /// setup screen would go on suggesting a session that was deliberately closed.
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

    /// Objects finished before the crash are on disk, so the study keeps their dimensions even though
    /// the payload has to be measured again.
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

    /// The box being resumed is measured again from nothing — its old objects belong to an AR
    /// coordinate system the relaunch already threw away. Leaving them in place would let their stale
    /// count block the progress safety net (`recordMeasurementProgress`) from persisting genuine
    /// re-measurement until it happened to catch back up, on top of misrepresenting what the payload
    /// currently holds.
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
