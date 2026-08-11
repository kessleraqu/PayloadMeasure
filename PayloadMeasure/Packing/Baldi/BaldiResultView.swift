import SwiftUI

/// Operator-facing result for the two support-aware Baldi packing modes.
///
/// Detailed method evidence lives in the audit documentation and verifier. This screen stays
/// focused on the physical task: choose a result, inspect it, then load one complete layer at a
/// time from the floor upward.
struct BaldiResultView: View {
    let comparison: Baldi3BKPComparison
    let colours: [UUID: Color]
    @Binding var highlightedPackageID: UUID?

    @State private var selectedMode: BaldiPackingMode = .paper
    @State private var selectedLayerIndex: Int?

    private var result: Baldi3BKPResult {
        comparison.result(for: selectedMode)
    }

    var body: some View {
        Group {
            modeControl
            readySummary

            if let solution = verifiedSolution,
               let verification = result.verification {
                interactivePacking(solution)
                openingInstruction
                loadingGuide(solution, verification: verification)
                if !solution.unloaded.isEmpty {
                    unloadedWarning(solution)
                }
            }
        }
        .onChange(of: selectedMode) { _, _ in
            highlightedPackageID = nil
            selectedLayerIndex = nil
        }
    }

    // MARK: - Mode and readiness

    private var modeControl: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Packing version")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Packing version", selection: $selectedMode) {
                ForEach(BaldiPackingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Switches between the paper stopping rule and the additional centring refinement.")

            Text(
                selectedMode == .paper
                    ? "Paper stops when the load first reaches the allowed balance region."
                    : "Centred adds a bounded refinement toward the middle of that region."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private var readySummary: some View {
        card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusSymbol)
                    .font(.title3)
                    .foregroundStyle(statusColour)
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if verifiedSolution == nil {
                        ForEach(result.errors.prefix(4), id: \.self) { message in
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Interactive overview

    private func interactivePacking(_ solution: BaldiSolution) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("1. Inspect the load")
                    .font(.headline)
                BaldiPlanView(
                    solution: solution,
                    colours: colours,
                    highlightedPackageID: packageSelection(in: solution),
                    selectedLayerIndex: selectedLayerIndex
                )
                .id(selectedMode)

                Label(
                    "Tap a package to reveal its name. Drag to rotate; pinch to zoom.",
                    systemImage: "hand.tap"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    compactKey(colour: .orange, text: "cargo balance")
                    compactKey(colour: .purple, text: "target")
                    compactKey(colour: .green, text: "allowed region")
                }
                .font(.caption2)
            }
        }
    }

    private var openingInstruction: some View {
        Label {
            Text("The opening marker identifies the box opening, and measured length runs parallel to it. Rotate the physical package to match before loading.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.left.and.right")
                .foregroundStyle(.yellow)
        }
        .font(.caption.weight(.medium))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.1), in: .rect(cornerRadius: 12))
        .accessibilityLabel("Opening marker instruction")
        .accessibilityValue("The opening marker identifies the box opening, and measured length runs parallel to it. Rotate the physical package to match before loading.")
    }

    private func compactKey(colour: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(colour).frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
    }

    // MARK: - Sequential loading

    private func loadingGuide(
        _ solution: BaldiSolution,
        verification: BaldiVerification
    ) -> some View {
        let layers = BaldiLoadingGuide.layers(for: solution)
        let numbering = BaldiLoadingGuide.numbering(for: solution)
        let reports = Dictionary(
            uniqueKeysWithValues: verification.supportReports.map { ($0.packageID, $0) }
        )

        return VStack(alignment: .leading, spacing: 10) {
            Text("2. Load from the floor up")
                .font(.headline)
            Text("Complete each numbered layer before starting the next one.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(layers) { layer in
                layerStage(
                    layer,
                    solution: solution,
                    numbering: numbering,
                    reports: reports
                )
            }
        }
    }

    private func layerStage(
        _ layer: BaldiLoadingLayer,
        solution: BaldiSolution,
        numbering: [UUID: Int],
        reports: [UUID: BaldiSupportReport]
    ) -> some View {
        card {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Text("\(layer.index + 1)")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor, in: .circle)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(layer.isFloorLayer ? "Place on the payload floor" : "Place after Layer \(layer.index)")
                            .font(.subheadline.weight(.semibold))
                        Text(layerAction(layer, reports: reports, numbering: numbering))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                BaldiLayerFootprintView(
                    solution: solution,
                    layer: layer,
                    colours: colours,
                    numbering: numbering,
                    highlightedPackageID: packageSelection(in: solution)
                )

                packageLegend(
                    layer.placements,
                    layerIndex: layer.index,
                    numbering: numbering
                )
            }
        }
    }

    private func packageLegend(
        _ placements: [BaldiPlacement],
        layerIndex: Int,
        numbering: [UUID: Int]
    ) -> some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(placements) { placement in
                        let selected = highlightedPackageID == placement.id
                        Button {
                            if selected {
                                highlightedPackageID = nil
                                selectedLayerIndex = nil
                            } else {
                                highlightedPackageID = placement.id
                                selectedLayerIndex = layerIndex
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(colours[placement.id] ?? .accentColor)
                                        .frame(width: 14, height: 14)
                                    Text("#\(numbering[placement.id] ?? 0)")
                                        .font(.caption.weight(.bold).monospacedDigit())
                                    if selected {
                                        Text(placement.name)
                                            .font(.caption.weight(.semibold))
                                            .lineLimit(1)
                                    }
                                }
                                if selected {
                                    Text(BaldiOpeningMarker.description(for: placement))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(
                                selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05),
                                in: .rect(cornerRadius: 9)
                            )
                        }
                        .id(placement.id)
                        .buttonStyle(.plain)
                        .accessibilityLabel("Package \(numbering[placement.id] ?? 0), \(placement.name)")
                        .accessibilityValue(BaldiOpeningMarker.description(for: placement))
                        .accessibilityHint("Reveals or hides this package name and highlights it in the 3D view.")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: highlightedPackageID) { _, id in
                guard let id, placements.contains(where: { $0.id == id }) else { return }
                withAnimation { reader.scrollTo(id, anchor: .center) }
            }
            .onAppear {
                guard let id = highlightedPackageID,
                      placements.contains(where: { $0.id == id }) else { return }
                reader.scrollTo(id, anchor: .center)
            }
        }
    }

    private func layerAction(
        _ layer: BaldiLoadingLayer,
        reports: [UUID: BaldiSupportReport],
        numbering: [UUID: Int]
    ) -> String {
        if layer.isFloorLayer {
            return "Set every coloured package in this plan directly on the floor."
        }

        let supporterNumbers = Set(
            layer.placements.flatMap { reports[$0.id]?.supporterIDs ?? [] }
                .compactMap { numbering[$0] }
        ).sorted()
        guard !supporterNumbers.isEmpty else {
            return "Finish all earlier layers, then place every package in this plan."
        }
        let supporters = supporterNumbers.map { "#\($0)" }.joined(separator: ", ")
        return "Finish the earlier layer, then place these on supporter\(supporterNumbers.count == 1 ? "" : "s") \(supporters)."
    }

    // MARK: - Exceptions

    private func unloadedWarning(_ solution: BaldiSolution) -> some View {
        card {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(solution.unloaded.count) not loaded")
                        .font(.subheadline.weight(.semibold))
                    Text(solution.unloaded.map(\.name).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !result.oversizedItems.isEmpty {
                        Text("\(result.oversizedItems.count) cannot fit in any allowed rotation.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - State and status

    private var verifiedSolution: BaldiSolution? {
        guard result.status == .feasible,
              result.verification?.isValid == true else { return nil }
        return result.solution
    }

    private func packageSelection(in solution: BaldiSolution) -> Binding<UUID?> {
        Binding(
            get: { highlightedPackageID },
            set: { id in
                highlightedPackageID = id
                guard let id else {
                    selectedLayerIndex = nil
                    return
                }
                selectedLayerIndex = BaldiLoadingGuide.layers(for: solution).first {
                    $0.placements.contains { $0.id == id }
                }?.index
            }
        )
    }

    private var statusTitle: String {
        if verifiedSolution != nil { return "Ready to load" }
        return switch result.status {
        case .feasible: "Packing is not ready"
        case .notFound: "No usable load found"
        case .invalidInput: "Arrangement needs input"
        case .verificationFailed: "Packing failed its checks"
        }
    }

    private var statusDetail: String {
        if let solution = verifiedSolution {
            let layers = BaldiLoadingGuide.layers(for: solution)
            let layerWord = layers.count == 1 ? "layer" : "layers"
            let total = solution.loadedCount + solution.unloaded.count
            return "\(solution.loadedCount) of \(total) packages · \(layers.count) bottom-up \(layerWord) · balance and support checked"
        }
        return switch result.status {
        case .feasible: "The result is incomplete or could not be verified."
        case .notFound: "Try the other packing version or revise the load."
        case .invalidInput: "Correct the package or container details, then arrange again."
        case .verificationFailed: "This arrangement is hidden and must not be used."
        }
    }

    private var statusSymbol: String {
        verifiedSolution != nil ? "checkmark.circle.fill" : {
            switch result.status {
            case .notFound: "magnifyingglass"
            case .feasible, .invalidInput: "exclamationmark.triangle.fill"
            case .verificationFailed: "xmark.seal.fill"
            }
        }()
    }

    private var statusColour: Color {
        verifiedSolution != nil ? .green : result.status == .notFound ? .orange : .red
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }
}
