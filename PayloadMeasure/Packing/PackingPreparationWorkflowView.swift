import SwiftUI
import UIKit

/// Keeps physical preparation and the generated arrangement inside one presentation. The camera
/// therefore remains suspended while the operator moves from handling real packages to following
/// the loading plan.
struct PackingPreparationWorkflowView: View {
    let captureEngine: ObjectCaptureEngine
    @Bindable var store: PackingStore

    @State private var stage: Stage = .preparation

    private enum Stage {
        case preparation
        case arrangement
    }

    var body: some View {
        switch stage {
        case .preparation:
            PackingPreparationView(
                captureEngine: captureEngine,
                store: store
            ) {
                withAnimation(.snappy(duration: 0.25)) {
                    stage = .arrangement
                }
            }
            .transition(.opacity)

        case .arrangement:
            PackingArrangementView(
                captureEngine: captureEngine,
                store: store
            )
            .transition(.opacity)
        }
    }
}

/// A short, one-package-at-a-time hand-off from AR measurement to the loading optimiser.
private struct PackingPreparationView: View {
    private enum FocusedField: Hashable {
        case name
        case weight
    }

    private struct Draft {
        var nameText: String
        var selectedPresetID: String?
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
                if let currentObjectID {
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

                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
        }
        .onAppear(perform: prepareDrafts)
    }

