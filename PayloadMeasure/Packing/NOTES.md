# Packing

Everything that happens after measuring: choose an outer box for each measured object, decide where
the boxes go, and show the operator how to load them.

`METHODS.md` covers the academic side — the two papers, what was taken from each, and where this
code deviates. This file is about the code.

## Flow

```
ObjectCaptureEngine (locked measurements)
        │
        ▼
PackagePreparation ──── system assigns the smallest fitting box; operator names and weighs it,
        │              or marks the object as being a box already
        │
        ▼
PackingStore ────────── builds the inputs, runs the chosen method off the main actor, holds results
        │
        ├── Balance/    every package flat on the floor, centre of mass pulled to a target
        └── Knapsack/   packages stacked in 3D, some possibly left out, centre of mass held in a box
        │
        ▼
ArrangementView ─────── drawings, balance figures, layer-by-layer loading order
```

The two methods are independent. Neither calls into the other; deleting one would not disturb the
other beyond the picker in `ArrangementView` and the matching branch in `PackingStore`.

## Files

| File | What it holds |
| --- | --- |
| `PackingStore.swift` | The hub. Converts measurements into method inputs, launches and cancels solves, publishes results, and tracks a signature so a stale answer is never shown as current. |
| `PackagePreparation.swift` | The box list and the per-object preparation state. |
| `PreparationView.swift` | The step-through screen: the assigned box, the measured size, the packed weight, then straight into the arrangement without leaving the sheet. |
| `ArrangementView.swift` | Result screen. Switches between the two methods on the same measurements. |
| `BoxCatalogView.swift` | The box list and the form for adding to it. A box is named by its size and has 1 mm walls; the whole list persists in user defaults and every box can be deleted. |
| `ArrangementSettingsView.swift` | Module size, clearances, balance target and domain, time limits. |
| `Balance/BalanceModel.swift` | Problem types and the mixed-integer model, plus the valid inequalities that prune it. |
| `Balance/BalanceSolver.swift` | Runs the model in two passes — balance, then compactness — and checks the answer. |
| `Balance/MILPSolver.swift` | Bounded-variable simplex and branch and bound. Nothing else uses it. |
| `Balance/BalancePlanView.swift` | Plan and elevation drawing for a Balance result. |
| `Knapsack/Knapsack.swift` | Containers, packages, placements, the support rule and the verifier. |
| `Knapsack/KnapsackHeuristic.swift` | The search: sorting, extreme-point construction, balancing, and the loop over them. |
| `Knapsack/KnapsackSolver.swift` | Entry point. Validates, searches, and refuses anything the verifier rejects. |
| `Knapsack/KnapsackReferenceModel.swift` | The source paper's exact model, kept for inspection. Not run by the app. |
| `Knapsack/KnapsackResultView.swift` | Mode picker, layer-by-layer loading guide. |
| `Knapsack/KnapsackSceneView.swift` | Rotatable 3D view and flat per-layer footprints. |
| `PackingARView.swift` | The finished plan placed on a real table at full size, one layer at a time. |

## Things worth knowing before changing anything

**Isolation.** The project defaults to `MainActor`. Every solver type is marked `nonisolated` so the
search can run on a detached task. Drop that keyword and the solve silently moves back onto the main
actor, blocking the AR session.

**Cancellation.** `PackingStore` keeps a handle on the detached work, not just the awaiting task.
Cancelling the parent does not propagate into a detached child, so both are cancelled and the search
loop polls `Task.isCancelled` between rounds.

**Nothing reaches the screen unverified.** `BaldiVerifier.verify` re-derives containment, overlap,
support and centre of mass from the placements alone. If it fails, the solver returns no solution
rather than a suspect one. The same holds for Balance via `PackingGeometryCheck`.

**The augmented view runs its own AR session.** Presenting the packing workflow already suspends the
measurement session (`setPackingArrangementPresented`), which releases the camera, so
`PackingARView` can start a second `ARWorldTrackingConfiguration` of its own. If that suspension is
ever removed, two sessions will fight over the camera.

**Packing is z-up, RealityKit is y-up.** Every placement crossing into `PackingARView` swaps those
axes, and the horizontal ones are offset by half the container because the shell is centred on the
anchor. Getting one of the two wrong puts packages outside the box in a way that still looks
plausible from some angles.

**Determinism.** The knapsack search is seeded, so the same input always produces the same packing.
Useful for tests; do not replace the seeded generator with `SystemRandomNumberGenerator`.

**Units.** Millimetres and kilograms throughout. Package sizes are whole millimetres, rounded up
from the measurement; the container is rounded down. Placement coordinates stay continuous because
the balancing stage can land between millimetres.

**Measured sizes are rounded to the micrometre first.** The measurement is Float metres, so 0.4 m
arrives as 400.000006 mm. Rounding a package size up from that adds a millimetre to every axis of
every object that is its own box. `measuredSizeMillimetres` clears the noise before anything else
sees it.

**Excluding an object is only for objects that need a box.** An object marked "already a box", or
given an enforced size, needs no box at all — running it down the "nothing fits, exclude it" path
throws away the name and weight just entered and leaves it permanently incomplete, which makes the
plan screen unreachable. Check `isItsOwnBox` and `forcedSize` before ever excluding.

**Boxes are assigned, not chosen.** `assignBoxesAutomatically` gives every object the smallest box
it fits; the operator is told which one to use. The only override is marking the object
as being a box already, in which case its measured size is the package size and no preset is
involved. A third option, an enforced size, overrides both — it exists so a bad measurement does not
stop a load being planned. All three converge on `packagedSizeMillimetres`, which is the single
answer to "how big is this package" that the two methods and the preparation screen all read.
Priority runs enforced size, then own box, then assigned box.

**Scaling in the MILP.** `BalanceModel` divides rows by positive constants and holds positions as
fractions of the module. Written in raw units the matrix spans about eight orders of magnitude and
the simplex stalls. The scaling changes no feasible point.

## Tests

`PayloadMeasureTests` — the knapsack path is covered end to end:

| Suite | Covers |
| --- | --- |
| `BaldiPipelineTests` | Construction, sorting, the search loop, the reference model. |
| `BaldiVerticalSupportTests` | The support rule, including partial and multi-supporter contact. |
| `BaldiCOMQualityTests` | Paper versus centred balancing, and that package count stays primary. |
| `BaldiLoadingGuideTests` | Layer grouping for the loading order. |
| `PackingStoreComparisonTests` | Both modes published together, stale results suppressed. |
| `PackagePreparationTests` | Box selection and exclusion. |

Run them with `xcodebuild test -scheme PayloadMeasure -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`.

The Balance path has no automated tests. It is exercised through the UI only.
