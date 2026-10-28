import Foundation
import simd

// The Balance arrangement as a mixed-integer program. Every package sits on the module floor and
// positions are chosen so the centre of mass is as close as possible to the target. The solver
// decides position, orientation and relative order of each pair of packages together.
//
// PackingCuts adds valid inequalities that remove symmetric or impossible arrangements without
// changing the optimum.

// MARK: - Coordinate system

nonisolated struct PackingItem: Sendable, Identifiable {
    var id: UUID
    var name: String
    var size: SIMD3<Double>
    var massKilograms: Double
    var comOffset: SIMD3<Double> = .zero
    var horizontalClearance: Double = 0
    var verticalClearance: Double = 0
    var keepsUpright: Bool = false

    var volume: Double { size.x * size.y * size.z }

    static func axisName(_ axis: Int) -> String {
        switch axis {
        case 0: "width"
        case 1: "depth"
        default: "height"
        }
    }
}

nonisolated struct CentreOfMassEnvelope: Sendable, Equatable {
    var minimum: SIMD3<Double>
    var maximum: SIMD3<Double>

    static let unbounded = CentreOfMassEnvelope(
        minimum: SIMD3(repeating: -.infinity),
        maximum: SIMD3(repeating: .infinity)
    )

    var isUnbounded: Bool { self == .unbounded }

    func contains(_ point: SIMD3<Double>, tolerance: Double) -> Bool {
        for axis in 0..<3 {
            if point[axis] < minimum[axis] - tolerance { return false }
            if point[axis] > maximum[axis] + tolerance { return false }
        }
        return true
    }
}

nonisolated struct PayloadModule: Sendable, Equatable {
    var lengthMillimetres: Double = 600
    var widthMillimetres: Double = 200
    var heightMillimetres: Double = 100
    var minimumWallClearance: Double = 0
    var maximumPayloadMassKilograms: Double? = nil

    var emptyMassKilograms: Double = 0
    var emptyCentreOfMass: SIMD3<Double> = SIMD3(0, 0, 0)

    var airframeMassKilograms: Double = 0
    var airframeCentreOfMass: SIMD3<Double> = SIMD3(0, 0, 0)

    var targetCentreOfMass: SIMD3<Double> = SIMD3(0, 0, 0)
    var centreOfMassEnvelope: CentreOfMassEnvelope = .unbounded
    var axisWeights: SIMD3<Double> = SIMD3(1, 1, 0.5)

    var floorArea: Double { lengthMillimetres * widthMillimetres }

    var fixedMassKilograms: Double { emptyMassKilograms + airframeMassKilograms }

    var fixedMassMoment: SIMD3<Double> {
        emptyMassKilograms * emptyCentreOfMass + airframeMassKilograms * airframeCentreOfMass
    }

    static let standard = PayloadModule()
}

// MARK: - Orientations

nonisolated struct OrthogonalOrientation: Sendable, Hashable {
    var sourceAxis: [Int]
    var signs: [Double]

    func halfExtents(of size: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(size[sourceAxis[0]], size[sourceAxis[1]], size[sourceAxis[2]]) * 0.5
    }

    func rotatedOffset(of offset: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            signs[0] * offset[sourceAxis[0]],
            signs[1] * offset[sourceAxis[1]],
            signs[2] * offset[sourceAxis[2]]
        )
    }

    var keepsPackageUpright: Bool { sourceAxis[2] == 2 && signs[2] > 0 }

    var restingDescription: String {
        switch (sourceAxis[2], signs[2] > 0) {
        case (2, true): "upright"
        case (2, false): "upside down"
        case (0, _): "on its end, width vertical"
        default: "on its side, depth vertical"
        }
    }

    var alignmentDescription: String {
        "\(PackingItem.axisName(sourceAxis[0])) along the module"
    }

    var summary: String { "\(restingDescription), \(alignmentDescription)" }

    static let all: [OrthogonalOrientation] = {
        let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        var result: [OrthogonalOrientation] = []
        for permutation in permutations {
            let permutationSign = parity(of: permutation)
            for mask in 0..<8 {
                let signs = (0..<3).map { mask & (1 << $0) == 0 ? 1.0 : -1.0 }
                let determinant = permutationSign * signs.reduce(1, *)
                guard determinant > 0 else { continue }
                result.append(OrthogonalOrientation(sourceAxis: permutation, signs: signs))
            }
        }
        return result
    }()

    private static func parity(of permutation: [Int]) -> Double {
        var inversions = 0
        for first in 0..<permutation.count {
            for second in (first + 1)..<permutation.count where permutation[first] > permutation[second] {
                inversions += 1
            }
        }
        return inversions % 2 == 0 ? 1 : -1
    }
}

