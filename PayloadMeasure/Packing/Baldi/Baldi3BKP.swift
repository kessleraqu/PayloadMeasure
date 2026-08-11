import Foundation
import simd

// MARK: - Support-aware three-dimensional knapsack heuristic
//
// Baldi, Perboli & Tadei, "The three-dimensional knapsack problem with balancing constraints",
// Applied Mathematics and Computation 218 (2012) 9802–9818, doi:10.1016/j.amc.2012.03.052.
//
// Baldi supplies the item selection, six orthogonal rotations, containment, non-overlap, Extreme
// Point construction and centre-of-mass domain. This project deliberately specialises that model:
//
//   * every item has equal value p_i = 1, so the objective is loaded-package count;
//   * every item's centre of mass is its geometric centre, as in Baldi's benchmark instances;
//   * equation (10)'s apparent rotation-index typo is corrected;
//   * equation (16) is repaired to Σ_r ρ_ir = t_i, so an unloaded item has no rotation.
//
// Junqueira, Morabito & Yamashita, "Three-dimensional container loading models with cargo
// stability and load bearing constraints", Computers & Operations Research 39 (2012) 74–85,
// equation (11), adds the condition Baldi deliberately omits: every non-floor package must have
// its complete bottom face supported by top faces in direct contact below it (`alpha = 1`). The
// continuous-coordinate evaluation is in `BaldiVerticalSupport`.
//
//   * items and knapsack are parallelepipeds;
//   * the origin of the knapsack and of every item is its bottom-left-back corner;
//   * the knapsack sits in the first octant with its origin at (0,0,0);
//   * items may rotate so that each side is parallel to an axis — |R| = 6;
//   * walls have negligible thickness, so the whole volume W·D·H is usable;
//   * knapsack and item sizes are non-negative integers.
//
// This is therefore a documented hybrid heuristic, not a 1-to-1 implementation and not an exact
// optimiser. It does not model load-bearing strength, deformation, friction, vibration or dynamic
// flight loads.

/// Selects how closely the centre-of-mass stage follows Baldi §5.2 after feasibility is reached.
nonisolated enum BaldiPackingMode: String, Sendable, Equatable, Hashable, CaseIterable, Identifiable {
    /// Stops as soon as the cargo CoM enters `[L,U]` and uses the paper-style local movement domain.
    case paper
    /// Continues with bounded static relocations toward the centre of `[L,U]`.
    case centred

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paper: "Paper"
        case .centred: "Centred"
        }
    }
}

/// One item of the 3BKP.
nonisolated struct BaldiItem: Sendable, Identifiable {
    var id: UUID
    var name: String
    /// `(w_j, d_j, h_j)` — the item's size in its own frame. Integers, per the paper's assumption.
    var size: SIMD3<Int>
    /// `m_j`.
    var mass: Double

    /// All packages have equal priority. Keeping the paper's name makes the sorting/model mapping
    /// readable while preventing UI or captured data from silently changing the objective.
    var profit: Double { 1 }

    /// `w_j · d_j · h_j`.
    var volume: Int { size.x * size.y * size.z }
    /// Specific weight `sw`, one of the three sorting attributes of paper §5.1.
    var specificWeight: Double { volume > 0 ? mass / Double(volume) : 0 }
    /// Item area, defined in paper §5.1 and Fig. 8 as the projection on the (x, y) plane.
    var area: Int { size.x * size.y }
}

