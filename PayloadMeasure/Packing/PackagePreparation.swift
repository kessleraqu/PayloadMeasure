import Foundation
import simd

// Outer boxes and the preparation state of each measured object (assigned box, already a box, or
// nothing fits). The packed size comes from the box, not the raw measurement.

nonisolated enum PackagePreparationState: Sendable, Equatable {
    case unavailable
    case noStockedBoxFits
    case excludedBecauseNoStockedBoxFits
    /// Left out by the operator. Needs no box, name or weight.
    case skipped
    case needsFittingBox
    case needsName
    case needsPackedWeight
    case ready
    /// Already a box, so its measured size is the package size.
    case readyAsItsOwnBox

    var isComplete: Bool {
        isSubmittedToOptimizer
            || self == .excludedBecauseNoStockedBoxFits
            || self == .skipped
    }

    var isSubmittedToOptimizer: Bool {
        self == .ready || self == .readyAsItsOwnBox
    }
}

nonisolated struct PackingBoxPreset: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let name: String
    /// Outside size, used for placement.
    let outerSizeMillimetres: SIMD3<Double>
    /// Inside size, also shown as the box name.
    let usableInnerSizeMillimetres: SIMD3<Double>

    /// Sizes are taken as labelled, no wall allowance.
    static let wallThicknessMillimetres: Double = 0

    static func sized(
        outerSizeMillimetres: SIMD3<Double>,
        usableInnerSizeMillimetres: SIMD3<Double>? = nil
    ) -> PackingBoxPreset? {
        sized(
            id: identifier(for: outerSizeMillimetres),
            outerSizeMillimetres: outerSizeMillimetres,
            usableInnerSizeMillimetres: usableInnerSizeMillimetres
        )
    }

    static func sized(
        id: String,
        outerSizeMillimetres: SIMD3<Double>,
        usableInnerSizeMillimetres: SIMD3<Double>? = nil
    ) -> PackingBoxPreset? {
        let inner = usableInnerSizeMillimetres
            ?? outerSizeMillimetres - SIMD3(repeating: 2 * wallThicknessMillimetres)
        guard outerSizeMillimetres.allFiniteAndPositive, inner.allFiniteAndPositive else {
            return nil
        }
        return PackingBoxPreset(
            id: id,
            name: sizeName(inner),
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
