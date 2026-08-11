import Foundation
import simd

// Runs the Balance arrangement and checks the answer.
//
// In:  a PackingProblem plus PackingOptions (time limits, which cut families to use).
// Out: a PackingResult — the placements, the achieved centre of mass and its deviation, whether
//      optimality was proven, and an independent geometry check. Balance first, then a second pass
//      that squeezes the load together without giving any balance back.

nonisolated struct PlacedPackage: Sendable, Identifiable {
    var id: UUID
    var name: String
    var itemIndex: Int
    var orientation: OrthogonalOrientation
    var footprint: SIMD2<Double>
    var height: Double
    var centre: SIMD3<Double>
    var massCentre: SIMD3<Double>
    var massKilograms: Double
    var wallClearance: Double
    var neighbourClearance: Double

    var minimumX: Double { centre.x - footprint.x / 2 }
    var maximumX: Double { centre.x + footprint.x / 2 }
    var minimumY: Double { centre.y - footprint.y / 2 }
    var maximumY: Double { centre.y + footprint.y / 2 }
    var floorArea: Double { footprint.x * footprint.y }
}

nonisolated struct PackingBoundingBox: Sendable {
    var minimumX: Double
    var maximumX: Double
    var minimumY: Double
    var maximumY: Double

    var length: Double { maximumX - minimumX }
    var width: Double { maximumY - minimumY }
    var compactness: Double { length + width }
}

nonisolated struct PackingSolution: Sendable {
    var module: PayloadModule
    var packages: [PlacedPackage]
    var centreOfMass: SIMD3<Double>
    var deviation: SIMD3<Double>
    var weightedDeviation: Double
    var boundingBox: PackingBoundingBox?
    var totalPayloadMass: Double
    var totalSystemMass: Double

    var occupiedFloorArea: Double { packages.reduce(0) { $0 + $1.floorArea } }
    var floorUtilisation: Double {
        module.floorArea > 0 ? occupiedFloorArea / module.floorArea : 0
    }
    var tallestPackageHeight: Double { packages.map(\.height).max() ?? 0 }

    var recomputedCentreOfMass: SIMD3<Double> {
        var moment = module.fixedMassMoment
        for package in packages {
            moment += package.massKilograms * package.massCentre
        }
        return totalSystemMass > 0 ? moment / totalSystemMass : .zero
    }
}

nonisolated enum PackingSolutionReader {
    static func read(_ model: PackingModel, values: [Double]) -> PackingSolution {
        let problem = model.problem
        var packages: [PlacedPackage] = []

        for (index, prepared) in problem.items.enumerated() {
            let variables = model.orientationVariables[index]
            var chosen = 0
            if !variables.isEmpty {
                var best = -Double.infinity
                for (position, variable) in variables.enumerated() where values[variable] > best {
                    best = values[variable]
                    chosen = position
                }
            }
            let orientation = prepared.orientations[chosen]
            let centre = SIMD3(
                values[model.xVariables[index]],
                values[model.yVariables[index]],
                orientation.halfExtents.z
            )
            packages.append(
                PlacedPackage(
                    id: prepared.item.id,
                    name: prepared.item.name,
                    itemIndex: index,
                    orientation: orientation.orientation,
                    footprint: SIMD2(orientation.footprintX, orientation.footprintY),
                    height: orientation.height,
                    centre: centre,
                    massCentre: centre + orientation.comOffset,
                    massKilograms: prepared.item.massKilograms,
                    wallClearance: prepared.wallClearance,
                    neighbourClearance: prepared.item.horizontalClearance
                )
            )
        }

        let centreOfMass = SIMD3(
            values[model.centreOfMassVariables[0]],
            values[model.centreOfMassVariables[1]],
            values[model.centreOfMassVariables[2]]
        )
        let deviation = centreOfMass - problem.module.targetCentreOfMass
        var weighted = 0.0
        for axis in 0..<3 {
            weighted += max(0, problem.module.axisWeights[axis]) * abs(deviation[axis])
        }

        var boundingBox: PackingBoundingBox?
        if !packages.isEmpty {
            boundingBox = PackingBoundingBox(
                minimumX: packages.map(\.minimumX).min() ?? 0,
                maximumX: packages.map(\.maximumX).max() ?? 0,
                minimumY: packages.map(\.minimumY).min() ?? 0,
                maximumY: packages.map(\.maximumY).max() ?? 0
            )
        }

        return PackingSolution(
            module: problem.module,
            packages: packages,
            centreOfMass: centreOfMass,
            deviation: deviation,
            weightedDeviation: weighted,
            boundingBox: boundingBox,
            totalPayloadMass: problem.totalItemMass,
            totalSystemMass: problem.totalSystemMass
        )
    }
}

