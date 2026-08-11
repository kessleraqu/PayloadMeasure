import Foundation

// Bounded-variable simplex and branch and bound, used by the Balance arrangement.
//
// In:  a LinearProgram — variables with bounds and integrality, rows with lower/upper limits, and a
//      linear objective to minimise.
// Out: Simplex gives an optimal vertex or a status saying why not; BranchAndBound gives the best
//      integer point it found plus a dual bound, so the caller can tell proven from merely good.
//
// The tableau is dense and updated in place, which drifts, so it is rebuilt from the basis
// periodically and the ratio test prefers large pivots. Both matter on big-M rows.

nonisolated struct LinearProgram: Sendable {
    nonisolated struct Variable: Sendable {
        var name: String
        var lower: Double
        var upper: Double
        var isInteger: Bool
        var objective: Double
    }

    nonisolated struct Row: Sendable {
        var name: String
        var indices: [Int]
        var coefficients: [Double]
        var lower: Double
        var upper: Double
    }

    nonisolated struct Statistics: Sendable {
        var variableCount: Int
        var integerVariableCount: Int
        var continuousVariableCount: Int
        var rowCount: Int
        var nonZeroCount: Int
    }

    private(set) var variables: [Variable] = []
    private(set) var rows: [Row] = []

    // MARK: - Construction

    @discardableResult
    mutating func addVariable(
        name: String,
        lower: Double,
        upper: Double,
        isInteger: Bool = false,
        objective: Double = 0
    ) -> Int {
        precondition(lower <= upper, "variable \(name) has an empty domain [\(lower), \(upper)]")
        variables.append(
            Variable(
                name: name,
                lower: lower,
                upper: upper,
                isInteger: isInteger,
                objective: objective
            )
        )
        return variables.count - 1
    }

    @discardableResult
    mutating func addBinary(name: String) -> Int {
        addVariable(name: name, lower: 0, upper: 1, isInteger: true)
    }

    mutating func setObjective(_ index: Int, coefficient: Double) {
        variables[index].objective = coefficient
    }

    @discardableResult
    mutating func addRow(
        name: String,
        terms: [(Int, Double)],
        lower: Double = -.infinity,
        upper: Double = .infinity
    ) -> Int {
        precondition(lower <= upper, "row \(name) has an empty range [\(lower), \(upper)]")
        var merged: [Int: Double] = [:]
        for (index, coefficient) in terms where coefficient != 0 {
            precondition(coefficient.isFinite, "row \(name) has a non-finite coefficient")
            merged[index, default: 0] += coefficient
        }
        let ordered = merged.filter { $0.value != 0 }.sorted { $0.key < $1.key }
        rows.append(
            Row(
                name: name,
                indices: ordered.map(\.key),
                coefficients: ordered.map(\.value),
                lower: lower,
                upper: upper
            )
        )
        return rows.count - 1
    }

    @discardableResult
    mutating func addGreaterOrEqual(name: String, terms: [(Int, Double)], value: Double) -> Int {
        addRow(name: name, terms: terms, lower: value)
    }

    @discardableResult
    mutating func addLessOrEqual(name: String, terms: [(Int, Double)], value: Double) -> Int {
        addRow(name: name, terms: terms, upper: value)
    }

    @discardableResult
    mutating func addEqual(name: String, terms: [(Int, Double)], value: Double) -> Int {
        addRow(name: name, terms: terms, lower: value, upper: value)
    }

    // MARK: - Inspection

    var integerVariableIndices: [Int] {
        variables.indices.filter { variables[$0].isInteger }
    }

    var statistics: Statistics {
        let integerCount = variables.count(where: { $0.isInteger })
        return Statistics(
            variableCount: variables.count,
            integerVariableCount: integerCount,
            continuousVariableCount: variables.count - integerCount,
            rowCount: rows.count,
            nonZeroCount: rows.reduce(0) { $0 + $1.indices.count }
        )
    }

    func objectiveValue(at values: [Double]) -> Double {
        var total = 0.0
        for (index, variable) in variables.enumerated() where variable.objective != 0 {
            total += variable.objective * values[index]
        }
        return total
    }

}

