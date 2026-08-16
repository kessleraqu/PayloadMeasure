import SwiftUI
import simd

struct FramingAccuracySiteView: View {
    let store: FramingAccuracyStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.activeTest == nil {
                    FramingAccuracySetupView(store: store)
                } else if store.isMeasuring {
                    FramingAccuracyMeasureView(store: store)
                } else {
                    FramingAccuracyResultsView(store: store)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Accuracy tests") { dismiss() }
                }
            }
        }
    }
}

private struct FramingAccuracySetupView: View {
    let store: FramingAccuracyStore

    @State private var label = ""
    @State private var rounds = 5
    @State private var workflowMode: MeasurementWorkflowMode = .top

    var body: some View {
        Form {
            Section("Framing calibration") {
                TextField("Label, object and conditions", text: $label)
                Picker("Measurement method", selection: $workflowMode) {
                    ForEach(MeasurementWorkflowMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Stepper(
                    "Repeated rounds: \(rounds)",
                    value: $rounds,
                    in: 1...FramingAccuracyStore.maximumRounds
                )
            }

            Section("Protocol") {
                Label("Use the same object throughout", systemImage: "shippingbox")
                Label("Five framing squares per round", systemImage: "viewfinder")
                Label("Full AR reset after every reading", systemImage: "arrow.clockwise")
                Text("Frames: 20%, 35%, 50%, 65%, and 80% of the screen's shorter side.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    store.startTest(
                        label: label,
                        rounds: rounds,
                        workflowMode: workflowMode
                    )
                } label: {
                    Text("Start framing test").font(.headline)
                }
            } footer: {
                Text("\(rounds * FramingCalibrationProtocol.targetFillPercentages.count) independent measurements. Odd rounds run far-to-near; even rounds reverse the order. Enter the object's true size after the final reading.")
            }

            if !store.saved.isEmpty {
                Section("Earlier framing tests") {
                    ForEach(store.saved) { test in
                        Button {
                            store.resume(test)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(test.label.isEmpty ? "Untitled framing test" : test.label)
                                    .font(.headline)
                                Text(StudyRun.displayDateFormatter.string(from: test.createdAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("\(test.completedAttemptCount) of \(test.totalExpectedReadings) attempts · \(test.workflowMode.shortTitle)")
                                    .font(.caption2)
                                    .foregroundStyle(test.isComplete ? Color.secondary : Color.orange)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Distance and framing")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct FramingAccuracyMeasureView: View {
    let store: FramingAccuracyStore

    @State private var sessionManager = ARSessionManager()
    @State private var aimerState = AimerState()
    @State private var captureEngine = ObjectCaptureEngine()
    @State private var viewportSize: CGSize = .zero
    @State private var lastRecorded: String?
    @State private var resetMessage: String?
    @State private var showsFailureConfirmation = false
    @Environment(\.scenePhase) private var scenePhase

    private var workflowMode: MeasurementWorkflowMode {
        store.activeTest?.workflowMode ?? .top
    }

    private var slot: FramingAccuracySlot? { store.nextSlot }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ARCameraView(
                    sessionManager: sessionManager,
                    aimerState: aimerState,
                    captureEngine: captureEngine,
                    workflowMode: workflowMode
                )
                .ignoresSafeArea()

                if let slot {
                    framingSquare(targetFillPercent: slot.targetFillPercent, in: geometry.size)
                        .allowsHitTesting(false)
                }

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
            .onAppear { viewportSize = geometry.size }
            .onChange(of: geometry.size) { _, size in viewportSize = size }
        }
        .navigationTitle("Framing test")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { captureEngine.setMeasurementMode(workflowMode) }
        .onChange(of: scenePhase) { _, phase in
            sessionManager.setApplicationActive(phase == .active)
        }
        .confirmationDialog(
            "Record no stable measurement?",
            isPresented: $showsFailureConfirmation,
            titleVisibility: .visible
        ) {
            Button("Record failed attempt and continue", role: .destructive) {
                if store.recordFailure(
                    reason: "No stable measurement could be completed at the target framing."
                ) {
                    resetCapture(reason: "Failed attempt recorded. AR reset for the next frame.")
                }
            }
            Button("Keep trying", role: .cancel) {}
        } message: {
            Text("Use this only after trying to obtain a settled measurement. Failures are evidence and will appear in the exported report.")
        }
    }

    private var topHUD: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.progressText).font(.headline)
                if let slot {
                    Text("Target frame \(AccuracyTestRun.number(slot.targetFillPercent))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: fillIsWithinTarget ? "checkmark.viewfinder" : "viewfinder")
                    .foregroundStyle(fillIsWithinTarget ? .green : methodColor)
                Text(cardHeadline).font(.subheadline.weight(.semibold))
                Spacer()
                if let actualFillPercent {
                    Text("\(AccuracyTestRun.number(actualFillPercent))% actual")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }
            Text(cardDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if captureEngine.convergence.isActive {
                ProgressView(value: captureEngine.convergence.progress)
                    .tint(captureEngine.convergence.isConverged ? .green : methodColor)
            }

            if let lastRecorded {
                Text(lastRecorded)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.green)
            }
            if let resetMessage {
                Text(resetMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
                    Text("Measure inside this frame")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canStart)

                if (store.activeTest?.completedAttemptCount ?? 0) > 0 {
                    Button("Undo the last attempt") {
                        store.undoLastReading()
                        resetCapture(reason: "Last attempt removed. AR reset for the repeated level.")
                    }
                    .font(.footnote)
                }
            } else {
                Button(action: saveReading) {
                    Text(fillIsWithinTarget
                        ? "Save and reset for next frame"
                        : "Match the square to save")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSave)
                .tint(captureEngine.convergence.isConverged && fillIsWithinTarget ? .green : .accentColor)

                Button("Cancel and reset this reading") {
                    resetCapture(reason: "Reading cancelled. AR reset for the same frame.")
                }
                .font(.footnote)
            }

            Button("Could not obtain a stable measurement") {
                showsFailureConfirmation = true
            }
            .font(.footnote)
            .disabled(!sessionManager.isTrackingReady)
        }
    }

    private func framingSquare(targetFillPercent: Double, in size: CGSize) -> some View {
        let side = min(size.width, size.height) * targetFillPercent / 100
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill((fillIsWithinTarget ? Color.green : Color.cyan).opacity(0.07))
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    fillIsWithinTarget ? Color.green : Color.cyan,
                    style: StrokeStyle(lineWidth: 3, dash: [10, 6])
                )
            Text("Fit the object's longest visible side to this frame")
                .font(.caption2.weight(.semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(8)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: side, height: side)
    }

    private var activeBoundingBox: CGRect? {
        captureEngine.activeObjectID.flatMap {
            captureEngine.objectMaskDisplayBoundingBoxes[$0]
        }
    }

    private var actualFillPercent: Double? {
        guard let activeBoundingBox else { return nil }
        return FramingCalibrationProtocol.fillPercent(
            boundingBox: activeBoundingBox,
            viewportSize: measurementViewportSize
        )
    }

    private var measurementViewportSize: CGSize {
        let measured = captureEngine.objectMaskViewportSize
        return measured.width > 0 && measured.height > 0 ? measured : viewportSize
    }

    private var fillIsWithinTarget: Bool {
        guard let target = slot?.targetFillPercent,
              let actualFillPercent else { return false }
        return abs(actualFillPercent - target)
            <= FramingCalibrationProtocol.allowedFillErrorPercentagePoints
    }

    private var canStart: Bool {
        sessionManager.isTrackingReady
            && sessionManager.isObjectTrackingEnvironmentReady
            && captureEngine.hasCompletedObjectRecognitionWarmup
            && !captureEngine.isObjectSelectionPending
            && captureEngine.measurementMode == workflowMode
            && (workflowMode != .top || captureEngine.isTopViewAligned)
    }

    private var canSave: Bool {
        captureEngine.canFinalizeActiveObject
            && activeBoundingBox != nil
            && fillIsWithinTarget
    }

    private var methodColor: Color { workflowMode == .top ? .cyan : .orange }

    private var cardHeadline: String {
        if captureEngine.activeObjectID == nil {
            if workflowMode == .top, !captureEngine.isTopViewAligned {
                return "Point straight down"
            }
            return "Place the object inside the square"
        }
        if !fillIsWithinTarget { return "Adjust distance to match the square" }
        if captureEngine.convergence.isConverged { return "Frame and measurement settled" }
        return "Keep measuring at this frame size"
    }

    private var cardDetail: String {
        if captureEngine.activeObjectID == nil {
            return "Keep the same object centred. Move the phone until its longest visible side matches the square, then begin."
        }
        if let target = slot?.targetFillPercent,
           let actualFillPercent,
           !fillIsWithinTarget {
            return "Match the object's longest visible side to the square. Saving unlocks within ±\(AccuracyTestRun.number(FramingCalibrationProtocol.allowedFillErrorPercentagePoints)) percentage points of \(AccuracyTestRun.number(target))%; current fill is \(AccuracyTestRun.number(actualFillPercent))%."
        }
        if workflowMode == .spatial3D {
            return "Capture the top and an isometric or lateral view while keeping approximately the same framing."
        }
        return captureEngine.convergence.isConverged
            ? "Save now. The app will clear the object and restart AR tracking."
            : captureEngine.statusText
    }

    private func saveReading() {
        guard let activeID = captureEngine.activeObjectID,
              let captured = captureEngine.capturedObjectsByID[activeID],
              let activeBoundingBox else {
            return
        }
        let distance = sessionManager.cameraDistanceMetres(to: captured.center)
        guard let id = captureEngine.lockActiveObject() else { return }
        let size = captured.sizeMillimetres
        guard store.record(
            sizeMillimetres: size,
            viewportBoundingBox: activeBoundingBox,
            viewportSize: measurementViewportSize,
            cameraDistanceMetres: distance
        ) else {
            captureEngine.removeFinalizedObject(id: id)
            resetCapture(reason: "The object moved outside the target tolerance. AR reset; repeat this frame.")
            return
        }
        lastRecorded = "Recorded \(AccuracyTestRun.sizeText([size.x, size.y, size.z]))"
        resetCapture(reason: "Capture, masks, anchors, and AR tracking reset for independence.")
    }

    private func resetCapture(reason: String) {
        captureEngine.reset()
        sessionManager.restartTracking()
        captureEngine.setMeasurementMode(workflowMode)
        resetMessage = reason
    }
}

private struct FramingAccuracyResultsView: View {
    let store: FramingAccuracyStore

    @State private var first = ""
    @State private var second = ""
    @State private var third = ""
    @State private var showsDownload = false
    @State private var downloadURL: URL?

    private var test: FramingAccuracyRun {
        store.activeTest ?? FramingAccuracyRun(
            id: UUID(),
            createdAt: Date(),
            label: "",
            rounds: 1,
            workflowMode: .top
        )
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    referenceField(text: $first)
                    Text("×").foregroundStyle(.secondary)
                    referenceField(text: $second)
                    Text("×").foregroundStyle(.secondary)
                    referenceField(text: $third)
                }
            } header: {
                Text("True object size in millimetres")
            } footer: {
                Text("Enter the same object's three calliper or ruler dimensions. Order does not matter.")
            }

            Section("Attempts") {
                HStack {
                    Text("Successful measurements")
                    Spacer()
                    Text("\(test.readings.count)").foregroundStyle(.secondary)
                }
                HStack {
                    Text("No stable measurement")
                    Spacer()
                    Text("\(test.failures.count)").foregroundStyle(.secondary)
                }
            }

            if let summary = store.summary {
                Section("Overall") {
                    figure("Bias", summary.bias, suffix: " mm")
                    figure("Mean absolute error", summary.meanAbsoluteError, suffix: " mm")
                    figure("RMSE", summary.rootMeanSquareError, suffix: " mm")
                    figure("Largest error", summary.maximumAbsoluteError, suffix: " mm")
                }

                ForEach(summary.levels, id: \.targetFillPercent) { level in
                    Section("Target \(AccuracyTestRun.number(level.targetFillPercent))%") {
                        HStack {
                            Text("Successful / failed")
                            Spacer()
                            Text("\(level.readings.count) / \(test.failures(targetFillPercent: level.targetFillPercent).count)")
                                .foregroundStyle(.secondary)
                        }
                        figure("Mean actual fill", level.meanActualFillPercent, suffix: "%")
                        if level.meanCameraDistanceMillimetres.isFinite {
                            figure("Mean camera distance", level.meanCameraDistanceMillimetres, suffix: " mm")
                        }
                        figure("Bias", level.bias, suffix: " mm")
                        figure("Mean absolute error", level.meanAbsoluteError, suffix: " mm")
                        figure("RMSE", level.rootMeanSquareError, suffix: " mm")
                        figure("Largest error", level.maximumAbsoluteError, suffix: " mm")
                    }
                }
            } else {
                Section {
                    Text(test.referenceSize == nil
                        ? "Enter all three true dimensions to calculate error at each framing level."
                        : "No successful measurements are available to compare. Failed attempts remain in the report.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Raw readings") {
                ForEach(test.readings) { reading in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Round \(reading.round) · target \(AccuracyTestRun.number(reading.targetFillPercent))% · actual \(AccuracyTestRun.number(reading.actualFillPercent))%")
                            .font(.subheadline.weight(.semibold))
                        Text(reading.sizeText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let distance = reading.cameraDistanceMillimetres {
                            Text("Camera to object centre: \(AccuracyTestRun.number(distance)) mm")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                ForEach(test.failures) { failure in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Round \(failure.round) · target \(AccuracyTestRun.number(failure.targetFillPercent))% · no reading")
                            .font(.subheadline.weight(.semibold))
                        Text(failure.reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                Button {
                    downloadURL = store.exportReport(for: test)
                    showsDownload = downloadURL != nil
                } label: {
                    Label("Download the framing report", systemImage: "square.and.arrow.down")
                }
                if let url = store.lastExportURL {
                    ShareLink(item: url) {
                        Label("Share instead", systemImage: "square.and.arrow.up")
                    }
                }
                Button("Close this framing test") { store.closeActiveTest() }
            } footer: {
                Text("This screen reports the evidence but does not choose a threshold automatically. Define the acceptable error first, then select and validate the passing interval on other objects.")
            }
        }
        .navigationTitle("Framing results")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadReference)
        .onChange(of: first) { _, _ in commitReference() }
        .onChange(of: second) { _, _ in commitReference() }
        .onChange(of: third) { _, _ in commitReference() }
        .sheet(isPresented: $showsDownload) {
            if let downloadURL {
                DocumentExporter(url: downloadURL) { _ in showsDownload = false }
                    .ignoresSafeArea()
            }
        }
    }

    private func referenceField(text: Binding<String>) -> some View {
        TextField("mm", text: text)
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 8))
    }

    private func figure(_ name: String, _ value: Double, suffix: String) -> some View {
        HStack {
            Text(name)
            Spacer(minLength: 8)
            Text(AccuracyTestRun.number(value) + suffix)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private func loadReference() {
        guard let values = test.referenceSize else { return }
        first = PositiveDecimalText.format(values[0], maximumFractionDigits: 2) ?? ""
        second = PositiveDecimalText.format(values[1], maximumFractionDigits: 2) ?? ""
        third = PositiveDecimalText.format(values[2], maximumFractionDigits: 2) ?? ""
    }

    private func commitReference() {
        let values = [first, second, third].compactMap(PositiveDecimalText.parse)
        guard values.count == 3 else {
            store.setReference(nil)
            return
        }
        store.setReference(SIMD3(values[0], values[1], values[2]))
    }
}
