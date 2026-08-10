import Foundation
import simd

/// The mixed-integer linear program, after Kaluzny & Shaw, "Optimal aircraft load balancing",
/// Intl. Trans. in Op. Res. 16 (2009) 767–787, adapted to the modular payload system as set out in
/// the project's adaptation chapter.
///
/// What comes from the paper
/// -------------------------
///   * free continuous placement of each package's geometric centre inside the cargo area;
///   * orthogonal rotation chosen by the optimiser, not fixed in advance;
///   * pairwise non-overlap as a four-way disjunction linearised with big-M indicators;
///   * item-specific spacing, both to the walls and between packages;
///   * an L1 centre-of-mass objective against a target, with an optional allowable envelope;
///   * everything decided simultaneously in one program — nothing is placed sequentially and
///     nothing is repositioned afterwards.
///
/// What the adaptation adds
/// ------------------------
///   * **Axis-aligned 3D orientations.** The paper turns a footprint by 90°; here each package
///     chooses from the orthogonal rotations `R_ik` about all three axes, selected by a one-hot
///     binary `u_ik`. Half-extents and the rotated centre-of-mass offset are precomputed per
///     orientation, so the model stays linear.
///   * **The module height.** Orientations taller than `H_b` are removed before solving, which is
///     the chapter's height-feasible orientation set `K_ib`.
///   * **A third centre-of-mass axis.** Packages rest on the module floor, so `z` is not a free
///     variable — the centre height is `Z_i`, fixed by the chosen orientation — but it still enters
///     the centre of mass, and the objective weights all three axes.
///   * **Empty masses.** The module's own mass and centre of mass and the airframe's are carried
///     through to the centre of mass of the complete connected aircraft. They are constants, so
///     the expression stays linear.
///
/// Deliberate departures, and why
/// ------------------------------
///   * **Item selection (paper §5) is not used.** Every measured package must be loaded; if no
///     complete arrangement exists the result is an explicit infeasibility rather than a silently
///     shortened load.
///   * **Stacking is not modelled**, matching the chapter: every package rests on the module floor.
///   * **The second objective is hierarchical, never blended.** Compactness is only minimised after
///     the centre-of-mass objective has been *proven* optimal, and subject to keeping it there.
nonisolated struct PackingModel: Sendable {
    nonisolated struct PairVariables: Sendable {
        var first: Int
        var second: Int
        /// `s_ij = max(s_i, s_j)`.
        var requiredClearance: Double
        /// The four separation indicators `γ¹…γ⁴`: first ahead / second ahead along x, then along y.
        var separation: [Int]
        var bigM: [Double]
        var activationRow: Int
    }

    nonisolated struct PositionBounds: Sendable {
        var lowerX: Double
        var upperX: Double
        var lowerY: Double
        var upperY: Double
    }

    var program: LinearProgram
    var problem: PreparedProblem

    /// `u_ik`. Empty for a package whose orientation set collapsed to a single entry — there is
    /// nothing to decide, so the constants are folded into the rows instead.
    var orientationVariables: [[Int]]
    var xVariables: [Int]
    var yVariables: [Int]
    /// `c_x`, `c_y`, `c_z`.
    var centreOfMassVariables: [Int]
    /// `e_x`, `e_y`, `e_z`.
    var deviationVariables: [Int]
    var pairs: [PairVariables]
    var positionBounds: [PositionBounds]
    var centreOfMassRange: (minimum: SIMD3<Double>, maximum: SIMD3<Double>)
    /// `bbXmin, bbXmax, bbYmin, bbYmax`, only present in the compactness phase.
    var boundingBoxVariables: [Int]?
    var appliedCuts: PackingCutCounts = PackingCutCounts()
    /// Branching priority for the search: orientation choices first, then separation relations.
    var branchingPriority: [Int] {
        var priorities = [Int](repeating: 0, count: program.variables.count)
        for group in orientationVariables {
            for variable in group { priorities[variable] = 1 }
        }
        return priorities
    }

    /// True when the strengthening row budget ran out before every valid inequality was added. The
    /// model is still correct; it is only less tightly described, so the result panel says so
    /// rather than letting a silently smaller model look like a fully cut one.
    var strengtheningWasTruncated = false
}

