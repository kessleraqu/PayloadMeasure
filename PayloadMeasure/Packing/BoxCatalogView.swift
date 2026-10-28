import SwiftUI
import simd

// Box list for one payload, with a form for adding boxes. Changes are saved and invalidate the
// current arrangement.
//
// Each box has an interior size (what has to fit inside it, also used as its name) and an outer
// footprint (what gets placed in the payload). They are usually the same; two of the stocked
// boxes were measured and differ. Opened from both the setup screen and the measuring screens.

struct BoxCatalogView: View {
    let catalogue: BoxCatalogue
    /// Called after every edit so the plan can be re-solved. Nil on the setup screen.
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
                    Text("The displayed size is the interior. Outer footprint is still tracked for payload placement. Tap the bin, or swipe, to delete a box. An object fits when it fits in any of the six orientations, and the system always assigns the smallest box that fits.")
                }

                Section {
                    millimetres("Length", value: $length)
                    millimetres("Width", value: $width)
                    millimetres("Height", value: $height)
                } header: {
                    Text("New box · outer footprint")
                } footer: {
                    Text("Used for payload placement only.")
                }

                Section {
                    Toggle("Interior differs from outer footprint", isOn: $holdsADifferentSize)
                    if holdsADifferentSize {
                        millimetres("Length inside", value: $innerLength)
                        millimetres("Width inside", value: $innerWidth)
                        millimetres("Height inside", value: $innerHeight)
                    }
                } header: {
                    Text("New box · interior size (displayed name)")
                } footer: {
                    Text(holdsADifferentSize
                        ? "This is the size shown everywhere in the app when naming this box."
                        : "Off for almost every box: interior and outer are the same.")
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
                Text("Interior and outer are the same")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Outer footprint \(PackingBoxPreset.sizeName(preset.outerSizeMillimetres))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            preset.usableInnerSizeMillimetres == preset.outerSizeMillimetres
                ? "\(preset.name), interior and outer are the same"
                : "\(preset.name), outer footprint \(PackingBoxPreset.sizeName(preset.outerSizeMillimetres))"
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
