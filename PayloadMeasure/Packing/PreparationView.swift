import SwiftUI
import UIKit

// Step-by-step preparation before loading. Each object gets the smallest box it fits in; the
// operator packs it, weighs the sealed package and moves on. Handoff screens separate measuring,
// packing and loading.

struct PreparationView: View {
    let captureEngine: ObjectCaptureEngine
    @Bindable var store: PackingStore
    let study: StudyStore
    var allowsRoomScaleAR = true
    let onBoxFinished: () -> Void

    @State private var stage: Stage = .packingHandoff

    private enum Stage {
        case packingHandoff
        case preparation
        case payloadHandoff
        case arrangement
    }

    var body: some View {
        switch stage {
        case .packingHandoff:
            StudyPhaseHandoffView(
                title: "Packing",
                detail: "The measuring timer is stopped. Start when you are ready to prepare and weigh every package.",
                buttonTitle: "Start packing"
            ) {
                study.beginPhase(.pack)
                withAnimation(.snappy(duration: 0.25)) {
                    stage = .preparation
                }
            }
            .onAppear { study.endCurrentPhase() }

        case .preparation:
            PackingPreparationView(
                captureEngine: captureEngine,
                store: store
            ) {
                study.endCurrentPhase()
                withAnimation(.snappy(duration: 0.25)) {
                    stage = .payloadHandoff
                }
            }
            .transition(.opacity)

        case .payloadHandoff:
            StudyPhaseHandoffView(
                title: "Loading",
                detail: "The packing timer is stopped. Start when you are ready to optimise and load the payload.",
                buttonTitle: "Start loading"
            ) {
                study.beginPhase(.payload)
                withAnimation(.snappy(duration: 0.25)) {
                    stage = .arrangement
                }
            }
            .onAppear { study.endCurrentPhase() }

        case .arrangement:
            ArrangementView(
                captureEngine: captureEngine,
                store: store,
                study: study,
                allowsRoomScaleAR: allowsRoomScaleAR,
                onBoxFinished: onBoxFinished
            )
            .transition(.opacity)
        }
    }
}

private struct PackingPreparationView: View {
    private enum FocusedField: Hashable {
        case name
        case weight
    }

    private struct Draft {
        var nameText: String
        var packedWeightText: String
        /// Whether the object had no name when the draft was created. Fixed at creation: deriving it from
        /// the live text would remove the name field after the first keystroke.
        let arrivedWithoutName: Bool
    }

    let captureEngine: ObjectCaptureEngine
    @Bindable var store: PackingStore
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: FocusedField?
    @State private var currentIndex = 0
    @State private var drafts: [UUID: Draft] = [:]
    @State private var validationMessage: String?
    /// Fields Next rejected, highlighted in place.
    @State private var invalidFields: Set<FocusedField> = []

    private var objectIDs: [UUID] {
        captureEngine.measuredObjectIDs
    }

    private var currentObjectID: UUID? {
        guard objectIDs.indices.contains(currentIndex) else { return nil }
        return objectIDs[currentIndex]
    }

