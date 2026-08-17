import SwiftUI
import simd

// Camera-free counterpart to the AR measurement screen. It creates finalized measurements in the
// shared capture engine, then hands the same engine to package preparation and both optimizers.

struct ManualMeasurementView: View {
    private enum FocusedField: Hashable {
        case length
        case width
        case height
    }

    let captureEngine: ObjectCaptureEngine
    let study: StudyStore
    let onFullReset: () -> Void
    let onPayloadFinished: () -> Void
    let onRunCancelled: () -> Void

    @State private var packingStore = PackingStore()
    @State private var lengthText = ""
    @State private var widthText = ""
    @State private var heightText = ""
    @State private var editingObjectID: UUID?
    @State private var pendingRemovalID: UUID?
    @State private var validationMessage: String?
    @State private var showsPackingWorkflow = false
    @State private var showsPackingConfirmation = false
    @State private var showsCancelPassword = false
    @State private var showsResetConfirmation = false
    @FocusState private var focusedField: FocusedField?

    private var objectIDs: [UUID] { captureEngine.measuredObjectIDs }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    conditionHeader
                    measurementEntryCard
                    savedObjectsSection
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Enter measurements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .top) {
                StudyTimerStrip(study: study)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
            .safeAreaInset(edge: .bottom) { preparationButton }
        }
        .onAppear(perform: configurePackingStore)
        .fullScreenCover(
            isPresented: $showsPackingWorkflow,
            onDismiss: { study.beginPhase(.measure) }
        ) {
            PreparationView(
                captureEngine: captureEngine,
                store: packingStore,
                study: study,
                allowsRoomScaleAR: false,
                onBoxFinished: onPayloadFinished
            )
        }
        .sheet(isPresented: $showsCancelPassword) {
            StudyPasswordSheet(
                title: "Cancel this run",
                message: "Returns to setup. Finished payloads remain recorded; this payload is not saved.",
                password: StudyStore.nextBoxPassword,
                confirmTitle: "Cancel the run",
                onUnlocked: onRunCancelled
            )
        }
        .confirmationDialog(
            "Did you measure all the objects?",
            isPresented: $showsPackingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Continue to packing") {
                focusedField = nil
                clearDraft()
                study.endCurrentPhase()
                showsPackingWorkflow = true
            }
            Button("Keep measuring", role: .cancel) {}
        } message: {
            Text("Check that every object has all three dimensions before continuing. Names are entered while packing and weighing.")
        }
        .confirmationDialog(
            "Reset all manual measurements?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset everything", role: .destructive, action: onFullReset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears every entered size, box, weight and loading plan for this payload.")
        }
        .confirmationDialog(
            "Remove this object?",
            isPresented: removalIsPresented,
            titleVisibility: .visible
        ) {
            Button("Remove object", role: .destructive) { removePendingObject() }
            Button("Cancel", role: .cancel) { pendingRemovalID = nil }
        } message: {
            Text("Its dimensions, package choice and weight will be removed.")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    showsResetConfirmation = true
                } label: {
                    Label("Reset this payload", systemImage: "arrow.counterclockwise")
                }
                Button(role: .destructive) {
                    showsCancelPassword = true
                } label: {
                    Label("Cancel study run", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Manual measurement options")
        }

        if focusedField != nil {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(editingObjectID == nil ? "Add object" : "Save changes") {
                    saveDraft()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var conditionHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: StudyInputMode.manual.systemImage)
                .font(.title2)
                .foregroundStyle(.cyan)
                .frame(width: 44, height: 44)
                .background(Color.cyan.opacity(0.14), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("No-AR condition")
                    .font(.headline)
                Text("\(study.isPractice ? "Practice payload" : study.currentBox?.shortTitle ?? "Payload") · \(objectIDs.count) object\(objectIDs.count == 1 ? "" : "s") entered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var measurementEntryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                editingObjectID == nil ? "Measure the next object" : "Edit this object",
                systemImage: "ruler"
            )
            .font(.headline)

            Text("Use a ruler or calliper and enter the three outside dimensions in millimetres. You will name the object while packing and weighing it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                dimensionField("Length", text: $lengthText, field: .length)
                Text("×").foregroundStyle(.secondary)
                dimensionField("Width", text: $widthText, field: .width)
                Text("×").foregroundStyle(.secondary)
                dimensionField("Height", text: $heightText, field: .height)
                Text("mm")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(action: saveDraft) {
                    Label(
                        editingObjectID == nil ? "Add object" : "Save changes",
                        systemImage: editingObjectID == nil ? "plus" : "checkmark"
                    )
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)

                if editingObjectID != nil {
                    Button("Cancel edit", action: clearDraft)
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }

    private func dimensionField(
        _ title: String,
        text: Binding<String>,
        field: FocusedField
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("0", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field)
                .accessibilityLabel("\(title) in millimetres")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var savedObjectsSection: some View {
        if objectIDs.isEmpty {
            ContentUnavailableView {
                Label("No objects entered", systemImage: "shippingbox")
            } description: {
                Text("Enter every object before continuing to package weights.")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Measured objects")
                    .font(.headline)
                ForEach(objectIDs, id: \.self) { id in
                    objectRow(id)
                }
            }
        }
    }

    private func objectRow(_ id: UUID) -> some View {
        HStack(spacing: 12) {
            ZStack {
                objectColour(id).opacity(0.16)
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .foregroundStyle(objectColour(id))
            }
            .frame(width: 54, height: 54)
            .clipShape(.rect(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 3) {
                Text(manualObjectTitle(id))
                    .font(.subheadline.weight(.semibold))
                Text(sizeText(for: id))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("Entered manually · no photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Menu {
                Button {
                    beginEditing(id)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingRemovalID = id
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Options for \(manualObjectTitle(id))")
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(objectColour(id).opacity(0.8), lineWidth: 2)
        }
    }

    private var preparationButton: some View {
        VStack(spacing: 5) {
            Button {
                focusedField = nil
                showsPackingConfirmation = true
            } label: {
                HStack {
                    Text("Start packing")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .disabled(objectIDs.isEmpty)
            .accessibilityHint("Confirms every object was measured, then opens the untimed packing start screen.")

            Text("Add every object first. Weights are entered on the next screen.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var removalIsPresented: Binding<Bool> {
        Binding(
            get: { pendingRemovalID != nil },
            set: { if !$0 { pendingRemovalID = nil } }
        )
    }

    private func configurePackingStore() {
        if let size = study.activeModuleSizeMillimetres {
            packingStore.module.lengthMillimetres = size.x
            packingStore.module.widthMillimetres = size.y
            packingStore.module.heightMillimetres = size.z
        }
        packingStore.setPayload(study.catalogueOwner)
        study.beginPhase(.measure)
    }

    private func saveDraft() {
        focusedField = nil
        validationMessage = nil
        let values = [lengthText, widthText, heightText].compactMap(PositiveDecimalText.parse)
        guard values.count == 3 else {
            validationMessage = "Enter all three dimensions as numbers greater than zero."
            return
        }
        let size = SIMD3(values[0], values[1], values[2])

        if let editingObjectID {
            packingStore.clearPreparation(for: editingObjectID)
            guard captureEngine.updateManualMeasurement(
                id: editingObjectID,
                sizeMillimetres: size
            ) else {
                validationMessage = "These dimensions could not be saved."
                return
            }
        } else {
            guard captureEngine.addManualMeasurement(sizeMillimetres: size) != nil else {
                validationMessage = "These dimensions could not be added."
                return
            }
        }
        clearDraft()
    }

    private func beginEditing(_ id: UUID) {
        guard let size = packingStore.measuredSizeMillimetres(for: id, in: captureEngine) else {
            return
        }
        editingObjectID = id
        lengthText = PositiveDecimalText.format(size.x, maximumFractionDigits: 2) ?? ""
        widthText = PositiveDecimalText.format(size.y, maximumFractionDigits: 2) ?? ""
        heightText = PositiveDecimalText.format(size.z, maximumFractionDigits: 2) ?? ""
        validationMessage = nil
        focusedField = .length
    }

    private func clearDraft() {
        editingObjectID = nil
        lengthText = ""
        widthText = ""
        heightText = ""
        validationMessage = nil
    }

    private func removePendingObject() {
        guard let id = pendingRemovalID else { return }
        packingStore.clearPreparation(for: id)
        captureEngine.removeFinalizedObject(id: id)
        if editingObjectID == id { clearDraft() }
        pendingRemovalID = nil
    }

    private func objectColour(_ id: UUID) -> Color {
        guard let colour = captureEngine.objectColor(for: id) else { return .cyan }
        return Color(red: colour.red, green: colour.green, blue: colour.blue)
    }

    private func manualObjectTitle(_ id: UUID) -> String {
        if let name = captureEngine.name(for: id), !name.isEmpty { return name }
        return "Object \((objectIDs.firstIndex(of: id) ?? 0) + 1)"
    }

    private func sizeText(for id: UUID) -> String {
        guard let size = packingStore.measuredSizeMillimetres(for: id, in: captureEngine) else {
            return "—"
        }
        return "\(PositiveDecimalText.format(size.x, maximumFractionDigits: 2) ?? "—") × \(PositiveDecimalText.format(size.y, maximumFractionDigits: 2) ?? "—") × \(PositiveDecimalText.format(size.z, maximumFractionDigits: 2) ?? "—") mm"
    }
}