nonisolated struct PackingCutCounts: Sendable {
    var exactlyOneSeparation = 0
    var identicalPackageSymmetry = 0
    var fittingPairs = 0
    var orientedFittingPairs = 0
    var fittingTriples = 0
    var transitivity = 0

    var total: Int {
        exactlyOneSeparation + identicalPackageSymmetry + fittingPairs
            + orientedFittingPairs + fittingTriples + transitivity
    }
}

/// Which families of valid inequalities to add. Each can be switched off on its own so the effect
/// of a family can be measured, which is what the paper's §3 evaluation does.
nonisolated struct PackingStrengthening: Sendable, Equatable {
    /// Tight, row-specific big-M values derived from the container and the variable bounds,
    /// instead of one loose global constant (paper §2.5.3).
    var usesTightBigM = true
    /// Requires exactly one separation relation per pair instead of at least one. Any arrangement
    /// still has a representation, so this removes duplicate encodings, not solutions.
    var usesExactlyOneSeparation = true
    /// Orders packages that are identical in every respect, removing `k!` relabellings.
    var usesIdenticalPackageSymmetry = true
    /// Paper (26)–(28), (43)–(44): a pair or triple that cannot fit along an axis may not choose it.
    var usesFittingCuts = true
    /// Forbids cyclic "i before j before i" separation patterns along one axis (paper §3.1).
    var usesTransitivity = true
    /// Upper limit on how many strengthening rows may be added, applied in priority order. Rows are
    /// what drive the dense tableau's size, so a large load is better served by a smaller model.
    var maximumAdditionalRows = 600

    static let all = PackingStrengthening()
    static let none = PackingStrengthening(
        usesTightBigM: false,
        usesExactlyOneSeparation: false,
        usesIdenticalPackageSymmetry: false,
        usesFittingCuts: false,
        usesTransitivity: false
    )
}

// MARK: - Construction

