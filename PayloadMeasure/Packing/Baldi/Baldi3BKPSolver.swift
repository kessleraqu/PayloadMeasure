import Foundation

/// Production options for the support-aware 3BKP-H heuristic.
///
/// The Baldi-only MIP remains in `Baldi3BKPModel.swift` as a formulation reference. It is not a
/// solver for the Baldi–Junqueira hybrid because Junqueira's continuous support-area predicate is
/// evaluated on known placements rather than represented by that MIP.
nonisolated struct Baldi3BKPOptions: Sendable, Equatable {
    var heuristic = BaldiHeuristicOptions()

    init() {}
}

nonisolated struct Baldi3BKPResult: Sendable {
    nonisolated enum Status: String, Sendable, Equatable {
        /// A nonempty packing passed every independent feasibility check.
        case feasible
        /// The heuristic found no reportable packing before its stopping condition.
        case notFound
        case invalidInput
        /// A defensive state: heuristic output failed the independent verifier.
        case verificationFailed
    }

    var status: Status
    var solution: BaldiSolution?
    var verification: BaldiVerification?
    var errors: [String] = []
    /// Items removed before searching because they do not fit in the container in any rotation.
    var oversizedItems: [BaldiItem] = []

    var runtimeSeconds: Double = 0
    var heuristicDetail: BaldiHeuristicResult?
}

/// The two explicitly labelled outcomes for the same validated problem and base options.
nonisolated struct Baldi3BKPComparison: Sendable {
    let paper: Baldi3BKPResult
    let centred: Baldi3BKPResult

    func result(for mode: BaldiPackingMode) -> Baldi3BKPResult {
        switch mode {
        case .paper: paper
        case .centred: centred
        }
    }
}

/// Validates inputs, runs the support-aware Baldi heuristic and exposes a solution only after an
/// independent check of containment, rotations, non-overlap, full support and cargo balance.
nonisolated enum Baldi3BKPSolver {
    /// Solves the same problem under both CoM policies using structured child tasks. Each result
    /// retains its own status and verification; one mode failing does not erase the other result.
    static func solveBoth(
        _ problem: BaldiProblem,
        options: Baldi3BKPOptions = Baldi3BKPOptions()
    ) async -> Baldi3BKPComparison {
        let paperOptions: Baldi3BKPOptions = {
            var configured = options
            configured.heuristic.centreOfMass.mode = .paper
            return configured
        }()
        let centredOptions: Baldi3BKPOptions = {
            var configured = options
            configured.heuristic.centreOfMass.mode = .centred
            return configured
        }()

        async let paperResult = solve(problem, options: paperOptions)
        async let centredResult = solve(problem, options: centredOptions)
        return await Baldi3BKPComparison(
            paper: paperResult,
            centred: centredResult
        )
    }

    static func solve(
        _ problem: BaldiProblem,
        options: Baldi3BKPOptions = Baldi3BKPOptions()
    ) -> Baldi3BKPResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        func elapsed() -> Double {
            let duration = clock.now - startedAt
            return Double(duration.components.seconds)
                + Double(duration.components.attoseconds) * 1e-18
        }

        let errors = validationErrors(in: problem, options: options)
        guard errors.isEmpty else {
            var result = Baldi3BKPResult(status: .invalidInput, errors: errors)
            result.runtimeSeconds = elapsed()
            return result
        }

        let (fitting, oversized) = problem.partitionByFit()
        let reduced = BaldiProblem(knapsack: problem.knapsack, items: fitting)

        guard !fitting.isEmpty else {
            var result = Baldi3BKPResult(
                status: .notFound,
                errors: ["No measured package fits inside the payload container in any allowed rotation."],
                oversizedItems: oversized
            )
            result.runtimeSeconds = elapsed()
            return result
        }

        let detail = BaldiHeuristic.solve(reduced, options: options.heuristic)
        var solution = detail.solution
        solution.unloaded += oversized

        guard !solution.placements.isEmpty else {
            var result = Baldi3BKPResult(
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

        let verification = BaldiGeometryCheck.verify(solution, against: problem)
        let verified = verification.isValid
        var result = Baldi3BKPResult(
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
        options: Baldi3BKPOptions
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
