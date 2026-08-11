# Pseudocode, papers against this implementation

Every algorithm in this project that comes from a paper, written twice: as the paper prints it, then
as the code runs it, with the differences named. Two algorithms qualify — the 3D knapsack packing
and the 2D bounding-box orientation. The load-balancing MILP is not here because it is a model
rather than an algorithm; its equation-by-equation mapping is the table in
`PayloadMeasure/Packing/METHODS.md`.

Sources:

- **[B]** M. M. Baldi, G. Perboli, R. Tadei, "The three-dimensional knapsack problem with balancing
  constraints", *Applied Mathematics and Computation* 218 (2012) 9802–9818.
- **[J]** L. Junqueira, R. Morabito, D. S. Yamashita, "Three-dimensional container loading models
  with cargo stability and load bearing constraints", *Computers & Operations Research* 39 (2012)
  74–85.
- **[L]** Y. Liu, B. Liu, H. Zhang, "Estimation of 2D Bounding Box Orientation with Convex-Hull
  Points", *IEEE Intelligent Vehicles Symposium*, 2020.
- **[Z]** X. Zhang, W. Xu, C. Dong, J. M. Dolan, "Efficient L-shape fitting for vehicle detection
  using laser scanners", *IEEE Intelligent Vehicles Symposium*, 2017. Reference [15] of [L], and the
  definition of `closeness`.

---

# Part 1 — Packing

## 1.1 The outer loop, 3BKP-H

### As printed, [B] §5 and Fig. 6

```
BS ← PCH()                                  // initial solution
InitialiseScores(BS)
while not StoppingConditions:
    order ← items sorted by score, descending
    CS    ← EP-BPH(order)
    if non-improving iterations limit reached:
        LongTermScoreReinitialisation()
    else:
        ScoreUpdate(CS)
    if CS better than BS:  BS ← CS          // "better" = merit F, eq. (24)
    ParameterUpdate()
return BS
```

### As implemented, `BaldiSearch.solve`

```
(searchBest, bestFeasible) ← ConstructInitialSolution()   // PCH, all six criteria
scores ← InitialiseScores(items, loadedIn: searchBest)
while now < deadline and not cancelled:
    order ← items sorted by score, descending, index breaking ties
    CS    ← Balance(EP-BPH(order))
    record loaded/unloaded counts for every item
    if nonImproving ≥ 1000:
        LongTermScoreReinitialisation()
        ParameterUpdate()                                 // ← moved here
        nonImproving ← 0
    else:
        ScoreUpdate(CS)
    if BetterForSearch(CS, searchBest):  searchBest ← CS ; nonImproving ← 0
    else:                                nonImproving ← nonImproving + 1
    if Feasible(CS) and BetterFeasible(CS, bestFeasible):  bestFeasible ← CS
return bestFeasible or empty                              // ← never an unverified packing
```

| Difference | Why |
| --- | --- |
| `ParameterUpdate` runs at reinitialisation, not every pass | §5.3.3 states the α = 2α / β = 2β rule as part of reinitialisation; Fig. 6 draws it per pass. Run per pass, both steps double from 0.1 and hit their cap within four rounds, so the paper's adaptation never happens. |
| Stopping condition is a wall clock plus cancellation | §5.3.4 gives 5 s. Cancellation is added so the solve can be abandoned when the operator leaves the screen. |
| Two incumbents are tracked | The paper's `BS` may be infeasible; the screen must never show one. `searchBest` drives the search exactly as `BS` does, `bestFeasible` is what is returned. |
| Reinitialisation triggers on non-improving rounds | §5.3.4 says "every 1000 iterations", Fig. 6 says "Non Improving Iter. Limit". |
| Ties in the sort broken by index | The paper leaves ties undefined. Every profit is 1 here, so ties are common and determinism matters. |

`BetterForSearch` is the paper's merit function F = P − αU (eq. 24) with α = 0, so F = P, followed by
tie-breaks the paper does not have: full support, then balance, then — in `centred` mode only —
closeness to the domain centre. `BetterFeasible` compares only count and, in `centred` mode,
closeness.

## 1.2 The constructive heuristic, EP-BPH

### As printed, [B] §5.1

```
order items by the sorting criterion
for each item in order:
    for each rotation r:
        find the EP e of the best bin minimising
            f = (RSˣₑ − wⱼ) + (RSʸₑ − dⱼ) + (RSᶻₑ − hⱼ)      // eq. (21)
        checking for overlap, since RS is only an estimate
    if such an EP exists: place the item there
    else if bins < maximum: open a new bin                  // maximum = 1 for the 3BKP
    else: discard the item
```

