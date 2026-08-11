import SwiftUI
import simd

/// The arrangement result screen: where the selected measured packages go inside the payload
/// module and how well the resulting load is balanced. The 3D knapsack path may omit packages.
struct PackingArrangementView: View {
    let captureEngine: ObjectCaptureEngine
    @Bindable var store: PackingStore

    @Environment(\.dismiss) private var dismiss
    @State private var highlightedPackageID: UUID?
    @State private var showsSettings = false
    @State private var showsDiagnostics = false

    private var packages: [PackingItem] { store.packages(from: captureEngine) }
    private var baldiProblem: BaldiProblem { store.baldiProblem(from: captureEngine) }
    private var missingWeightIDs: [UUID] { store.packagesMissingWeight(from: captureEngine) }
    private var excludedBecauseNoStockedBoxFitsIDs: [UUID] {
        store.objectIDsExcludedBecauseNoStockedBoxFits(in: captureEngine)
    }
    private var missingPreparationIDs: [UUID] {
        store.packagesMissingPreparation(from: captureEngine)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    approachPicker

                    if captureEngine.measuredObjectIDs.isEmpty {
                        emptyCard
                    } else if !missingPreparationIDs.isEmpty {
                        preparationRequiredCard
                    } else if packages.isEmpty {
                        allPackagesExcludedCard
                    } else if store.isSolving {
                        solvingCard
                    } else {
                        if !excludedBecauseNoStockedBoxFitsIDs.isEmpty {
                            physicalExclusionCard
                        }
                        switch store.approach {
                        case .loadBalanced:
                            if let result = store.result {
                                resultContent(result)
                            } else {
                                solvingCard
                            }
                        case .knapsack3D:
                            if !missingWeightIDs.isEmpty { missingWeightCard }
                            if let comparison = store.baldiComparison {
                                BaldiResultView(
                                    comparison: comparison,
                                    colours: colourMap,
                                    highlightedPackageID: $highlightedPackageID
                                )
                            } else {
                                solvingCard
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Payload arrangement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Arrangement settings")
                }
            }
            .sheet(isPresented: $showsSettings) {
                PackingSettingsView(store: store, packages: packages)
            }
            .task(id: solveTrigger) {
                store.reconcilePreparationState(with: captureEngine)
                guard missingPreparationIDs.isEmpty else {
                    store.cancel()
                    return
                }
                guard !packages.isEmpty else {
                    store.cancel()
                    return
                }
                switch store.approach {
                case .loadBalanced:
                    if store.result == nil || store.isStale(for: packages) {
                        store.solve(packages: packages)
                    }
                case .knapsack3D:
                    if store.baldiComparison == nil || store.isBaldiStale(for: baldiProblem) {
                        store.solveBaldi(problem: baldiProblem)
                    }
                }
            }
            .onDisappear { store.cancel() }
        }
    }

    /// Re-solves whenever the measured load, the chosen method, or any setting it depends on
    /// changes.
    private var solveTrigger: String {
        guard missingPreparationIDs.isEmpty else {
            return "preparation-required|" + missingPreparationIDs
                .map(\.uuidString)
                .sorted()
                .joined(separator: ",")
        }
        switch store.approach {
        case .loadBalanced:
            return "balance|" + store.signature(for: packages)
        case .knapsack3D:
            return "knapsack|" + store.baldiSignature(for: baldiProblem)
        }
    }

