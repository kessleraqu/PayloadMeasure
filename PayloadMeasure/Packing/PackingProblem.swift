import Foundation
import simd

// MARK: - Coordinate system
//
// The payload module frame has its origin at the centre of the module floor:
//
//   x  along the module length  (−L/2 … +L/2)   — the drone's longitudinal axis
//   y  across the module width  (−W/2 … +W/2)
//   z  upwards from the floor   (0 … H)
//
// This is the frame used by Kaluzny & Shaw and by the adaptation chapter, which is why the
// centre-of-mass target and envelope are expressed in it directly. Every length is in millimetres
// and every mass in kilograms.

/// One package to be loaded, in its own measured frame.
///
/// The axis order matches the app's measurement readout, `width × depth × height`, so
/// `size.z` is the axis the operator measured as vertical. That only matters for `keepsUpright`;
/// otherwise the model is free to choose any permitted orthogonal orientation.
nonisolated struct PackingItem: Sendable, Identifiable {
    var id: UUID
    var name: String
    /// (width, depth, height) in millimetres, in the package's own frame.
    var size: SIMD3<Double>
    var massKilograms: Double
    /// Offset of the package's centre of mass from its geometric centre, own frame, millimetres.
    var comOffset: SIMD3<Double> = .zero
    /// `s_i` — clearance this package needs to a wall and to its neighbours, millimetres.
    var horizontalClearance: Double = 0
    /// `s_i^z` — vertical clearance, millimetres. Chapter eq. (feasible orientation set).
    var verticalClearance: Double = 0
    /// When true the package may only be turned about the vertical axis: its measured top face
    /// stays up. Use for anything that must not be tipped.
    var keepsUpright: Bool = false

    var footprintArea: Double { size.x * size.y }
    var volume: Double { size.x * size.y * size.z }

    static func axisName(_ axis: Int) -> String {
        switch axis {
        case 0: "width"
        case 1: "depth"
        default: "height"
        }
    }
}

/// An allowable centre-of-mass envelope, chapter eq. (adapted COM envelope). Any side may be
/// infinite, in which case that side is not restricted.
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

/// The payload module the packages go into, plus everything the whole-aircraft centre of mass
/// needs: the module's own empty mass and centre of mass, and the airframe's.
nonisolated struct PayloadModule: Sendable, Equatable {
    /// `L_b`, along x.
    var lengthMillimetres: Double = 800
    /// `W_b`, along y.
    var widthMillimetres: Double = 200
    /// `H_b`, along z.
    var heightMillimetres: Double = 100
    /// Clearance every package keeps from the module walls, on top of its own requirement.
    var minimumWallClearance: Double = 0
    /// `m̄_b`, the largest payload mass the module may carry. `nil` means unlimited.
    var maximumPayloadMassKilograms: Double? = nil

    /// `m_b⁰` — the empty module, and `c_b⁰`, its centre of mass in the module frame.
    var emptyMassKilograms: Double = 0
    var emptyCentreOfMass: SIMD3<Double> = SIMD3(0, 0, 0)

    /// `m_0` and `c_0` — the drone without the payload module, in the same frame.
    var airframeMassKilograms: Double = 0
    var airframeCentreOfMass: SIMD3<Double> = SIMD3(0, 0, 0)

    /// `c*`, the centre of mass the arrangement should achieve.
    var targetCentreOfMass: SIMD3<Double> = SIMD3(0, 0, 0)
    var centreOfMassEnvelope: CentreOfMassEnvelope = .unbounded
    /// `w_x`, `w_y`, `w_z` — relative importance of each direction in the objective.
    var axisWeights: SIMD3<Double> = SIMD3(1, 1, 0.5)

    var floorArea: Double { lengthMillimetres * widthMillimetres }

    /// Mass that is present regardless of the arrangement.
    var fixedMassKilograms: Double { emptyMassKilograms + airframeMassKilograms }

    /// Mass-weighted contribution of the empty module and the airframe to the system centre of mass.
    var fixedMassMoment: SIMD3<Double> {
        emptyMassKilograms * emptyCentreOfMass + airframeMassKilograms * airframeCentreOfMass
    }

    /// The default module for this project: a 20 × 80 × 10 cm compartment, packages balanced about
    /// its centre and kept as low as reasonably possible.
    static let standard = PayloadModule()
}

// MARK: - Orientations

