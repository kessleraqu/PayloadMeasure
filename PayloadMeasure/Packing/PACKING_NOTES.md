# Load-balanced payload arrangement

This folder adds the payload-arrangement stage to PayloadMeasure: once the operator has measured,
named and weighed a set of objects, it decides where each one goes inside the payload module and
shows the result as a to-scale drawing plus a numbered loading order.

It is a Swift reimplementation of the browser tool in `../../../PackingOptimization`, extended with
the adaptations set out in that project's `modifications` chapter. Nothing in the other project was
modified; it was read as the reference.

## Source

Formulation: **Kaluzny & Shaw, "Optimal aircraft load balancing"**, *International Transactions in
Operational Research* 16 (2009) 767–787, doi:10.1111/j.1475-3995.2009.00723.x.

Adaptation to the modular payload system: the project chapter *Load-Balanced Payload Arrangement*
(`PackingOptimization/modifications`), §"Adaptation to the Modular Payload System".

## What the model decides

All of it simultaneously, as one mixed-integer linear program. There is no greedy, sequential,
bottom-left or row-based placement step anywhere in the pipeline, and nothing is repositioned after
the solve.

* the free continuous position of every package's geometric centre on the module floor;
* the axis-aligned orientation of every package;
* which of the four relative placements separates each pair of packages;
* the resulting centre of mass of the complete connected system.

## Coordinate system

Origin at the centre of the module floor, following the chapter:

