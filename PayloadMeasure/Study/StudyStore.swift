import Foundation
import Observation
import simd

// Holds the run in progress, times its phases and stores finished runs under
// Documents/StudyRuns/. Every change is saved straight away.
//
// `delete(runID:)` is the only way to remove a run and is password protected wherever it's used.

@MainActor
@Observable
final class StudyStore {
    /// Needed to finish a payload or cancel the current condition.
    static let nextBoxPassword = "130802"
    /// Needed to open the results screen and to restart from it.
    static let restartPassword = "13820485"

    private(set) var activeRun: StudyRun?
    private(set) var saved: [StudyRun] = []
    private(set) var lastExportURL: URL?
    private(set) var exportMessage: String?

    /// Index into `activeRun.boxOrder`.
    private(set) var currentBoxIndex = 0
    /// A throwaway run for trying the app: no participant, never saved, no password to leave.
    private(set) var isTestMode = false
    /// The run is configured but the participant hasn't tapped Start yet. Nothing is timed.
    private(set) var isAwaitingParticipantStart = false
    private var phaseStartedAt: Date?
    private(set) var currentPhase: StudyPhase?

    init() {
        saved = Self.loadAll()
    }

    // MARK: - Current position

    /// Nil until the participant taps Start.
    var currentBox: StudyBox? {
        guard !isAwaitingParticipantStart,
              let activeRun,
              activeRun.boxOrder.indices.contains(currentBoxIndex) else { return nil }
        return activeRun.boxOrder[currentBoxIndex]
    }

    /// Payload shown on the handoff screen. Unlike `currentBox` this is set while timing is stopped.
    var scheduledBox: StudyBox? {
        guard let activeRun,
              activeRun.boxOrder.indices.contains(currentBoxIndex) else { return nil }
        return activeRun.boxOrder[currentBoxIndex]
    }

    var hasActiveSession: Bool {
        activeRun != nil && !isAwaitingParticipantStart && currentBox != nil
    }

    var activeModuleSizeMillimetres: SIMD3<Double>? {
        currentBox?.sizeMillimetres
    }

    var isOnLastBox: Bool {
        guard let activeRun else { return false }
        return currentBoxIndex >= activeRun.boxOrder.count - 1
    }

    var currentInputMode: StudyInputMode {
        guard let activeRun else { return .augmentedReality }
        guard activeRun.inputModeOrder.indices.contains(currentBoxIndex) else {
            return .augmentedReality
        }
        return activeRun.inputModeOrder[currentBoxIndex]
    }

    var nextInputMode: StudyInputMode? {
        guard let activeRun,
              activeRun.inputModeOrder.indices.contains(currentBoxIndex + 1) else {
            return nil
        }
        return activeRun.inputModeOrder[currentBoxIndex + 1]
    }

    var switchesInputModeAfterCurrentBox: Bool {
        nextInputMode.map { $0 != currentInputMode } ?? false
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
        firstBox: StudyBox,
        inputPlan: StudyInputPlan? = nil,
        firstInputMode: StudyInputMode = .augmentedReality
    ) {
        var run = StudyRun(
            id: UUID(),
            participantName: participantName.trimmingCharacters(in: .whitespacesAndNewlines),
            studyDate: studyDate,
            createdAt: Date(),
            flow: flow.rawValue,
            firstBox: firstBox
        )
        run.includesBothPayloads = true
        run.inputPlan = inputPlan
        run.firstInputMode = inputPlan == .arOnly
            ? .augmentedReality
            : inputPlan == .manualOnly ? .manual : inputPlan == .both ? firstInputMode : nil
        // Pick the folder name once, checked against what's actually on disk, so a new run never
        // writes into a folder left over from a deleted one.
        run.folderName = Self.availableFolderName(base: run.exportBaseName)
        activeRun = run
        currentBoxIndex = 0
        isTestMode = false
        isAwaitingParticipantStart = true
        persistActiveRun()
    }