// MARK: - Independent verification

nonisolated struct PackingVerification: Sendable {
    var isValid: Bool
    var tolerance: Double
    var maximumViolation: Double
    var violations: [String]
    var recomputedCentreOfMass: SIMD3<Double>
    var centreOfMassError: Double
}

nonisolated enum PackingGeometryCheck {
    static let defaultTolerance = 1e-3

    static func verify(
        _ solution: PackingSolution,
        against problem: PreparedProblem,
        tolerance: Double = defaultTolerance
    ) -> PackingVerification {
        var violations: [String] = []
        var maximumViolation = 0.0
        let module = solution.module

        func fail(_ message: String, amount: Double) {
            violations.append(message)
            maximumViolation = max(maximumViolation, amount)
        }

        let requested = Set(problem.items.map(\.item.id))
        let reported = Set(solution.packages.map(\.id))
        if requested != reported || solution.packages.count != problem.items.count {
            fail(
                "The arrangement contains \(solution.packages.count) packages but \(problem.items.count) were requested.",
                amount: Double(abs(solution.packages.count - problem.items.count))
            )
        }

        let halfLength = module.lengthMillimetres / 2
        let halfWidth = module.widthMillimetres / 2

        for package in solution.packages {
            let clearance = package.wallClearance
            let checks: [(String, Double)] = [
                ("the rear wall", package.minimumX - clearance + halfLength),
                ("the front wall", halfLength - clearance - package.maximumX),
                ("the left wall", package.minimumY - clearance + halfWidth),
                ("the right wall", halfWidth - clearance - package.maximumY),
            ]
            for (side, slack) in checks where slack < -tolerance {
                fail(
                    String(format: "“%@” crosses %@ by %.4f mm.", package.name, side, -slack),
                    amount: -slack
                )
            }

            let item = problem.items[package.itemIndex].item
            let heightSlack = module.heightMillimetres - package.height - 2 * item.verticalClearance
            if heightSlack < -tolerance {
                fail(
                    String(
                        format: "“%@” stands %.1f mm tall, which exceeds the %.0f mm module height.",
                        package.name,
                        package.height,
                        module.heightMillimetres
                    ),
                    amount: -heightSlack
                )
            }

            let measured = [item.size.x, item.size.y, item.size.z].map { ($0 * 1e6).rounded() }.sorted()
            let placed = [package.footprint.x, package.footprint.y, package.height]
                .map { ($0 * 1e6).rounded() }
                .sorted()
            if measured != placed {
                fail("“\(package.name)” reports a footprint that is not a rotation of its measured size.", amount: 1)
            }
            if item.keepsUpright, !package.orientation.keepsPackageUpright {
                fail("“\(package.name)” must stay upright but was placed \(package.orientation.restingDescription).", amount: 1)
            }
        }

        for first in 0..<solution.packages.count {
            for second in (first + 1)..<solution.packages.count {
                let a = solution.packages[first]
                let b = solution.packages[second]
                let required = max(a.neighbourClearance, b.neighbourClearance)
                let gapX = abs(a.centre.x - b.centre.x) - (a.footprint.x + b.footprint.x) / 2
                let gapY = abs(a.centre.y - b.centre.y) - (a.footprint.y + b.footprint.y) / 2
                let best = max(gapX, gapY)
                if best < required - tolerance {
                    if best < -tolerance {
                        fail(
                            String(format: "“%@” and “%@” overlap by %.4f mm.", a.name, b.name, -best),
                            amount: -best
                        )
                    } else {
                        fail(
                            String(
                                format: "“%@” and “%@” are only %.4f mm apart but require %.1f mm.",
                                a.name, b.name, best, required
                            ),
                            amount: required - best
                        )
                    }
                }
            }
        }

        if let limit = module.maximumPayloadMassKilograms, solution.totalPayloadMass > limit + 1e-6 {
            fail(
                String(
                    format: "The load weighs %.2f kg, above the %.2f kg module limit.",
                    solution.totalPayloadMass,
                    limit
                ),
                amount: solution.totalPayloadMass - limit
            )
        }

        let recomputed = solution.recomputedCentreOfMass
        let error = (0..<3).map { abs(recomputed[$0] - solution.centreOfMass[$0]) }.max() ?? 0
        let centreTolerance = max(tolerance, 1e-3)
        if error > centreTolerance {
            fail(
                String(
                    format: "The reported centre of mass differs from an independent recomputation by %.6f mm.",
                    error
                ),
                amount: error
            )
        }
        if !module.centreOfMassEnvelope.isUnbounded,
           !module.centreOfMassEnvelope.contains(recomputed, tolerance: centreTolerance) {
            fail("The resulting centre of mass lies outside the requested envelope.", amount: 1)
        }

        return PackingVerification(
            isValid: violations.isEmpty,
            tolerance: tolerance,
            maximumViolation: maximumViolation,
            violations: violations,
            recomputedCentreOfMass: recomputed,
            centreOfMassError: error
        )
    }
}