nonisolated final class Simplex {
    nonisolated enum Status: Sendable, Equatable {
        case optimal
        case infeasible
        case iterationLimit
        case timeLimit
        case numericalFailure
    }

    nonisolated struct Tolerances: Sendable {
        var primalFeasibility: Double = 1e-7
        var dualFeasibility: Double = 1e-7
        var pivot: Double = 1e-9
        var relativePivot: Double = 1e-7

        init() {}
    }

    private let structuralCount: Int
    private let rowCount: Int
    private let columnCount: Int
    private let originalColumns: [[(row: Int, value: Double)]]

    private var tableau: [Double]
    private var basis: [Int]
    private var isBasic: [Bool]
    private var isAtUpper: [Bool]
    private var nonbasicValue: [Double]
    private var basicValue: [Double]
    private var reducedCost: [Double]

    private var lowerBound: [Double]
    private var upperBound: [Double]
    private let cost: [Double]

    private var infeasibilitySign: [Double]
    private var phaseOneCost: [Double]
    private var ratioCandidates: [(row: Int, ratio: Double, magnitude: Double, reachesUpper: Bool)] = []

    private(set) var iterationCount = 0
    private var pivotsSinceRefactorisation = 0
    private var pivotsSinceRefresh = 0
    private var needsRefactorisation = false
    private let refactorisationInterval: Int

    var tolerances = Tolerances()

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

        isAtUpper = [Bool](repeating: false, count: columnCount)
        for index in 0..<structuralCount where objective[index] < 0 {
            isAtUpper[index] = true
        }

        nonbasicValue = [Double](repeating: 0, count: columnCount)
        basicValue = [Double](repeating: 0, count: rowCount)
        reducedCost = objective
        infeasibilitySign = [Double](repeating: 0, count: rowCount)
        phaseOneCost = [Double](repeating: 0, count: columnCount)

        refactorisationInterval = min(600, max(150, 120_000 / max(1, rowCount)))
        refreshPrimalValues()
    }

    // MARK: - Bounds

    func lower(of variable: Int) -> Double { lowerBound[variable] }
    func upper(of variable: Int) -> Double { upperBound[variable] }

    func setBounds(of variable: Int, lower: Double, upper: Double) {
        lowerBound[variable] = lower
        upperBound[variable] = upper
    }

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
                    isAtUpper[replaced] = reducedCost[replaced] < 0 && upperBound[replaced].isFinite
                    let logical = structuralCount + row
                    basis[position] = logical
                    isBasic[logical] = true
                }
                continue
            }

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

    func reoptimize(deadline: ContinuousClock.Instant?, dualIterationLimit: Int = 400) -> Status {
        refreshPrimalValues()
        let status = solveDual(iterationLimit: dualIterationLimit, deadline: deadline)
        switch status {
        case .optimal, .infeasible:
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

    func solvePrimal(iterationLimit: Int = 200_000, deadline: ContinuousClock.Instant? = nil) -> Status {
        var budget = iterationLimit
        let phaseOne = runPrimalPhaseOne(iterationLimit: &budget, deadline: deadline)
        guard phaseOne == .optimal else { return phaseOne }
        refreshReducedCosts()
        return runPrimalPhaseTwo(iterationLimit: &budget, deadline: deadline)
    }

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
                    refactorise()
                    continue
                }
            }

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

    private func chooseEnteringColumn(costs: [Double], useBland: Bool) -> Int? {
        let tolerance = tolerances.dualFeasibility
        var best: Int?
        var bestMagnitude = tolerance

        for column in 0..<columnCount {
            if isBasic[column] { continue }
            if lowerBound[column] >= upperBound[column] { continue }
            let value = costs[column]
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

        if step != 0 {
            for otherRow in 0..<rowCount where otherRow != row {
                let coefficient = tableau[otherRow * columnCount + column]
                if coefficient != 0 { basicValue[otherRow] -= coefficient * step }
            }
        }

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

    var maximumPrimalInfeasibility: Double {
        var worst = 0.0
        for rowIndex in 0..<rowCount {
            let variable = basis[rowIndex]
            let value = basicValue[rowIndex]
            worst = max(worst, lowerBound[variable] - value, value - upperBound[variable])
        }
        return max(worst, 0)
    }

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

nonisolated struct MixedIntegerResult: Sendable {
    nonisolated enum Status: String, Sendable {
        case optimal
        case feasible
        case infeasible
        case noSolutionFound
        case numericalFailure
    }

    var status: Status
    var values: [Double]
    var objectiveValue: Double?
    var dualBound: Double
    var provenOptimal: Bool
    var nodeCount: Int
    var simplexIterationCount: Int
    var runtimeSeconds: Double
    var hitTimeLimit: Bool

    var absoluteGap: Double? {
        guard let objectiveValue, dualBound.isFinite else { return nil }
        return max(0, objectiveValue - dualBound)
    }

    var relativeGap: Double? {
        guard let objectiveValue, let absoluteGap else { return nil }
        return abs(objectiveValue) > 1e-10 ? absoluteGap / abs(objectiveValue) : 0
    }
}

nonisolated final class BranchAndBound {
    nonisolated struct Options: Sendable {
        var timeLimitSeconds: Double = 8
        var nodeLimit: Int = 200_000
        var integralityTolerance: Double = 1e-6
        var cutOffTolerance: Double = 1e-6
        var objectiveLowerBound: Double = 0
        var branchingPriority: [Int] = []

        init() {}
    }

    private let program: LinearProgram
    private let options: Options
    private let simplex: Simplex
    private let integerIndices: [Int]

    private var incumbentValue = Double.infinity
    private var incumbentValues: [Double]?
    private var abandonedBound = Double.infinity
    private var exploredEverything = true
    private var nodeCount = 0
    private var deadline: ContinuousClock.Instant = .now
    private var hitTimeLimit = false

    init(program: LinearProgram, options: Options = Options()) {
        self.program = program
        self.options = options
        self.simplex = Simplex(program: program)
        self.integerIndices = program.integerVariableIndices
    }

    func solve() -> MixedIntegerResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        deadline = startedAt.advanced(by: .seconds(options.timeLimitSeconds))

        search()

        let runtime = Double((clock.now - startedAt).components.seconds)
            + Double((clock.now - startedAt).components.attoseconds) * 1e-18

        let status: MixedIntegerResult.Status
        var dualBound: Double
        if let value = incumbentValues, !value.isEmpty {
            if exploredEverything {
                status = .optimal
                dualBound = incumbentValue
            } else {
                status = .feasible
                dualBound = min(abandonedBound, incumbentValue)
            }
        } else if exploredEverything {
            status = .infeasible
            dualBound = .infinity
        } else {
            status = .noSolutionFound
            dualBound = abandonedBound
        }
        if dualBound.isFinite {
            dualBound = max(dualBound, options.objectiveLowerBound)
        }

        return MixedIntegerResult(
            status: status,
            values: incumbentValues ?? [],
            objectiveValue: incumbentValues == nil ? nil : incumbentValue,
            dualBound: dualBound,
            provenOptimal: exploredEverything && incumbentValues != nil,
            nodeCount: nodeCount,
            simplexIterationCount: simplex.iterationCount,
            runtimeSeconds: runtime,
            hitTimeLimit: hitTimeLimit
        )
    }

    // MARK: - Search

    private func abandon(bound: Double) {
        exploredEverything = false
        abandonedBound = min(abandonedBound, bound)
    }

    private struct Frame {
        var variable: Int
        var savedLower: Double
        var savedUpper: Double
        var bound: Double
        var children: [(lower: Double, upper: Double)]
        var nextChild: Int
    }

    private enum NodeOutcome {
        case closed
        case branch(Frame)
    }

    private func search() {
        var frames: [Frame] = []
        var parentBound = options.objectiveLowerBound
        var descending = true

        while true {
            if descending {
                switch processNode(parentBound: parentBound) {
                case .branch(var frame):
                    let child = frame.children[frame.nextChild]
                    frame.nextChild += 1
                    simplex.setBounds(of: frame.variable, lower: child.lower, upper: child.upper)
                    parentBound = frame.bound
                    frames.append(frame)
                    continue
                case .closed:
                    descending = false
                }
            }

            while var frame = frames.last {
                let exhausted = frame.nextChild >= frame.children.count
                let dominated = frame.bound >= incumbentValue - options.cutOffTolerance
                if exhausted || dominated {
                    simplex.setBounds(of: frame.variable, lower: frame.savedLower, upper: frame.savedUpper)
                    frames.removeLast()
                    continue
                }
                let child = frame.children[frame.nextChild]
                frame.nextChild += 1
                simplex.setBounds(of: frame.variable, lower: child.lower, upper: child.upper)
                parentBound = frame.bound
                frames[frames.count - 1] = frame
                descending = true
                break
            }

            if !descending { return }
        }
    }

    private func processNode(parentBound: Double) -> NodeOutcome {
        if Task.isCancelled {
            abandon(bound: parentBound)
            return .closed
        }
        if ContinuousClock.now >= deadline {
            hitTimeLimit = true
            abandon(bound: parentBound)
            return .closed
        }
        if nodeCount >= options.nodeLimit {
            abandon(bound: parentBound)
            return .closed
        }
        nodeCount += 1

        let status = nodeCount == 1
            ? simplex.solvePrimal(deadline: deadline)
            : simplex.reoptimize(deadline: deadline)
        switch status {
        case .optimal:
            break
        case .infeasible:
            return .closed
        case .timeLimit:
            hitTimeLimit = true
            abandon(bound: parentBound)
            return .closed
        case .iterationLimit, .numericalFailure:
            abandon(bound: parentBound)
            return .closed
        }

        let bound = max(parentBound, simplex.objectiveValue)
        if bound >= incumbentValue - options.cutOffTolerance { return .closed }

        let values = simplex.structuralValues()
        guard let branching = selectBranchingVariable(values: values) else {
            incumbentValue = bound
            incumbentValues = values
            return .closed
        }

        let variable = branching.index
        let savedLower = simplex.lower(of: variable)
        let savedUpper = simplex.upper(of: variable)
        let floorValue = values[variable].rounded(.down)
        let ceilingValue = floorValue + 1
        let downChild = (lower: savedLower, upper: min(savedUpper, floorValue))
        let upChild = (lower: max(savedLower, ceilingValue), upper: savedUpper)

        var children = branching.fraction >= 0.5 ? [upChild, downChild] : [downChild, upChild]
        children.removeAll { $0.lower > $0.upper }
        guard !children.isEmpty else { return .closed }

        return .branch(
            Frame(
                variable: variable,
                savedLower: savedLower,
                savedUpper: savedUpper,
                bound: bound,
                children: children,
                nextChild: 0
            )
        )
    }

    private struct Branching {
        var index: Int
        var fraction: Double
    }

    private func priority(of variable: Int) -> Int {
        options.branchingPriority.indices.contains(variable) ? options.branchingPriority[variable] : 0
    }

    private func selectBranchingVariable(values: [Double]) -> Branching? {
        var best: Branching?
        var bestDistance = 0.0
        var bestPriority = Int.min
        for index in integerIndices {
            let value = values[index]
            let fraction = value - value.rounded(.down)
            let distance = min(fraction, 1 - fraction)
            if distance <= options.integralityTolerance { continue }
            let rank = priority(of: index)
            if rank > bestPriority || (rank == bestPriority && distance > bestDistance) {
                bestPriority = rank
                bestDistance = distance
                best = Branching(index: index, fraction: fraction)
            }
        }
        return best
    }

    // MARK: - Polishing

    func polishedSolution(for values: [Double]) -> (values: [Double], objectiveValue: Double)? {
        var saved: [(Int, Double, Double)] = []
        saved.reserveCapacity(integerIndices.count)
        for index in integerIndices {
            saved.append((index, simplex.lower(of: index), simplex.upper(of: index)))
            let pinned = values[index].rounded()
            simplex.setBounds(of: index, lower: pinned, upper: pinned)
        }
        defer {
            for (index, lower, upper) in saved {
                simplex.setBounds(of: index, lower: lower, upper: upper)
            }
            simplex.refreshPrimalValues()
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        guard simplex.reoptimize(deadline: deadline) == .optimal else { return nil }
        return (simplex.structuralValues(), simplex.objectiveValue)
    }
}
