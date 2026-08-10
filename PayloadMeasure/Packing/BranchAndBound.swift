import Foundation

/// Exact branch-and-bound for the mixed-integer packing model.
///
/// Depth-first with dual-simplex warm starts. Depth-first is the right shape here for two reasons:
/// it dives straight at a first feasible arrangement, and — because a simplex basis is independent
/// of the variable bounds — a child node can continue from the tableau its parent left behind. Only
/// the branching bound changes, so a node normally costs a handful of pivots.
///
/// The search is honest about what it proved. If it explores the whole tree the result is optimal;
/// if it runs out of time it reports the best arrangement it found together with the dual bound of
/// everything it did not finish, so the optimality gap is a real number rather than a guess.
nonisolated struct MixedIntegerResult: Sendable {
    nonisolated enum Status: String, Sendable {
        /// A feasible point was found and the whole tree was explored.
        case optimal
        /// A feasible point was found but optimality was not proven within the limits.
        case feasible
        /// The whole tree was explored and no feasible point exists.
        case infeasible
        /// The limits were reached before any feasible point was found.
        case noSolutionFound
        case numericalFailure
    }

    var status: Status
    var values: [Double]
    var objectiveValue: Double?
    /// Valid lower bound on the true optimum.
    var dualBound: Double
    var provenOptimal: Bool
    var nodeCount: Int
    var simplexIterationCount: Int
    var runtimeSeconds: Double
    var hitTimeLimit: Bool

    var absoluteGap: Double? {
        guard let objectiveValue, dualBound.isFinite else { return nil }
        return max(0, objectiveValue - dualBound)
    }

    var relativeGap: Double? {
        guard let objectiveValue, let absoluteGap else { return nil }
        return abs(objectiveValue) > 1e-10 ? absoluteGap / abs(objectiveValue) : 0
    }
}