/// An axis-aligned orientation: one of the orthogonal rotation matrices `R ∈ {0, −1, 1}^{3×3}` of
/// the adaptation chapter, stored in the compact form such a matrix always has — one non-zero entry
/// per row and column.
///
/// `sourceAxis[i]` is the package axis that ends up on module axis `i`, and `signs[i]` is that
/// entry's sign. Only proper rotations (`det R = +1`) are enumerated: a reflection would describe a
/// mirrored package, which is not a thing that can be done to a physical box.
nonisolated struct OrthogonalOrientation: Sendable, Hashable {
    var sourceAxis: [Int]
    var signs: [Double]

    /// Half-extents `[X_ik, Y_ik, Z_ik]ᵀ = ½|R_ik| d_i` — chapter eq. (oriented 3D dimensions).
    func halfExtents(of size: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(size[sourceAxis[0]], size[sourceAxis[1]], size[sourceAxis[2]]) * 0.5
    }

    /// Rotated centre-of-mass offset `Δ_ik = R_ik δ_i` — chapter eq. (rotated COM offset).
    func rotatedOffset(of offset: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(
            signs[0] * offset[sourceAxis[0]],
            signs[1] * offset[sourceAxis[1]],
            signs[2] * offset[sourceAxis[2]]
        )
    }

    /// True when the package's measured top face still points up.
    var keepsPackageUpright: Bool { sourceAxis[2] == 2 && signs[2] > 0 }

    /// How the package rests on the module floor.
    var restingDescription: String {
        switch (sourceAxis[2], signs[2] > 0) {
        case (2, true): "upright"
        case (2, false): "upside down"
        case (0, _): "on its end, width vertical"
        default: "on its side, depth vertical"
        }
    }

    /// Which package axis runs along the module length.
    var alignmentDescription: String {
        "\(PackingItem.axisName(sourceAxis[0])) along the module"
    }

    var summary: String { "\(restingDescription), \(alignmentDescription)" }

    /// All 24 proper axis-aligned rotations of a cuboid.
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

/// One orientation of one package, with everything the model needs precomputed.
nonisolated struct PreparedOrientation: Sendable {
    var orientation: OrthogonalOrientation
    /// `X_ik`, `Y_ik`, `Z_ik`.
    var halfExtents: SIMD3<Double>
    /// `Δ_ik`.
    var comOffset: SIMD3<Double>

    var footprintX: Double { 2 * halfExtents.x }
    var footprintY: Double { 2 * halfExtents.y }
    var height: Double { 2 * halfExtents.z }
}

/// A package with its permitted, height-feasible, duplicate-free orientation set.
nonisolated struct PreparedItem: Sendable {
    var item: PackingItem
    var orientations: [PreparedOrientation]
    /// `max(s_i, container wall clearance)` — both are floors, so the binding one is the larger.
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

    /// Distinct values of a given half-extent axis across the permitted orientations.
    func halfExtentValues(axis: Int) -> [Double] {
        var seen: Set<Int64> = []
        var values: [Double] = []
        for prepared in orientations {
            let value = prepared.halfExtents[axis]
            let key = Int64((value * 1e6).rounded())
            if seen.insert(key).inserted { values.append(value) }
        }
        return values
    }
}

// MARK: - Problem

nonisolated struct PackingProblem: Sendable {
    var module: PayloadModule
    var items: [PackingItem]
}

/// The normalised, orientation-prepared problem the model builder consumes.
nonisolated struct PreparedProblem: Sendable {
    var module: PayloadModule
    var items: [PreparedItem]
    var totalItemMass: Double

    /// Denominator of the centre-of-mass expression. Constant, because every package is loaded and
    /// no mass depends on a decision variable — which is what keeps the model linear.
    var totalSystemMass: Double { totalItemMass + module.fixedMassKilograms }
}

/// Why a problem cannot be arranged, when that can be established without solving anything.
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

/// Input problems that cannot be normalised at all, with one operator-facing message per fault.
nonisolated struct PackingValidationFailure: Sendable, Error {
    var messages: [String]
}

nonisolated enum PackingPreparation {
    /// Validates the problem and precomputes each package's permitted orientation set.
    ///
    /// Orientations are filtered by the module height (chapter eq. for `K_ib`) and then reduced by
    /// removing entries that are observationally identical to one already kept. With a centred
    /// centre of mass the 24 rotations collapse to at most 6 distinct dimension assignments, and
    /// fewer still for a square or cubic package. That reduction is exact, not an approximation,
    /// and it removes binaries from the model rather than solutions from the search.
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
                // Chapter: K_ib = { k : 2·Z_ik + 2·s_i^z ≤ H_b }.
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

    /// Checks that prove infeasibility without building a model. Every check is a valid
    /// implication, so a reported infeasibility is never wrong; returning `nil` decides nothing.
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

        // Area bound. Every package body lies inside the floor inset by the smallest wall clearance
        // of any package, so the footprints cannot sum to more than that inset area. Clearance
        // between packages is ignored, which can only weaken the bound, never invalidate it.
        let inset = problem.items.map(\.wallClearance).min() ?? 0
        let usableLength = max(0, module.lengthMillimetres - 2 * inset)
        let usableWidth = max(0, module.widthMillimetres - 2 * inset)
        let usableArea = usableLength * usableWidth
        // Each package occupies at least its smallest possible footprint over its orientations.
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
