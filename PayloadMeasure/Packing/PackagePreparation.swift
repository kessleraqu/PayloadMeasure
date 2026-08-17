import Foundation
import simd

// The outer boxes and what happened to each measured object.
//
// In:  a measured size.
// Out: the boxes it fits into, and a per-object state: which box the system assigned, that the
//      object is a box already, or that nothing fits. Whatever it ends up in, not the raw
//      measurement, is what gets packed.

nonisolated enum PackagePreparationState: Sendable, Equatable {
    case unavailable
    case noStockedBoxFits
    case excludedBecauseNoStockedBoxFits
    case needsFittingBox
    case needsName
    case needsPackedWeight
    case ready
    /// The object needs no outer box: it is one already, and its measured size is the package size.
    case readyAsItsOwnBox

    var isComplete: Bool {
        isSubmittedToOptimizer || self == .excludedBecauseNoStockedBoxFits
    }

    var isSubmittedToOptimizer: Bool {
        self == .ready || self == .readyAsItsOwnBox
    }
}

nonisolated struct PackingBoxPreset: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let name: String
    let outerSizeMillimetres: SIMD3<Double>
    let usableInnerSizeMillimetres: SIMD3<Double>

    /// Box sizes are taken as given: what is written on the box is what fits in it. No wall
    /// allowance is subtracted, so the usable inside equals the outer size.
    static let wallThicknessMillimetres: Double = 0

    /// A box is identified by its size, so that is its name.
    static func sized(outerSizeMillimetres: SIMD3<Double>) -> PackingBoxPreset? {
        sized(id: identifier(for: outerSizeMillimetres), outerSizeMillimetres: outerSizeMillimetres)
    }

    static func sized(
        id: String,
        outerSizeMillimetres: SIMD3<Double>
    ) -> PackingBoxPreset? {
        let inner = outerSizeMillimetres - SIMD3(repeating: 2 * wallThicknessMillimetres)
        guard outerSizeMillimetres.allFiniteAndPositive, inner.allFiniteAndPositive else {
            return nil
        }
        return PackingBoxPreset(
            id: id,
            name: sizeName(outerSizeMillimetres),
            outerSizeMillimetres: outerSizeMillimetres,
            usableInnerSizeMillimetres: inner
        )
    }

    static func sizeName(_ size: SIMD3<Double>) -> String {
        String(format: "%.0f × %.0f × %.0f mm", size.x, size.y, size.z)
    }

    var outerVolume: Double {
        outerSizeMillimetres.x
            * outerSizeMillimetres.y
            * outerSizeMillimetres.z
    }

    /// What the list starts as. Everything in it can be deleted, so this is only ever a starting
    /// point; once the operator edits the list, theirs is the one that counts.
    /// The boxes available for one payload module. The two modules carry different boxes, and the
    /// practice payload uses the small module's, being the same size — see `catalogueOwner`.
    static func defaultCatalog(for payload: StudyBox) -> [PackingBoxPreset] {
        let sizes: [SIMD3<Double>]
        switch payload {
        case .big:
            sizes = [
                SIMD3(35, 22, 115),
                // Measured inside rather than taken from the label: this one is 235 mm deep inside.
                SIMD3(75, 75, 235),
                SIMD3(95, 95, 160),
                SIMD3(100, 95, 85),
                SIMD3(130, 100, 105),
            ]
        case .small:
            sizes = [
                SIMD3(100, 75, 90),
                // Also an inside measurement: the label says 40 mm, only 30 mm is usable.
                SIMD3(120, 90, 30),
            ]
        }
        return sizes.compactMap {
            PackingBoxPreset.sized(id: identifier(for: $0), outerSizeMillimetres: $0)
        }
    }

    /// The size is the identity, so it is also the id.
    static func identifier(for size: SIMD3<Double>) -> String {
        String(format: "%.0fx%.0fx%.0f", size.x, size.y, size.z)
    }

    func fits(objectSizeMillimetres size: SIMD3<Double>) -> Bool {
        guard size.allFiniteAndPositive,
              usableInnerSizeMillimetres.allFiniteAndPositive else {
            return false
        }
        return Self.axisPermutations.contains { permutation in
            size[permutation[0]] <= usableInnerSizeMillimetres.x + Self.fitTolerance
                && size[permutation[1]] <= usableInnerSizeMillimetres.y + Self.fitTolerance
                && size[permutation[2]] <= usableInnerSizeMillimetres.z + Self.fitTolerance
        }
    }

    private static let fitTolerance = 1e-6

    private static let axisPermutations: [[Int]] = [
        [0, 1, 2], [0, 2, 1],
        [1, 0, 2], [1, 2, 0],
        [2, 0, 1], [2, 1, 0],
    ]
}

nonisolated enum PackingBoxCatalog {
    static func fittingPresets(
        for objectSizeMillimetres: SIMD3<Double>,
        in catalog: [PackingBoxPreset]
    ) -> [PackingBoxPreset] {
        catalog.enumerated()
            .filter { $0.element.fits(objectSizeMillimetres: objectSizeMillimetres) }
            .sorted { lhs, rhs in
                if abs(lhs.element.outerVolume - rhs.element.outerVolume) > 1e-9 {
                    return lhs.element.outerVolume < rhs.element.outerVolume
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func recommendedPreset(
        for objectSizeMillimetres: SIMD3<Double>,
        in catalog: [PackingBoxPreset]
    ) -> PackingBoxPreset? {
        fittingPresets(for: objectSizeMillimetres, in: catalog).first
    }
}

extension SIMD3 where Scalar == Double {
    nonisolated var allFiniteAndPositive: Bool {
        x.isFinite && y.isFinite && z.isFinite
            && x > 0 && y > 0 && z > 0
    }
}
