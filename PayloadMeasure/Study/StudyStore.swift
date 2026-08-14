import Foundation
import Observation
import simd

// Holds the run in progress, times its phases, and keeps every finished run on disk forever.
//
// In:  the setup screen starts a run; the measuring and packing screens mark phase boundaries and
//      hand over each box's result.
// Out: observable state for the study screens, plus files under Documents/StudyRuns/.
//
// There is no delete. `saved` only ever grows, every mutation is written straight through, and a run
// is persisted the moment it is created rather than when it finishes.

@MainActor
@Observable
final class StudyStore {
    /// Gate for moving to the second box.
    static let nextBoxPassword = "130802"
    /// Gate for restarting the app from the results screen, and for opening the results screen.
    static let restartPassword = "13820485"

    private(set) var activeRun: StudyRun?
    private(set) var saved: [StudyRun] = []
    private(set) var lastExportURL: URL?
    private(set) var exportMessage: String?

    /// Index into `activeRun.boxOrder`.
    private(set) var currentBoxIndex = 0
    private var phaseStartedAt: Date?
    private var currentPhase: StudyPhase?

    init() {
        saved = Self.loadAll()
    }

    // MARK: - Current position

    var currentBox: StudyBox? {
        guard let activeRun, activeRun.boxOrder.indices.contains(currentBoxIndex) else { return nil }
        return activeRun.boxOrder[currentBoxIndex]
    }

    var isOnLastBox: Bool {
        guard let activeRun else { return false }
        return currentBoxIndex >= activeRun.boxOrder.count - 1
    }

    var hasFinishedAllBoxes: Bool {
        activeRun?.isComplete ?? false
    }

    var flow: MeasurementFlow? {
        activeRun.flatMap { MeasurementFlow(rawValue: $0.flow) }
    }

    // MARK: - Lifecycle

    func startRun(
        participantName: String,
        studyDate: Date,
        flow: MeasurementFlow,
        firstBox: StudyBox
    ) {
        var run = StudyRun(
            id: UUID(),
            participantName: participantName.trimmingCharacters(in: .whitespacesAndNewlines),
            studyDate: studyDate,
            createdAt: Date(),
            flow: flow.rawValue,
            firstBox: firstBox
        )
        run.boxes = [StudyBoxResult(box: firstBox, startedAt: Date())]
        activeRun = run
        currentBoxIndex = 0
        persistActiveRun()
        beginPhase(.measure)
    }

    /// Called once the operator has cleared the password. Closes the current box and opens the next.
    func advanceToNextBox() {
        guard activeRun != nil, !isOnLastBox else { return }
        endCurrentPhase()
        // Read the run *after* ending the phase. Taking the copy first and writing it back at the end
        // threw away the seconds the phase had just recorded, which is why the last phase of every
        // box came out blank.
        guard var run = activeRun else { return }
        closeCurrentBox(in: &run)
        currentBoxIndex += 1
        let next = run.boxOrder[currentBoxIndex]
        if run.result(for: next) == nil {
            run.boxes.append(StudyBoxResult(box: next, startedAt: Date()))
        }
        activeRun = run
        persistActiveRun()
        beginPhase(.measure)
    }

    /// Closes the last box and finalises the run: it joins `saved` and its report is written.
    func finishRun() {
        guard activeRun != nil else { return }
        endCurrentPhase()
        guard var run = activeRun else { return }
        closeCurrentBox(in: &run)
        activeRun = run
        persistActiveRun()
        if let index = saved.firstIndex(where: { $0.id == run.id }) {
            saved[index] = run
        } else {
            saved.append(run)
        }
        exportReport(for: run)
    }

    /// Clears the run in progress without touching anything already saved.
    func clearActiveRun() {
        endCurrentPhase()
        activeRun = nil
        currentBoxIndex = 0
        lastExportURL = nil
        exportMessage = nil
    }

    private func closeCurrentBox(in run: inout StudyRun) {
        guard let box = currentBox,
              let index = run.boxes.firstIndex(where: { $0.box == box }) else { return }
        if run.boxes[index].completedAt == nil {
            run.boxes[index].completedAt = Date()
        }
    }

