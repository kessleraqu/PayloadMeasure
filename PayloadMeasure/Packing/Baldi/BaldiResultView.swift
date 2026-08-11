import SwiftUI
import simd

/// The 3BKP result screen: which packages were loaded, where each one goes in three dimensions,
/// and where the packing centre of mass ended up relative to its allowable domain.
struct BaldiResultView: View {
    let result: Baldi3BKPResult
    let colours: [UUID: Color]
    @Binding var highlightedPackageID: UUID?

    @State private var showsDiagnostics = false

    var body: some View {
        statusCard
        if let solution = result.solution, !solution.placements.isEmpty {
            drawingCard(solution)
            loadCard(solution)
            balanceCard(solution)
            placementCard(solution)
            if !solution.unloaded.isEmpty {
                unloadedCard(solution)
            }
        }
        if let verification = result.verification {
            verificationCard(verification)
        }
        diagnosticsCard
        scopeCard
    }

    // MARK: - Cards

    private var statusCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: statusSymbol)
                        .font(.title2)
                        .foregroundStyle(statusColour)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.headline)
                        Text(statusDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                ForEach(result.errors, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func drawingCard(_ solution: BaldiSolution) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                BaldiPlanView(
                    solution: solution,
                    colours: colours,
                    highlightedPackageID: highlightedPackageID
                )
                HStack(spacing: 14) {
                    legend(symbol: "plus", colour: solution.isBalanced ? .orange : .red, title: "Centre of mass")
                    legend(symbol: "rectangle.dashed", colour: .green, title: "Allowable domain")
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                Text("Drawn to scale, origin at the bottom-left-back corner. A dashed outline marks a package resting on top of another.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func legend(symbol: String, colour: Color, title: String) -> some View {
        Label {
            Text(title).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(colour)
        }
    }

    private func loadCard(_ solution: BaldiSolution) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Load")
                    .font(.headline)
                row("Packages loaded", "\(solution.loadedCount) of \(solution.loadedCount + solution.unloaded.count)")
                row("Total profit P", String(format: "%.0f", solution.profit))
                if let bound = result.upperBound {
                    row("Upper bound UB₁D", String(format: "%.0f", bound))
                }
                if let gap = result.gapToUpperBound {
                    row("Gap to UB₁D", String(format: "%.1f%%", gap))
                }
                row("Mass loaded", String(format: "%.2f kg", solution.totalMass))
                row("Volume used", String(format: "%.1f%%", solution.fillRatio * 100))
            }
        }
    }

    private func balanceCard(_ solution: BaldiSolution) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Balance")
                        .font(.headline)
                    Spacer()
                    Label(
                        solution.isBalanced ? "Inside the domain" : "Outside the domain",
                        systemImage: solution.isBalanced ? "checkmark.circle.fill" : "xmark.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(solution.isBalanced ? Color.green : Color.red)
                }

                let names = ["x — along", "y — across", "z — height"]
                ForEach(0..<3, id: \.self) { axis in
                    let value = solution.centreOfMass[axis]
                    let low = solution.knapsack.domainLower[axis]
                    let high = solution.knapsack.domainUpper[axis]
                    let inside = value >= low - 1e-6 && value <= high + 1e-6
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(names[axis]).font(.subheadline)
                            Spacer(minLength: 8)
                            Text(String(format: "%.1f mm", value))
                                .font(.subheadline.monospacedDigit())
                        }
                        Text(String(format: "allowed %.0f … %.0f mm", low, high))
                            .font(.caption2)
                            .foregroundStyle(inside ? Color.secondary : Color.red)
                    }
                }

                Divider()
                LabeledContent {
                    Text(String(format: "%.1f mm", solution.unbalancingIndex))
                        .monospacedDigit()
                } label: {
                    Text("Unbalancing index U")
                    Text("eq. (4): the spread of the loaded items' own centres of mass about the ideal point")
                        .font(.caption2)
                }
                .font(.subheadline)
            }
        }
    }

    private func placementCard(_ solution: BaldiSolution) -> some View {
        let ordered = solution.placements.sorted {
            $0.origin.z == $1.origin.z ? $0.origin.x < $1.origin.x : $0.origin.z < $1.origin.z
        }
        return card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Placement")
                    .font(.headline)
                Text("Coordinates are to each package's bottom-left-back corner, measured from the same corner of the module. Load in this order, lowest first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, placement in
                    placementRow(index: index + 1, placement: placement)
                }
            }
        }
    }

    private func placementRow(index: Int, placement: BaldiPlacement) -> some View {
        let isHighlighted = highlightedPackageID == placement.id
        let isStacked = placement.origin.z > 1e-6
        return Button {
            highlightedPackageID = isHighlighted ? nil : placement.id
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill((colours[placement.id] ?? .accentColor).opacity(0.3))
                    Text("\(index)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(placement.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if isStacked {
                            Text(String(format: "on top, %.0f mm up", placement.origin.z))
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18), in: .capsule)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(
                        String(
                            format: "x %.0f · y %.0f · z %.0f mm",
                            placement.origin.x, placement.origin.y, placement.origin.z
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(
                        String(
                            format: "%@ · %d × %d × %d mm · %.2f kg",
                            placement.rotation.restingDescription,
                            placement.size.x, placement.size.y, placement.size.z,
                            placement.mass
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(
                isHighlighted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                in: .rect(cornerRadius: 12)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func unloadedCard(_ solution: BaldiSolution) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Left out", systemImage: "tray.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("The 3BKP loads the most valuable subset that fits and balances, so these were not loaded. Raise a package's profit in the settings to force it in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(solution.unloaded) { item in
                    HStack {
                        Text(item.name).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(String(format: "%d × %d × %d mm · %.0f", item.size.x, item.size.y, item.size.z, item.profit))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !result.oversizedItems.isEmpty {
                    Text("\(result.oversizedItems.count) of these do not fit the module in any rotation.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func verificationCard(_ verification: BaldiVerification) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    verification.isValid ? "Geometry verified" : "Verification failed",
                    systemImage: verification.isValid ? "checkmark.seal.fill" : "xmark.seal.fill"
                )
                .font(.headline)
                .foregroundStyle(verification.isValid ? Color.green : Color.red)
                Text(
                    verification.isValid
                        ? "Every package is inside the module, no two overlap, and the packing centre of mass recomputes to the reported value inside its domain."
                        : "The reported packing did not pass the independent geometric check, so it must not be used."
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

    private var diagnosticsCard: some View {
        card {
            DisclosureGroup(isExpanded: $showsDiagnostics) {
                VStack(alignment: .leading, spacing: 8) {
                    row("Method", result.method.title)
                    row("Runtime", String(format: "%.2f s", result.runtimeSeconds))
                    if let detail = result.heuristicDetail {
                        row("Iterations", "\(detail.iterations)")
                        row("Improvements", "\(detail.improvements)")
                        row("Score reinitialisations", "\(detail.reinitialisations)")
                        row("Best initial criterion", detail.initialCriterion.rawValue)
                        row("PCH initial profit", String(format: "%.0f", detail.initialSolution.profit))
                    }
                    if let statistics = result.modelStatistics {
                        row("Variables", "\(statistics.variableCount) (\(statistics.integerVariableCount) binary)")
                        row("Rows", "\(statistics.rowCount)")
                        row("Nodes", "\(result.modelNodeCount ?? 0)")
                        if let dual = result.dualBound {
                            row("Dual bound", String(format: "%.0f", dual))
                        }
                    }
                    Text("Equation (16) is solved in its repaired form, Σ_r ρ_ir = t_i. As printed, Σ_r ρ_ir = 1 makes every packing that leaves an item out infeasible.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)
            } label: {
                Text("Method and diagnostics").font(.headline)
            }
        }
    }

    private var scopeCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Text("Outside the model")
                    .font(.headline)
                Text("Paper §2: balancing conditions are not stability conditions. The 3BKP constrains where the centre of mass ends up; it says nothing about whether a stacked package is safely carried.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(scopeLines, id: \.self) { line in
                    Text("• \(line)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What the formulation leaves out. The two methods differ on one point that matters
    /// physically, so the text is not the same for both.
    private var scopeLines: [String] {
        var lines: [String] = []
        switch result.method {
        case .heuristic:
            lines.append("No supporting-surface requirement. §5.2's gravity step settles every package down onto whatever is beneath it, so nothing floats — but a package may come to rest on a small part of its base. Check the elevation before trusting a stacked package.")
        case .model:
            lines.append("No support constraint of any kind. Constraints (5)–(20) contain nothing that requires a package to rest on anything, and the exact model does place packages in mid-air. Only the 3BKP-H heuristic applies the gravity step of §5.2.")
        }
        lines.append("No limit on the number of supporting items, and no load-bearing or fragility limit along the vertical axis. The paper names all three as stability conditions it does not model.")
        lines.append("No clearances. The 3BKP has no item spacing; packages may touch, and the module walls are assumed to have negligible thickness.")
        lines.append("No tie-down or flight loads.")
        lines.append("Every package's centre of mass is taken to be its geometric centre, as in the paper's instances.")
        return lines
    }

    // MARK: - Helpers

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.subheadline.monospacedDigit())
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
    }

    private var statusSymbol: String {
        switch result.status {
        case .optimal: "checkmark.circle.fill"
        case .feasible: "shippingbox.fill"
        case .empty: "tray"
        case .invalidInput: "exclamationmark.triangle.fill"
        case .modelTooLarge: "exclamationmark.triangle.fill"
        }
    }

    private var statusColour: Color {
        switch result.status {
        case .optimal: .green
        case .feasible: .blue
        case .empty: .orange
        case .invalidInput, .modelTooLarge: .red
        }
    }

    private var statusTitle: String {
        switch result.status {
        case .optimal: "Best possible load"
        case .feasible: result.method == .model ? "Load found" : "Load found"
        case .empty: "Nothing could be loaded"
        case .invalidInput: "Cannot arrange this load yet"
        case .modelTooLarge: "Too large for the exact model"
        }
    }

    private var statusDetail: String {
        switch result.status {
        case .optimal:
            return "Proven optimal: no other subset of these packages has a higher total profit while fitting and staying balanced."
        case .feasible:
            if result.method == .heuristic {
                let gap = result.gapToUpperBound.map { String(format: " It is within %.1f%% of the UB₁D upper bound.", $0) } ?? ""
                return "3BKP-H ran for its time limit and returned the best load it found.\(gap) The heuristic gives no optimality proof."
            }
            return "The time limit was reached before optimality could be proven."
        case .empty:
            return "No package could be placed while keeping the centre of mass inside its allowable domain."
        case .invalidInput:
            return "Fix the problems below, then optimise again."
        case .modelTooLarge:
            return "Switch to the 3BKP-H heuristic in the settings."
        }
    }
}
