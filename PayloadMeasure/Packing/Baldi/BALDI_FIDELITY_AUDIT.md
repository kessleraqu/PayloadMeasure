# Baldi–Junqueira heuristic — fidelity and scope audit

This audit records what the production packing workflow takes from each paper, what the project
fixes as an input assumption, and what is an implementation choice. Its purpose is reproducibility
and honest scope, not a claim of literal transcription.

Sources:

> M. M. Baldi, G. Perboli, R. Tadei, "The three-dimensional knapsack problem with balancing
> constraints", *Applied Mathematics and Computation* 218 (2012) 9802–9818.

> L. Junqueira, R. Morabito, D. S. Yamashita, "Three-dimensional container loading models with
> cargo stability and load bearing constraints", *Computers & Operations Research* 39 (2012) 74–85.

## 1. Scope conclusion

The production method is accurately described as:

> An adaptation of Baldi et al.'s 3BKP-H heuristic, specialised to equal package values and
> geometrically centred package centres of mass, and augmented with a continuous-coordinate
> evaluation of the full vertical-support condition in Junqueira et al. equation (11), with
> `alpha_j = 1`.

It is not:

- a 1-to-1 implementation of either paper;
- Junqueira's original grid-based MILP;
- an exact solver for the combined formulation;
- a proof that the returned subset is globally optimal;
- a proof of infeasibility when the time limit expires;
- a complete model of flight safety or structural strength.

The production result is the highest-cardinality **verified feasible** packing found within the
configured search time. If every package is loaded, the UI may state that all packages were loaded;
otherwise it makes no global-optimality claim.

## 2. Traceability to Baldi

| Baldi element | Production use | Code |
| --- | --- | --- |
| one rectangular knapsack and selectable items | retained | `Baldi3BKP.swift`, `Baldi3BKPSolver.swift` |
| selection variable `t_i` | retained conceptually; a placement means `t_i = 1` | `BaldiSolution` |
| six orthogonal rotations `R` | retained | `BaldiRotation.all` |
| rotated dimensions `s_ir^delta` | retained | `BaldiRotation.size(of:)` |
| package COM coordinate `c_ir^delta` | specialised to `s_ir^delta / 2` | `centreOfMassOffset(of:)`, `BaldiPlacement.centreOfMass` |
| total value `P` | specialised by `p_i = 1`, so `P` is loaded count | `BaldiItem.profit`, `BaldiSolution.profit` |
| cargo COM, Eq. (2) | retained | `BaldiSolution.centreOfMass` |
| hard COM domain `[L,U]` | retained as feasibility | `BaldiKnapsack.containsCentreOfMass` |
| unbalancing index `U`, Eqs. (3)–(4) | retained for paper traceability | `BaldiSolution.unbalancingIndex` |
| merit `F = P - alpha U`, Eq. (24) | specialised to `alpha = 0`, hence `F = P` | heuristic comparison |
| Extreme Points and Residual Space, §5.1 | retained | `BaldiExtremePoints.swift` |
| EP-BPH and Eq. (21) | retained, with support added to its candidate gate | `BaldiEPBPH.pack` |
| clustering, Eqs. (22)–(23), and six criteria | retained | `BaldiSorting.swift` |
| PCH | retained | `constructInitialSolution` |
| COM adjustment, Eqs. (25)–(29) | retained in support-preserving form | `BaldiCentreOfMass.swift` |
| scoring, parameter update and Fig. 6 loop | retained with documented deterministic choices | `BaldiHeuristic.swift` |

The six rotations and geometric-centre COM assumption reproduce the geometry used by Baldi's
benchmark instances. They do not implement Baldi's more general ability to receive arbitrary package
COM coordinates.

## 3. Project specialisations

These choices set inputs or parameters; they are not proposed as new algorithms.

### Equal priority

Every package has

```text
p_i = 1.
```

Baldi's objective `max sum_i p_i t_i` therefore becomes `max sum_i t_i`, the loaded-package count.
There is no measured or editable package profit.

### Geometric-centre package COM