### As implemented, `BaldiConstruction.pack`

```
packing ← empty, extreme points ← { origin, RS = container }
for each item in order:
    best ← none, bestScore ← +∞
    for each extreme point e, for each of the six rotations r:
        body ← r(size of item)
        if RSₑ < body on any axis: skip                     // eq. (21) gate
        if not CanPlace(item, r, e): skip                   // ← inside, clear, AND supported
        score ← (RSˣₑ − bodyˣ) + (RSʸₑ − bodyʸ) + (RSᶻₑ − bodyᶻ)
        if score < bestScore: best ← (e, r)
    if best exists: Place(item, best) else: discard(item)
return packing
```

`Place` removes the used point, generates the new extreme points, then prunes and recomputes every
residual space.

| Difference | Why |
| --- | --- |
| `CanPlace` also requires full bottom-face support | [J] eq. (11) with α = 1. This is the whole reason the second paper is in the project. |
| One bin, never opened | The 3BKP has a single container; [B] says so explicitly. |

Everything else is eq. (21) verbatim, including minimising the plain sum of the three slacks rather
than any weighted or squared variant, and re-checking overlap because RS only estimates the free
volume.

## 1.3 Extreme points

### As printed, [B] §5, after Crainic et al. [7]

> The new EPs are generated by projecting the points with coordinates (xⱼ + wⱼ, yⱼ, zⱼ),
> (xⱼ, yⱼ + dⱼ, zⱼ), and (xⱼ, yⱼ, zⱼ + hⱼ) on the orthogonal axes of the knapsack.

### As implemented, `BaldiPacking.appendGeneratedPoints`

```
for (corner, axes) in [ ((xⱼ+wⱼ, yⱼ, zⱼ), {y,z}),
                        ((xⱼ, yⱼ+dⱼ, zⱼ), {x,z}),
                        ((xⱼ, yⱼ, zⱼ+hⱼ), {x,y}) ]:
    for axis in axes:
        p ← corner with p[axis] ← the highest face below it, or 0
        add p as a new extreme point
prune: drop points outside the container, buried inside an item, or duplicated
RS(p)[axis] ← distance from p to the nearest item face ahead of it on that axis, or the wall
```

No difference. Six points per placement, each projected onto the two axes it does not extend along.

## 1.4 Sorting and clustering

### As printed, [B] §5.1, eqs. (22)–(23)

```
Aᵢ(θ) = [ Aₘᵢₙ + (i−1)(Aₘₐₓ − Aₘᵢₙ)θ/100 ,  Aₘᵢₙ + i(Aₘₐₓ − Aₘᵢₙ)θ/100 ]     // (22)
Aᵢ(θ) = [ (i−1)·W·D·θ/100 , i·W·D·θ/100 ]    for the knapsack basis area    // (23)
n_c   = ⌈100/θ⌉

six criteria:  a-sw, a-p, sw-a, sw-p, p-sw, p-a
               (cluster by the first attribute, sort by the second)
```

### As implemented, `BaldiSorting`

```
θ ← 20, so n_c = 5
if the clustered attribute is area:  Aₘᵢₙ ← 0, Aₘₐₓ ← W·D          // eq. (23)
else:                                Aₘᵢₙ, Aₘₐₓ ← range over the items   // eq. (22)
cluster(v) ← clamp( ⌈(v − Aₘᵢₙ)/width⌉ , 1, n_c )
sort by cluster descending, then by the sorted attribute descending, then by index
```

Only θ differs, and only because [B] defines it without ever giving it a value.

## 1.5 Centre-of-mass optimisation

### As printed, [B] §5.2, eqs. (25)–(29)

```
repeat until: packing is balanced, or no item can move, or max iterations:
    r_CM ← Σⱼ m_j r_CMⱼ / M                                     // eq. (2)
    for each item i:
        r′_CMᵢ ← r_CMᵢ + (r′_CM − r_CM)·M/mᵢ                    // eq. (28)
        r′ᵢ    ← (r′¹_CMᵢ − γ¹ᵢᵣ, r′²_CMᵢ − γ²ᵢᵣ, r′³_CMᵢ − γ³ᵢᵣ) // eq. (29)
        Dᵢ ← positions where i can move without overlapping anything or the bin
        if Dᵢ = ∅:        i cannot move
        elif r′ᵢ ∈ Dᵢ:    move i to r′ᵢ
        else:             move i to r″ᵢ, the point best approximating r′ᵢ on each axis
compact every item along z towards the (x,y) plane          // gravity
```

