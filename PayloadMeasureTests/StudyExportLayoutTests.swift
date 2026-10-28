import XCTest
@testable import PayloadMeasure

// Folder layout under Documents/StudyRuns: one folder per run, named after it, with photos next to
// the report. Two runs must never share a folder.

@MainActor
final class StudyExportLayoutTests: XCTestCase {
    func testAFreeNameIsUsedAsItIs() {
        XCTAssertEqual(
            StudyStore.uniqueFolderName(base: "Run", taken: ["Other", "Run2"]),
            "Run"
        )
    }

    /// Run, Run(1), Run(2). Run2 is a different name.
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

    /// A leftover folder from a deleted run still counts as taken.
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

    /// Names differing only in case are the same folder on this file system.
    func testNamesThatDifferOnlyInCaseAreTreatedAsTheSameFolder() {
        XCTAssertEqual(
            StudyStore.uniqueFolderName(base: "run", taken: ["RUN"]),
            "run(1)"
        )
    }

    func testNamesArePathSafeAndNeverEmpty() {
        XCTAssertEqual(StudyStore.uniqueFolderName(base: "P01/02", taken: []), "P01-02")
        XCTAssertEqual(StudyStore.uniqueFolderName(base: "  ", taken: []), "Run")
        // Brackets are reserved for duplicate numbering.
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

    /// Older runs without a folder name still resolve to their id folder.
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
