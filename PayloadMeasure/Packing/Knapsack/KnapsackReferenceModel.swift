import Foundation
import simd

// REFERENCE ONLY - not the method the app runs.
//
// The source paper's exact mixed-integer model, kept so the formulation can be inspected next to
// the paper. It does not encode the full-support rule, so it cannot certify the packings the app
// actually produces. Two printed equations had to be repaired to be solvable at all; METHODS.md
// records which and why.
//
// In:  a BaldiProblem.
// Out: a LinearProgram plus the variable indices needed to read a solver point back as placements.

nonisolated struct BaldiReferenceModel: Sendable {
    var program: LinearProgram
    var problem: BaldiProblem
    var selection: [Int]
    var position: [[Int]]
    var rotation: [[Int]]
    var precedence: [[[Int]?]]

    var totalProfit: Double
    var profitScale: Double
}

nonisolated enum BaldiReferenceModelBuilder {
    static func build(
        _ problem: BaldiProblem,
        usesPrintedRotationEquality: Bool = false
    ) -> BaldiReferenceModel {
        let knapsack = problem.knapsack
        let items = problem.items
        let count = items.count
        let rotations = BaldiRotation.all
        let axisNames = ["1", "2", "3"]
        let extent = SIMD3<Double>(
            Double(knapsack.size.x),
            Double(knapsack.size.y),
            Double(knapsack.size.z)
        )
        let totalMass = max(items.reduce(0) { $0 + $1.mass }, 1e-12)
        let profitScale = max(items.map(\.profit).max() ?? 1, 1e-12)

        var program = LinearProgram()

        // (18) t_i ∈ {0,1}. The objective (5) maximises Σ p_j t_j; the solver minimises, so the
        var selection: [Int] = []
        for (index, item) in items.enumerated() {
            let variable = program.addBinary(name: "t_\(index)")
            program.setObjective(variable, coefficient: -item.profit / profitScale)
            selection.append(variable)
        }

        // (17) χ^δ_i ≥ 0. The upper bound S^δ is implied by (8) and stated explicitly so that every
        var position: [[Int]] = []
        for index in 0..<count {
            var perAxis: [Int] = []
            for axis in 0..<3 {
                perAxis.append(
                    program.addVariable(
                        name: "chi_\(index)_\(axisNames[axis])",
                        lower: 0,
                        upper: 1
                    )
                )
            }
            position.append(perAxis)
        }

        // (20) ρ_ir ∈ {0,1}.
        var rotationVariables: [[Int]] = []
        for index in 0..<count {
            var perRotation: [Int] = []
            for r in rotations.indices {
                perRotation.append(program.addBinary(name: "rho_\(index)_\(r)"))
            }
            rotationVariables.append(perRotation)
        }

        // (19) b^δ_ij ∈ {0,1}, for every ordered pair i ≠ j and every dimension.
        var precedence: [[[Int]?]] = Array(
            repeating: Array(repeating: nil, count: count),
            count: count
        )
        for i in 0..<count {
            for j in 0..<count where i != j {
                precedence[i][j] = (0..<3).map {
                    program.addBinary(name: "b_\(i)_\(j)_\(axisNames[$0])")
                }
            }
        }

        // (6) Σ_j w_j d_j h_j t_j ≤ W D H. Redundant with (8), but the paper keeps it because it
        let knapsackVolume = Double(max(knapsack.volume, 1))
        program.addLessOrEqual(
            name: "capacity",
            terms: items.enumerated().map {
                (selection[$0.offset], Double($0.element.volume) / knapsackVolume)
            },
            value: 1
        )

        // (16) Σ_r ρ_ir = t_i, the repaired form; `Σ_r ρ_ir = 1` as printed.
        for index in 0..<count {
            var terms: [(Int, Double)] = rotationVariables[index].map { ($0, 1.0) }
            if !usesPrintedRotationEquality {
                terms.append((selection[index], -1))
            }
            program.addEqual(
                name: "rotation_\(index)",
                terms: terms,
                value: usesPrintedRotationEquality ? 1 : 0
            )
        }

        // (8) χ^δ_i + Σ_r s^δ_ir ρ_ir ≤ S^δ, divided by S^δ.
        for (index, item) in items.enumerated() {
            for axis in 0..<3 {
                var terms: [(Int, Double)] = [(position[index][axis], 1)]
                for (r, rotation) in rotations.enumerated() {
                    terms.append(
                        (rotationVariables[index][r], Double(rotation.size(of: item.size)[axis]) / extent[axis])
                    )
                }
                program.addLessOrEqual(
                    name: "inside_\(index)_\(axisNames[axis])",
                    terms: terms,
                    value: 1
                )
            }
        }

        // (7) Σ_δ (b^δ_ij + b^δ_ji) ≥ t_i + t_j − 1, i < j.
        for i in 0..<count {
            for j in (i + 1)..<count {
                var terms: [(Int, Double)] = []
                for axis in 0..<3 {
                    terms.append((precedence[i][j]![axis], 1))
                    terms.append((precedence[j][i]![axis], 1))
                }
                terms.append((selection[i], -1))
                terms.append((selection[j], -1))
                program.addGreaterOrEqual(name: "nonoverlap_\(i)_\(j)", terms: terms, value: -1)
            }
        }

        // (9) and (10). For the ordered pair (i, j): χ^δ_i + size_i − χ^δ_j + M·b^δ_ij ≤ M.
        for i in 0..<count {
            for j in 0..<count where i != j {
                for axis in 0..<3 {
                    var terms: [(Int, Double)] = [
                        (position[i][axis], 1),
                        (position[j][axis], -1),
                        (precedence[i][j]![axis], 1),
                    ]
                    for (r, rotation) in rotations.enumerated() {
                        terms.append(
                            (rotationVariables[i][r], Double(rotation.size(of: items[i].size)[axis]) / extent[axis])
                        )
                    }
                    program.addLessOrEqual(
                        name: "before_\(i)_\(j)_\(axisNames[axis])",
                        terms: terms,
                        value: 1
                    )
                }
            }
        }

        // (11) χ^δ_i ≤ M t_i.
        for index in 0..<count {
            for axis in 0..<3 {
                program.addLessOrEqual(
                    name: "unloadedAtOrigin_\(index)_\(axisNames[axis])",
                    terms: [(position[index][axis], 1), (selection[index], -1)],
                    value: 0
                )
            }
        }

        // (12) b^δ_ij ≤ t_i and (13) b^δ_ji ≤ t_j.
        for i in 0..<count {
            for j in 0..<count where i != j {
                for axis in 0..<3 {
                    program.addLessOrEqual(
                        name: "precedenceLoaded_\(i)_\(j)_\(axisNames[axis])",
                        terms: [(precedence[i][j]![axis], 1), (selection[i], -1)],
                        value: 0
                    )
                }
            }
        }

        // (14) and (15): the balancing constraints.
        for axis in 0..<3 {
            let scale = totalMass * extent[axis]
            var moment: [(Int, Double)] = []
            for (index, item) in items.enumerated() {
                moment.append((position[index][axis], item.mass * extent[axis] / scale))
                for (r, rotation) in rotations.enumerated() {
                    let offset = rotation.centreOfMassOffset(of: item.size)[axis]
                    moment.append((rotationVariables[index][r], item.mass * offset / scale))
                }
            }
            var lower = moment
            var upper = moment
            for (index, item) in items.enumerated() {
                lower.append((selection[index], -knapsack.domainLower[axis] * item.mass / scale))
                upper.append((selection[index], -knapsack.domainUpper[axis] * item.mass / scale))
            }
            program.addGreaterOrEqual(name: "balanceLow_\(axisNames[axis])", terms: lower, value: 0)
            program.addLessOrEqual(name: "balanceHigh_\(axisNames[axis])", terms: upper, value: 0)
        }

        return BaldiReferenceModel(
            program: program,
            problem: problem,
            selection: selection,
            position: position,
            rotation: rotationVariables,
            precedence: precedence,
            totalProfit: items.reduce(0) { $0 + $1.profit },
            profitScale: profitScale
        )
    }

    static func readSolution(_ model: BaldiReferenceModel, values: [Double]) -> BaldiSolution {
        var placements: [BaldiPlacement] = []
        var unloaded: [BaldiItem] = []
        let rotations = BaldiRotation.all

        for (index, item) in model.problem.items.enumerated() {
            guard values[model.selection[index]] > 0.5 else {
                unloaded.append(item)
                continue
            }
            var chosen = 0
            var best = -Double.infinity
            for r in rotations.indices where values[model.rotation[index][r]] > best {
                best = values[model.rotation[index][r]]
                chosen = r
            }
            let rotation = rotations[chosen]
            let size = rotation.size(of: item.size)
            let origin = SIMD3<Double>(
                values[model.position[index][0]] * Double(model.problem.knapsack.size.x),
                values[model.position[index][1]] * Double(model.problem.knapsack.size.y),
                values[model.position[index][2]] * Double(model.problem.knapsack.size.z)
            )
            placements.append(
                BaldiPlacement(
                    id: item.id,
                    name: item.name,
                    origin: origin,
                    rotation: rotation,
                    size: size,
                    mass: item.mass,
                    isOwnBox: item.isOwnBox
                )
            )
        }

        return BaldiSolution(
            knapsack: model.problem.knapsack,
            placements: placements,
            unloaded: unloaded
        )
    }
}
