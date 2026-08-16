import CoreGraphics
import Foundation
import Observation
import simd

@MainActor
@Observable
final class FramingAccuracyStore {
    static let maximumRounds = 10

    private(set) var activeTest: FramingAccuracyRun?
    private(set) var saved: [FramingAccuracyRun] = []
    private(set) var lastExportURL: URL?
    private(set) var message: String?

    init() {
        saved = Self.loadAll()
    }

    var nextSlot: FramingAccuracySlot? { activeTest?.nextSlot }
    var isMeasuring: Bool { activeTest != nil && nextSlot != nil }

    var progressText: String {
        guard let test = activeTest else { return "" }
        guard let slot = nextSlot else { return "All \(test.totalExpectedReadings) readings done." }
        return "Round \(slot.round) of \(test.rounds) · frame \(slot.levelPosition) of \(FramingCalibrationProtocol.targetFillPercentages.count)"
    }

    func startTest(label: String, rounds: Int, workflowMode: MeasurementWorkflowMode) {
        activeTest = FramingAccuracyRun(
            id: UUID(),
            createdAt: Date(),
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            rounds: min(max(rounds, 1), Self.maximumRounds),
            workflowMode: workflowMode
        )
        persistAndArchive()
    }

    func resume(_ test: FramingAccuracyRun) {
        activeTest = test
    }

    func closeActiveTest() {
        activeTest = nil
    }

    @discardableResult
    func record(
        sizeMillimetres: SIMD3<Double>,
        viewportBoundingBox: CGRect,
        viewportSize: CGSize,
        cameraDistanceMetres: Double?
    ) -> Bool {
        guard var test = activeTest,
              let slot = test.nextSlot,
              [sizeMillimetres.x, sizeMillimetres.y, sizeMillimetres.z]
                .allSatisfy({ $0.isFinite && $0 > 0 }),
              let actualFill = FramingCalibrationProtocol.fillPercent(
                boundingBox: viewportBoundingBox,
                viewportSize: viewportSize
              ),
              abs(actualFill - slot.targetFillPercent)
                <= FramingCalibrationProtocol.allowedFillErrorPercentagePoints else {
            return false
        }
        let distanceMillimetres = cameraDistanceMetres.flatMap {
            $0.isFinite && $0 > 0 ? $0 * 1_000 : nil
        }
        test.readings.append(
            FramingAccuracyReading(
                id: UUID(),
                round: slot.round,
                targetFillPercent: slot.targetFillPercent,
                actualFillPercent: actualFill,
                viewportBoundingBox: FramingViewportBox(viewportBoundingBox),
                viewportWidthPoints: Double(viewportSize.width),
                viewportHeightPoints: Double(viewportSize.height),
                cameraDistanceMillimetres: distanceMillimetres,
                sizeMillimetres: [sizeMillimetres.x, sizeMillimetres.y, sizeMillimetres.z],
                recordedAt: Date()
            )
        )
        activeTest = test
        persistAndArchive()
        return true
    }

    func undoLastReading() {
        guard var test = activeTest, test.completedAttemptCount > 0 else { return }
        let latestReading = test.readings.last?.recordedAt ?? .distantPast
        let latestFailure = test.failures.last?.recordedAt ?? .distantPast
        if latestFailure > latestReading {
            test.failures.removeLast()
        } else {
            test.readings.removeLast()
        }
        activeTest = test
        persistAndArchive()
    }

    @discardableResult
    func recordFailure(reason: String) -> Bool {
        guard var test = activeTest, let slot = test.nextSlot else { return false }
        test.failures.append(
            FramingAccuracyFailure(
                id: UUID(),
                round: slot.round,
                targetFillPercent: slot.targetFillPercent,
                reason: reason,
                recordedAt: Date()
            )
        )
        activeTest = test
        persistAndArchive()
        return true
    }

    func setReference(_ size: SIMD3<Double>?) {
        guard var test = activeTest else { return }
        if let size,
           size.x.isFinite, size.y.isFinite, size.z.isFinite,
           size.x > 0, size.y > 0, size.z > 0 {
            test.referenceSizeMillimetres = [size.x, size.y, size.z]
        } else {
            test.referenceSizeMillimetres = nil
        }
        activeTest = test
        persistAndArchive()
    }

    var summary: FramingAccuracySummary? {
        activeTest.flatMap(FramingAccuracyStatistics.summarise)
    }

    @discardableResult
    func exportReport(for test: FramingAccuracyRun) -> URL? {
        let folder = Self.testFolder(id: test.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(test.reportFileName)
            try test.reportText().write(to: url, atomically: true, encoding: .utf8)
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

    private func persistAndArchive() {
        guard let activeTest else { return }
        if let index = saved.firstIndex(where: { $0.id == activeTest.id }) {
            saved[index] = activeTest
        } else {
            saved.insert(activeTest, at: 0)
        }
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
        return documents.appendingPathComponent("FramingAccuracyTests", isDirectory: true)
    }

    static func testFolder(id: UUID) -> URL {
        rootFolder.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private static func loadAll() -> [FramingAccuracyRun] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: rootFolder,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return folders.compactMap { folder in
            try? decoder.decode(
                FramingAccuracyRun.self,
                from: Data(contentsOf: folder.appendingPathComponent("test.json"))
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
}
