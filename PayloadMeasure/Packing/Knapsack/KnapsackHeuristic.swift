import Foundation
import simd

// The packing search itself, in the order it runs:
//
//   1. sorting        — six ways of ordering the packages before they are placed
//   2. construction   — drop packages one at a time onto extreme points, best fit first
//   3. balancing      — slide packages around to pull the cargo centre of mass into its domain
//   4. search loop    — reorder, repack, keep the best fully verified result until time runs out
//
// In:  a BaldiProblem plus BaldiSearchOptions (time limit, scoring constants, packing mode).
// Out: BaldiSearchResult, whose `solution` is the best packing that passed every feasibility
//      rule. It may be empty; that means none was found in the time given, not that none exists.
//
// Nothing here is random beyond a fixed seed, so the same input always gives the same packing.

// MARK: - Sorting

nonisolated enum BaldiAttribute: Sendable {
    case profit
    case specificWeight
    case area

    func value(of item: BaldiItem) -> Double {
        switch self {
        case .profit: item.profit
        case .specificWeight: item.specificWeight
        case .area: Double(item.area)
        }
    }
}

/// Each criterion buckets packages by one attribute, then orders within a bucket by another.
/// Both run high to low.
nonisolated enum BaldiSortingCriterion: String, Sendable, CaseIterable {
    case areaSpecificWeight = "a-sw"
    case areaProfit = "a-p"
    case specificWeightArea = "sw-a"
    case specificWeightProfit = "sw-p"
    case profitSpecificWeight = "p-sw"
    case profitArea = "p-a"

    var clusteredAttribute: BaldiAttribute {
        switch self {
        case .areaSpecificWeight, .areaProfit: .area
        case .specificWeightArea, .specificWeightProfit: .specificWeight
        case .profitSpecificWeight, .profitArea: .profit
        }
    }

    var sortedAttribute: BaldiAttribute {
        switch self {
        case .areaSpecificWeight, .profitSpecificWeight: .specificWeight
        case .areaProfit, .specificWeightProfit: .profit
        case .specificWeightArea, .profitArea: .area
        }
    }
}

nonisolated enum BaldiSorting {
    /// Bucket width as a percentage of the attribute range, so 20 gives five buckets.
    static let defaultTheta: Double = 20

    static func clusterIndex(
        of value: Double,
        minimum: Double,
        maximum: Double,
        theta: Double
    ) -> Int {
        let clusterCount = max(1, Int((100 / theta).rounded(.up)))
        let span = maximum - minimum
        guard span > 0 else { return 1 }
        let width = span * theta / 100
        guard width > 0 else { return 1 }
        let raw = Int(((value - minimum) / width).rounded(.up))
        return min(max(raw, 1), clusterCount)
    }

    static func order(
        _ items: [BaldiItem],
        by criterion: BaldiSortingCriterion,
        knapsack: BaldiKnapsack,
        theta: Double = defaultTheta
    ) -> [BaldiItem] {
        guard !items.isEmpty else { return [] }
        let clustered = criterion.clusteredAttribute
        let sorted = criterion.sortedAttribute

        // Area buckets span the whole container floor; the other attributes span the package range.
        let minimum: Double
        let maximum: Double
        if clustered == .area {
            minimum = 0
            maximum = Double(knapsack.size.x * knapsack.size.y)
        } else {
            let values = items.map { clustered.value(of: $0) }
            minimum = values.min() ?? 0
            maximum = values.max() ?? 0
        }

        return items.enumerated()
            .map { entry -> (cluster: Int, key: Double, index: Int, item: BaldiItem) in
                (
                    clusterIndex(
                        of: clustered.value(of: entry.element),
                        minimum: minimum,
                        maximum: maximum,
                        theta: theta
                    ),
                    sorted.value(of: entry.element),
                    entry.offset,
                    entry.element
                )
            }
            .sorted { left, right in
                if left.cluster != right.cluster { return left.cluster > right.cluster }
                if left.key != right.key { return left.key > right.key }
                return left.index < right.index
            }
            .map(\.item)
    }
}

// MARK: - Construction

/// A corner where the next package can go, with the free space around it on each axis.
nonisolated struct BaldiExtremePoint: Sendable, Hashable {
    var position: SIMD3<Double>
    var residualSpace: SIMD3<Double>
}

