import SwiftUI
import simd

/// Everything the arrangement depends on that is not measured: the module, the balance target and
/// the solver's limits. The defaults describe this project's 20 × 80 × 10 cm payload module.
struct PackingSettingsView: View {
    @Bindable var store: PackingStore
    var packages: [PackingItem] = []
    var baldiItems: [BaldiItem] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                moduleSection
                if store.approach == .knapsack3D {
                    knapsackDomainSection
                    knapsackProfitSection
                    knapsackSolverSection
                } else {
                    clearanceSection
                    balanceSection
                    envelopeSection
                    packageSection
                    massSection
                    solverSection
                }
                resetSection
            }
            .navigationTitle("Arrangement settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    private var moduleSection: some View {
        Section {
            measurement("Length (x)", value: $store.module.lengthMillimetres, range: 50...5000)
            measurement("Width (y)", value: $store.module.widthMillimetres, range: 50...5000)
            measurement("Height (z)", value: $store.module.heightMillimetres, range: 10...2000)
        } header: {
            Text("Payload module")
        } footer: {
            Text("Usable interior of one module. The origin is the centre of its floor: x runs along the module, y across it, z upwards.")
        }
    }

    private var clearanceSection: some View {
        Section {
            measurement("Wall clearance", value: $store.module.minimumWallClearance, range: 0...200, step: 1)
            measurement("Package clearance", value: $store.defaultPackageClearance, range: 0...200, step: 1)
        } header: {
            Text("Clearances")
        } footer: {
            Text("Package clearance is kept between neighbours and, where it is larger, to the walls as well. Both are the paper's item spacing requirement s.")
        }
    }

    private var balanceSection: some View {
        Section {
            offsetField("Target along (x)", value: $store.module.targetCentreOfMass.x)
            offsetField("Target across (y)", value: $store.module.targetCentreOfMass.y)
            offsetField("Target height (z)", value: $store.module.targetCentreOfMass.z, allowsNegative: false)

            weightSlider("Weight along (wx)", value: $store.module.axisWeights.x)
            weightSlider("Weight across (wy)", value: $store.module.axisWeights.y)
            weightSlider("Weight height (wz)", value: $store.module.axisWeights.z)
        } header: {
            Text("Balance target")
        } footer: {
            Text("The optimiser minimises wx·|cx − cx*| + wy·|cy − cy*| + wz·|cz − cz*|. A target height of zero simply asks for the load's centre of mass to sit as low as it can.")
        }
    }

    private var envelopeSection: some View {
        Section {
            Toggle("Restrict the centre of mass", isOn: $store.restrictsCentreOfMass)
            if store.restrictsCentreOfMass {
                measurement("Tolerance along", value: $store.centreOfMassTolerance.x, range: 0...500, step: 1)
                measurement("Tolerance across", value: $store.centreOfMassTolerance.y, range: 0...500, step: 1)
                measurement("Tolerance height", value: $store.centreOfMassTolerance.z, range: 0...500, step: 1)
            }
        } header: {
            Text("Allowable envelope")
        } footer: {
            Text("A hard limit rather than a preference: an arrangement whose centre of mass falls outside the tolerance is reported as infeasible instead of merely penalised.")
        }
    }

    @ViewBuilder
    private var packageSection: some View {
        if !packages.isEmpty {
            Section {
                ForEach(packages) { package in
                    Toggle(isOn: uprightBinding(for: package.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(package.name)
                            Text(
                                String(
                                    format: "%.0f × %.0f × %.0f mm · %.2f kg",
                                    package.size.x, package.size.y, package.size.z, package.massKilograms
                                )
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Keep upright")
            } footer: {
                Text("A package left off may be turned onto any face, which is often the only way a tall item fits under the module height. Switch it on for anything that must not be tipped.")
            }
        }
    }

    private func uprightBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { store.uprightPackageIDs.contains(id) },
            set: { isOn in
                if isOn { store.uprightPackageIDs.insert(id) } else { store.uprightPackageIDs.remove(id) }
            }
        )
    }

    private var massSection: some View {
        Section {
            Toggle("Limit the payload mass", isOn: $store.limitsPayloadMass)
            if store.limitsPayloadMass {
                massField("Maximum payload", value: $store.maximumPayloadMass)
            }
            massField("Empty module mass", value: $store.module.emptyMassKilograms)
            if store.module.emptyMassKilograms > 0 {
                offsetField("Its centre along (x)", value: $store.module.emptyCentreOfMass.x)
                offsetField("Its centre across (y)", value: $store.module.emptyCentreOfMass.y)
                offsetField("Its centre height (z)", value: $store.module.emptyCentreOfMass.z)
            }
            massField("Airframe mass", value: $store.module.airframeMassKilograms)
            if store.module.airframeMassKilograms > 0 {
                offsetField("Airframe centre along (x)", value: $store.module.airframeCentreOfMass.x)
                offsetField("Airframe centre across (y)", value: $store.module.airframeCentreOfMass.y)
                offsetField("Airframe centre height (z)", value: $store.module.airframeCentreOfMass.z)
            }
        } header: {
            Text("Masses")
        } footer: {
            Text("Entering the empty module and airframe masses makes the reported centre of mass that of the complete aircraft rather than of the cargo alone. Leave them at zero to balance the cargo by itself.")
        }
    }

    private var solverSection: some View {
        Section {
            Toggle("Pack the load together", isOn: $store.options.minimisesFootprintAfterBalance)
            timeField("Balance time limit", value: $store.options.balanceTimeLimitSeconds)
            if store.options.minimisesFootprintAfterBalance {
                timeField("Packing time limit", value: $store.options.compactnessTimeLimitSeconds)
            }
            Toggle("Valid inequalities", isOn: $store.options.strengthening.usesFittingCuts)
            Toggle("Transitivity cuts", isOn: $store.options.strengthening.usesTransitivity)
        } header: {
            Text("Solver")
        } footer: {
            Text("Packing the load together is a second, lower-priority objective: it only runs once the balance objective has been proven optimal, and it is not allowed to make the balance worse. The cut families remove provably impossible or duplicate arrangements without changing the optimum — switching them off is slower but must give the same answer.")
        }
    }

    // MARK: - 3BKP sections

    private var knapsackDomainSection: some View {
        Section {
            Toggle("Use the paper's domain", isOn: $store.usesStandardDomain)
            if !store.usesStandardDomain {
                offsetField("L¹ along", value: $store.domainLower.x, allowsNegative: false)
                offsetField("U¹ along", value: $store.domainUpper.x, allowsNegative: false)
                offsetField("L² across", value: $store.domainLower.y, allowsNegative: false)
                offsetField("U² across", value: $store.domainUpper.y, allowsNegative: false)
                offsetField("L³ height", value: $store.domainLower.z, allowsNegative: false)
                offsetField("U³ height", value: $store.domainUpper.z, allowsNegative: false)
            } else {
                LabeledContent("L^δ", value: describe(store.centreOfMassDomainLower(for: knapsackSize)))
                LabeledContent("U^δ", value: describe(store.centreOfMassDomainUpper(for: knapsackSize)))
            }
        } header: {
            Text("Centre-of-mass domain")
        } footer: {
            Text("The 3BKP treats balance as a hard constraint: the packing centre of mass must lie inside [L¹,U¹]×[L²,U²]×[L³,U³]. The paper's own instances use L = (W/4, D/4, 0) and U = (3W/4, 3D/4, H/2), the upper vertical bound being the practical requirement that the centre of mass sit low in the bin.")
        }
    }

    private var knapsackSize: SIMD3<Int> {
        SIMD3(
            Int(store.module.lengthMillimetres.rounded(.down)),
            Int(store.module.widthMillimetres.rounded(.down)),
            Int(store.module.heightMillimetres.rounded(.down))
        )
    }

    private func describe(_ vector: SIMD3<Double>) -> String {
        String(format: "%.0f, %.0f, %.0f mm", vector.x, vector.y, vector.z)
    }

    @ViewBuilder
    private var knapsackProfitSection: some View {
        if !baldiItems.isEmpty {
            Section {
                ForEach(baldiItems) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name).font(.subheadline)
                        HStack(spacing: 6) {
                            Text(
                                String(
                                    format: "%d × %d × %d mm · %.2f kg",
                                    item.size.x, item.size.y, item.size.z, item.mass
                                )
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            TextField(
                                "Profit",
                                value: profitBinding(for: item),
                                format: .number.precision(.fractionLength(0))
                            )
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 110)
                        }
                    }
                }
            } header: {
                Text("Profit p_j")
            } footer: {
                Text("The knapsack maximises the total profit of the loaded packages, so profit is what decides which package is left behind when the module is full. The default is the paper's own instance rule, p_j = 200 + w·d·h. Raise a value to force a package in.")
            }
        }
    }

    private func profitBinding(for item: BaldiItem) -> Binding<Double> {
        Binding(
            get: {
                store.profitOverrides[item.id]
                    ?? PackingStore.defaultProfit(forVolume: max(item.volume, 1))
            },
            set: { store.profitOverrides[item.id] = $0 }
        )
    }

    private var knapsackSolverSection: some View {
        Section {
            Picker("Method", selection: $store.baldiOptions.method) {
                ForEach(BaldiMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            if store.baldiOptions.method == .heuristic {
                timeField("3BKP-H time limit", value: $store.baldiOptions.heuristic.timeLimitSeconds)
                LabeledContent("Merit weight α") {
                    HStack(spacing: 6) {
                        Text(String(format: "%.0f", store.baldiOptions.heuristic.meritAlpha))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper(
                            "Merit weight",
                            value: $store.baldiOptions.heuristic.meritAlpha,
                            in: 0...100_000,
                            step: 1000
                        )
                        .labelsHidden()
                    }
                }
                LabeledContent("Cluster width θ") {
                    HStack(spacing: 6) {
                        Text(String(format: "%.0f%%", store.baldiOptions.heuristic.clusterTheta))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Stepper(
                            "Cluster width",
                            value: $store.baldiOptions.heuristic.clusterTheta,
                            in: 1...100,
                            step: 5
                        )
                        .labelsHidden()
                    }
                }
            } else {
                timeField("3BKP-M time limit", value: $store.baldiOptions.modelTimeLimitSeconds)
                Toggle("Equation (16) exactly as printed", isOn: $store.baldiOptions.usesPrintedRotationEquality)
            }
        } header: {
            Text("Method")
        } footer: {
            Text("3BKP-H is the paper's heuristic and stops after its time limit with no optimality proof; α is the weight of the unbalancing index in the merit function F = P − αU, which the paper defines but never gives a value for, and θ is the cluster width of equations (22)–(23), likewise unspecified. 3BKP-M is the exact model, which the paper reports cannot handle more than about twenty items — on a phone the practical limit is far lower. Equation (16) as printed makes any packing that leaves an item out infeasible; the switch is there so that can be seen.")
        }
    }

    private var resetSection: some View {
        Section {
            Button("Restore defaults", role: .destructive) {
                store.module = .standard
                store.options = PackingOptions()
                store.defaultPackageClearance = 5
                store.restrictsCentreOfMass = false
                store.centreOfMassTolerance = SIMD3(20, 10, 50)
                store.limitsPayloadMass = false
                store.maximumPayloadMass = 5
                store.baldiOptions = Baldi3BKPOptions()
                store.usesStandardDomain = true
                store.profitOverrides = [:]
            }
        }
    }

    // MARK: - Fields

    private func measurement(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 5
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(
                    title,
                    value: value,
                    format: .number.precision(.fractionLength(0...1))
                )
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 84)
                .onChange(of: value.wrappedValue) { _, new in
                    value.wrappedValue = min(max(new, range.lowerBound), range.upperBound)
                }
                Text("mm").foregroundStyle(.secondary)
                Stepper(title, value: value, in: range, step: step)
                    .labelsHidden()
            }
        }
    }

    private func offsetField(_ title: String, value: Binding<Double>, allowsNegative: Bool = true) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(
                    title,
                    value: value,
                    format: .number.precision(.fractionLength(0...1))
                )
                .keyboardType(allowsNegative ? .numbersAndPunctuation : .decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 84)
                Text("mm").foregroundStyle(.secondary)
            }
        }
    }

    private func massField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number.precision(.fractionLength(0...3)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 84)
                    .onChange(of: value.wrappedValue) { _, new in
                        if new < 0 { value.wrappedValue = 0 }
                    }
                Text("kg").foregroundStyle(.secondary)
            }
        }
    }

    private func timeField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                Text(String(format: "%.0f s", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper(title, value: value, in: 1...60, step: 1)
                    .labelsHidden()
            }
        }
    }

    private func weightSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...2, step: 0.05)
        }
    }
}
