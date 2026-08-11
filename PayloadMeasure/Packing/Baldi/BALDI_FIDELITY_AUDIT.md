# 3BKP implementation — fidelity audit

Line-by-line comparison of the code in this folder against

> M. M. Baldi, G. Perboli, R. Tadei, "The three-dimensional knapsack problem with balancing
> constraints", *Applied Mathematics and Computation* 218 (2012) 9802–9818.

Written to be checkable by a reviewer: every equation has a file and line, and every place the code
is *not* a literal transcription is listed with the reason.

---

## 1. Where each equation lives

Line numbers are from the current sources in `PayloadMeasure/Packing/Baldi/`.

### Problem definition and quantities, §2

| Paper | Meaning | Code |
| --- | --- | --- |
| §2 | knapsack `K`, size `(W, D, H)`, domain `[L^δ, U^δ]` | `Baldi3BKP.swift:52` `BaldiKnapsack` |
| §2 | item `j`: `p_j`, `(w_j, d_j, h_j)`, `m_j` | `Baldi3BKP.swift:33` `BaldiItem` |
| §2.1 | rotation set `R`, `\|R\| = 6` | `Baldi3BKP.swift:140` `BaldiRotation.all` |
| §2.1 | `s^δ_ir` | `Baldi3BKP.swift:116` `BaldiRotation.size(of:)` |
| §2.1 | `γ^δ_ir` | `Baldi3BKP.swift:126` `BaldiRotation.centreOfMassOffset(of:)` |
| §2.1 | `χ^δ_i` | `Baldi3BKP.swift:189` `BaldiPlacement.origin` |
| (1) | `P = Σ_{j∈J'} p_j` | `Baldi3BKP.swift:216` `BaldiSolution.profit` |
| (2) | `r_CM = Σ r_CMj m_j / M` | `Baldi3BKP.swift:225` `BaldiSolution.centreOfMass` |
| (3)–(4) | `U = √( Σ \|r_CMj − r⁰_CM\|² / k )` | `Baldi3BKP.swift:241` `BaldiSolution.unbalancingIndex` |
| (24) | `F = P − αU` | `Baldi3BKP.swift:258` `BaldiSolution.merit(alpha:)` |
| §6.1 | instance domain `L = (W/4, D/4, 0)`, `U = (3W/4, 3D/4, H/2)` | `Baldi3BKP.swift:82` `standardDomain(size:)` |

### The MIP model 3BKP-M, §2.1

All in `Baldi3BKPModel.swift`; the equation list is restated at lines 14–25.

| Equation | Code |
| --- | --- |
| (5) `max Σ p_j t_j` | line 110 (objective set to `−p_j`, the solver minimises) |
| (6) capacity | line 162 |
| (7) non-overlap activation | line 210 |
| (8) inside the knapsack | line 192 |
| (9) + (10) precedence | line 229 (one row per ordered pair; `(i,j)` is (9), `(j,i)` is (10)) |
| (11) unloaded at the origin | line 242 |
| (12) + (13) precedence only if loaded | line 254 |
| (14) + (15) balancing | lines 283, 284 |
| (16) one rotation per item | line 176 |
| (17) `χ ≥ 0` | line 123 |
| (18) `t_i` binary | line 110 |
| (19) `b^δ_ij` binary | line 151 |
| (20) `ρ_ir` binary | line 138 |
| §4 `UB_1D` | line 366 `BaldiUpperBound.oneDimensional` |
| — | solution read-back at line 300 |

### The heuristic 3BKP-H, §5

