import XCTest
@testable import PayloadMeasure

// The layout under Documents/StudyRuns: one folder per run, named after the run, with the photos in a
// folder beside the report. Two runs must never share a folder, because the second one would write
// over the first one's report and photos.

@MainActor
final class StudyExportLayoutTests: XCTestCase {
    func testAFreeNameIsUsedAsItIs() {
        XCTAssertEqual(
            StudyStore.uniqueFolderName(base: "Run", taken: ["Other", "Run2"]),
            "Run"
        )
    }

    /// The numbering the run folders use: Run, Run(1), Run(2) — and Run2 is a different name, not the
    /// second Run.
    func testATakenNameGetsTheNextNumberInBrackets() {
        XCTAssertEqual(
            StudyStore.uniqueFolderName(base: "Run", taken: ["Run"]),
            "Run(1)"
        )
        XCTAssertEqual(
            StudyStore.uniqueFolderName(base: "Run", taken: ["Run", "Run(1)", "Run2"]),
            "Run(2)"
        )
        XCTAssertEqual(
            StudyStore.uniqueFolderName(base: "Run2", taken: ["Run", "Run(1)", "Run2"]),
            "Run2(1)"
        )
    }

    /// A folder left behind by a run deleted in the app still counts as taken: the whole point of
    /// checking the disk rather than the app's own list.
    func testGapsInTheNumberingAreNotFilled() {
        XCTAssertEqual(
            StudyStore.uniqueFolderName(base: "Run", taken: ["Run", "Run(2)"]),
            "Run(1)"
        )
        XCTAssertEqual(
            StudyStore.uniqueFolderName(base: "Run", taken: ["Run", "Run(1)", "Run(2)"]),
            "Run(3)"
        )
    }

    /// Two names differing only in case are one folder on this file system, so they must not both be
    /// handed out.
    func testNamesThatDifferOnlyInCaseAreTreatedAsTheSameFolder() {
        XCTAssertEqual(
            StudyStore.uniqueFolderName(base: "run", taken: ["RUN"]),
            "run(1)"
        )
    }

    func testNamesArePathSafeAndNeverEmpty() {
        XCTAssertEqual(StudyStore.uniqueFolderName(base: "P01/02", taken: []), "P01-02")
        XCTAssertEqual(StudyStore.uniqueFolderName(base: "  ", taken: []), "Run")
        // Brackets are what makes a duplicate unique, so a name may not bring its own.
        XCTAssertEqual(StudyStore.uniqueFolderName(base: "P01(1)", taken: []), "P01-1")
    }

    // MARK: - What lands in the folder

    func testReportIsNamedAfterTheRunFolder() {
        var run = StudyRun(
            id: UUID(),
            participantName: "P01",
            studyDate: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            flow: MeasurementFlow.sequential.rawValue,
            firstBox: .big
        )
        run.inputPlan = .arOnly
        XCTAssertEqual(run.exportBaseName, "P01 AR")

        run.folderName = "P01 AR(1)"
        XCTAssertEqual(run.exportFolderName, "P01 AR(1)")
        XCTAssertEqual(run.reportFileName, "P01 AR(1).txt")
        XCTAssertEqual(
            StudyStore.photosFolder(for: run).lastPathComponent,
            "photos"
        )
        XCTAssertEqual(
            StudyStore.photosFolder(for: run).deletingLastPathComponent(),
            StudyStore.runFolder(for: run)
        )
    }

    /// Runs recorded before the per-run folders keep reading from the folder named after their id.
    func testRunsWithoutAFolderNameStillResolveToTheirIdFolder() {
        let id = UUID()
        let run = StudyRun(
            id: id,
            participantName: "P02",
            studyDate: Date(timeIntervalSince1970: 0),
            createdAt: Date(timeIntervalSince1970: 0),
            flow: MeasurementFlow.sequential.rawValue,
            firstBox: .small
        )
        XCTAssertEqual(run.exportFolderName, id.uuidString)
        XCTAssertEqual(
            StudyStore.runFolder(for: run).lastPathComponent,
            id.uuidString
        )
    }

    func testPhotosAreNamedAfterTheObjectAndFallBackToTheID() {
        let id = UUID()
        XCTAssertEqual(
            StudyStore.photoFileName(objectID: id, objectName: "Red drum", box: .big),
            "Big box - Red drum.jpg"
        )
        XCTAssertEqual(
            StudyStore.photoFileName(objectID: id, objectName: "  ", box: .big),
            "\(id.uuidString).jpg"
        )
        XCTAssertEqual(
            StudyStore.photoFileName(objectID: id, objectName: "Cable/reel", box: nil),
            "Cable-reel.jpg"
        )
    }
}
