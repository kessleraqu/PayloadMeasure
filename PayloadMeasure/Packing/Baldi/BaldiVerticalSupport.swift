import Foundation

/// One package's vertical-support result.
///
/// Junqueira, Morabito & Yamashita (2012), equation (11), require a chosen fraction of a
/// non-floor box's bottom face to be covered by top faces in direct contact below it. This project
/// fixes that fraction to one: every non-floor package must have its complete bottom face covered.
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

/// Continuous-coordinate evaluation of Junqueira et al.'s area support condition with `alpha = 1`.
///
/// The paper's model indexes binary placement variables on a discrete coordinate grid. Baldi's
/// heuristic instead gives us an already known, continuous placement, so the same geometric rule is
/// evaluated directly: clip every contacting supporter's top face to the package's bottom face and
/// measure the union of those rectangles. Union area is used rather than a raw sum so numerical
/// tolerances can never double-count support.
nonisolated enum BaldiVerticalSupport {
    /// Millimetres. This handles floating-point noise only; it is not a measurement allowance.
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

    /// Rectangle-union area by an x-axis sweep. The support rectangles are few, so the direct
    /// `O(n^2 log n)` implementation is easier to audit than a stateful sweep-line structure.
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
            for rectangle in rectangles
            where rectangle.minX < middle && middle < rectangle.maxX {
                intervals.append((lower: rectangle.minY, upper: rectangle.maxY))
            }
            intervals.sort { first, second in
                first.lower == second.lower
                    ? first.upper < second.upper
                    : first.lower < second.lower
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