For each package, rotation and axis,

```text
c_ir^delta = s_ir^delta / 2.
```

This matches Baldi's benchmark-instance generator, but is narrower than the general formulation.

### Merit coefficient

The merit coefficient in Eq. (24) is fixed to zero, so the ranking objective is package count.
Cargo-COM membership in `[L,U]` is independently mandatory. This coefficient is not Baldi §5.3's
score-decrease value: score decrease and score increase both begin at `0.1` and are dynamically
updated.

### One container and rigid packages

The project uses one fixed rectangular payload container. Packages are rigid and may be omitted.
Supporting packages are assumed strong enough for the loads above them, and mechanical restraint is
assumed to prevent horizontal sliding.

## 4. Corrections to Baldi's printed reference MIP

The production path uses 3BKP-H, so these equations are not production support constraints. They are
retained in `Baldi3BKPModel.swift`, the Baldi-only reference model.

### Equation (10)

The printed expression sizes package `j` but multiplies by package `i`'s rotation variable. Its
stated meaning and symmetry with Eq. (9) require `rho_jr`, which is what the reference code uses:

```text
chi_j^delta + sum_r s_jr^delta rho_jr
    <= chi_i^delta + M(1 - b_ji^delta).
```

### Equation (16)

The printed `sum_r rho_ir = 1` gives an unloaded package a rotation. Its COM-offset term then remains
in Eqs. (14)–(15) even though its mass is absent from the selected total. The reference code uses

```text
sum_r rho_ir = t_i,
```

so a loaded package has exactly one rotation and an unloaded package has none.

These corrections are documented errata/repairs. They are not evidence that the combined
Baldi–Junqueira workflow is a literal implementation of Baldi.

## 5. Traceability to Junqueira vertical support

Junqueira Eq. (11) requires a chosen fraction of a selected box's bottom face to be supported by one
or more boxes immediately below. The project fixes that fraction to full support:

```text
alpha_j = 1.
```

For a known Baldi placement of target package `j`:

1. A package with `z_j = 0`, within numerical contact tolerance, is supported by the container floor.
2. Otherwise only package `i` satisfying

   ```text
   abs((z_i + h_i) - z_j) <= contactTolerance
   ```

   may support `j`.
3. Each supporter's top face is clipped to `j`'s bottom footprint:

   ```text
   deltaX_ij = max(0, min(x_i+l_i,x_j+l_j) - max(x_i,x_j))
   deltaY_ij = max(0, min(y_i+w_i,y_j+w_j) - max(y_i,y_j)).
   ```

4. The union area of all clipped contact rectangles is computed by an x-axis sweep.
5. The package passes only when the union covers its complete bottom-face area, within a small area
   tolerance.

The rectangle union avoids double-counting if numerical tolerance or invalid input makes two contact
rectangles overlap. A raw sum would be mathematically sufficient only after assuming an exact
non-overlapping packing.

`BaldiVerticalSupport.swift` is the canonical implementation. It reports supported area, required
area, support fraction, supporter identifiers, floor support and pass/fail state.

### Why this is an adaptation

Junqueira expresses support through binary placement variables on a discrete grid. Baldi 3BKP-H
produces known continuous coordinates. Evaluating the same area-coverage principle directly on those
coordinates preserves the selected physical meaning, but not Junqueira's original variable encoding
or complete MILP. The code and documentation therefore call it a **continuous-coordinate
evaluation/analogue**, not a 1-to-1 Junqueira implementation.

Only the vertical supporting-surface condition is adopted. Junqueira load-bearing, fragility and
horizontal/dynamic stability constraints are deliberately excluded.

## 6. Where support is enforced

Full support is an invariant across the complete production pipeline:

- `BaldiPacking.canPlace` rejects an unsupported Extreme Point/rotation candidate before placement;
- EP-BPH therefore constructs only fully supported partial packings;
- COM adjustment validates the entire tentative packing after every proposed movement, because
  moving a supporter can invalidate packages above it;