nonisolated struct PackingOptions: Sendable, Equatable {
    var balanceTimeLimitSeconds: Double = 12
    var compactnessTimeLimitSeconds: Double = 5
    var minimisesFootprintAfterBalance = true
    var strengthening: PackingStrengthening = .all
    var maximumTableauElements = 4_000_000

    init() {}
}

nonisolated struct PackingPhaseReport: Sendable, Identifiable {
    var id = UUID()
    var name: String
    var status: String
    var objectiveValue: Double?
    var provenOptimal: Bool
    var nodeCount: Int
    var simplexIterationCount: Int
    var runtimeSeconds: Double
}

nonisolated struct PackingDiagnostics: Sendable {
    var variableCount = 0
    var integerVariableCount = 0
    var rowCount = 0
    var nonZeroCount = 0
    var cuts = PackingCutCounts()
    var strengtheningWasTruncated = false
    var phases: [PackingPhaseReport] = []
    var dualBound: Double?
    var absoluteGap: Double?
    var relativeGap: Double?
    var totalRuntimeSeconds: Double = 0
    var solverDescription = "Bounded-variable dual simplex with depth-first branch and bound"
}

nonisolated struct PackingSecondaryObjective: Sendable {
    var compactness: Double
    var provenOptimal: Bool
}

nonisolated struct PackingResult: Sendable {
    nonisolated enum Status: String, Sendable {
        case optimal
        case feasible
        case infeasible
        case noSolutionFound
        case invalidInput
    }

    var status: Status
    var solution: PackingSolution?
    var verification: PackingVerification?
    var infeasibility: PackingInfeasibility?
    var errors: [String] = []
    var secondaryObjective: PackingSecondaryObjective?
    var diagnostics = PackingDiagnostics()

    var provenOptimal: Bool { status == .optimal }
}

