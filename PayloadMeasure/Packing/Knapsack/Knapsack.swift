import Foundation
import simd

// Knapsack, packages, placements and the feasibility rules.
//
// A packing is feasible when every package is inside the container, no two overlap, every package
// above the floor has its whole bottom face supported, and the cargo centre of mass lies inside
// the target domain. Based on Baldi et al.

nonisolated enum BaldiPackingMode: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    /// Stop as soon as the centre of mass reaches the domain, moving packages only locally.
    case paper
    /// Keep going afterwards, relocating packages anywhere legal to pull the centre of mass in.
    case centred

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper: "Paper"
        case .centred: "Centred"
        }
    }
}

nonisolated struct BaldiItem: Sendable, Identifiable {
    var id: UUID
    var name: String
    var size: SIMD3<Int>
    var mass: Double
    /// The object is already a box. Only used by the loading guide (no opening line is drawn); the
    /// solver ignores it.
    var isOwnBox: Bool = false

    /// All packages are worth the same, so the objective is the number loaded.
    var profit: Double { 1 }

    var volume: Int { size.x * size.y * size.z }
    var specificWeight: Double { volume > 0 ? mass / Double(volume) : 0 }
    var area: Int { size.x * size.y }
}

nonisolated struct BaldiKnapsack: Sendable, Equatable {
    var size: SIMD3<Int>
    var domainLower: SIMD3<Double>
    var domainUpper: SIMD3<Double>

    var volume: Int { size.x * size.y * size.z }
    var idealCentreOfMass: SIMD3<Double> { (domainLower + domainUpper) / 2 }

    init(size: SIMD3<Int>) {
        self.size = size
        let domain = BaldiKnapsack.standardDomain(size: size)
        self.domainLower = domain.lower
        self.domainUpper = domain.upper
    }

    init(size: SIMD3<Int>, domainLower: SIMD3<Double>, domainUpper: SIMD3<Double>) {
        self.size = size
        self.domainLower = domainLower
        self.domainUpper = domainUpper
    }

    func containsCentreOfMass(_ centre: SIMD3<Double>, tolerance: Double = 1e-9) -> Bool {
        guard tolerance.isFinite, tolerance >= 0 else { return false }
        for axis in 0..<3 {
            guard centre[axis].isFinite,
                  domainLower[axis].isFinite,
                  domainUpper[axis].isFinite else { return false }
            if centre[axis] < domainLower[axis] - tolerance { return false }
            if centre[axis] > domainUpper[axis] + tolerance { return false }
        }
        return true
    }

    /// Middle half of the floor, bottom half of the height.
    static func standardDomain(size: SIMD3<Int>) -> (lower: SIMD3<Double>, upper: SIMD3<Double>) {
        let extent = SIMD3<Double>(Double(size.x), Double(size.y), Double(size.z))
        return (
            SIMD3(extent.x / 4, extent.y / 4, 0),
            SIMD3(3 * extent.x / 4, 3 * extent.y / 4, extent.z / 2)
        )
    }
}