/// The knapsack `K` and the balancing domain.
nonisolated struct BaldiKnapsack: Sendable, Equatable {
    /// `(S¹, S², S³) = (W, D, H)`.
    var size: SIMD3<Int>
    /// `L^δ` — lower bound of the domain the packing centre of mass must lie within.
    var domainLower: SIMD3<Double>
    /// `U^δ` — upper bound of the same domain.
    var domainUpper: SIMD3<Double>

    var volume: Int { size.x * size.y * size.z }

    /// Ideal centre-of-mass position `r⁰_CM`, used by the unbalancing index of eq. (4) and as the
    /// target of the centre-of-mass optimisation of §5.2.
    ///
    /// The paper does not state `r⁰_CM` for the 3BKP — eq. (4) refers to [2] for details. The
    /// centre of the allowable domain is used here, which is the only choice that is symmetric in
    /// the constraint the domain expresses.
    var idealCentreOfMass: SIMD3<Double> { (domainLower + domainUpper) / 2 }

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

    /// The domain used throughout the paper's own test instances, paper §6.1:
    /// `L^δ = {W/4, D/4, 0}` and `U^δ = {3W/4, 3D/4, H/2}`. The paper motivates the vertical bound
    /// by practical maritime and air cargo requirements — the centre of mass should be as near as
    /// possible to the bottom of the bin.
    static func standardDomain(size: SIMD3<Int>) -> (lower: SIMD3<Double>, upper: SIMD3<Double>) {
        let extent = SIMD3<Double>(Double(size.x), Double(size.y), Double(size.z))
        return (
            SIMD3(extent.x / 4, extent.y / 4, 0),
            SIMD3(3 * extent.x / 4, 3 * extent.y / 4, extent.z / 2)
        )
    }

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
}

/// The rotation set `R`, of cardinality 6 exactly as the paper defines it: an item may be rotated
/// so that each of its sides is parallel to an axis, which for a parallelepiped gives the six
/// assignments of `(w, d, h)` to the three knapsack axes.
///
/// The paper's `|R| = 6` — rather than the 24 proper rotations of a cuboid — is consistent with its
/// own instances, where the centre of mass of every item is at its geometric centre (paper §6.1),
/// so the 24 rotations collapse to 6 observationally distinct ones.
nonisolated struct BaldiRotation: Sendable, Hashable {
    /// `sourceAxis[δ]` is the item axis placed on knapsack axis `δ`.
    var sourceAxis: [Int]

    /// `s^δ_ir` — the size of item `i` along dimension `δ` under this rotation.
    func size(of item: SIMD3<Int>) -> SIMD3<Int> {
        SIMD3(item[sourceAxis[0]], item[sourceAxis[1]], item[sourceAxis[2]])
    }

    /// `γ^δ_ir` — the coordinate of the item's centre of mass along `δ`, measured from the item's
    /// own bottom-left-back corner.
    ///
    /// Paper §6.1: "the center of mass of each item is placed in the geometrical center of the item
    /// itself, i.e. r_CMi = {w_i/2, d_i/2, h_i/2}". The app cannot measure an internal mass
    /// distribution, so the same assumption holds here.
    func centreOfMassOffset(of item: SIMD3<Int>) -> SIMD3<Double> {
        let rotated = size(of: item)
        return SIMD3(Double(rotated.x) / 2, Double(rotated.y) / 2, Double(rotated.z) / 2)
    }

    /// Human-readable description of which item axis ends up vertical, for the placement list.
    var restingDescription: String {
        switch sourceAxis[2] {
        case 0: "on its side, width vertical"
        case 1: "on its side, depth vertical"
        default: "upright, height vertical"
        }
    }

    static let all: [BaldiRotation] = [
        [0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0],
    ].map { BaldiRotation(sourceAxis: $0) }
}