### As implemented, `BaldiBalancer.optimise`

```
best ← placements
for iteration in 1...50:
    if mode = paper and r_CM ∈ [L,U]: break
    moved ← false
    for each item i, heaviest first:
        r_CM ← Σⱼ m_j r_CMⱼ / M                                 // eq. (2)
        if mode = paper and r_CM ∈ [L,U]: break
        r′_CMᵢ ← r_CMᵢ + (target − r_CM)·M/mᵢ                    // eq. (28)
        r′ᵢ    ← r′_CMᵢ − extentᵢ/2                              // eq. (29), γ = extent/2
        Dᵢ     ← mode = paper ? free-slide box around i : whole container
        r″ᵢ    ← clamp(r′ᵢ, Dᵢ)                                  // "best approximates on each axis"

        if Move(i → r″ᵢ) keeps the packing valid and balanced:   // ← the paper's move, taken as-is
            apply it; moved ← true; record if best; continue

        // reached only when full support rejects r″ᵢ
        candidates ← r″ᵢ, then r″ᵢ at each resting height, then single-axis moves
                     (centred mode also adds a capped grid of neighbours' face coordinates)
        pick the candidate that strictly reduces |r_CM − target| and keeps the packing valid
        if one exists: apply it; moved ← true; record if best
    if not moved: break
return best
```

`Valid` means: inside the container, no overlap, and **every** package fully supported.

| Difference | Why |
| --- | --- |
| No gravity compaction | Full support forbids the mid-air placements gravity exists to repair, and compacting afterwards would move mass and undo the balance just achieved. |
| A candidate list when `r″ᵢ` is rejected | Only reached when support blocks the prescribed point, which cannot happen in [B] because [B] has no support rule. Without it the added constraint would block most moves and the load would never balance. |
| Returns the best arrangement seen | Once clamping and support force partial moves, a run of them can end worse than it started. Balanced beats unbalanced, then closeness to target. Measured over 40 instances it changes nothing; it removes a possibility. |
| Heaviest first | [B] says only "one item after another". A heavy item needs the shortest move to shift the centre of mass. |
| 50 iterations | [B] names a maximum-iteration stopping condition and never values it. |
| `centred` mode does not stop at feasibility | This is the third method, described in Part 3. |

## 1.6 Scoring

### As printed, [B] §5.3

```
Initialisation:   sᵢ ← k·pᵢ if i is in the initial solution, else pᵢ         k = 3

Update:           k ← argmin over loaded i of  μᵢ = (1 + f l ᵢ)·pᵢ/(wᵢdᵢhᵢ)
                  sₖ ← (1 − α)·sₖ
                  l ← argmax over unloaded i of θᵢ = pᵢ/(wᵢdᵢhᵢ·(1 + f u ᵢ))
                  s_l ← (1 + β)·s_l
                  swap sₖ and s_l

Reinitialisation: sᵢ ← as in Initialisation, against the best solution so far
                  swap a fixed number of randomly chosen score pairs

Parameters:       α = β = 0.1
                  best infeasible          → α ← 2α, β ← 2β
                  best feasible and CoM in the central half of the domain → α ← α/2, β ← β/2
                  otherwise unchanged
                  reinitialise every 1000 iterations; pairs = 5% of the items; stop after 5 s
```

### As implemented

Identical, with two bounds and one clarification:

- steps are held in `(0, 0.9]`, because the paper doubles them without bound and a score of
  `(1 − α)·s` with α > 1 would go negative;
- the random pair selection uses a seeded generator, so a run reproduces;
- `f l ᵢ` and `f u ᵢ` count the rounds the item has been loaded and not loaded, incremented before the
  update, as the paper describes.

Note that every package here has profit 1, so μᵢ and θᵢ reduce to functions of volume and history
alone. That is a property of the input, not a change to the rule.

## 1.7 Vertical support

### As printed, [J] eqs. (10)–(11)

```
for every box j at (x′,y′,z′) with z′ ≠ 0:

    Σ over boxes i with z′ − hᵢ ≥ 0
      Σ over x ∈ Xᵢ with x′ − lᵢ + 1 ≤ x ≤ x′ + lⱼ − 1
        Σ over y ∈ Yᵢ with y′ − wᵢ + 1 ≤ y ≤ y′ + wⱼ − 1
            L⁽¹⁾ᵢⱼ · W⁽¹⁾ᵢⱼ · aᵢ,x,y,(z′−hᵢ)   ≥   αⱼ · lⱼ · wⱼ · aⱼ,x′,y′,z′

    L⁽¹⁾ᵢⱼ = min(x + lᵢ, x′ + lⱼ) − max(x, x′)
    W⁽¹⁾ᵢⱼ = min(y + wᵢ, y′ + wⱼ) − max(y, y′)
```

