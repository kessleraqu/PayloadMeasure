import SwiftUI
import simd

// One object, boxed and weighed on the spot. This is what "Box as you go" shows after each
// measurement, and what the review list opens when a weight needs correcting.
//
// In:  the object, the capture engine and the packing store.
// Out: writes the name, the own-box mark and the packed weight back through the engine and store.
//      Calls onRescan when the operator wants to measure the object again.

struct PackageDetailsSheet: View {
    private enum FocusedField: Hashable {
        case name
        case weight
    }

    let objectID: UUID
    let captureEngine: ObjectCaptureEngine
    @Bindable var store: PackingStore
    var onRescan: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var weightText = ""
    @State private var message: String?
    @FocusState private var focusedField: FocusedField?

    var body: some View {
        NavigationStack {
            Form {
                Section("Object") {
                    if let measured = store.measuredSizeMillimetres(for: objectID, in: captureEngine) {
                        LabeledContent("Measured", value: PackingBoxPreset.sizeName(measured))
                            .monospacedDigit()
                    }
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .focused($focusedField, equals: .name)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .weight }
                }

                Section {
                    if store.isItsOwnBox(objectID, in: captureEngine) {
                        Text("Loaded exactly as measured. Nothing to pack.")
                            .font(.subheadline)
                    } else if let assigned = store.selectedBoxPreset(for: objectID) {
                        LabeledContent("Put it in", value: assigned.name)
                            .monospacedDigit()
                    } else {
                        Text("Nothing in the list fits this object. Mark it as already a box only if that is correct.")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }

                    Toggle("Already a box", isOn: ownBoxBinding)
                } header: {
                    Text("Box")
                } footer: {
                    Text("Tick this only when the measured object is already its own shipping box.")
                }

                Section("Packed weight") {
                    HStack {
                        TextField("Weight", text: $weightText)
                            .keyboardType(.decimalPad)
                            .monospacedDigit()
                            .focused($focusedField, equals: .weight)
                            .submitLabel(.done)
                        Text("g").foregroundStyle(.secondary)
                    }
                }

                if let onRescan {
                    Section {
                        Button("Measure this object again") {
                            onRescan()
                            dismiss()
                        }
                    }
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("Package details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var ownBoxBinding: Binding<Bool> {
        Binding(
            get: { store.isItsOwnBox(objectID, in: captureEngine) },
            set: {
                store.setIsItsOwnBox($0, for: objectID, in: captureEngine)
                store.assignBoxesAutomatically(in: captureEngine)
                message = nil
            }
        )
    }

    private func load() {
        store.setForcedSize(nil, for: objectID, in: captureEngine)
        store.assignBoxesAutomatically(in: captureEngine)
        name = captureEngine.name(for: objectID) ?? ""
        weightText = captureEngine.weightInGrams(for: objectID)
            .flatMap { PositiveDecimalText.format($0, maximumFractionDigits: 3) } ?? ""
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "Give this object a name."
            return
        }
        guard captureEngine.isNameAvailable(trimmed, excluding: objectID) else {
            message = "Another object is already called “\(trimmed)”."
            return
        }
        guard let grams = PositiveDecimalText.parse(weightText) else {
            message = "Enter the packed weight in grams, greater than zero."
            return
        }
        guard store.packagedSizeMillimetres(for: objectID, in: captureEngine) != nil else {
            message = "No available box fits this object. Mark it as already a box if that is correct."
            return
        }
        captureEngine.updateName(id: objectID, name: trimmed)
        captureEngine.updatePackedWeight(id: objectID, weightInGrams: grams)
        dismiss()
    }
}
