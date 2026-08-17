import SwiftUI
import simd

// The outer boxes the system chooses from for one payload, and the form for adding more.
//
// In:  a BoxCatalogue, which is per payload.
// Out: on screen only. A box is identified by its size, so a size is all there is to enter. The
//      list survives relaunch, every box can be deleted, and changing it invalidates the current
//      arrangement.
//
// Reached both from the setup screen, before a run starts, and from the measuring screens. Both edit
// the same saved list for that payload; `onChange` is how the measuring side learns to re-solve.

struct BoxCatalogView: View {
    let catalogue: BoxCatalogue
    /// Called after every edit. Nil from the setup screen, where nothing is solved yet.
    var onChange: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var length: Double = 200
    @State private var width: Double = 150
    @State private var height: Double = 100
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if catalogue.presets.isEmpty {
                        Text("No boxes. Add one below, or every object will have to be marked as already a box.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(catalogue.presets) { preset in
                        HStack {
                            Text(preset.name)
                                .monospacedDigit()
                            Spacer(minLength: 0)
                            Button(role: .destructive) {
                                remove(preset.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete the \(preset.name) box")
                        }
                    }
                    .onDelete { offsets in
                        for id in offsets.map({ catalogue.presets[$0].id }) {
                            remove(id)
                        }
                    }
                } header: {
                    Text("Boxes")
                } footer: {
                    Text("Every size here is the usable space **inside** the box. For most boxes that is what is written on them; two of the standard ones are smaller inside than their label says and are listed at their measured inside size. Tap the bin, or swipe, to delete a box. An object fits when it fits inside in any of the six orientations, and the system always assigns the smallest box that fits.")
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
                    Text("Enter the space available inside the box, measured rather than read off the label. The size is also the box's name, and nothing is subtracted for walls.")
                }

                resetSection
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var titleText: String {
        catalogue.payload == .big ? "Boxes · big payload" : "Boxes · small payload"
    }

    private var outerSize: SIMD3<Double> {
        SIMD3(length, width, height)
    }

    private var innerSize: SIMD3<Double> {
        outerSize - SIMD3(repeating: 2 * PackingBoxPreset.wallThicknessMillimetres)
    }

    private var isDuplicate: Bool {
        catalogue.presets.contains { $0.outerSizeMillimetres == outerSize }
    }

    private var canAdd: Bool {
        innerSize.allFiniteAndPositive && !isDuplicate
    }

    private func add() {
        guard catalogue.add(outerSizeMillimetres: outerSize) != nil else {
            message = isDuplicate
                ? "That size is already in the list."
                : "This size is too small to have 1 mm walls."
            return
        }
        message = nil
        onChange?()
    }

    private func remove(_ id: String) {
        catalogue.remove(id: id)
        onChange?()
    }

    private var resetSection: some View {
        Section {
            Button("Put the standard boxes back") {
                catalogue.resetToDefaults()
                onChange?()
            }
            .disabled(catalogue.isDefault)
        } footer: {
            Text("Restores this payload's standard list.")
        }
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