A box at z′ = 0 is always stable. Valid on reduced normal-pattern sets only when αⱼ = 1.

### As implemented, `BaldiVerticalSupport.report`

```
required ← extentˣ_j · extentʸ_j
if |z_j| ≤ tol:  return fully supported by the floor       // the z′ ≠ 0 exemption

rectangles ← []
for every placement i ≠ j with |top_z(i) − z_j| ≤ tol:     // in contact
    L ← min(maxˣᵢ, maxˣⱼ) − max(xᵢ, xⱼ)                    // L⁽¹⁾ᵢⱼ
    W ← min(maxʸᵢ, maxʸⱼ) − max(yᵢ, yⱼ)                    // W⁽¹⁾ᵢⱼ
    if L > tol and W > tol: rectangles.append((L, W) rectangle)

supported ← UnionArea(rectangles)                          // ← union, not sum
return supported + tol ≥ required                          // αⱼ = 1
```

| Difference | Why |
| --- | --- |
| α fixed to 1 | Complete support. [J] notes eq. (11) is only valid on reduced sets at α = 1, so this is the unconditionally sound case. |
| Union, not sum | Equal under non-overlap, so nothing is lost, but the union cannot double-count where a tolerance makes two supporters appear to share a strip. |
| Continuous coordinates, no `X`, `Y`, `Z` grids | [B]'s heuristic produces continuous positions; there is no discrete set to sum over. [J]'s exclusion of the back and right edges of a top face is a grid artefact with no continuous counterpart. |
| Load bearing (14) and horizontal stability (12)–(13) not implemented | Out of scope; stated in `METHODS.md`. |

---

# Part 2 — 2D bounding box

## 2.1 Convex hull

### As printed, [L] Algorithm 1

```
ConvexHull(P):
    P₀ ← lowest(P)                        // leftmost if tied
    P  ← sort by polar angle about P₀
    m ← 1
    for i ← 1 to n:                       // collapse collinear runs, keep the farthest
        while i < n−1 and ‖sin ∠P₀PᵢPᵢ₊₁‖ ≤ τ:  i ← i+1
        Pₘ ← Pᵢ ;  m ← m+1
    if m < 3: return ∅
    push P₀, P₁, P₂
    for i ← 3 to m:
        while |stack| ≥ 2 and sin ∠(next_top, top, Pᵢ) ≤ τ:  pop
        push Pᵢ
    return stack
```

### As implemented, `PaperTopBoundingBox.convexHull`

```
pivot ← min by y, then by x
sorted ← points sorted by atan2 about pivot, ties by distance ascending
polar ← []
i ← 0
while i < |sorted|:
    farthest ← sorted[i]
    j ← i+1
    while j < |sorted| and ApproximatelyCollinear(pivot, sorted[i], sorted[j], τ):
        if |sorted[j] − pivot| ≥ |farthest − pivot|:  farthest ← sorted[j]
        j ← j+1
    polar.append(farthest);  i ← j
if |polar| < 2: return ∅                                  // pivot + 2 = the paper's m < 3
stack ← [pivot, polar[0], polar[1]]
for p in polar[2...]:
    while |stack| ≥ 2 and TurnSine(stack[−2], stack[−1], p) ≤ τ:  pop
    stack.append(p)
return |stack| ≥ 3 ? stack : ∅

τ = 0.01
```

| Difference | Why |
| --- | --- |
| A collinear run is measured against its first point, not the previous one | Identical at τ = 0. Above it, anchoring stops the run from drifting off the ray it started on. |

τ = 0.01 is [L]'s own recommended value: "it produces almost the same results as using accurate
convex-hull points".

## 2.2 Orientation search

### As printed, [L] Algorithm 2

```
S ← INT_MAX
if |P| > N_max:  P ← downsample(P)
C ← ConvexHull(P)
if |C| = 0: return
for i ← 0 to |C|−1:
    for j ← i+1 to |C|:
        θcur ← atan2(yⱼ − yᵢ, xⱼ − xᵢ)
        Scur, lcur, wcur ← closeness(P, θcur)
        if Scur < S:  θ, length, width ← θcur, lcur, wcur
```

### And `closeness`, as printed in [Z]

