import Foundation
import simd

/// The MIP model 3BKP-M, Baldi, Perboli & Tadei (2012), equations (5)–(20).
///
/// Every row below is annotated with the equation it implements, in the paper's own order and with
/// the paper's own symbols:
///
///   variables   t_i     binary, 1 if item i is loaded                                     (18)
///               b^δ_ij  binary, 1 if item i comes before item j along dimension δ          (19)
///               ρ_ir    binary, 1 if item i is rotated with rotation r                     (20)
///               χ^δ_i   continuous, bottom-left-back coordinate of item i along δ          (17)
///
///   (5)   max Σ_j p_j t_j
///   (6)   Σ_j w_j d_j h_j t_j ≤ W D H
///   (7)   Σ_δ (b^δ_ij + b^δ_ji) ≥ t_i + t_j − 1                              i < j
///   (8)   χ^δ_i + Σ_r s^δ_ir ρ_ir ≤ S^δ
///   (9)   χ^δ_i + Σ_r s^δ_ir ρ_ir ≤ χ^δ_j + M(1 − b^δ_ij)                    i < j
///   (10)  χ^δ_j + Σ_r s^δ_jr ρ_jr ≤ χ^δ_i + M(1 − b^δ_ji)                    i < j
///   (11)  χ^δ_i ≤ M t_i
///   (12)  b^δ_ij ≤ t_i
///   (13)  b^δ_ji ≤ t_j
///   (14)  Σ_i m_i χ^δ_i + Σ_i Σ_r m_i γ^δ_ir ρ_ir ≥ L^δ Σ_i m_i t_i
///   (15)  Σ_i m_i χ^δ_i + Σ_i Σ_r m_i γ^δ_ir ρ_ir ≤ U^δ Σ_i m_i t_i
///   (16)  Σ_r ρ_ir = 1
///
/// Two points where the printed paper needs reading rather than transcribing:
///
/// * **Equation (10) is misprinted.** It appears as `χ^δ_j + Σ_r s^δ_jr ρ_ir ≤ χ^δ_i + M(1−b^δ_ji)`,
///   with `ρ_ir` where the summation is over item *j*'s sizes. Taken literally the row would size
///   item j by item i's rotation, which contradicts the constraint's stated meaning ("the same
///   meaning, this time with item j coming before item i") and its symmetry with (9). It is
///   implemented as `ρ_jr`.
/// * **Equation (16) leaves the model infeasible as printed.** `Σ_r ρ_ir = 1` forces *every* item
///   to take a rotation, loaded or not. The moment term of (14)–(15) is
///   `Σ_i m_i χ^δ_i + Σ_i Σ_r m_i γ^δ_ir ρ_ir`, summed over all of `J`, so an unloaded item — held
///   at the origin by (11) — still contributes `m_i γ^δ_ir` to the packing moment while
///   contributing nothing to the mass `Σ_i m_i t_i` on the right-hand side. With every item
///   unloaded, (15) reads `Σ_i m_i γ^δ_ir ≤ 0`, which no rotation can satisfy: the empty packing is
///   infeasible, and so is any packing that leaves out enough mass. This also makes (8) reject an
///   item that fits in no rotation even though the knapsack is free to not load it.
///
///   The repair is one right-hand side: `Σ_r ρ_ir = t_i`. An unloaded item then selects no
///   rotation, its `γ` term vanishes, and the moment becomes exactly the numerator the paper writes
///   for `r^δ_CM` immediately below (15). For a fully loaded packing the two forms coincide, which
///   is why the paper's own instances — where the model rarely leaves items out at the sizes it can
///   solve — do not expose it. `usesPrintedRotationEquality` keeps the literal form available.
///
/// * **`M` is not given a value.** The paper writes a generic big-M. Here `M = S^δ` per dimension,
///   which is the smallest value that cannot cut off a feasible point: in (9)–(10) the left side is
///   at most `S^δ` by (8) and the right side is at least 0 by (17), and in (11) `χ^δ_i ≤ S^δ`
///   likewise. A tighter big-M changes no feasible solution, only the strength of the relaxation.
///
/// Scaling
/// -------
/// Written in the paper's own units the rows span an enormous range — the capacity row (6) carries
/// volumes, the balancing rows (14)–(15) carry mass times length, and the ordering rows carry ones —
/// and a simplex on the raw matrix stalls. Every row is therefore divided by a positive constant and
/// the positions are held as `χ̂^δ_i = χ^δ_i / S^δ`, which brings every coefficient into `[−1, 1]`.
/// Dividing a constraint by a positive number and rescaling a variable changes no feasible point and
/// no optimal selection; positions are multiplied back by `S^δ` when the solution is read.
nonisolated struct Baldi3BKPModel: Sendable {
    var program: LinearProgram
    var problem: BaldiProblem
    /// `t_i`.
    var selection: [Int]
    /// `χ^δ_i`, indexed `[item][δ]`.
    var position: [[Int]]
    /// `ρ_ir`, indexed `[item][rotation]`.
    var rotation: [[Int]]
    /// `b^δ_ij`, indexed `[i][j][δ]`; `nil` on the diagonal.
    var precedence: [[[Int]?]]

    /// Total profit of the instance, used as the objective's lower bound after negation.
    var totalProfit: Double
    /// The objective was divided by this, so a solver objective maps back to profit as
    /// `profit = −objective × profitScale`.
    var profitScale: Double
}

