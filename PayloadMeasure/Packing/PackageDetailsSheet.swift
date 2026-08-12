import SwiftUI
import simd

// One object, boxed and weighed on the spot. This is what "Box as you go" shows after each
// measurement, and what the review list opens when a weight needs correcting.
//
// In:  the object, the capture engine and the packing store.
// Out: writes the name, the own-box mark and the packed weight back through the engine and store.
//      Calls onRescan when the operator wants to measure the object again.

struct PackageDetailsSheet: View {
    let objectID: UUID
    let captureEngine: ObjectCaptureEngine
    @Bindable var store: PackingStore
    var onRescan: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var weightText = ""
    @State private var message: String?
    @State private var isShowingBoxes = false
    @State private var forcesSize = false
    @State private var forcedLength: Double = 100
    @State private var forcedWidth: Double = 100
    @State private var forcedHeight: Double = 100

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
                }

                Section {
                    if forcesSize {
                        Text("Loaded at the size you entered, ignoring the measurement.")
                            .font(.subheadline)
                    } else if store.isItsOwnBox(objectID, in: captureEngine) {
                        Text("Loaded exactly as measured. Nothing to pack.")
                            .font(.subheadline)
                    } else if let assigned = store.selectedBoxPreset(for: objectID) {
                        LabeledContent("Put it in", value: assigned.name)
                            .monospacedDigit()
                    } else {
                        Text("Nothing in the list fits this object. Mark it as already a box, or add a bigger one.")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }

                    Toggle("Already a box", isOn: ownBoxBinding)
                        .disabled(forcesSize)

                    Toggle("Enforce box size", isOn: forcedSizeBinding)

                    if forcesSize {
                        millimetres("Length", value: $forcedLength)
                        millimetres("Width", value: $forcedWidth)
                        millimetres("Height", value: $forcedHeight)
                    }

                    Button("Boxes…") { isShowingBoxes = true }
                        .disabled(forcesSize)
                } header: {
                    Text("Box")
                } footer: {
                    Text("Enforce a size when the measurement is wrong: the load is planned around the size you type instead, with no box chosen for it.")
                }

                Section("Packed weight") {
                    HStack {
                        TextField("Weight", text: $weightText)
                            .keyboardType(.decimalPad)
                            .monospacedDigit()
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
            .sheet(isPresented: $isShowingBoxes, onDismiss: reassign) {
                BoxCatalogView(store: store)
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

    private var forcedSizeBinding: Binding<Bool> {
        Binding(
            get: { forcesSize },
            set: { isForced in
                forcesSize = isForced
                message = nil
                if isForced {
                    store.setForcedSize(currentForcedSize, for: objectID, in: captureEngine)
                } else {
                    store.setForcedSize(nil, for: objectID, in: captureEngine)
                    store.assignBoxesAutomatically(in: captureEngine)
                }
            }
        )
    }

    private var currentForcedSize: SIMD3<Double> {
        SIMD3(forcedLength, forcedWidth, forcedHeight)
    }

    private func millimetres(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 84)
                    .onChange(of: value.wrappedValue) { _, new in
                        value.wrappedValue = min(max(new.rounded(), 1), 999)
                        store.setForcedSize(currentForcedSize, for: objectID, in: captureEngine)
                    }
                Text("mm").foregroundStyle(.secondary)
            }
        }
    }

    private func load() {
        store.assignBoxesAutomatically(in: captureEngine)
        if let forced = store.forcedSize(for: objectID, in: captureEngine) {
            forcesSize = true
            forcedLength = forced.x
            forcedWidth = forced.y
            forcedHeight = forced.z
        } else if let measured = store.measuredSizeMillimetres(for: objectID, in: captureEngine) {
            forcedLength = min(max(measured.x.rounded(), 1), 999)
            forcedWidth = min(max(measured.y.rounded(), 1), 999)
            forcedHeight = min(max(measured.z.rounded(), 1), 999)
        }
        name = captureEngine.name(for: objectID) ?? ""
        weightText = captureEngine.weightInGrams(for: objectID)
            .flatMap { PositiveDecimalText.format($0, maximumFractionDigits: 3) } ?? ""
    }

    private func reassign() {
        store.assignBoxesAutomatically(in: captureEngine)
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
            message = "No box fits this object. Enforce a size, add a bigger box, or mark it as already a box."
            return
        }
        captureEngine.updateName(id: objectID, name: trimmed)
        captureEngine.updatePackedWeight(id: objectID, weightInGrams: grams)
        dismiss()
    }
}
