# Pseudocode: the papers against this implementation

Every algorithm in this project that comes from a paper, written twice — as the paper states it,
then as the code runs it — followed by the differences between them. The point of the document is
that a reader can tell, for any line of the implementation, which of three categories it falls in:

1. **from the cited paper**,
2. **an adaptation** required by this application or by combining two papers,
3. **the centred extension**, which is in no paper at all (Part 4).

Attribution here is deliberately cautious. "Direct implementation of eq. (X)" means the equation was
checked against the PDF. Where a claim could not be checked, it says so.

## Sources

- **[B]** M. M. Baldi, G. Perboli, R. Tadei, "The three-dimensional knapsack problem with balancing
  constraints", *Applied Mathematics and Computation* 218 (2012) 9802–9818.
- **[J]** L. Junqueira, R. Morabito, D. S. Yamashita, "Three-dimensional container loading models
  with cargo stability and load bearing constraints", *Computers & Operations Research* 39 (2012)
  74–85.
- **[L]** Y. Liu, B. Liu, H. Zhang, "Estimation of 2D Bounding Box Orientation with Convex-Hull
  Points", *IEEE Intelligent Vehicles Symposium*, 2020.
- **[Z]** X. Zhang, W. Xu, C. Dong, J. M. Dolan, "Efficient L-shape fitting for vehicle detection
  using laser scanners", *IEEE Intelligent Vehicles Symposium*, 2017. Reference [15] of [L], and the
  source of the `closeness` criterion.

**Equation numbers.** All [B] numbers below were re-checked against the PDF: (1) total profit,
(2) centre of mass, (3) standard deviation, (4) unbalancing index, (5)–(20) the MIP model,
(21) residual-space fit, (22)–(23) clustering, (24) merit function, (25)–(29) centre-of-mass
relocation. [J] numbers: (9)–(11) vertical stability, (12)–(13) horizontal stability, (14) load
bearing.

## Two application-wide input choices

These are set by the application, not by [B], and they affect several sections below.

- **p_i = 1 for every package.** The objective here is to load as many packages as possible, so all
  profits are equal. [B]'s own benchmarks use p_i = 200 + w·d·h. Consequences: P in eq. (1) is the
  loaded-package count, and the sorting criteria that key on profit (§1.4) lose their discriminating
  power.
- **Each package's own centre of mass is its geometric centre**, so γ_ir = extent/2 in eq. (29).
  This matches [B]'s benchmark generator, which places r_CMi at {w/2, d/2, h/2}, but is narrower
  than [B]'s general formulation, which allows any γ.

---

# Part 1 — Baldi packing

## 1.1 Outer search, 3BKP-H

### Paper — [B] §5, main-step list and Fig. 6

```
BS ← PCH()                                     // initial solution, §5.1
InitialiseScores(BS)                           // §5.3.1
while not StoppingConditions:                  // §5.3.4: 5 s
    sort items by score, descending
    CS ← EP-BPH(sorted items)
    if non-improving iteration limit reached:
        LongTermScoreReinitialisation()        // §5.3.3
    else:
        ScoreUpdate(CS)                        // §5.3.2
    if F(CS) > F(BS): BS ← CS                  // F = P − αU, eq. (24)
    ParameterUpdate()                          // §5.3.3 rule, run here per the step list
return BS
```

### Implementation — `BaldiSearch.solve`

```
(searchBest, bestFeasible) ← ConstructInitialSolution()   // PCH over all six criteria
scores ← InitialiseScores(items, loadedIn: searchBest)
while now < deadline and not cancelled:
    order ← items by score descending, index breaking ties
    CS    ← Balance(EP-BPH(order))
    record loaded / not-loaded counts for every item
    if nonImproving ≥ 1000: LongTermScoreReinitialisation(); nonImproving ← 0
    else:                   ScoreUpdate(CS)
    if merit(CS) > merit(searchBest): searchBest ← CS; nonImproving ← 0
    else:                             nonImproving += 1
    if Feasible(CS) and betterFeasible(CS): bestFeasible ← CS      // safety wrapper only
    ParameterUpdate()
return bestFeasible or empty
```

with

```
merit(S) = |loaded(S)| − α · Û(S)          Û = U / halfDiagonal(knapsack)
```

### Differences

| # | Difference | Category |
| --- | --- | --- |
| 1 | **U is normalised** by the knapsack half-diagonal before entering eq. (24). | Adaptation forced by p_i = 1. With [B]'s six-figure profits, raw millimetre U is a rounding error beside P; with P a package count it would swamp it entirely. Normalised, the penalty is < 1, so it orders equal-count packings and can never outvote a package. Pinned by `testMeritPenaltyCanOrderEqualCountsButNeverOutvotesAPackage`. |
| 2 | **α in eq. (24) is the adaptive α of §5.3.** [B] reuses the symbol for the merit penalty and the score-decrease step, and §5.2 says "for setting the α values see Section 5.3", which is the only value the paper offers. | Interpretation of an ambiguity in [B]. |
| 3 | **Two incumbents are tracked.** `searchBest` is BS and is driven purely by eq. (24); `bestFeasible` is what is returned. | Application safety wrapper. BS in [B] may be infeasible — §5.3.3 branches on exactly that — but a packing that is unbalanced or unsupported must never reach the screen. It does not influence which packings the search builds or keeps. |
| 4 | **Stopping is a wall clock plus a cancellation check.** | §5.3.4 gives 5 s; cancellation is added so a solve can be abandoned when the operator leaves the screen. |
| 5 | **Reinitialisation triggers on 1000 non-improving rounds.** | §5.3.4 says "every 1000 iterations"; Fig. 6 labels the branch "Non Improving Iter. Limit". The two disagree; this follows the figure. |
| 6 | **Ties in the score sort break by item index.** | Implementation detail. [B] leaves ties undefined, and with p_i = 1 they are common; determinism matters for reproducibility. |
| 7 | **A balancing pass runs on every constructed solution.** | [B] §5.2 is a separate procedure and the paper does not state where in the loop it runs. Running it per iteration is an interpretation. |