/// A packing being built up. `canPlace` is the only gate: a package has to be inside the container,
/// clear of everything else and fully supported before it is allowed in.
nonisolated struct BaldiPacking: Sendable {
    let knapsack: BaldiKnapsack
    let extent: SIMD3<Double>
    private(set) var placements: [BaldiPlacement] = []
    private(set) var extremePoints: [BaldiExtremePoint]
    private let tolerance = 1e-6

    init(knapsack: BaldiKnapsack) {
        self.knapsack = knapsack
        let extent = SIMD3<Double>(
            Double(knapsack.size.x),
            Double(knapsack.size.y),
            Double(knapsack.size.z)
        )
        self.extent = extent
        self.extremePoints = [BaldiExtremePoint(position: .zero, residualSpace: extent)]
    }

    func canPlace(item: BaldiItem, rotation: BaldiRotation, at point: BaldiExtremePoint) -> Bool {
        guard BaldiRotation.all.contains(rotation),
              item.mass.isFinite,
              item.mass > 0,
              !placements.contains(where: { $0.id == item.id }) else { return false }
        let placement = candidate(item: item, rotation: rotation, at: point)
        guard fitsClear(size: placement.size, at: placement.origin) else { return false }
        return BaldiVerticalSupport.report(for: placement, among: placements).isFullySupported
    }

    /// Rechecked here so a caller that forgets `canPlace` cannot break the invariant.
    @discardableResult
    mutating func place(item: BaldiItem, rotation: BaldiRotation, at point: BaldiExtremePoint) -> Bool {
        guard canPlace(item: item, rotation: rotation, at: point) else { return false }
        placements.append(candidate(item: item, rotation: rotation, at: point))
        extremePoints.removeAll { $0.position == point.position }
        appendGeneratedPoints(for: placements[placements.count - 1])
        pruneAndRefreshResidualSpace()
        return true
    }

    func solution(unloaded: [BaldiItem]) -> BaldiSolution {
        BaldiSolution(knapsack: knapsack, placements: placements, unloaded: unloaded)
    }

    private func candidate(
        item: BaldiItem,
        rotation: BaldiRotation,
        at point: BaldiExtremePoint
    ) -> BaldiPlacement {
        BaldiPlacement(
            id: item.id,
            name: item.name,
            origin: point.position,
            rotation: rotation,
            size: rotation.size(of: item.size),
            mass: item.mass
        )
    }

    private func fitsClear(size: SIMD3<Int>, at origin: SIMD3<Double>) -> Bool {
        guard size.x > 0, size.y > 0, size.z > 0 else { return false }
        let body = SIMD3<Double>(Double(size.x), Double(size.y), Double(size.z))
        for axis in 0..<3 {
            guard origin[axis].isFinite else { return false }
            if origin[axis] < -tolerance { return false }
            if origin[axis] + body[axis] > extent[axis] + tolerance { return false }
        }
        let maximum = origin + body
        for placed in placements {
            var separated = false
            for axis in 0..<3
            where origin[axis] >= placed.maximum[axis] - tolerance
                || placed.origin[axis] >= maximum[axis] - tolerance {
                separated = true
                break
            }
            if !separated { return false }
        }
        return true
    }

    /// Each of the three far corners of the new package, slid back along the two axes it does not
    /// extend along, gives a new corner to try later.
    private mutating func appendGeneratedPoints(for placement: BaldiPlacement) {
        let origin = placement.origin
        let maximum = placement.maximum
        let corners: [(point: SIMD3<Double>, axes: [Int])] = [
            (SIMD3(maximum.x, origin.y, origin.z), [1, 2]),
            (SIMD3(origin.x, maximum.y, origin.z), [0, 2]),
            (SIMD3(origin.x, origin.y, maximum.z), [0, 1]),
        ]
        for corner in corners {
            for axis in corner.axes {
                var projected = corner.point
                projected[axis] = projection(of: corner.point, along: axis)
                extremePoints.append(BaldiExtremePoint(position: projected, residualSpace: .zero))
            }
        }
    }

    private func projection(of point: SIMD3<Double>, along axis: Int) -> Double {
        let (first, second) = otherAxes(of: axis)
        var best = 0.0
        for placed in placements {
            guard placed.origin[first] <= point[first] + tolerance,
                  point[first] < placed.maximum[first] - tolerance else { continue }
            guard placed.origin[second] <= point[second] + tolerance,
                  point[second] < placed.maximum[second] - tolerance else { continue }
            guard placed.maximum[axis] <= point[axis] + tolerance else { continue }
            best = max(best, placed.maximum[axis])
        }
        return best
    }

    private mutating func pruneAndRefreshResidualSpace() {
        var seen: Set<SIMD3<Double>> = []
        var kept: [BaldiExtremePoint] = []
        for point in extremePoints {
            let position = point.position
            var outside = false
            for axis in 0..<3 where position[axis] < -tolerance || position[axis] >= extent[axis] - tolerance {
                outside = true
                break
            }
            if outside { continue }
            if isBuried(position) { continue }
            guard seen.insert(position).inserted else { continue }
            kept.append(BaldiExtremePoint(position: position, residualSpace: residualSpace(at: position)))
        }
        extremePoints = kept
    }

    private func isBuried(_ position: SIMD3<Double>) -> Bool {
        for placed in placements {
            var inside = true
            for axis in 0..<3
            where !(placed.origin[axis] <= position[axis] + tolerance
                && position[axis] < placed.maximum[axis] - tolerance) {
                inside = false
                break
            }
            if inside { return true }
        }
        return false
    }

    private func residualSpace(at position: SIMD3<Double>) -> SIMD3<Double> {
        var space = extent - position
        for axis in 0..<3 {
            let (first, second) = otherAxes(of: axis)
            for placed in placements {
                guard placed.origin[first] <= position[first] + tolerance,
                      position[first] < placed.maximum[first] - tolerance else { continue }
                guard placed.origin[second] <= position[second] + tolerance,
                      position[second] < placed.maximum[second] - tolerance else { continue }
                guard placed.origin[axis] >= position[axis] - tolerance else { continue }
                space[axis] = min(space[axis], placed.origin[axis] - position[axis])
            }
        }
        return space
    }

    private func otherAxes(of axis: Int) -> (Int, Int) {
        switch axis {
        case 0: (1, 2)
        case 1: (0, 2)
        default: (0, 1)
        }
    }
}

