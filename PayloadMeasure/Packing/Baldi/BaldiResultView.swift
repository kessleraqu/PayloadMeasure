import SwiftUI

/// Result screen for the support-aware Baldi–Junqueira heuristic.
struct BaldiResultView: View {
    let result: Baldi3BKPResult
    let colours: [UUID: Color]
    @Binding var highlightedPackageID: UUID?

    @State private var showsDiagnostics = false

    var body: some View {
        statusCard

        if result.status == .feasible,
           let solution = result.solution,
           let verification = result.verification,
           verification.isValid {
            drawingCard(solution)
            loadCard(solution)
            balanceCard(solution)
            supportCard(solution, verification: verification)
            placementCard(solution)
            if !solution.unloaded.isEmpty { unloadedCard(solution) }
        }

        if let verification = result.verification {
            verificationCard(verification)
        }
        diagnosticsCard
        scopeCard
    }

    // MARK: - Result summary

    private var statusCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: statusSymbol)
                        .font(.title2)
                        .foregroundStyle(statusColour)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle).font(.headline)
                        Text(statusDetail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                if result.status == .invalidInput
                    || (result.status == .verificationFailed && result.verification == nil) {
                    ForEach(result.errors, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
                    legend(symbol: "plus", colour: .orange, title: "Centre of mass")
                    legend(symbol: "rectangle.dashed", colour: .green, title: "Allowable domain")
                    Spacer(minLength: 0)
                }
                .font(.caption2)
                Text("Drawn to scale from the bottom-left-back origin. Dashed packages are above the floor and have their complete bottom face supported.")
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
                Text("Load").font(.headline)
                row("Packages loaded", "\(solution.loadedCount) of \(solution.loadedCount + solution.unloaded.count)")
                row("Mass loaded", String(format: "%.2f kg", solution.totalMass))
                row("Volume used", String(format: "%.1f%%", solution.fillRatio * 100))
            }
        }
    }

    private func balanceCard(_ solution: BaldiSolution) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Cargo balance").font(.headline)
                    Spacer()
                    Label("Inside the domain", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }

                let names = ["x — along", "y — across", "z — height"]
                ForEach(0..<3, id: \.self) { axis in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(names[axis]).font(.subheadline)
                            Spacer(minLength: 8)
                            Text(String(format: "%.1f mm", solution.centreOfMass[axis]))
                                .font(.subheadline.monospacedDigit())
                        }
                        Text(
                            String(
                                format: "allowed %.0f … %.0f mm",
                                solution.knapsack.domainLower[axis],
                                solution.knapsack.domainUpper[axis]
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func supportCard(_ solution: BaldiSolution, verification: BaldiVerification) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Vertical support").font(.headline)
                    Spacer()
                    Label("100% verified", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
                Text("Every non-floor package is covered across its complete bottom face by top faces in direct contact below it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(solution.placements.sorted(by: placementOrder)) { placement in
                    let report = verification.supportReports.first { $0.packageID == placement.id }
                    HStack {
                        Text(placement.name).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(supportDescription(report))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Placement

    private func placementCard(_ solution: BaldiSolution) -> some View {
        let ordered = solution.placements.sorted(by: placementOrder)
        return card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Placement").font(.headline)
                Text("Coordinates are to each package's bottom-left-back corner. Load in this order, lowest first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(ordered.enumerated()), id: \.element.id) { index, placement in
                    placementRow(index: index + 1, placement: placement, solution: solution)
                }
            }
        }
    }

    private func placementRow(
        index: Int,
        placement: BaldiPlacement,
        solution: BaldiSolution
    ) -> some View {
        let isHighlighted = highlightedPackageID == placement.id
        let support = BaldiVerticalSupport.report(for: placement, among: solution.placements)
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
                        if !support.isFloorSupported {
                            Text("100% supported")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.16), in: .capsule)
                                .foregroundStyle(.green)
                        }
                    }
                    Text(
                        String(
                            format: "x %.0f · y %.0f · z %.0f mm",
                            placement.origin.x,
                            placement.origin.y,
                            placement.origin.z
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(
                        String(
                            format: "%@ · %d × %d × %d mm · %.2f kg",
                            placement.rotation.restingDescription,
                            placement.size.x,
                            placement.size.y,
                            placement.size.z,
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
                Label("Not included", systemImage: "tray.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("All packages have equal priority. These packages were not included in the highest-cardinality feasible arrangement found within the search time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(solution.unloaded) { item in
                    HStack {
                        Text(item.name).font(.subheadline)
                        Spacer(minLength: 8)
                        Text(String(format: "%d × %d × %d mm", item.size.x, item.size.y, item.size.z))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if !result.oversizedItems.isEmpty {
                    Text("\(result.oversizedItems.count) of these do not fit the container in any allowed rotation.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Verification and scope

    private func verificationCard(_ verification: BaldiVerification) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    verification.isValid ? "Feasibility independently verified" : "Verification failed",
                    systemImage: verification.isValid ? "checkmark.seal.fill" : "xmark.seal.fill"
                )
                .font(.headline)
                .foregroundStyle(verification.isValid ? Color.green : Color.red)
                Text(
                    verification.isValid
                        ? "The check independently reconstructed rotations, dimensions, containment, non-overlap, centred package COM, cargo balance and complete vertical support."
                        : "The heuristic output failed an independent check and is not presented as a usable arrangement."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(verification.violations, id: \.self) { violation in
                    Text("• \(violation)")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        card {
            DisclosureGroup(isExpanded: $showsDiagnostics) {
                VStack(alignment: .leading, spacing: 8) {
                    row("Method", "Support-aware 3BKP-H")
                    row("Runtime", String(format: "%.2f s", result.runtimeSeconds))
                    if let detail = result.heuristicDetail {
                        row("Iterations", "\(detail.iterations)")
                        row("Feasible improvements", "\(detail.improvements)")
                        row("Score reinitialisations", "\(detail.reinitialisations)")
                        row("Best initial criterion", detail.initialCriterion.rawValue)
                        row("Initial packages loaded", "\(detail.initialSolution.loadedCount)")
                    }
                    Text("Fixed choices: pᵢ = 1, centred package COM, merit coefficient 0 and Junqueira vertical support α = 1.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
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
                Text("Assumptions and limits").font(.headline)
                ForEach(scopeLines, id: \.self) { line in
                    Text("• \(line)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var scopeLines: [String] {
        [
            "Baldi supplies selection, rotation, Extreme Point placement and cargo-COM balancing; a continuous-coordinate evaluation of Junqueira equation (11) enforces complete vertical support.",
            "Packages are rigid and assumed strong enough to carry packages above them. Load-bearing pressure and fragility are not modelled.",
            "Mechanical restraint is assumed to prevent horizontal sliding. Friction, vibration, deformation and flight acceleration loads are outside the model.",
            "The method is a heuristic: it reports the best feasible load found within its search time, not a globally proven optimum.",
        ]
    }

    // MARK: - Helpers

    private func supportDescription(_ report: BaldiSupportReport?) -> String {
        guard let report else { return "not assessed" }
        if report.isFloorSupported { return "floor" }
        let noun = report.supporterIDs.count == 1 ? "supporter" : "supporters"
        return String(format: "%.0f%% · %d %@", report.fraction * 100, report.supporterIDs.count, noun)
    }

    private func placementOrder(_ first: BaldiPlacement, _ second: BaldiPlacement) -> Bool {
        if first.origin.z != second.origin.z { return first.origin.z < second.origin.z }
        if first.origin.x != second.origin.x { return first.origin.x < second.origin.x }
        if first.origin.y != second.origin.y { return first.origin.y < second.origin.y }
        return first.id.uuidString < second.id.uuidString
    }

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
        case .feasible: "checkmark.circle.fill"
        case .notFound: "magnifyingglass"
        case .invalidInput: "exclamationmark.triangle.fill"
        case .verificationFailed: "xmark.seal.fill"
        }
    }

    private var statusColour: Color {
        switch result.status {
        case .feasible: .green
        case .notFound: .orange
        case .invalidInput, .verificationFailed: .red
        }
    }

    private var statusTitle: String {
        switch result.status {
        case .feasible:
            guard let solution = result.solution else { return "Best feasible load found" }
            return solution.unloaded.isEmpty ? "All packages loaded" : "Best feasible load found"
        case .notFound:
            return noPackageFits ? "No package fits the container" : "No feasible load found in time"
        case .invalidInput: return "Cannot arrange this load yet"
        case .verificationFailed: return "Packing rejected by verification"
        }
    }

    private var statusDetail: String {
        switch result.status {
        case .feasible:
            guard let solution = result.solution else { return "The independently verified heuristic result is ready." }
            if solution.unloaded.isEmpty {
                return "All \(solution.loadedCount) packages fit in an independently verified supported and balanced arrangement."
            }
            return "The heuristic loaded \(solution.loadedCount) of \(solution.loadedCount + solution.unloaded.count) packages. This is the highest-cardinality feasible load it found within the search time; global optimality is not claimed."
        case .notFound:
            if noPackageFits {
                return "None of the measured packages fits inside the payload container in any of the six allowed rotations."
            }
            return "The heuristic did not find a supported and balanced arrangement before it stopped. This does not prove that none exists."
        case .invalidInput:
            return "Fix the input problems below, then run the search again."
        case .verificationFailed:
            return "The result failed an independent invariant check and must not be used."
        }
    }

    private var noPackageFits: Bool {
        result.status == .notFound
            && result.heuristicDetail == nil
            && !result.oversizedItems.isEmpty
    }
}
