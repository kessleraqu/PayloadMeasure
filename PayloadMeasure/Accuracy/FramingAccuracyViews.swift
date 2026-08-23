import SwiftUI
import simd

struct FramingAccuracySiteView: View {
    let store: FramingAccuracyStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sharedARViewHost) private var sharedARViewHost

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
        .onAppear {
            // Accuracy runs must begin in a fresh AR world, but use the same persistent renderer as
            // the study so RealityKit cannot leave this full-screen cover with a black/stale feed.
            sharedARViewHost?.requestNewMeasurementWorld()
        }
    }
}

private struct FramingAccuracySetupView: View {
    let store: FramingAccuracyStore

    @State private var label = ""
    @State private var objectCount = 4
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
                    "Objects: \(objectCount)",
                    value: $objectCount,
                    in: 1...FramingAccuracyStore.maximumObjects
                )
            }

            Section("Protocol") {
                Label("Measure each object at all five sizes", systemImage: "shippingbox")
                Label("One pass through the sizes per object", systemImage: "viewfinder")
                Label("You decide when the object is positioned correctly", systemImage: "hand.tap")
                Label("Full AR reset after every reading", systemImage: "arrow.clockwise")
                Text("Position the object inside each rectangle, then tap Start measuring whenever you are ready. The mask, cyan points, and measured box remain visible while measuring.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    store.startTest(
                        label: label,
                        objectCount: objectCount,
                        workflowMode: workflowMode
                    )
                } label: {
                    Text("Start framing test").font(.headline)
                }
            } footer: {
                Text("\(objectCount * FramingCalibrationProtocol.targetFillPercentages.count) measurements: all five visible sizes once per object. Enter each object's true size after the final reading.")
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
    private struct MaskCandidate {
        var boundingBox: CGRect
        var selectionPoint: CGPoint
    }

    let store: FramingAccuracyStore

    @State private var sessionManager = ARSessionManager()
    @State private var aimerState = AimerState()
    @State private var captureEngine = ObjectCaptureEngine()
    @State private var viewportSize: CGSize = .zero
    @State private var lastRecorded: String?
    @State private var resetMessage: String?
    @State private var showsFailureConfirmation = false
    @State private var startBoundingBox: CGRect?
    @State private var startViewportSize: CGSize = .zero
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sharedARViewHost) private var sharedARViewHost

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
                    workflowMode: workflowMode,
                    sharedViewHost: sharedARViewHost
                )
                .ignoresSafeArea()

                objectMaskPreview

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
            .onAppear {
                viewportSize = geometry.size
            }
            .onChange(of: geometry.size) { _, size in
                viewportSize = size
            }
        }
        .navigationTitle("Framing test")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            sessionManager.setApplicationActive(scenePhase == .active)
            captureEngine.setMeasurementMode(workflowMode)
            captureEngine.showMeasurementVisuals()
        }
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
                    reason: "No stable measurement could be completed for this guide size."
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
                Text("Position the object, then start when ready")
                    .font(.caption)
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
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "viewfinder")
                    .foregroundStyle(methodColor)
                Text(cardHeadline).font(.subheadline.weight(.semibold))
                Spacer()
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
                Button(action: startMeasurement) {
                    Text(startButtonTitle)
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
                    Text("Save measurement and continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSave)
                .tint(captureEngine.convergence.isConverged ? .green : .accentColor)

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

    /// ARCameraView produces the Vision mask but does not draw it itself. The normal measurement
    /// screen owns this presentation layer; the framing test needs the same layer explicitly.
    @ViewBuilder
    private var objectMaskPreview: some View {
        if let preview = captureEngine.objectMaskPreview {
            ZStack {
                ForEach(preview.layers, id: \.id) { layer in
                    if let trackedObjectID = layer.trackedObjectID {
                        if captureEngine.showsSelectedObjectMaskPreview,
                           captureEngine.activeObjectID == trackedObjectID,
                           !captureEngine.finalizedObjectIDs.contains(trackedObjectID),
                           let marker = captureEngine.objectMaskMarkers.first(where: {
                               $0.id == trackedObjectID
                           }) {
                            trackedObjectMaskPreview(
                                layer,
                                marker: marker,
                                currentBoundingBox: captureEngine
                                    .objectMaskDisplayBoundingBoxes[layer.id]
                            )
                        }
                    } else if captureEngine.showsLiveMaskPreview {
                        trackedObjectMaskPreview(
                            layer,
                            marker: nil,
                            currentBoundingBox: captureEngine
                                .objectMaskDisplayBoundingBoxes[layer.id]
                        )
                    }
                }
            }
        }
    }

    private func trackedObjectMaskPreview(
        _ layer: ObjectMaskPreviewLayer,
        marker: ObjectMaskMarker?,
        currentBoundingBox: CGRect?
    ) -> some View {
        GeometryReader { proxy in
            let referencePoint = layer.referenceAnchorPoint ?? CGPoint(x: 0.5, y: 0.5)
            let currentPoint = marker?.normalizedViewportPoint ?? referencePoint
            let trackedTransform: (xOffset: CGFloat, yOffset: CGFloat)? = {
                guard let reference = layer.referenceViewportBoundingBox,
                      let current = currentBoundingBox,
                      reference.width >= 0.005,
                      reference.height >= 0.005,
                      current.width >= 0.005,
                      current.height >= 0.005 else {
                    return nil
                }
                return (
                    (current.midX - reference.midX) * proxy.size.width,
                    (current.midY - reference.midY) * proxy.size.height
                )
            }()
            let xOffset = trackedTransform?.xOffset
                ?? (currentPoint.x - referencePoint.x) * proxy.size.width
            let yOffset = trackedTransform?.yOffset
                ?? (currentPoint.y - referencePoint.y) * proxy.size.height

            Image(decorative: layer.image, scale: 1, orientation: .up)
                .resizable()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .offset(x: xOffset, y: yOffset)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func framingSquare(targetFillPercent: Double, in size: CGSize) -> some View {
        let normalizedGuide = FramingCalibrationProtocol.guideRect(
            targetFillPercent: targetFillPercent,
            viewportSize: size
        )
        let width = size.width * (normalizedGuide?.width
            ?? CGFloat(targetFillPercent / 100))
        let height = size.height * (normalizedGuide?.height
            ?? CGFloat(targetFillPercent / 100))
        return ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.cyan.opacity(0.04))
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    Color.cyan,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                )
        }
        .frame(width: width, height: height)
    }

    private var previewCandidate: MaskCandidate? {
        guard let layers = captureEngine.objectMaskPreview?.layers else { return nil }
        let viewportCentre = CGPoint(x: 0.5, y: 0.5)
        return layers.compactMap { layer -> (MaskCandidate, CGFloat)? in
            guard layer.trackedObjectID == nil,
                  let box = captureEngine.objectMaskDisplayBoundingBoxes[layer.id]
                    ?? layer.referenceViewportBoundingBox else {
                return nil
            }
            // Where the mask is *now*, not where it was when its silhouette was cut. A held mask is
            // drawn through the world for up to `ObjectMaskPreviewHold.maximumHoldSeconds` while
            // `referenceAnchorPoint` stays at the frame it was sampled in, so by the time Start is
            // pressed that point can be well off the object — and a selection resolved there either
            // finds nothing or finds the surface behind it. `liveMaskTracking` is the same anchor
            // reprojected into the current frame, published every frame. Same reasoning as the Measure
            // button in `MesOverlayView.onScreenMask`.
            let point = captureEngine.liveMaskTracking?.normalizedViewportPoint
                ?? layer.referenceAnchorPoint
                ?? CGPoint(x: box.midX, y: box.midY)
            let distance = hypot(point.x - viewportCentre.x, point.y - viewportCentre.y)
            return (MaskCandidate(boundingBox: box, selectionPoint: point), distance)
        }
        .min { $0.1 < $1.1 }?.0
    }

    private var measurementViewportSize: CGSize {
        viewportSize
    }

    private var canStart: Bool {
        !captureEngine.isObjectSelectionPending
    }

    private var canSave: Bool {
        captureEngine.canFinalizeActiveObject
            && recordingBoundingBox != nil
    }

    private var recordingBoundingBox: CGRect? {
        if let startBoundingBox { return startBoundingBox }
        guard let activeID = captureEngine.activeObjectID else { return nil }
        return captureEngine.objectMaskDisplayBoundingBoxes[activeID]
    }

    private var methodColor: Color { workflowMode == .top ? .cyan : .orange }

    private var startButtonTitle: String {
        if captureEngine.isObjectSelectionPending { return "Starting measurement…" }
        return "Start measuring"
    }

    private var cardHeadline: String {
        if captureEngine.activeObjectID == nil {
            if captureEngine.isObjectSelectionPending { return "Starting measurement" }
            return "Start when you are ready"
        }
        if captureEngine.convergence.isConverged { return "Measurement settled" }
        return "Keep measuring the same object"
    }

    private var cardDetail: String {
        if captureEngine.activeObjectID == nil {
            if captureEngine.isObjectSelectionPending {
                return "Hold the phone steady while the measurement starts."
            }
            return "Place the object inside the rectangle, then tap Start measuring."
        }
        if workflowMode == .spatial3D {
            return "Capture the top and an isometric or lateral view. Keep the mask, cyan points, and fitted box on the same object."
        }
        return captureEngine.convergence.isConverged
            ? "Save now. The app will clear the object and restart AR tracking."
            : captureEngine.statusText
    }

    private func startMeasurement() {
        guard canStart else { return }
        let candidate = previewCandidate
        startBoundingBox = candidate?.boundingBox
        startViewportSize = measurementViewportSize
        captureEngine.requestObjectMaskToggle(
            at: candidate?.selectionPoint ?? CGPoint(x: 0.5, y: 0.5)
        )
    }

    private func saveReading() {
        let measuredObjectNumber = slot?.round
        guard let activeID = captureEngine.activeObjectID,
              let captured = captureEngine.capturedObjectsByID[activeID],
              let recordingBoundingBox,
              startViewportSize.width > 0,
              startViewportSize.height > 0 else {
            return
        }
        let distance = sessionManager.cameraDistanceMetres(to: captured.center)
        guard let id = captureEngine.lockActiveObject() else { return }
        let size = captured.sizeMillimetres
        guard store.record(
            sizeMillimetres: size,
            viewportBoundingBox: recordingBoundingBox,
            viewportSize: startViewportSize,
            cameraDistanceMetres: distance
        ) else {
            captureEngine.removeFinalizedObject(id: id)
            resetCapture(reason: "The reading could not be recorded. AR reset; repeat this size.")
            return
        }
        lastRecorded = "Recorded \(AccuracyTestRun.sizeText([size.x, size.y, size.z]))"
        if store.activeTest?.usesObjectProtocol == true,
           let completedObject = measuredObjectNumber,
           let next = store.nextSlot,
           next.round != completedObject {
            resetCapture(
                reason: "Object \(completedObject) complete. Place object \(next.round); AR has been reset."
            )
        } else {
            resetCapture(reason: "Capture, masks, anchors, and AR tracking reset for independence.")
        }
    }

    private func resetCapture(reason: String) {
        captureEngine.reset()
        sessionManager.restartTracking()
        captureEngine.setMeasurementMode(workflowMode)
        captureEngine.showMeasurementVisuals()
        startBoundingBox = nil
        startViewportSize = .zero
        resetMessage = reason
    }
}