/// Walks the ordered packages and puts each one on the corner and rotation that leaves the least
/// slack around it. Anything that fits nowhere is discarded.
nonisolated enum BaldiConstruction {
    static func pack(order: [BaldiItem], knapsack: BaldiKnapsack) -> BaldiSolution {
        var packing = BaldiPacking(knapsack: knapsack)
        var discarded: [BaldiItem] = []

        for item in order {
            var bestPoint: BaldiExtremePoint?
            var bestRotation: BaldiRotation?
            var bestScore = Double.infinity

            for point in packing.extremePoints {
                for rotation in BaldiRotation.all {
                    let size = rotation.size(of: item.size)
                    let body = SIMD3<Double>(Double(size.x), Double(size.y), Double(size.z))
                    if point.residualSpace.x < body.x - 1e-6 { continue }
                    if point.residualSpace.y < body.y - 1e-6 { continue }
                    if point.residualSpace.z < body.z - 1e-6 { continue }
                    guard packing.canPlace(item: item, rotation: rotation, at: point) else { continue }

                    let score = (point.residualSpace.x - body.x)
                        + (point.residualSpace.y - body.y)
                        + (point.residualSpace.z - body.z)
                    if score < bestScore {
                        bestScore = score
                        bestPoint = point
                        bestRotation = rotation
                    }
                }
            }

            if let bestPoint, let bestRotation {
                if !packing.place(item: item, rotation: bestRotation, at: bestPoint) {
                    discarded.append(item)
                }
            } else {
                discarded.append(item)
            }
        }

        return packing.solution(unloaded: discarded)
    }
}

// MARK: - Balancing

