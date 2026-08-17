import Foundation
import Observation
import simd

// Holds the run in progress, times its phases, and keeps every finished run on disk forever.
//
// In:  the setup screen starts a run; the measuring and packing screens mark phase boundaries and
//      hand over each box's result.
// Out: observable state for the study screens, plus files under Documents/StudyRuns/.
//
// Every mutation is written straight through, and a run is persisted the moment it is created rather
// than when it finishes, so a crash mid-study loses at most the box in progress.
//
// `delete(runID:)` is the one destructive path, added on request and gated behind a password at every
// call site. Nothing else removes a run, and there is no copy elsewhere: deleting is final.

@MainActor
@Observable
final class StudyStore {
    /// Gate for finishing a payload or cancelling the selected study condition.
    static let nextBoxPassword = "130802"
    /// Gate for restarting the app from the results screen, and for opening the results screen.
    static let restartPassword = "13820485"

    private(set) var activeRun: StudyRun?
    private(set) var saved: [StudyRun] = []
    private(set) var lastExportURL: URL?
    private(set) var exportMessage: String?

    /// Index into `activeRun.boxOrder`.
    private(set) var currentBoxIndex = 0
    /// True while the participant is on the practice payload, before the study proper.
    private(set) var isPractice = false
    /// True after the administrator has configured the run but before the participant taps the
    /// neutral Start screen. No study timer or measuring workflow is active in this state.
    private(set) var isAwaitingParticipantStart = false
    private var phaseStartedAt: Date?
    private(set) var currentPhase: StudyPhase?

    /// The practice payload is the same size as the small module, so the participant has met the
    /// screens and the AR view before anything is measured for real. Deliberately derived rather than
    /// written out again, so the two cannot drift apart.
    static var practiceModuleSizeMillimetres: SIMD3<Double> {
        StudyBox.small.sizeMillimetres
    }

    init() {
        saved = Self.loadAll()
    }

    // MARK: - Current position

    /// Nil during the practice run and before the participant's Start tap. Nothing measured in
    /// practice is recorded, and the configured payload cannot leak into a pre-start timer.
    var currentBox: StudyBox? {
        guard !isPractice,
              !isAwaitingParticipantStart,
              let activeRun,
              activeRun.boxOrder.indices.contains(currentBoxIndex) else { return nil }
        return activeRun.boxOrder[currentBoxIndex]
    }

    /// The payload shown on a neutral handoff screen. Unlike `currentBox`, this remains available
    /// while timing is deliberately stopped.
    var scheduledBox: StudyBox? {
        guard !isPractice,
              let activeRun,
              activeRun.boxOrder.indices.contains(currentBoxIndex) else { return nil }
        return activeRun.boxOrder[currentBoxIndex]
    }

    /// Whether the measuring screens should be up at all: a box, or the practice payload.
    var hasActiveSession: Bool {
        activeRun != nil && !isAwaitingParticipantStart && (isPractice || currentBox != nil)
    }

    /// The module the plan is built for.
    var activeModuleSizeMillimetres: SIMD3<Double>? {
        isPractice ? Self.practiceModuleSizeMillimetres : currentBox?.sizeMillimetres
    }

    var isOnLastBox: Bool {
        guard let activeRun else { return false }
        return currentBoxIndex >= activeRun.boxOrder.count - 1
    }

    /// Practice uses the first condition so the participant learns the interface they will see
    /// first. Recorded boxes resolve their condition from the two-box schedule.
    var currentInputMode: StudyInputMode {
        guard let activeRun else { return .augmentedReality }
        if isPractice { return activeRun.resolvedFirstInputMode }
        guard activeRun.inputModeOrder.indices.contains(currentBoxIndex) else {
            return .augmentedReality
        }
        return activeRun.inputModeOrder[currentBoxIndex]
    }

    var nextInputMode: StudyInputMode? {
        guard let activeRun,
              !isPractice,
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
        includesPractice: Bool,
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
        run.includedPracticeRun = includesPractice
        run.includesBothPayloads = true
        run.inputPlan = inputPlan
        run.firstInputMode = inputPlan == .arOnly
            ? .augmentedReality
            : inputPlan == .manualOnly ? .manual : inputPlan == .both ? firstInputMode : nil
        // Fixed once, at the start: everything this run writes goes into this one folder, and the name
        // is checked against what is on disk rather than against the app's own list. A folder left
        // behind by a run that was deleted in the app is therefore never written into by a new one.
        run.folderName = Self.availableFolderName(base: run.exportBaseName)
        activeRun = run
        currentBoxIndex = 0
        isPractice = includesPractice
        isAwaitingParticipantStart = true
        persistActiveRun()
    }

    /// Leaves the administrator-free handoff screen and starts the selected workflow. This is the
    /// exact point at which the first timer starts.
    func beginParticipantSession() {
        guard var run = activeRun, isAwaitingParticipantStart else { return }
        if currentBoxIndex == 0, run.boxes.isEmpty {
            run.createdAt = Date()
        }
        activeRun = run
        persistActiveRun()
        if isPractice {
            isAwaitingParticipantStart = false
            // No box result yet. The first one is opened when the practice ends, so its start time is
            // when the study actually began rather than when the participant started playing.
            beginPhase(.measure)
        } else {
            openCurrentBox()
        }
    }

