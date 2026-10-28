import Foundation

// Entry point for the 3D knapsack. Validates the input, runs the heuristic and only returns
// packings the verifier accepts. `solveBoth` runs both packing modes concurrently.

nonisolated struct BaldiOptions: Sendable, Equatable {
    var heuristic = BaldiSearchOptions()

    init() {}
}

nonisolated struct BaldiResult: Sendable {
    nonisolated enum Status: String, Sendable, Equatable {
        case feasible
        case notFound
        case invalidInput
        case verificationFailed
    }

    var status: Status
    var solution: BaldiSolution?
    var verification: BaldiVerification?
    var errors: [String] = []
    var oversizedItems: [BaldiItem] = []

    var runtimeSeconds: Double = 0
    var heuristicDetail: BaldiSearchResult?
}

nonisolated struct BaldiComparison: Sendable {
    let paper: BaldiResult
    let centred: BaldiResult

    func result(for mode: BaldiPackingMode) -> BaldiResult {
        switch mode {
        case .paper: paper
        case .centred: centred
        }
    }
}

nonisolated enum BaldiSolver {
    static func solveBoth(
        _ problem: BaldiProblem,
        options: BaldiOptions = BaldiOptions()
    ) async -> BaldiComparison {
        let paperOptions: BaldiOptions = {
            var configured = options
            configured.heuristic.centreOfMass.mode = .paper
            return configured
        }()
        let centredOptions: BaldiOptions = {
            var configured = options
            configured.heuristic.centreOfMass.mode = .centred
            return configured
        }()

        async let paperResult = solve(problem, options: paperOptions)
        async let centredResult = solve(problem, options: centredOptions)
        return await BaldiComparison(
            paper: paperResult,
            centred: centredResult
        )
    }

    static func solve(
        _ problem: BaldiProblem,
        options: BaldiOptions = BaldiOptions()
    ) -> BaldiResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        func elapsed() -> Double {
            let duration = clock.now - startedAt
            return Double(duration.components.seconds)
                + Double(duration.components.attoseconds) * 1e-18
        }

        let errors = validationErrors(in: problem, options: options)
        guard errors.isEmpty else {
            var result = BaldiResult(status: .invalidInput, errors: errors)
            result.runtimeSeconds = elapsed()
            return result
        }

        let (fitting, oversized) = problem.partitionByFit()
        let reduced = BaldiProblem(knapsack: problem.knapsack, items: fitting)

        guard !fitting.isEmpty else {
            var result = BaldiResult(
                status: .notFound,
                errors: ["No measured package fits inside the payload container in any allowed rotation."],
                oversizedItems: oversized
            )
            result.runtimeSeconds = elapsed()
            return result
        }

        let detail = BaldiSearch.solve(reduced, options: options.heuristic)
        var solution = detail.solution
        solution.unloaded += oversized

        guard !solution.placements.isEmpty else {
            var result = BaldiResult(
                status: .notFound,
                errors: [
                    "No supported and balanced arrangement was found within the search time. This does not prove that none exists.",
                ],
                oversizedItems: oversized,
                heuristicDetail: detail
            )
            result.runtimeSeconds = elapsed()
            return result
        }

        let verification = BaldiVerifier.verify(solution, against: problem)
        let verified = verification.isValid
        var result = BaldiResult(
            status: verified ? .feasible : .verificationFailed,
            solution: verified ? solution : nil,
            verification: verification,
            errors: verified ? [] : verification.violations,
            oversizedItems: oversized,
            heuristicDetail: detail
        )
        result.runtimeSeconds = elapsed()
        return result
    }

    private static func validationErrors(
        in problem: BaldiProblem,
        options: BaldiOptions
    ) -> [String] {
        var errors: [String] = []
        let size = problem.knapsack.size
        if size.x <= 0 || size.y <= 0 || size.z <= 0 {
            errors.append("The payload container must have a positive size on every axis.")
        } else {
            let (baseArea, areaOverflow) = size.x.multipliedReportingOverflow(by: size.y)
            let (_, volumeOverflow) = baseArea.multipliedReportingOverflow(by: size.z)
            if areaOverflow || volumeOverflow {
                errors.append("The payload container dimensions are too large to represent safely.")
            }
        }
        if problem.items.isEmpty {
            errors.append("Add at least one measured package.")
        }

        var identifiers: Set<UUID> = []
        for item in problem.items {
            if !identifiers.insert(item.id).inserted {
                errors.append("The package list contains a duplicate identifier for “\(item.name)”.")
            }
            if item.size.x <= 0 || item.size.y <= 0 || item.size.z <= 0 {
                errors.append("“\(item.name)” has a non-positive dimension.")
            } else {
                let (baseArea, areaOverflow) = item.size.x.multipliedReportingOverflow(by: item.size.y)
                let (_, volumeOverflow) = baseArea.multipliedReportingOverflow(by: item.size.z)
                if areaOverflow || volumeOverflow {
                    errors.append("“\(item.name)” has dimensions too large to represent safely.")
                }
            }
            if !item.mass.isFinite || item.mass <= 0 {
                errors.append("“\(item.name)” has no weight. Enter its weight before arranging the load.")
            }
        }

        for axis in 0..<3 {
            let lower = problem.knapsack.domainLower[axis]
            let upper = problem.knapsack.domainUpper[axis]
            guard lower.isFinite, upper.isFinite else {
                errors.append("The centre-of-mass domain has a non-finite value on axis \(axis + 1).")
                continue
            }
            if lower > upper {
                errors.append("The centre-of-mass domain is empty on axis \(axis + 1).")
            }
            if lower < 0 || upper > Double(size[axis]) {
                errors.append("The centre-of-mass domain lies outside the container on axis \(axis + 1).")
            }
        }

        let heuristic = options.heuristic
        if !heuristic.timeLimitSeconds.isFinite || heuristic.timeLimitSeconds <= 0 {
            errors.append("The heuristic time limit must be a finite positive number.")
        }
        if !heuristic.scoreDecrease.isFinite
            || heuristic.scoreDecrease <= 0
            || heuristic.scoreDecrease >= 1 {
            errors.append("The score-decrease fraction must lie strictly between zero and one.")
        }
        if !heuristic.scoreIncrease.isFinite
            || heuristic.scoreIncrease <= 0
            || heuristic.scoreIncrease >= 1 {
            errors.append("The score-increase fraction must lie strictly between zero and one.")
        }
        if !heuristic.loadedScoreFactor.isFinite || heuristic.loadedScoreFactor <= 0 {
            errors.append("The loaded-item score factor must be a finite positive number.")
        }
        if heuristic.nonImprovingLimit <= 0 {
            errors.append("The non-improving iteration limit must be positive.")
        }
        if !heuristic.reinitialisationPairFraction.isFinite
            || heuristic.reinitialisationPairFraction <= 0
            || heuristic.reinitialisationPairFraction > 1 {
            errors.append("The score-reinitialisation pair fraction must lie in (0, 1].")
        }
        if !heuristic.clusterTheta.isFinite
            || heuristic.clusterTheta < 1
            || heuristic.clusterTheta > 100 {
            errors.append("The clustering width must lie between 1% and 100%.")
        }
        if heuristic.centreOfMass.maximumIterations < 0 {
            errors.append("The centre-of-mass iteration limit cannot be negative.")
        }
        return errors
    }
}
