import SwiftUI
import simd

// The accuracy test screens: set the test up, measure the objects round after round, then type in the
// real sizes and read the figures.
//
// In:  AccuracyStore.
// Out: on screen only, plus the text reports AccuracyStore writes.
//
// Every screen has a way back to the main page, including while measuring — the test is written to
// disk after each reading, so leaving and coming back loses nothing.

struct AccuracySiteView: View {
    let store: AccuracyStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.activeTest == nil {
                    AccuracySetupView(store: store)
                } else if store.isMeasuring {
                    AccuracyMeasureView(store: store)
                } else {
                    AccuracyResultsView(store: store)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Main page") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Setup

private struct AccuracySetupView: View {
    let store: AccuracyStore

    @State private var label = ""
    @State private var objectCount = 3
    @State private var passes = 10

    var body: some View {
        Form {
            Section("This test") {
                TextField("Label, for example \"iPhone 15 Pro, office\"", text: $label)
                Stepper("Objects: \(objectCount)", value: $objectCount, in: 1...AccuracyStore.maximumObjects)
                Stepper("Times each: \(passes)", value: $passes, in: 1...AccuracyStore.maximumPasses)
            }

            Section {
                Button {
                    store.startTest(label: label, objectCount: objectCount, passes: passes)
                } label: {
                    Text("Start measuring").font(.headline)
                }
            } footer: {
                Text("\(objectCount * passes) measurements in total: object 1 to \(objectCount), then round again, \(passes) times. Measure them in the same order every round. Type the real sizes in at the end.")
            }

            if !store.saved.isEmpty {
                Section("Earlier tests") {
                    ForEach(store.saved) { test in
                        Button {
                            store.resume(test)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(test.label.isEmpty ? "Untitled test" : test.label)
                                    .font(.headline)
                                Text(StudyRun.displayDateFormatter.string(from: test.createdAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(test.readings.count) of \(test.totalExpectedReadings) readings")
                                    .font(.caption2)
                                    .foregroundStyle(test.isComplete ? Color.secondary : Color.orange)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Accuracy test")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Measuring

private struct AccuracyMeasureView: View {
    let store: AccuracyStore

    // Its own session and engine. Nothing else is on screen while this is up, and keeping them
    // separate means an accuracy test can never leave state behind in a study.
    @State private var sessionManager = ARSessionManager()
    @State private var aimerState = AimerState()
    @State private var captureEngine = ObjectCaptureEngine()
    @State private var lastRecorded: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            ARCameraView(
                sessionManager: sessionManager,
                aimerState: aimerState,
                captureEngine: captureEngine,
                workflowMode: .spatial3D
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                banner
                Spacer()
                controls
            }
            .padding(16)
        }
        .navigationTitle("Measuring")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { captureEngine.setMeasurementMode(.spatial3D) }
        .onChange(of: scenePhase) { _, phase in
            sessionManager.setApplicationActive(phase == .active)
        }
    }

    private var banner: some View {
        VStack(spacing: 4) {
            Text(store.progressText)
                .font(.headline)
            Text(captureEngine.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let lastRecorded {
                Text(lastRecorded)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if captureEngine.activeObjectID == nil {
                Button("Measure") {
                    captureEngine.requestObjectMaskToggle(at: CGPoint(x: 0.5, y: 0.5))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .disabled(!canStart)

                if store.activeTest?.readings.isEmpty == false {
                    Button("Undo the last reading") { store.undoLastReading() }
                        .font(.footnote)
                }
            } else {
                Button("Save this reading") { saveReading() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .disabled(!captureEngine.canFinalizeActiveObject)
                    .tint(captureEngine.convergence.isConverged ? .green : .accentColor)

                Button("Cancel this measurement") {
                    captureEngine.cancelActiveMeasurement()
                }
                .font(.footnote)
            }
        }
    }

    private var canStart: Bool {
        sessionManager.isTrackingReady
            && sessionManager.isObjectTrackingEnvironmentReady
            && captureEngine.hasCompletedObjectRecognitionWarmup
            && !captureEngine.isObjectSelectionPending
    }

    /// Finishes the measurement, files the size, then throws the object away again. Keeping it would
    /// grow the scene and slow every later reading down, and the test only ever needs the numbers.
    private func saveReading() {
        guard let id = captureEngine.lockActiveObject(),
              let captured = captureEngine.capturedObjectsByID[id] else {
            return
        }
        let size = captured.sizeMillimetres
        if store.record(sizeMillimetres: size) {
            lastRecorded = "Recorded \(AccuracyTestRun.sizeText([size.x, size.y, size.z]))"
        }
        captureEngine.removeFinalizedObject(id: id)
    }
}

// MARK: - Results

private struct AccuracyResultsView: View {
    let store: AccuracyStore

    @State private var showsDownload = false
    @State private var downloadURL: URL?

    private var test: AccuracyTestRun { store.activeTest ?? AccuracyTestRun(id: UUID(), createdAt: Date(), label: "", objectCount: 1, passes: 1) }

    var body: some View {
        List {
            Section {
                ForEach(test.objectNumbers, id: \.self) { number in
                    AccuracyReferenceRow(store: store, objectNumber: number)
                }
            } header: {
                Text("The real sizes")
            } footer: {
                Text("Measure each object with a ruler or calliper and type it in. Order does not matter: sides are compared largest to largest, so turning an object between rounds is not counted as an error.")
            }

            if let summary = store.summary, !summary.objects.isEmpty {
                Section("Overall") {
                    figure(
                        "Readings compared",
                        "\(summary.readingCount) · \(summary.comparisonCount) sides"
                    )
                    figure("Bias (trueness)", AccuracyTestRun.number(summary.bias) + " mm")
                    figure("SD of errors", AccuracyTestRun.number(summary.errorStandardDeviation) + " mm")
                    figure("Mean absolute error", AccuracyTestRun.number(summary.meanAbsoluteError) + " mm")
                    figure("RMSE", AccuracyTestRun.number(summary.rootMeanSquareError) + " mm")
                    figure("Largest single error", AccuracyTestRun.number(summary.maximumAbsoluteError) + " mm")
                    figure(
                        "95% limits of agreement",
                        AccuracyTestRun.number(summary.limitsOfAgreement.lower) + " to "
                            + AccuracyTestRun.number(summary.limitsOfAgreement.upper) + " mm"
                    )
                    figure(
                        "Worst repeatability SD",
                        AccuracyTestRun.number(summary.worstRepeatabilityStandardDeviation) + " mm"
                    )
                }

                ForEach(summary.objects, id: \.objectNumber) { object in
                    Section("Object \(object.objectNumber) · \(AccuracyTestRun.sizeText(object.reference))") {
                        ForEach(object.axes, id: \.axisIndex) { axis in
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(axis.axisLabel.capitalized) side · reference \(AccuracyTestRun.number(axis.reference)) mm")
                                    .font(.subheadline.weight(.semibold))
                                Text("mean \(AccuracyTestRun.number(axis.mean)) · bias \(AccuracyTestRun.number(axis.bias)) (\(AccuracyTestRun.number(axis.relativeBiasPercent))%)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("sd \(AccuracyTestRun.number(axis.standardDeviation)) · RMSE \(AccuracyTestRun.number(axis.rootMeanSquareError)) · worst \(AccuracyTestRun.number(axis.maximumAbsoluteError))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            } else {
                Section {
                    Text("Type at least one object's real size to see the figures.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Readings") {
                ForEach(test.objectNumbers, id: \.self) { number in
                    let readings = test.readings(forObject: number)
                    if !readings.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Object \(number)").font(.subheadline.weight(.semibold))
                            ForEach(readings) { reading in
                                Text("pass \(reading.pass): \(reading.sizeText)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                Button {
                    downloadURL = store.exportReport(for: test)
                    showsDownload = downloadURL != nil
                } label: {
                    Label("Download the report", systemImage: "square.and.arrow.down")
                }
                if let url = store.lastExportURL {
                    ShareLink(item: url) {
                        Label("Share instead", systemImage: "square.and.arrow.up")
                    }
                }
                Button("Close this test") { store.closeActiveTest() }
            } footer: {
                if let message = store.message {
                    Text(message)
                }
            }
        }
        .navigationTitle("Accuracy results")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsDownload) {
            if let downloadURL {
                DocumentExporter(url: downloadURL) { _ in showsDownload = false }
                    .ignoresSafeArea()
            }
        }
    }

    private func figure(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer(minLength: 8)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

/// One object's reference size. Kept as its own view so each set of three fields owns its own text
/// state and typing in one does not redraw the whole results list.
private struct AccuracyReferenceRow: View {
    let store: AccuracyStore
    let objectNumber: Int

    @State private var first = ""
    @State private var second = ""
    @State private var third = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Object \(objectNumber)")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                field("mm", text: $first)
                Text("×").foregroundStyle(.secondary)
                field("mm", text: $second)
                Text("×").foregroundStyle(.secondary)
                field("mm", text: $third)
            }
        }
        .padding(.vertical, 2)
        .onAppear(perform: load)
        .onChange(of: first) { _, _ in commit() }
        .onChange(of: second) { _, _ in commit() }
        .onChange(of: third) { _, _ in commit() }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 8))
    }

    private func load() {
        guard let values = store.activeTest?.reference(forObject: objectNumber) else { return }
        first = PositiveDecimalText.format(values[0], maximumFractionDigits: 2) ?? ""
        second = PositiveDecimalText.format(values[1], maximumFractionDigits: 2) ?? ""
        third = PositiveDecimalText.format(values[2], maximumFractionDigits: 2) ?? ""
    }

    /// Same parser the weight fields use, so a comma works as a decimal mark here too.
    private func commit() {
        let values = [first, second, third].compactMap(PositiveDecimalText.parse)
        guard values.count == 3 else {
            store.setReference(nil, forObject: objectNumber)
            return
        }
        store.setReference(SIMD3(values[0], values[1], values[2]), forObject: objectNumber)
    }
}
