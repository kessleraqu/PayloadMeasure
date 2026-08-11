# Methods and sources

What the two arrangement methods take from the literature, where this implementation departs from
it, and what it does not claim. `NOTES.md` covers the code layout.

## Sources

**Balance**
> B. L. Kaluzny, R. H. A. D. Shaw, "Optimal aircraft load balancing", *International Transactions in
> Operational Research* 16 (2009) 767–787.

adapted per the project chapter *Load-Balanced Payload Arrangement* in `PackingOptimization/modifications`.

**3D knapsack**
> M. M. Baldi, G. Perboli, R. Tadei, "The three-dimensional knapsack problem with balancing
> constraints", *Applied Mathematics and Computation* 218 (2012) 9802–9818.

> L. Junqueira, R. Morabito, D. S. Yamashita, "Three-dimensional container loading models with cargo
> stability and load bearing constraints", *Computers & Operations Research* 39 (2012) 74–85.

---

# Balance

Everything on the floor, nothing left behind, centre of mass pulled to a target. One mixed-integer
program decides all positions, orientations and pairwise relations at once — no sequential or
bottom-left placement anywhere, and nothing is nudged afterwards.

Frame: origin at the centre of the module floor, `x` along the module, `y` across, `z` up.
Default module 800 × 200 × 100 mm.

| Element | Paper / chapter | Code |
| --- | --- | --- |
| Position variables | §2.3 | continuous `x_i`, `y_i` |
| Orientation | chapter, axis-aligned 3D | one-hot binaries over the height-feasible set |
| Oriented half-extents, rotated COM offset | chapter | precomputed per orientation |
| Module height limit | chapter | orientations too tall are dropped before solving |
| Boundaries | (33)–(34) | `wallXlo/hi`, `wallYlo/hi` |
| Non-overlap | (35)–(38) | four big-M rows per pair plus an activation row |
| Big-M | §2.5.3 | one value per row from the module and variable box, never a global constant |
| Centre of mass | (7)–(8) | mass-weighted average including empty module and airframe |
| Objective | (9)–(10) | L1 deviation, linearised with non-negative deviation variables |
| Envelope | (11)–(12) | hard bounds on the centre-of-mass variables |
| Transitivity | §3.1, (23)–(24) | three-cycle exclusions |
| Identical-item symmetry | (25) | ordering along `x` within a group |
| Fitting cuts | (26)–(28), (43)–(44) | evaluated per orientation group |

**Chapter extensions implemented:** three-dimensional orientations; centre of mass of the complete
connected aircraft on all three axes with per-axis weights; empty module and airframe masses.

**Chapter extensions not implemented:** assignment across two modules, and the choice of connection
between them — one module was the scope. Support and load bearing do not arise: the chapter's model
keeps every package on the floor.

**Deliberate departures:** item selection is not used, so every package must be loaded or the result
is an explicit infeasibility; and the compactness objective is hierarchical, applied only after the
balance objective is proven optimal and never blended into it.

**Solver.** No third-party dependency. `MILPSolver.swift` is a bounded-variable simplex with both
primal and dual methods, driven by depth-first branch and bound. The primal solves a node cold — the
objective touches only three variables, so a dual ratio test ties everywhere and wanders. The dual
re-optimises after a branching bound change, which is cheap because a basis does not depend on
bounds. Numerical care: Harris ratio test, a pivot floor relative to the entering column, periodic
refactorisation from the basis, and verification of the dual method's conclusions before they are
trusted.

**Reported honestly.** Optimal only when the whole tree was explored. Otherwise the best arrangement
found with its true gap.

---

# 3D knapsack

Stacks in three dimensions, loads the subset it can, and treats balance as a hard constraint. Frame:
origin at the bottom-left-back corner, container in the first octant.

## What is taken from Baldi

| Element | Use |
| --- | --- |
| One container, selectable items | retained |
| Six orthogonal rotations | retained |
| Rotated dimensions | retained |
| Cargo centre of mass, eq. (2) | retained |
| Hard centre-of-mass domain `[L, U]` | retained as feasibility |
| Unbalancing index, eqs. (3)–(4) | computed and shown on the result screen; the search does not use it |
| Extreme Points and Residual Space, §5.1 | retained |
| EP-BPH and its best-fit rule, eq. (21) | retained, with support added to the candidate gate |
| Clustering, eqs. (22)–(23), and the six criteria | retained |
| PCH opening solution | retained |
| Centre-of-mass adjustment, eqs. (25)–(29) | retained; see the three departures below |
| Scoring, §5.3.1–§5.3.4, and the Fig. 6 loop | retained |

Default domain is the paper's own instance setting: `L = (W/4, D/4, 0)`, `U = (3W/4, 3D/4, H/2)`.

## What this project fixes as an input

- **Equal priority.** Every package has value 1, so the objective is loaded-package count. There is
  no measured or editable package value.
- **Geometric-centre package mass.** Each package's centre of mass is the middle of its box, which
  matches the paper's benchmark generator but is narrower than its general formulation.
- **Merit coefficient zero.** The paper's `F = P − αU` reduces to `F = P`. Domain membership is
  separately mandatory. Distance from the domain centre breaks ties only between verified packings
  that load the same number of packages; it cannot override the count objective.
- **One rigid container.** Packages are rigid, supporting packages are assumed strong enough, and
  restraint against horizontal sliding is assumed.

## Vertical support, from Junqueira

Baldi's model has no support term at all — it will place a package in mid-air. Junqueira's
equation (11) requires a chosen fraction of a package's bottom face to be carried by packages
directly below. This project fixes that fraction to 1: complete support.