/// Nudges packages, one at a time, to bring the cargo centre of mass towards the middle of its
/// domain. Paper mode stops the moment the centre of mass is inside and only considers positions
/// reachable past the immediate neighbours; centred mode keeps going and will relocate a package
/// anywhere legal. Every proposed arrangement is revalidated whole, because moving a low package
/// can strand the ones above it.
nonisolated enum BaldiBalancer {
    nonisolated struct Options: Sendable, Equatable {
        var mode: BaldiPackingMode = .paper
        var maximumIterations = 50

        init() {}
    }

    static func optimise(
        placements: [BaldiPlacement],
        knapsack: BaldiKnapsack,
        options: Options = Options()
    ) -> [BaldiPlacement] {
        guard !placements.isEmpty,
              options.maximumIterations > 0,
              hasValidDomain(knapsack),
              isSpatiallyValid(placements, in: knapsack) else { return placements }
        var current = placements
        let target = knapsack.idealCentreOfMass
        // §5.2's move is taken as printed, without an improvement test, so a run of them can drift.
        // Keeping the best arrangement seen means the procedure never hands back something worse
        // than it was given; balanced always beats unbalanced, then closeness to target.
        var best = placements
        var bestIsBalanced = knapsack.containsCentreOfMass(centreOfMass(of: placements))
        var bestQuality = simd_distance_squared(centreOfMass(of: placements), target)

        func recordIfBest(_ arrangement: [BaldiPlacement]) {
            let centre = centreOfMass(of: arrangement)
            let balanced = knapsack.containsCentreOfMass(centre)
            let quality = simd_distance_squared(centre, target)
            guard quality.isFinite else { return }
            guard balanced != bestIsBalanced ? balanced : quality < bestQuality else { return }
            best = arrangement
            bestIsBalanced = balanced
            bestQuality = quality
        }

        for _ in 0..<options.maximumIterations {
            if options.mode == .paper,
               knapsack.containsCentreOfMass(centreOfMass(of: current)) { break }
            var movedAnything = false

            // Heaviest first: a heavy package needs the shortest move to shift the centre of mass.
            let order = current.indices.sorted { current[$0].mass > current[$1].mass }

            for index in order {
                let centre = centreOfMass(of: current)
                if options.mode == .paper, knapsack.containsCentreOfMass(centre) { break }
                let currentQuality = simd_distance_squared(centre, target)
                guard currentQuality.isFinite, currentQuality > 0 else { continue }
                let mustRemainBalanced = knapsack.containsCentreOfMass(centre)
                let totalMass = current.reduce(0) { $0 + $1.mass }
                let item = current[index]
                guard item.mass.isFinite, item.mass > 0,
                      totalMass.isFinite, totalMass > 0 else { continue }

                // Where this package alone would have to go to land the centre of mass on target.
                let desiredItemCentre = item.centreOfMass + (target - centre) * totalMass / item.mass
                let desiredOrigin = desiredItemCentre - item.extent / 2

                let domain: CandidateDomain?
                switch options.mode {
                case .paper: domain = localCandidateDomain(for: index, in: current, knapsack: knapsack)
                case .centred: domain = containerDomain(for: item, knapsack: knapsack)
                }
                guard let domain else { continue }

                let clamped = simd_clamp(desiredOrigin, domain.lower, domain.upper)

                // The move §5.2 actually prescribes: r′ᵢ if it lies in Dᵢ, otherwise the point that
                // best approximates it on each axis. Taken whenever full support permits it.
                if let relocated = prescribedMove(
                    of: index,
                    to: clamped,
                    in: current,
                    knapsack: knapsack,
                    mustRemainBalanced: mustRemainBalanced
                ) {
                    current = relocated
                    movedAnything = true
                    recordIfBest(current)
                    continue
                }

                // Only reached when the prescribed point is unsupported, which is a consequence of
                // adding Junqueira's rule. Fall back to the nearest arrangement that improves.
                let candidates: [SIMD3<Double>]
                switch options.mode {
                case .paper:
                    candidates = localCandidateOrigins(for: index, desired: clamped, in: current, domain: domain)
                case .centred:
                    candidates = centredCandidateOrigins(for: index, desired: clamped, in: current, domain: domain)
                }
                guard let improvement = bestImprovingMove(
                    of: index,
                    toOneOf: candidates,
                    in: current,
                    knapsack: knapsack,
                    target: target,
                    currentQuality: currentQuality,
                    mustRemainBalanced: mustRemainBalanced
                ) else { continue }

                current = improvement
                movedAnything = true
                recordIfBest(current)
            }

            if !movedAnything { break }
        }

        return best
    }

    /// Applies §5.2's own relocation. No improvement test — eq. (28) already aims the centre of mass
    /// at the target — but the whole packing has to stay valid, and a balanced packing has to stay
    /// balanced.
    private static func prescribedMove(
        of index: Int,
        to origin: SIMD3<Double>,
        in placements: [BaldiPlacement],
        knapsack: BaldiKnapsack,
        mustRemainBalanced: Bool
    ) -> [BaldiPlacement]? {
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
              simd_distance_squared(origin, placements[index].origin) >= 1e-12 else { return nil }
        var proposed = placements
        proposed[index].origin = origin
        guard isSpatiallyValid(proposed, in: knapsack) else { return nil }
        if mustRemainBalanced, !knapsack.containsCentreOfMass(centreOfMass(of: proposed)) { return nil }
        return proposed
    }

    static func centreOfMass(of placements: [BaldiPlacement]) -> SIMD3<Double> {
        guard !placements.isEmpty else { return .zero }
        guard placements.allSatisfy({
            $0.mass.isFinite && $0.mass > 0
                && $0.origin.x.isFinite && $0.origin.y.isFinite && $0.origin.z.isFinite
        }) else { return SIMD3<Double>(repeating: .nan) }
        let mass = placements.reduce(0) { $0 + $1.mass }
        guard mass.isFinite, mass > 0 else { return SIMD3<Double>(repeating: .nan) }
        var moment = SIMD3<Double>.zero
        for placement in placements {
            moment += placement.centreOfMass * placement.mass
        }
        return moment / mass
    }

    private struct CandidateDomain {
        var lower: SIMD3<Double>
        var upper: SIMD3<Double>
    }

    /// Bounded by whatever the package would run into on each axis from where it currently sits.
    private static func localCandidateDomain(
        for index: Int,
        in placements: [BaldiPlacement],
        knapsack: BaldiKnapsack
    ) -> CandidateDomain? {
        let item = placements[index]
        let tolerance = BaldiVerticalSupport.contactTolerance
        var lower = SIMD3<Double>.zero
        var upper = SIMD3<Double>(
            Double(knapsack.size.x), Double(knapsack.size.y), Double(knapsack.size.z)
        ) - item.extent
        for axis in 0..<3 where upper[axis] < -tolerance { return nil }

        for axis in 0..<3 {
            let (first, second) = otherAxes(of: axis)
            for (other, placed) in placements.enumerated() where other != index {
                let overlapsFirst = item.origin[first] < placed.maximum[first] - tolerance
                    && placed.origin[first] < item.maximum[first] - tolerance
                let overlapsSecond = item.origin[second] < placed.maximum[second] - tolerance
                    && placed.origin[second] < item.maximum[second] - tolerance
                guard overlapsFirst, overlapsSecond else { continue }

                if placed.maximum[axis] <= item.origin[axis] + tolerance {
                    lower[axis] = max(lower[axis], placed.maximum[axis])
                } else if placed.origin[axis] >= item.maximum[axis] - tolerance {
                    upper[axis] = min(upper[axis], placed.origin[axis] - item.extent[axis])
                }
            }
            if lower[axis] > upper[axis] + tolerance { return nil }
        }
        return CandidateDomain(lower: lower, upper: upper)
    }

    /// The whole container. Neighbours are not folded in because centred mode picks a new resting
    /// place rather than a path to slide along; the result is validated afterwards either way.
    private static func containerDomain(
        for item: BaldiPlacement,
        knapsack: BaldiKnapsack
    ) -> CandidateDomain? {
        let tolerance = 1e-6
        let upper = SIMD3<Double>(
            Double(knapsack.size.x), Double(knapsack.size.y), Double(knapsack.size.z)
        ) - item.extent
        for axis in 0..<3 where upper[axis] < -tolerance { return nil }
        return CandidateDomain(lower: .zero, upper: upper)
    }

    /// Desired point first, then the same point at each available support height, then one-axis
    /// moves, then a capped grid of coordinates taken from the faces of the other packages.
    private static func centredCandidateOrigins(
        for index: Int,
        desired: SIMD3<Double>,
        in placements: [BaldiPlacement],
        domain: CandidateDomain
    ) -> [SIMD3<Double>] {
        let maximumAxisCoordinates = 8
        let maximumCandidates = 48
        let item = placements[index]
        let original = item.origin
        let others = placements.indices.filter { $0 != index }.map { placements[$0] }

        let xCoordinates = boundedCoordinates(
            required: [desired.x, original.x, domain.lower.x, domain.upper.x],
            alternatives: others.flatMap { [$0.origin.x - item.extent.x, $0.maximum.x] },
            lower: domain.lower.x, upper: domain.upper.x, desired: desired.x, limit: maximumAxisCoordinates
        )
        let yCoordinates = boundedCoordinates(
            required: [desired.y, original.y, domain.lower.y, domain.upper.y],
            alternatives: others.flatMap { [$0.origin.y - item.extent.y, $0.maximum.y] },
            lower: domain.lower.y, upper: domain.upper.y, desired: desired.y, limit: maximumAxisCoordinates
        )
        let supportHeights = boundedCoordinates(
            required: [desired.z, original.z, domain.lower.z, domain.upper.z],
            alternatives: others.map(\.maximum.z),
            lower: domain.lower.z, upper: domain.upper.z, desired: desired.z, limit: maximumAxisCoordinates
        )

        var priority: [SIMD3<Double>] = [desired]
        for height in supportHeights {
            priority.append(SIMD3(desired.x, desired.y, height))
        }
        for axis in 0..<3 {
            var candidate = original
            candidate[axis] = desired[axis]
            priority.append(candidate)
        }

        var neighbourhood: [SIMD3<Double>] = []
        for x in xCoordinates {
            for y in yCoordinates {
                for z in supportHeights {
                    neighbourhood.append(SIMD3(x, y, z))
                }
            }
        }
        neighbourhood.sort { first, second in
            let firstDistance = simd_distance_squared(first, desired)
            let secondDistance = simd_distance_squared(second, desired)
            if firstDistance != secondDistance { return firstDistance < secondDistance }
            if first.x != second.x { return first.x < second.x }
            if first.y != second.y { return first.y < second.y }
            return first.z < second.z
        }

        var seen: Set<SIMD3<Double>> = []
        var result: [SIMD3<Double>] = []
        for candidate in priority + neighbourhood {
            guard simd_distance_squared(candidate, original) >= 1e-12 else { continue }
            guard seen.insert(candidate).inserted else { continue }
            result.append(candidate)
            if result.count == maximumCandidates { break }
        }
        return result
    }

    private static func localCandidateOrigins(
        for index: Int,
        desired: SIMD3<Double>,
        in placements: [BaldiPlacement],
        domain: CandidateDomain
    ) -> [SIMD3<Double>] {
        let original = placements[index].origin
        var candidates: [SIMD3<Double>] = [desired]

        let supportHeights = [0.0] + placements.indices
            .filter { $0 != index }
            .map { placements[$0].maximum.z }
        for height in supportHeights where height >= domain.lower.z && height <= domain.upper.z {
            var candidate = desired
            candidate.z = height
            candidates.append(candidate)
        }
        for axis in 0..<3 {
            var candidate = original
            candidate[axis] = desired[axis]
            candidates.append(candidate)
        }

        var seen: Set<SIMD3<Double>> = []
        return candidates
            .filter { simd_distance_squared($0, original) >= 1e-12 }
            .filter { seen.insert($0).inserted }
            .sorted {
                let firstDistance = simd_distance_squared($0, desired)
                let secondDistance = simd_distance_squared($1, desired)
                if firstDistance != secondDistance { return firstDistance < secondDistance }
                if $0.x != $1.x { return $0.x < $1.x }
                if $0.y != $1.y { return $0.y < $1.y }
                return $0.z < $1.z
            }
    }

    private static func boundedCoordinates(
        required: [Double],
        alternatives: [Double],
        lower: Double,
        upper: Double,
        desired: Double,
        limit: Int
    ) -> [Double] {
        func clamped(_ value: Double) -> Double { min(max(value, lower), upper) }

        var seen: Set<Double> = []
        var result: [Double] = []
        for value in required where value.isFinite {
            let value = clamped(value)
            if seen.insert(value).inserted { result.append(value) }
        }
        let orderedAlternatives = alternatives
            .filter(\.isFinite)
            .map(clamped)
            .sorted { first, second in
                let firstDistance = abs(first - desired)
                let secondDistance = abs(second - desired)
                return firstDistance == secondDistance ? first < second : firstDistance < secondDistance
            }
        for value in orderedAlternatives where result.count < limit {
            if seen.insert(value).inserted { result.append(value) }
        }
        return Array(result.prefix(limit))
    }

    private static func bestImprovingMove(
        of index: Int,
        toOneOf origins: [SIMD3<Double>],
        in placements: [BaldiPlacement],
        knapsack: BaldiKnapsack,
        target: SIMD3<Double>,
        currentQuality: Double,
        mustRemainBalanced: Bool
    ) -> [BaldiPlacement]? {
        var best: [BaldiPlacement]?
        var bestQuality = currentQuality

        for origin in origins {
            var proposed = placements
            proposed[index].origin = origin
            guard isSpatiallyValid(proposed, in: knapsack) else { continue }

            let proposedCentre = centreOfMass(of: proposed)
            if mustRemainBalanced, !knapsack.containsCentreOfMass(proposedCentre) { continue }
            let proposedQuality = simd_distance_squared(proposedCentre, target)
            guard isStrictImprovement(proposedQuality, over: bestQuality) else { continue }
            best = proposed
            bestQuality = proposedQuality
        }
        return best
    }

    private static func isStrictImprovement(_ candidate: Double, over incumbent: Double) -> Bool {
        guard candidate.isFinite, incumbent.isFinite else { return false }
        let scale = max(1, max(abs(candidate), abs(incumbent)))
        return candidate < incumbent - scale * 1e-12
    }

    private static func isSpatiallyValid(
        _ placements: [BaldiPlacement],
        in knapsack: BaldiKnapsack
    ) -> Bool {
        let tolerance = BaldiVerticalSupport.contactTolerance
        for placement in placements {
            guard placement.mass.isFinite,
                  placement.mass > 0,
                  placement.size.x > 0,
                  placement.size.y > 0,
                  placement.size.z > 0 else { return false }
            for axis in 0..<3 {
                guard placement.origin[axis].isFinite else { return false }
                if placement.origin[axis] < -tolerance { return false }
                if placement.maximum[axis] > Double(knapsack.size[axis]) + tolerance { return false }
            }
        }
        for first in placements.indices {
            for second in placements.indices where second > first {
                if placements[first].overlaps(placements[second], tolerance: tolerance) { return false }
            }
        }
        return BaldiVerticalSupport.allFullySupported(placements, tolerance: tolerance)
    }

    private static func hasValidDomain(_ knapsack: BaldiKnapsack) -> Bool {
        guard knapsack.size.x > 0, knapsack.size.y > 0, knapsack.size.z > 0 else { return false }
        for axis in 0..<3 {
            let lower = knapsack.domainLower[axis]
            let upper = knapsack.domainUpper[axis]
            guard lower.isFinite, upper.isFinite,
                  lower >= 0, lower <= upper,
                  upper <= Double(knapsack.size[axis]) else { return false }
        }
        return true
    }

    private static func otherAxes(of axis: Int) -> (Int, Int) {
        switch axis {
        case 0: (1, 2)
        case 1: (0, 2)
        default: (0, 1)
        }
    }
}

