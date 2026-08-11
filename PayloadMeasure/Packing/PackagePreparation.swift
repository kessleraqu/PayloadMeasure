import Foundation
import simd

/// Physical preparation state for one measured object.
///
/// `.excludedBecauseNoStockedBoxFits` is an operator decision made before optimisation. It is
/// deliberately distinct from a 3D-knapsack solution omitting an otherwise eligible package.
nonisolated enum PackagePreparationState: Sendable, Equatable {
    case unavailable
    case noStockedBoxFits
    case excludedBecauseNoStockedBoxFits
    case needsFittingBox
    case needsName
    case needsPackedWeight
    case ready

    var isComplete: Bool {
        self == .ready || self == .excludedBecauseNoStockedBoxFits
    }

    var isSubmittedToOptimizer: Bool {
        self == .ready
    }
}

/// One physical box that the operator can use around a measured object.
///
/// Keep the stocked box catalogue in one place. `outerSizeMillimetres` is what the loading
/// optimiser must arrange; `usableInnerSizeMillimetres` is what the scanned object has to fit
/// inside. Keeping both avoids silently treating cardboard thickness as free space.
nonisolated struct PackingBoxPreset: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let outerSizeMillimetres: SIMD3<Double>
    let usableInnerSizeMillimetres: SIMD3<Double>

    var outerVolume: Double {
        outerSizeMillimetres.x
            * outerSizeMillimetres.y
            * outerSizeMillimetres.z
    }

    /// The app's initial stocked-box catalogue. Change these values to match the boxes available
    /// to operators; the rest of the preparation and optimisation flow reads this single list.
    static let standardCatalog: [PackingBoxPreset] = [
        PackingBoxPreset(
            id: "small",
            name: "Small box",
            outerSizeMillimetres: SIMD3(120, 80, 60),
            usableInnerSizeMillimetres: SIMD3(114, 74, 54)
        ),
        PackingBoxPreset(
            id: "medium",
            name: "Medium box",
            outerSizeMillimetres: SIMD3(180, 120, 80),
            usableInnerSizeMillimetres: SIMD3(174, 114, 74)
        ),
        PackingBoxPreset(
            id: "large",
            name: "Large box",
            outerSizeMillimetres: SIMD3(280, 180, 95),
            usableInnerSizeMillimetres: SIMD3(272, 172, 87)
        ),
    ]

    /// True when the object fits in at least one of the six orthogonal cuboid orientations.
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

    /// All six mappings of an object's three axes onto the box's three axes.
    private static let axisPermutations: [[Int]] = [
        [0, 1, 2], [0, 2, 1],
        [1, 0, 2], [1, 2, 0],
        [2, 0, 1], [2, 1, 0],
    ]
}

nonisolated enum PackingBoxCatalog {
    /// Fitting options ordered from least outer volume to greatest, with stable catalogue order as
    /// the final tie-break. The first is therefore the frictionless recommendation.
    static func fittingPresets(
        for objectSizeMillimetres: SIMD3<Double>,
        in catalog: [PackingBoxPreset] = PackingBoxPreset.standardCatalog
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
        in catalog: [PackingBoxPreset] = PackingBoxPreset.standardCatalog
    ) -> PackingBoxPreset? {
        fittingPresets(for: objectSizeMillimetres, in: catalog).first
    }
}

private extension SIMD3 where Scalar == Double {
    nonisolated var allFiniteAndPositive: Bool {
        x.isFinite && y.isFinite && z.isFinite
            && x > 0 && y > 0 && z > 0
    }
}