nonisolated struct PreparedOrientation: Sendable {
    var orientation: OrthogonalOrientation
    var halfExtents: SIMD3<Double>
    var comOffset: SIMD3<Double>

    var footprintX: Double { 2 * halfExtents.x }
    var footprintY: Double { 2 * halfExtents.y }
    var height: Double { 2 * halfExtents.z }
}

nonisolated struct PreparedItem: Sendable {
    var item: PackingItem
    var orientations: [PreparedOrientation]
    var wallClearance: Double

    var minimumHalfExtents: SIMD3<Double> {
        var result = SIMD3<Double>(repeating: .infinity)
        for prepared in orientations {
            result = simd_min(result, prepared.halfExtents)
        }
        return result
    }

    var maximumHalfExtents: SIMD3<Double> {
        var result = SIMD3<Double>(repeating: -.infinity)
        for prepared in orientations {
            result = simd_max(result, prepared.halfExtents)
        }
        return result
    }

}

// MARK: - Problem

nonisolated struct PackingProblem: Sendable {
    var module: PayloadModule
    var items: [PackingItem]
}

nonisolated struct PreparedProblem: Sendable {
    var module: PayloadModule
    var items: [PreparedItem]
    var totalItemMass: Double

    var totalSystemMass: Double { totalItemMass + module.fixedMassKilograms }
}

nonisolated struct PackingInfeasibility: Sendable, Equatable, Error {
    nonisolated enum Reason: String, Sendable {
        case packageTooLarge
        case totalFloorAreaExceeded
        case payloadMassExceeded
        case centreOfMassEnvelopeUnreachable
        case noFeasibleArrangement
        case modelTooLarge
        case timeLimitWithoutSolution
    }

    var reason: Reason
    var detail: String
}

nonisolated struct PackingValidationFailure: Sendable, Error {
    var messages: [String]
}