    var body: some View {
        NavigationStack {
            Group {
                if !isReady {
                    waitingState
                } else if let currentObjectID {
                    preparationContent(for: currentObjectID)
                } else {
                    emptyState
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Prepare packages")
            .navigationBarTitleDisplayMode(.inline)
            // Buttons go in the navigation bar so the keyboard never covers them.
            .toolbar {
                if isReady, let currentObjectID {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: goBack) {
                            Image(systemName: "chevron.left")
                        }
                        .accessibilityLabel(currentIndex == 0 ? "Back" : "Previous object")
                        .accessibilityHint(
                            currentIndex == 0
                                ? "Leaves the packing screen."
                                : "Goes back to the previous object."
                        )
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            saveAndAdvance(objectID: currentObjectID)
                        } label: {
                            Label(
                                compactNextActionTitle(for: currentObjectID),
                                systemImage: currentIndex == objectIDs.count - 1
                                    ? "square.grid.3x3.square"
                                    : "arrow.right"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(nextActionTitle(for: currentObjectID))
                        .accessibilityHint(nextActionHint(for: currentObjectID))
                    }
                }

                if focusedField != nil {
                    ToolbarItemGroup(placement: .keyboard) {
                        // Decimal pads have no return key.
                        Spacer()
                        Button("Done") { focusedField = nil }
                            .accessibilityHint("Closes the keyboard.")
                    }
                }
            }
        }
        .onAppear(perform: prepareDrafts)
    }

    private func preparationContent(for objectID: UUID) -> some View {
        let canPrepare = store.isItsOwnBox(objectID, in: captureEngine)
            || !store.fittingBoxPresets(for: objectID, in: captureEngine).isEmpty

        // Fits an iPhone 13 without scrolling. The ScrollView is only there for large text sizes.
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                progressHeader
                objectCard(for: objectID)

                if store.isSkipped(objectID, in: captureEngine) {
                    skippedCard(for: objectID)
                } else if canPrepare {
                    boxCard(for: objectID)
                    // The name is given while measuring, so only the weight is entered here.
                    detailsCard(for: objectID)
                    ownBoxCard(for: objectID)
                } else {
                    noFittingBoxCard(for: objectID)
                }

                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollDismissesKeyboard(.interactively)
        .id(objectID)
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Object \(currentIndex + 1) of \(objectIDs.count)")
                .font(.subheadline.weight(.semibold))
            ProgressView(value: progress)
                .tint(.accentColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preparation progress")
        .accessibilityValue("Object \(currentIndex + 1) of \(objectIDs.count)")
    }

    private var progress: Double {
        guard !objectIDs.isEmpty else { return 0 }
        return Double(currentIndex + 1) / Double(objectIDs.count)
    }

    private func objectCard(for objectID: UUID) -> some View {
        HStack(alignment: .top, spacing: 12) {
            objectVisual(for: objectID)
                .frame(width: 78, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 9) {
                Circle()
                    .fill(objectColour(for: objectID))
                    .frame(width: 11, height: 11)
                    .accessibilityHidden(true)

                Text(displayName(for: objectID))
                    .font(.title3.weight(.semibold))
                    .accessibilityLabel("Object, \(displayName(for: objectID))")
            }

            if let measured = store.measuredSizeMillimetres(for: objectID, in: captureEngine) {
                Label("Measured \(sizeText(measured))", systemImage: "ruler")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Measured size \(sizeText(measured))")
            }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(objectColour(for: objectID), lineWidth: 3)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func objectVisual(for objectID: UUID) -> some View {
        if let data = captureEngine.snapshotJPEGData(for: objectID),
           let image = UIImage(data: data) {
            ZStack {
                Color(.tertiarySystemGroupedBackground)
                objectColour(for: objectID).opacity(0.1)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo of \(displayName(for: objectID))")
        } else {
            ZStack {
                objectColour(for: objectID).opacity(0.16)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(objectColour(for: objectID))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("No photo available for \(displayName(for: objectID))")
        }
    }

    @ViewBuilder
    private func boxCard(for objectID: UUID) -> some View {
        let isOwnBox = store.isItsOwnBox(objectID, in: captureEngine)
        let assigned = store.selectedBoxPreset(for: objectID)

        VStack(alignment: .leading, spacing: 12) {
            if isOwnBox {
                Label("NO OUTER BOX NEEDED", systemImage: "checkmark.seal.fill")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(objectColour(for: objectID))
                Text("Use the object exactly as measured.")
                    .font(.subheadline)
            } else if let assigned {
                HStack(spacing: 12) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(objectColour(for: objectID))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PUT IT IN THIS BOX")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.secondary)
                        Text(assigned.name)
                            .font(.title2.monospacedDigit().weight(.bold))
                        Text("Smallest available box that fits")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            objectColour(for: objectID).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 18)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(objectColour(for: objectID), lineWidth: 3)
        }
    }

    /// Weight, plus the name if the object somehow arrived without one.
    private func detailsCard(for objectID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Weigh the finished package", systemImage: "scalemass")
                .font(.headline)

            if needsName(for: objectID) {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Name of this object", field: .name)
                    TextField("For example: red cable drum", text: nameBinding(for: objectID))
                        .textInputAutocapitalization(.words)
                        .font(.title3)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .weight }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 50)
                        .background(fieldFill(.name), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(fieldStroke(.name), lineWidth: 2)
                        }
                        .accessibilityLabel("Name of this object")
                        .accessibilityHint("This name appears in the loading plan.")
                    if invalidFields.contains(.name) {
                        fieldWarning("A name is needed before you can continue.")
                    }
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Weight of the finished package", field: .weight)
                Text(weightInstruction(for: objectID, packageName: displayName(for: objectID)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    TextField("0", text: packedWeightBinding(for: objectID))
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .weight)
                        .font(.title3.monospacedDigit())
                        .padding(.horizontal, 12)
                        .frame(minHeight: 50)
                        .background(fieldFill(.weight), in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(fieldStroke(.weight), lineWidth: 2)
                        }
                        .accessibilityLabel("Total packed weight in grams")
                        .accessibilityHint("Include the object, the box and all packing material.")

                    Text("g")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                if invalidFields.contains(.weight) {
                    fieldWarning("A weight in grams is needed before you can continue.")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    /// Only true if something went wrong upstream, since both measuring paths ask for a name. Uses
    /// the flag stored in the draft, not the live text (see `arrivedWithoutName`).
    private func needsName(for objectID: UUID) -> Bool {
        drafts[objectID]?.arrivedWithoutName ?? isUnnamed(captureEngine.name(for: objectID))
    }

    /// An object skipped while measuring. Recorded as skipped and left out of the plan.
    private func skippedCard(for objectID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Skipped", systemImage: "arrow.uturn.forward")
                .font(.title3.weight(.bold))
                .foregroundStyle(.orange)

            Text("This object was skipped while measuring. It is not boxed, not weighed and not loaded, and it is recorded as skipped.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                store.setSkipped(false, for: objectID, in: captureEngine)
                store.assignBoxesAutomatically(in: captureEngine)
                validationMessage = nil
            } label: {
                Label("Put it back in the payload", systemImage: "arrow.uturn.backward")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    Color.orange.opacity(0.7),
                    style: StrokeStyle(lineWidth: 2, dash: [5, 4])
                )
        }
        .accessibilityElement(children: .contain)
    }

    private func fieldLabel(_ title: String, field: FocusedField) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            if invalidFields.contains(field) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private func fieldWarning(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fieldFill(_ field: FocusedField) -> Color {
        invalidFields.contains(field)
            ? Color.red.opacity(0.10)
            : Color.primary.opacity(0.06)
    }

    private func fieldStroke(_ field: FocusedField) -> Color {
        invalidFields.contains(field) ? .red : .clear
    }

    private func ownBoxCard(for objectID: UUID) -> some View {
        let isOwnBox = store.isItsOwnBox(objectID, in: captureEngine)

        return VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: ownBoxBinding(for: objectID)) {
                Text("This object is a box itself, so it does not go inside another one")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(
                isOwnBox
                    ? "It will be loaded exactly as measured. Weigh it as it is."
                    : "Leave this off if the object is going into one of the boxes. Only turn it on for something that is already a rigid box or case."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityHint("Uses the measured dimensions as the package size, with no outer box.")
    }

    private func ownBoxBinding(for objectID: UUID) -> Binding<Bool> {
        Binding(
            get: { store.isItsOwnBox(objectID, in: captureEngine) },
            set: { isOwnBox in
                store.setIsItsOwnBox(isOwnBox, for: objectID, in: captureEngine)
                store.assignBoxesAutomatically(in: captureEngine)
                validationMessage = nil
            }
        )
    }

    private func noFittingBoxCard(for objectID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Does not fit available boxes", systemImage: "shippingbox.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.orange)

            Text("This object does not fit any available box, even when turned. Usually that means the measurement came out too big.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Text("Skipped objects are recorded as not boxable and are left out of the loading plan. No name or packed weight is needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Kept small and at the bottom so skipping isn't done by accident.
            Button {
                skip(objectID: objectID)
            } label: {
                Label("Skip this object", systemImage: "arrow.uturn.forward")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(.secondary)
            .accessibilityHint("Leaves this object out: no box, no weight, and no place in the loading plan.")

            Divider()

            Toggle(isOn: ownBoxBinding(for: objectID)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("This object is a box itself, so it does not go inside another one")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Turn this on to keep it in the plan at its measured size. Otherwise continue, and it is left out.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.orange.opacity(0.7), lineWidth: 2)
        }
        // .contain so the Skip button and the switch stay reachable separately.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(displayName(for: objectID)) does not fit any available box."
        )
    }

    /// Short title for the navigation bar. VoiceOver reads the full one.
    private func compactNextActionTitle(for objectID: UUID) -> String {
        let isLastObject = currentIndex == objectIDs.count - 1
        if !store.isSkipped(objectID, in: captureEngine),
           store.fittingBoxPresets(for: objectID, in: captureEngine).isEmpty,
           !store.isItsOwnBox(objectID, in: captureEngine) {
            return isLastObject ? "Skip & plan" : "Skip"
        }
        return isLastObject ? "Loading plan" : "Next"
    }

    private func nextActionHint(for objectID: UUID) -> String {
        let isLastObject = currentIndex == objectIDs.count - 1
        let hasNoFittingBox = store.fittingBoxPresets(for: objectID, in: captureEngine).isEmpty
        if hasNoFittingBox {
            return isLastObject
                ? "Skips this object and creates a loading plan from the objects that fit available boxes."
                : "Skips this object and shows the next one."
        }
        return isLastObject
            ? "Checks every prepared package, then opens the loading plan."
            : "Saves this box and packed weight, then shows the next object."
    }

    private func nextActionTitle(for objectID: UUID) -> String {
        if store.isSkipped(objectID, in: captureEngine) {
            return currentIndex == objectIDs.count - 1
                ? "Create loading plan"
                : "Next object"
        }
        if store.fittingBoxPresets(for: objectID, in: captureEngine).isEmpty,
           !store.isItsOwnBox(objectID, in: captureEngine) {
            return currentIndex == objectIDs.count - 1
                ? "Skip and create the plan"
                : "Skip this object"
        }
        return currentIndex == objectIDs.count - 1
            ? "Create loading plan"
            : "Next object"
    }

    /// Nothing is editable until the measured objects have arrived.
    private var isReady: Bool {
        !captureEngine.measuredObjectIDs.isEmpty
            && !captureEngine.isObjectSelectionPending
            && captureEngine.activeObjectID == nil
    }

    private var waitingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Getting your objects ready")
                .font(.headline)
            Text(waitingDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Back") { dismiss() }
                .buttonStyle(.bordered)
                .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var waitingDetail: String {
        if captureEngine.activeObjectID != nil {
            return "One object is still being measured. Finish or cancel it first."
        }
        if captureEngine.isObjectSelectionPending {
            return "An object is still being selected."
        }
        return "No measured objects yet. Measure at least one before preparing packages."
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No locked objects", systemImage: "shippingbox")
        } description: {
            Text("Lock at least one measured object before preparing packages.")
        } actions: {
            Button("Back") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func prepareDrafts() {
        store.assignBoxesAutomatically(in: captureEngine)
        for objectID in objectIDs where drafts[objectID] == nil {
            let weightText = captureEngine.weightInGrams(for: objectID)
                .flatMap { PositiveDecimalText.format($0, maximumFractionDigits: 3) }
                ?? ""
            drafts[objectID] = Draft(
                nameText: captureEngine.name(for: objectID) ?? "",
                packedWeightText: weightText,
                arrivedWithoutName: isUnnamed(captureEngine.name(for: objectID))
            )
        }

        let missingIDs = Set(store.packagesMissingPreparation(from: captureEngine))
        if let firstMissingIndex = objectIDs.firstIndex(where: missingIDs.contains) {
            currentIndex = firstMissingIndex
        }
    }

    private func nameBinding(for objectID: UUID) -> Binding<String> {
        Binding(
            get: { drafts[objectID]?.nameText ?? "" },
            set: { newValue in
                updateDraft(for: objectID) { draft in
                    draft.nameText = newValue
                }
            }
        )
    }

    private func packedWeightBinding(for objectID: UUID) -> Binding<String> {
        Binding(
            get: { drafts[objectID]?.packedWeightText ?? "" },
            set: { newValue in
                updateDraft(for: objectID) { draft in
                    draft.packedWeightText = newValue
                }
            }
        )
    }

    private func updateDraft(for objectID: UUID, change: (inout Draft) -> Void) {
        var draft = drafts[objectID] ?? Draft(
            nameText: captureEngine.name(for: objectID) ?? "",
            packedWeightText: "",
            arrivedWithoutName: isUnnamed(captureEngine.name(for: objectID))
        )
        change(&draft)
        drafts[objectID] = draft
        validationMessage = nil
        invalidFields = []
    }

    private func isUnnamed(_ name: String?) -> Bool {
        (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Leaves an object out: no box, no placement, no name or weight needed.
    private func skip(objectID: UUID) {
        focusedField = nil
        validationMessage = nil
        invalidFields = []
        guard store.markExcludedBecauseNoStockedBoxFits(
            objectID,
            in: captureEngine
        ) else {
            validationMessage = "This object could not be skipped, because a box does fit it. Choose the box and weigh it instead."
            return
        }
        advanceAfterCurrentObject()
    }

    private func saveAndAdvance(objectID: UUID) {
        focusedField = nil
        validationMessage = nil
        invalidFields = []

        if store.isSkipped(objectID, in: captureEngine) {
            advanceAfterCurrentObject()
            return
        }

        // Only exclude objects that need a box and don't have one. Objects that are already a box would
        // otherwise lose the name and weight just entered.
        let needsNoBox = store.isItsOwnBox(objectID, in: captureEngine)
        if !needsNoBox, store.fittingBoxPresets(for: objectID, in: captureEngine).isEmpty {
            guard store.markExcludedBecauseNoStockedBoxFits(
                objectID,
                in: captureEngine
            ) else {
                validationMessage = "This object could not be excluded. Review the available boxes and try again."
                return
            }
            advanceAfterCurrentObject()
            return
        }

        // Check both fields so the operator sees everything that's missing at once.
        let name = drafts[objectID]?.nameText
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let weightText = drafts[objectID]?.packedWeightText ?? ""
        let packedWeight = PositiveDecimalText.parse(weightText)
        if name.isEmpty { invalidFields.insert(.name) }
        if packedWeight == nil { invalidFields.insert(.weight) }
        if !invalidFields.isEmpty {
            validationMessage = invalidFields == [.name]
                ? "Enter a name for this object."
                : invalidFields == [.weight]
                    ? "Enter the packed weight in grams, as a number greater than zero."
                    : "Enter a name and the packed weight in grams before continuing."
            focusedField = invalidFields.contains(.name) ? .name : .weight
            return
        }
        guard captureEngine.isNameAvailable(name, excluding: objectID) else {
            invalidFields.insert(.name)
            focusedField = .name
            validationMessage = "Another object is already called “\(name)”. Give this one a different name."
            return
        }
        guard store.packagedSizeMillimetres(for: objectID, in: captureEngine) != nil else {
            validationMessage = "No available box fits this object. Mark it as already a box only if that is correct."
            return
        }
        guard let packedWeightGrams = packedWeight else {
            invalidFields.insert(.weight)
            focusedField = .weight
            validationMessage = "Enter the packed weight in grams, as a number greater than zero."
            return
        }

        captureEngine.updateName(id: objectID, name: name)
        captureEngine.updatePackedWeight(
            id: objectID,
            weightInGrams: packedWeightGrams
        )

        advanceAfterCurrentObject()
    }

    private func advanceAfterCurrentObject() {
        if currentIndex < objectIDs.count - 1 {
            currentIndex += 1
        } else {
            // The box list may have changed, so assign first.
            store.assignBoxesAutomatically(in: captureEngine)
            let missing = store.packagesMissingPreparation(from: captureEngine)
            guard let firstMissing = missing.first else {
                onComplete()
                return
            }
            // Jump to the first missing field instead of only showing a message.
            let names = missing
                .map { captureEngine.name(for: $0) ?? "an unnamed object" }
                .joined(separator: ", ")
            validationMessage = missing.count == 1
                ? "\(names) still needs a box, a name or a packed weight."
                : "These still need a box, a name or a packed weight: \(names)."
            if let index = objectIDs.firstIndex(of: firstMissing) {
                currentIndex = index
            }
        }
    }

    private func goBack() {
        focusedField = nil
        validationMessage = nil
        invalidFields = []
        if currentIndex > 0 {
            currentIndex -= 1
        } else {
            dismiss()
        }
    }

    private func displayName(for objectID: UUID) -> String {
        let name = drafts[objectID]?.nameText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return name
        }
        return "Object \((objectIDs.firstIndex(of: objectID) ?? 0) + 1)"
    }

    private func objectColour(for objectID: UUID) -> Color {
        guard let colour = captureEngine.objectColor(for: objectID) else {
            return .accentColor
        }
        return Color(red: colour.red, green: colour.green, blue: colour.blue)
    }

    private func sizeText(_ size: SIMD3<Double>) -> String {
        "\(Int(size.x.rounded(.up))) × \(Int(size.y.rounded(.up))) × \(Int(size.z.rounded(.up))) mm"
    }

    private func weightInstruction(for objectID: UUID, packageName: String) -> String {
        if store.isItsOwnBox(objectID, in: captureEngine) {
            return "Weigh \(packageName) as it is."
        }
        if let assigned = store.selectedBoxPreset(for: objectID) {
            return "Put \(packageName) in the \(assigned.name) box, add the packing material, and close it."
        }
        return "Pack \(packageName), then weigh it."
    }

}