| Paper | Code |
| --- | --- |
| §5.1 Extreme Point generation | `BaldiExtremePoints.swift:99` `appendGeneratedPoints(for:)` |
| §5.1 projection onto an axis | `BaldiExtremePoints.swift:120` `projection(of:along:)` |
| §5.1 Residual Space | `BaldiExtremePoints.swift:171` `residualSpace(at:)` |
| §5.1 EP-BPH | `BaldiExtremePoints.swift:244` `BaldiEPBPH.pack` |
| (21) `f = Σ (RS − size)` | `BaldiExtremePoints.swift:268` |
| (22)–(23) clustering | `BaldiSorting.swift:71` `clusterIndex(of:…)` |
| §5.1 the six criteria | `BaldiSorting.swift:16` `BaldiSortingCriterion`, ordering at line 87 |
| §5.1 PCH | `BaldiHeuristic.swift:69` `constructInitialSolution` |
| (25)–(29) centre-of-mass optimisation | `BaldiCentreOfMass.swift:39` `optimise`, eqs. (28)–(29) at line 70 |
| §5.2 domain `D_i` | `BaldiCentreOfMass.swift:170` `freeDomain(for:in:knapsack:)` |
| §5.2 gravity | `BaldiCentreOfMass.swift:133` `applyGravity(to:knapsack:)` |
| Fig. 6 main loop | `BaldiHeuristic.swift:98` `solve` |
| §5.3.1 score initialisation | `BaldiHeuristic.swift:222` `initialScores` |
| §5.3.2 score update (`μ_i`, `θ_i`) | `BaldiHeuristic.swift:232` `scoreUpdate` |
| §5.3.3 long-term reinitialisation | `BaldiHeuristic.swift:273` `longTermReinitialisation` |
| §5.3.3 parameter update | `BaldiHeuristic.swift:298` `parameterUpdate` |
| Fig. 6 "CS better than BS" | `BaldiHeuristic.swift:332` `isBetter` |
| §5.3.4 parameter values | `BaldiHeuristic.swift:16` `BaldiHeuristicOptions` |

---

## 2. Divergences from the printed paper

Four categories. **A** are defects in the paper that make a literal transcription unusable, **B** are
choices the paper leaves open, **C** are numerical necessities that change no feasible point, and
**D** are consequences of running on measured data.

### A. Defects in the printed model

**A1 — Equation (10) misprints `ρ_ir` for `ρ_jr`.** Printed:

    χ^δ_j + Σ_r s^δ_jr ρ_ir ≤ χ^δ_i + M(1 − b^δ_ji)