private struct FramingAccuracyResultsView: View {
    let store: FramingAccuracyStore

    @State private var referenceInputs: [Int: [String]] = [:]
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
            ForEach(referenceObjectNumbers, id: \.self) { objectNumber in
                Section {
                    HStack(spacing: 8) {
                        referenceField(text: referenceBinding(objectNumber, dimension: 0))
                        Text("×").foregroundStyle(.secondary)
                        referenceField(text: referenceBinding(objectNumber, dimension: 1))
                        Text("×").foregroundStyle(.secondary)
                        referenceField(text: referenceBinding(objectNumber, dimension: 2))
                    }
                } header: {
                    Text(test.usesObjectProtocol
                        ? "True size for object \(objectNumber) in millimetres"
                        : "True object size in millimetres")
                } footer: {
                    Text("Enter the three calliper or ruler dimensions. Order does not matter.")
                }
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
                if !hasAllReferences {
                    Section {
                        Text("Enter the remaining object reference sizes to include every object in these statistics.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Overall") {
                    figure("Bias", summary.bias, suffix: " mm")
                    figure("Mean absolute error", summary.meanAbsoluteError, suffix: " mm")
                    figure("RMSE", summary.rootMeanSquareError, suffix: " mm")
                    figure("Largest error", summary.maximumAbsoluteError, suffix: " mm")
                }

                ForEach(summary.levels, id: \.targetFillPercent) { level in
                    Section(test.frameName(targetFillPercent: level.targetFillPercent)) {
                        HStack {
                            Text("Successful / failed")
                            Spacer()
                            Text("\(level.readings.count) / \(test.failures(targetFillPercent: level.targetFillPercent).count)")
                                .foregroundStyle(.secondary)
                        }
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
                    Text(!hasAllReferences
                        ? "Enter all three true dimensions for every object to calculate the complete error at each framing level."
                        : "No successful measurements are available to compare. Failed attempts remain in the report.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Raw readings") {
                ForEach(test.readings) { reading in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(test.usesObjectProtocol ? "Object" : "Round") \(reading.round) · \(test.frameName(targetFillPercent: reading.targetFillPercent))")
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
                        Text("\(test.usesObjectProtocol ? "Object" : "Round") \(failure.round) · \(test.frameName(targetFillPercent: failure.targetFillPercent)) · no reading")
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
                Text("Compare the measurement error and camera distance across the five frame sizes. The downloaded report retains the recorded mask position for auditability.")
            }
        }
        .navigationTitle("Framing results")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadReference)
        .sheet(isPresented: $showsDownload) {
            if let downloadURL {
                DocumentExporter(url: downloadURL) { _ in showsDownload = false }
                    .ignoresSafeArea()
            }
        }
    }

    private var referenceObjectNumbers: [Int] {
        test.usesObjectProtocol ? Array(1...test.configuredObjectCount) : [1]
    }

    private var hasAllReferences: Bool {
        referenceObjectNumbers.allSatisfy { test.referenceSize(forObject: $0) != nil }
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
        for objectNumber in referenceObjectNumbers {
            guard let values = test.referenceSize(forObject: objectNumber) else { continue }
            referenceInputs[objectNumber] = values.map {
                PositiveDecimalText.format($0, maximumFractionDigits: 2) ?? ""
            }
        }
    }

    private func referenceBinding(_ objectNumber: Int, dimension: Int) -> Binding<String> {
        Binding(
            get: {
                let values = referenceInputs[objectNumber] ?? ["", "", ""]
                return values.indices.contains(dimension) ? values[dimension] : ""
            },
            set: { newValue in
                var values = referenceInputs[objectNumber] ?? ["", "", ""]
                values[dimension] = newValue
                referenceInputs[objectNumber] = values
                commitReference(for: objectNumber, inputs: values)
            }
        )
    }

    private func commitReference(for objectNumber: Int, inputs: [String]) {
        let values = inputs.compactMap(PositiveDecimalText.parse)
        guard values.count == 3 else {
            if test.usesObjectProtocol {
                store.setReference(nil, forObject: objectNumber)
            } else {
                store.setReference(nil)
            }
            return
        }
        let size = SIMD3(values[0], values[1], values[2])
        if test.usesObjectProtocol {
            store.setReference(size, forObject: objectNumber)
        } else {
            store.setReference(size)
        }
    }
}