## 1.2 Constructive heuristic, EP-BPH

### Paper — [B] §5.1

```
order items by the sorting criterion
for each item in order:
    for each rotation r:
        find the EP of the best bin minimising
            f = (RSˣₑ − wⱼ) + (RSʸₑ − dⱼ) + (RSᶻₑ − hⱼ)          // eq. (21)
        checking overlap, since RS only estimates the free volume
    if such an EP exists: place the item there
    else if bins < maximum: open a new bin                       // maximum = 1 for the 3BKP
    else: discard the item
```

### Implementation — `BaldiConstruction.pack`

```
packing ← empty; extreme points ← { origin, RS = container }
for each item in order:
    best ← none; bestScore ← +∞
    for each extreme point e, for each of the six rotations r:
        body ← r(size of item)
        if RSₑ < body on any axis:  skip
        if not CanPlace(item, r, e): skip
        score ← (RSˣₑ − bodyˣ) + (RSʸₑ − bodyʸ) + (RSᶻₑ − bodyᶻ)
        if score < bestScore: best ← (e, r)
    if best exists: Place(item, best) else: discard(item)

CanPlace = inside the container
         ∧ no overlap with any placed package
         ∧ bottom face fully supported            ← the only added condition
```

### Differences

| # | Difference | Category |
| --- | --- | --- |
| 1 | **`CanPlace` additionally requires full bottom-face support.** | The Junqueira condition, Part 2. This is the single intended addition to the construction. |
| 2 | One bin, never opened. | Not a difference: [B] states the 3BKP has one container. |

Eq. (21) is implemented as the plain sum of the three slacks, minimised, with the residual-space
gate and the separate overlap re-check the paper describes. No centre-of-mass or distance preference
enters the construction.

## 1.3 Extreme points

### Paper — [B] §5, following Crainic et al. [7]

> The new EPs are generated by projecting the points with coordinates (xⱼ + wⱼ, yⱼ, zⱼ),
> (xⱼ, yⱼ + dⱼ, zⱼ), and (xⱼ, yⱼ, zⱼ + hⱼ) on the orthogonal axes of the knapsack.

The Residual Space of a new EP is the distance along each axis to the bin side, updated whenever an
item is added.

### Implementation — `BaldiPacking.appendGeneratedPoints`, `residualSpace`

```
for (corner, axes) in [ ((xⱼ+wⱼ, yⱼ, zⱼ), {y,z}),
                        ((xⱼ, yⱼ+dⱼ, zⱼ), {x,z}),
                        ((xⱼ, yⱼ, zⱼ+hⱼ), {x,y}) ]:
    for axis in axes:
        p ← corner, with p[axis] slid to the highest face below it, or 0
        add p
prune:  drop points outside the container, buried inside a package, or duplicated
RS(p)[axis] ← distance from p to the nearest package face ahead of it on that axis, else the wall
```

### Differences

This **follows the extreme-point construction [B] uses**; it is not claimed to be line-for-line
identical to Crainic et al., which is a separate paper not re-derived here. Six points per placement,
each projected onto the two axes it does not extend along, matches [B]'s sentence exactly. The
pruning of buried and duplicate points, the tolerances, and the recomputation of every RS after each
placement are **implementation details** — [B] describes the concept and refers to [7] for the
mechanics.

## 1.4 Sorting and clustering

### Paper — [B] §5.1, eqs. (22)–(23)

```
Aᵢ(θ) = [ Aₘᵢₙ + (i−1)(Aₘₐₓ − Aₘᵢₙ)θ/100 , Aₘᵢₙ + i(Aₘₐₓ − Aₘᵢₙ)θ/100 ]      // (22)
Aᵢ(θ) = [ (i−1)·W·D·θ/100 , i·W·D·θ/100 ]   for the knapsack basis area       // (23)
n_c   = ⌈100/θ⌉

six criteria: a-sw, a-p, sw-a, sw-p, p-sw, p-a   (cluster by the first, sort by the second)
```

### Implementation — `BaldiSorting`

```
θ ← 20, so n_c = 5
if the clustered attribute is area: Aₘᵢₙ ← 0, Aₘₐₓ ← W·D                      // eq. (23)
else:                               Aₘᵢₙ, Aₘₐₓ ← range over the items          // eq. (22)
cluster(v) ← clamp( ⌈(v − Aₘᵢₙ)/width⌉ , 1, n_c )
sort by cluster descending, then by the sorted attribute descending, then by index
```

### Differences

| # | Difference | Category |
| --- | --- | --- |
| 1 | **θ = 20.** | Implementation parameter. [B] defines θ ∈ [1,100] and never gives it a value. |
| 2 | The profit-keyed criteria (a-p, sw-p, p-sw, p-a) degenerate. | Consequence of p_i = 1, not a code change. All six criteria are still run; four of them collapse onto fewer distinct orderings. |

## 1.5 Centre-of-mass balancing — paper mode

### Paper — [B] §5.2, eqs. (25)–(29)

```
repeat until: the packing is balanced,
              or no item can move,
              or a maximum number of iterations is reached:
    r_CM ← Σⱼ m_j r_CMⱼ / M                                        // eq. (2)
    for each item i, one after another:
        r′_CMᵢ ← r_CMᵢ + (r′_CM − r_CM)·M/mᵢ                        // eq. (28)
        r′ᵢ    ← (r′¹_CMᵢ − γ¹ᵢᵣ, r′²_CMᵢ − γ²ᵢᵣ, r′³_CMᵢ − γ³ᵢᵣ)     // eq. (29)
        Dᵢ ← positions where i can move without overlapping anything or the bin
        if Dᵢ = ∅:        i cannot move
        elif r′ᵢ ∈ Dᵢ:    move i to r′ᵢ
        else:             move i to r″ᵢ, the point best approximating r′ᵢ on each axis
compact every item along z towards the (x,y) plane                  // gravity
```