// MARK: - Search loop

nonisolated struct BaldiSearchOptions: Sendable, Equatable {
    var timeLimitSeconds: Double = 5
    /// How hard a score is pushed down when a loaded package looks like a poor use of space, and up
    /// when an unloaded one looks promising. Both adapt as the search runs.
    var scoreDecrease: Double = 0.1
    var scoreIncrease: Double = 0.1
    /// Packages loaded by the opening solution start with this multiple of the base score.
    var loadedScoreFactor: Double = 3
    /// Rounds without an improvement before the scores are reset and shuffled.
    var nonImprovingLimit = 1000
    var reinitialisationPairFraction: Double = 0.05
    var clusterTheta: Double = BaldiSorting.defaultTheta
    var centreOfMass = BaldiBalancer.Options()
    var randomSeed: UInt64 = 0x3B_C0_5EED

    init() {}
}

nonisolated struct BaldiSearchResult: Sendable {
    var solution: BaldiSolution
    var initialSolution: BaldiSolution
    var initialCriterion: BaldiSortingCriterion
    var iterations: Int
    var improvements: Int
    var reinitialisations: Int
    var runtimeSeconds: Double
}

nonisolated enum BaldiSearch {
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// Packs once under each of the six orderings and keeps the best.
    static func constructInitialSolution(
        _ problem: BaldiProblem,
        options: BaldiSearchOptions
    ) -> (solution: BaldiSolution, criterion: BaldiSortingCriterion, feasibleSolution: BaldiSolution?) {
        var bestForSearch: BaldiSolution?
        var bestFeasible: BaldiSolution?
        var bestCriterion = BaldiSortingCriterion.areaSpecificWeight

        for criterion in BaldiSortingCriterion.allCases {
            let order = BaldiSorting.order(
                problem.items,
                by: criterion,
                knapsack: problem.knapsack,
                theta: options.clusterTheta
            )
            let packed = balance(BaldiConstruction.pack(order: order, knapsack: problem.knapsack), options: options)
            if bestForSearch == nil
                || isBetterForSearch(packed, than: bestForSearch!, mode: options.centreOfMass.mode) {
                bestForSearch = packed
                bestCriterion = criterion
            }
            if isFeasible(packed) {
                if let incumbent = bestFeasible {
                    if isBetterFeasible(packed, than: incumbent, mode: options.centreOfMass.mode) {
                        bestFeasible = packed
                    }
                } else {
                    bestFeasible = packed
                }
            }
        }
        return (
            bestForSearch ?? BaldiSolution(knapsack: problem.knapsack, placements: [], unloaded: problem.items),
            bestCriterion,
            bestFeasible
        )
    }

    static func solve(
        _ problem: BaldiProblem,
        options: BaldiSearchOptions = BaldiSearchOptions()
    ) -> BaldiSearchResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: .seconds(options.timeLimitSeconds))
        let items = problem.items

        let initial = constructInitialSolution(problem, options: options)
        var searchBest = initial.solution
        var bestFeasible = initial.feasibleSolution

        var scores = initialScores(for: items, loadedIn: searchBest, options: options)
        var loadedCount = [Int](repeating: 0, count: items.count)
        var unloadedCount = [Int](repeating: 0, count: items.count)

        var scoreDecrease = options.scoreDecrease
        var scoreIncrease = options.scoreIncrease
        var generator = SeededGenerator(state: options.randomSeed == 0 ? 1 : options.randomSeed)

        var iterations = 0
        var improvements = 0
        var reinitialisations = 0
        var nonImproving = 0

        while ContinuousClock.now < deadline {
            if Task.isCancelled { break }
            iterations += 1

            let order = items.indices
                .sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
                .map { items[$0] }
            let current = balance(BaldiConstruction.pack(order: order, knapsack: problem.knapsack), options: options)

            let loadedIDs = Set(current.placements.map(\.id))
            for (index, item) in items.enumerated() {
                if loadedIDs.contains(item.id) { loadedCount[index] += 1 } else { unloadedCount[index] += 1 }
            }

            if nonImproving >= options.nonImprovingLimit {
                longTermReinitialisation(
                    scores: &scores,
                    items: items,
                    best: searchBest,
                    options: options,
                    generator: &generator
                )
                // §5.3.3 states the step-size rule as part of reinitialisation, so it belongs here
                // rather than on every pass. Per pass the steps would saturate within four rounds.
                parameterUpdate(
                    best: searchBest,
                    knapsack: problem.knapsack,
                    decrease: &scoreDecrease,
                    increase: &scoreIncrease
                )
                reinitialisations += 1
                nonImproving = 0
            } else {
                scoreUpdate(
                    scores: &scores,
                    items: items,
                    loadedIDs: loadedIDs,
                    loadedCount: loadedCount,
                    unloadedCount: unloadedCount,
                    decrease: scoreDecrease,
                    increase: scoreIncrease
                )
            }

            if isBetterForSearch(current, than: searchBest, mode: options.centreOfMass.mode) {
                searchBest = current
                nonImproving = 0
            } else {
                nonImproving += 1
            }

            if isFeasible(current) {
                if let incumbent = bestFeasible {
                    if isBetterFeasible(current, than: incumbent, mode: options.centreOfMass.mode) {
                        bestFeasible = current
                        improvements += 1
                    }
                } else {
                    bestFeasible = current
                    improvements += 1
                }
            }
        }

        let elapsed = clock.now - startedAt
        let reported = bestFeasible
            ?? BaldiSolution(knapsack: problem.knapsack, placements: [], unloaded: problem.items)
        return BaldiSearchResult(
            solution: reported,
            initialSolution: initial.solution,
            initialCriterion: initial.criterion,
            iterations: iterations,
            improvements: improvements,
            reinitialisations: reinitialisations,
            runtimeSeconds: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) * 1e-18
        )
    }

    /// Ranking used while searching. Count first, then support and balance, then how central the
    /// load is — but only in centred mode.
    static func isBetterForSearch(
        _ candidate: BaldiSolution,
        than incumbent: BaldiSolution,
        mode: BaldiPackingMode = .paper
    ) -> Bool {
        if candidate.loadedCount != incumbent.loadedCount {
            return candidate.loadedCount > incumbent.loadedCount
        }
        if candidate.isFullySupported != incumbent.isFullySupported { return candidate.isFullySupported }
        if candidate.isBalanced != incumbent.isBalanced { return candidate.isBalanced }
        return mode == .centred && isCloserToIdeal(candidate, than: incumbent)
    }

    /// Ranking used for the result actually shown, which is always already feasible.
    static func isBetterFeasible(
        _ candidate: BaldiSolution,
        than incumbent: BaldiSolution,
        mode: BaldiPackingMode = .paper
    ) -> Bool {
        guard isFeasible(candidate) else { return false }
        guard isFeasible(incumbent) else { return true }
        if candidate.loadedCount != incumbent.loadedCount {
            return candidate.loadedCount > incumbent.loadedCount
        }
        return mode == .centred && isCloserToIdeal(candidate, than: incumbent)
    }

    private static func balance(
        _ solution: BaldiSolution,
        options: BaldiSearchOptions
    ) -> BaldiSolution {
        guard !solution.placements.isEmpty else { return solution }
        return BaldiSolution(
            knapsack: solution.knapsack,
            placements: BaldiBalancer.optimise(
                placements: solution.placements,
                knapsack: solution.knapsack,
                options: options.centreOfMass
            ),
            unloaded: solution.unloaded
        )
    }

    private static func initialScores(
        for items: [BaldiItem],
        loadedIn solution: BaldiSolution,
        options: BaldiSearchOptions
    ) -> [Double] {
        let loaded = Set(solution.placements.map(\.id))
        return items.map { loaded.contains($0.id) ? options.loadedScoreFactor * $0.profit : $0.profit }
    }

    /// Demotes the loaded package making the poorest use of its volume, promotes the most promising
    /// unloaded one, then swaps the two so they trade places in the next ordering.
    private static func scoreUpdate(
        scores: inout [Double],
        items: [BaldiItem],
        loadedIDs: Set<UUID>,
        loadedCount: [Int],
        unloadedCount: [Int],
        decrease: Double,
        increase: Double
    ) {
        var worstLoaded: Int?
        var worstLoadedValue = Double.infinity
        var bestUnloaded: Int?
        var bestUnloadedValue = -Double.infinity

        for (index, item) in items.enumerated() {
            let volume = Double(max(item.volume, 1))
            if loadedIDs.contains(item.id) {
                let value = (1 + Double(loadedCount[index])) * item.profit / volume
                if value < worstLoadedValue {
                    worstLoadedValue = value
                    worstLoaded = index
                }
            } else {
                let value = item.profit / (volume * (1 + Double(unloadedCount[index])))
                if value > bestUnloadedValue {
                    bestUnloadedValue = value
                    bestUnloaded = index
                }
            }
        }

        guard let loaded = worstLoaded, let unloaded = bestUnloaded else { return }
        scores[loaded] = (1 - decrease) * scores[loaded]
        scores[unloaded] = (1 + increase) * scores[unloaded]
        scores.swapAt(loaded, unloaded)
    }

    private static func longTermReinitialisation(
        scores: inout [Double],
        items: [BaldiItem],
        best: BaldiSolution,
        options: BaldiSearchOptions,
        generator: inout SeededGenerator
    ) {
        scores = initialScores(for: items, loadedIn: best, options: options)
        guard items.count > 1 else { return }
        let pairs = max(1, Int((Double(items.count) * options.reinitialisationPairFraction).rounded()))
        for _ in 0..<pairs {
            let first = Int.random(in: 0..<items.count, using: &generator)
            let offset = Int.random(in: 0..<(items.count - 1), using: &generator)
            scores.swapAt(first, offset >= first ? offset + 1 : offset)
        }
    }

    /// Widens the score steps while the best packing is still unbalanced, narrows them once it is
    /// comfortably inside the domain. Held below one so a score can never go negative.
    private static func parameterUpdate(
        best: BaldiSolution,
        knapsack: BaldiKnapsack,
        decrease: inout Double,
        increase: inout Double
    ) {
        if !best.isBalanced {
            decrease = min(0.9, 2 * decrease)
            increase = min(0.9, 2 * increase)
            return
        }
        let centre = best.centreOfMass
        var inCentralHalf = true
        for axis in 0..<3 {
            let low = knapsack.domainLower[axis]
            let high = knapsack.domainUpper[axis]
            let quarter = (high - low) / 4
            if centre[axis] < low + quarter || centre[axis] > high - quarter {
                inCentralHalf = false
                break
            }
        }
        if inCentralHalf {
            decrease = max(1e-4, decrease / 2)
            increase = max(1e-4, increase / 2)
        }
    }

    private static func isCloserToIdeal(_ candidate: BaldiSolution, than incumbent: BaldiSolution) -> Bool {
        let candidateDistance = candidate.centreOfMassDistanceToIdeal
        let incumbentDistance = incumbent.centreOfMassDistanceToIdeal
        guard candidateDistance.isFinite, incumbentDistance.isFinite else {
            return candidateDistance.isFinite && !incumbentDistance.isFinite
        }
        let scale = max(1, max(candidateDistance, incumbentDistance))
        return candidateDistance < incumbentDistance - scale * 1e-12
    }

    private static func isFeasible(_ solution: BaldiSolution) -> Bool {
        solution.loadedCount > 0 && solution.isBalanced && solution.isFullySupported
    }
}