nonisolated enum PackingModelBuilder {
    /// A linear expression `constant + Σ coefficient · variable`.
    private struct Expression {
        var constant: Double = 0
        var terms: [(Int, Double)] = []

        static func constant(_ value: Double) -> Expression { Expression(constant: value) }
        static func variable(_ index: Int, _ coefficient: Double = 1) -> Expression {
            Expression(constant: 0, terms: [(index, coefficient)])
        }

        func scaled(by factor: Double) -> Expression {
            Expression(constant: constant * factor, terms: terms.map { ($0.0, $0.1 * factor) })
        }

        static func + (lhs: Expression, rhs: Expression) -> Expression {
            Expression(constant: lhs.constant + rhs.constant, terms: lhs.terms + rhs.terms)
        }

        static func - (lhs: Expression, rhs: Expression) -> Expression {
            lhs + rhs.scaled(by: -1)
        }
    }

    nonisolated struct Options: Sendable {
        var strengthening: PackingStrengthening = .all
        /// Builds the compactness phase instead of the balance phase.
        var minimisesFootprint = false
        /// Upper bound to hold the already-proven centre-of-mass objective at, in the second phase.
        var primaryObjectiveBound: Double?

        init() {}
    }

    static func build(
        _ problem: PreparedProblem,
        options: Options = Options()
    ) -> Result<PackingModel, PackingInfeasibility> {
        let module = problem.module
        let halfLength = module.lengthMillimetres / 2
        let halfWidth = module.widthMillimetres / 2
        let count = problem.items.count

        var program = LinearProgram()

        // --- position variables and their boxes -----------------------------------------------
        //
        // The box uses each package's *smallest* possible half-extent; the wall rows below enforce
        // the exact, orientation-dependent value. Deriving the box from the module rather than
        // using one loose constant is what keeps the big-M coefficients small (paper §2.5.3).
        var positionBounds: [PackingModel.PositionBounds] = []
        for prepared in problem.items {
            let minimum = prepared.minimumHalfExtents
            let clearance = prepared.wallClearance
            let bounds = PackingModel.PositionBounds(
                lowerX: -halfLength + clearance + minimum.x,
                upperX: halfLength - clearance - minimum.x,
                lowerY: -halfWidth + clearance + minimum.y,
                upperY: halfWidth - clearance - minimum.y
            )
            if bounds.lowerX > bounds.upperX + 1e-9 || bounds.lowerY > bounds.upperY + 1e-9 {
                return .failure(
                    PackingInfeasibility(
                        reason: .packageTooLarge,
                        detail: "“\(prepared.item.name)” cannot be placed inside the module in any permitted orientation while respecting its clearance."
                    )
                )
            }
            positionBounds.append(bounds)
        }

        var xVariables: [Int] = []
        var yVariables: [Int] = []
        for index in 0..<count {
            xVariables.append(
                program.addVariable(name: "x_\(index)", lower: positionBounds[index].lowerX, upper: positionBounds[index].upperX)
            )
            yVariables.append(
                program.addVariable(name: "y_\(index)", lower: positionBounds[index].lowerY, upper: positionBounds[index].upperY)
            )
        }

        // --- orientation selection, chapter eq. (unique module and orientation) ----------------
        var orientationVariables: [[Int]] = []
        for (index, prepared) in problem.items.enumerated() {
            guard prepared.orientations.count > 1 else {
                orientationVariables.append([])
                continue
            }
            let variables = prepared.orientations.indices.map {
                program.addBinary(name: "u_\(index)_\($0)")
            }
            program.addEqual(name: "orient_\(index)", terms: variables.map { ($0, 1.0) }, value: 1)
            orientationVariables.append(variables)
        }

        /// `X_i`, `Y_i` or `Z_i` as a linear expression — chapter eq. (selected half-dimensions).
        func halfExtent(_ index: Int, axis: Int) -> Expression {
            let prepared = problem.items[index]
            let variables = orientationVariables[index]
            if variables.isEmpty {
                return .constant(prepared.orientations[0].halfExtents[axis])
            }
            return Expression(
                constant: 0,
                terms: zip(variables, prepared.orientations).map { ($0, $1.halfExtents[axis]) }
            )
        }

        /// `Δ_i` on one axis — chapter eq. (selected COM offset). For the vertical axis the centre
        /// height `Z_i` is included, because the package rests on the floor.
        func massOffset(_ index: Int, axis: Int) -> Expression {
            let prepared = problem.items[index]
            let variables = orientationVariables[index]
            let value: (PreparedOrientation) -> Double = { orientation in
                axis == 2
                    ? orientation.halfExtents.z + orientation.comOffset.z
                    : orientation.comOffset[axis]
            }
            if variables.isEmpty {
                return .constant(value(prepared.orientations[0]))
            }
            return Expression(
                constant: 0,
                terms: zip(variables, prepared.orientations).map { ($0, value($1)) }
            )
        }

        func addGreaterOrEqual(_ program: inout LinearProgram, _ name: String, _ expression: Expression, _ value: Double) {
            program.addGreaterOrEqual(name: name, terms: expression.terms, value: value - expression.constant)
        }
        func addLessOrEqual(_ program: inout LinearProgram, _ name: String, _ expression: Expression, _ value: Double) {
            program.addLessOrEqual(name: name, terms: expression.terms, value: value - expression.constant)
        }
        func addEqual(_ program: inout LinearProgram, _ name: String, _ expression: Expression, _ value: Double) {
            program.addEqual(name: name, terms: expression.terms, value: value - expression.constant)
        }

        // --- module boundaries, chapter eq. (adapted boundary constraints) ----------------------
        for index in 0..<count {
            let clearance = problem.items[index].wallClearance
            addGreaterOrEqual(&program, "wallXlo_\(index)", .variable(xVariables[index]) - halfExtent(index, axis: 0), -halfLength + clearance)
            addLessOrEqual(&program, "wallXhi_\(index)", .variable(xVariables[index]) + halfExtent(index, axis: 0), halfLength - clearance)
            addGreaterOrEqual(&program, "wallYlo_\(index)", .variable(yVariables[index]) - halfExtent(index, axis: 1), -halfWidth + clearance)
            addLessOrEqual(&program, "wallYhi_\(index)", .variable(yVariables[index]) + halfExtent(index, axis: 1), halfWidth - clearance)
        }

        // --- pairwise non-overlap, chapter eq. (module non-overlap 1–4) -------------------------
        let looseBigM = 2 * max(module.lengthMillimetres, module.widthMillimetres)
        var pairs: [PackingModel.PairVariables] = []
        for first in 0..<count {
            for second in (first + 1)..<count {
                let clearance = max(
                    problem.items[first].item.horizontalClearance,
                    problem.items[second].item.horizontalClearance
                )
                let maximumFirst = problem.items[first].maximumHalfExtents
                let maximumSecond = problem.items[second].maximumHalfExtents
                let boundsFirst = positionBounds[first]
                let boundsSecond = positionBounds[second]

                // Smallest big-M that cannot cut off a feasible point: the largest amount by which
                // the row can be violated anywhere inside the variable box.
                let tight = [
                    max(0, clearance + maximumFirst.x + maximumSecond.x - boundsFirst.lowerX + boundsSecond.upperX),
                    max(0, clearance + maximumFirst.x + maximumSecond.x - boundsSecond.lowerX + boundsFirst.upperX),
                    max(0, clearance + maximumFirst.y + maximumSecond.y - boundsFirst.lowerY + boundsSecond.upperY),
                    max(0, clearance + maximumFirst.y + maximumSecond.y - boundsSecond.lowerY + boundsFirst.upperY),
                ]
                let bigM = options.strengthening.usesTightBigM ? tight : [Double](repeating: looseBigM, count: 4)

                var separation: [Int] = []
                for relation in 0..<4 {
                    separation.append(program.addBinary(name: "g\(relation + 1)_\(first)_\(second)"))
                }

                let separationX = halfExtent(first, axis: 0) + halfExtent(second, axis: 0)
                let separationY = halfExtent(first, axis: 1) + halfExtent(second, axis: 1)
                let bodies: [(String, Expression, Int)] = [
                    ("sepXfirst", .variable(xVariables[first]) - .variable(xVariables[second]) - separationX, 0),
                    ("sepXsecond", .variable(xVariables[second]) - .variable(xVariables[first]) - separationX, 1),
                    ("sepYfirst", .variable(yVariables[first]) - .variable(yVariables[second]) - separationY, 2),
                    ("sepYsecond", .variable(yVariables[second]) - .variable(yVariables[first]) - separationY, 3),
                ]
                for (name, body, relation) in bodies {
                    // body − M·γ ≥ σ − M   ⟺   body ≥ σ − M(1 − γ)
                    let row = body - .variable(separation[relation], bigM[relation])
                    addGreaterOrEqual(&program, "\(name)_\(first)_\(second)", row, clearance - bigM[relation])
                }

                // At least one relation must hold. With a single module both packages are always
                // loaded, so the chapter's activation right-hand side a_ib + a_jb − 1 is just 1.
                let activationRow = program.addRow(
                    name: "sepAny_\(first)_\(second)",
                    terms: separation.map { ($0, 1.0) },
                    lower: 1,
                    upper: options.strengthening.usesExactlyOneSeparation ? 1 : .infinity
                )

                pairs.append(
                    PackingModel.PairVariables(
                        first: first,
                        second: second,
                        requiredClearance: clearance,
                        separation: separation,
                        bigM: bigM,
                        activationRow: activationRow
                    )
                )
            }
        }

        // --- centre of mass of the complete connected system ------------------------------------
        let totalMass = problem.totalSystemMass
        let fixedMoment = module.fixedMassMoment

        var centreLower = SIMD3<Double>(repeating: 0)
        var centreUpper = SIMD3<Double>(repeating: 0)
        for axis in 0..<3 {
            var lowest = fixedMoment[axis]
            var highest = fixedMoment[axis]
            for (index, prepared) in problem.items.enumerated() {
                let mass = prepared.item.massKilograms
                let offsets = prepared.orientations.map { orientation -> Double in
                    axis == 2
                        ? orientation.halfExtents.z + orientation.comOffset.z
                        : orientation.comOffset[axis]
                }
                let positionLow: Double
                let positionHigh: Double
                switch axis {
                case 0: positionLow = positionBounds[index].lowerX; positionHigh = positionBounds[index].upperX
                case 1: positionLow = positionBounds[index].lowerY; positionHigh = positionBounds[index].upperY
                default: positionLow = 0; positionHigh = 0
                }
                lowest += mass * (positionLow + (offsets.min() ?? 0))
                highest += mass * (positionHigh + (offsets.max() ?? 0))
            }
            centreLower[axis] = lowest / totalMass
            centreUpper[axis] = highest / totalMass
        }

        let envelope = module.centreOfMassEnvelope
        for axis in 0..<3 {
            centreLower[axis] = max(centreLower[axis], envelope.minimum[axis])
            centreUpper[axis] = min(centreUpper[axis], envelope.maximum[axis])
            if centreLower[axis] > centreUpper[axis] + 1e-9 {
                return .failure(
                    PackingInfeasibility(
                        reason: .centreOfMassEnvelopeUnreachable,
                        detail: "The requested centre-of-mass envelope lies outside the range these packages can produce in this module, so no arrangement can satisfy it."
                    )
                )
            }
        }

        let axisNames = ["X", "Y", "Z"]
        var centreOfMassVariables: [Int] = []
        var deviationVariables: [Int] = []
        for axis in 0..<3 {
            let centre = program.addVariable(
                name: "com\(axisNames[axis])",
                lower: centreLower[axis],
                upper: centreUpper[axis]
            )
            centreOfMassVariables.append(centre)

            // m_tot·c_α = Σ m_i·p_αi + fixed moment.
            var expression = Expression.variable(centre, -totalMass)
            for (index, prepared) in problem.items.enumerated() {
                let mass = prepared.item.massKilograms
                if axis == 0 { expression = expression + Expression.variable(xVariables[index], mass) }
                if axis == 1 { expression = expression + Expression.variable(yVariables[index], mass) }
                expression = expression + massOffset(index, axis: axis).scaled(by: mass)
            }
            addEqual(&program, "comDef\(axisNames[axis])", expression, -fixedMoment[axis])

            // L1 deviation, linearised as in paper (10): e ≥ c − c*, e ≥ c* − c.
            let target = module.targetCentreOfMass[axis]
            let largestDeviation = max(abs(centreUpper[axis] - target), abs(target - centreLower[axis]))
            let deviation = program.addVariable(
                name: "dev\(axisNames[axis])",
                lower: 0,
                upper: max(0, largestDeviation),
                objective: options.minimisesFootprint ? 0 : max(0, module.axisWeights[axis])
            )
            deviationVariables.append(deviation)
            program.addGreaterOrEqual(name: "devPos\(axisNames[axis])", terms: [(deviation, 1), (centre, -1)], value: -target)
            program.addGreaterOrEqual(name: "devNeg\(axisNames[axis])", terms: [(deviation, 1), (centre, 1)], value: target)
        }

        // --- optional hierarchical second objective ---------------------------------------------
        var boundingBoxVariables: [Int]?
        if options.minimisesFootprint {
            let minimumX = program.addVariable(name: "bbXmin", lower: -halfLength, upper: halfLength, objective: -1)
            let maximumX = program.addVariable(name: "bbXmax", lower: -halfLength, upper: halfLength, objective: 1)
            let minimumY = program.addVariable(name: "bbYmin", lower: -halfWidth, upper: halfWidth, objective: -1)
            let maximumY = program.addVariable(name: "bbYmax", lower: -halfWidth, upper: halfWidth, objective: 1)
            boundingBoxVariables = [minimumX, maximumX, minimumY, maximumY]
            for index in 0..<count {
                addLessOrEqual(&program, "bbXmin_\(index)", .variable(minimumX) - .variable(xVariables[index]) + halfExtent(index, axis: 0), 0)
                addGreaterOrEqual(&program, "bbXmax_\(index)", .variable(maximumX) - .variable(xVariables[index]) - halfExtent(index, axis: 0), 0)
                addLessOrEqual(&program, "bbYmin_\(index)", .variable(minimumY) - .variable(yVariables[index]) + halfExtent(index, axis: 1), 0)
                addGreaterOrEqual(&program, "bbYmax_\(index)", .variable(maximumY) - .variable(yVariables[index]) - halfExtent(index, axis: 1), 0)
            }
            if let bound = options.primaryObjectiveBound {
                let terms = (0..<3).map { (deviationVariables[$0], max(0, module.axisWeights[$0])) }
                program.addLessOrEqual(name: "balanceHeld", terms: terms, value: bound)
            }
        }

        var model = PackingModel(
            program: program,
            problem: problem,
            orientationVariables: orientationVariables,
            xVariables: xVariables,
            yVariables: yVariables,
            centreOfMassVariables: centreOfMassVariables,
            deviationVariables: deviationVariables,
            pairs: pairs,
            positionBounds: positionBounds,
            centreOfMassRange: (centreLower, centreUpper),
            boundingBoxVariables: boundingBoxVariables
        )
        if options.strengthening.usesExactlyOneSeparation {
            model.appliedCuts.exactlyOneSeparation = pairs.count
        }
        return .success(model)
    }
}
