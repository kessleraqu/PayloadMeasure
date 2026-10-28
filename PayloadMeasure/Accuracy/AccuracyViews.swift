import SwiftUI
import simd

// Accuracy test screens: setup, measuring, and entering reference sizes to see the results.
// The test is saved after every reading, so it's safe to leave at any point.

struct AccuracySiteView: View {
    let store: AccuracyStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sharedARViewHost) private var sharedARViewHost

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
        .onAppear {
            sharedARViewHost?.requestNewMeasurementWorld()
        }
    }
}

// MARK: - Setup

private struct AccuracySetupView: View {
    let store: AccuracyStore

    @State private var label = ""
    @State private var objectCount = 4
    @State private var passes = 5

    var body: some View {
        Form {
            Section("This test") {
                TextField("Label, for example \"iPhone 15 Pro, office\"", text: $label)
                Stepper("Objects: \(objectCount)", value: $objectCount, in: 1...AccuracyStore.maximumObjects)
                Stepper("Times each: \(passes)", value: $passes, in: 1...AccuracyStore.maximumPasses)
            }

            Section("Measurement methods") {
                Label("Top view", systemImage: "arrow.down.to.line")
                Label("Full 3D · top + 3/4 or side", systemImage: "cube.transparent")
            }

            Section {
                Button {
                    store.startTest(label: label, objectCount: objectCount, passes: passes)
                } label: {
                    Text("Start measuring").font(.headline)
                }
            } footer: {
                Text("\(objectCount * passes * 2) measurements in total: \(objectCount * passes) Top readings, then \(objectCount * passes) 3D readings. Each 3D reading uses an overhead view plus an isometric or lateral view. Type the real sizes in at the end.")
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
                                Text("\(test.readings.count) of \(test.totalExpectedReadings) readings · \(test.measurementModes.map(\.shortTitle).joined(separator: " + "))")
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

    // Separate session manager and engine so accuracy data stays apart from the study. The ARView
    // itself is shared.
    @State private var sessionManager = ARSessionManager()
    @State private var aimerState = AimerState()
    @State private var captureEngine = ObjectCaptureEngine()
    @State private var lastRecorded: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sharedARViewHost) private var sharedARViewHost

    private var workflowMode: MeasurementWorkflowMode {
        store.nextSlot?.workflowMode ?? .spatial3D
    }

    var body: some View {
        ZStack {
            ARCameraView(
                sessionManager: sessionManager,
                aimerState: aimerState,
                captureEngine: captureEngine,
                workflowMode: workflowMode,
                sharedViewHost: sharedARViewHost
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topHUD
                Spacer()
                VStack(spacing: 10) {
                    measurementCard
                    controls
                }
            }
            .padding(16)
        }
        .navigationTitle("Measuring")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            sessionManager.setApplicationActive(scenePhase == .active)
            captureEngine.setMeasurementMode(workflowMode)
        }
        .onChange(of: scenePhase) { _, phase in
            sessionManager.setApplicationActive(phase == .active)
        }
    }

    private var topHUD: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.progressText)
                    .font(.headline)
                Text(methodProgressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(workflowMode.shortTitle)
                .font(.caption.weight(.bold))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(methodColor.opacity(0.2), in: Capsule())
                .foregroundStyle(methodColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var measurementCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: workflowMode == .top ? "arrow.down.to.line" : "cube.transparent")
                    .foregroundStyle(methodColor)
                Text(cardHeadline)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                if captureEngine.activeObjectID != nil,
                   captureEngine.primaryText != "--" {
                    Text(captureEngine.primaryText)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }

            Text(cardDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if workflowMode == .spatial3D,
               captureEngine.activeObjectID != nil {
                HStack(spacing: 8) {
                    coverageChip(
                        "Top",
                        systemImage: "arrow.down.to.line",
                        isDone: captureEngine.footprintSatisfied,
                        isCurrent: captureEngine.scanViewHint == .topDown
                    )
                    coverageChip(
                        "3/4 or side",
                        systemImage: "move.3d",
                        isDone: captureEngine.heightSatisfied,
                        isCurrent: captureEngine.scanViewHint == .side
                    )
                }
            }

            if captureEngine.convergence.isActive {
                ProgressView(value: captureEngine.convergence.progress)
                    .tint(captureEngine.convergence.isConverged ? .green : methodColor)
            }

            if let lastRecorded {
                Text(lastRecorded)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if captureEngine.activeObjectID == nil {
                Button {
                    captureEngine.requestObjectMaskToggle(at: CGPoint(x: 0.5, y: 0.5))
                } label: {
                    Text(workflowMode == .top ? "Measure top view" : "Measure in 3D")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
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
                Button { saveReading() } label: {
                    Text("Save this \(workflowMode.shortTitle) reading")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
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
            && captureEngine.measurementMode == workflowMode
            && (workflowMode != .top || captureEngine.isTopViewAligned)
    }

    private var methodColor: Color {
        workflowMode == .top ? .cyan : .orange
    }

    private var methodProgressText: String {
        guard let test = store.activeTest else { return "" }
        let completed = test.readings.filter {
            ($0.workflowMode ?? .spatial3D) == workflowMode
        }.count
        return "\(completed) of \(test.objectCount * test.passes) \(workflowMode.shortTitle) readings"
    }

    private var cardHeadline: String {
        if captureEngine.activeObjectID == nil {
            if workflowMode == .top, !captureEngine.isTopViewAligned {
                return "Point straight down"
            }
            return "Ready for \(workflowMode.shortTitle)"
        }
        if captureEngine.convergence.isConverged { return "Reading settled" }
        switch captureEngine.convergence.limitingFactor {
        case .needsTopView: return "Capture the top"
        case .needsSideView: return "Move to a 3/4 or side view"
        case .waitingForSupportPlane: return "Find the supporting surface"
        default: return "Measuring \(workflowMode.shortTitle)"
        }
    }

    private var cardDetail: String {
        if captureEngine.activeObjectID == nil {
            if workflowMode == .top,
               let degrees = captureEngine.topViewDeviationDegrees,
               !captureEngine.isTopViewAligned {
                return "The phone is \(degrees)° off vertical. \(workflowMode.accuracyInstruction)"
            }
            return workflowMode.accuracyInstruction
        }
        if captureEngine.convergence.isConverged {
            return "The dimensions have stopped changing. Save this reading."
        }
        if workflowMode == .spatial3D {
            return "The footprint comes from above; height comes from an isometric or lateral view. Complete both view chips."
        }
        return captureEngine.statusText
    }

    private func coverageChip(
        _ title: String,
        systemImage: String,
        isDone: Bool,
        isCurrent: Bool
    ) -> some View {
        Label(title, systemImage: isDone ? "checkmark" : systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isDone ? .green : (isCurrent ? .yellow : .secondary))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                (isDone ? Color.green : (isCurrent ? Color.yellow : Color.secondary))
                    .opacity(0.16),
                in: Capsule()
            )
    }

    /// Finishes the measurement, stores the size and removes the object so the scene doesn't grow.
    private func saveReading() {
        guard let id = captureEngine.lockActiveObject(),
              let captured = captureEngine.capturedObjectsByID[id] else {
            return
        }
        let size = captured.sizeMillimetres
        if store.record(sizeMillimetres: size) {
            lastRecorded = "Recorded \(workflowMode.shortTitle): \(AccuracyTestRun.sizeText([size.x, size.y, size.z]))"
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
                if test.measurementModes.count > 1 {
                    ForEach(test.measurementModes) { mode in
                        let methodSummary = AccuracyStatistics.summarise(
                            test,
                            workflowMode: mode
                        )
                        if !methodSummary.objects.isEmpty {
                            Section("\(mode.shortTitle) overall") {
                                figure("Bias", AccuracyTestRun.number(methodSummary.bias) + " mm")
                                figure("Mean absolute error", AccuracyTestRun.number(methodSummary.meanAbsoluteError) + " mm")
                                figure("RMSE", AccuracyTestRun.number(methodSummary.rootMeanSquareError) + " mm")
                                figure("Largest error", AccuracyTestRun.number(methodSummary.maximumAbsoluteError) + " mm")
                            }
                        }
                    }
                }

                Section(test.measurementModes.count > 1 ? "Both methods combined" : "Overall") {
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

                ForEach(test.measurementModes) { mode in
                    let methodSummary = AccuracyStatistics.summarise(
                        test,
                        workflowMode: mode
                    )
                    ForEach(methodSummary.objects, id: \.objectNumber) { object in
                        Section("\(mode.shortTitle) · Object \(object.objectNumber) · \(AccuracyTestRun.sizeText(object.reference))") {
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
                                Text("\((reading.workflowMode ?? .spatial3D).shortTitle) · pass \(reading.pass): \(reading.sizeText)")
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

/// Separate view so each row owns its text state and typing doesn't redraw the whole list.
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

    private func commit() {
        let values = [first, second, third].compactMap(PositiveDecimalText.parse)
        guard values.count == 3 else {
            store.setReference(nil, forObject: objectNumber)
            return
        }
        store.setReference(SIMD3(values[0], values[1], values[2]), forObject: objectNumber)
    }
}
