import SwiftUI
import simd

// The outer boxes the system chooses from, and the form for adding more.
//
// In:  PackingStore.
// Out: on screen only. A box is identified by its size, so a size is all there is to enter. The
//      list survives relaunch, every box can be deleted, and changing it invalidates the current
//      arrangement.

struct BoxCatalogView: View {
    @Bindable var store: PackingStore
    @Environment(\.dismiss) private var dismiss

    @State private var length: Double = 200
    @State private var width: Double = 150
    @State private var height: Double = 100
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.boxPresets.isEmpty {
                        Text("No boxes. Add one below, or every object will have to be marked as already a box.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.boxPresets) { preset in
                        HStack {
                            Text(preset.name)
                                .monospacedDigit()
                            Spacer(minLength: 0)
                            Button(role: .destructive) {
                                store.removeBox(id: preset.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete the \(preset.name) box")
                        }
                    }
                    .onDelete { offsets in
                        for id in offsets.map({ store.boxPresets[$0].id }) {
                            store.removeBox(id: id)
                        }
                    }
                } header: {
                    Text("Boxes")
                } footer: {
                    Text("Tap the bin, or swipe, to delete a box. An object fits when it fits inside in any of the six orientations, and the system always assigns the smallest box that fits.")
                }

                Section {
                    millimetres("Length", value: $length)
                    millimetres("Width", value: $width)
                    millimetres("Height", value: $height)

                    Button("Add box", action: add)
                        .disabled(!canAdd)

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } header: {
                    Text("New box")
                } footer: {
                    Text("The size is the box's name, and it is taken as the space available inside. Nothing is subtracted for walls.")
                }
            }
            .navigationTitle("Boxes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var outerSize: SIMD3<Double> {
        SIMD3(length, width, height)
    }

    private var innerSize: SIMD3<Double> {
        outerSize - SIMD3(repeating: 2 * PackingBoxPreset.wallThicknessMillimetres)
    }

    private var isDuplicate: Bool {
        store.boxPresets.contains { $0.outerSizeMillimetres == outerSize }
    }

    private var canAdd: Bool {
        innerSize.allFiniteAndPositive && !isDuplicate
    }

    private func add() {
        guard store.addBox(outerSizeMillimetres: outerSize) != nil else {
            message = isDuplicate
                ? "That size is already in the list."
                : "This size is too small to have 1 mm walls."
            return
        }
        message = nil
    }


    private func millimetres(
        _ title: String,
        value: Binding<Double>,
        minimum: Double = 1
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 84)
                    .onChange(of: value.wrappedValue) { _, new in
                        value.wrappedValue = min(max(new, minimum), 999)
                    }
                Text("mm").foregroundStyle(.secondary)
            }
        }
    }
}