### Implementation — `BaldiBalancer.optimise`, paper mode

```
best ← placements
for iteration in 1...50:
    if r_CM ∈ [L,U]: break
    moved ← false
    for each item i in packing order:
        r_CM ← Σⱼ m_j r_CMⱼ / M                                     // eq. (2)
        if r_CM ∈ [L,U]: break
        r′_CMᵢ ← r_CMᵢ + (target − r_CM)·M/mᵢ                        // eq. (28)
        r′ᵢ    ← r′_CMᵢ − extentᵢ/2                                  // eq. (29), γ = extent/2
        Dᵢ     ← free-slide box around i, bounded by its neighbours
        r″ᵢ    ← clamp(r′ᵢ, Dᵢ)                                      // "best approximates on each axis"

        if Move(i → r″ᵢ) leaves the packing valid:                   // no improvement test
            apply; moved ← true; record if best; continue

        ── below here is not [B]; reached only when support rejects r″ᵢ ──
        candidates ← r″ᵢ at each height something could rest on
        pick the one that strictly reduces |r_CM − target| and leaves the packing valid
        if one exists: apply; moved ← true; record if best
    if not moved: break
return best

Valid = inside the container ∧ no overlap ∧ every package fully supported
```

### Differences

| # | Difference | Category |
| --- | --- | --- |
| 1 | **Every move must additionally leave the whole packing fully supported.** | The unavoidable consequence of combining [B] with [J]. §5.2 has no support condition. |
| 2 | **A fallback candidate set when `r″ᵢ` is unsupported**: the same point at each available resting height, and nothing else. | Required by difference 1. Without it, the added constraint would block most moves and the load would never balance. Deliberately minimal; the larger neighbourhood belongs to Part 4. |
| 3 | **No gravity compaction.** | Not an omission: under α = 1 full support it is provably a no-op. A package off the floor rests on top faces that cover its bottom face completely, so it cannot descend — any drop breaks overlap or support. `testGravityCompactionIsVacuousUnderFullSupport` verifies this. §5.2's compaction exists to repair the mid-air placements [B]'s model allows and this one forbids. |
| 4 | **The best arrangement seen is returned, not the last.** | Implementation safeguard. [B]'s move is exact by construction; once clamping and support can force partial moves, a run of them could end worse than it started. It changes which arrangement is returned, never which moves are attempted. |
| 5 | **Items are taken in packing order.** | §5.2 says only "one item after another". Neutral and deterministic. Heaviest-first is a Part 4 choice and is not used here. |
| 6 | **50 iterations.** | Implementation parameter. §5.2 names the stopping condition and never values it. |
| 7 | **γ = extent/2.** | Application assumption; see the input choices above. |

## 1.6 Scores and parameters

### Paper — [B] §5.3

```
§5.3.1  Initialisation:   sᵢ ← k·pᵢ if i is in the initial solution, else pᵢ,   k = 3

§5.3.2  Update:           k ← argmin over loaded i of  μᵢ = (1 + f l ᵢ)·pᵢ/(wᵢdᵢhᵢ)
                          sₖ ← (1 − α)·sₖ,        α ∈ (0,1)
                          l ← argmax over unloaded i of θᵢ = pᵢ/(wᵢdᵢhᵢ·(1 + f u ᵢ))
                          s_l ← (1 + β)·s_l,      β ∈ (0,1)
                          swap sₖ and s_l; leave every other score unchanged

§5.3.3  Reinitialisation: rescore as in §5.3.1 against the best solution so far,
                          then swap a fixed number of randomly chosen score pairs
                          best infeasible                        → α = 2α,   β = 2β
                          best feasible ∧ CoM in central half    → α = α/2,  β = β/2
                          otherwise                              → unchanged

§5.3.4  α = β = 0.1; reinitialise every 1000 iterations; pairs = 5% of items; stop after 5 s
```

### Implementation

Direct implementation of all four subsections, with:

| # | Difference | Category |
| --- | --- | --- |
| 1 | **α and β are clamped to stay inside (0,1).** | Implementation detail enforcing the interval §5.3.2 requires. Unbounded doubling from 0.1 leaves it on the fourth consecutive infeasible round, after which (1 − α)·s turns a score negative. |
| 2 | **Seeded random generator** for the reinitialisation pair swaps. | Implementation detail; "randomly selected", made reproducible. |
| 3 | `ParameterUpdate` runs once per search iteration. | Not a difference. §5.3.3 states the *rule*; the §5 step list and Fig. 6 both place the *call* at the end of every iteration. |
| 4 | β adapts alongside α. | Not a difference, and worth stating because it looks like one: §5.3.3 says "α = 2α and β = 2β" and "α = α/2 and β = β/2" explicitly. |

---

# Part 2 — Junqueira vertical support

## Paper — [J] eqs. (9)–(11)

For every box j placed at (x′, y′, z′) with z′ ≠ 0:

```
Σ over boxes i with z′ − hᵢ ≥ 0
  Σ over x ∈ Xᵢ with x′ − lᵢ + 1 ≤ x ≤ x′ + lⱼ − 1
    Σ over y ∈ Yᵢ with y′ − wᵢ + 1 ≤ y ≤ y′ + wⱼ − 1
        L⁽¹⁾ᵢⱼ · W⁽¹⁾ᵢⱼ · aᵢ,x,y,(z′−hᵢ)   ≥   αⱼ · lⱼ · wⱼ · aⱼ,x′,y′,z′

L⁽¹⁾ᵢⱼ = min(x + lᵢ, x′ + lⱼ) − max(x, x′)
W⁽¹⁾ᵢⱼ = min(y + wᵢ, y′ + wⱼ) − max(y, y′)
```