/// A 3BKP instance.
nonisolated struct BaldiProblem: Sendable {
    var knapsack: BaldiKnapsack
    var items: [BaldiItem]

    /// Items that cannot fit in the knapsack in any rotation.
    ///
    /// Removing these before the search is exact: no allowed orientation can place them inside the
    /// container. They are still reported as unloaded rather than silently discarded.
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

// MARK: - Placement and solution

/// One loaded item: its origin `χ^δ_i` (bottom-left-back corner) and its rotation.
nonisolated struct BaldiPlacement: Sendable, Identifiable {
    var id: UUID
    var name: String
    /// `χ^δ_i`. Continuous, because equation (17) makes it continuous: the paper's integrality
    /// assumption covers the knapsack and item *sizes*, not the placement coordinates. The
    /// heuristic only ever produces integral values, since every Extreme Point is a sum of integer
    /// sizes, but the MIP can and does place an item at a fractional coordinate.
    var origin: SIMD3<Double>
    var rotation: BaldiRotation
    /// `s^δ_ir`.
    var size: SIMD3<Int>
    var mass: Double

    var extent: SIMD3<Double> { SIMD3(Double(size.x), Double(size.y), Double(size.z)) }
    var maximum: SIMD3<Double> { origin + extent }

    /// `r_CMj` — this item's centre of mass in knapsack coordinates.
    var centreOfMass: SIMD3<Double> { origin + extent / 2 }

    /// True when this box and `other` share interior volume.
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
    /// Items of the instance that were not loaded.
    var unloaded: [BaldiItem]

    /// `k`, the number of loaded items (paper §2).
    var loadedCount: Int { placements.count }
    /// `P = Σ_i t_i`. With the fixed `p_i = 1`, this is the loaded-package count.
    var profit: Double { Double(loadedCount) }
    /// `M = Σ_{j∈J'} m_j`.
    var totalMass: Double { placements.reduce(0) { $0 + $1.mass } }
    var loadedVolume: Int { placements.reduce(0) { $0 + $1.size.x * $1.size.y * $1.size.z } }
    var fillRatio: Double {
        knapsack.volume > 0 ? Double(loadedVolume) / Double(knapsack.volume) : 0
    }

    /// `r_CM = Σ_{j∈J'} r_CMj · m_j / M`, eq. (2).
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

    /// Euclidean distance from the overall cargo centre of mass to the centre of the admissible
    /// domain. Package count remains the objective; centred mode uses this only as a quality
    /// tie-break between solutions that load the same number of packages. Paper mode does not.
    var centreOfMassDistanceToIdeal: Double {
        guard !placements.isEmpty else { return .infinity }
        let centre = centreOfMass
        let ideal = knapsack.idealCentreOfMass
        guard centre.x.isFinite,
              centre.y.isFinite,
              centre.z.isFinite,
              ideal.x.isFinite,
              ideal.y.isFinite,
              ideal.z.isFinite else { return .infinity }
        let distance = simd_distance(centre, ideal)
        return distance.isFinite ? distance : .infinity
    }

    /// The unbalancing index `U`, eq. (4):
    ///
    ///   U = sqrt( Σ_{j∈J'} |r_CMj − r⁰_CM|² / k )
    ///
    /// Note that this is the dispersion of the *items'* centres of mass about the ideal point, not
    /// the distance of the packing centre of mass from it. Eq. (4) is implemented as written.
    var unbalancingIndex: Double {
        guard loadedCount > 0 else { return 0 }
        let ideal = knapsack.idealCentreOfMass
        var total = 0.0
        for placement in placements {
            let delta = placement.centreOfMass - ideal
            total += simd_length_squared(delta)
        }
        return (total / Double(loadedCount)).squareRoot()
    }

    /// True when the packing centre of mass lies inside the allowable domain.
    var isBalanced: Bool {
        loadedCount > 0 && knapsack.containsCentreOfMass(centreOfMass)
    }

    /// Junqueira equation (11), specialised to complete bottom-face support (`alpha = 1`).
    var isFullySupported: Bool {
        loadedCount > 0 && BaldiVerticalSupport.allFullySupported(placements)
    }
}

// MARK: - Verification

/// Independent check of a reported packing, re-derived from the placements alone.
nonisolated struct BaldiVerification: Sendable {
    var isValid: Bool
    var violations: [String]
    var recomputedCentreOfMass: SIMD3<Double>
    var isBalanced: Bool
    var isFullySupported: Bool
    var supportReports: [BaldiSupportReport]
}

nonisolated enum BaldiGeometryCheck {
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
                violations.append("“\(placement.name)” uses a rotation outside Baldi's six allowed rotations.")
            }
            if usesAllowedRotation,
               placement.size != placement.rotation.size(of: source.size) {
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
                            format: "“%@” extends %.3f mm past the knapsack on axis %d.",
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
                    name,
                    report.fraction * 100
                )
            )
        }

        let hasValidMasses = solution.placements.allSatisfy {
            $0.mass.isFinite && $0.mass > 0
        }
        let mass = solution.placements.reduce(0) { $0 + $1.mass }
        let moment = solution.placements.reduce(into: SIMD3<Double>.zero) {
            $0 += $1.mass * ($1.origin + $1.extent / 2)
        }
        let hasValidTotalMass = hasValidMasses && mass.isFinite && mass > 0
        let centre = hasValidTotalMass
            ? moment / mass
            : SIMD3<Double>(repeating: .nan)
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
