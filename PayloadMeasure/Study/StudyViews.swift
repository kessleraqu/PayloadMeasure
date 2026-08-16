import SwiftUI

// The screens that wrap a session in a user study: setup, the password gate, the results screen and
// the archive of every run ever recorded.
//
// In:  StudyStore.
// Out: on screen only, plus the text reports StudyStore writes.
//
// Nothing here can delete a run. The archive is read-only by design.

// MARK: - Setup

struct StudySetupView: View {
    let warmup: AppWarmup
    let store: StudyStore
    let accuracy: AccuracyStore

    @State private var name = ""
    @State private var date = Date()
    @State private var flow: MeasurementFlow = .batch
    @State private var firstBox: StudyBox = .big
    @State private var includesPractice = true
    @State private var showsArchive = false
    @State private var showsAccuracy = false
    @State private var editedCatalogue: StudyBox?
    /// One per payload, kept for the life of this screen so the lists redraw as they are edited.
    @State private var catalogues: [StudyBox: BoxCatalogue] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section("Participant") {
                    TextField("Name or code", text: $name)
                        .textInputAutocapitalization(.words)
                    DatePicker("Study date", selection: $date, displayedComponents: [.date, .hourAndMinute])
                }

                Section {
                    Picker("Method", selection: $flow) {
                        ForEach(MeasurementFlow.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Method")
                } footer: {
                    Text(flow.detail)
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
                    Text("Which payload box first")
                } footer: {
                    Text("The participant fills both. This only sets the order, which should be counterbalanced across participants. Second: \(firstBox.other.shortTitle).")
                }

                Section {
                    Toggle("Practice run first", isOn: $includesPractice)
                } footer: {
                    Text(practiceFooter)
                }

                Section {
                    // Starts immediately rather than waiting on the warmup. The measuring screen
                    // shows the live camera with instructions while the rest finishes loading, which
                    // is more useful than a spinner on a form.
                    Button {
                        start()
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
                } footer: {
                    Text("Nothing to do with a participant: measure the same objects over and over, type in their real sizes, and see how far out the app is.")
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
            .sheet(item: $editedCatalogue) { payload in
                BoxCatalogView(catalogue: catalogue(for: payload))
            }
        }
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
        return "The participant measures and loads a practice payload of \(centimetres) first, to learn the app. Nothing from it is recorded. The study proper starts from the arrangement screen, behind the password."
    }

    private func start() {
        store.startRun(
            participantName: name,
            studyDate: date,
            flow: flow,
            firstBox: firstBox,
            includesPractice: includesPractice
        )
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

                Text("Nothing on this screen can be deleted. Every run stays on the device.")
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
            Text("\(methodTitle) · \(run.boxOrder.map(\.shortTitle).joined(separator: " then "))")
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

    var body: some View {
        NavigationStack {
            Group {
                if store.saved.isEmpty {
                    ContentUnavailableView {
                        Label("No runs yet", systemImage: "tray")
                    } description: {
                        Text("Completed study runs appear here and are never removed.")
                    }
                } else {
                    List {
                        ForEach(store.saved) { run in
                            row(for: run)
                        }
                    }
                }
            }
            .navigationTitle("Saved runs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(for run: StudyRun) -> some View {
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
        }
    }

    private func summary(for run: StudyRun) -> String {
        run.isComplete
            ? "Both boxes · " + StudyRun.durationText(run.totalSeconds)
            : "Incomplete"
    }
}