A box at z′ = 0 is always vertically stable. [J] notes that with the reduced normal-pattern sets
(1)–(3), eqs. (10)–(11) are valid only for α = 1.

## Implementation — `BaldiVerticalSupport.report`

```
required ← extentˣ_j · extentʸ_j
if |z_j| ≤ tol:  return fully supported            // the z′ ≠ 0 exemption

rectangles ← []
for every placement i ≠ j whose top face is at z_j, within tol:
    L ← min(maxˣᵢ, maxˣⱼ) − max(xᵢ, xⱼ)             // L⁽¹⁾ᵢⱼ
    W ← min(maxʸᵢ, maxʸⱼ) − max(yᵢ, yⱼ)             // W⁽¹⁾ᵢⱼ
    if L > tol and W > tol: append the (L × W) rectangle
supported ← UnionArea(rectangles)
return supported + tol ≥ required                  // αⱼ = 1
```

## Differences

This is **a continuous-coordinate geometric implementation of the vertical-support condition of [J]
with α = 1**. It is not an implementation of [J]'s MILP, and should not be described as one.

| # | Difference | Category |
| --- | --- | --- |
| 1 | **Continuous coordinates, no X, Y, Z normal-pattern sets and no `a_ixyz` variables.** | [B]'s heuristic produces continuous positions; there is no discrete grid to sum over. The contact rectangles L⁽¹⁾ and W⁽¹⁾ are computed directly from the placements. |
| 2 | **The contact areas are unioned, not summed.** | Under the non-overlap constraints the two are equal, so nothing is lost. The union additionally cannot double-count a strip that two supporters appear to share because of a tolerance. |
| 3 | **α_j = 1 for every package**, fixed rather than a parameter. | Application choice: complete support. It is also the case in which [J] states eq. (11) is unconditionally sound. |
| 4 | [J] excludes the back and right-hand edges of a top face. | No continuous counterpart; a grid artefact of the discrete formulation. |
| 5 | **Load bearing (14) and horizontal stability (12)–(13) are not implemented.** | Out of scope, stated in `METHODS.md`. |

---

# Part 3 — Liu / Zhang 2D bounding box

Three contributors, kept separate because they are three different sources:

| Contributor | What it provides | Where |
| --- | --- | --- |
| **[L] Liu, Liu & Zhang** | Convex-hull extraction by Graham scan, the approximate-collinearity threshold τ, downsampling to N_max, and the candidate directions taken from every pair of hull points | §3.1, §3.2 |
| **[Z] Zhang, Xu, Dong & Dolan** | The scoring criterion itself — `closeness` — which [L] cites as its reference [15] and does not define | §3.3 |
| **This application** | Final extents from the full point cloud, height from the support plane, and the width/length naming | §3.4 |

[L] answers one question: which way is the object turned. §3.4 is where the papers stop and the
application starts.

## 3.1 Convex hull

### Paper — [L] Algorithm 1

```
P₀ ← lowest(P)                                 // leftmost if tied
P  ← sort by polar angle about P₀
m ← 1
for i ← 1 to n:                                // collapse collinear runs, keep the farthest
    while i < n−1 and ‖sin ∠P₀PᵢPᵢ₊₁‖ ≤ τ:  i ← i+1
    Pₘ ← Pᵢ ;  m ← m+1
if m < 3: return ∅
push P₀, P₁, P₂
for i ← 3 to m:
    while |stack| ≥ 2 and sin ∠(next_top, top, Pᵢ) ≤ τ:  pop
    push Pᵢ
return stack
```

### Implementation — `OrientedBoundingBox.convexHull`

Same structure, with τ = 0.01, [L]'s own recommended value.

### Differences

| # | Difference | Category |
| --- | --- | --- |
| 1 | A collinear run is measured against the run's **first** point, not the previous one. | Implementation detail. Identical at τ = 0; above it, anchoring stops the run drifting off the ray it started on. |

## 3.2 Orientation search

### Paper — [L] Algorithm 2

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

### Implementation — `OrientedBoundingBox.bestOrientation`

```
sample ← ReservoirDownsample(points, N_max = 100)
hull   ← ConvexHull(sample, τ = 0.01)
if |hull| < 3: return nil
bestScore ← −∞
for i ← 0 to |hull|−2:
    for j ← i+1 to |hull|−1:
        axis  ← normalise(hull[j] − hull[i])
        score ← Closeness(sample, axis, d₀)
        if score > bestScore: bestScore ← score; bestAxis ← axis
return bestAxis
```

### Differences

| # | Difference | Category |
| --- | --- | --- |
| 1 | **The criterion is maximised, not minimised.** | [L]'s printed optimisation direction (`S = INT_MAX`, keep `Scur < S`, "a smaller closeness means a better orientation") conflicts with the definition and original use of the referenced closeness criterion of [Z], which increases as the points lie closer to the rectangle edges and which [Z] explicitly treats as a maximisation objective. The implementation follows [Z]'s maximisation convention. |
| 2 | **Reservoir sampling**, seeded. | [L] says "uniformly downsampled" without specifying a method. Reservoir sampling gives a uniformly random subset; seeding makes a scan reproducible. Implementation choice. |
| 3 | Direction vectors instead of `atan2`. | Implementation detail; algebraically the same, and it avoids a wrap at ±π. |
| 4 | N_max = 100. | [L]'s largest tested value, where the reported average error is under 1°. See below. |
| 5 | Only θ is returned; `lcur`, `wcur` are not. | See §3.4 — the size is computed differently by the application. |