```
C₁ ← X cos θ + Y sin θ ;  C₂ ← −X sin θ + Y cos θ
D₁ ← argmin( ‖max C₁ − C₁‖ , ‖C₁ − min C₁‖ )
D₂ ← argmin( ‖max C₂ − C₂‖ , ‖C₂ − min C₂‖ )
β ← 0
for each pair (d₁, d₂):  β ← β + 1 / max( min(d₁, d₂), d₀ )
return β                                     // the search takes the argmax of β
```

### As implemented, `PaperTopBoundingBox.make`

```
all2D  ← every object point projected onto the support plane
sample ← ReservoirDownsample(all2D, 100)
hull   ← ConvexHull(sample, τ = 0.01)
if |hull| < 3: return nil

bestScore ← −∞
for i ← 0 to |hull|−2:
    for j ← i+1 to |hull|−1:
        axis ← normalise(hull[j] − hull[i])          // the direction, not the angle
        score ← Closeness(sample, axis, d₀)
        if score > bestScore:  bestScore ← score; bestAxis ← axis     // ← argmax

fit ← min/max projection of ALL2D onto (bestAxis, bestAxis⊥)          // ← full cloud
if depth > width: swap the two axes so width is the longer side
height ← max projection of every point onto the up axis − ground height
```

`Closeness` is [Z] term for term: the same squared-norm side selection, the same
`1/max(min(d₁,d₂), d₀)` accumulation, `d₀` supplied as `minimumEdgeDistance`.

| Difference | Why |
| --- | --- |
| **Maximise, not minimise** | [Z]'s β is larger the better the points hug the rectangle, and [Z]'s own search takes the argmax. [L]'s `S = INT_MAX` / `Scur < S` would select the worst-fitting orientation. The comparison in Algorithm 2 is a misprint. |
| Extents from the full cloud, orientation from the sample | [L] states it omits size and warns size is what missing points damage most. A downsample discards disproportionately the extreme points, which are exactly the ones that set the extents. The orientation search is untouched. |
| Reservoir sampling, seeded | [L] says "uniformly downsampled" without specifying random subset or fixed stride. Seeding makes a scan reproducible. |
| Direction vectors instead of `atan2` | Algebraically identical and avoids a wrap at ±π. |
| Longer side named width | An app convention. [L] does not evaluate size at all. |
| `N_max` = 100 | [L]'s upper tested value, where average error is under 1°. |

---

# Part 3 — `centred`, the third method

`centred` is not in either paper. It is [B] §5.2 with the stopping rule relaxed, offered next to the
faithful `paper` mode so the two can be compared on the same measurements.

[B] treats balance as a **feasibility** condition: the centre of mass must lie in `[L, U]`, and
§5.2's first stopping condition is "the packing is balanced". The moment it is inside the domain,
the procedure is finished — anywhere inside is as good as anywhere else. That is `paper` mode, and
it is why its mean distance from the domain centre is around 100 mm on a container a few hundred
millimetres across: it stops at the boundary it was asked to reach.

`centred` treats balance as an **objective**. Four changes, all in `BaldiBalancer` and the two
comparison functions:

| | `paper` | `centred` |
| --- | --- | --- |
| Stop when the centre of mass enters `[L, U]` | yes, §5.2's first condition | no, keeps going |
| Domain `Dᵢ` for a move | the free-slide box bounded by the item's immediate neighbours, [B]'s own construction | the whole container minus the item's extent |
| Candidates when the prescribed point is unsupported | that point at each resting height, then single-axis moves | the same, plus a distance-ordered grid built from the neighbouring faces, capped at 48 |
| Distance to the domain centre as a tie-break between equal-count packings | no | yes, in both `isBetterForSearch` and `isBetterFeasible` |

Everything else is shared: the same construction, the same six sorting criteria, the same scoring,
the same full-support rule, the same verifier, the same 50-iteration cap and heaviest-first order.

The practical difference, measured over 40 random 8-package instances at 0.35 s each:

| | packages loaded | balanced | mean distance from domain centre |
| --- | --- | --- | --- |
| `paper` | 317 / 320 | 40 / 40 | 103 mm |
| `centred` | 315 / 320 | 40 / 40 | 4 mm |

So `centred` costs about 0.6% of the load and puts the centre of mass roughly 25× closer to the
middle of its allowed region. Both satisfy [B]'s constraint; `centred` satisfies it with margin. For
a drone module, where the domain is a tolerance rather than a target, that margin is what absorbs
flight loads and any error in the measured masses — which is the reason the mode exists.

`paper` is the mode to cite. `centred` is the mode to fly.