    /// The two arrangement methods, side by side on the same measurements.
    private var approachPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Arrangement method", selection: $store.approach) {
                ForEach(PackingApproach.allCases) { approach in
                    Text(approach.title).tag(approach)
                }
            }
            .pickerStyle(.segmented)

            Text(
                store.approach == .knapsack3D
                    ? "Stacks packages in supported layers; some may be left out."
                    : "Places every package on the floor and balances the load."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - States

    private var solvingCard: some View {
        card {
            HStack(spacing: 14) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        store.approach == .knapsack3D
                            ? "Preparing both 3D layouts"
                            : "Optimising the arrangement"
                    )
                        .font(.headline)
                    Text(
                        store.approach == .knapsack3D
                            ? "Preparing the Paper-mode and centre-refined supported layouts for \(packages.count) packages."
                            : "Solving one mixed-integer program for all \(packages.count) packages at once."
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var emptyCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Label("Nothing to arrange yet", systemImage: "shippingbox")
                    .font(.headline)
                Text("Measure and lock at least one object first.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var preparationRequiredCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Label("Finish preparing the packages", systemImage: "shippingbox")
                    .font(.headline)
                Text("Return to package preparation. Prepare each fitting object, or continue past an object that does not fit an available box.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var allPackagesExcludedCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Label("Nothing submitted for loading", systemImage: "shippingbox.and.arrow.backward")
                    .font(.headline)
                Text("None of the measured objects fits an available outer box, so there is no loading plan to follow.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var physicalExclusionCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Label("Left out — no fitting box", systemImage: "shippingbox.and.arrow.backward")
                    .font(.headline)
                Text("Not in this plan: \(physicalExclusionNames). These objects do not fit any available outer box.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var physicalExclusionNames: String {
        excludedBecauseNoStockedBoxFitsIDs.map { id in
            captureEngine.name(for: id)
                ?? "Object \(captureEngine.objectNumber(for: id) ?? 0)"
        }
        .joined(separator: ", ")
    }

    @ViewBuilder
    private func resultContent(_ result: PackingResult) -> some View {
        statusCard(result)

        if !missingWeightIDs.isEmpty {
            missingWeightCard
        }

        if let solution = result.solution {
            drawingCard(solution)
            balanceCard(solution, result: result)
            placementCard(solution)
            loadCard(solution)
        }

        if let verification = result.verification {
            verificationCard(verification)
        }

        diagnosticsCard(result)
        scopeCard
    }

    // MARK: - Cards

    private func statusCard(_ result: PackingResult) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: statusSymbol(result))
                        .font(.title2)
                        .foregroundStyle(statusColour(result))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle(result))
                            .font(.headline)
                        Text(statusDetail(result))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if !result.errors.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(result.errors, id: \.self) { message in
                            Label(message, systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        store.solve(packages: packages)
                    } label: {
                        Label("Re-optimise", systemImage: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(packages.isEmpty || store.isSolving)

                    Button {
                        showsSettings = true
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var missingWeightCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Label("Weights missing", systemImage: "scalemass")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("Balance cannot be computed without every package's weight. Add one to: \(missingWeightNames).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var missingWeightNames: String {
        missingWeightIDs
            .map { captureEngine.name(for: $0) ?? "an unnamed object" }
            .joined(separator: ", ")
    }

    private func drawingCard(_ solution: PackingSolution) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                PackingPlanView(
                    solution: solution,
                    colours: colourMap,
                    highlightedPackageID: highlightedPackageID
                )

                HStack(spacing: 14) {
                    legendMark(symbol: "plus", colour: .orange, title: "Centre of mass")
                    legendMark(symbol: "circle.dashed", colour: .secondary, title: "Target")
                    Spacer(minLength: 0)
                }
                .font(.caption2)

                Text("Drawn to scale. The rear of the module is on the left; “across” is measured from the lower edge.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legendMark(symbol: String, colour: Color, title: String) -> some View {
        Label {
            Text(title).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(colour)
        }
    }

    private func balanceCard(_ solution: PackingSolution, result: PackingResult) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Balance")
                    .font(.headline)

                ForEach(0..<3, id: \.self) { axis in
                    balanceRow(axis: axis, solution: solution)
                }

                Divider()

                LabeledContent {
                    Text(String(format: "%.2f mm", solution.weightedDeviation))
                        .monospacedDigit()
                } label: {
                    Text("Weighted deviation")
                    Text("w·|c − c*| summed over the three axes — the value the optimiser minimises")
                        .font(.caption2)
                }
                .font(.subheadline)

                if let gap = result.diagnostics.absoluteGap, gap > 1e-6, let bound = result.diagnostics.dualBound {
                    Text(
                        String(
                            format: "Not proven optimal: the best possible value is at least %.2f mm, so this arrangement is within %.2f mm of the true optimum.",
                            bound,
                            gap
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func balanceRow(axis: Int, solution: PackingSolution) -> some View {
        let names = ["Along the module (x)", "Across the module (y)", "Height (z)"]
        let value = solution.centreOfMass[axis]
        let target = solution.module.targetCentreOfMass[axis]
        let deviation = value - target
        let weight = solution.module.axisWeights[axis]
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(names[axis])
                    .font(.subheadline)
                Spacer(minLength: 8)
                Text(String(format: "%+.1f mm", value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            HStack(spacing: 8) {
                Text(String(format: "target %+.0f mm · off by %+.1f mm", target, deviation))
                Spacer(minLength: 4)
                Text(weight > 0 ? String(format: "weight %.2g", weight) : "not weighted")
            }
            .font(.caption2)
            .foregroundStyle(abs(deviation) < 0.5 ? Color.secondary : Color.orange)
        }
    }

    private func placementCard(_ solution: PackingSolution) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Placement")
                    .font(.headline)
                Text("Load from the rear of the module forwards. Distances are to the nearest corner of each package.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(orderedPackages(solution).enumerated()), id: \.element.id) { index, package in
                    placementRow(index: index + 1, package: package, solution: solution)
                }
            }
        }
    }

    private func orderedPackages(_ solution: PackingSolution) -> [PlacedPackage] {
        solution.packages.sorted { $0.centre.x < $1.centre.x }
    }

    private func placementRow(index: Int, package: PlacedPackage, solution: PackingSolution) -> some View {
        let alongWall = package.minimumX + solution.module.lengthMillimetres / 2
        let acrossWall = package.minimumY + solution.module.widthMillimetres / 2
        let isHighlighted = highlightedPackageID == package.id

        return Button {
            highlightedPackageID = isHighlighted ? nil : package.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill((colourMap[package.id] ?? .accentColor).opacity(0.3))
                    Text("\(index)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(package.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(
                        String(
                            format: "%.0f mm from the rear wall · %.0f mm from the lower wall",
                            alongWall,
                            acrossWall
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(
                        String(
                            format: "%@ · footprint %.0f × %.0f mm, %.0f mm tall · %.2f kg",
                            package.orientation.summary,
                            package.footprint.x,
                            package.footprint.y,
                            package.height,
                            package.massKilograms
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                (isHighlighted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)),
                in: .rect(cornerRadius: 12)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Highlights this package in the drawing.")
    }

    private func loadCard(_ solution: PackingSolution) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Load")
                    .font(.headline)
                summaryRow("Packages", "\(solution.packages.count)")
                summaryRow("Payload mass", String(format: "%.2f kg", solution.totalPayloadMass))
                if solution.module.fixedMassKilograms > 0 {
                    summaryRow("System mass", String(format: "%.2f kg", solution.totalSystemMass))
                }
                summaryRow("Floor used", String(format: "%.0f%%", solution.floorUtilisation * 100))
                summaryRow(
                    "Tallest package",
                    String(format: "%.0f of %.0f mm", solution.tallestPackageHeight, solution.module.heightMillimetres)
                )
                if let box = solution.boundingBox {
                    summaryRow("Occupied area", String(format: "%.0f × %.0f mm", box.length, box.width))
                }
            }
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.monospacedDigit())
        }
    }

    private func verificationCard(_ verification: PackingVerification) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    verification.isValid ? "Geometry verified" : "Verification failed",
                    systemImage: verification.isValid ? "checkmark.seal.fill" : "xmark.seal.fill"
                )
                .font(.headline)
                .foregroundStyle(verification.isValid ? .green : .red)

                Text(
                    verification.isValid
                        ? String(
                            format: "Every package is inside the module, no two overlap, all clearances hold, and the centre of mass recomputes to within %.1e mm.",
                            max(verification.centreOfMassError, 1e-12)
                        )
                        : "The reported arrangement did not pass the independent geometric check, so it must not be used."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                ForEach(verification.violations, id: \.self) { violation in
                    Text("• \(violation)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func diagnosticsCard(_ result: PackingResult) -> some View {
        card {
            DisclosureGroup(isExpanded: $showsDiagnostics) {
                VStack(alignment: .leading, spacing: 8) {
                    let diagnostics = result.diagnostics
                    summaryRow("Variables", "\(diagnostics.variableCount) (\(diagnostics.integerVariableCount) binary)")
                    summaryRow("Rows", "\(diagnostics.rowCount)")
                    summaryRow("Non-zeros", "\(diagnostics.nonZeroCount)")
                    summaryRow("Valid inequalities", "\(diagnostics.cuts.total)")
                    summaryRow("Total time", String(format: "%.2f s", diagnostics.totalRuntimeSeconds))

                    if diagnostics.strengtheningWasTruncated {
                        Text("The strengthening row budget was reached, so not every valid inequality was added. The model is still exact, only less tightly described.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()

                    ForEach(diagnostics.phases) { phase in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(phase.name)
                                .font(.subheadline.weight(.semibold))
                            Text(
                                String(
                                    format: "%@ · %d nodes · %d simplex iterations · %.2f s",
                                    phase.status,
                                    phase.nodeCount,
                                    phase.simplexIterationCount,
                                    phase.runtimeSeconds
                                )
                            )
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        }
                    }

                    if let secondary = result.secondaryObjective {
                        Divider()
                        summaryRow(
                            "Occupied extent",
                            String(format: "%.0f mm%@", secondary.compactness, secondary.provenOptimal ? "" : " (not proven)")
                        )
                    }

                    Text(diagnostics.solverDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 8)
            } label: {
                Text("Model and solver")
                    .font(.headline)
            }
        }
    }

    private var scopeCard: some View {
        card {
            VStack(alignment: .leading, spacing: 6) {
                Text("Outside the model")
                    .font(.headline)
                ForEach(
                    [
                        "Stacking. Every package rests on the module floor; nothing is placed on top of anything else.",
                        "Load-bearing strength and tie-down forces during flight.",
                        "A second payload module and the choice of connection between modules.",
                        "Anything not measured: a package's internal mass distribution is assumed to be centred unless an offset was entered.",
                    ],
                    id: \.self
                ) { line in
                    Text("• \(line)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Helpers

    private var colourMap: [UUID: Color] {
        var map: [UUID: Color] = [:]
        for package in packages {
            map[package.id] = store.colour(for: package.id, in: captureEngine)
        }
        return map
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }

    private func statusSymbol(_ result: PackingResult) -> String {
        switch result.status {
        case .optimal: "checkmark.circle.fill"
        case .feasible: "clock.badge.checkmark"
        case .infeasible: "xmark.octagon.fill"
        case .noSolutionFound: "hourglass"
        case .invalidInput: "exclamationmark.triangle.fill"
        }
    }

    private func statusColour(_ result: PackingResult) -> Color {
        switch result.status {
        case .optimal: .green
        case .feasible: .orange
        case .infeasible, .invalidInput: .red
        case .noSolutionFound: .orange
        }
    }

    private func statusTitle(_ result: PackingResult) -> String {
        switch result.status {
        case .optimal: "Best possible arrangement"
        case .feasible: "Arrangement found"
        case .infeasible: "This load does not fit"
        case .noSolutionFound: "No arrangement found in time"
        case .invalidInput: "Cannot arrange this load yet"
        }
    }

    private func statusDetail(_ result: PackingResult) -> String {
        switch result.status {
        case .optimal:
            return "Proven optimal: no other arrangement of these packages balances the load better."
        case .feasible:
            if let gap = result.diagnostics.relativeGap, gap > 0 {
                return String(
                    format: "The time limit was reached before optimality could be proven. This arrangement is within %.1f%% of the best possible.",
                    gap * 100
                )
            }
            return "The time limit was reached before optimality could be proven."
        case .infeasible, .noSolutionFound:
            return result.infeasibility?.detail ?? "No arrangement satisfies the constraints."
        case .invalidInput:
            return "Fix the problems below, then optimise again."
        }
    }
}