nonisolated enum PackingPreparation {
    static func prepare(_ problem: PackingProblem) -> Result<PreparedProblem, PackingValidationFailure> {
        var errors: [String] = []
        let module = problem.module

        if !(module.lengthMillimetres > 0) { errors.append("The module length must be greater than zero.") }
        if !(module.widthMillimetres > 0) { errors.append("The module width must be greater than zero.") }
        if !(module.heightMillimetres > 0) { errors.append("The module height must be greater than zero.") }
        if module.minimumWallClearance < 0 { errors.append("The wall clearance cannot be negative.") }
        if problem.items.isEmpty { errors.append("Add at least one measured package.") }

        var prepared: [PreparedItem] = []
        for item in problem.items {
            let label = item.name.isEmpty ? "A package" : "“\(item.name)”"
            if !(item.size.x > 0 && item.size.y > 0 && item.size.z > 0) {
                errors.append("\(label) has a non-positive dimension.")
                continue
            }
            if !(item.massKilograms > 0) {
                errors.append("\(label) has no weight. Enter its weight before arranging the load.")
                continue
            }

            let wallClearance = max(item.horizontalClearance, module.minimumWallClearance)
            var seen: Set<[Int64]> = []
            var orientations: [PreparedOrientation] = []
            for orientation in OrthogonalOrientation.all {
                if item.keepsUpright, !orientation.keepsPackageUpright { continue }
                let halfExtents = orientation.halfExtents(of: item.size)
                if 2 * halfExtents.z + 2 * item.verticalClearance > module.heightMillimetres + 1e-9 { continue }
                let offset = orientation.rotatedOffset(of: item.comOffset)
                let key = [halfExtents.x, halfExtents.y, halfExtents.z, offset.x, offset.y, offset.z]
                    .map { Int64(($0 * 1e6).rounded()) }
                guard seen.insert(key).inserted else { continue }
                orientations.append(
                    PreparedOrientation(orientation: orientation, halfExtents: halfExtents, comOffset: offset)
                )
            }

            if orientations.isEmpty {
                let shortest = min(item.size.x, min(item.size.y, item.size.z))
                errors.append(
                    item.keepsUpright
                        ? "\(label) is \(millimetres(item.size.z)) tall and must stay upright, but the module is only \(millimetres(module.heightMillimetres)) high."
                        : "\(label) does not fit under the \(millimetres(module.heightMillimetres)) module height in any orientation — its smallest dimension is \(millimetres(shortest))."
                )
                continue
            }

            prepared.append(PreparedItem(item: item, orientations: orientations, wallClearance: wallClearance))
        }

        guard errors.isEmpty else { return .failure(PackingValidationFailure(messages: errors)) }

        let totalMass = prepared.reduce(0) { $0 + $1.item.massKilograms }
        guard totalMass > 0 else {
            return .failure(PackingValidationFailure(messages: ["The combined weight of the packages must be greater than zero."]))
        }

        return .success(PreparedProblem(module: module, items: prepared, totalItemMass: totalMass))
    }

    static func detectTrivialInfeasibility(_ problem: PreparedProblem) -> PackingInfeasibility? {
        let module = problem.module

        for prepared in problem.items {
            let clearance = prepared.wallClearance
            let fits = prepared.orientations.contains { orientation in
                orientation.footprintX + 2 * clearance <= module.lengthMillimetres + 1e-9
                    && orientation.footprintY + 2 * clearance <= module.widthMillimetres + 1e-9
            }
            if !fits {
                return PackingInfeasibility(
                    reason: .packageTooLarge,
                    detail: "“\(prepared.item.name)” (\(millimetres(prepared.item.size.x)) × \(millimetres(prepared.item.size.y)) × \(millimetres(prepared.item.size.z))) does not fit on the \(millimetres(module.lengthMillimetres)) × \(millimetres(module.widthMillimetres)) module floor in any permitted orientation with its \(millimetres(clearance)) clearance."
                )
            }
        }

        if let limit = module.maximumPayloadMassKilograms, problem.totalItemMass > limit + 1e-9 {
            return PackingInfeasibility(
                reason: .payloadMassExceeded,
                detail: String(
                    format: "The packages weigh %.2f kg in total, which exceeds the module's %.2f kg payload limit.",
                    problem.totalItemMass,
                    limit
                )
            )
        }

        let inset = problem.items.map(\.wallClearance).min() ?? 0
        let usableLength = max(0, module.lengthMillimetres - 2 * inset)
        let usableWidth = max(0, module.widthMillimetres - 2 * inset)
        let usableArea = usableLength * usableWidth
        let requiredArea = problem.items.reduce(0.0) { total, prepared in
            total + (prepared.orientations.map { $0.footprintX * $0.footprintY }.min() ?? 0)
        }
        if requiredArea > usableArea + 1e-9 {
            return PackingInfeasibility(
                reason: .totalFloorAreaExceeded,
                detail: String(
                    format: "The %d packages need at least %.0f cm² of floor, but only %.0f cm² is usable.",
                    problem.items.count,
                    requiredArea / 100,
                    usableArea / 100
                )
            )
        }

        return nil
    }

    private static func millimetres(_ value: Double) -> String {
        String(format: "%.0f mm", value)
    }
}