**Why 100, precisely.** [L] §IV.E ("Efficiency and Impact of Downsampling") states the experiment directly:
on the 3,095 test cases with 1000 or more points, "we uniformly downsampled its points to a smaller size
ranging from **20 to 100**, with a step size of 10" — so 100 is not a round number picked for convenience,
it is the literal upper end of the only range [L] tested. Within that range: "By downsampling the raw
points to a size of **80 or 100**, it works well with an average error lower than 1°." 100 is one of the
two sizes [L] explicitly reports meeting that bar, and it is the larger of the two — the code comment's
"largest tested value, where the reported average error is under 1°" is that sentence, not a paraphrase
that drifted from it. (§IV.F additionally reports the pair (100 points, τ = 0.01) together delivering a
0.04° average difference from the exhaustive-search baseline and an 8× speed-up, but that is a
consequence of the choice already justified above, not a separate justification for it.) Nothing above
N_max = 100 was tested by [L], so nothing above it could be cited; the implementation does not extrapolate
past the paper's own experiment.

## 3.3 Zhang's closeness

### Paper — [Z]

```
C₁ ← X cos θ + Y sin θ ;  C₂ ← −X sin θ + Y cos θ
D₁ ← argmin( ‖max C₁ − C₁‖ , ‖C₁ − min C₁‖ )      // per point: pick the nearer of the two sides
D₂ ← argmin( ‖max C₂ − C₂‖ , ‖C₂ − min C₂‖ )      // per point: pick the nearer of the two sides
β ← 0
for each pair (d₁, d₂):  β ← β + 1 / max( min(d₁, d₂), d₀ )    // one (d₁, d₂) per point
return β                                        // the search takes the argmax
```

`D₁` and `D₂` are per-point: for point *i*, `D₁ᵢ` is that point's own distance to whichever of the two
sides of axis 1 it happens to be nearer, independent of what every other point picks — which is what
makes `D₁` a vector long enough for "for each pair (d₁, d₂)" to range over one pair per point. This
matches Zhang's own definition and the reference open-source transcriptions of it (e.g. Autoware's and
PythonRobotics' L-shape fitters).

### Implementation — `OrientedBoundingBox.closenessScore`

The same per-point `D₁ᵢ = min(c1_max − c1ᵢ, c1ᵢ − c1_min)`, `D₂ᵢ` likewise, and the same
`1/max(min(D₁ᵢ, D₂ᵢ), d₀)` accumulation, `d₀` supplied as `minimumEdgeDistance`.

### Differences

**Found and fixed, not merely checked.** An earlier version of this function read the vectorised
`argmin(‖max C1 − C1‖, ‖C1 − min C1‖)` notation as a single *scalar* choice per axis — comparing
`Σᵢ(c1_max − c1ᵢ)²` against `Σᵢ(c1ᵢ − c1_min)²` once for the whole cloud, then using that one verdict
for every point. That is a real, verified deviation from [Z]: it is exact on point clouds symmetric
enough for the vote to agree with the per-point answer for (nearly) every point — which is what every
prior unit test's fixtures happened to be — but on an asymmetric or partially-occluded cloud it forces
roughly half the points to be scored against the *far* edge instead of their own near one, discarding
real evidence and biasing the axis search. Confirmed by comparing both formulas directly against
synthetic asymmetric box clouds before changing the code. Fixed to the per-point form above; see
`BaldiPaperFidelityTests.testClosenessIsMaximisedSoTheChosenAxisHugsTheRectangle`, which still passes
under either formula and therefore could not have caught this on its own — it was not extended, because
the discriminating case is a full-perimeter, deliberately asymmetric cloud, which belongs with the other
orientation-search behaviour rather than duplicated as a unit fixture here.

Where [L] and [Z] disagree on the direction of optimisation, see §3.2, difference 1.

## 3.4 Final extents and height — application only

**Not from [L] or [Z].** [L] states explicitly that it "focus[es] on evaluating the orientation
accuracy … and omit[s] the size information", and warns that size is the quantity most damaged by
missing points. This application is measuring size, so it takes the orientation from the paper and
builds the box itself.

```
axis   ← bestOrientation(all 2D points)               // Part 3.2, the paper's answer
fit    ← min/max projection of ALL points onto (axis, axis⊥)
if depth > width: swap, so the longer horizontal side is called width
height ← max projection of every point onto the up axis − support-plane height
```

| # | Element | Category |
| --- | --- | --- |
| 1 | Extents from the **full** cloud while orientation uses the sample. | Application extension. A downsample discards disproportionately the extreme points, which are exactly the ones that set the extents. It cannot affect the orientation, which is computed first and from the sample only. |
| 2 | Height from the support plane to the highest point. | Application; [L] is purely 2D. |
| 3 | Longer horizontal side named "width". | Application naming convention. |
| 4 | Full 3D and Top modes share this fitter. | Application. The world is gravity-aligned and the object rests on a horizontal plane, so the box has a vertical axis by construction and the 3D fit reduces to the same 2D problem. A PCA fit remains as a fallback for a cloud too degenerate to hull. |
| 5 | The extreme projection is **literal**. Depth artifacts are rejected upstream, in image space, never here — see below. | Application; the rejection itself is a standard depth-discontinuity test, not a new method. |

### Where depth-artifact rejection lives, and why it is not here

The extents above are literal: the box is exactly the smallest box containing every point handed to
the fitter. Nothing is trimmed at this stage, deliberately.

LiDAR/ToF sensors do produce "flying pixels" — readings displaced past the true surface, generated at
sharp depth discontinuities, which is why a box-shaped object generates far more of them than a
smoothly curved one. They are rejected, but **in image space, before a point is ever unprojected**, in
`ObjectMaskProcessor.maskedWorldSurface`: a depth sample is admitted only if at least three of its four
pixel neighbours are also admitted and none of them differs from it in depth by more than a proportional
threshold. That is the standard depth-discontinuity / neighbourhood-consistency test for flying pixels,
and image space is the only place it can be applied, because it is the only place where "neighbour" is
still defined.

An earlier attempt in this project put a second, statistical filter in the fitter instead
(`RobustExtent`): sort each axis's projections, split them into runs at large gaps, and keep the
largest run. **It has been removed.** Once a point is projected onto an axis, a thin real feature — a
prong, a handle, a tab — and a small multipath cluster are the same thing: a few points set apart from
the bulk. The rule cannot separate them even in principle, and in practice it deleted thin parts of real
objects, which is exactly what it was observed doing. It also introduced four thresholds with no source.
`ThinFeatureExtentTests` pins the restored behaviour: every point drawn is inside the box drawn.