/// One of the six axis-aligned orientations of a box.
nonisolated struct BaldiRotation: Sendable, Hashable {
    /// Which package axis ends up on each container axis.
    var sourceAxis: [Int]

    static let all: [BaldiRotation] = [
        [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
    ].map { BaldiRotation(sourceAxis: $0) }

    func size(of item: SIMD3<Int>) -> SIMD3<Int> {
        SIMD3(item[sourceAxis[0]], item[sourceAxis[1]], item[sourceAxis[2]])
    }

    /// Packages are assumed uniform, so the centre of mass is the box centre.
    func centreOfMassOffset(of item: SIMD3<Int>) -> SIMD3<Double> {
        let rotated = size(of: item)
        return SIMD3(Double(rotated.x) / 2, Double(rotated.y) / 2, Double(rotated.z) / 2)
    }

    var restingDescription: String {
        switch sourceAxis[2] {
        case 0: "on its side, width vertical"
        case 1: "on its side, depth vertical"
        default: "upright, height vertical"
        }
    }
}

nonisolated struct BaldiProblem: Sendable {
    var knapsack: BaldiKnapsack
    var items: [BaldiItem]

    /// Separates packages that don't fit in any orientation so they can be reported.
    func partitionByFit() -> (fitting: [BaldiItem], oversized: [BaldiItem]) {
        var fitting: [BaldiItem] = []
        var oversized: [BaldiItem] = []
        for item in items {
            let fits = BaldiRotation.all.contains { rotation in
                let rotated = rotation.size(of: item.size)
                return rotated.x <= knapsack.size.x
                    && rotated.y <= knapsack.size.y
                    && rotated.z <= knapsack.size.z
            }
            if fits { fitting.append(item) } else { oversized.append(item) }
        }
        return (fitting, oversized)
    }
}

// MARK: - Placements

nonisolated struct BaldiPlacement: Sendable, Identifiable {
    var id: UUID
    var name: String
    /// Bottom-left-back corner. Not integer, since balancing can move packages by fractions of a mm.
    var origin: SIMD3<Double>
    var rotation: BaldiRotation
    var size: SIMD3<Int>
    var mass: Double
    /// See `BaldiItem.isOwnBox`. The opening marker only applies to the app's own box presets.
    var isOwnBox: Bool = false

    var extent: SIMD3<Double> { SIMD3(Double(size.x), Double(size.y), Double(size.z)) }
    var maximum: SIMD3<Double> { origin + extent }
    var centreOfMass: SIMD3<Double> { origin + extent / 2 }

    func overlaps(_ other: BaldiPlacement, tolerance: Double = 1e-6) -> Bool {
        for axis in 0..<3 {
            if origin[axis] >= other.maximum[axis] - tolerance { return false }
            if other.origin[axis] >= maximum[axis] - tolerance { return false }
        }
        return true
    }
}

nonisolated struct BaldiSolution: Sendable {
    var knapsack: BaldiKnapsack
    var placements: [BaldiPlacement]
    var unloaded: [BaldiItem]

    var loadedCount: Int { placements.count }
    var profit: Double { Double(loadedCount) }
    var totalMass: Double { placements.reduce(0) { $0 + $1.mass } }

    var centreOfMass: SIMD3<Double> {
        guard !placements.isEmpty else { return .zero }
        guard placements.allSatisfy({ placement in
            placement.mass.isFinite
                && placement.mass > 0
                && placement.size.x > 0
                && placement.size.y > 0
                && placement.size.z > 0
                && placement.origin.x.isFinite
                && placement.origin.y.isFinite
                && placement.origin.z.isFinite
        }) else { return SIMD3<Double>(repeating: .nan) }
        let mass = totalMass
        guard mass.isFinite, mass > 0 else { return SIMD3<Double>(repeating: .nan) }
        var moment = SIMD3<Double>.zero
        for placement in placements {
            moment += placement.centreOfMass * placement.mass
        }
        return moment / mass
    }

    /// Tie-break in centred mode. The package count is still the main objective.
    var centreOfMassDistanceToIdeal: Double {
        guard !placements.isEmpty else { return .infinity }
        let centre = centreOfMass
        let ideal = knapsack.idealCentreOfMass
        guard centre.x.isFinite, centre.y.isFinite, centre.z.isFinite,
              ideal.x.isFinite, ideal.y.isFinite, ideal.z.isFinite else { return .infinity }
        let distance = simd_distance(centre, ideal)
        return distance.isFinite ? distance : .infinity
    }

    /// Spread of package centres around the ideal point. Reported for comparison with the paper,
    /// not used by the search.
    var unbalancingIndex: Double {
        guard loadedCount > 0 else { return 0 }
        let ideal = knapsack.idealCentreOfMass
        var total = 0.0
        for placement in placements {
            total += simd_length_squared(placement.centreOfMass - ideal)
        }
        return (total / Double(loadedCount)).squareRoot()
    }

    /// U from eq. (4) divided by the knapsack's half-diagonal, so it lies in [0, 1]. Needed because
    /// all profits are 1 here, so the raw value in mm would outweigh the package count. Our own
    /// scaling, not part of the paper.
    var normalisedUnbalancingIndex: Double {
        let extent = SIMD3<Double>(
            Double(knapsack.size.x),
            Double(knapsack.size.y),
            Double(knapsack.size.z)
        )
        let halfDiagonal = simd_length(extent) / 2
        guard halfDiagonal > 0, unbalancingIndex.isFinite else { return 0 }
        return min(unbalancingIndex / halfDiagonal, 1)
    }

    /// Baldi eq. (24): F = P - alpha * U, where P is the number of loaded packages.
    func merit(alpha: Double) -> Double {
        guard loadedCount > 0 else { return 0 }
        return profit - alpha * normalisedUnbalancingIndex
    }

    var isBalanced: Bool {
        loadedCount > 0 && knapsack.containsCentreOfMass(centreOfMass)
    }

    var isFullySupported: Bool {
        loadedCount > 0 && BaldiVerticalSupport.allFullySupported(placements)
    }
}

// MARK: - Vertical support

nonisolated struct BaldiSupportReport: Sendable {
    let packageID: UUID
    let supportedArea: Double
    let requiredArea: Double
    let supporterIDs: [UUID]
    let isFloorSupported: Bool
    let isFullySupported: Bool

    var fraction: Double {
        guard requiredArea.isFinite, requiredArea > 0, supportedArea.isFinite else { return 0 }
        return min(max(supportedArea / requiredArea, 0), 1)
    }
}

/// A package is supported when its whole bottom face rests on the floor or on packages below.
/// Contact areas are unioned, not summed, so overlaps aren't counted twice.
nonisolated enum BaldiVerticalSupport {
    /// Floating-point tolerance only.
    static let contactTolerance = 1e-6

    private struct Rectangle {
        var minX: Double
        var maxX: Double
        var minY: Double
        var maxY: Double
    }

    static func report(
        for target: BaldiPlacement,
        among placements: [BaldiPlacement],
        tolerance: Double = contactTolerance
    ) -> BaldiSupportReport {
        let requiredArea = target.extent.x * target.extent.y
        guard tolerance.isFinite, tolerance >= 0,
              requiredArea.isFinite, requiredArea > 0,
              target.origin.x.isFinite,
              target.origin.y.isFinite,
              target.origin.z.isFinite else {
            return BaldiSupportReport(
                packageID: target.id,
                supportedArea: 0,
                requiredArea: requiredArea,
                supporterIDs: [],
                isFloorSupported: false,
                isFullySupported: false
            )
        }
        let areaTolerance = max(1e-6, requiredArea * 1e-9)

        if abs(target.origin.z) <= tolerance {
            return BaldiSupportReport(
                packageID: target.id,
                supportedArea: requiredArea,
                requiredArea: requiredArea,
                supporterIDs: [],
                isFloorSupported: true,
                isFullySupported: true
            )
        }

        var rectangles: [Rectangle] = []
        var supporters: [UUID] = []
        for placement in placements where placement.id != target.id {
            guard abs(placement.maximum.z - target.origin.z) <= tolerance else { continue }
            let minX = max(placement.origin.x, target.origin.x)
            let maxX = min(placement.maximum.x, target.maximum.x)
            let minY = max(placement.origin.y, target.origin.y)
            let maxY = min(placement.maximum.y, target.maximum.y)
            guard maxX - minX > tolerance, maxY - minY > tolerance else { continue }
            rectangles.append(Rectangle(minX: minX, maxX: maxX, minY: minY, maxY: maxY))
            supporters.append(placement.id)
        }

        let supportedArea = min(unionArea(of: rectangles, tolerance: tolerance), requiredArea)
        return BaldiSupportReport(
            packageID: target.id,
            supportedArea: supportedArea,
            requiredArea: requiredArea,
            supporterIDs: supporters,
            isFloorSupported: false,
            isFullySupported: supportedArea + areaTolerance >= requiredArea
        )
    }

    static func reports(
        for placements: [BaldiPlacement],
        tolerance: Double = contactTolerance
    ) -> [BaldiSupportReport] {
        placements.map { report(for: $0, among: placements, tolerance: tolerance) }
    }

    static func allFullySupported(
        _ placements: [BaldiPlacement],
        tolerance: Double = contactTolerance
    ) -> Bool {
        reports(for: placements, tolerance: tolerance).allSatisfy(\.isFullySupported)
    }

    /// Simple sweep along x, merging y intervals per slab. Fine for the handful of rectangles here.
    private static func unionArea(of rectangles: [Rectangle], tolerance: Double) -> Double {
        guard !rectangles.isEmpty else { return 0 }
        let xCoordinates = rectangles.flatMap { [$0.minX, $0.maxX] }.sorted()
        var area = 0.0

        for index in 0..<(xCoordinates.count - 1) {
            let left = xCoordinates[index]
            let right = xCoordinates[index + 1]
            let width = right - left
            guard width > tolerance else { continue }
            let middle = (left + right) / 2

            var intervals: [(lower: Double, upper: Double)] = []
            for rectangle in rectangles where rectangle.minX < middle && middle < rectangle.maxX {
                intervals.append((lower: rectangle.minY, upper: rectangle.maxY))
            }
            intervals.sort { first, second in
                first.lower == second.lower ? first.upper < second.upper : first.lower < second.lower
            }
            guard var merged = intervals.first else { continue }

            var coveredY = 0.0
            for interval in intervals.dropFirst() {
                if interval.lower <= merged.upper {
                    merged.upper = max(merged.upper, interval.upper)
                } else {
                    coveredY += max(0, merged.upper - merged.lower)
                    merged = interval
                }
            }
            coveredY += max(0, merged.upper - merged.lower)
            area += width * coveredY
        }
        return area
    }
}

// MARK: - Verification

nonisolated struct BaldiVerification: Sendable {
    var isValid: Bool
    var violations: [String]
    var recomputedCentreOfMass: SIMD3<Double>
    var isBalanced: Bool
    var isFullySupported: Bool
    var supportReports: [BaldiSupportReport]
}

/// Checks every rule again from the placements alone, independent of the search. Results are only
/// shown if this passes.
nonisolated enum BaldiVerifier {
    static func verify(_ solution: BaldiSolution, against problem: BaldiProblem) -> BaldiVerification {
        var violations: [String] = []
        let knapsack = problem.knapsack
        let tolerance = 1e-6

        if solution.knapsack != problem.knapsack {
            violations.append("The reported container does not match the problem that was solved.")
        }
        if solution.placements.isEmpty {
            violations.append("The heuristic did not produce a non-empty packing.")
        }

        var sourceByID: [UUID: BaldiItem] = [:]
        for item in problem.items {
            if sourceByID[item.id] != nil {
                violations.append("The input contains the same package identifier more than once.")
            } else {
                sourceByID[item.id] = item
            }
        }

        for placement in solution.placements {
            guard let source = sourceByID[placement.id] else {
                violations.append("“\(placement.name)” was not present in the input problem.")
                continue
            }
            let usesAllowedRotation = BaldiRotation.all.contains(placement.rotation)
            if !usesAllowedRotation {
                violations.append("“\(placement.name)” uses a rotation outside the six allowed rotations.")
            }
            if usesAllowedRotation, placement.size != placement.rotation.size(of: source.size) {
                violations.append("“\(placement.name)” has dimensions inconsistent with its reported rotation.")
            }
            if placement.size.x <= 0 || placement.size.y <= 0 || placement.size.z <= 0 {
                violations.append("“\(placement.name)” has a non-positive reported dimension.")
            }
            if !placement.mass.isFinite || placement.mass <= 0 {
                violations.append("“\(placement.name)” has an invalid reported mass.")
            } else if !source.mass.isFinite
                || source.mass <= 0
                || abs(placement.mass - source.mass) > tolerance {
                violations.append("“\(placement.name)” has a mass inconsistent with the measured package.")
            }
            for axis in 0..<3 {
                guard placement.origin[axis].isFinite else {
                    violations.append("“\(placement.name)” has a non-finite coordinate on axis \(axis + 1).")
                    continue
                }
                if placement.origin[axis] < -tolerance {
                    violations.append("“\(placement.name)” has a negative coordinate on axis \(axis + 1).")
                }
                let overshoot = placement.maximum[axis] - Double(knapsack.size[axis])
                if overshoot > tolerance {
                    violations.append(
                        String(
                            format: "“%@” extends %.3f mm past the container on axis %d.",
                            placement.name, overshoot, axis + 1
                        )
                    )
                }
            }
        }

        for first in 0..<solution.placements.count {
            for second in (first + 1)..<solution.placements.count {
                let a = solution.placements[first]
                let b = solution.placements[second]
                if a.overlaps(b) {
                    violations.append("“\(a.name)” and “\(b.name)” overlap.")
                }
            }
        }

        let identifiers = Set(solution.placements.map(\.id))
        if identifiers.count != solution.placements.count {
            violations.append("The packing contains the same item more than once.")
        }
        let unloadedIdentifiers = Set(solution.unloaded.map(\.id))
        if unloadedIdentifiers.count != solution.unloaded.count {
            violations.append("The unloaded list contains the same item more than once.")
        }
        if !identifiers.isDisjoint(with: unloadedIdentifiers) {
            violations.append("A package is reported as both loaded and unloaded.")
        }
        if identifiers.union(unloadedIdentifiers) != Set(problem.items.map(\.id)) {
            violations.append("The loaded and unloaded packages do not exactly match the input problem.")
        }

        let supportReports = BaldiVerticalSupport.reports(for: solution.placements, tolerance: tolerance)
        let fullySupported = !solution.placements.isEmpty && supportReports.allSatisfy(\.isFullySupported)
        for report in supportReports where !report.isFullySupported {
            let name = solution.placements.first(where: { $0.id == report.packageID })?.name ?? "A package"
            violations.append(
                String(
                    format: "“%@” has only %.2f%% bottom-face support; 100%% is required.",
                    name, report.fraction * 100
                )
            )
        }

        let hasValidMasses = solution.placements.allSatisfy { $0.mass.isFinite && $0.mass > 0 }
        let mass = solution.placements.reduce(0) { $0 + $1.mass }
        let moment = solution.placements.reduce(into: SIMD3<Double>.zero) {
            $0 += $1.mass * ($1.origin + $1.extent / 2)
        }
        let hasValidTotalMass = hasValidMasses && mass.isFinite && mass > 0
        let centre = hasValidTotalMass ? moment / mass : SIMD3<Double>(repeating: .nan)
        let balanced = solution.loadedCount > 0 && hasValidTotalMass
            && knapsack.containsCentreOfMass(centre, tolerance: tolerance)
        if solution.loadedCount > 0, !balanced {
            violations.append(
                String(
                    format: "The packing centre of mass (%.1f, %.1f, %.1f) lies outside the allowable domain.",
                    centre.x, centre.y, centre.z
                )
            )
        }

        return BaldiVerification(
            isValid: violations.isEmpty,
            violations: violations,
            recomputedCentreOfMass: centre,
            isBalanced: balanced,
            isFullySupported: fullySupported,
            supportReports: supportReports
        )
    }
}
