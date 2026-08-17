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
            .safeAreaInset(edge: .top) {
                StudyTimerStrip(study: study)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }

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
            .safeAreaInset(edge: .top) {
                StudyTimerStrip(study: study)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            }
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
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: FocusedField?
    @State private var currentIndex = 0
    @State private var drafts: [UUID: Draft] = [:]
    @State private var validationMessage: String?
    @State private var isShowingBoxCatalog = false
    @State private var forcedSizeDrafts: [UUID: SIMD3<Double>] = [:]

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
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(currentIndex == 0 ? "Back" : "Previous") {
                        goBack()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isShowingBoxCatalog = true
                        } label: {
                            Label("Boxes…", systemImage: "shippingbox")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Preparation options")
                    .accessibilityHint("Review the boxes, add a size, or delete one.")
                }

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
        .sheet(isPresented: $isShowingBoxCatalog, onDismiss: reassignBoxes) {
            BoxCatalogView(catalogue: store.boxes) { store.reloadBoxes() }
        }
    }

    private func preparationContent(for objectID: UUID) -> some View {
        let canPrepare = store.isItsOwnBox(objectID, in: captureEngine)
            || store.forcedSize(for: objectID, in: captureEngine) != nil
            || !store.fittingBoxPresets(for: objectID, in: captureEngine).isEmpty

        // Sized to fit an iPhone 13 without scrolling: the photo is a thumbnail beside the name
        // rather than a banner above it, and every card carries one line of guidance at most. The
        // ScrollView stays only so accessibility text sizes still reach the bottom.
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                progressHeader
                objectCard(for: objectID, allowsNameEditing: canPrepare)

                if canPrepare {
                    boxCard(for: objectID)
                    weightCard(for: objectID)
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
            nextButton(for: objectID)
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

    private func objectCard(
        for objectID: UUID,
        allowsNameEditing: Bool
    ) -> some View {
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

                if allowsNameEditing {
                    TextField("Object name", text: nameBinding(for: objectID))
                        .textInputAutocapitalization(.words)
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .accessibilityLabel("Object name")
                        .accessibilityHint("This name appears in the loading plan.")
                } else {
                    Text(displayName(for: objectID))
                        .font(.title3.weight(.semibold))
                        .accessibilityLabel("Object name, \(displayName(for: objectID))")
                }
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
        let forced = store.forcedSize(for: objectID, in: captureEngine)

        VStack(alignment: .leading, spacing: 9) {
            Label("1. Box this object", systemImage: "shippingbox")
                .font(.headline)

            if let forced {
                Text("Loaded at **\(sizeText(forced))**, the size you entered.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isOwnBox {
                Text("This object is already a box, so it is loaded exactly as measured. Nothing to pack.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let assigned {
                Text("Put it in the **\(assigned.name)** box — the smallest one it fits.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(PackingBoxPreset.sizeName(assigned.usableInnerSizeMillimetres)) inside")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle(isOn: ownBoxBinding(for: objectID)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Already a box")
                        .font(.subheadline.weight(.medium))
                    Text("Load it at its measured size instead of putting it in one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityHint("Uses the measured dimensions as the package size, with no outer box.")
            .disabled(forced != nil)

            Toggle(isOn: forcedSizeBinding(for: objectID)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enforce box size")
                        .font(.subheadline.weight(.medium))
                    Text("Plan around a size you type, when the measurement is wrong.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if forced != nil {
                HStack(spacing: 8) {
                    forcedSizeField("L", axis: 0, objectID: objectID)
                    forcedSizeField("W", axis: 1, objectID: objectID)
                    forcedSizeField("H", axis: 2, objectID: objectID)
                    Text("mm").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18)
        )
    }

    private func forcedSizeBinding(for objectID: UUID) -> Binding<Bool> {
        Binding(
            get: { store.forcedSize(for: objectID, in: captureEngine) != nil },
            set: { isForced in
                if isForced {
                    let start = forcedSizeDrafts[objectID]
                        ?? store.measuredSizeMillimetres(for: objectID, in: captureEngine)
                            .map { SIMD3($0.x.rounded(), $0.y.rounded(), $0.z.rounded()) }
                        ?? SIMD3(100, 100, 100)
                    forcedSizeDrafts[objectID] = start
                    store.setForcedSize(start, for: objectID, in: captureEngine)
                } else {
                    store.setForcedSize(nil, for: objectID, in: captureEngine)
                    store.assignBoxesAutomatically(in: captureEngine)
                }
                validationMessage = nil
            }
        )
    }

    private func forcedSizeField(_ title: String, axis: Int, objectID: UUID) -> some View {
        let binding = Binding<Double>(
            get: { store.forcedSize(for: objectID, in: captureEngine)?[axis] ?? 100 },
            set: { new in
                var size = store.forcedSize(for: objectID, in: captureEngine)
                    ?? SIMD3(100, 100, 100)
                size[axis] = min(max(new.rounded(), 1), 999)
                forcedSizeDrafts[objectID] = size
                store.setForcedSize(size, for: objectID, in: captureEngine)
            }
        )
        return HStack(spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: binding, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 52)
                .textFieldStyle(.roundedBorder)
        }
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

            Text("This object does not fit any available box, even when turned.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Text("Continue to leave it out. It will not appear in the loading instructions, and no name or packed weight is required.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Toggle(isOn: ownBoxBinding(for: objectID)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Already a box")
                        .font(.subheadline.weight(.medium))
                    Text("Keep it in the plan at its measured size, with no outer box.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(isOn: forcedSizeBinding(for: objectID)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enforce box size")
                        .font(.subheadline.weight(.medium))
                    Text("Plan around a size you type instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Or enforce a size below, or add a box big enough from the menu at the top right.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.orange.opacity(0.7), lineWidth: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(displayName(for: objectID)) does not fit any available box. Continue to leave it out of the loading plan. No name, box choice or packed weight is required."
        )
    }

    private func weightCard(for objectID: UUID) -> some View {
        let packageName = displayName(for: objectID)

        return VStack(alignment: .leading, spacing: 9) {
            Label("2. Pack and weigh", systemImage: "scalemass")
                .font(.headline)

            Text(weightInstruction(for: objectID, packageName: packageName))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                TextField("Total packed weight", text: packedWeightBinding(for: objectID))
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: .weight)
                    .font(.title3.monospacedDigit())
                    .padding(.horizontal, 12)
                    .frame(minHeight: 50)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Total packed weight in grams")
                    .accessibilityHint("Include the object, outer box and all packing material.")

                Text("g")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

        }
        .padding(13)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func nextButton(for objectID: UUID) -> some View {
        let hasNoFittingBox = store.fittingBoxPresets(
            for: objectID,
            in: captureEngine
        ).isEmpty
        let isLastObject = currentIndex == objectIDs.count - 1

        return Button {
            saveAndAdvance(objectID: objectID)
        } label: {
            HStack {
                Text(nextActionTitle(for: objectID))
                Spacer()
                Image(systemName: isLastObject ? "square.grid.3x3.square" : "arrow.right")
            }
            .font(.headline)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityHint(
            hasNoFittingBox
                ? isLastObject
                    ? "Excludes this object and creates a loading plan from the objects that fit available boxes."
                    : "Excludes this object from loading instructions and shows the next object."
                : isLastObject
                    ? "Checks every prepared package, then opens the loading plan."
                    : "Saves this box and packed weight, then shows the next object."
        )
    }

    private func nextActionTitle(for objectID: UUID) -> String {
        if currentIndex == objectIDs.count - 1 {
            return "Create loading plan"
        }
        return store.fittingBoxPresets(for: objectID, in: captureEngine).isEmpty
            ? "Continue"
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
    }

    private func saveAndAdvance(objectID: UUID) {
        focusedField = nil
        validationMessage = nil

        // Only exclude an object that actually needs a box and has none. Marked "already a box" or
        // given an enforced size, it needs no box at all — excluding it here would throw away the
        // name and weight just typed and leave it permanently incomplete.
        let needsNoBox = store.isItsOwnBox(objectID, in: captureEngine)
            || store.forcedSize(for: objectID, in: captureEngine) != nil
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

        let name = drafts[objectID]?.nameText
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else {
            validationMessage = "Enter a name for this object."
            return
        }
        guard captureEngine.isNameAvailable(name, excluding: objectID) else {
            validationMessage = "Another object is already called “\(name)”. Give this one a different name."
            return
        }
        guard store.packagedSizeMillimetres(for: objectID, in: captureEngine) != nil else {
            validationMessage = "No box fits this object any more. Add a bigger box, or mark the object as already a box."
            return
        }
        guard let text = drafts[objectID]?.packedWeightText,
              let packedWeightGrams = PositiveDecimalText.parse(text) else {
            validationMessage = "Enter the total packed weight as a number greater than zero grams."
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
        return "Unnamed object"
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

    /// Boxes are assigned by the system, so a new or deleted box size can change what an object
    /// should go in. Re-run the assignment whenever the catalogue is edited.
    private func reassignBoxes() {
        store.assignBoxesAutomatically(in: captureEngine)
        validationMessage = nil
    }
}