nonisolated final class BranchAndBound {
    nonisolated struct Options: Sendable {
        var timeLimitSeconds: Double = 8
        var nodeLimit: Int = 200_000
        var integralityTolerance: Double = 1e-6
        /// Nodes whose relaxation is no better than this much below the incumbent are cut off.
        var cutOffTolerance: Double = 1e-6
        /// A bound the objective can never go below. The packing objective is a non-negative
        /// weighted sum of deviations, so zero is always valid and often tightens the reported gap.
        var objectiveLowerBound: Double = 0
        /// Optional per-variable branching priority, highest first. Deciding a package's orientation
        /// before the relative placements settles its footprint and its contribution to the centre
        /// of mass, which is what the objective is actually made of; the separation indicators are
        /// then mostly a feasibility question.
        var branchingPriority: [Int] = []

        init() {}
    }

    private let program: LinearProgram
    private let options: Options
    private let simplex: Simplex
    private let integerIndices: [Int]

    private var incumbentValue = Double.infinity
    private var incumbentValues: [Double]?
    private var abandonedBound = Double.infinity
    private var exploredEverything = true
    private var nodeCount = 0
    private var deadline: ContinuousClock.Instant = .now
    private var hitTimeLimit = false

    init(program: LinearProgram, options: Options = Options()) {
        self.program = program
        self.options = options
        self.simplex = Simplex(program: program)
        self.integerIndices = program.integerVariableIndices
    }

    /// Seeds the search with a known feasible point, so the first bound cut-off is available before
    /// the dive reaches a leaf. Ignored unless the point really is integral and feasible.
    func addIncumbent(values: [Double], objectiveValue: Double) {
        guard objectiveValue < incumbentValue else { return }
        incumbentValue = objectiveValue
        incumbentValues = values
    }

    func solve() -> MixedIntegerResult {
        let clock = ContinuousClock()
        let startedAt = clock.now
        deadline = startedAt.advanced(by: .seconds(options.timeLimitSeconds))

        search()

        let runtime = Double((clock.now - startedAt).components.seconds)
            + Double((clock.now - startedAt).components.attoseconds) * 1e-18

        let status: MixedIntegerResult.Status
        var dualBound: Double
        if let value = incumbentValues, !value.isEmpty {
            if exploredEverything {
                status = .optimal
                dualBound = incumbentValue
            } else {
                status = .feasible
                dualBound = min(abandonedBound, incumbentValue)
            }
        } else if exploredEverything {
            status = .infeasible
            dualBound = .infinity
        } else {
            status = .noSolutionFound
            dualBound = abandonedBound
        }
        if dualBound.isFinite {
            dualBound = max(dualBound, options.objectiveLowerBound)
        }

        return MixedIntegerResult(
            status: status,
            values: incumbentValues ?? [],
            objectiveValue: incumbentValues == nil ? nil : incumbentValue,
            dualBound: dualBound,
            provenOptimal: exploredEverything && incumbentValues != nil,
            nodeCount: nodeCount,
            simplexIterationCount: simplex.iterationCount,
            runtimeSeconds: runtime,
            hitTimeLimit: hitTimeLimit
        )
    }

    // MARK: - Search

    private func abandon(bound: Double) {
        exploredEverything = false
        abandonedBound = min(abandonedBound, bound)
    }

    /// One open branch of the tree. The branching variable's bounds are currently set to
    /// `children[nextChild - 1]`; `savedLower`/`savedUpper` restore them when the frame is popped.
    private struct Frame {
        var variable: Int
        var savedLower: Double
        var savedUpper: Double
        var bound: Double
        var children: [(lower: Double, upper: Double)]
        var nextChild: Int
    }

    private enum NodeOutcome {
        case closed
        case branch(Frame)
    }

    /// Iterative depth-first search. The tree is walked with an explicit stack rather than by
    /// recursion: a model with a few hundred binaries can branch several hundred levels deep, and
    /// one relaxation point per recursion frame would be a real risk of overrunning the stack of a
    /// background thread.
    private func search() {
        var frames: [Frame] = []
        var parentBound = options.objectiveLowerBound
        var descending = true

        while true {
            if descending {
                switch processNode(parentBound: parentBound) {
                case .branch(var frame):
                    let child = frame.children[frame.nextChild]
                    frame.nextChild += 1
                    simplex.setBounds(of: frame.variable, lower: child.lower, upper: child.upper)
                    parentBound = frame.bound
                    frames.append(frame)
                    continue
                case .closed:
                    descending = false
                }
            }

            // Backtrack to the deepest frame that still has an unexplored child worth visiting.
            while var frame = frames.last {
                let exhausted = frame.nextChild >= frame.children.count
                let dominated = frame.bound >= incumbentValue - options.cutOffTolerance
                if exhausted || dominated {
                    simplex.setBounds(of: frame.variable, lower: frame.savedLower, upper: frame.savedUpper)
                    frames.removeLast()
                    continue
                }
                let child = frame.children[frame.nextChild]
                frame.nextChild += 1
                simplex.setBounds(of: frame.variable, lower: child.lower, upper: child.upper)
                parentBound = frame.bound
                frames[frames.count - 1] = frame
                descending = true
                break
            }

            if !descending { return }
        }
    }

    private func processNode(parentBound: Double) -> NodeOutcome {
        // The search runs inside a task; when the caller walks away from the result there is no
        // point spending another ten seconds of a phone's CPU next to a live AR session.
        if Task.isCancelled {
            abandon(bound: parentBound)
            return .closed
        }
        if ContinuousClock.now >= deadline {
            hitTimeLimit = true
            abandon(bound: parentBound)
            return .closed
        }
        if nodeCount >= options.nodeLimit {
            abandon(bound: parentBound)
            return .closed
        }
        nodeCount += 1

        // The root has no inherited basis worth warm-starting from, so it goes straight to the
        // primal method; every later node re-optimises from its parent's basis.
        let status = nodeCount == 1
            ? simplex.solvePrimal(deadline: deadline)
            : simplex.reoptimize(deadline: deadline)
        switch status {
        case .optimal:
            break
        case .infeasible:
            // The subtree is empty and contributes nothing to the global bound.
            return .closed
        case .timeLimit:
            hitTimeLimit = true
            abandon(bound: parentBound)
            return .closed
        case .iterationLimit, .numericalFailure:
            abandon(bound: parentBound)
            return .closed
        }

        let bound = max(parentBound, simplex.objectiveValue)
        if bound >= incumbentValue - options.cutOffTolerance { return .closed }

        let values = simplex.structuralValues()
        guard let branching = selectBranchingVariable(values: values) else {
            incumbentValue = bound
            incumbentValues = values
            return .closed
        }

        let variable = branching.index
        let savedLower = simplex.lower(of: variable)
        let savedUpper = simplex.upper(of: variable)
        let floorValue = values[variable].rounded(.down)
        let ceilingValue = floorValue + 1
        let downChild = (lower: savedLower, upper: min(savedUpper, floorValue))
        let upChild = (lower: max(savedLower, ceilingValue), upper: savedUpper)

        // Dive towards the nearer integer first: it is the child more likely to hold a feasible
        // arrangement, and an early incumbent is what makes the bound cut-off effective.
        var children = branching.fraction >= 0.5 ? [upChild, downChild] : [downChild, upChild]
        children.removeAll { $0.lower > $0.upper }
        guard !children.isEmpty else { return .closed }

        return .branch(
            Frame(
                variable: variable,
                savedLower: savedLower,
                savedUpper: savedUpper,
                bound: bound,
                children: children,
                nextChild: 0
            )
        )
    }

    private struct Branching {
        var index: Int
        var fraction: Double
    }

    private func priority(of variable: Int) -> Int {
        options.branchingPriority.indices.contains(variable) ? options.branchingPriority[variable] : 0
    }

    /// Most-fractional branching. The packing model's integer variables are all binaries with a
    /// direct geometric meaning, and the orientation one-hot groups are naturally resolved first
    /// because a fractional assignment shows up as a half-chosen orientation.
    private func selectBranchingVariable(values: [Double]) -> Branching? {
        var best: Branching?
        var bestDistance = 0.0
        var bestPriority = Int.min
        for index in integerIndices {
            let value = values[index]
            let fraction = value - value.rounded(.down)
            let distance = min(fraction, 1 - fraction)
            if distance <= options.integralityTolerance { continue }
            let rank = priority(of: index)
            if rank > bestPriority || (rank == bestPriority && distance > bestDistance) {
                bestPriority = rank
                bestDistance = distance
                best = Branching(index: index, fraction: fraction)
            }
        }
        return best
    }

    // MARK: - Polishing

    /// Re-solves the model as a pure LP with every integer variable pinned to its incumbent value.
    ///
    /// This matters because the non-overlap rows carry big-M terms: an integer the search accepts
    /// as `1 - 1e-9` leaks `M · 1e-9` of slack into a geometric constraint, which surfaces as a
    /// sub-micrometre overlap in the reported arrangement. With the integers pinned the big-M terms
    /// are constants and only the LP feasibility tolerance is left. Same model, same objective, so
    /// the objective can only stay equal or improve.
    func polishedSolution(for values: [Double]) -> (values: [Double], objectiveValue: Double)? {
        var saved: [(Int, Double, Double)] = []
        saved.reserveCapacity(integerIndices.count)
        for index in integerIndices {
            saved.append((index, simplex.lower(of: index), simplex.upper(of: index)))
            let pinned = values[index].rounded()
            simplex.setBounds(of: index, lower: pinned, upper: pinned)
        }
        defer {
            for (index, lower, upper) in saved {
                simplex.setBounds(of: index, lower: lower, upper: upper)
            }
            simplex.refreshPrimalValues()
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        guard simplex.reoptimize(deadline: deadline) == .optimal else { return nil }
        return (simplex.structuralValues(), simplex.objectiveValue)
    }
}
