import XCTest
import ARKit
@testable import PayloadMeasure

// The study moves from one payload box to the next by rebuilding the view hierarchy. That destroys
// the view which had presented the packing sheet, so the sheet's dismissal callback never runs and
// nothing clears the suspension reason it set. Before this was fixed the AR session stayed paused
// for the whole second box and the HUD sat on "understanding environment" forever.

@MainActor
final class StudyTransitionTests: XCTestCase {
    func testConfiguringAFreshSessionClearsAStalePackingSuspension() {
        let manager = ARSessionManager()
        manager.setPackingArrangementPresented(true)
        XCTAssertTrue(manager.isTrackingSuspended)

        // No dismissal happens — the view is simply gone, as it is between boxes.
        manager.configure(ARSession())

        XCTAssertFalse(
            manager.isTrackingSuspended,
            "A rebuilt hierarchy has no packing sheet, so the session must not stay paused."
        )
    }

    func testApplicationInactivitySurvivesAReconfigure() {
        // That reason describes real app state rather than a presentation, so it must not be cleared.
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
            firstBox: .small,
            includesPractice: false
        )
        XCTAssertEqual(store.currentBox, .small)
        XCTAssertFalse(store.isOnLastBox)

        store.advanceToNextBox()
        XCTAssertEqual(store.currentBox, .big, "The second box is always the other one.")
        XCTAssertTrue(store.isOnLastBox)

        store.finishRun()
        XCTAssertTrue(store.hasFinishedAllBoxes)
        let run = try! XCTUnwrap(store.activeRun)
        XCTAssertEqual(run.boxOrder, [.small, .big])
        XCTAssertTrue(store.saved.contains { $0.id == run.id }, "A finished run must be archived.")
    }

    /// The practice payload exists so a participant can learn the app on something that does not
    /// count. Nothing measured on it may reach the run, and the first box must not start until the
    /// operator has cleared the password.
    func testPracticePayloadIsNotRecordedAndPrecedesTheFirstBox() throws {
        let store = StudyStore()
        store.startRun(
            participantName: "P03",
            studyDate: Date(),
            flow: .batch,
            firstBox: .big,
            includesPractice: true
        )

        XCTAssertTrue(store.isPractice)
        XCTAssertTrue(store.hasActiveSession, "The measuring screens have to be up during practice.")
        XCTAssertNil(store.currentBox, "There is no study box yet.")
        XCTAssertEqual(
            store.activeModuleSizeMillimetres,
            StudyBox.small.sizeMillimetres,
            "The practice payload is the same size as the small module."
        )
        XCTAssertEqual(store.activeRun?.boxes.count, 0, "No box may be opened during practice.")

        // Anything the participant does with it goes nowhere.
        store.beginPhase(.pack)
        store.beginPhase(.payload)
        store.recordCurrentBox(
            objects: [],
            loadedObjectIDs: [],
            unloadedObjectNames: ["practice object"],
            packingMode: "practice",
            centreOfMass: nil,
            unbalancingIndex: nil
        )
        XCTAssertNil(store.storePhoto(Data([0x01]), objectID: UUID()))
        XCTAssertEqual(store.activeRun?.boxes.count, 0)

        store.startRealStudy()

        XCTAssertFalse(store.isPractice)
        XCTAssertEqual(store.currentBox, .big, "The study starts on the chosen first box.")
        XCTAssertEqual(store.activeRun?.boxes.count, 1)
        let first = try XCTUnwrap(store.activeRun?.boxes.first)
        XCTAssertTrue(
            first.phaseSeconds.isEmpty,
            "The first box must start with a clean clock, not with the practice time."
        )
        XCTAssertTrue(first.unloadedObjectNames.isEmpty)
        XCTAssertEqual(store.activeRun?.includedPracticeRun, true)
        XCTAssertTrue(
            try XCTUnwrap(store.activeRun).reportText().contains("Practice"),
            "The report has to say a practice run happened, since nothing else records it."
        )
    }

    func testPracticeCanBeTurnedOffAndTheFirstBoxOpensImmediately() {
        let store = StudyStore()
        store.startRun(
            participantName: "P04",
            studyDate: Date(),
            flow: .sequential,
            firstBox: .small,
            includesPractice: false
        )

        XCTAssertFalse(store.isPractice)
        XCTAssertEqual(store.currentBox, .small)
        XCTAssertEqual(store.activeRun?.boxes.count, 1)
        XCTAssertEqual(store.activeRun?.includedPracticeRun, false)
    }

    /// Boxing and loading the payload were showing as "—" on the results screen and in the report.
    /// The measuring phase was started for us, but nothing ever started the other two, so they were
    /// never written. Each of the three has to end up in the file for both boxes.
    func testEveryPhaseIsTimedForBothBoxes() throws {
        let store = StudyStore()
        store.startRun(
            participantName: "P02",
            studyDate: Date(),
            flow: .batch,
            firstBox: .big,
            includesPractice: false
        )

        for _ in 0..<2 {
            // What the screens do: measure, then the preparation stage, then the arrangement.
            store.beginPhase(.pack)
            store.beginPhase(.payload)
            if store.isOnLastBox {
                store.finishRun()
            } else {
                store.advanceToNextBox()
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

        // The report has to carry them too, and a dash on a timing line is how a missing one shows
        // up. Only the timing lines are checked: box headings contain a dash of their own.
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
}
