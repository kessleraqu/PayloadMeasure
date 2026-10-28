import Foundation
import Observation
import simd

// Holds the accuracy test in progress and saves every test under Documents/AccuracyTests/.
// Saved after every change, so a test can be left halfway and resumed.

@MainActor
@Observable
final class AccuracyStore {
    static let maximumObjects = 20
    static let maximumPasses = 50

    private(set) var activeTest: AccuracyTestRun?
    private(set) var saved: [AccuracyTestRun] = []
    private(set) var lastExportURL: URL?
    private(set) var message: String?

    init() {
        saved = Self.loadAll()
    }

    // MARK: - Where the test is up to

    var nextSlot: (
        objectNumber: Int,
        pass: Int,
        workflowMode: MeasurementWorkflowMode
    )? {
        activeTest?.nextSlot
    }

    var isMeasuring: Bool {
        activeTest != nil && nextSlot != nil
    }

    var progressText: String {
        guard let test = activeTest else { return "" }
        guard let slot = nextSlot else {
            return "All \(test.totalExpectedReadings) readings done."
        }
        return "Object \(slot.objectNumber) of \(test.objectCount) · pass \(slot.pass) of \(test.passes)"
            + " · \(slot.workflowMode.shortTitle)"
    }

    // MARK: - Lifecycle

    func startTest(label: String, objectCount: Int, passes: Int) {
        let test = AccuracyTestRun(
            id: UUID(),
            createdAt: Date(),
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            objectCount: min(max(objectCount, 1), Self.maximumObjects),
            passes: min(max(passes, 1), Self.maximumPasses),
            workflowModes: [.top, .spatial3D]
        )
        activeTest = test
        persist()
        archiveActiveTest()
    }

    /// Reopens a saved test so it can be continued or have reference sizes added.
    func resume(_ test: AccuracyTestRun) {
        activeTest = test
    }

    func closeActiveTest() {
        activeTest = nil
    }

    // MARK: - Recording

    /// Adds a reading to the next slot. Ignored once the test is full.
    @discardableResult
    func record(sizeMillimetres: SIMD3<Double>) -> Bool {
        guard var test = activeTest, let slot = test.nextSlot else { return false }
        let values = [sizeMillimetres.x, sizeMillimetres.y, sizeMillimetres.z]
        guard values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return false }

        test.readings.append(
            AccuracyReading(
                id: UUID(),
                objectNumber: slot.objectNumber,
                pass: slot.pass,
                sizeMillimetres: values,
                recordedAt: Date(),
                workflowMode: slot.workflowMode
            )
        )
        activeTest = test
        persist()
        archiveActiveTest()
        return true
    }

    /// Removes the last reading, e.g. after an obviously bad measurement.
    func undoLastReading() {
        guard var test = activeTest, !test.readings.isEmpty else { return }
        test.readings.removeLast()
        activeTest = test
        persist()
        archiveActiveTest()
    }

    func setReference(_ size: SIMD3<Double>?, forObject objectNumber: Int) {
        guard var test = activeTest else { return }
        if let size, size.x > 0, size.y > 0, size.z > 0 {
            test.referenceSizesMillimetres["\(objectNumber)"] = [size.x, size.y, size.z]
        } else {
            test.referenceSizesMillimetres.removeValue(forKey: "\(objectNumber)")
        }
        activeTest = test
        persist()
        archiveActiveTest()
    }

    var summary: AccuracySummary? {
        activeTest.map { AccuracyStatistics.summarise($0) }
    }

    // MARK: - Export

    @discardableResult
    func exportReport(for test: AccuracyTestRun) -> URL? {
        let folder = Self.testFolder(id: test.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(test.reportFileName)
            try test.reportText().write(to: url, atomically: true, encoding: .utf8)
            // Also copy the report to the top of the folder so it's easy to find in Files.
            try? test.reportText().write(
                to: Self.rootFolder.appendingPathComponent(test.reportFileName),
                atomically: true,
                encoding: .utf8
            )
            lastExportURL = url
            message = "Saved \(test.reportFileName)"
            return url
        } catch {
            message = "Could not write the report: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Persistence

    private func archiveActiveTest() {
        guard let activeTest else { return }
        if let index = saved.firstIndex(where: { $0.id == activeTest.id }) {
            saved[index] = activeTest
        } else {
            saved.insert(activeTest, at: 0)
        }
    }

    private func persist() {
        guard let activeTest else { return }
        let folder = Self.testFolder(id: activeTest.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(activeTest).write(
                to: folder.appendingPathComponent("test.json"),
                options: .atomic
            )
        } catch {
            message = "Could not save the test: \(error.localizedDescription)"
        }
    }

    static var rootFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("AccuracyTests", isDirectory: true)
    }

    static func testFolder(id: UUID) -> URL {
        rootFolder.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func loadAll() -> [AccuracyTestRun] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: rootFolder,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return folders
            .compactMap { folder -> AccuracyTestRun? in
                guard let data = try? Data(
                    contentsOf: folder.appendingPathComponent("test.json")
                ) else {
                    return nil
                }
                return try? decoder.decode(AccuracyTestRun.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
