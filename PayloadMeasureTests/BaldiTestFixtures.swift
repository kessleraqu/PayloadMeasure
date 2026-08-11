import Foundation
import simd
@testable import PayloadMeasure

enum BaldiTestFixtures {
    static let upright = BaldiRotation.all[0]

    static func item(
        id: UUID = UUID(),
        name: String = "Package",
        size: SIMD3<Int> = SIMD3(10, 10, 10),
        mass: Double = 1
    ) -> BaldiItem {
        BaldiItem(id: id, name: name, size: size, mass: mass)
    }

    static func placement(
        id: UUID = UUID(),
        name: String = "Package",
        origin: SIMD3<Double>,
        size: SIMD3<Int> = SIMD3(10, 10, 10),
        mass: Double = 1,
        rotation: BaldiRotation = upright
    ) -> BaldiPlacement {
        BaldiPlacement(
            id: id,
            name: name,
            origin: origin,
            rotation: rotation,
            size: size,
            mass: mass
        )
    }

    static func knapsack(
        size: SIMD3<Int> = SIMD3(100, 100, 100),
        domainLower: SIMD3<Double>? = nil,
        domainUpper: SIMD3<Double>? = nil
    ) -> BaldiKnapsack {
        BaldiKnapsack(
            size: size,
            domainLower: domainLower ?? .zero,
            domainUpper: domainUpper ?? SIMD3(
                Double(size.x),
                Double(size.y),
                Double(size.z)
            )
        )
    }

    static func problem(
        items: [BaldiItem],
        knapsack: BaldiKnapsack = knapsack()
    ) -> BaldiProblem {
        BaldiProblem(knapsack: knapsack, items: items)
    }

    static func solution(
        placements: [BaldiPlacement],
        unloaded: [BaldiItem] = [],
        knapsack: BaldiKnapsack = knapsack()
    ) -> BaldiSolution {
        BaldiSolution(knapsack: knapsack, placements: placements, unloaded: unloaded)
    }
}
