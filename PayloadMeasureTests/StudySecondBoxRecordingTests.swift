import XCTest
@testable import PayloadMeasure

// Reported directly: starting with the small box, the big box's time was recorded but its measurements
// and photos were not. `StudyTransitionTests` already covers timing across both boxes exhaustively
// (`testEveryPhaseIsTimedForBothBoxes`, `testSecondPayloadHasAWhiteHandoffAndIndependentTimers`), which
// is presumably why the timing half of this was never seen to regress — but nothing in the suite checked
// that `recordMeasurementProgress`, `recordCurrentBox`, or `storePhoto` actually reach the *second* box's
// result rather than silently landing on the first, or on nothing. These tests close that gap directly.
@MainActor
final class StudySecondBoxRecordingTests: XCTestCase {
    private var startedRunIDs: [UUID] = []

    override func tearDown() {
        let store = StudyStore()
        for id in startedRunIDs {
            store.delete(runID: id)
        }
        startedRunIDs = []
        super.tearDown()
    }

    private func object(_ name: String, size: [Double]) -> StudyObjectRecord {
        StudyObjectRecord(
            id: UUID(),
            name: name,
            measuredSizeMillimetres: size,
            packagedSizeMillimetres: [],
            assignedBoxName: nil,
            isOwnBox: false,
            hasEnforcedSize: false,
            massKilograms: nil,
            photoFileName: nil,
            placementOriginMillimetres: nil
        )
    }

    /// A store with a run already started on the small box and the participant session begun.
    private func makeSmallBoxStore(_ label: String) throws -> StudyStore {
        let store = StudyStore()
        store.startRun(
            participantName: "\(label)-\(UUID().uuidString.prefix(8))",
            studyDate: Date(),
            flow: .batch,
            firstBox: .small,
            includesPractice: false,
            inputPlan: .arOnly
        )
        startedRunIDs.append(try XCTUnwrap(store.activeRun?.id))
        store.beginParticipantSession()
        return store
    }

    /// The reported scenario, at store level: small box first, big box second, one object measured on
    /// each. Both must show up under their own box afterwards.
    func testMeasurementProgressReachesTheSecondBoxAfterAdvancing() throws {
        let store = try makeSmallBoxStore("second-box-progress")
        XCTAssertEqual(store.currentBox, .small, "Fixture check.")

        store.recordMeasurementProgress(objects: [object("Small-box item", size: [100, 80, 60])])

        store.advanceToNextBox()
        store.beginParticipantSession()
        XCTAssertEqual(store.currentBox, .big, "Fixture check: the second box is big.")

        store.recordMeasurementProgress(objects: [object("Big-box item", size: [300, 200, 150])])

        let run = try XCTUnwrap(store.activeRun)
        let smallResult = try XCTUnwrap(run.result(for: .small))
        let bigResult = try XCTUnwrap(run.result(for: .big))

        XCTAssertEqual(smallResult.objects.map(\.name), ["Small-box item"])
        XCTAssertEqual(
            bigResult.objects.map(\.name), ["Big-box item"],
            "The big box's own measured object must be recorded, not left empty."
        )
        XCTAssertNotEqual(
            smallResult.objects.map(\.id), bigResult.objects.map(\.id),
            "The two boxes must not end up sharing the same object records."
        )
    }

    /// The packing screen's final snapshot — objects, loaded IDs, packing mode, balance — for the second
    /// box specifically, since `recordCurrentBox` is the call that carries most of what a participant
    /// actually did with a payload.
    func testRecordCurrentBoxReachesTheSecondBoxAfterAdvancing() throws {
        let store = try makeSmallBoxStore("second-box-final")

        let smallObject = object("Small-box item", size: [100, 80, 60])
        store.recordCurrentBox(
            objects: [smallObject],
            loadedObjectIDs: [smallObject.id],
            unloadedObjectNames: [],
            packingMode: "paper",
            centreOfMass: SIMD3(50, 40, 30),
            unbalancingIndex: 4.5
        )

        store.advanceToNextBox()
        store.beginParticipantSession()
        XCTAssertEqual(store.currentBox, .big, "Fixture check.")

        let bigObject = object("Big-box item", size: [300, 200, 150])
        store.recordCurrentBox(
            objects: [bigObject],
            loadedObjectIDs: [bigObject.id],
            unloadedObjectNames: ["Left out item"],
            packingMode: "centred",
            centreOfMass: SIMD3(150, 100, 75),
            unbalancingIndex: 12.0
        )

        let run = try XCTUnwrap(store.activeRun)
        let bigResult = try XCTUnwrap(run.result(for: .big))
        XCTAssertEqual(bigResult.objects.map(\.name), ["Big-box item"])
        XCTAssertEqual(bigResult.loadedObjectIDs, [bigObject.id])
        XCTAssertEqual(bigResult.unloadedObjectNames, ["Left out item"])
        XCTAssertEqual(bigResult.packingMode, "centred")
        XCTAssertEqual(bigResult.centreOfMassMillimetres, [150, 100, 75])
        XCTAssertEqual(bigResult.unbalancingIndexMillimetres, 12.0)

        // And the small box's snapshot from before advancing must still be exactly what it was.
        let smallResult = try XCTUnwrap(run.result(for: .small))
        XCTAssertEqual(smallResult.objects.map(\.name), ["Small-box item"])
        XCTAssertEqual(smallResult.packingMode, "paper")
    }

    /// A photo captured for the second box must be named and filed under the second box, not the first.
    func testAPhotoStoredForTheSecondBoxIsNamedForTheSecondBox() throws {
        let store = try makeSmallBoxStore("second-box-photo")
        let runID = try XCTUnwrap(store.activeRun?.id)

        let smallObjectID = UUID()
        let smallFileName = try XCTUnwrap(
            store.storePhoto(Data([0xFF]), objectID: smallObjectID, objectName: "Small item")
        )
        XCTAssertTrue(smallFileName.hasPrefix("Small box"), "Fixture check: named for the small box.")

        store.advanceToNextBox()
        store.beginParticipantSession()
        XCTAssertEqual(store.currentBox, .big, "Fixture check.")

        let bigObjectID = UUID()
        let bigFileName = try XCTUnwrap(
            store.storePhoto(Data([0xFF]), objectID: bigObjectID, objectName: "Big item")
        )
        XCTAssertTrue(
            bigFileName.hasPrefix("Big box"),
            "A photo captured after advancing must be filed under the box now in progress, not the first."
        )
        XCTAssertNotEqual(smallFileName, bigFileName)

        let photoURL = store.photoURL(runID: runID, fileName: bigFileName)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: photoURL.path),
            "The second box's photo must actually be written to disk."
        )
    }
}