- unsupported movement is rolled back by never accepting the tentative coordinates;
- no separate partial-contact gravity repair is used;
- `BaldiGeometryCheck` recomputes support for every final placement;
- `Baldi3BKPSolver` exposes a solution only when the independent verifier passes.

Containment and pairwise non-overlap are checked alongside support after movement. Cargo-COM domain
membership is checked before a candidate can become the best reportable solution.

## 7. Implementation choices left open by the papers

| Item | Choice | Consequence |
| --- | --- | --- |
| sorting cluster width `theta` | `20%` | five clusters |
| ideal COM `r_CM^0` | centre of `[L,U]` | symmetric movement target |
| COM-adjustment cap | 50 iterations | finite deterministic stopping condition |
| COM movement order | heaviest first | deterministic resolution of unspecified order |
| candidate movement domain | axis-wise bounds inspired by Baldi `D_i` | every candidate still receives explicit collision/support checks |
| location of COM adjustment | after every EP-BPH result, including PCH | one consistent balance stage |
| score parameters | start at `0.1`, clamp to `[1e-4,0.9]` | avoids repeated doubling leaving Baldi's stated interval |
| reinitialisation trigger | 1000 non-improving iterations | resolves §5.3.4/Fig. 6 wording |
| score swap pairs | rounded 5%, at least one, always distinct | implements the stated fraction reproducibly |
| randomness | fixed seeded generator | repeated inputs produce repeated search order |
| sorting/EP/rotation ties | deterministic first/input order | reproducible result |
| contact tolerance | `1e-6 mm` | floating-point noise only, not placement allowance |
| support area tolerance | `max(1e-6 mm², area * 1e-9)` | numerical comparison only |
| measured dimensions | package up/container down to integral millimetres | conservative preprocessing |
| oversized packages | removed before search and reported | cannot enter any feasible rotation |

The code calls its axis-aligned movement box a candidate domain rather than claiming it is Baldi's
exact convex collision-free `D_i`. Explicit validation is authoritative.

## 8. Production heuristic versus reference MIP

`Baldi3BKPModel.swift` remains useful as a readable map of Baldi Eqs. (5)–(20), the Eq. (10)/(16)
repairs, scaling and `UB_1D`. It has no Junqueira support constraint.

Consequently:

- it is not invoked by the production Baldi–Junqueira workflow;
- its solution is not a feasible certificate for the hybrid problem unless independently subjected
  to the added support rule;
- its optimum could only bound the more restricted hybrid problem from above unless it were matched
  by an independently verified hybrid solution; production does not use it to claim optimality;
- `UB_1D` is likewise only a volume-based upper bound and ignores geometry, COM balance and support;
- the UI does not offer an "exact hybrid" mode or a printed-Eq. (16) switch.

The production driver runs only the support-aware 3BKP-H heuristic.

## 9. Independent verification boundary

For every surfaced result, `BaldiGeometryCheck` independently derives:

- that the load is nonempty;
- input identity and unique loaded/unloaded membership;
- one of the six allowed rotations and the matching rotated dimensions;
- measured mass consistency;
- containment;
- pairwise non-overlap;
- complete bottom-face support and the supporting package identifiers;
- cargo COM from package origins, rotated extents and masses;
- cargo COM membership in `[L,U]`.

A failed check produces no actionable solution. An unbalanced or unsupported exploratory packing may
influence search scores, but it cannot become the reported feasible result.

## 10. Excluded claims and physics

The implementation does not model or claim:

- package load-bearing or pressure limits;
- fragility;
- friction or resistance to aircraft acceleration;
- vibration, impact or deformation;
- restraint design or failure;
- full static/dynamic stability;
- airworthiness or structural certification.

The implementation claim should remain:

> Baldi provides the 3D selection, rotation, Extreme Point placement and cargo-COM framework;
> Junqueira's vertical-support principle is added with `alpha = 1`. The project uses a hybrid
> heuristic, reports only independently verified feasible arrangements, and does not claim global
> optimality.

The project's research contribution is the AR measurement and application integration workflow,
not a new packing algorithm.