    /// Starts a test run with the selected condition and payload size. Nothing is saved and there is
    /// no handoff screen.
    func startTestRun(box: StudyBox, inputMode: StudyInputMode) {
        var run = StudyRun(
            id: UUID(),
            participantName: "",
            studyDate: Date(),
            createdAt: Date(),
            flow: MeasurementFlow.batch.rawValue,
            firstBox: box
        )
        // A single payload is enough for a test.
        run.includesBothPayloads = false
        run.inputPlan = inputMode == .augmentedReality ? .arOnly : .manualOnly
        run.firstInputMode = inputMode
        activeRun = run
        currentBoxIndex = 0
        isTestMode = true
        isAwaitingParticipantStart = false
        // Skips persistActiveRun: test runs have no folder.
        openCurrentBox()
    }

    // MARK: - Picking a run back up

    /// The most recent run that was started but never finished (e.g. after a crash), if any.
    var resumableRun: StudyRun? {
        guard activeRun == nil else { return nil }
        return saved.first {
            !$0.isComplete && !$0.boxes.isEmpty && $0.abandonedAt == nil
        }
    }

    /// Resumes an unfinished run at the first payload it hadn't finished. Finished payloads and time
    /// already spent are kept. The payload in progress is measured again from scratch, because its
    /// AR coordinates were lost with the relaunch.
    @discardableResult
    func resumeRun(_ run: StudyRun) -> Bool {
        guard activeRun == nil, !run.isComplete else { return false }
        var run = run
        let firstUnfinished = run.boxOrder.firstIndex {
            run.result(for: $0)?.completedAt == nil
        }
        guard let firstUnfinished else { return false }
        let resumedBox = run.boxOrder[firstUnfinished]
        // The objects recorded for this payload belong to the lost AR session and will be re-measured.
        // Clear them, otherwise recordMeasurementProgress would refuse new snapshots with fewer objects.
        if let index = run.boxes.firstIndex(where: { $0.box == resumedBox }) {
            run.boxes[index].objects = []
            run.boxes[index].loadedObjectIDs = []
            run.boxes[index].unloadedObjectNames = []
            run.boxes[index].packingMode = nil
            run.boxes[index].centreOfMassMillimetres = nil
            run.boxes[index].unbalancingIndexMillimetres = nil
        }
        endCurrentPhase()
        activeRun = run
        currentBoxIndex = firstUnfinished
        isTestMode = false
        isAwaitingParticipantStart = true
        currentPhase = nil
        phaseStartedAt = nil
        lastExportURL = nil
        exportMessage = nil
        if let index = saved.firstIndex(where: { $0.id == run.id }) {
            saved[index] = run
        }
        persistActiveRun()
        return true
    }

    /// Saves the objects measured so far for the payload in progress, so a crash only loses the
    /// object being measured.
    ///
    /// Never shrinks the recorded list: after the last payload the capture engine is reset, and a
    /// late call with an empty list must not wipe what recordCurrentBox just saved.
    func recordMeasurementProgress(objects: [StudyObjectRecord]) {
        guard let box = currentBox,
              var run = activeRun,
              let index = run.boxes.firstIndex(where: { $0.box == box }) else { return }
        guard objects.count >= run.boxes[index].objects.count else { return }
        guard run.boxes[index].objects.map(\.id) != objects.map(\.id)
                || run.boxes[index].objects.count != objects.count else {
            return
        }
        run.boxes[index].objects = objects
        run.boxes[index].inputMode = currentInputMode
        activeRun = run
        persistActiveRun()
    }

    /// Leaves the handoff screen and starts the first timer.
    func beginParticipantSession() {
        guard var run = activeRun, isAwaitingParticipantStart else { return }
        if currentBoxIndex == 0, run.boxes.isEmpty {
            run.createdAt = Date()
        }
        activeRun = run
        persistActiveRun()
        openCurrentBox()
    }

    private func openCurrentBox() {
        guard var run = activeRun else { return }
        guard run.boxOrder.indices.contains(currentBoxIndex) else { return }
        let box = run.boxOrder[currentBoxIndex]
        if run.result(for: box) == nil {
            run.boxes.append(
                StudyBoxResult(
                    box: box,
                    startedAt: Date(),
                    inputMode: run.inputMode(for: box)
                )
            )
        }
        activeRun = run
        isAwaitingParticipantStart = false
        persistActiveRun()
        beginPhase(.measure)
    }