### The cross-frame merge: `ObjectBoundingBox.enclosing`

Purely application behaviour; no paper claims anything about it. While the object fits in the point
accumulator the displayed box is the current `OrientedBoundingBox.make` fit. Once `PointAccumulator`
reaches capacity, later frames instead rebuild the box with `ObjectBoundingBox.enclosing`, which takes
the literal min/max of the retained surface points unioned with the box's existing extent, on the rule
that a box already confirmed must never be shown smaller later. It is the same literal-extent rule as
the fitter, applied to the accumulated point set.

### Keeping the points inside the mask: silhouette carving

The box is the literal extent of the retained points, so the box is only correct if the points are.
Points were only ever *added*: `PointAccumulator` never drops a voxel once it has been observed
`minObservations` times. A single frame on which the segmentation jumped to the wrong object —
which happens, because the locked instance is re-matched per frame from 2D geometry and appearance
alone, and admitted points are only required to lie within 42 cm of the anchor — therefore left
foreign points in the cloud for the rest of the scan, and the box grew to contain them. Observed
directly as dots that sit inside the mask from the viewpoint they were captured from and outside it
from any other.

Removing them again is the standard **silhouette / space-carving** argument — Laurentini's visual hull
(1994), and Kutulakos & Seitz, *A Theory of Shape by Space Carving* (2000): a point that lies inside
the camera frustum, is not occluded by anything nearer, and still falls outside the object's silhouette
cannot belong to the object.

```
for each retained point p:
    (col, row, d) ← project p into this frame          // exact: world → camera → intrinsics
    if p is behind the camera or outside the frame:  this frame says nothing
    if not ClearlyOutside(col, row):                 this frame says nothing
    if depth(col,row) > 0 and depth(col,row) < d − voxelSize:   hidden ⇒ says nothing
    disagreements[p] += 1
    if disagreements[p] ≥ minObservations:  remove p

for each retained point this frame vouched for:  disagreements[p] ← 0

ClearlyOutside(col,row) = the pixel and its four neighbours are all outside the mask
```

Three things keep this from eating real surface, and none of them is a new tuned constant:

- **`ClearlyOutside` is the silhouette dilated by one pixel.** A segmentation boundary wobbles by a
  pixel between frames, most of all on a translucent or specular surface; a point sitting on the true
  edge must not be carved by that wobble. One pixel is the finest distinction the mask can make.
- **The occlusion test.** Depth is measured to the nearest surface along the ray, so a point on the
  object's own far side reads as "something nearer" and is correctly judged unobservable rather than
  empty. Carving only ever acts on space it can actually see. One voxel of slack absorbs sensor noise.
- **Repeated, uninterrupted disagreement.** Removal needs `minObservations` frames — the same constant
  a point needs to be trusted in the first place, so evidence to drop a point is held to exactly the
  standard as evidence to keep one — and any frame that vouches for the point clears its doubt.

Everything the test uses comes from **one frame**: the silhouette, the pose it was seen from, the
intrinsics, and the depth map, bundled together in `ObjectMaskSilhouette` by the same pass that
extracts the points. So the projection is exact. This replaces an earlier attempt
(`removeVisiblePointsOutsideCurrentMask`) which had the right idea but tested against a mask up to
0.2 s stale, warping viewport coordinates by an approximate scale-and-offset to guess where a point
would have landed, and which only ran while the mask overlay happened to be visible on screen.

Pinned by `ObjectMaskSilhouetteTests`, including the projection's sign conventions — which must mirror
the unprojection in `maskedWorldSurface` exactly, or every carve decision is wrong.

### A removed point could not be allowed to reshuffle the rest

`OrientedBoundingBox.bestOrientation` reservoir-samples `PointAccumulator.stablePointsSnapshot()` with a
fixed seed. Reservoir sampling's initial fill is a literal prefix of the array being sampled, so which
points end up in the sample is a function of the array's **order**, not only its content — the seed is
fixed specifically so that the same accumulated cloud reproduces the same orientation search, as §3.2's
implementation notes already state.

Removing a point used to plug the gap with whichever point currently sat last in the array — an
ordinary swap-remove, correct for an unordered set. It is not correct here: it reshuffles the relative
order of every point that survives, and after that reshuffling the "same" cloud, sampled again, hands
the orientation search an effectively different, arbitrary ~100-point subsample. That is indistinguishable
downstream from the fit itself being unstable, and it used to be rare enough not to matter — the only
removal paths were capacity eviction and a manual, gated cleanup — but it stopped being rare the moment
silhouette carving started calling it every frame. This is what "the bounding box rotates wildly between
frames that added nothing" actually was: not the orientation search failing, but the search being fed a
freshly-shuffled hand of the same cards each time.

Fixed by making removal a single order-preserving compaction pass — every point that survives keeps its
position relative to every other survivor — rather than a swap-remove per key. `PointAccumulatorOrderingTests`
pins this directly; two of its five tests were confirmed to fail against the previous swap-remove
implementation before this fix was written, and continue to pass against it now.

### The lock follows the mask on screen

`aimedCandidate` chooses which segmented instance the crosshair is on, and takes a `continuing:` hint —
the mask already on screen, which "wins any argument it is still eligible for", judged on a looser
threshold so that sitting on a boundary does not flick the mask on and off. The preview passed that
hint. The lock did not: `lockCandidate` omitted it and let it default to `nil`.

So pressing *measure* re-decided from scratch which object the crosshair was on. On a frame whose
segmentation momentarily differed from the one the user was looking at, that either locked a different
instance or found none at all and returned `.unchanged` — the button pressed and no measurement
starting. Both paths now pass the hint, which is what the function's own contract already claimed:
the object that lights up is the object that gets measured.