| axis | direction | range |
| --- | --- | --- |
| `x` | along the module (the aircraft's longitudinal axis) | −L/2 … +L/2 |
| `y` | across the module | −W/2 … +W/2 |
| `z` | up from the floor | 0 … H |

Default module: **L = 800 mm, W = 200 mm, H = 100 mm** — the project's 20 × 80 × 10 cm compartment.
Every dimension is editable in the arrangement settings. Lengths are millimetres, masses kilograms.

## Model map

| Element | Paper / chapter | Implementation |
| --- | --- | --- |
| Position variables | paper §2.3 | continuous `x_i`, `y_i` — `PackingModel.swift` |
| Orientation | chapter, axis-aligned 3D orientations | one-hot binaries `u_ik` over the height-feasible set `K_ib` |
| Oriented half-extents | chapter, `[X,Y,Z]ᵀ = ½|R_ik| d_i` | precomputed per orientation, entered affinely into every row |
| Rotated COM offset | chapter, `Δ_ik = R_ik δ_i` | precomputed per orientation |
| Module height limit | chapter, `2Z_ik + 2s_i^z ≤ H_b` | orientations that do not fit are removed before solving |
| Boundaries | paper (33)–(34), chapter's adapted form | `wallXlo/hi`, `wallYlo/hi` |
| Non-overlap | paper (35)–(38), chapter `γ¹…γ⁴` | four big-M rows per pair plus an activation row |
| Big-M | paper §2.5.3 | one value per row, derived from the module and the variable box — never a single loose global constant |
| Centre of mass | paper (7)–(8), chapter's connected-system COM | mass-weighted average including the empty module and the airframe |
| Objective | paper (9)–(10), chapter `J = w_x e_x + w_y e_y + w_z e_z` | L1 deviation from the target, linearised with non-negative deviation variables |
| Envelope | paper (11)–(12), chapter's adapted envelope | hard bounds on the centre-of-mass variables |
| Transitivity | paper §3.1, (23)–(24) | three-cycle exclusions, restated for the `γ` encoding — `PackingCuts.swift` |
| Identical-item symmetry | paper (25) | ordering along `x` within a group of identical packages |
| Fitting cuts, pairs and triples | paper (26)–(28), (43)–(44) | evaluated per orientation group |

## Which of the chapter's limitations are addressed

The chapter lists six extensions the reference formulation needs for this project.

| Extension | Status |
| --- | --- |
| Three-dimensional object orientations | **Implemented.** All 24 proper axis-aligned rotations, reduced to the observationally distinct ones and filtered by the module height. |
| Centre of mass of the complete connected UAV | **Implemented.** `c` includes the cargo, the empty module and the airframe, and is minimised on all three axes with per-axis weights. |
| Empty masses and centres of mass of the payload modules | **Implemented.** `m_b⁰`, `c_b⁰`, `m_0` and `c_0` are all inputs; leaving them at zero balances the cargo by itself. |
| Assignment of objects to two payload modules | **Not implemented** — one module was the chosen scope for this build. |
| Selection of the connection between the modules | **Not implemented**, for the same reason. |
| Support and load-bearing constraints | **Not implemented.** The chapter's own adapted model does not stack: every package rests on the module floor, so `z` is not a free variable and no package ever bears another. |

The single-module model is the two-module model with `B = {1}`: `a_ib ≡ 1`, so the assignment
binaries collapse and the chapter's activation right-hand side `a_ib + a_jb − 1` becomes 1. Adding
the second module later means restoring `u_ibk`, the per-module position variables and the
activation form, not rewriting the formulation.

Deliberate departures from the paper, inherited from the reference implementation:

* **Item selection (paper §5) is not used.** Every measured package must be loaded. If no complete
  arrangement exists the tool reports an explicit infeasibility instead of quietly dropping one.
* **A hierarchical second objective** minimises the occupied floor rectangle, but only after the
  centre-of-mass objective has been *proven* optimal, and subject to keeping it there. The two
  objectives are never blended with weights.

## Solver

There is no third-party solver: the browser tool uses HiGHS compiled to WebAssembly, which has no
counterpart here, and the project's constraint is to minimise dependencies. `Simplex.swift` and
`BranchAndBound.swift` are a self-contained exact MILP solver.

* **Bounded-variable simplex over a dense tableau**, with both methods. The primal (phase 1 then
  phase 2) solves a node from cold; the dual re-optimises after a branching bound change. Both are
  needed. The objective touches only the three deviation variables, so almost every reduced cost is
  zero and a dual ratio test ties everywhere — from cold it wanders and does not converge. The
  primal phase-1 objective, total bound infeasibility, is a real gradient. Conversely a simplex
  basis does not depend on variable bounds, so a child node inherits its parent's basis and the dual
  method usually finishes it in a handful of pivots.
* **Numerical care.** A dense tableau updated in place drifts, and big-M rows punish that hard: one
  pivot on a near-zero entry can make the reduced costs meaningless, after which the search deletes
  parts of the tree and reports a wrong "optimal". Three things prevent it — a Harris two-pass ratio
  test that takes the largest pivot among near-equal candidates, a pivot floor relative to the
  entering column, and refactorisation of the tableau from the basis and the original matrix. The
  dual method's "optimal" and "infeasible" conclusions are additionally verified against the
  dual-feasibility condition before they are trusted, and fall back to a primal solve if it fails.
* **Depth-first branch and bound** with an explicit stack (a few hundred binaries can branch several
  hundred levels deep). Most-fractional branching, diving towards the nearer integer first.
* **LP polish.** After the search, the same model is re-solved with the integers pinned. The
  non-overlap rows carry big-M terms, so an integer accepted as `1 − 1e−9` leaks `M · 1e−9` of slack
  into a geometric constraint; pinning removes it.
* **Honest reporting.** If the whole tree is explored the result is *optimal*. If the time limit is
  reached first, it is *feasible*, with the dual bound of everything left unexplored, so the
  reported optimality gap is a real number.
* **Independent verification.** `PackingGeometryCheck` re-derives every property from the reported
  placement alone — containment, wall and neighbour clearances, height, orientation legality, the
  centre of mass — so it checks the model and the solver rather than restating them. A failed
  verification downgrades the result out of "proven optimal".

## Performance

One test family of packages 70–150 mm on a side, 2 mm clearances, balance phase only, full cut set,
on an Apple M2. Times are to *prove* optimality, with a 30 s limit:

| packages | binaries | rows | result |
| --- | --- | --- | --- |
| 6 | 85 | 233 | optimal, 0.11 s |
| 8 | 144 | 473 | optimal, 0.98 s |
| 9 | 182 | 646 | optimal, 2.09 s |
| 10 | 222 | 862 | an arrangement, not proven optimal |
| 11–12 | 268–316 | 939–999 | no arrangement found within 30 s |

**Nine packages is the practical ceiling for a proven-optimal answer**, and it is a reasonable one:
nine packages of that size already occupy more than half of a 20 × 80 cm floor. Past ten the dense
tableau, not the search tree, is the bottleneck — a node costs hundreds of pivots over a
1000 × 1400 matrix. Getting further would mean a sparse LU-factorised revised simplex rather than a
dense tableau; the model itself would not change.

Defaults are 12 s for the balance phase and 5 s for the packing phase, both adjustable in the
settings. Past the limit the best arrangement found so far is shown with its true gap, and if
nothing was found the screen says so rather than implying the load cannot fit.

Two things earn most of the speed. **Branching on the orientation binaries before the separation
indicators** is worth an order of magnitude: it settles each package's footprint and its
contribution to the centre of mass — which is what the objective is made of — before spending
nodes on relative placements. Without it the same nine-package instance did not finish in 25 s. The
**valid inequalities** are worth roughly another factor of six at nine packages (2.1 s against
12.8 s), though they cost rows, and past ten packages that cost starts to outweigh the benefit.

## Files

```
LinearProgram.swift         solver-independent model container + CPLEX LP writer
Simplex.swift               bounded-variable primal and dual simplex, dense tableau
BranchAndBound.swift        depth-first exact search, warm-started, with gap reporting
PackingProblem.swift        module, package, orientation enumeration, validation
PackingModel.swift          the MILP
PackingCuts.swift           valid inequalities, individually switchable
PackingSolution.swift       solution extraction + independent geometric verification
PackingOptimizer.swift      solve driver and the two hierarchical phases
PackingStore.swift          bridge from the measured objects, off-main-actor solving
PackingArrangementView.swift  the result screen
PackingPlanView.swift       to-scale plan and elevation drawing
PackingSettingsView.swift   module, balance target and solver settings
```

`LinearProgram.lpFormat()` writes the model in CPLEX LP format. It is not used at runtime; it exists
so a model built on the device can be exported and re-solved with a reference solver, which is how
this implementation is checked against the browser one.