    /// Called after the password. Closes the current payload and opens the next one.
    func advanceToNextBox() {
        guard activeRun != nil, !isOnLastBox else { return }
        endCurrentPhase()
        // Read the run after ending the phase, otherwise the phase's time is lost.
        guard var run = activeRun else { return }
        closeCurrentBox(in: &run)
        currentBoxIndex += 1
        activeRun = run
        isAwaitingParticipantStart = true
        persistActiveRun()
    }

    /// Closes the last payload, adds the run to `saved` and writes its report.
    func finishRun() {
        // Test runs are never saved; they end through clearActiveRun.
        guard activeRun != nil, !isTestMode else { return }
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

    func recordFinalConnection(seconds: Double) {
        guard var run = activeRun else { return }
        run.finalConnectionSeconds = max(0, seconds)
        activeRun = run
        persistActiveRun()
    }

    /// Returns to setup after a completed condition. The other condition isn't started automatically.
    func returnToSetupAfterCompletion() {
        guard activeRun?.isComplete == true else { return }
        activeRun = nil
        currentBoxIndex = 0
        isTestMode = false
        isAwaitingParticipantStart = false
        currentPhase = nil
        phaseStartedAt = nil
    }

    /// Compares names ignoring case and surrounding spaces.
    func savedRun(named name: String, inputMode: StudyInputMode? = nil) -> StudyRun? {
        let wanted = Self.comparableName(name)
        guard !wanted.isEmpty else { return nil }
        return saved.first { run in
            guard Self.comparableName(run.participantName) == wanted else { return false }
            guard let inputMode else { return true }
            return run.inputModeOrder.contains(inputMode)
        }
    }

    private static func comparableName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Permanently deletes a saved run: JSON, photos and report.
    func delete(runID: UUID) {
        let deleted = run(withID: runID)
        let folder = runFolder(runID: runID)
        let legacyReportName = deleted?.legacyReportFileName
        saved.removeAll { $0.id == runID }
        if activeRun?.id == runID {
            activeRun = nil
            currentBoxIndex = 0
            isTestMode = false
            isAwaitingParticipantStart = false
            currentPhase = nil
            phaseStartedAt = nil
        }
        try? FileManager.default.removeItem(at: folder)
        // Older versions also wrote a report copy to the top of StudyRuns.
        if let legacyReportName {
            try? FileManager.default.removeItem(
                at: Self.rootFolder.appendingPathComponent(legacyReportName)
            )
        }
        lastExportURL = nil
    }

    /// Clears the run in progress. It stays on disk marked as abandoned, so it won't be offered for
    /// resuming.
    func clearActiveRun() {
        endCurrentPhase()
        if var run = activeRun, !run.isComplete, !isTestMode {
            run.abandonedAt = Date()
            activeRun = run
            persistActiveRun()
        }
        activeRun = nil
        currentBoxIndex = 0
        isTestMode = false
        isAwaitingParticipantStart = false
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

    func beginPhase(_ phase: StudyPhase, at date: Date = Date()) {
        guard currentPhase != phase else { return }
        endCurrentPhase(at: date)
        currentPhase = phase
        phaseStartedAt = date
    }

    func endCurrentPhase(at date: Date = Date()) {
        guard let currentPhase, let phaseStartedAt, let box = currentBox,
              var run = activeRun,
              let index = run.boxes.firstIndex(where: { $0.box == box }) else {
            self.currentPhase = nil
            self.phaseStartedAt = nil
            return
        }
        let elapsed = date.timeIntervalSince(phaseStartedAt)
        run.boxes[index].phaseSeconds[currentPhase.rawValue] =
            (run.boxes[index].phaseSeconds[currentPhase.rawValue] ?? 0) + max(0, elapsed)
        activeRun = run
        self.currentPhase = nil
        self.phaseStartedAt = nil
        persistActiveRun()
    }

    /// Saved seconds plus the running interval. Takes the date from TimelineView so it's testable.
    func elapsedSeconds(for phase: StudyPhase, at date: Date = Date()) -> Double {
        let recorded = currentBox
            .flatMap { activeRun?.result(for: $0)?.seconds(for: phase) }
            ?? 0
        guard currentPhase == phase, let phaseStartedAt else {
            return max(0, recorded)
        }
        return max(0, recorded + date.timeIntervalSince(phaseStartedAt))
    }

    // MARK: - Recording a box

    /// Saves everything known about the current payload. Can be called repeatedly; the last call
    /// wins.
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
        run.boxes[index].inputMode = currentInputMode
        run.boxes[index].loadedObjectIDs = loadedObjectIDs
        run.boxes[index].unloadedObjectNames = unloadedObjectNames
        run.boxes[index].packingMode = packingMode
        run.boxes[index].centreOfMassMillimetres = centreOfMass.map { [$0.x, $0.y, $0.z] }
        run.boxes[index].unbalancingIndexMillimetres = unbalancingIndex
        activeRun = run
        persistActiveRun()
    }

    /// Saves an object's photo in the run folder and returns its file name (object and payload
    /// name, so the folder is readable).
    @discardableResult
    func storePhoto(_ data: Data, objectID: UUID, objectName: String? = nil) -> String? {
        guard !isTestMode, let run = activeRun else { return nil }
        let name = Self.photoFileName(
            objectID: objectID,
            objectName: objectName,
            box: currentBox
        )
        let folder = Self.photosFolder(for: run)
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

    static func photoFileName(
        objectID: UUID,
        objectName: String?,
        box: StudyBox?
    ) -> String {
        let object = objectName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !object.isEmpty else { return "\(objectID.uuidString).jpg" }
        let prefix = box.map { StudyRun.safeName($0.shortTitle) + " - " } ?? ""
        return "\(prefix)\(StudyRun.safeName(object)).jpg"
    }

    func photoURL(runID: UUID, fileName: String) -> URL {
        runFolder(runID: runID)
            .appendingPathComponent("photos", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    // MARK: - Export

    /// Writes the run's report into its folder.
    @discardableResult
    func exportReport(for run: StudyRun) -> URL? {
        let folder = Self.runFolder(for: run)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(run.reportFileName)
            try run.reportText().write(to: url, atomically: true, encoding: .utf8)
            lastExportURL = url
            exportMessage = "Saved \(run.exportFolderName)/\(run.reportFileName)"
            return url
        } catch {
            exportMessage = "Could not write the report: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Persistence

    private func persistActiveRun() {
        // Test runs are never written to disk.
        guard !isTestMode, let activeRun else { return }
        write(activeRun)
        if let index = saved.firstIndex(where: { $0.id == activeRun.id }) {
            saved[index] = activeRun
        }
    }

    private func write(_ run: StudyRun) {
        let folder = Self.runFolder(for: run)
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

    // StudyRuns/
    //   <Run name>/
    //     <Run name>.txt      report
    //     run.json            data read back by the app
    //     photos/             one JPEG per object
    //   <Run name>(1)/        next run with the same name
    //
    // Older runs live in a folder named after their id (`folderName` is nil).

    static func runFolder(for run: StudyRun) -> URL {
        rootFolder.appendingPathComponent(run.exportFolderName, isDirectory: true)
    }

    static func photosFolder(for run: StudyRun) -> URL {
        runFolder(for: run).appendingPathComponent("photos", isDirectory: true)
    }

    func runFolder(runID: UUID) -> URL {
        guard let run = run(withID: runID) else {
            return Self.rootFolder.appendingPathComponent(runID.uuidString, isDirectory: true)
        }
        return Self.runFolder(for: run)
    }

    private func run(withID runID: UUID) -> StudyRun? {
        if let activeRun, activeRun.id == runID { return activeRun }
        return saved.first { $0.id == runID }
    }

    /// Run name, or with a number in brackets if a folder with that name already exists.
    static func availableFolderName(base: String) -> String {
        let existing = (try? FileManager.default.contentsOfDirectory(
            atPath: rootFolder.path
        )) ?? []
        return uniqueFolderName(base: base, taken: Set(existing))
    }

    /// `Run`, `Run(1)`, `Run(2)`, ... Case-insensitive because the file system is.
    static func uniqueFolderName(base: String, taken: Set<String>) -> String {
        let safeBase = StudyRun.safeName(base)
        let lowercased = Set(taken.map { $0.lowercased() })
        guard lowercased.contains(safeBase.lowercased()) else { return safeBase }
        var suffix = 1
        while lowercased.contains("\(safeBase)(\(suffix))".lowercased()) {
            suffix += 1
        }
        return "\(safeBase)(\(suffix))"
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
