import SwiftUI
import simd

// Camera-free counterpart to the AR measurement screen. It creates finalized measurements in the
// shared capture engine, then hands the same engine to package preparation and both optimizers.

struct ManualMeasurementView: View {
    let captureEngine: ObjectCaptureEngine
    let study: StudyStore
    let onFullReset: () -> Void
    let onPayloadFinished: () -> Void
    let onRunCancelled: () -> Void

    @State private var packingStore = PackingStore()
    @State private var nameText = ""
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
    @State private var showsObjectEntry = false

    private var objectIDs: [UUID] { captureEngine.measuredObjectIDs }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    conditionHeader
                    addObjectButton
                    savedObjectsSection
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Enter measurements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { preparationButton }
        }
        .onAppear(perform: configurePackingStore)
        // The form is a sheet rather than a card on the page. As a card it sat between the header
        // and the list looking like part of the page, and operators asked where they were supposed
        // to put the object's details while looking straight at it. A "+" that opens a form on top
        // of everything else cannot be mistaken for anything other than what it is.
        .sheet(isPresented: $showsObjectEntry) {
            ManualObjectEntrySheet(
                nameText: $nameText,
                lengthText: $lengthText,
                widthText: $widthText,
                heightText: $heightText,
                isEditing: editingObjectID != nil,
                validationMessage: validationMessage,
                onSave: {
                    if saveDraft() { showsObjectEntry = false }
                },
                onCancel: {
                    clearDraft()
                    showsObjectEntry = false
                }
            )
        }
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
                clearDraft()
                study.endCurrentPhase()
                showsPackingWorkflow = true
            }
            Button("Keep measuring", role: .cancel) {}
        } message: {
            Text("Check that every object has a name and all three dimensions before continuing. Weights are entered while packing.")
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
                    // Nothing to protect in a test run: no participant, no record, no password.
                    if study.isTestMode {
                        onRunCancelled()
                    } else {
                        showsCancelPassword = true
                    }
                } label: {
                    Label(
                        study.isTestMode ? "Leave the test" : "Cancel study run",
                        systemImage: "xmark.circle"
                    )
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Manual measurement options")
        }

        // The same action as the card below, kept where it is reachable once the list is long
        // enough to have scrolled the card away.
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: beginAddingObject) {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add object")
            .accessibilityHint("Opens the form for a new object's name and size.")
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
                Text("\(study.isTestMode ? "Test payload" : study.currentBox?.shortTitle ?? "Payload") · \(objectIDs.count) object\(objectIDs.count == 1 ? "" : "s") entered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    /// The one obvious thing to press. Deliberately large, deliberately alone, and deliberately not
    /// styled like the "Start packing" bar at the foot of the screen.
    private var addObjectButton: some View {
        Button(action: beginAddingObject) {
            HStack(spacing: 12) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add object")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Name it, then enter its length, width and height.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add object")
        .accessibilityHint("Opens the form for a new object's name and size.")
    }

    @ViewBuilder
    private var savedObjectsSection: some View {
        if objectIDs.isEmpty {
            ContentUnavailableView {
                Label("No objects entered", systemImage: "shippingbox")
            } description: {
                Text("Enter every object before continuing to package weights.")
            } actions: {
                Button("Add the first object", action: beginAddingObject)
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(measuredObjectsTitle)
                    .font(.headline)
                ForEach(objectIDs, id: \.self) { id in
                    objectRow(id)
                }
            }
        }
    }

    private var measuredObjectsTitle: String {
        let skipped = packingStore.objectIDsSkipped(in: captureEngine).count
        guard skipped > 0 else { return "Measured objects" }
        return "Measured objects · \(skipped) skipped"
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
                if isSkipped(id) {
                    Label("Skipped · left out of this payload", systemImage: "arrow.uturn.forward")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    Text("Entered manually · no photo")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button {
                    beginEditing(id)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button {
                    packingStore.setSkipped(!isSkipped(id), for: id, in: captureEngine)
                    if editingObjectID == id { clearDraft() }
                } label: {
                    isSkipped(id)
                        ? Label("Put back in the payload", systemImage: "arrow.uturn.backward")
                        : Label("Skip this object", systemImage: "arrow.uturn.forward")
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
                .stroke(
                    isSkipped(id) ? Color.orange.opacity(0.8) : objectColour(id).opacity(0.8),
                    style: StrokeStyle(lineWidth: 2, dash: isSkipped(id) ? [5, 4] : [])
                )
        }
        .opacity(isSkipped(id) ? 0.75 : 1)
    }

    private func isSkipped(_ id: UUID) -> Bool {
        packingStore.isSkipped(id, in: captureEngine)
    }

    private var preparationButton: some View {
        VStack(spacing: 5) {
            Button {
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

            Text("Add every object with its name and size. Weights are entered on the next screen.")
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

    /// Opens the entry form for a new object. Any half-typed draft from a cancelled edit is cleared
    /// first, so the form is never opened showing someone else's object.
    private func beginAddingObject() {
        clearDraft()
        showsObjectEntry = true
    }

    /// True when the object was saved and the form can close. False leaves the form up with
    /// `validationMessage` explaining why — closing on a refusal would throw away what was typed.
    @discardableResult
    private func saveDraft() -> Bool {
        validationMessage = nil
        let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = [lengthText, widthText, heightText].compactMap(PositiveDecimalText.parse)
        guard !name.isEmpty else {
            validationMessage = "Give this object a name. It is what the loading plan calls it."
            return false
        }
        guard captureEngine.isNameAvailable(name, excluding: editingObjectID) else {
            validationMessage = "Another object is already called “\(name)”. Give this one a different name."
            return false
        }
        guard values.count == 3 else {
            validationMessage = "Enter all three dimensions in millimetres, as numbers greater than zero."
            return false
        }
        let size = SIMD3(values[0], values[1], values[2])

        if let editingObjectID {
            packingStore.clearPreparation(for: editingObjectID)
            guard captureEngine.updateManualMeasurement(
                id: editingObjectID,
                name: name,
                sizeMillimetres: size
            ) else {
                validationMessage = "These dimensions could not be saved."
                return false
            }
        } else {
            guard captureEngine.addManualMeasurement(
                name: name,
                sizeMillimetres: size
            ) != nil else {
                validationMessage = "These dimensions could not be added."
                return false
            }
        }
        clearDraft()
        return true
    }

    private func beginEditing(_ id: UUID) {
        guard let size = packingStore.measuredSizeMillimetres(for: id, in: captureEngine) else {
            return
        }
        editingObjectID = id
        nameText = captureEngine.name(for: id) ?? ""
        lengthText = PositiveDecimalText.format(size.x, maximumFractionDigits: 2) ?? ""
        widthText = PositiveDecimalText.format(size.y, maximumFractionDigits: 2) ?? ""
        heightText = PositiveDecimalText.format(size.z, maximumFractionDigits: 2) ?? ""
        validationMessage = nil
        showsObjectEntry = true
    }

    private func clearDraft() {
        editingObjectID = nil
        nameText = ""
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

/// The name and size of one object, asked for on top of everything else.
///
/// It owns its own focus rather than borrowing the presenting screen's: focus does not reliably
/// cross a sheet boundary, and a field that cannot be focused is a field that cannot be typed into.
private struct ManualObjectEntrySheet: View {
    private enum Field: Hashable {
        case name
        case length
        case width
        case height
    }

    @Binding var nameText: String
    @Binding var lengthText: String
    @Binding var widthText: String
    @Binding var heightText: String
    let isEditing: Bool
    let validationMessage: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("For example: red cable drum", text: $nameText)
                        .textInputAutocapitalization(.words)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .length }
                        .accessibilityLabel("Object name")
                } header: {
                    Text("Name")
                } footer: {
                    Text("This name appears in the loading plan.")
                }

                Section {
                    HStack(alignment: .bottom, spacing: 8) {
                        dimensionField("Length", text: $lengthText, field: .length)
                        separator
                        dimensionField("Width", text: $widthText, field: .width)
                        separator
                        dimensionField("Height", text: $heightText, field: .height)
                    }
                } header: {
                    Text("Size in millimetres")
                } footer: {
                    Text("Measure the object itself with a ruler or calliper. The packed weight is asked for later, while packing.")
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit object" : "New object")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditing ? "Save" : "Add", action: onSave)
                        .buttonStyle(.borderedProminent)
                }
                if focusedField != nil {
                    ToolbarItemGroup(placement: .keyboard) {
                        // The dimensions use a decimal pad, which has no return key of its own.
                        Spacer()
                        Button("Done") { focusedField = nil }
                    }
                }
            }
            .onAppear { focusedField = .name }
        }
        .presentationDetents([.medium, .large])
    }

    private var separator: some View {
        Text("×")
            .foregroundStyle(.secondary)
            .padding(.bottom, 8)
            .accessibilityHidden(true)
    }

    private func dimensionField(
        _ title: String,
        text: Binding<String>,
        field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("mm", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field)
                .accessibilityLabel("\(title) in millimetres")
        }
        .frame(maxWidth: .infinity)
    }
}
