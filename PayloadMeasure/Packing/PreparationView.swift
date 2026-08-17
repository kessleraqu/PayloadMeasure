import SwiftUI
import UIKit

// Step-by-step screen the operator works through before loading. The system assigns the smallest
// fitting box to every object; the operator is told which one to use, weighs the sealed package,
// and moves on. Neutral handoff screens separate measuring, packing and loading inside the sheet.
//
// In:  PackingStore and the capture engine.
// Out: on screen only. Writes names, packed weights, own-box marks and exclusions into the store.

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
                buttonTitle: "Start packing",
                study: study
            ) {
                study.beginPhase(.pack)
                withAnimation(.snappy(duration: 0.25)) {
                    stage = .preparation
                }
            }
            .onAppear { study.endCurrentPhase() }

        case .preparation:
            // The timer strip is inset inside the screen's own navigation stack rather than around it.
            // Wrapped around, it was laid over the navigation bar, and the bar's Previous button ended
            // up underneath the timers where it could be neither read nor pressed.
            PackingPreparationView(
                captureEngine: captureEngine,
                store: store,
                study: study
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
                buttonTitle: "Start loading",
                study: study
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
    }

    let captureEngine: ObjectCaptureEngine
    @Bindable var store: PackingStore
    let study: StudyStore
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: FocusedField?
    @State private var currentIndex = 0
    @State private var drafts: [UUID: Draft] = [:]
    @State private var validationMessage: String?
    /// Which fields Next refused. A message at the bottom of the screen is easy to miss; the field
    /// that is actually empty is not.
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
            .safeAreaInset(edge: .top) {
                StudyTimerStrip(study: study)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
            .navigationTitle("Prepare packages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if focusedField == .weight,
                   let currentObjectID {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button {
                            saveAndAdvance(objectID: currentObjectID)
                        } label: {
                            Label(
                                nextActionTitle(for: currentObjectID),
                                systemImage: currentIndex == objectIDs.count - 1
                                    ? "square.grid.3x3.square"
                                    : "arrow.right"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Saves the weight and continues without first closing the keyboard.")
                    }
                }
            }
        }
        .onAppear(perform: prepareDrafts)
    }

    private func preparationContent(for objectID: UUID) -> some View {
        let canPrepare = store.isItsOwnBox(objectID, in: captureEngine)
            || !store.fittingBoxPresets(for: objectID, in: captureEngine).isEmpty

        // Sized to fit an iPhone 13 without scrolling: the photo is a thumbnail beside the name
        // rather than a banner above it, and every card carries one line of guidance at most. The
        // ScrollView stays only so accessibility text sizes still reach the bottom.
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                progressHeader
                objectCard(for: objectID)

                if canPrepare {
                    boxCard(for: objectID)
                    // Name and weight are the only two things to type, so they are one card, one after
                    // the other. They used to sit on either side of the box instructions, which read as
                    // two unrelated jobs and left the second one easy to walk past.
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
        .safeAreaInset(edge: .bottom) {
            bottomBar(for: objectID)
        }
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
            // The "already a box" switch used to live here, under the assigned box size. Next to an
            // instruction to put the object in a box, a tick box about boxes reads as "done that" —
            // which is not what it means at all. It is now its own card at the bottom.
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

    /// The two things the operator has to type, side by side and labelled, with whichever one Next
    /// refused marked in place.
    private func detailsCard(for objectID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Fill in both", systemImage: "square.and.pencil")
                .font(.headline)

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

    /// Deliberately last, quiet, and phrased as a question about the object rather than as a task.
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

            // The skip is spelled out and given its own button rather than left to a "Continue" that
            // says nothing about what it does. Skipping is the honest outcome for an over-measured
            // object: it is not boxed, and it is not loaded.
            Button {
                skip(objectID: objectID)
            } label: {
                Label("Skip this object", systemImage: "arrow.uturn.forward")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .accessibilityHint("Leaves this object out: no box, no weight, and no place in the loading plan.")

            Text("Skipped objects are recorded as not boxable and are left out of the loading plan. No name or packed weight is needed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
        // Deliberately `.contain` rather than `.combine`: the card holds the Skip button and the
        // already-a-box switch, and combining them into one element would put both out of reach.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(displayName(for: objectID)) does not fit any available box."
        )
    }

    /// Previous and Next together at the bottom. Previous used to be the navigation bar's leading item,
    /// where the study timers were laid over it.
    private func bottomBar(for objectID: UUID) -> some View {
        let hasNoFittingBox = store.fittingBoxPresets(
            for: objectID,
            in: captureEngine
        ).isEmpty
        let isLastObject = currentIndex == objectIDs.count - 1

        return HStack(spacing: 10) {
            Button {
                goBack()
            } label: {
                Label(
                    currentIndex == 0 ? "Back" : "Previous",
                    systemImage: "chevron.left"
                )
                .font(.headline)
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
            }
            .buttonStyle(.bordered)
            .accessibilityHint(
                currentIndex == 0
                    ? "Leaves the packing screen."
                    : "Goes back to the previous object."
            )

            Button {
                saveAndAdvance(objectID: objectID)
            } label: {
                HStack {
                    Text(nextActionTitle(for: objectID))
                    Spacer(minLength: 6)
                    Image(systemName: isLastObject ? "square.grid.3x3.square" : "arrow.right")
                }
                .font(.headline)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(
                hasNoFittingBox
                    ? isLastObject
                        ? "Skips this object and creates a loading plan from the objects that fit available boxes."
                        : "Skips this object and shows the next one."
                    : isLastObject
                        ? "Checks every prepared package, then opens the loading plan."
                        : "Saves this box and packed weight, then shows the next object."
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func nextActionTitle(for objectID: UUID) -> String {
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

    /// Everything here depends on a finished measurement, so nothing is editable until the objects
    /// have actually arrived. Showing the fields greyed out invites typing into them; showing this
    /// instead says plainly that there is nothing to do yet.
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
                packedWeightText: weightText
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
            packedWeightText: ""
        )
        change(&draft)
        drafts[objectID] = draft
        validationMessage = nil
        invalidFields = []
    }

    /// Leaves an object out for good: it is marked as fitting no box, so it is neither boxed nor placed
    /// in the payload, and it needs no name or weight. For an object that fits nothing, this is what
    /// Next does too — the button just says so plainly.
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

        // Only exclude an object that actually needs a box and has none. An object marked "already
        // a box" needs no outer box, so excluding it here would throw away the name and weight just
        // typed and leave it permanently incomplete.
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

        // Both fields are checked before returning, so an operator who left both blank is told about
        // both at once rather than being sent back a second time for the other one.
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
            // Assign first: the box list may have changed since an object was last looked at.
            store.assignBoxesAutomatically(in: captureEngine)
            let missing = store.packagesMissingPreparation(from: captureEngine)
            guard let firstMissing = missing.first else {
                onComplete()
                return
            }
            // Name what is actually missing, and go there, rather than blocking with a message the
            // operator cannot act on.
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