### The drawn footprint follows the current fit

`ARCameraView.viewGatedBox` classifies the view (`.topDown`, `.side`, `.other`) to decide when width
and depth have been observed well enough to call the scan settled. That classification once also decided
*what geometry was drawn*: the footprint was published only on `.topDown` frames, so approaching an
object from any other angle drew whatever rectangle the first frame had guessed, over a point cloud that
had since filled in and settled underneath it — the box standing off the dots on every side. The height
had already been fixed for precisely this reason; the footprint had not. Both now publish the current
fit on every frame.

This cannot shrink the box as the phone moves, because the fit is taken over the *accumulated* cloud,
not the current frame's: the masked accumulator retains points from every earlier view and is only ever
`pruneTransient`-ed, so a face that has been seen stays seen.

---

# Part 4 — The centred extension

**This method is not contained in [B], [J], [L] or [Z].** It is an extension introduced in this
project and must not be presented as any paper's algorithm.

## Why it exists

[B] treats balance as a feasibility condition. Entering the admissible centre-of-mass region
satisfies that condition and, by §5.2's first stopping condition, ends the relocation procedure.
[B]'s overall heuristic does still care about balance beyond feasibility — the unbalancing index
appears in the merit function, eq. (24) — but the *relocation* stops at the region boundary. The
centred extension differs by explicitly continuing relocation towards the centre of the region after
feasibility has already been achieved.

For a drone module the admissible region is a tolerance, not a target; margin inside it is what
absorbs flight loads and error in the measured masses.

## Modifications relative to the paper implementation

Everything not listed is shared: the same construction, the same six sorting criteria, the same
scoring and parameter adaptation, the same full-support rule, the same verifier, the same
50-iteration cap.

| | Paper mode | `centred` |
| --- | --- | --- |
| Stop relocating when the centre of mass enters [L, U] | yes, §5.2's first condition | no, keeps going |
| Ranking of solutions | eq. (24), F = P − αÛ | package count, then distance from the centre of [L, U] |
| Movement domain Dᵢ | the free-slide box bounded by the item's neighbours, [B]'s own construction | the whole container minus the item's extent |
| Candidates when the prescribed point is unsupported | that point at each resting height | the same, plus a distance-ordered grid built from neighbouring faces, capped at 48 |
| Relocation order | packing order | heaviest first |

## Measured effect

40 random 8-package instances, 0.35 s each:

| | packages loaded | balanced | mean distance from the region centre |
| --- | --- | --- | --- |
| paper | 317 / 320 | 40 / 40 | 103 mm |
| centred | 315 / 320 | 40 / 40 | 4 mm |

Both satisfy [B]'s balancing constraint. `centred` satisfies it with margin, at a cost of about 0.6%
of the load.

---

# Part 5 — When a measurement is finished

The rule that decides a scan has settled. Included here because it is the other place in the project
where a statistical procedure could be mistaken for a cited method.

## The condition, exactly

Over the sliding window of the last **N = 24** observations of one dimension:

```
x̄ₙ = (1/n) Σ xᵢ
sₙ = √( Σ(xᵢ − x̄ₙ)² / (n − 1) )              Bessel-corrected sample standard deviation
hₙ = t₀.₉₇₅,ₙ₋₁ · sₙ / √n                     95% two-sided confidence-interval half-width
δₙ = | mean(second half of window) − mean(first half) |
dₙ = max(5 mm, 1% · |x̄ₙ|) / 2                 one combined tolerance, halved because hₙ is one side
```

The scan finishes when, for width, depth **and** height simultaneously:

```
n ≥ 24    ∧    hₙ ≤ dₙ    ∧    δₙ ≤ dₙ    ∧    a support plane exists beneath the object
```

Second exit: if at least 4 observations exist and none has arrived for 2.5 s, the measurement
finishes anyway, on the grounds that no further waiting can tighten it.

Third exit: after 10 s the reading is taken as it stands, whatever the statistics are doing.

The support-plane condition applies to **all three** exits, because a finish without it is refused
further down the line, and a measurement that both claims to have converged and cannot end is a
measurement that never ends. For the same reason the progress shown on the HUD is held below 100%
while the support is unknown. The support may come from an ARKit plane anchor, a raycast against
estimated planes, or the depth histogram of the surface around the object — the same height the
fitted box is already standing on; small objects, whose tables ARKit is slowest to bound, otherwise
measure indefinitely.

`dₙ` is a single threshold, not two alternative tests. The relative term governs dimensions above
500 mm; the 5 mm floor governs everything smaller, so a 100 mm object is never asked for the 1 mm
precision it could not reach.

## What is literature-derived and what is not

| Element | Status |
| --- | --- |
| The stopping **form** `hₙ ≤ dₙ` — sample until the interval is narrow enough, with n not fixed in advance | The fixed-width sequential principle of **Chow & Robbins (1965)**. The only element with a literature source. |
| Sliding window of 24 instead of an accumulating sample | Project-defined, **and the reason the citation cannot stand as "the method"** |
| N = 24 | Project-defined |
| 95% level | Project-defined |
| Student-t finite-sample quantile in place of a normal quantile | Project-defined implementation choice |
| 5 mm floor, 1% relative term | Project-defined |
| The drift test `δₙ ≤ dₙ` | Project-defined; no counterpart in Chow & Robbins |
| The 2.5 s stale-evidence exit | Project-defined safeguard |
| The 10 s time limit | Project-defined safeguard |
| Requiring a support plane | Project-defined; a physical precondition the statistics cannot see |

## Why this is not the Chow–Robbins procedure

Chow & Robbins accumulate every observation. That is what makes `hₙ → 0` almost surely and gives the
procedure its asymptotic guarantee on coverage and width. Here the estimator runs over a **fixed
24-frame window**, so `hₙ` does not shrink with time; it measures how consistent the most recent 24
fits are with each other.

