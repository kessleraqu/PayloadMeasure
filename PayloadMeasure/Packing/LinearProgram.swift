import Foundation

/// A solver-independent linear / mixed-integer program.
///
/// Row semantics are `lower <= sum(coefficient * variable) <= upper`, where either side may be
/// infinite and `lower == upper` is an equality. The container carries no solver state, so the
/// same program can be solved twice — once with integrality, once relaxed — to obtain a valid
/// dual bound, or written out in CPLEX LP format for inspection.
///
/// The design follows `src/solver/lpModel.js` of the browser reference implementation so that the
/// two can be compared model-for-model.
nonisolated struct LinearProgram: Sendable {
    nonisolated struct Variable: Sendable {
        var name: String
        var lower: Double
        var upper: Double
        var isInteger: Bool
        var objective: Double
    }

    /// Sparse row. `indices` and `coefficients` are parallel and hold no explicit zeros.
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

    /// Adds a row, merging duplicate variable references and dropping zero coefficients.
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

    /// Every structural variable must be boxed for the dual simplex to start from a dual-feasible
    /// all-logical basis: a nonbasic variable has to sit on a finite bound. The model builder
    /// derives all of its bounds from the container, so this is an invariant, not a limitation.
    var hasOnlyBoundedVariables: Bool {
        variables.allSatisfy { $0.lower.isFinite && $0.upper.isFinite }
    }

    func objectiveValue(at values: [Double]) -> Double {
        var total = 0.0
        for (index, variable) in variables.enumerated() where variable.objective != 0 {
            total += variable.objective * values[index]
        }
        return total
    }

    // MARK: - CPLEX LP format

    /// Writes the program in CPLEX LP format. Not used by the app at runtime; it exists so a model
    /// produced on the device can be exported and re-solved with a reference solver, which is how
    /// the Swift branch-and-bound is validated against the browser implementation.
    func lpFormat(relaxIntegers: Bool = false) -> String {
        var lines: [String] = []

        let objectiveTerms = variables.enumerated()
            .filter { $0.element.objective != 0 }
            .map { term($0.element.objective, $0.element.name) }
        lines.append("Minimize")
        lines.append(" obj: " + (objectiveTerms.isEmpty ? "0" : objectiveTerms.joined(separator: " ")))

        lines.append("Subject To")
        for row in rows where !row.indices.isEmpty {
            let body = zip(row.indices, row.coefficients)
                .map { term($1, variables[$0].name) }
                .joined(separator: " ")
            if row.lower == row.upper {
                lines.append(" \(row.name): \(body) = \(number(row.lower))")
            } else {
                if row.lower > -.infinity {
                    lines.append(" \(row.name)_lo: \(body) >= \(number(row.lower))")
                }
                if row.upper < .infinity {
                    lines.append(" \(row.name)_hi: \(body) <= \(number(row.upper))")
                }
            }
        }

        lines.append("Bounds")
        for variable in variables {
            if variable.lower == -.infinity, variable.upper == .infinity {
                lines.append(" \(variable.name) free")
            } else if variable.lower == -.infinity {
                lines.append(" -inf <= \(variable.name) <= \(number(variable.upper))")
            } else if variable.upper == .infinity {
                lines.append(" \(variable.name) >= \(number(variable.lower))")
            } else {
                lines.append(" \(number(variable.lower)) <= \(variable.name) <= \(number(variable.upper))")
            }
        }

        if !relaxIntegers {
            let binaries = variables.filter { $0.isInteger && $0.lower == 0 && $0.upper == 1 }
            let generals = variables.filter { $0.isInteger && !($0.lower == 0 && $0.upper == 1) }
            if !generals.isEmpty {
                lines.append("General")
                lines.append(" " + generals.map(\.name).joined(separator: " "))
            }
            if !binaries.isEmpty {
                lines.append("Binary")
                lines.append(" " + binaries.map(\.name).joined(separator: " "))
            }
        }

        lines.append("End")
        return lines.joined(separator: "\n") + "\n"
    }

    private func term(_ coefficient: Double, _ name: String) -> String {
        let sign = coefficient < 0 ? "-" : "+"
        let magnitude = abs(coefficient)
        return magnitude == 1 ? "\(sign) \(name)" : "\(sign) \(number(magnitude)) \(name)"
    }

    private func number(_ value: Double) -> String {
        let rounded = (value * 1e10).rounded() / 1e10
        return rounded == 0 ? "0" : String(rounded)
    }
}
