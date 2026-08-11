# Support-aware 3D packing

The production 3D packing path is a documented hybrid heuristic based on two sources:

> M. M. Baldi, G. Perboli, R. Tadei, **"The three-dimensional knapsack problem with balancing
> constraints"**, *Applied Mathematics and Computation* 218 (2012) 9802–9818,
> doi:[10.1016/j.amc.2012.03.052](https://doi.org/10.1016/j.amc.2012.03.052).

> L. Junqueira, R. Morabito, D. S. Yamashita, **"Three-dimensional container loading models with
> cargo stability and load bearing constraints"**, *Computers & Operations Research* 39 (2012)
> 74–85.

Baldi supplies item selection, six orthogonal rotations, Extreme Point placement, non-overlap,
containment and cargo-centre-of-mass balancing. Junqueira supplies the area-based vertical-support
principle. The project fixes each package value to one, assumes that each package centre of mass is
at its geometric centre, and requires complete bottom-face support.

This is **not** a 1-to-1 implementation of either paper, an exact hybrid solver, or a proof of global
optimality. The production result is the highest-cardinality feasible packing found by the heuristic
within its configured search time.

## Production flow at a glance

```text
PackingStore
  measured dimensions/masses -> equal-priority BaldiProblem
    |
    v
Baldi3BKPSolver
  input validation + oversized-package partition
    |
    v
BaldiHeuristic
  BaldiSorting -> BaldiEPBPH/BaldiExtremePoints
                         |
                         +-> BaldiVerticalSupport candidate gate
    |
    v
BaldiCentreOfMassOptimisation
  support-preserving tentative movements
    |
    v
BaldiGeometryCheck
  independent bounds/rotation/overlap/support/COM verification
    |
    v
BaldiResultView -> BaldiPlanView
```

The files remain separated by responsibility so a reviewer can follow the paper algorithm without
mixing it with UI state, and so every construction, movement and final check shares one canonical
support implementation. `Baldi3BKPModel.swift` is deliberately absent from this production flow: it
is a **Baldi-only reference model**, contains no Junqueira support constraint, and is not used by the
production workflow to claim hybrid optimality.

## Relationship to the other arrangement method

This method sits beside the floor-only load-balancing formulation documented in
[`../PACKING_NOTES.md`](../PACKING_NOTES.md). They solve different problems on the same measured
packages:

| | Floor-only load balancing | Support-aware 3D packing |
| --- | --- | --- |
| Packages | all packages, or no complete arrangement | a subset may be omitted |
| Objective | minimise centre-of-mass deviation | maximise loaded-package count |
| Balance | objective, optionally with an envelope | hard cargo-COM domain |
| Placement | every package on the container floor | stacking in three dimensions |
| Vertical support | automatic because every package is on the floor | 100% of every non-floor bottom face |
| Production method | mixed-integer model | Baldi 3BKP-H-based heuristic |
| Optimality claim | reported by that separate solver when proved | none |

## Coordinate system and inputs

The origin is the bottom-left-back corner of one rectangular payload container. Its usable volume is
the first octant from `(0,0,0)` to `(W,D,H)`. A package origin is its bottom-left-back corner and its
dimensions after rotation are aligned with the container axes.

The project assumes:

- one fixed rectangular payload container;
- rigid rectangular packages with measured dimensions and known positive mass;
- packages may be omitted;
- the six orthogonal rotations used by Baldi;
- negligible wall thickness and no inter-package clearance in the packing model;
- conservative millimetre discretisation: package dimensions round up and container dimensions
  round down;
- package centres of mass coincide with their geometric centres;
- supporting packages have sufficient load-bearing strength;
- installed mechanical restraint prevents horizontal sliding.

Friction, vibration, deformation, fragility, restraint failure and acceleration loads during flight
are outside this packing model. Complete geometric support alone is not a flight-safety or structural
certification.

## Equal-priority objective

Baldi defines the selection variable `t_i`, which is one when package `i` is loaded. This project sets

```text
p_i = 1  for every package i.
```

Therefore Baldi's objective becomes

```text
maximise P = sum_i t_i,
```

so `P` is the number of loaded packages. There is no package-specific profit editor or hidden
volume-derived priority.

The coefficient in Baldi's merit function `F = P - alpha U` is fixed to zero for this project, so
`F = P`. This `alpha` is distinct from the score-decrease parameter in Baldi §5.3.2. The score
decrease and score increase both start at `0.1`, as stated in §5.3.4, and continue to be updated by
the heuristic. Balance is not traded against package count: cargo-COM compliance remains a hard
feasibility condition.

## Centre of mass

For package `i` under rotation `r`, the rotated extent along axis `delta` is `s_ir^delta`. The project
specialisation is

```text
c_ir^delta = s_ir^delta / 2.
```

Baldi's general formulation permits an arbitrary package COM coordinate. The centred value above is
a project input assumption and is also the value used in Baldi's benchmark instances; it is not a
claim that the general formulation requires centred mass.

For a nonempty loaded set, the cargo COM is

```text
r_CM^delta =
    sum_i m_i t_i (v_i^delta + c_i,r(i)^delta)
    / sum_i m_i t_i.
```

It must satisfy

```text
L^delta <= r_CM^delta <= U^delta
```

on all three axes. The standard instance domain is `L = (W/4,D/4,0)` and
`U = (3W/4,3D/4,H/2)`. The empty packing has no defined cargo COM and is not classified as balanced.

## Full vertical support

Baldi explicitly distinguishes balancing from stability and does not include a supporting-surface
constraint. The production heuristic adds a continuous-coordinate evaluation of Junqueira equation
(11), with the required support fraction fixed to

```text
alpha_j = 1.
```

For a non-floor package `j`, only packages whose top face is in direct contact with the bottom of
`j` may support it. Each contacting top face is clipped to `j`'s footprint. The implementation then
computes the **union** of those contact rectangles, rather than blindly summing their areas, and
requires

```text
supportUnionArea_j = length_j * width_j.
```

A floor package is automatically fully supported. A small `1e-6 mm` contact tolerance handles
floating-point noise only; it is not a measurement allowance and does not legitimise a visible gap
or overhang. The area comparison uses only a correspondingly small numerical tolerance.

This direct geometric evaluation has the same full-area meaning as the selected Junqueira condition
for an already known orthogonal placement, but it is not Junqueira's original grid-based MILP
encoding. That distinction is why the result is described as a hybrid heuristic.

## Production flow

The production path is deliberately heuristic-only:

1. Remove and report packages that cannot fit in any of the six rotations.
2. Generate Baldi's sorting orders and Extreme Points.
3. For each package, rotation and candidate Extreme Point, reject containment failures, overlaps and
   any non-floor placement without complete bottom support.
4. Run Baldi's centre-of-mass adjustment. Each proposed movement is accepted atomically only if the
   complete packing remains contained, non-overlapping and fully supported, including packages above
   the moved supporter.
5. Keep the best nonempty candidate that also satisfies the cargo-COM domain.
6. Independently recompute every feasibility condition before exposing the arrangement to the UI.

An invalid or unbalanced exploratory candidate may guide the heuristic internally, but it is never
returned or labelled feasible. If no verified packing is found before the stopping condition, the
result says that none was **found**; it does not claim that none exists.

## Paper corrections and implementation choices

| Category | Choice | Scope |
| --- | --- | --- |
| Project specialisation | `p_i = 1` | objective is loaded-package cardinality |
| Project specialisation | `c_ir^delta = s_ir^delta / 2` | centred package COM, matching Baldi's benchmarks |
| Project specialisation | merit coefficient `alpha = 0` | `F = P`; COM domain remains mandatory |
| Printed-model correction | Baldi Eq. (10) uses `rho_jr` for package `j` | retained in the Baldi-only reference MIP |
| Printed-model correction | Baldi Eq. (16) is `sum_r rho_ir = t_i` | retained in the Baldi-only reference MIP |
| Added condition | Junqueira Eq. (11), `alpha_j = 1` | every non-floor bottom face is completely supported |
| Implementation choice | `theta = 20%` | five sorting clusters; Baldi defines but does not value it |
| Implementation choice | ideal COM is the domain centre | target used by Baldi's COM adjustment |
| Implementation choice | at most 50 COM-adjustment iterations | Baldi names a limit but does not value it |
| Implementation choice | heaviest package considered first for movement | deterministic order where Baldi gives none |
| Implementation choice | seeded random score reinitialisation | reproducible runs |
| Implementation choice | deterministic input/rotation/Extreme Point tie-breaking | reproducible runs |
| Implementation choice | 1000 non-improving iterations and 5% distinct swap pairs | resolves the wording of Baldi §5.3/Fig. 6 |
| Numerical choice | score parameters clamped to `[1e-4,0.9]` | prevents repeated doubling leaving Baldi's stated interval |
| Numerical choice | rectangle-union support with contact/area tolerances | prevents overlap double-counting and absorbs only round-off |

The reference MIP in `Baldi3BKPModel.swift` documents Baldi equations (5)–(20) and the two printed
equation corrections. It does **not** contain the Junqueira support rule, is not used by the
production hybrid workflow, and is not used to certify a hybrid result as optimal. Its objective and
`UB_1D` can only bound the more restricted hybrid problem from above because they ignore at least
support; the UI makes no optimality claim from those bounds.

## Independent verification

`BaldiGeometryCheck` derives the final result from the reported placements rather than trusting
heuristic state. It verifies:

- a nonempty load;
- one of Baldi's six rotations and dimensions consistent with that rotation;
- source-package identity, mass and unique identifiers;
- containment and pairwise non-overlap;
- an exact partition between loaded and unloaded input packages;
- complete bottom-face support, including its supporters and support fraction;
- cargo COM recomputed from centred package COMs;
- cargo COM inside `[L,U]`.

Only a result passing all of these checks is surfaced as feasible.

## Source map

| Responsibility | File |
| --- | --- |
| problem, rotations, placements, cargo COM and verifier | `Baldi3BKP.swift` |
| continuous rectangle-union support rule | `BaldiVerticalSupport.swift` |
| Extreme Points, residual space and EP-BPH | `BaldiExtremePoints.swift` |
| clustering and six Baldi sorting criteria | `BaldiSorting.swift` |
| support-preserving cargo-COM adjustment | `BaldiCentreOfMass.swift` |
| PCH, scoring, parameter update and 3BKP-H loop | `BaldiHeuristic.swift` |
| production validation and result orchestration | `Baldi3BKPSolver.swift` |
| Baldi-only, non-production reference MIP and `UB_1D` | `Baldi3BKPModel.swift` |
| result and plan presentation | `BaldiResultView.swift`, `BaldiPlanView.swift` |

The defensible project description is:

> Baldi et al.'s 3BKP-H supplies the item-selection, orthogonal-rotation, Extreme Point placement,
> non-overlap, containment and cargo-COM balancing framework. Packages have equal value and centred
> COMs. A continuous-coordinate evaluation of Junqueira et al.'s area support condition is added
> with `alpha = 1`. The resulting method is a reproducible hybrid heuristic and does not provide a
> global-optimality guarantee.

The project's contribution is the AR measurement and integration workflow, not a new packing
algorithm.