nonisolated struct PackingModel: Sendable {
    nonisolated struct PairVariables: Sendable {
        var first: Int
        var second: Int
        var requiredClearance: Double
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

    var orientationVariables: [[Int]]
    var xVariables: [Int]
    var yVariables: [Int]
    var centreOfMassVariables: [Int]
    var deviationVariables: [Int]
    var pairs: [PairVariables]
    var positionBounds: [PositionBounds]
    var centreOfMassRange: (minimum: SIMD3<Double>, maximum: SIMD3<Double>)
    var boundingBoxVariables: [Int]?
    var appliedCuts: PackingCutCounts = PackingCutCounts()
    var branchingPriority: [Int] {
        var priorities = [Int](repeating: 0, count: program.variables.count)
        for group in orientationVariables {
            for variable in group { priorities[variable] = 1 }
        }
        return priorities
    }

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

nonisolated struct PackingStrengthening: Sendable, Equatable {
    var usesTightBigM = true
    var usesExactlyOneSeparation = true
    var usesIdenticalPackageSymmetry = true
    var usesFittingCuts = true
    var usesTransitivity = true
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
        var minimisesFootprint = false
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

        for index in 0..<count {
            let clearance = problem.items[index].wallClearance
            addGreaterOrEqual(&program, "wallXlo_\(index)", .variable(xVariables[index]) - halfExtent(index, axis: 0), -halfLength + clearance)
            addLessOrEqual(&program, "wallXhi_\(index)", .variable(xVariables[index]) + halfExtent(index, axis: 0), halfLength - clearance)
            addGreaterOrEqual(&program, "wallYlo_\(index)", .variable(yVariables[index]) - halfExtent(index, axis: 1), -halfWidth + clearance)
            addLessOrEqual(&program, "wallYhi_\(index)", .variable(yVariables[index]) + halfExtent(index, axis: 1), halfWidth - clearance)
        }

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
                    let row = body - .variable(separation[relation], bigM[relation])
                    addGreaterOrEqual(&program, "\(name)_\(first)_\(second)", row, clearance - bigM[relation])
                }

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

            var expression = Expression.variable(centre, -totalMass)
            for (index, prepared) in problem.items.enumerated() {
                let mass = prepared.item.massKilograms
                if axis == 0 { expression = expression + Expression.variable(xVariables[index], mass) }
                if axis == 1 { expression = expression + Expression.variable(yVariables[index], mass) }
                expression = expression + massOffset(index, axis: axis).scaled(by: mass)
            }
            addEqual(&program, "comDef\(axisNames[axis])", expression, -fixedMoment[axis])

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

nonisolated extension PackingModel {
    mutating func applyStrengthening(_ flags: PackingStrengthening) -> PackingInfeasibility? {
        var budget = flags.maximumAdditionalRows

        if flags.usesIdenticalPackageSymmetry {
            addIdenticalPackageSymmetry(budget: &budget)
        }
        if flags.usesFittingCuts {
            if let infeasibility = addFittingPairCuts(budget: &budget) { return infeasibility }
            addFittingTripleCuts(budget: &budget)
        }
        if flags.usesTransitivity {
            addTransitivityCuts(budget: &budget)
        }
        strengtheningWasTruncated = budget <= 0
        return nil
    }

    // MARK: - Identical packages

    private mutating func addIdenticalPackageSymmetry(budget: inout Int) {
        var classes: [String: [Int]] = [:]
        for (index, prepared) in problem.items.enumerated() {
            let item = prepared.item
            let key = [
                item.size.x, item.size.y, item.size.z,
                item.massKilograms,
                item.horizontalClearance, item.verticalClearance,
                item.comOffset.x, item.comOffset.y, item.comOffset.z,
            ]
            .map { String(format: "%.6f", $0) }
            .joined(separator: "|") + (item.keepsUpright ? "|upright" : "|free")
            classes[key, default: []].append(index)
        }

        for members in classes.values where members.count > 1 {
            for first in 0..<members.count {
                for second in (first + 1)..<members.count {
                    guard budget >= 2 else { return }
                    let a = members[first]
                    let b = members[second]
                    program.addLessOrEqual(
                        name: "symOrder_\(a)_\(b)",
                        terms: [(xVariables[a], 1), (xVariables[b], -1)],
                        value: 0
                    )
                    budget -= 1
                    appliedCuts.identicalPackageSymmetry += 1
                    if let pair = pair(a, b) {
                        program.addLessOrEqual(
                            name: "symAhead_\(a)_\(b)",
                            terms: [(pair.separation[relationIndex(pair: pair, ahead: a, axis: 0)], 1)],
                            value: 0
                        )
                        budget -= 1
                        appliedCuts.identicalPackageSymmetry += 1
                    }
                }
            }
        }
    }

    // MARK: - Fitting cuts

    private mutating func addFittingPairCuts(budget: inout Int) -> PackingInfeasibility? {
        let spans = [module.lengthMillimetres, module.widthMillimetres]

        for pairIndex in pairs.indices {
            let pair = pairs[pairIndex]
            let first = pair.first
            let second = pair.second
            var excludedAxes = 0

            for axis in 0..<2 {
                let groupsA = orientationGroups(of: first, axis: axis)
                let groupsB = orientationGroups(of: second, axis: axis)
                let required = pair.requiredClearance
                    + problem.items[first].wallClearance
                    + problem.items[second].wallClearance
                let span = spans[axis]

                var anyCombinationFits = false
                var impossible: [(a: [Int], b: [Int])] = []
                for groupA in groupsA {
                    for groupB in groupsB {
                        let needed = 2 * groupA.halfExtent + 2 * groupB.halfExtent + required
                        if needed <= span + 1e-9 {
                            anyCombinationFits = true
                        } else {
                            impossible.append((groupA.variables, groupB.variables))
                        }
                    }
                }

                let axisRelations = [pair.separation[axis * 2], pair.separation[axis * 2 + 1]]
                if !anyCombinationFits {
                    excludedAxes += 1
                    if excludedAxes == 2 {
                        return PackingInfeasibility(
                            reason: .noFeasibleArrangement,
                            detail: "“\(problem.items[first].item.name)” and “\(problem.items[second].item.name)” cannot be placed side by side along either module axis with their required clearances, so no arrangement contains both."
                        )
                    }
                    guard budget >= 1 else { continue }
                    program.addLessOrEqual(
                        name: "fitAxis\(axis)_\(first)_\(second)",
                        terms: axisRelations.map { ($0, 1.0) },
                        value: 0
                    )
                    budget -= 1
                    appliedCuts.fittingPairs += 1
                    continue
                }

                for combination in impossible {
                    guard budget >= 1 else { return nil }
                    var terms: [(Int, Double)] = axisRelations.map { ($0, 1.0) }
                    var indicators = 1 // axis indicator
                    if !combination.a.isEmpty {
                        terms.append(contentsOf: combination.a.map { ($0, 1.0) })
                        indicators += 1
                    }
                    if !combination.b.isEmpty {
                        terms.append(contentsOf: combination.b.map { ($0, 1.0) })
                        indicators += 1
                    }
                    guard indicators >= 2 else { continue }
                    program.addLessOrEqual(
                        name: "fitPair\(axis)_\(first)_\(second)_\(appliedCuts.orientedFittingPairs)",
                        terms: terms,
                        value: Double(indicators - 1)
                    )
                    budget -= 1
                    appliedCuts.orientedFittingPairs += 1
                }
            }
        }
        return nil
    }

    private mutating func addFittingTripleCuts(budget: inout Int) {
        let count = problem.items.count
        guard count >= 3 else { return }
        let spans = [module.lengthMillimetres, module.widthMillimetres]

        for first in 0..<count {
            for second in (first + 1)..<count {
                for third in (second + 1)..<count {
                    let trio = [first, second, third]
                    guard
                        let pairA = pair(first, second),
                        let pairB = pair(first, third),
                        let pairC = pair(second, third)
                    else { continue }

                    let smallestClearance = min(
                        pairA.requiredClearance,
                        min(pairB.requiredClearance, pairC.requiredClearance)
                    )
                    let smallestWallClearance = trio.map { problem.items[$0].wallClearance }.min() ?? 0

                    for axis in 0..<2 {
                        let bodies = trio.reduce(0.0) { $0 + 2 * problem.items[$1].minimumHalfExtents[axis] }
                        let needed = bodies + 2 * smallestClearance + 2 * smallestWallClearance
                        if needed <= spans[axis] + 1e-9 { continue }
                        guard budget >= 1 else { return }
                        var terms: [(Int, Double)] = []
                        for pair in [pairA, pairB, pairC] {
                            terms.append((pair.separation[axis * 2], 1))
                            terms.append((pair.separation[axis * 2 + 1], 1))
                        }
                        program.addLessOrEqual(
                            name: "fitTriple\(axis)_\(first)_\(second)_\(third)",
                            terms: terms,
                            value: 2
                        )
                        budget -= 1
                        appliedCuts.fittingTriples += 1
                    }
                }
            }
        }
    }

    // MARK: - Transitivity

    private mutating func addTransitivityCuts(budget: inout Int) {
        let count = problem.items.count
        guard count >= 3 else { return }

        for first in 0..<count {
            for second in (first + 1)..<count {
                for third in (second + 1)..<count {
                    guard
                        let pairA = pair(first, second),
                        let pairB = pair(second, third),
                        let pairC = pair(first, third)
                    else { continue }

                    for axis in 0..<2 {
                        let forward = [
                            pairA.separation[relationIndex(pair: pairA, ahead: first, axis: axis)],
                            pairB.separation[relationIndex(pair: pairB, ahead: second, axis: axis)],
                            pairC.separation[relationIndex(pair: pairC, ahead: third, axis: axis)],
                        ]
                        let backward = [
                            pairA.separation[relationIndex(pair: pairA, ahead: second, axis: axis)],
                            pairB.separation[relationIndex(pair: pairB, ahead: third, axis: axis)],
                            pairC.separation[relationIndex(pair: pairC, ahead: first, axis: axis)],
                        ]
                        for (name, cycle) in [("fwd", forward), ("bwd", backward)] {
                            guard budget >= 1 else { return }
                            program.addLessOrEqual(
                                name: "cycle\(axis)\(name)_\(first)_\(second)_\(third)",
                                terms: cycle.map { ($0, 1.0) },
                                value: 2
                            )
                            budget -= 1
                            appliedCuts.transitivity += 1
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    var module: PayloadModule { problem.module }

    func pair(_ first: Int, _ second: Int) -> PairVariables? {
        let low = min(first, second)
        let high = max(first, second)
        return pairs.first { $0.first == low && $0.second == high }
    }

    private func relationIndex(pair: PairVariables, ahead: Int, axis: Int) -> Int {
        let base = axis * 2
        return ahead == pair.first ? base : base + 1
    }

    private func orientationGroups(of index: Int, axis: Int) -> [(halfExtent: Double, variables: [Int])] {
        let prepared = problem.items[index]
        let variables = orientationVariables[index]
        var order: [Int64] = []
        var grouped: [Int64: (Double, [Int])] = [:]
        for (position, orientation) in prepared.orientations.enumerated() {
            let value = orientation.halfExtents[axis]
            let key = Int64((value * 1e6).rounded())
            if grouped[key] == nil {
                grouped[key] = (value, [])
                order.append(key)
            }
            if !variables.isEmpty {
                grouped[key]!.1.append(variables[position])
            }
        }
        return order.compactMap { grouped[$0] }.map { (halfExtent: $0.0, variables: $0.1) }
    }
}