    // MARK: - Timing

    func beginPhase(_ phase: StudyPhase) {
        guard currentPhase != phase else { return }
        endCurrentPhase()
        currentPhase = phase
        phaseStartedAt = Date()
    }

    func endCurrentPhase() {
        guard let currentPhase, let phaseStartedAt, let box = currentBox,
              var run = activeRun,
              let index = run.boxes.firstIndex(where: { $0.box == box }) else {
            self.currentPhase = nil
            self.phaseStartedAt = nil
            return
        }
        let elapsed = Date().timeIntervalSince(phaseStartedAt)
        run.boxes[index].phaseSeconds[currentPhase.rawValue] =
            (run.boxes[index].phaseSeconds[currentPhase.rawValue] ?? 0) + max(0, elapsed)
        activeRun = run
        self.currentPhase = nil
        self.phaseStartedAt = nil
        persistActiveRun()
    }

    // MARK: - Recording a box

    /// Snapshots everything known about the current box. Safe to call repeatedly; the latest call
    /// wins, so it can be called when the plan is first shown and again when the box is closed.
    func recordCurrentBox(
        objects: [StudyObjectRecord],
        loadedObjectIDs: [UUID],
        unloadedObjectNames: [String],
        packingMode: String?,
        centreOfMass: SIMD3<Double>?,
        unbalancingIndex: Double?
    ) {
        guard let box = currentBox,
              var run = activeRun,
              let index = run.boxes.firstIndex(where: { $0.box == box }) else { return }
        run.boxes[index].objects = objects
        run.boxes[index].loadedObjectIDs = loadedObjectIDs
        run.boxes[index].unloadedObjectNames = unloadedObjectNames
        run.boxes[index].packingMode = packingMode
        run.boxes[index].centreOfMassMillimetres = centreOfMass.map { [$0.x, $0.y, $0.z] }
        run.boxes[index].unbalancingIndexMillimetres = unbalancingIndex
        activeRun = run
        persistActiveRun()
    }

    /// Writes one object's photo into the run folder and returns the file name to store with it.
    @discardableResult
    func storePhoto(_ data: Data, objectID: UUID) -> String? {
        guard let run = activeRun else { return nil }
        let name = "\(objectID.uuidString).jpg"
        let folder = Self.photosFolder(runID: run.id)
        do {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    func photoURL(runID: UUID, fileName: String) -> URL {
        Self.photosFolder(runID: runID).appendingPathComponent(fileName)
    }

    // MARK: - Export

    @discardableResult
    func exportReport(for run: StudyRun) -> URL? {
        let folder = Self.runFolder(runID: run.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(run.reportFileName)
            try run.reportText().write(to: url, atomically: true, encoding: .utf8)
            // A copy at the top level too, so it is easy to find in Files without digging.
            let flat = Self.rootFolder.appendingPathComponent(run.reportFileName)
            try? run.reportText().write(to: flat, atomically: true, encoding: .utf8)
            lastExportURL = url
            exportMessage = "Saved \(run.reportFileName)"
            return url
        } catch {
            exportMessage = "Could not write the report: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Persistence

    private func persistActiveRun() {
        guard let activeRun else { return }
        write(activeRun)
        if let index = saved.firstIndex(where: { $0.id == activeRun.id }) {
            saved[index] = activeRun
        }
    }

    private func write(_ run: StudyRun) {
        let folder = Self.runFolder(runID: run.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(run)
            try data.write(to: folder.appendingPathComponent("run.json"), options: .atomic)
        } catch {
            exportMessage = "Could not save the run: \(error.localizedDescription)"
        }
    }

    static var rootFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("StudyRuns", isDirectory: true)
    }

    static func runFolder(runID: UUID) -> URL {
        rootFolder.appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    static func photosFolder(runID: UUID) -> URL {
        runFolder(runID: runID).appendingPathComponent("photos", isDirectory: true)
    }

    private static func loadAll() -> [StudyRun] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: rootFolder,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return folders
            .compactMap { folder -> StudyRun? in
                let url = folder.appendingPathComponent("run.json")
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(StudyRun.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