The summation is over item *j*'s sizes but multiplies item *i*'s rotation indicator, which would
size item `j` by item `i`'s rotation. It contradicts the constraint's stated meaning ("the same
meaning, this time with item j coming before item i") and its symmetry with (9). Implemented as
`ρ_jr`. `Baldi3BKPModel.swift:214–236`.

**A2 — Equation (16) makes the model infeasible.** `Σ_r ρ_ir = 1` forces every item to take a
rotation whether or not it is loaded. The moment term of (14)–(15) is summed over all of `J`, so an
unloaded item — pinned to the origin by (11) — still contributes `m_i γ^δ_ir` to the packing moment
while contributing nothing to the mass `Σ_i m_i t_i` on the right. It is treated as a point mass at
the origin.

Consequence: with every item unloaded, (15) reads `Σ_i m_i γ^δ_ir ≤ 0`, which no rotation satisfies.
The empty packing is infeasible, and so is any packing that leaves out enough mass — in a *knapsack*,
whose whole point is leaving items out. The same defect makes (8) reject an instance containing an
item that fits in no rotation, even though the knapsack is free not to load it.

Demonstrated directly: one 200 × 100 × 60 item in a 300 × 200 × 100 knapsack, at
`t = 0, χ = 0, ρ = e₁`, gives row `balanceHigh_1` a left-hand side of 100 against a right-hand side
of 0.

Repair, one right-hand side: **`Σ_r ρ_ir = t_i`**. An unloaded item then selects no rotation, its `γ`
term vanishes, and the moment becomes exactly the numerator the paper itself writes for `r^δ_CM`
immediately below (15). For a fully loaded packing the two forms are identical, which is presumably
why the paper's experiments never expose it. `Baldi3BKPModel.swift:170–181`; the literal form is
still selectable via `usesPrintedRotationEquality` (settings → Method → *Equation (16) exactly as
printed*).

### B. Choices the paper leaves open

Each is a setting, not a hidden constant.

| # | Item | Paper | Choice | Reason |
| --- | --- | --- | --- | --- |
| B1 | `M` | generic big-M | `M = S^δ` per dimension | Smallest value that cannot cut off a feasible point, given (8) and (17). Changes no feasible solution. |
| B2 | `α` in (24) | §5.2 defers to §5.3; §5.3 only sets the *scoring* `α = 0.1` — the symbol is reused for two different parameters and this one is never given | `0` | `F = P` with balance entering as the hard domain and via §5.2. Adjustable. |
| B3 | `θ` in (22)–(23) | defined, `n_c = ⌈100/θ⌉`, value never stated | `20 %`, 5 clusters | Adjustable. |
| B4 | `r⁰_CM` | eq. (4) refers to [2] | centre of the allowable domain | The only choice symmetric in the constraint the domain expresses. |
| B5 | §5.2 iteration cap | named, no value | 50 | — |
| B6 | §5.2 item order | not fixed | heaviest first | (28) makes the required displacement inversely proportional to mass, so the heaviest item travels least and is likeliest to fit inside its `D_i`. |
| B7 | Where §5.2 runs in Fig. 6 | no box for it | after every EP-BPH call, including PCH's | §5.2 describes it as acting on a calculated packing, and (24) speaks of balance being addressed "even before the center of mass optimization procedure". |
| B8 | Gravity, before the first balance test | §5.2 attributes the need to "items movements" | applied to the incoming packing too | EP-BPH on its own does leave items unsupported — measured, see §3 — and the paper calls such a state a "faulty solution for many real-life applications". Without this the balance decision would be taken on a floating packing. |
| B9 | Which of (22)/(23) applies to *item* area | (23) is given for "the overall knapsack (basis) area" | (23), range `[0, W·D]`, for area; (22) with the item extremes for profit and specific weight | (23) is printed as an equation, so it is presumably the one used. Reading (22) with item extremes instead is defensible and would change only the clustering of the area criteria. |
| B10 | Projections per corner point | "projected on the orthogonal axes" | two per point, six new EPs | The paper refers to Crainic et al. [7] for the details, and this is [7]'s rule: for a point extending along one axis, project along the other two. |
| B11 | "CS better than BS" | compares by (24), but the Parameter Update also reacts to `BS` being unfeasible | balanced beats unbalanced, then higher `F` | `BS` must be able to be unfeasible for the Parameter Update to have anything to react to, so feasibility is the primary key. |
| B12 | Sort direction | — | non-increasing | "Giving more importance to an attribute means to favor those items showing the highest values". |
| B13 | Reinitialisation trigger | §5.3.4 says "every 1000 iterations"; Fig. 6's box says "Non Improving Iter. Limit" | 1000 **non-improving** iterations | Fig. 6 is the more specific statement. |
| B14 | `α, β` range | stated `∈ (0,1)`, but the Parameter Update doubles them | held in `(0, 0.9]` | Repeated doubling leaves `(0,1)` and makes the factor `1 − α` negative. |
| B15 | Randomness in §5.3.3 | "randomly selected" | seeded generator | Reproducibility. |
| B16 | EP / rotation tie-break in (21) | — | first encountered, i.e. lowest EP then lowest rotation index | Deterministic. |

Taken from the paper unchanged: `α = β = 0.1`, `k = 3`, 1000 iterations, 5 % of items as swap pairs,
5 s stopping time, `\|R\| = 6`, `γ` at the geometric centre, and the §6.1 instance domain.

### C. Numerical treatment — no feasible point changed

**C1 — Row scaling.** In the paper's units the matrix spans 1 to 10⁸: the capacity row carries
volumes, the balancing rows carry mass × length, the ordering rows carry ones. The simplex stalled on
the raw matrix (200 000 iterations on a 48-variable, 67-row LP). Every row is divided by a positive
constant and positions are held as `χ̂^δ_i = χ^δ_i / S^δ`, putting every coefficient in `[−1, 1]`.
Dividing a constraint by a positive number and rescaling a variable changes no feasible point and no
optimal selection. `Baldi3BKPModel.swift:81–96`, unscaled on read-back at line 313.

**C2 — Positions stay continuous.** Equation (17) makes `χ` continuous and it is kept that way.
Rounding the MIP's positions onto the millimetre grid was tried: it moves the packing centre of mass
by 0.1–0.2 mm, which pushed five of twenty-four random instances — those whose balancing constraint
is tight — just outside the domain and failed verification.

**C3 — Oversized items removed before solving.** An item that fits in no rotation can never be
loaded. Required under the printed (16), a model-size reduction under the repaired one. Reported
separately in the UI rather than dropped silently. `Baldi3BKP.swift:157`.

### D. Consequences of running on measured data

**D1 — Discretisation.** The paper assumes integral sizes. Measured millimetres are rounded, item
sizes *up* and the knapsack *down*, so the discretisation is conservative.

**D2 — Profit.** The 3BKP needs `p_j`; nothing in the app measures it. The default is the paper's own
instance rule `p_j = 200 + w·d·h` (§6.1), editable per package.

**D3 — Practical size limit.** The paper reports 3BKP-M cannot handle more than about twenty items
*using Gurobi on a workstation*. This app carries its own dense-tableau branch and bound, so the
model proves optimality to about four or five items and times out beyond. 3BKP-H is the default.

---

## 3. Support and stacking — what the model actually permits

This is the point most likely to be challenged, so it is measured rather than asserted.

Paper §2, page 9803: *"balancing conditions are not equivalent to stability conditions"*. The paper
then lists the stability conditions in the literature that it does **not** adopt: the supporting
surface (the percentage of area an item lies on), the number of supporting items, and the maximum
weight allowed along the vertical axis. Constraints (5)–(20) contain no support term of any kind.

Measured over 40 random instances, 4–8 items, in a 400 × 250 × 150 knapsack — support fraction is
the share of an item's base area resting on the floor or on another item's top face:

| | items | fully floating | partly supported | worst support |
| --- | --- | --- | --- | --- |
| EP-BPH alone, no gravity | 239 | 3 | 24 | 0 % |
| after §5.2's gravity step | 239 | **0** | 24 | 4.1 % |
| 3BKP-M exact model | 92 | **18** | 1 | 0 % |

So:

* **The exact model does place packages in mid-air** — 18 of 92. That is the printed model, not an
  implementation error; there is simply no constraint forbidding it.
* **The heuristic never does.** §5.2's gravity compaction settles every package onto whatever is
  beneath it, so "floats" is wrong for 3BKP-H. An earlier version of the result screen said
  otherwise and has been corrected.
* **Both allow an item to rest on a small part of its base** — 4.1 % in the worst case measured.
  "Resting on an edge" is accurate for both.

The result screen now states this per method (`BaldiResultView.swift`, `scopeLines`). Adding a
supporting-surface or load-bearing constraint would make the arrangement physically safer but it
would no longer be this paper's model, so it is reported rather than silently added.

---

## 4. Verification performed

Harness under `swiftc`, not shipped in the app.

* `\|R\| = 6`, six distinct size assignments, `γ` at the geometric centre, §6.1 domain — all exact.
* `U` checked against eq. (4) by hand on a two-item packing.
* Stacking used when the floor runs out; items left out when the knapsack is full; an item fitting
  in no rotation reported rather than making the instance infeasible.
* **24 random instances, 3–6 items, exact model against heuristic.** Model proved optimality on 15.
  The heuristic never beat a proven optimum, matched it on 14 of 15, and was 10 % below on one. Zero
  geometry violations across all 48 solves.
* Support audit above, 40 further instances.
* Independent geometric verification (`BaldiGeometryCheck`) runs on every solve inside the app and
  re-derives containment, pairwise overlap and the centre of mass from the placements alone.
