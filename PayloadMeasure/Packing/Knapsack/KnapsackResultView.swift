import SwiftUI

// Result screen for the 3D knapsack: choose a packing mode, inspect it, then load it layer by
// layer from the floor up.

/// Gives each opening of the room-scale AR view a fresh identity so old placement state isn't
/// kept. The ARView itself is shared across the app.
nonisolated struct PackingARPresentation: Identifiable, Sendable {
    let id: UUID
    let solution: BaldiSolution

    init(id: UUID = UUID(), solution: BaldiSolution) {
        self.id = id
        self.solution = solution
    }
}

struct BaldiResultView: View {
    let comparison: BaldiComparison
    let colours: [UUID: Color]
    var allowsRoomScaleAR = true
    @Binding var highlightedPackageID: UUID?

    @State private var selectedMode: BaldiPackingMode = .paper
    /// A new model and coordinator per opening, on the shared ARView.
    @State private var augmentedPresentation: PackingARPresentation?
    @State private var showsDetails = false

    private var result: BaldiResult {
        comparison.result(for: selectedMode)
    }

    var body: some View {
        Group {
            if let solution = verifiedSolution,
               let verification = result.verification {
                headline(solution)
                // In the AR condition the plan is only shown on the real table, so participants load from the
                // full-size version. The no-AR condition keeps the on-screen drawing; that difference is part of
                // what's being compared.
                if allowsRoomScaleAR {
                    placeOnTableButton
                } else {
                    interactivePacking(solution)
                }
                openingInstruction
                loadingGuide(solution, verification: verification)
                if !solution.unloaded.isEmpty {
                    unloadedWarning(solution)
                }
            } else {
                modeControl
                readySummary
            }
        }
        .sheet(isPresented: $showsDetails) {
            detailsSheet
        }
        .onChange(of: selectedMode) { _, _ in
            highlightedPackageID = nil
            // Close the details after switching so the new result is visible.
            showsDetails = false
        }
        .fullScreenCover(item: $augmentedPresentation) { presentation in
            PackingARView(solution: presentation.solution, colours: colours)
                .id(presentation.id)
        }
    }

    /// Top of the screen: the package count, a warning if needed, and the info button. Everything else
    /// is in the details sheet so the 3D view stays visible.
    private func headline(_ solution: BaldiSolution) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(solution.loadedCount) package\(solution.loadedCount == 1 ? "" : "s") loaded")
                    .font(.title3.weight(.semibold))
                if !solution.unloaded.isEmpty {
                    Text("\(solution.unloaded.count) did not fit")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Button {
                showsDetails = true
            } label: {
                Image(systemName: "info")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Packing details and options")
        }
    }

    private var detailsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modeControl
                    readySummary
                    if let solution = verifiedSolution,
                       let verification = result.verification {
                        openingInstruction
                        loadingGuide(solution, verification: verification)
                        if !solution.unloaded.isEmpty {
                            unloadedWarning(solution)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Packing details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showsDetails = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Shows the plan on the real table at full size. Doesn't change the plan.
    private var placeOnTableButton: some View {
        Button {
            guard let solution = verifiedSolution else { return }
            augmentedPresentation = PackingARPresentation(solution: solution)
        } label: {
            Label("Show it on the table", systemImage: "arkit")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint("Places the module and its packages in the room at full size, one layer at a time.")
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
                    if let solution = verifiedSolution {
                        balanceFigures(solution)
                    } else {
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

    /// Centre of mass and the paper's unbalancing index, for comparison with the published results.
    @ViewBuilder
    private func balanceFigures(_ solution: BaldiSolution) -> some View {
        let centre = solution.centreOfMass
        if centre.x.isFinite, centre.y.isFinite, centre.z.isFinite {
            Text(
                String(
                    format: "Balance point %.0f, %.0f, %.0f mm · %.0f mm from target · spread %.0f mm",
                    centre.x, centre.y, centre.z,
                    solution.centreOfMassDistanceToIdeal,
                    solution.unbalancingIndex
                )
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Balance figures")
        }
    }

    // MARK: - Interactive overview

    private func interactivePacking(_ solution: BaldiSolution) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tap a package to see which one it is")
                    .font(.subheadline.weight(.semibold))
                BaldiPlanView(
                    solution: solution,
                    colours: colours,
                    highlightedPackageID: packageSelection
                )
                .id(selectedMode)

                Text("Drag to rotate, pinch to zoom.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var openingInstruction: some View {
        Label {
            Text(Self.openingInstructionText)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "rectangle.split.3x1")
                .foregroundStyle(.primary)
        }
        .font(.caption.weight(.medium))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 12))
        .accessibilityLabel("Opening marker instruction")
        .accessibilityValue(Self.openingInstructionText)
    }

    private static let openingInstructionText =
        "The shaded side is the box opening. The dark line runs the length of the box, its longest side, parallel to that opening. Turn the physical package until both match before loading."

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
                    highlightedPackageID: packageSelection
                )

                packageLegend(
                    layer.placements,
                    numbering: numbering
                )
            }
        }
    }

    private func packageLegend(
        _ placements: [BaldiPlacement],
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
                            } else {
                                highlightedPackageID = placement.id
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
                        .accessibilityHint(
                            allowsRoomScaleAR
                                ? "Reveals or hides this package name."
                                : "Reveals or hides this package name and highlights it in the drawing."
                        )
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

    private var packageSelection: Binding<UUID?> {
        Binding(
            get: { highlightedPackageID },
            set: { id in
                highlightedPackageID = id
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
