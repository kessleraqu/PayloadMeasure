import SwiftUI

// The screens that wrap a session in a user study: setup, the password gate, the results screen and
// the archive of every run ever recorded.
//
// In:  StudyStore.
// Out: on screen only, plus the text reports StudyStore writes.
//
// Saved runs can be deleted only through the archive's explicit red action and password gate.

// MARK: - Setup

struct StudySetupView: View {
    let warmup: AppWarmup
    let store: StudyStore
    let accuracy: AccuracyStore
    let framingAccuracy: FramingAccuracyStore

    @State private var name = ""
    @State private var date = Date()
    @State private var firstBox: StudyBox = .big
    @State private var inputMode: StudyInputMode = .augmentedReality
    @State private var includesPractice = true
    @State private var showsArchive = false
    @State private var showsAccuracy = false
    @State private var showsFramingAccuracy = false
    @State private var editedCatalogue: StudyBox?
    @State private var duplicateRun: StudyRun?
    @State private var showsOverwritePassword = false
    /// One per payload, kept for the life of this screen so the lists redraw as they are edited.
    @State private var catalogues: [StudyBox: BoxCatalogue] = [:]

    var body: some View {
        NavigationStack {
            Form {
                resumeSection

                Section("Participant") {
                    TextField("Name or code", text: $name)
                        .textInputAutocapitalization(.words)
                    DatePicker("Study date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                }

                Section {
                    Label("Measure all, then prepare and weigh all", systemImage: "square.grid.2x2")
                } header: {
                    Text("Object workflow")
                } footer: {
                    Text("Every condition follows the same controlled sequence: measure or enter every object, prepare and weigh every package, then optimise the placement.")
                }

                Section {
                    Picker("Condition", selection: $inputMode) {
                        ForEach(StudyInputMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Condition for this run")
                } footer: {
                    Text("Select one condition only. When it finishes, the app returns here so you can configure the other condition as a separate run.")
                }

                Section {
                    Picker("First box", selection: $firstBox) {
                        ForEach(StudyBox.allCases) { box in
                            Text(box.title).tag(box)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("First payload box")
                } footer: {
                    Text("The selected condition uses both payloads. The chosen size is first, followed by the other size after a separate Start screen.")
                }

                Section {
                    Toggle("Practice run first", isOn: $includesPractice)
                } footer: {
                    Text(practiceFooter)
                }

                Section {
                    // Stages the run, then replaces this administrator form with the neutral
                    // participant handoff. Timing and the workflow start only after that Start tap.
                    Button {
                        // A repeated participant name almost always means the operator has typed the
                        // wrong one, so it is refused rather than quietly making a second run that is
                        // indistinguishable from the first in the archive.
                        if let existing = store.savedRun(named: name, inputMode: inputMode) {
                            duplicateRun = existing
                        } else {
                            start()
                        }
                    } label: {
                        Text("Start the study")
                            .font(.headline)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Saved runs (\(store.saved.count))") {
                        showsArchive = true
                    }
                }

                Section {
                    Button {
                        editedCatalogue = StudyBox.big
                    } label: {
                        boxRow(for: .big)
                    }
                    Button {
                        editedCatalogue = StudyBox.small
                    } label: {
                        boxRow(for: .small)
                    }
                } header: {
                    Text("Package boxes")
                } footer: {
                    Text("Each payload has its own boxes. The practice payload uses the small one's, being the same size.")
                }

                Section {
                    Button {
                        showsAccuracy = true
                    } label: {
                        Label("Accuracy test", systemImage: "ruler")
                    }
                    Button {
                        showsFramingAccuracy = true
                    } label: {
                        Label("Distance and framing test", systemImage: "viewfinder")
                    }
                } footer: {
                    Text("Independent tools: compare Top and 3D measurements, or measure one object inside five framing boxes to calibrate distance guidance.")
                }
            }
            .navigationTitle("New study run")
            .onAppear(perform: warmup.start)
            .sheet(isPresented: $showsArchive) {
                StudyArchiveView(store: store)
            }
            .fullScreenCover(isPresented: $showsAccuracy) {
                AccuracySiteView(store: accuracy)
            }
            .fullScreenCover(isPresented: $showsFramingAccuracy) {
                FramingAccuracySiteView(store: framingAccuracy)
            }
            .sheet(item: $editedCatalogue) { payload in
                BoxCatalogView(catalogue: catalogue(for: payload))
            }
            .alert("That name is already used", isPresented: duplicateIsPresented) {
                Button("Cancel", role: .cancel) { duplicateRun = nil }
                Button("Overwrite", role: .destructive) { showsOverwritePassword = true }
            } message: {
                Text("A \(inputMode.title) run for \(duplicateRun?.participantName ?? "this participant") was recorded on \(duplicateRun.map { StudyRun.displayDateFormatter.string(from: $0.studyDate) } ?? ""). Overwriting deletes it and everything in it. The participant's other condition is not affected.")
            }
            .sheet(isPresented: $showsOverwritePassword) {
                StudyPasswordSheet(
                    title: "Overwrite the run",
                    message: "Deletes the earlier run for this participant, with its photos and report, and starts again. This cannot be undone.",
                    password: StudyStore.nextBoxPassword,
                    confirmTitle: "Overwrite"
                ) {
                    if let duplicateRun {
                        store.delete(runID: duplicateRun.id)
                    }
                    duplicateRun = nil
                    start()
                }
            }
        }
    }

    /// The first thing on the screen when a run was left unfinished — because after a crash, this is the
    /// screen the operator is looking at while wondering whether the session is gone.
    @ViewBuilder
    private var resumeSection: some View {
        if let run = store.resumableRun {
            Section {
                Button {
                    store.resumeRun(run)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Continue \(run.participantName)")
                                .font(.headline)
                            Text(resumeDetail(for: run))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title2)
                    }
                }
            } header: {
                Text("Unfinished run")
            } footer: {
                Text("Everything already saved is kept, including the time recorded for finished payloads. The payload that was in progress is measured again — its measurements belonged to the camera session that ended.")
            }
        }
    }

    private func resumeDetail(for run: StudyRun) -> String {
        let finished = run.boxOrder.filter { run.result(for: $0)?.completedAt != nil }
        let next = run.boxOrder.first { run.result(for: $0)?.completedAt == nil }
        let condition = run.inputModeOrder.first?.title ?? "AR measurement"
        let progress = finished.isEmpty
            ? "nothing finished yet"
            : "\(finished.count) of \(run.boxOrder.count) payloads finished"
        return "\(condition) · \(progress) · continues on the \(next?.shortTitle.lowercased() ?? "next payload")"
    }

    private var duplicateIsPresented: Binding<Bool> {
        Binding(
            get: { duplicateRun != nil && !showsOverwritePassword },
            set: { if !$0 { duplicateRun = nil } }
        )
    }

    private func catalogue(for payload: StudyBox) -> BoxCatalogue {
        if let existing = catalogues[payload] { return existing }
        let created = BoxCatalogue(payload: payload)
        catalogues[payload] = created
        return created
    }

    private func boxRow(for payload: StudyBox) -> some View {
        let presets = catalogue(for: payload).presets
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(payload.shortTitle)
                    .font(.body)
                Text(presets.isEmpty
                    ? "No boxes"
                    : presets.map(\.name).joined(separator: ", "))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Text("\(presets.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var practiceFooter: String {
        guard includesPractice else {
            return "The participant goes straight into the first payload box."
        }
        let size = StudyStore.practiceModuleSizeMillimetres
        let centimetres = String(
            format: "%.0f × %.0f × %.0f cm",
            size.x / 10, size.y / 10, size.z / 10
        )
        return "The participant uses \(inputMode.title.lowercased()) for a practice payload of \(centimetres) first. Nothing from it is recorded. The same selected condition is then used for both study payloads."
    }

    private func start() {
        store.startRun(
            participantName: name,
            studyDate: date,
            flow: .batch,
            firstBox: firstBox,
            includesPractice: includesPractice,
            inputPlan: inputMode == .augmentedReality ? .arOnly : .manualOnly,
            firstInputMode: inputMode
        )
    }
}

// MARK: - Participant handoff

/// A deliberately neutral screen between the administrator's setup and the timed study. The
/// participant sees no names, condition controls, payload choices, or saved study data.
struct StudyParticipantStartView: View {
    let store: StudyStore
    let onStart: () -> Void

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            VStack {
                StudyTimerStrip(study: store)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                Spacer()
            }

            Button(buttonTitle, action: onStart)
                .font(.title2.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 48)
                .accessibilityHint("Starts the study and its timer")
        }
        .preferredColorScheme(.light)
    }

    private var buttonTitle: String {
        if store.isPractice {
            return "Start practice"
        }
        guard let box = store.scheduledBox else { return "Start" }
        return "Start \(box.shortTitle.lowercased())"
    }
}

// MARK: - Password gate

struct StudyPasswordSheet: View {
    let title: String
    let message: String
    let password: String
    let confirmTitle: String
    let onUnlocked: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var entry = ""
    @State private var wasWrong = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $entry)
                        .keyboardType(.numberPad)
                        .onChange(of: entry) { _, _ in wasWrong = false }
                    if wasWrong {
                        Text("That is not the right password.")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text(message)
                }

                Section {
                    Button(confirmTitle) {
                        if entry == password {
                            onUnlocked()
                            dismiss()
                        } else {
                            wasWrong = true
                        }
                    }
                    .disabled(entry.isEmpty)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Results

struct StudyResultsView: View {
    let run: StudyRun
    let store: StudyStore
    /// Nil in the archive, where there is nothing to restart.
    var onRestart: (() -> Void)? = nil

    @State private var showsRestartPassword = false
    @State private var exportNote: String?
    @State private var showsDownload = false
    @State private var downloadURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                ForEach(run.boxOrder, id: \StudyBox.id) { box in
                    if let result = run.result(for: box) {
                        boxSection(result)
                    }
                }

                exportSection

                if onRestart != nil {
                    Button("Restart for the next participant") {
                        showsRestartPassword = true
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                }

                Text("Runs stay on the device. Deleting one is possible from Saved runs, behind the password.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Study data")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Automatic on arrival, as well as on demand below.
            if store.exportReport(for: run) != nil {
                exportNote = "Report saved to Files › PayloadMeasure › StudyRuns."
            }
        }
        .sheet(isPresented: $showsRestartPassword) {
            StudyPasswordSheet(
                title: "Restart the app",
                message: "Clears the screen for the next participant. The data you are looking at is kept and stays in Saved runs.",
                password: StudyStore.restartPassword,
                confirmTitle: "Restart"
            ) {
                onRestart?()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(run.participantName)
                .font(.title2.weight(.semibold))
            Text(StudyRun.displayDateFormatter.string(from: run.studyDate))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(methodTitle) · \(run.inputModeOrder.map(\.shortTitle).joined(separator: " then ")) · \(run.boxOrder.map(\.shortTitle).joined(separator: " then "))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var methodTitle: String {
        MeasurementFlow(rawValue: run.flow)?.title ?? run.flow
    }

    private func boxSection(_ result: StudyBoxResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.box.title)
                .font(.headline)

            Label(
                (result.inputMode ?? run.inputMode(for: result.box)).title,
                systemImage: (result.inputMode ?? run.inputMode(for: result.box)).systemImage
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 14) {
                ForEach(StudyPhase.allCases, id: \.self) { phase in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(StudyRun.durationText(result.seconds(for: phase)))
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 14) {
                Text("Total \(StudyRun.durationText(result.totalSeconds))")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                if let mode = result.packingMode {
                    Text("Version: \(mode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if result.objects.isEmpty {
                Text("No objects recorded for this box.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(result.objects) { object in
                    objectRow(object, loaded: result.loadedObjectIDs.contains(object.id))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }

    private func objectRow(_ object: StudyObjectRecord, loaded: Bool) -> some View {
        HStack(alignment: .top, spacing: 11) {
            photo(for: object)
                .frame(width: 58, height: 58)
                .clipShape(.rect(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(object.name)
                        .font(.subheadline.weight(.semibold))
                    if !loaded {
                        Text("not loaded")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                }
                Text("Measured \(object.measuredSizeText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Packed as \(object.packagedSizeText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(packageDescription(object))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let mass = object.massKilograms {
                    Text(String(format: "%.0f g", mass * 1000))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func packageDescription(_ object: StudyObjectRecord) -> String {
        if object.isOwnBox { return "Package: the object itself" }
        if object.hasEnforcedSize { return "Package: size entered by hand" }
        return "Package: \(object.assignedBoxName ?? "none assigned")"
    }

    @ViewBuilder
    private func photo(for object: StudyObjectRecord) -> some View {
        if let fileName = object.photoFileName,
           let image = UIImage(contentsOfFile: store.photoURL(runID: run.id, fileName: fileName).path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Writes the txt, then opens the system save panel on it. Two steps in one button,
            // because "download" means ending up with a file, not with a share sheet.
            Button {
                downloadURL = store.exportReport(for: run)
                if downloadURL != nil {
                    showsDownload = true
                } else {
                    exportNote = "Could not write the report."
                }
            } label: {
                Label("Download the report", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)

            if let url = store.lastExportURL {
                ShareLink(item: url) {
                    Label("Share instead", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            }

            if let note = exportNote ?? store.exportMessage {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(run.reportFileName)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
            Text("Every report is also in Files › On My iPhone › PayloadMeasure.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showsDownload) {
            if let downloadURL {
                DocumentExporter(url: downloadURL) { saved in
                    exportNote = saved
                        ? "Saved. Look for it wherever you chose."
                        : "Nothing was saved."
                    showsDownload = false
                }
                .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Archive

struct StudyArchiveView: View {
    let store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeletion: StudyRun?
    @State private var showsDeletePassword = false

    var body: some View {
        NavigationStack {
            Group {
                if store.saved.isEmpty {
                    ContentUnavailableView {
                        Label("No runs yet", systemImage: "tray")
                    } description: {
                        Text("Completed study runs appear here. Each row has a password-protected Delete button.")
                    }
                } else {
                    List {
                        ForEach(store.saved) { run in
                            row(for: run)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        pendingDeletion = run
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("Saved runs")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Delete this run?", isPresented: deletionIsPresented) {
                Button("Cancel", role: .cancel) { pendingDeletion = nil }
                Button("Delete", role: .destructive) { showsDeletePassword = true }
            } message: {
                Text("\(pendingDeletion?.participantName ?? "This run"), with its photos and report. There is no copy anywhere else.")
            }
            .sheet(
                isPresented: $showsDeletePassword,
                onDismiss: { pendingDeletion = nil }
            ) {
                StudyPasswordSheet(
                    title: "Delete the run",
                    message: "Removes it and everything in it from the device for good.",
                    password: StudyStore.nextBoxPassword,
                    confirmTitle: "Delete"
                ) {
                    if let pendingDeletion {
                        store.delete(runID: pendingDeletion.id)
                    }
                    pendingDeletion = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var deletionIsPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil && !showsDeletePassword },
            set: {
                if !$0, !showsDeletePassword {
                    pendingDeletion = nil
                }
            }
        )
    }

    private func row(for run: StudyRun) -> some View {
        HStack(spacing: 10) {
            NavigationLink {
                StudyResultsView(run: run, store: store)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.participantName)
                        .font(.headline)
                    Text(StudyRun.displayDateFormatter.string(from: run.studyDate))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(summary(for: run))
                        .font(.caption2)
                        .foregroundStyle(run.isComplete ? Color.secondary : Color.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(role: .destructive) {
                pendingDeletion = run
            } label: {
                Label("Delete", systemImage: "trash")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .frame(minHeight: 40)
                    .background(Color.red.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Asks for confirmation and the study password before deleting.")
        }
    }

    private func summary(for run: StudyRun) -> String {
        run.isComplete
            ? run.inputModeOrder.map(\.shortTitle).joined(separator: " then ")
                + " · "
                + (run.boxOrder.count == 2 ? "Both boxes" : run.boxOrder[0].shortTitle)
                + " · " + StudyRun.durationText(run.totalSeconds)
            : "Incomplete"
    }
}