nonisolated enum Baldi3BKPModelBuilder {
    /// Builds 3BKP-M. `usesPrintedRotationEquality` selects equation (16) exactly as printed,
    /// `Σ_r ρ_ir = 1`, instead of the repaired `Σ_r ρ_ir = t_i`; see the type comment.
    static func build(
        _ problem: BaldiProblem,
        usesPrintedRotationEquality: Bool = false
    ) -> Baldi3BKPModel {
        let knapsack = problem.knapsack
        let items = problem.items
        let count = items.count
        let rotations = BaldiRotation.all
        let axisNames = ["1", "2", "3"]
        // M = S^δ; see the type comment. Because the positions are scaled by the same S^δ, the
        // big-M terms below all reduce to a coefficient of 1.
        let extent = SIMD3<Double>(
            Double(knapsack.size.x),
            Double(knapsack.size.y),
            Double(knapsack.size.z)
        )
        let totalMass = max(items.reduce(0) { $0 + $1.mass }, 1e-12)
        let profitScale = max(items.map(\.profit).max() ?? 1, 1e-12)

        var program = LinearProgram()

        // --- variables ------------------------------------------------------------------------
        // (18) t_i ∈ {0,1}. The objective (5) maximises Σ p_j t_j; the solver minimises, so the
        // objective coefficient is −p_j.
        var selection: [Int] = []
        for (index, item) in items.enumerated() {
            let variable = program.addBinary(name: "t_\(index)")
            program.setObjective(variable, coefficient: -item.profit / profitScale)
            selection.append(variable)
        }

        // (17) χ^δ_i ≥ 0. The upper bound S^δ is implied by (8) and stated explicitly so that every
        // structural variable is boxed, which the simplex needs for a dual-feasible start.
        var position: [[Int]] = []
        for index in 0..<count {
            var perAxis: [Int] = []
            for axis in 0..<3 {
                perAxis.append(
                    // χ̂^δ_i = χ^δ_i / S^δ, so the box is the unit interval.
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

        // --- constraints ----------------------------------------------------------------------

        // (6) Σ_j w_j d_j h_j t_j ≤ W D H. Redundant with (8), but the paper keeps it because it
        // improves the continuous relaxation on some instances; it is kept here for the same reason.
        // Divided by the knapsack volume.
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
                    // Divided by S^δ, which turns the big-M coefficient into 1.
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
                // Divided by S^δ.
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
        //   Σ_i m_i χ^δ_i + Σ_i Σ_r m_i γ^δ_ir ρ_ir − L^δ Σ_i m_i t_i ≥ 0
        //   Σ_i m_i χ^δ_i + Σ_i Σ_r m_i γ^δ_ir ρ_ir − U^δ Σ_i m_i t_i ≤ 0
        // Both rows are divided by (Σ_i m_i)·S^δ, and χ is already scaled by S^δ.
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

        return Baldi3BKPModel(
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

    /// Reads a solver point back into a packing.
    static func readSolution(_ model: Baldi3BKPModel, values: [Double]) -> BaldiSolution {
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
            // The positions are continuous in the model; the paper's items are integral, so the
            // reported origin is rounded to the millimetre grid the instance is stated on.
            // χ̂ is scaled by S^δ; multiply back. The coordinate stays continuous, as equation (17)
            // makes it — rounding it onto the millimetre grid would move the packing centre of mass
            // by a fraction of a millimetre, which is enough to push a solution whose balancing
            // constraint is tight just outside the allowable domain.
            let origin = SIMD3<Double>(
                values[model.position[index][0]] * Double(model.problem.knapsack.size.x),
                values[model.position[index][1]] * Double(model.problem.knapsack.size.y),
                values[model.position[index][2]] * Double(model.problem.knapsack.size.z)
            )
            placements.append(
                BaldiPlacement(
                    id: item.id,
                    itemIndex: index,
                    name: item.name,
                    origin: origin,
                    rotation: rotation,
                    size: size,
                    mass: item.mass,
                    profit: item.profit
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

// MARK: - UB_1D

/// The upper bound `UB_1D` of paper §4: model 3BKP-M with constraints (7)–(16) ignored, which
/// leaves a one-dimensional knapsack of capacity `W·D·H` in which item `j` weighs `w_j d_j h_j`.
///
/// The paper notes this bound has essentially the same quality as the continuous relaxation of the
/// full model (Table 1) and uses it as the reference bound throughout its results.
nonisolated enum BaldiUpperBound {
    /// Solves the relaxed one-dimensional knapsack exactly.
    ///
    /// Depth-first over the items in decreasing profit density, pruned by the Dantzig bound — the
    /// continuous relaxation of the remaining sub-problem, which is an upper bound on it. For the
    /// instance sizes this app produces this closes in microseconds. A node cap guards against a
    /// pathological instance; if it is ever hit the Dantzig bound itself is returned, which is still
    /// a valid upper bound, only weaker.
    static func oneDimensional(_ problem: BaldiProblem) -> Double {
        let capacity = problem.knapsack.volume
        guard capacity > 0, !problem.items.isEmpty else { return 0 }

        let ordered = problem.items
            .filter { $0.volume > 0 && $0.volume <= capacity }
            .sorted { $0.profit / Double($0.volume) > $1.profit / Double($1.volume) }
        guard !ordered.isEmpty else { return 0 }

        let weights = ordered.map { Double($0.volume) }
        let profits = ordered.map(\.profit)
        let count = ordered.count

        /// Continuous relaxation of the sub-problem from `index` onwards.
        func dantzig(from index: Int, remaining: Double) -> Double {
            var room = remaining
            var bound = 0.0
            var position = index
            while position < count, room > 0 {
                if weights[position] <= room {
                    bound += profits[position]
                    room -= weights[position]
                } else {
                    bound += profits[position] * room / weights[position]
                    break
                }
                position += 1
            }
            return bound
        }

        var best = 0.0
        var nodes = 0
        var exhausted = false

        func explore(index: Int, remaining: Double, profit: Double) {
            nodes += 1
            if nodes > 2_000_000 { exhausted = true }
            if exhausted { return }
            if profit > best { best = profit }
            guard index < count else { return }
            if profit + dantzig(from: index, remaining: remaining) <= best + 1e-9 { return }
            if weights[index] <= remaining {
                explore(index: index + 1, remaining: remaining - weights[index], profit: profit + profits[index])
            }
            explore(index: index + 1, remaining: remaining, profit: profit)
        }

        explore(index: 0, remaining: Double(capacity), profit: 0)
        return exhausted ? dantzig(from: 0, remaining: Double(capacity)) : best
    }
}