    private func preparationContent(for objectID: UUID) -> some View {
        let hasFittingBox = !store.fittingBoxPresets(
            for: objectID,
            in: captureEngine
        ).isEmpty

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                progressHeader
                objectCard(for: objectID, allowsNameEditing: hasFittingBox)

                if hasFittingBox {
                    boxChoiceCard(for: objectID)
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
            .padding(20)
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
        VStack(alignment: .leading, spacing: 12) {
            objectVisual(for: objectID)

            HStack(alignment: .center, spacing: 9) {
                Circle()
                    .fill(objectColour(for: objectID))
                    .frame(width: 13, height: 13)
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
        }
        .padding(14)
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
            .frame(maxWidth: .infinity)
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Photo of \(displayName(for: objectID))")
        } else {
            ZStack {
                objectColour(for: objectID).opacity(0.16)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(objectColour(for: objectID))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 130)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("No photo available for \(displayName(for: objectID))")
        }
    }

    @ViewBuilder
    private func boxChoiceCard(for objectID: UUID) -> some View {
        let fittingPresets = store.fittingBoxPresets(for: objectID, in: captureEngine)
        let recommendedID = store.recommendedBoxPreset(for: objectID, in: captureEngine)?.id

        if let recommended = fittingPresets.first(where: { $0.id == recommendedID }) {
            VStack(alignment: .leading, spacing: 12) {
                Label("1. Choose the outer box", systemImage: "shippingbox")
                    .font(.headline)

                Text("Use **\(recommended.name)** for the smallest fit, or choose another fitting box below.")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 8) {
                    ForEach(fittingPresets) { preset in
                        boxChoiceButton(
                            preset,
                            isRecommended: preset.id == recommendedID,
                            objectID: objectID
                        )
                    }
                }
            }
            .padding(16)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 18)
            )
        } else {
            noFittingBoxCard(for: objectID)
        }
    }

    private func noFittingBoxCard(for objectID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Does not fit available boxes", systemImage: "shippingbox.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(.orange)

            Text("This object does not fit any available box, even when turned.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            Text("Continue to leave it out. It will not appear in the loading instructions, and no name, box choice or packed weight is required.")
                .font(.footnote.weight(.semibold))
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

    private func boxChoiceButton(
        _ preset: PackingBoxPreset,
        isRecommended: Bool,
        objectID: UUID
    ) -> some View {
        let isSelected = drafts[objectID]?.selectedPresetID == preset.id

        return Button {
            updateDraft(for: objectID) { draft in
                draft.selectedPresetID = preset.id
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(preset.name)
                            .font(.subheadline.weight(.semibold))
                        if isRecommended {
                            Text("Recommended")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    Text("Outer size \(sizeText(preset.outerSizeMillimetres))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 13)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name), outer size \(sizeText(preset.outerSizeMillimetres))")
        .accessibilityValue(isSelected ? "Selected" : isRecommended ? "Recommended" : "Not selected")
        .accessibilityHint("Selects this fitting outer box for the object.")
    }

    private func weightCard(for objectID: UUID) -> some View {
        let selectedPreset = drafts[objectID]?.selectedPresetID.flatMap { selectedID in
            store.boxPresets.first(where: { $0.id == selectedID })
        }
        let packageName = displayName(for: objectID)

        return VStack(alignment: .leading, spacing: 12) {
            Label("2. Pack and weigh", systemImage: "scalemass")
                .font(.headline)

            Text(weightInstruction(packageName: packageName, preset: selectedPreset))
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

            Text("Weigh the complete sealed package. The loading plan uses this total in grams.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
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
                Text(isLastObject ? "Create loading plan" : hasNoFittingBox ? "Continue" : "Next object")
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
        for objectID in objectIDs where drafts[objectID] == nil {
            let fittingPresets = store.fittingBoxPresets(
                for: objectID,
                in: captureEngine
            )
            let storedPresetID = store.selectedBoxPreset(for: objectID)?.id
            let selectedPreset = storedPresetID.flatMap { presetID in
                fittingPresets.first(where: { $0.id == presetID })
            } ?? fittingPresets.first
            let weightText = captureEngine.weightInGrams(for: objectID)
                .flatMap { PositiveDecimalText.format($0, maximumFractionDigits: 3) }
                ?? ""
            drafts[objectID] = Draft(
                nameText: captureEngine.name(for: objectID) ?? "",
                selectedPresetID: selectedPreset?.id,
                packedWeightText: weightText
            )
        }

        // If preparation was closed part-way through, resume at the first unfinished object.
        // A fully prepared load starts at the beginning so it can be reviewed deliberately.
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
            selectedPresetID: store.recommendedBoxPreset(for: objectID, in: captureEngine)?.id,
            packedWeightText: ""
        )
        change(&draft)
        drafts[objectID] = draft
        validationMessage = nil
    }

    private func saveAndAdvance(objectID: UUID) {
        focusedField = nil
        validationMessage = nil

        if store.fittingBoxPresets(for: objectID, in: captureEngine).isEmpty {
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
        guard let presetID = drafts[objectID]?.selectedPresetID else {
            validationMessage = "Choose a fitting outer box."
            return
        }
        guard store.fittingBoxPresets(for: objectID, in: captureEngine)
            .contains(where: { $0.id == presetID }) else {
            validationMessage = "That box no longer fits this measurement. Choose another box."
            return
        }
        guard let text = drafts[objectID]?.packedWeightText,
              let packedWeightGrams = PositiveDecimalText.parse(text) else {
            validationMessage = "Enter the total packed weight as a number greater than zero grams."
            return
        }

        // Validate the whole page before committing any part of it, so a malformed weight cannot
        // leave a new name or box choice partially saved.
        captureEngine.updateName(id: objectID, name: name)
        _ = store.selectBoxPreset(id: presetID, for: objectID, in: captureEngine)
        captureEngine.updatePackedWeight(
            id: objectID,
            weightInGrams: packedWeightGrams
        )

        advanceAfterCurrentObject()
    }

    private func advanceAfterCurrentObject() {
        if currentIndex < objectIDs.count - 1 {
            currentIndex += 1
        } else if store.packagesMissingPreparation(from: captureEngine).isEmpty {
            onComplete()
        } else {
            validationMessage = "Finish the name, box and packed weight for every object before creating the plan."
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

    private func weightInstruction(
        packageName: String,
        preset: PackingBoxPreset?
    ) -> String {
        if let preset {
            return "Put \(packageName) in the \(preset.name), add the packing material, and close the box."
        }
        return "Choose a box, then put \(packageName) inside with its packing material and close it."
    }
}
