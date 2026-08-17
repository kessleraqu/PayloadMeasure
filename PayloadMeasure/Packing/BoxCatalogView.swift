import SwiftUI
import simd

// The boxes the system chooses from for one payload, and the form for adding more.
//
// In:  a BoxCatalogue, which is per payload.
// Out: on screen only. The list survives relaunch, every box can be deleted, and changing it invalidates
//      the current arrangement.
//
// Every box carries two sizes, and this is the one screen that shows both, because it is the one screen
// where they can be edited:
//
//   • the size it takes up  — what the loading plan places in the payload, and the box's name
//   • the size it holds     — what an object has to fit inside to be assigned this box
//
// They are the same figure for almost every box. Two of the stocked ones were measured and are not what
// their size suggests, which is the whole reason the two are kept apart. Nowhere else in the app mentions
// the distinction: the packing instruction says one size, the one written on the box.
//
// Reached both from the setup screen, before a run starts, and from the measuring screens. Both edit the
// same saved list for that payload; `onChange` is how the measuring side learns to re-solve.

struct BoxCatalogView: View {
    let catalogue: BoxCatalogue
    /// Called after every edit. Nil from the setup screen, where nothing is solved yet.
    var onChange: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var length: Double = 200
    @State private var width: Double = 150
    @State private var height: Double = 100
    @State private var holdsADifferentSize = false
    @State private var innerLength: Double = 200
    @State private var innerWidth: Double = 150
    @State private var innerHeight: Double = 100
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
                        HStack(alignment: .firstTextBaseline) {
                            presetRow(preset)
                            Spacer(minLength: 8)
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
                    Text("Takes up is what the loading plan places in the payload. Holds is what an object has to fit inside to be given this box. Tap the bin, or swipe, to delete a box. An object fits when it fits in any of the six orientations, and the system always assigns the smallest box that fits.")
                }

                Section {
                    millimetres("Length", value: $length)
                    millimetres("Width", value: $width)
                    millimetres("Height", value: $height)
                } header: {
                    Text("New box · size it takes up")
                } footer: {
                    Text("This is the box's name, and the space it occupies in the payload.")
                }

                Section {
                    Toggle("It holds less than its size suggests", isOn: $holdsADifferentSize)
                    if holdsADifferentSize {
                        millimetres("Length inside", value: $innerLength)
                        millimetres("Width inside", value: $innerWidth)
                        millimetres("Height inside", value: $innerHeight)
                    }
                } header: {
                    Text("New box · size it holds")
                } footer: {
                    Text(holdsADifferentSize
                        ? "Measured, rather than read off the box. Only the fit test uses it; the box is still named and packed at the size above."
                        : "Off for almost every box: what it holds is its size.")
                }

                Section {
                    Button("Add box", action: add)
                        .disabled(!canAdd)

                    if let message {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
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
            .onChange(of: enteredSize) { _, size in
                guard !holdsADifferentSize else { return }
                innerLength = size.x
                innerWidth = size.y
                innerHeight = size.z
            }
        }
    }

    private func presetRow(_ preset: PackingBoxPreset) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(preset.name)
                .monospacedDigit()
            if preset.usableInnerSizeMillimetres == preset.outerSizeMillimetres {
                Text("Takes up and holds the same")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Holds \(PackingBoxPreset.sizeName(preset.usableInnerSizeMillimetres))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            preset.usableInnerSizeMillimetres == preset.outerSizeMillimetres
                ? "\(preset.name), takes up and holds the same"
                : "Takes up \(preset.name), holds \(PackingBoxPreset.sizeName(preset.usableInnerSizeMillimetres))"
        )
    }

    private var titleText: String {
        catalogue.payload == .big ? "Boxes · big payload" : "Boxes · small payload"
    }

    private var enteredSize: SIMD3<Double> {
        SIMD3(length, width, height)
    }

    private var enteredInnerSize: SIMD3<Double>? {
        holdsADifferentSize ? SIMD3(innerLength, innerWidth, innerHeight) : nil
    }

    private var isDuplicate: Bool {
        catalogue.presets.contains { $0.outerSizeMillimetres == enteredSize }
    }

    private var canAdd: Bool {
        enteredSize.allFiniteAndPositive
            && (enteredInnerSize?.allFiniteAndPositive ?? true)
            && !isDuplicate
    }

    private func add() {
        guard catalogue.add(
            outerSizeMillimetres: enteredSize,
            usableInnerSizeMillimetres: enteredInnerSize
        ) != nil else {
            message = isDuplicate
                ? "That size is already in the list."
                : "That size cannot be used. Every side has to be more than zero."
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