The window is deliberate rather than a shortcut. The quantity being estimated genuinely moves as new
faces of the object come into view — a side view that finally reveals the true height changes the
mean being estimated — so an accumulating sample would average across a changing quantity and break
the fixed-mean assumption more seriously than the window breaks independence.

A second, smaller caveat: consecutive LiDAR frames of a stationary object from a nearly stationary
viewpoint are **positively correlated**, so `sₙ/√n` understates the true uncertainty of the mean.
The window bounds how far that error can compound but does not remove it.

The description used throughout the code and notes is therefore: *a windowed precision criterion
that borrows the fixed-width sequential stopping form of Chow & Robbins, with project-defined
thresholds and two additional conditions.* They may be cited as the origin of the stopping form;
they must not be cited as the implemented method, and none of 24, 95%, 5 mm or 1% may be attributed
to them.

---

# What is tested

`BaldiPaperFidelityTests` pins the claims above that could otherwise drift:

| Test | Protects |
| --- | --- |
| `testMeritIsProfitMinusAlphaTimesUnbalancingIndex` | eq. (24) |
| `testMeritPenaltyCanOrderEqualCountsButNeverOutvotesAPackage` | the normalisation of U is a tie-break, not a re-weighting |
| `testAnUnbalancedPackingMayBeTheSearchIncumbent` | BS may be infeasible, as §5.3.3 presupposes |
| `testBothAlphaAndBetaAdaptTogetherAsTheParagraphStates` | §5.3.3 verbatim |
| `testParametersStayInsideTheOpenUnitIntervalTheScoreUpdateRequires` | the §5.3.2 interval |
| `testGravityCompactionIsVacuousUnderFullSupport` | the claim in Part 1.5, difference 3 |
| `testPaperBalancingUsesPackingOrderAndCentredUsesHeaviestFirst` | Part 1.5, difference 5, and Part 4 separation |
| `testEveryReturnedPackingPassesTheIndependentVerifier` | overlap, boundary, balance and support of every result |
| `testClosenessIsMaximisedSoTheChosenAxisHugsTheRectangle` | Part 3.2, difference 1 |
| `testFullCloudExtentsDoNotChangeTheOrientationChosen` | Part 3.4, element 1 |

`MeasurementConvergenceRuleTests` pins Part 5:

| Test | Protects |
| --- | --- |
| `testToleranceIsHalfOfMaxOfFloorAndRelativeTerm` | dₙ is one combined threshold, halved |
| `testWindowSlidesAndTheMinimumBlocksAnEarlyFinish` | 24 is both a window and a minimum, and not a cap |
| `testNoisyMeasurementsDoNotFinishAndTheirHalfWidthIsReported` | the precision test really is hₙ |
| `testASteadyRampIsRejectedEvenWhenTheIntervalIsTight` | δₙ is a separate condition |
| `testOneUnsettledDimensionBlocksTheWholeMeasurement` | all three dimensions must clear it |
| `testWithoutASupportPlaneNothingFinishes` | the physical precondition |
| `testStaleEvidenceFinishesTheScanWithoutThePrecisionTest` | the second exit, and that it is a safeguard |

`ThinFeatureExtentTests` pins the literal-extent rule:

| Test | Protects |
| --- | --- |
| `testAThinProtrusionIsInsideTheMeasuredBox` | a thin real feature is inside the box, not trimmed off it |
| `testTheBoxIsExactlyTheExtremesOfTheCloudItWasGiven` | the box is the literal min/max of its input |
| `testEnclosingContainsEveryRetainedPointAndNeverShrinks` | the cross-frame merge contains every retained point and never shrinks |

`ObjectMaskSilhouetteTests` pins silhouette carving:

| Test | Protects |
| --- | --- |
| `testAPointStraightAheadProjectsToThePrincipalPoint` | the projection, and its sign conventions against `maskedWorldSurface` |
| `testOffAxisPointsProjectToTheExpectedSideOfTheImage` | that +x is right and +y is a smaller row, as the unprojection assumes |
| `testAPointBehindTheCameraOrOutsideTheFrameHasNoPixel` | a point the frame cannot see is never judged |
| `testProjectionRespectsTheCameraPose` | the silhouette is only valid with the pose it was captured at |
| `testAPixelOnTheBoundaryIsNotClearlyOutside` | a one-pixel mask wobble cannot carve real surface |
| `testAPixelWellAwayFromTheObjectIsClearlyOutside` | a genuinely foreign point is still carveable |

`PointAccumulatorOrderingTests` pins order-preserving removal:

| Test | Protects |
| --- | --- |
| `testRemovingOnePointPreservesTheRelativeOrderOfEveryOtherPoint` | a single removal cannot reshuffle survivors — fails against the old swap-remove |
| `testRemovingSeveralPointsAtOncePreservesRelativeOrder` | a batch removal, as silhouette carving performs, cannot reshuffle survivors — fails against the old swap-remove |
| `testANewlyAddedPointAppendsAfterExistingOnesEvenFollowingARemoval` | a new point fills the end of the array, not the gap left by a removal |
| `testTwoIdenticallyOrderedSnapshotsSampleIdentically` | the property that actually matters: the same sequence of operations reproduces the same snapshot order, which is what makes the orientation search's fixed seed meaningful |

`StudySecondBoxRecordingTests` pins that a box's measurements and photos, not only its timing, reach the
box actually in progress after `advanceToNextBox`:

| Test | Protects |
| --- | --- |
| `testMeasurementProgressReachesTheSecondBoxAfterAdvancing` | per-object progress lands on the second box, not the first or nowhere |
| `testRecordCurrentBoxReachesTheSecondBoxAfterAdvancing` | the final snapshot — objects, loaded IDs, packing mode, balance — lands on the second box |
| `testAPhotoStoredForTheSecondBoxIsNamedForTheSecondBox` | a photo captured after advancing is filed under the box now in progress |