Evaluated on the continuous coordinates Baldi's heuristic produces, rather than on Junqueira's
discrete grid:

1. A package at `z = 0`, within contact tolerance, is carried by the floor.
2. Otherwise only a package whose top face is at the target's bottom height, within tolerance, can
   support it.
3. Each supporter's top face is clipped to the target's bottom footprint.
4. The **union** of those rectangles is measured, not their sum, so tolerance cannot double-count.
5. The package passes only when the union covers its whole bottom face.

Junqueira sums the contact areas; this unions them. Under the non-overlap constraints the two are
equal, so nothing is lost, and the union cannot double-count where a tolerance makes two supporters
appear to share a strip. Junqueira also notes that eq. (11) is only valid on reduced normal-pattern
sets when α = 1 (his Fig. 5), which is exactly the case used here.

His load-bearing constraint (14) and horizontal-stability constraints (12)–(13) are not
implemented; see the scope note at the end.

This is a continuous-coordinate evaluation of Junqueira's rule, not a reimplementation of his MILP.
Support is enforced during construction, after every tentative balancing move, and again by the
independent verifier, so no package ever floats.

## Three departures in the balancing procedure, §5.2

All three follow from making support a hard constraint, which Baldi's §5.2 does not have.

**Gravity is replaced, not omitted.** §5.2 ends by compacting every item along z towards the floor,
which is Baldi's repair for the mid-air placements his model permits. Full support forbids those
placements in the first place, so there is nothing to repair, and compacting afterwards would move
mass and undo the balance the procedure had just achieved.

**A fallback when the prescribed move is unsupported.** The move §5.2 prescribes — eq. (28), then
eq. (29), then clamped into `D_i` — is attempted first and taken whenever the packing stays valid,
with no improvement test, because eq. (28) already aims at the target. Only when full support
rejects that one point does the code look further: the same point at each available resting height,
then single-axis moves, accepting the best that strictly improves. Without a fallback the added
constraint would simply block most moves and the load would never balance.

**The best arrangement seen is returned, not the last.** §5.2's move is exact by construction, so
the paper has no reason to guard against drift. Once clamping and support can force partial moves,
a run of them can end worse than it started. Balanced always beats unbalanced, then closeness to
target. Measured over 40 random instances the guard changes nothing — mean distance to target 103
mm in paper mode either way, 40/40 balanced — it only removes the possibility.

## Two repairs to the printed reference model

Kept in `KnapsackReferenceModel.swift`, which the app does not run.

**Equation (10)** prints `ρ_ir` under a summation over item *j*'s sizes, which would size package
`j` by package `i`'s rotation. Its stated meaning and its symmetry with (9) require `ρ_jr`.

**Equation (16)** prints `Σ_r ρ_ir = 1`, giving every package a rotation whether or not it is
loaded. An unloaded package is pinned to the origin by (11) but its offset term stays in the
balancing rows (14)–(15) while its mass is absent from the right-hand side. With everything
unloaded, (15) reads `Σ m_i γ ≤ 0`, which nothing satisfies — the empty packing is infeasible, and
so is any packing that leaves out enough mass. In a knapsack. The repair is one right-hand side,
`Σ_r ρ_ir = t_i`, after which the moment matches the centre-of-mass expression the paper writes
immediately below (15).

## Parameters the papers leave open

| Symbol | Value used | Why |
| --- | --- | --- |
| `M` | `S^δ` per dimension | Smallest value that cannot cut off a feasible point. |
| `α` in `F = P − αU` | 0 | §5.2 defers to §5.3, which only sets the scoring `α`. The symbol is reused for two different parameters and this one is never given. |
| `θ`, cluster width | 20 %, five buckets | Defined but never valued. |
| Ideal point `r⁰` | centre of `[L, U]` | The only choice symmetric in the constraint. |
| Balancing iteration cap | 50 | Named as a stopping condition, never valued. |
| Balancing order | heaviest first | Not fixed. A heavy package needs the shortest move to shift the centre of mass. |
| Reinitialisation trigger | 1000 non-improving rounds | §5.3.4 says "every 1000 iterations"; Fig. 6 labels the box "Non Improving Iter. Limit". |
| When the score steps adapt | at reinitialisation | §5.3.3 states the α = 2α / β = 2β rule as part of reinitialisation; Fig. 6 draws Parameter Update on every pass. The prose wins: run per pass, both steps double from 0.1 to the cap within four rounds and stay there, so the adaptation the paper describes would never happen. |
| Score step bounds | held in `(0, 0.9]` | The update doubles them; unbounded doubling would make a score negative. |
| Randomness | seeded generator | "Randomly selected", made reproducible. |

Taken unchanged: score steps starting at 0.1, opening-score factor 3, 5 % of packages swapped at
reinitialisation, a 5 s stopping time, six rotations, and the instance domain.

## What this is not

- Not a 1-to-1 implementation of either paper. It is Baldi's heuristic, specialised as above, with
  Junqueira's support condition evaluated on continuous coordinates.
- Not an exact solver, and not a proof of optimality. The result is the best **verified feasible**
  packing found in the search time.
- Not a proof of infeasibility when nothing is found — only that nothing was found in the time given.
- Not a model of load-bearing strength, deformation, friction, vibration or flight loads.

## Scope of the physical claim

The result screen states this per method. After the support rule, no package floats and every one is
completely carried. What is still outside the model: how many packages do the carrying, whether a
supporting package is strong enough, fragility limits, clearances between packages, and any dynamic
load. A package may be carried entirely by one other package.