    /// The practice payload is done. Everything measured on it is dropped and the study begins.
    func startRealStudy() {
        guard isPractice else { return }
        endCurrentPhase()
        isPractice = false
        currentBoxIndex = 0
        isAwaitingParticipantStart = true
    }

    private func openCurrentBox() {
        guard var run = activeRun else { return }
        isPractice = false
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
        activeRun = run
        isAwaitingParticipantStart = true
        persistActiveRun()
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

    /// Dismisses a completed condition back to administrator setup while preserving the saved run
    /// and its exported report. The other condition is deliberately not started automatically.
    func returnToSetupAfterCompletion() {
        guard activeRun?.isComplete == true else { return }
        activeRun = nil
        currentBoxIndex = 0
        isPractice = false
        isAwaitingParticipantStart = false
        currentPhase = nil
        phaseStartedAt = nil
    }

    /// Whether a saved run already uses this participant name. Compared case- and space-insensitively,
    /// because "P01" and "p01 " are the same participant to everyone except a string comparison.
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

    /// Deletes a saved run and everything under it: the JSON, the photos and the report.
    ///
    /// This is here because it was asked for, behind `restartPassword`, and it is the one destructive
    /// action in the app. It cannot be undone and there is no copy anywhere else, so every caller puts
    /// the password in front of it.
    func delete(runID: UUID) {
        let deleted = run(withID: runID)
        let folder = runFolder(runID: runID)
        let legacyReportName = deleted?.legacyReportFileName
        saved.removeAll { $0.id == runID }
        if activeRun?.id == runID {
            activeRun = nil
            currentBoxIndex = 0
            isPractice = false
            isAwaitingParticipantStart = false
            currentPhase = nil
            phaseStartedAt = nil
        }
        try? FileManager.default.removeItem(at: folder)
        // Earlier versions also left a copy of the report at the top of StudyRuns. Nothing writes one
        // any more, but a run recorded back then still has one to clear.
        if let legacyReportName {
            try? FileManager.default.removeItem(
                at: Self.rootFolder.appendingPathComponent(legacyReportName)
            )
        }
        lastExportURL = nil
    }

    /// Clears the run in progress without touching anything already saved.
    func clearActiveRun() {
        endCurrentPhase()
        activeRun = nil
        currentBoxIndex = 0
        isPractice = false
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

    /// Includes both already-persisted seconds and the live interval. Passing the TimelineView date
    /// keeps rendering read-only and makes the boundary behaviour directly testable.
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
        run.boxes[index].inputMode = currentInputMode
        run.boxes[index].loadedObjectIDs = loadedObjectIDs
        run.boxes[index].unloadedObjectNames = unloadedObjectNames
        run.boxes[index].packingMode = packingMode
        run.boxes[index].centreOfMassMillimetres = centreOfMass.map { [$0.x, $0.y, $0.z] }
        run.boxes[index].unbalancingIndexMillimetres = unbalancingIndex
        activeRun = run
        persistActiveRun()
    }

    /// Writes one object's photo into the run folder and returns the file name to store with it.
    ///
    /// Named after the object and the payload it was measured for, so the photos folder can be read by
    /// a person. Object names are unique within a run, and re-recording the same box overwrites its own
    /// photos, so the name identifies the file for the whole run.
    @discardableResult
    func storePhoto(_ data: Data, objectID: UUID, objectName: String? = nil) -> String? {
        guard !isPractice, let run = activeRun else { return nil }
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

    /// One report, inside the run's own folder, named after the run. There used to be a second copy at
    /// the top of StudyRuns as well; with a folder per run there is nothing left to dig through, and two
    /// copies of the same report is how a folder becomes a mess.
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
        guard let activeRun else { return }
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
    //     <Run name>.txt      the whole run as text
    //     run.json            what the app reads back
    //     photos/             one JPEG per object, named after the object
    //   <Run name>(1)/        a second run whose name was already taken
    //
    // Runs written before this layout are in a folder named after their id, and are still found there:
    // `folderName` is what moved, and it is nil for those.

    static func runFolder(for run: StudyRun) -> URL {
        rootFolder.appendingPathComponent(run.exportFolderName, isDirectory: true)
    }

    static func photosFolder(for run: StudyRun) -> URL {
        runFolder(for: run).appendingPathComponent("photos", isDirectory: true)
    }

    /// Resolves a run's folder from its id, for the screens that only carry one.
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

    /// The name to give a new run's folder: its own, or its own with a number in brackets when that is
    /// taken. Everything already in StudyRuns counts as taken, whether or not the app still lists it.
    static func availableFolderName(base: String) -> String {
        let existing = (try? FileManager.default.contentsOfDirectory(
            atPath: rootFolder.path
        )) ?? []
        return uniqueFolderName(base: base, taken: Set(existing))
    }

    /// `Run`, then `Run(1)`, `Run(2)`, … Comparison ignores case, because two folders differing only in
    /// case are the same folder on this file system and one run would then write over another.
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