nonisolated enum PackingOptimizer {
    static func solve(_ problem: PackingProblem, options: PackingOptions = PackingOptions()) -> PackingResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        func elapsed() -> Double { seconds(from: startedAt, to: clock.now) }

        let prepared: PreparedProblem
        switch PackingPreparation.prepare(problem) {
        case .failure(let failure):
            var result = PackingResult(status: .invalidInput, errors: failure.messages)
            result.diagnostics.totalRuntimeSeconds = elapsed()
            return result
        case .success(let value):
            prepared = value
        }

        if let trivial = PackingPreparation.detectTrivialInfeasibility(prepared) {
            var result = PackingResult(status: .infeasible, infeasibility: trivial)
            result.diagnostics.totalRuntimeSeconds = elapsed()
            return result
        }

        var strengthening = options.strengthening
        var model: PackingModel
        switch buildStrengthenedModel(prepared, strengthening: strengthening, builderOptions: PackingModelBuilder.Options()) {
        case .failure(let infeasibility):
            var result = PackingResult(status: .infeasible, infeasibility: infeasibility)
            result.diagnostics.totalRuntimeSeconds = elapsed()
            return result
        case .success(let built):
            model = built
        }

        if tableauElements(of: model) > options.maximumTableauElements {
            strengthening.usesTransitivity = false
            strengthening.usesFittingCuts = false
            strengthening.usesIdenticalPackageSymmetry = false
            switch buildStrengthenedModel(prepared, strengthening: strengthening, builderOptions: PackingModelBuilder.Options()) {
            case .failure(let infeasibility):
                var result = PackingResult(status: .infeasible, infeasibility: infeasibility)
                result.diagnostics.totalRuntimeSeconds = elapsed()
                return result
            case .success(let built):
                model = built
            }
        }
        if tableauElements(of: model) > options.maximumTableauElements {
            var result = PackingResult(
                status: .infeasible,
                infeasibility: PackingInfeasibility(
                    reason: .modelTooLarge,
                    detail: "\(prepared.items.count) packages produce a model too large to solve exactly on this device. Remove some packages and arrange the load in more than one pass."
                )
            )
            result.diagnostics.totalRuntimeSeconds = elapsed()
            return result
        }

        var diagnostics = PackingDiagnostics()
        let statistics = model.program.statistics
        diagnostics.variableCount = statistics.variableCount
        diagnostics.integerVariableCount = statistics.integerVariableCount
        diagnostics.rowCount = statistics.rowCount
        diagnostics.nonZeroCount = statistics.nonZeroCount
        diagnostics.cuts = model.appliedCuts
        diagnostics.strengtheningWasTruncated = model.strengtheningWasTruncated

        var branchOptions = BranchAndBound.Options()
        branchOptions.timeLimitSeconds = options.balanceTimeLimitSeconds
        branchOptions.branchingPriority = model.branchingPriority
        let balanceSearch = BranchAndBound(program: model.program, options: branchOptions)
        var balance = balanceSearch.solve()
        diagnostics.phases.append(report(name: "Centre of mass", result: balance))

        switch balance.status {
        case .infeasible:
            var result = PackingResult(
                status: .infeasible,
                infeasibility: PackingInfeasibility(
                    reason: .noFeasibleArrangement,
                    detail: "No arrangement of all \(prepared.items.count) packages satisfies the module, clearance and centre-of-mass constraints at the same time."
                ),
                diagnostics: diagnostics
            )
            result.diagnostics.totalRuntimeSeconds = elapsed()
            return result

        case .noSolutionFound, .numericalFailure:
            let detail = balance.status == .noSolutionFound
                ? "The solver reached its \(Int(options.balanceTimeLimitSeconds)) s limit without finding an arrangement, and without proving that none exists — so one may well fit. Exact optimisation is comfortable up to about nine packages; \(prepared.items.count) is beyond that. Raise the time limit in the settings, reduce the clearances, or arrange the load in two passes."
                : "The solver ran into a numerical problem on this model. Try again with slightly different clearances."
            var result = PackingResult(
                status: .noSolutionFound,
                infeasibility: PackingInfeasibility(reason: .timeLimitWithoutSolution, detail: detail),
                diagnostics: diagnostics
            )
            result.diagnostics.dualBound = balance.dualBound.isFinite ? balance.dualBound : nil
            result.diagnostics.totalRuntimeSeconds = elapsed()
            return result

        case .optimal, .feasible:
            break
        }

        if let polished = balanceSearch.polishedSolution(for: balance.values) {
            balance.values = polished.values
            balance.objectiveValue = min(balance.objectiveValue ?? polished.objectiveValue, polished.objectiveValue)
        }
        var solution = PackingSolutionReader.read(model, values: balance.values)
        let balanceObjective = balance.objectiveValue ?? solution.weightedDeviation

        diagnostics.dualBound = balance.dualBound.isFinite ? balance.dualBound : nil
        diagnostics.absoluteGap = balance.absoluteGap
        diagnostics.relativeGap = balance.relativeGap
        var provenOptimal = balance.provenOptimal || (balance.absoluteGap ?? .infinity) <= 1e-6

        var secondary: PackingSecondaryObjective?
        if options.minimisesFootprintAfterBalance, provenOptimal, prepared.items.count > 1 {
            var builderOptions = PackingModelBuilder.Options()
            builderOptions.minimisesFootprint = true
            builderOptions.primaryObjectiveBound = balanceObjective + 1e-6
            if case .success(let compactModel) = buildStrengthenedModel(
                prepared,
                strengthening: strengthening,
                builderOptions: builderOptions
            ), tableauElements(of: compactModel) <= options.maximumTableauElements {
                var compactOptions = BranchAndBound.Options()
                compactOptions.timeLimitSeconds = options.compactnessTimeLimitSeconds
                compactOptions.branchingPriority = compactModel.branchingPriority
                let compactSearch = BranchAndBound(program: compactModel.program, options: compactOptions)
                var compact = compactSearch.solve()
                diagnostics.phases.append(report(name: "Compactness", result: compact))

                if compact.status == .optimal || compact.status == .feasible {
                    if let polished = compactSearch.polishedSolution(for: compact.values) {
                        compact.values = polished.values
                    }
                    let candidate = PackingSolutionReader.read(compactModel, values: compact.values)
                    let candidateCompactness = candidate.boundingBox?.compactness ?? .infinity
                    let currentCompactness = solution.boundingBox?.compactness ?? .infinity
                    if compact.provenOptimal || candidateCompactness <= currentCompactness {
                        solution = candidate
                        secondary = PackingSecondaryObjective(
                            compactness: candidateCompactness,
                            provenOptimal: compact.provenOptimal
                        )
                    } else {
                        secondary = PackingSecondaryObjective(
                            compactness: currentCompactness,
                            provenOptimal: false
                        )
                    }
                }
            }
        }

        let verification = PackingGeometryCheck.verify(solution, against: prepared)
        if !verification.isValid {
            provenOptimal = false
        }
        diagnostics.totalRuntimeSeconds = elapsed()

        return PackingResult(
            status: provenOptimal ? .optimal : .feasible,
            solution: solution,
            verification: verification,
            secondaryObjective: secondary,
            diagnostics: diagnostics
        )
    }

    // MARK: - Helpers

    private static func buildStrengthenedModel(
        _ problem: PreparedProblem,
        strengthening: PackingStrengthening,
        builderOptions: PackingModelBuilder.Options
    ) -> Result<PackingModel, PackingInfeasibility> {
        var options = builderOptions
        options.strengthening = strengthening
        switch PackingModelBuilder.build(problem, options: options) {
        case .failure(let infeasibility):
            return .failure(infeasibility)
        case .success(var model):
            if let infeasibility = model.applyStrengthening(strengthening) {
                return .failure(infeasibility)
            }
            return .success(model)
        }
    }

    private static func tableauElements(of model: PackingModel) -> Int {
        let statistics = model.program.statistics
        return Simplex.tableauElementCount(
            rowCount: statistics.rowCount,
            structuralCount: statistics.variableCount
        )
    }

    private static func report(name: String, result: MixedIntegerResult) -> PackingPhaseReport {
        PackingPhaseReport(
            name: name,
            status: result.status.rawValue,
            objectiveValue: result.objectiveValue,
            provenOptimal: result.provenOptimal,
            nodeCount: result.nodeCount,
            simplexIterationCount: result.simplexIterationCount,
            runtimeSeconds: result.runtimeSeconds
        )
    }

    private static func seconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let duration = end - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
}
