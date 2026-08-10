import Foundation

/// Bounded-variable simplex over a dense tableau, with both a primal and a dual method.
///
/// Both are needed, for different jobs:
///
/// * **Primal, phase 1 then phase 2** solves a node from cold. The packing model's objective
///   touches only the three centre-of-mass deviation variables, so nearly every reduced cost is
///   zero and a dual ratio test has nothing to choose between — it ties everywhere and wanders.
///   The primal phase-1 objective, total bound infeasibility, is a real gradient that decreases
///   monotonically, which is what actually finds a feasible basis for a model built out of big-M
///   disjunctions.
///
/// * **Dual** re-optimises after a bound change. A simplex basis does not depend on variable
///   bounds, and branch-and-bound only tightens them, so a child node inherits its parent's final
///   basis — still dual feasible — and normally needs a handful of pivots. That is what makes an
///   exact mixed-integer solve affordable on a phone.
///
/// The tableau is `B⁻¹A'` for `A' = [A | −I]`: the structural columns followed by one logical
/// (slack) column per row, with the logical of row `r` boxed by that row's own `[lower, upper]`
/// range. The system is `A'z = 0`.
///
/// Numerical care
/// --------------
/// A dense tableau updated in place accumulates error, and a big-M model punishes that hard: a
/// pivot on a near-zero entry multiplies a whole row by its reciprocal, and one such pivot can
/// leave the reduced costs meaningless. Three things keep it honest — a ratio test that prefers
/// large pivots among near-equal candidates (Harris' two-pass test), a relative floor on the pivot
/// magnitude, and periodic refactorisation of the tableau from the basis and the original matrix.
nonisolated final class Simplex {
    nonisolated enum Status: Sendable, Equatable {
        /// Primal feasible and no improving direction: the point is optimal for the LP.
        case optimal
        /// No feasible point exists under the current bounds.
        case infeasible
        case iterationLimit
        case timeLimit
        case numericalFailure
    }

    nonisolated struct Tolerances: Sendable {
        /// A basic variable is treated as inside its bounds within this margin.
        var primalFeasibility: Double = 1e-7
        /// Reduced costs below this are treated as zero.
        var dualFeasibility: Double = 1e-7
        /// Absolute floor on an accepted pivot.
        var pivot: Double = 1e-9
        /// Pivot floor relative to the largest magnitude in the entering column.
        var relativePivot: Double = 1e-7

        init() {}
    }

    private let structuralCount: Int
    private let rowCount: Int
    private let columnCount: Int
    /// Sparse columns of `A' = [A | −I]`, kept so the tableau can be rebuilt from the basis.
    private let originalColumns: [[(row: Int, value: Double)]]

    /// Row-major `rowCount × columnCount` tableau.
    private var tableau: [Double]
    private var basis: [Int]
    private var isBasic: [Bool]
    /// For a nonbasic variable: `true` when it sits on its upper bound.
    private var isAtUpper: [Bool]
    private var nonbasicValue: [Double]
    private var basicValue: [Double]
    private var reducedCost: [Double]

    private var lowerBound: [Double]
    private var upperBound: [Double]
    private let cost: [Double]

    /// Scratch buffers, reused so the pivot loop allocates nothing.
    private var infeasibilitySign: [Double]
    private var phaseOneCost: [Double]
    private var ratioCandidates: [(row: Int, ratio: Double, magnitude: Double, reachesUpper: Bool)] = []

    private(set) var iterationCount = 0
    private var pivotsSinceRefactorisation = 0
    private var pivotsSinceRefresh = 0
    private var needsRefactorisation = false
    /// Refactorising costs about `rows² × columns` operations, so a big model earns a longer
    /// interval between rebuilds; a small one can afford to stay very clean.
    private let refactorisationInterval: Int

    var tolerances = Tolerances()

    /// Number of stored doubles, exposed so the driver can refuse instances that would not fit.
    static func tableauElementCount(rowCount: Int, structuralCount: Int) -> Int {
        rowCount * (rowCount + structuralCount)
    }

    init(program: LinearProgram) {
        structuralCount = program.variables.count
        rowCount = program.rows.count
        columnCount = structuralCount + rowCount

        var lower = [Double](repeating: 0, count: columnCount)
        var upper = [Double](repeating: 0, count: columnCount)
        var objective = [Double](repeating: 0, count: columnCount)
        for (index, variable) in program.variables.enumerated() {
            lower[index] = variable.lower
            upper[index] = variable.upper
            objective[index] = variable.objective
        }
        for (rowIndex, row) in program.rows.enumerated() {
            lower[structuralCount + rowIndex] = row.lower
            upper[structuralCount + rowIndex] = row.upper
        }
        lowerBound = lower
        upperBound = upper
        cost = objective

        var columns = [[(row: Int, value: Double)]](repeating: [], count: columnCount)
        for (rowIndex, row) in program.rows.enumerated() {
            for (index, coefficient) in zip(row.indices, row.coefficients) {
                columns[index].append((rowIndex, coefficient))
            }
            columns[structuralCount + rowIndex].append((rowIndex, -1))
        }
        originalColumns = columns

        // T = B⁻¹A' with B = −I: structural columns are negated, logical columns become +I.
        tableau = [Double](repeating: 0, count: rowCount * columnCount)
        for (rowIndex, row) in program.rows.enumerated() {
            let start = rowIndex * columnCount
            for (index, coefficient) in zip(row.indices, row.coefficients) {
                tableau[start + index] = -coefficient
            }
            tableau[start + structuralCount + rowIndex] = 1
        }

        var initialBasis = [Int](repeating: 0, count: rowCount)
        for index in 0..<rowCount { initialBasis[index] = structuralCount + index }
        basis = initialBasis
        isBasic = [Bool](repeating: false, count: columnCount)
        for index in initialBasis { isBasic[index] = true }

        // Dual feasibility of the starting basis: a variable with a positive cost belongs on its
        // lower bound, one with a negative cost on its upper bound.
        isAtUpper = [Bool](repeating: false, count: columnCount)
        for index in 0..<structuralCount where objective[index] < 0 {
            isAtUpper[index] = true
        }

        nonbasicValue = [Double](repeating: 0, count: columnCount)
        basicValue = [Double](repeating: 0, count: rowCount)
        reducedCost = objective
        infeasibilitySign = [Double](repeating: 0, count: rowCount)
        phaseOneCost = [Double](repeating: 0, count: columnCount)

        // A rebuild costs about `rows² × columns` and a pivot about `rows × columns`, so rebuilding
        // every `k` pivots adds a factor of `rows / k` to the work. Scaling the interval down as the
        // model grows keeps that overhead roughly flat instead of letting a large tableau either
        // drift for thousands of pivots or spend all its time being rebuilt.
        refactorisationInterval = min(600, max(150, 120_000 / max(1, rowCount)))
        refreshPrimalValues()
    }

    // MARK: - Bounds

    func lower(of variable: Int) -> Double { lowerBound[variable] }
    func upper(of variable: Int) -> Double { upperBound[variable] }

    /// Tightens or restores a variable's bounds. Callers refresh primal values once per batch of
    /// changes rather than once per change.
    func setBounds(of variable: Int, lower: Double, upper: Double) {
        lowerBound[variable] = lower
        upperBound[variable] = upper
    }

    /// Recomputes every nonbasic value from its current bound and the basic values from the
    /// tableau. Cheap, and the only thing a bound change invalidates.
    func refreshPrimalValues() {
        var activeColumns: [Int] = []
        activeColumns.reserveCapacity(columnCount - rowCount)
        for column in 0..<columnCount where !isBasic[column] {
            var value = isAtUpper[column] ? upperBound[column] : lowerBound[column]
            if !value.isFinite {
                isAtUpper[column].toggle()
                value = isAtUpper[column] ? upperBound[column] : lowerBound[column]
            }
            nonbasicValue[column] = value.isFinite ? value : 0
            if nonbasicValue[column] != 0 { activeColumns.append(column) }
        }

        for rowIndex in 0..<rowCount {
            let start = rowIndex * columnCount
            var sum = 0.0
            for column in activeColumns {
                sum -= tableau[start + column] * nonbasicValue[column]
            }
            basicValue[rowIndex] = sum
        }
    }

    /// Rebuilds the reduced costs from the basis, so drift cannot accumulate over a long search.
    private func refreshReducedCosts() {
        reducedCost = cost
        for rowIndex in 0..<rowCount {
            let basicCost = cost[basis[rowIndex]]
            if basicCost == 0 { continue }
            let start = rowIndex * columnCount
            for column in 0..<columnCount {
                reducedCost[column] -= basicCost * tableau[start + column]
            }
        }
        for index in basis { reducedCost[index] = 0 }
    }

    // MARK: - Refactorisation

    /// Rebuilds `B⁻¹A'` from the current basis and the original matrix by Gauss-Jordan elimination
    /// with partial pivoting, discarding everything the in-place updates have accumulated.
    ///
    /// A basis can also go singular through round-off. When a basis column has no usable pivot left
    /// it is swapped for the logical of a row that has not been pivoted yet — a unit column, so the
    /// repaired basis is guaranteed non-singular — and the elimination is restarted once.
    @discardableResult
    private func refactorise() -> Bool {
        for attempt in 0..<2 {
            var work = [Double](repeating: 0, count: rowCount * columnCount)
            for column in 0..<columnCount {
                for entry in originalColumns[column] {
                    work[entry.row * columnCount + column] = entry.value
                }
            }

            var pivotRowUsed = [Bool](repeating: false, count: rowCount)
            var rowOfBasis = [Int](repeating: -1, count: rowCount)
            var singularPositions: [Int] = []

            for position in 0..<rowCount {
                let column = basis[position]
                var chosen = -1
                var best = 1e-9
                for row in 0..<rowCount where !pivotRowUsed[row] {
                    let magnitude = abs(work[row * columnCount + column])
                    if magnitude > best {
                        best = magnitude
                        chosen = row
                    }
                }
                guard chosen >= 0 else {
                    singularPositions.append(position)
                    continue
                }
                pivotRowUsed[chosen] = true
                rowOfBasis[position] = chosen

                let start = chosen * columnCount
                let inverse = 1 / work[start + column]
                for index in start..<(start + columnCount) { work[index] *= inverse }
                work[start + column] = 1
                for row in 0..<rowCount where row != chosen {
                    let otherStart = row * columnCount
                    let factor = work[otherStart + column]
                    if factor == 0 { continue }
                    for offset in 0..<columnCount {
                        work[otherStart + offset] -= factor * work[start + offset]
                    }
                    work[otherStart + column] = 0
                }
            }

            if !singularPositions.isEmpty {
                guard attempt == 0 else { return false }
                var spareRows = (0..<rowCount).filter { !pivotRowUsed[$0] }
                for position in singularPositions {
                    guard let row = spareRows.popLast() else { return false }
                    let replaced = basis[position]
                    isBasic[replaced] = false
                    // Park the displaced variable on the bound its reduced cost prefers.
                    isAtUpper[replaced] = reducedCost[replaced] < 0 && upperBound[replaced].isFinite
                    let logical = structuralCount + row
                    basis[position] = logical
                    isBasic[logical] = true
                }
                continue
            }

            // Permute the eliminated rows so that row `k` is the one `basis[k]` is basic in.
            var rebuilt = [Double](repeating: 0, count: rowCount * columnCount)
            for position in 0..<rowCount {
                let source = rowOfBasis[position] * columnCount
                let destination = position * columnCount
                for offset in 0..<columnCount {
                    rebuilt[destination + offset] = work[source + offset]
                }
            }
            tableau = rebuilt
            refreshPrimalValues()
            refreshReducedCosts()
            pivotsSinceRefactorisation = 0
            pivotsSinceRefresh = 0
            needsRefactorisation = false
            return true
        }
        return false
    }

    private func maintain() {
        if needsRefactorisation || pivotsSinceRefactorisation >= refactorisationInterval {
            refactorise()
            return
        }
        if pivotsSinceRefresh >= 64 {
            pivotsSinceRefresh = 0
            refreshPrimalValues()
            refreshReducedCosts()
        }
    }

    // MARK: - Re-optimisation entry point

    /// Re-optimises after bounds changed. Tries the dual method, which is cheap from an inherited
    /// basis, and falls back to a full primal solve when the dual stalls or when its conclusion
    /// cannot be trusted because the basis has drifted out of dual feasibility.
    func reoptimize(deadline: ContinuousClock.Instant?, dualIterationLimit: Int = 400) -> Status {
        refreshPrimalValues()
        let status = solveDual(iterationLimit: dualIterationLimit, deadline: deadline)
        switch status {
        case .optimal, .infeasible:
            // Both conclusions are only sound from a dual-feasible basis. Verify rather than trust:
            // a wrong "infeasible" silently deletes part of the branch-and-bound tree.
            if maximumDualInfeasibility <= 1e-6 { return status }
            refactorise()
            if maximumDualInfeasibility <= 1e-6, status == .optimal, maximumPrimalInfeasibility <= tolerances.primalFeasibility {
                return .optimal
            }
            return solvePrimal(deadline: deadline)
        case .iterationLimit, .numericalFailure:
            return solvePrimal(deadline: deadline)
        case .timeLimit:
            return .timeLimit
        }
    }

    // MARK: - Primal method

    /// Phase 1 drives the basis to primal feasibility by minimising total bound infeasibility;
    /// phase 2 then optimises the real objective.
    func solvePrimal(iterationLimit: Int = 200_000, deadline: ContinuousClock.Instant? = nil) -> Status {
        var budget = iterationLimit
        let phaseOne = runPrimalPhaseOne(iterationLimit: &budget, deadline: deadline)
        guard phaseOne == .optimal else { return phaseOne }
        refreshReducedCosts()
        return runPrimalPhaseTwo(iterationLimit: &budget, deadline: deadline)
    }

    /// Total amount by which basic variables sit outside their bounds, and the per-row direction.
    private func updateInfeasibility() -> Double {
        var total = 0.0
        let tolerance = tolerances.primalFeasibility
        for rowIndex in 0..<rowCount {
            let variable = basis[rowIndex]
            let value = basicValue[rowIndex]
            if value < lowerBound[variable] - tolerance {
                infeasibilitySign[rowIndex] = -1
                total += lowerBound[variable] - value
            } else if value > upperBound[variable] + tolerance {
                infeasibilitySign[rowIndex] = 1
                total += value - upperBound[variable]
            } else {
                infeasibilitySign[rowIndex] = 0
            }
        }
        return total
    }

    private func runPrimalPhaseOne(iterationLimit: inout Int, deadline: ContinuousClock.Instant?) -> Status {
        var stalledIterations = 0
        var bestInfeasibility = Double.infinity

        while true {
            if iterationLimit <= 0 { return .iterationLimit }
            if iterationCount & 0x3F == 0, let deadline, ContinuousClock.now >= deadline { return .timeLimit }
            maintain()

            let infeasibility = updateInfeasibility()
            if infeasibility <= tolerances.primalFeasibility { return .optimal }

            if infeasibility < bestInfeasibility - 1e-9 {
                bestInfeasibility = infeasibility
                stalledIterations = 0
            } else {
                stalledIterations += 1
                if stalledIterations == 60, !needsRefactorisation, pivotsSinceRefactorisation > 0 {
                    // A stall is often drift rather than genuine degeneracy. Rebuild once, cheaply,
                    // before falling back to the slow anti-cycling rule.
                    refactorise()
                    continue
                }
            }

            // Phase-1 reduced cost: ∂(total infeasibility)/∂z_j = −Σ_i σ_i · α_ij.
            for column in 0..<columnCount { phaseOneCost[column] = 0 }
            for rowIndex in 0..<rowCount {
                let sign = infeasibilitySign[rowIndex]
                if sign == 0 { continue }
                let start = rowIndex * columnCount
                for column in 0..<columnCount {
                    phaseOneCost[column] -= sign * tableau[start + column]
                }
            }

            guard let entering = chooseEnteringColumn(
                costs: phaseOneCost,
                useBland: stalledIterations > 200
            ) else {
                // No improving direction while still infeasible: the LP has no feasible point.
                // The phase-1 objective is convex, so a local statement here is a global one.
                return .infeasible
            }

            guard step(entering: entering, allowsInfeasibleBasics: true) else { return .numericalFailure }
            iterationLimit -= 1
        }
    }

    private func runPrimalPhaseTwo(iterationLimit: inout Int, deadline: ContinuousClock.Instant?) -> Status {
        var stalledIterations = 0
        var bestObjective = Double.infinity

        while true {
            if iterationLimit <= 0 { return .iterationLimit }
            if iterationCount & 0x3F == 0, let deadline, ContinuousClock.now >= deadline { return .timeLimit }
            maintain()

            let current = objectiveValue
            if current < bestObjective - 1e-9 {
                bestObjective = current
                stalledIterations = 0
            } else {
                stalledIterations += 1
            }

            guard let entering = chooseEnteringColumn(
                costs: reducedCost,
                useBland: stalledIterations > 200
            ) else {
                return .optimal
            }
            guard step(entering: entering, allowsInfeasibleBasics: false) else { return .numericalFailure }
            iterationLimit -= 1
        }
    }

    /// Dantzig pricing, with Bland's smallest-index rule as an anti-cycling fallback.
    private func chooseEnteringColumn(costs: [Double], useBland: Bool) -> Int? {
        let tolerance = tolerances.dualFeasibility
        var best: Int?
        var bestMagnitude = tolerance

        for column in 0..<columnCount {
            if isBasic[column] { continue }
            if lowerBound[column] >= upperBound[column] { continue }
            let value = costs[column]
            // A nonbasic variable may only move away from the bound it rests on.
            let improves = isAtUpper[column] ? value > tolerance : value < -tolerance
            if !improves { continue }
            if useBland { return column }
            if abs(value) > bestMagnitude {
                bestMagnitude = abs(value)
                best = column
            }
        }
        return best
    }

    /// Primal ratio test and pivot (or bound flip) for the chosen entering column.
    ///
    /// `allowsInfeasibleBasics` distinguishes the two phases. In phase 1 a basic variable that is
    /// already outside its bounds is limited only by the bound it is moving *towards* — reaching it
    /// makes that variable feasible and is a breakpoint of the piecewise-linear phase-1 objective.
    /// In phase 2 every basic variable is inside its box and must stay there.
    ///
    /// The test runs in two passes, after Harris: the first finds the smallest step allowing each
    /// basic variable a tolerance-sized excursion past its bound, the second takes the largest
    /// pivot among the candidates that fit within it. Picking the numerically strongest of several
    /// near-equivalent pivots is what keeps a dense tableau usable over thousands of iterations.
    private func step(entering: Int, allowsInfeasibleBasics: Bool) -> Bool {
        let direction: Double = isAtUpper[entering] ? -1 : 1
        let flipLimit = upperBound[entering] - lowerBound[entering]

        var largestMagnitude = 0.0
        for rowIndex in 0..<rowCount {
            largestMagnitude = max(largestMagnitude, abs(tableau[rowIndex * columnCount + entering]))
        }
        let pivotFloor = max(tolerances.pivot, tolerances.relativePivot * largestMagnitude)

        ratioCandidates.removeAll(keepingCapacity: true)
        let relaxation = tolerances.primalFeasibility
        var relaxedLimit = flipLimit

        for rowIndex in 0..<rowCount {
            let coefficient = tableau[rowIndex * columnCount + entering] * direction
            if abs(coefficient) <= pivotFloor { continue }
            // The basic variable moves by −coefficient per unit of step.
            let rate = -coefficient
            let variable = basis[rowIndex]
            let value = basicValue[rowIndex]
            let sign = allowsInfeasibleBasics ? infeasibilitySign[rowIndex] : 0

            var slack = Double.infinity
            var reachesUpper = false
            if sign < 0 {
                if rate > 0 { slack = (lowerBound[variable] - value) / rate }
            } else if sign > 0 {
                if rate < 0 { slack = (upperBound[variable] - value) / rate; reachesUpper = true }
            } else if rate > 0 {
                if upperBound[variable].isFinite {
                    slack = (upperBound[variable] - value) / rate
                    reachesUpper = true
                }
            } else if lowerBound[variable].isFinite {
                slack = (lowerBound[variable] - value) / rate
            }
            if !slack.isFinite { continue }
            let ratio = max(0, slack)
            ratioCandidates.append((rowIndex, ratio, abs(coefficient), reachesUpper))
            relaxedLimit = min(relaxedLimit, ratio + relaxation / abs(coefficient))
        }

        var leavingRow = -1
        var leavingAtUpper = false
        var chosenRatio = flipLimit
        var chosenMagnitude = 0.0
        for candidate in ratioCandidates where candidate.ratio <= relaxedLimit {
            if candidate.magnitude > chosenMagnitude {
                chosenMagnitude = candidate.magnitude
                leavingRow = candidate.row
                leavingAtUpper = candidate.reachesUpper
                chosenRatio = candidate.ratio
            }
        }
        if leavingRow >= 0, flipLimit < chosenRatio {
            leavingRow = -1 // the entering variable reaches its own opposite bound first
        }

        let limit = leavingRow >= 0 ? chosenRatio : flipLimit
        if !limit.isFinite { return false } // unbounded improving ray

        let move = direction * limit
        if leavingRow < 0 {
            // Bound flip: the entering variable travels the whole way to its other bound.
            if move != 0 {
                for rowIndex in 0..<rowCount {
                    let coefficient = tableau[rowIndex * columnCount + entering]
                    if coefficient != 0 { basicValue[rowIndex] -= coefficient * move }
                }
            }
            isAtUpper[entering].toggle()
            nonbasicValue[entering] = isAtUpper[entering] ? upperBound[entering] : lowerBound[entering]
            iterationCount += 1
            return true
        }

        let leaving = basis[leavingRow]
        let bound = leavingAtUpper ? upperBound[leaving] : lowerBound[leaving]
        guard bound.isFinite else { return false }
        performPivot(
            row: leavingRow,
            column: entering,
            step: move,
            leavingBound: bound,
            leavingAtUpper: leavingAtUpper
        )
        return true
    }

    // MARK: - Dual method

    func solveDual(iterationLimit: Int = 100_000, deadline: ContinuousClock.Instant? = nil) -> Status {
        var iterationsHere = 0
        while true {
            if iterationsHere >= iterationLimit { return .iterationLimit }
            if iterationsHere & 0x3F == 0, let deadline, ContinuousClock.now >= deadline { return .timeLimit }
            maintain()

            guard let leaving = chooseLeavingRow() else { return .optimal }
            guard let entering = chooseDualEnteringColumn(row: leaving.row, movesToUpper: leaving.movesToUpper) else {
                return .infeasible
            }
            let pivotElement = tableau[leaving.row * columnCount + entering]
            guard abs(pivotElement) > tolerances.pivot, leaving.target.isFinite else { return .numericalFailure }

            performPivot(
                row: leaving.row,
                column: entering,
                step: (basicValue[leaving.row] - leaving.target) / pivotElement,
                leavingBound: leaving.target,
                leavingAtUpper: leaving.movesToUpper
            )
            iterationsHere += 1
        }
    }

    private struct LeavingChoice {
        var row: Int
        var target: Double
        var movesToUpper: Bool
    }

    /// Dual pricing: the basic variable that violates a bound by the most.
    private func chooseLeavingRow() -> LeavingChoice? {
        var best: LeavingChoice?
        var bestViolation = tolerances.primalFeasibility
        for rowIndex in 0..<rowCount {
            let variable = basis[rowIndex]
            let value = basicValue[rowIndex]
            let below = lowerBound[variable] - value
            let above = value - upperBound[variable]
            if below > bestViolation {
                bestViolation = below
                best = LeavingChoice(row: rowIndex, target: lowerBound[variable], movesToUpper: false)
            }
            if above > bestViolation {
                bestViolation = above
                best = LeavingChoice(row: rowIndex, target: upperBound[variable], movesToUpper: true)
            }
        }
        return best
    }

    /// Dual ratio test. `movesToUpper` means the leaving variable sits above its upper bound, so
    /// the row value has to come down; otherwise it is below its lower bound and has to come up.
    ///
    /// A row's basic value depends on a nonbasic `j` as `∂x_B[r]/∂z_j = −α_rj`, and a nonbasic
    /// variable may only move away from the bound it rests on. Those two facts fix the admissible
    /// sign of `α_rj` in each of the four cases.
    private func chooseDualEnteringColumn(row: Int, movesToUpper: Bool) -> Int? {
        let start = row * columnCount
        var largestMagnitude = 0.0
        for column in 0..<columnCount where !isBasic[column] {
            largestMagnitude = max(largestMagnitude, abs(tableau[start + column]))
        }
        let pivotFloor = max(tolerances.pivot, tolerances.relativePivot * largestMagnitude)

        var bestColumn: Int?
        var bestRatio = Double.infinity
        var bestMagnitude = 0.0

        for column in 0..<columnCount {
            if isBasic[column] { continue }
            if lowerBound[column] >= upperBound[column] { continue }
            let alpha = tableau[start + column]
            if abs(alpha) <= pivotFloor { continue }

            let admissible: Bool
            if movesToUpper {
                admissible = isAtUpper[column] ? alpha < 0 : alpha > 0
            } else {
                admissible = isAtUpper[column] ? alpha > 0 : alpha < 0
            }
            if !admissible { continue }

            let ratio = abs(reducedCost[column]) / abs(alpha)
            let magnitude = abs(alpha)
            // Smallest ratio; among near-ties take the largest pivot, for numerical stability.
            if ratio < bestRatio - 1e-9 || (ratio < bestRatio + 1e-9 && magnitude > bestMagnitude) {
                bestRatio = ratio
                bestMagnitude = magnitude
                bestColumn = column
            }
        }
        return bestColumn
    }

    // MARK: - Pivoting

    private func performPivot(row: Int, column: Int, step: Double, leavingBound: Double, leavingAtUpper: Bool) {
        let start = row * columnCount
        let pivotElement = tableau[start + column]
        if abs(pivotElement) < 1e-6 { needsRefactorisation = true }
        let leaving = basis[row]
        let enteringValue = nonbasicValue[column] + step

        // Basic values move with the entering variable, using the pre-pivot column.
        if step != 0 {
            for otherRow in 0..<rowCount where otherRow != row {
                let coefficient = tableau[otherRow * columnCount + column]
                if coefficient != 0 { basicValue[otherRow] -= coefficient * step }
            }
        }

        // Eliminate the entering column from every other row.
        let inverse = 1 / pivotElement
        for index in start..<(start + columnCount) {
            tableau[index] *= inverse
        }
        tableau[start + column] = 1
        for otherRow in 0..<rowCount where otherRow != row {
            let otherStart = otherRow * columnCount
            let factor = tableau[otherStart + column]
            if factor == 0 { continue }
            for offset in 0..<columnCount {
                tableau[otherStart + offset] -= factor * tableau[start + offset]
            }
            tableau[otherStart + column] = 0
        }

        // d_j ← d_j − d_q·α'_rj also produces the correct value for the leaving variable, whose
        // pre-pivot column was the unit vector e_r.
        let enteringCost = reducedCost[column]
        if enteringCost != 0 {
            for offset in 0..<columnCount {
                reducedCost[offset] -= enteringCost * tableau[start + offset]
            }
        }
        reducedCost[column] = 0

        isBasic[leaving] = false
        nonbasicValue[leaving] = leavingBound
        isAtUpper[leaving] = leavingAtUpper
        isBasic[column] = true
        basis[row] = column
        basicValue[row] = enteringValue
        iterationCount += 1
        pivotsSinceRefactorisation += 1
        pivotsSinceRefresh += 1
    }

    // MARK: - Reading the point

    func value(ofStructural index: Int) -> Double {
        if isBasic[index] {
            for rowIndex in 0..<rowCount where basis[rowIndex] == index {
                return basicValue[rowIndex]
            }
        }
        return nonbasicValue[index]
    }

    /// The structural part of the current point, clamped into its bounds so that round-off cannot
    /// report a package a nanometre outside the module.
    func structuralValues() -> [Double] {
        var values = [Double](repeating: 0, count: structuralCount)
        for index in 0..<structuralCount where !isBasic[index] {
            values[index] = nonbasicValue[index]
        }
        for rowIndex in 0..<rowCount {
            let variable = basis[rowIndex]
            if variable < structuralCount {
                values[variable] = basicValue[rowIndex]
            }
        }
        for index in 0..<structuralCount {
            values[index] = min(max(values[index], lowerBound[index]), upperBound[index])
        }
        return values
    }

    var objectiveValue: Double {
        var total = 0.0
        for index in 0..<structuralCount where cost[index] != 0 {
            total += cost[index] * value(ofStructural: index)
        }
        return total
    }

    /// Largest amount by which any basic variable sits outside its bounds.
    var maximumPrimalInfeasibility: Double {
        var worst = 0.0
        for rowIndex in 0..<rowCount {
            let variable = basis[rowIndex]
            let value = basicValue[rowIndex]
            worst = max(worst, lowerBound[variable] - value, value - upperBound[variable])
        }
        return max(worst, 0)
    }

    /// Largest violation of the dual-feasibility sign condition. Zero means the current point is
    /// a genuine LP optimum whenever it is also primal feasible.
    var maximumDualInfeasibility: Double {
        var worst = 0.0
        for column in 0..<columnCount {
            if isBasic[column] { continue }
            if lowerBound[column] >= upperBound[column] { continue }
            let value = reducedCost[column]
            worst = max(worst, isAtUpper[column] ? value : -value)
        }
        return max(worst, 0)
    }
}
