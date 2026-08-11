# 3BKP — the three-dimensional knapsack problem with balancing constraints

A 1-to-1 implementation of

> M. M. Baldi, G. Perboli, R. Tadei, **"The three-dimensional knapsack problem with balancing
> constraints"**, *Applied Mathematics and Computation* 218 (2012) 9802–9818,
> doi:[10.1016/j.amc.2012.03.052](https://doi.org/10.1016/j.amc.2012.03.052)

This is the app's second arrangement formulation. It sits beside the load-balanced one
(`../PACKING_NOTES.md`, Kaluzny & Shaw 2009 as adapted in the project chapter) and is selected with
the segmented control at the top of the arrangement screen. The two solve different problems on the
same measurements:

| | Load balanced (Kaluzny) | 3D knapsack (Baldi) |
| --- | --- | --- |
| Items loaded | all of them, or infeasible | the most profitable subset that fits |
| Objective | minimise centre-of-mass deviation | maximise profit |
| Balance | objective, with an optional envelope | **hard constraint**, a box domain |
| Placement | 2D, everything on the floor | **3D, stacking allowed** |
| Clearances | per item, to walls and neighbours | none — the 3BKP has no spacing |
| Method | one exact MILP | 3BKP-M exact model, or the 3BKP-H heuristic |

## Coordinate system

The paper's, unchanged: origin at the bottom-left-back corner, knapsack in the first octant from
`(0,0,0)` to `(W, D, H)`, and `χ^δ_i` the bottom-left-back corner of item `i`. The app's 20 × 80 ×
10 cm module maps to `(S¹, S², S³) = (800, 200, 100)` mm, with `S¹` along the drone's longitudinal
axis.

## Equation map

Everything is annotated in the source with the equation it implements.

| Element | Paper | File |
| --- | --- | --- |
| Problem, assumptions, rotation set `R` (`\|R\| = 6`) | §2, §2.1 | `Baldi3BKP.swift` |
| Total profit `P` | (1) | `Baldi3BKP.swift` |
| Packing centre of mass `r_CM` | (2) | `Baldi3BKP.swift`, `BaldiCentreOfMass.swift` |
| Unbalancing index `U` | (3)–(4) | `Baldi3BKP.swift` |
| MIP model 3BKP-M | (5)–(20) | `Baldi3BKPModel.swift` |
| Upper bound `UB_1D` | §4 | `Baldi3BKPModel.swift` |
| Extreme Points, Residual Space, EP-BPH | §5.1, (21) | `BaldiExtremePoints.swift` |
| Clustering and the six sorting criteria | §5.1, (22)–(23) | `BaldiSorting.swift` |
| Merit function `F = P − αU` | (24) | `Baldi3BKP.swift`, `BaldiHeuristic.swift` |
| Centre-of-mass optimisation | §5.2, (25)–(29) | `BaldiCentreOfMass.swift` |
| PCH, 3BKP-H loop, scoring, parameters | §5, §5.3, Fig. 6 | `BaldiHeuristic.swift` |
| Method selection and driver | §4, §6.2 | `Baldi3BKPSolver.swift` |

## Two places where the printed model cannot be transcribed literally

Both are flagged in the source and the second is switchable in the app so it can be demonstrated.

### Equation (10) is misprinted

It appears as

    χ^δ_j + Σ_r s^δ_jr ρ_ir ≤ χ^δ_i + M(1 − b^δ_ji)

with `ρ_ir` under a summation over item *j*'s sizes. Taken literally the row sizes item `j` by item
`i`'s rotation. That contradicts the constraint's stated meaning — "the same meaning, this time with
item j coming before item i" — and its symmetry with (9). Implemented as `ρ_jr`.

### Equation (16) makes the model infeasible as printed

`Σ_r ρ_ir = 1` forces *every* item to take a rotation, loaded or not. The moment term of (14)–(15)
is `Σ_i m_i χ^δ_i + Σ_i Σ_r m_i γ^δ_ir ρ_ir`, summed over all of `J`. An unloaded item is held at
the origin by (11), but its `γ^δ_ir` term stays in the moment while contributing nothing to the mass
`Σ_i m_i t_i` on the right-hand side. So an unloaded item is treated as a point mass sitting near
the origin.

With every item unloaded, (15) reads `Σ_i m_i γ^δ_ir ≤ 0`, which no rotation satisfies. The empty
packing is infeasible, and so is any packing that leaves out enough mass — in a *knapsack*. The same
defect makes (8) reject an instance containing an item that fits in no rotation, even though the
knapsack is free to not load it.

Verified directly: for a single 200 × 100 × 60 item in a 300 × 200 × 100 knapsack, the point
`t = 0, χ = 0, ρ = e₁` gives row `balanceHigh_1` a left-hand side of 100 against a right-hand side
of 0.

**The repair is one right-hand side:** `Σ_r ρ_ir = t_i`. An unloaded item then selects no rotation,
its `γ` term vanishes, and the moment becomes exactly the numerator the paper itself writes for
`r^δ_CM` immediately below (15). For a fully loaded packing the two forms coincide, which is
presumably why the paper's own experiments — where the model is only run on instances it can solve
and the balancing domain is generous — never expose it.

`usesPrintedRotationEquality` in the solver options, surfaced as **Equation (16) exactly as
printed** in the arrangement settings, restores the literal form.

## Parameters the paper defines but never gives a value for

Each is a setting in the app rather than a buried constant.

| Symbol | Where | Value used | Why |
| --- | --- | --- | --- |
| `M` | (9)–(11) | `S^δ` per dimension | The smallest value that cannot cut off a feasible point, given (8) and (17). A tighter big-M changes no feasible solution, only the relaxation. |
| `α` in `F = P − αU` | (24) | `0` | §5.2 refers to §5.3 for it, but §5.3 only sets the *scoring* `α = 0.1` of §5.3.2 — the paper reuses the symbol for two different parameters and never states this one. Zero means the merit function is pure profit; balance still enters as the hard domain and through the §5.2 optimisation. |
| `θ` | (22)–(23) | `20%`, i.e. 5 clusters | The paper defines `θ ∈ [1,100]` and `n_c = ⌈100/θ⌉` but states no value. |
| `r⁰_CM` | (4), §5.2 | centre of the allowable domain | Eq. (4) refers to [2] for details. The domain centre is the only choice symmetric in the constraint the domain expresses. |
| Max iterations | §5.2 | 50 | Listed as a stopping condition with no value. |
| Item order in §5.2 | §5.2 | heaviest first | Not fixed by the paper. Eq. (28) makes the required displacement inversely proportional to mass, so the heaviest item travels least and is most likely to fit inside its `D_i`. |
| Where §5.2 runs | Fig. 6 | after every EP-BPH call | Fig. 6 has no box for it, but §5.2 describes it as operating on a calculated packing and eq. (24) speaks of balance being addressed "even before the center of mass optimization procedure". |
| "CS better than BS" | Fig. 6 | balanced beats unbalanced, then higher `F` | The paper compares by (24) and separately allows `BS` to be unfeasible (the Parameter Update reacts to exactly that), so feasibility is the primary key. |
| Sort direction | §5.1 | non-increasing | "Giving more importance to an attribute means to favor those items showing the highest values". |
| `α, β` bounds | §5.3.3 | held inside `(0, 0.9]` | The Parameter Update doubles them on an unfeasible best solution; repeated doubling leaves the paper's stated `(0,1)` and would make the factor `1 − α` negative. |
| Randomness | §5.3.3 | seeded generator | "Randomly selected" pairs, made reproducible. |

Taken from the paper unchanged: `α = β = 0.1`, `k = 3`, reinitialisation every 1000 non-improving
iterations, 5 % of the items as swap pairs, a 5 s stopping time, `\|R\| = 6`, `γ` at the geometric
centre, and the instance domain `L = (W/4, D/4, 0)`, `U = (3W/4, 3D/4, H/2)`.

## Implementation choices forced by the app

* **Discretisation.** The paper assumes integral sizes. Measured millimetres are rounded — item
  sizes *up*, the knapsack *down* — so the discretisation can only be conservative.
* **Positions stay continuous.** Equation (17) makes `χ` continuous, and it is kept that way.
  Rounding the MIP's positions onto the millimetre grid was tried and moves the packing centre of
  mass by 0.1–0.2 mm, which is enough to push a solution whose balancing constraint is tight just
  outside the domain — five of twenty-four random instances failed verification that way.
* **Profit.** The 3BKP needs a profit per item; the app has none to measure. The default is the
  paper's own instance rule, `p_j = 200 + w·d·h` (§6.1), editable per package so a critical package
  can be forced into the load.
* **Scaling.** In the paper's units the rows span 1 to 10⁸ — the capacity row carries volumes, the
  balancing rows mass × length, the ordering rows ones — and the simplex stalls on the raw matrix.
  Every row is divided by a positive constant and positions are held as `χ̂ = χ / S^δ`, which puts
  every coefficient in `[−1, 1]`. This changes no feasible point and no optimal selection.
* **Oversized items** are removed before solving and reported separately. Required under the printed
  (16); a model-size reduction under the repaired one.

## What the model does not contain

Straight from the paper, §2, page 9803: *balancing conditions are not equivalent to stability
conditions.* The paper lists the stability conditions it does not adopt — supporting surface, number
of supporting items, maximum weight along the vertical axis — and constraints (5)–(20) contain no
support term.

Measured over 40 random instances (support fraction = share of an item's base resting on the floor
or on another item's top face):

| | items | fully floating | partly supported | worst support |
| --- | --- | --- | --- | --- |
| EP-BPH alone | 239 | 3 | 24 | 0 % |
| after §5.2's gravity step | 239 | **0** | 24 | 4.1 % |
| 3BKP-M exact model | 92 | **18** | 1 | 0 % |

So the two methods differ, and the result screen says so per method: **the exact model does place
packages in mid-air**, because nothing in the printed model forbids it; **the heuristic never does**,
because §5.2's gravity compaction settles every package. Both allow a package to rest on a small
part of its base. The 3BKP also has no item spacing and assumes walls of negligible thickness.

Adding a supporting-surface or load-bearing constraint would make the arrangement physically safer
but would no longer be this paper's model, so it is reported rather than silently added.

A full line-by-line comparison, with file and line for every equation and every divergence, is in
`BALDI_FIDELITY_AUDIT.md`.

## Validation

`swiftc` harness, not shipped in the app:

* `\|R\| = 6`, six distinct size assignments, `γ` at the geometric centre, and the §6.1 domain
  reproduce exactly.
* `U` matches eq. (4) by hand on a two-item packing.
* Stacking is used when the floor runs out; items are left out when the knapsack is full; an item
  that fits in no rotation is reported rather than making the instance infeasible.
* **24 random instances, 3–6 items, exact model against heuristic.** The model proved optimality on
  15 of them. The heuristic never beat a proven optimum, matched it on 14 of 15, and was 10 % below
  on one. Zero geometry violations across all 48 solves.

## Practical limits

3BKP-M is far weaker than 3BKP-H here, and more so than in the paper — the paper used Gurobi on a
workstation and still reported that the model "is not able to solve instances with more than 20
items", while this app carries its own dense-tableau branch and bound. In testing the model proves
optimality up to about 4–5 items and times out beyond that. **3BKP-H is the default and the
practical method**; the model is there for small instances, for the bound, and because the paper
presents both.
