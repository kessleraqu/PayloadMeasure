import Foundation

/// The item sorting criteria of paper §5.1, together with the clustering of eqs. (22) and (23).
///
/// From the paper: the attributes that matter to the sorting are the profit, the specific weight
/// `sw`, and the area — for three-dimensional problems the item's projection on the (x, y) plane
/// (Fig. 8). Combining them pairwise gives six criteria, each written "clustered A, sorted B":
/// items are first grouped into clusters of close values of A, and then sorted by B inside each
/// cluster. "Giving more importance to an attribute means to favor those items showing the highest
/// values of that attribute or score", so both the clusters and the within-cluster order run from
/// the highest value down.
nonisolated enum BaldiSortingCriterion: String, Sendable, CaseIterable {
    /// Clustered area, sorted specific weight.
    case areaSpecificWeight = "a-sw"
    /// Clustered area, sorted profit.
    case areaProfit = "a-p"
    /// Clustered specific weight, sorted area.
    case specificWeightArea = "sw-a"
    /// Clustered specific weight, sorted profit.
    case specificWeightProfit = "sw-p"
    /// Clustered profit, sorted specific weight.
    case profitSpecificWeight = "p-sw"
    /// Clustered profit, sorted area.
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

nonisolated enum BaldiSorting {
    /// Cluster width as a percentage of the attribute's range, the paper's `θ ∈ [1, 100]`.
    ///
    /// The paper defines `θ` and derives the number of clusters from it, `n_c = ⌈100/θ⌉`, but never
    /// states the value used in its experiments. Twenty per cent — five clusters — is the value
    /// used here and is exposed as a setting rather than buried.
    static let defaultTheta: Double = 20

    /// The cluster index of `value`, 1-based, per eq. (22):
    ///
    ///   A_i(θ) = [A_min + (i−1)(A_max − A_min)θ/100, A_min + i(A_max − A_min)θ/100]
    ///
    /// and, when the attribute is the area clustered over the whole knapsack basis, eq. (23) with
    /// `A_min = 0` and `A_max = W · D`.
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

    /// Orders the items by one of the six criteria.
    static func order(
        _ items: [BaldiItem],
        by criterion: BaldiSortingCriterion,
        knapsack: BaldiKnapsack,
        theta: Double = defaultTheta
    ) -> [BaldiItem] {
        guard !items.isEmpty else { return [] }

        let clustered = criterion.clusteredAttribute
        let sorted = criterion.sortedAttribute

        // Eq. (23): the area is clustered over the knapsack basis area, so its range is fixed at
        // [0, W·D] rather than taken from the items. Every other attribute uses eq. (22), whose
        // range is the extreme values found among the items.
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
                // A stable tie-break so a given item list always produces the same order.
                return left.index < right.index
            }
            .map(\.item)
    }
}
