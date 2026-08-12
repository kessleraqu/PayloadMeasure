# PayloadMeasure

Measure a payload with the phone, then work out how to load it. Two halves:

```
PayloadMeasureApp
  └── ContentView
        ├── ARCameraView          the AR session and everything drawn in it
        └── MeasurementOverlayView  the HUD, and the way into the packing screens

AR/            session, aimer, and the coordinator that runs the scan
Capture/       segmentation, depth accumulation, box fitting, session state
Measurement/   the two measurement methods, and the automatic-lock rule
Packing/       what to do with the measurements once they exist (own NOTES.md)
Utilities/     small shared helpers
```

## Where things live

| File | What it holds |
| --- | --- |
| `AR/ARCameraView.swift` | The AR view and its coordinator. Session lifecycle, the mask loop, the scan loop, support-plane tracking, and all RealityKit content. Navigate it by its MARK sections. |
| `AR/ARSessionManager.swift` | Owns the ARKit session and publishes the readiness flags the UI gates on. |
| `AR/AimerState.swift` | Shape of the centre aimer, driven by the surface under the crosshair. |
| `Capture/ObjectMaskProcessor.swift` | Vision foreground segmentation, and keeping masks matched to the same object across frames. |
| `Capture/ObjectCapture.swift` | Depth to box. Pure computation: accumulate, voxelise, cluster, fit. |
| `Capture/ObjectCaptureEngine.swift` | Session state: active object, locked objects, names, weights, everything the HUD reads. |
| `Measurement/MeasurementWorkflowMode.swift` | Full 3D or Top. |
| `Measurement/MeasurementConvergence.swift` | The sequential stopping rule behind the automatic lock. |
| `MeasurementOverlayView.swift` | The HUD. |

Everything is inside `PayloadMeasure/`, which is a synchronised Xcode group — new files are picked
up automatically, and there is nothing to add to the project file.

## Why the code looks the way it does

These are the non-obvious decisions. They were comments in the source and are collected here so the
code stays readable.

**The coordinator is one long type.** It owns mutable per-frame state. Splitting it across files
would mean making that state internal, which buys navigability at the cost of the encapsulation.
The MARK sections do the same job.

**Observation has a gap.** `withObservationTracking` fires `onChange` once and then stops tracking
until it is re-registered, and re-registering has to hop through a `Task` to get back on the main
actor. Anything mutated inside that gap is never delivered — and the gap is widest on startup, when
the main thread is busiest. Every branch in `handleEngineRevisionChange` is therefore guarded by an
`observed… != current` comparison that it then syncs, so the whole thing is idempotent. The scan
timer polls it as a backstop.

**Finishing commits first and asks afterwards.** Tapping Finish freezes the dimensions immediately. The
name and weight sheet comes after, against an object already stored. The old order left the
transaction open while someone typed, and ARKit kept refining the plane the half-committed box was
bound to, so the geometry drifted out from under it. Cancel is the opposite door: it throws the
measurement away and deselects, so nothing half-measured is ever kept. Edit resumes a finished
object, and is offered only while a marker for it is visible — a stale focus is not enough.

**Anchor corrections rebase, they do not repaint.** ARKit refines an anchor while an object is
locked. The rendered box follows automatically, but the accumulated depth voxels are still in the
older world frame. The canonical box is rebased and the evidence reacquired, so unlocking never
mixes two frames. Box coordinates belong to the world frame captured alongside the published anchor
transform, and keeping that exact inverse as the child transform is what lets RealityKit apply later
corrections without dragging the box back into a stale frame.

**Support planes are held across a bad frame or two.** ARKit re-cuts a plane's boundary polygon as
it refines it, so the ring of validation points can briefly fall outside a plane that is perfectly
good. The last accepted match is carried over rather than dropped.

**The support surface is the nearest level below, not the lowest.** With the object's own points
excluded, the closest well-populated level beneath it is the table, not the floor past the table
edge. The plane search and the depth search break that tie the same way, so they agree.

**Depth noise is rejected by neighbours.** Most stray points are silhouette-ring samples from a
fuzzy mask edge, or LiDAR flying pixels straddling a depth step. A sample is kept only if at least
three of its four depth-grid neighbours are also admitted and depth-continuous.

**Framing advice is held before it changes.** The object's apparent size sits near a threshold for
most of a scan, so recomputing "move closer / move further" every mask update made the two trade
places frame by frame. A directional instruction now has to agree with itself four times before it
is published. Three things bypass the hold, because none of them can contradict itself: the first
advice of a scan, reaching "framed correctly", and any change the fit itself reports in how much
detail it has.

**The support raycast is not gated on the world mesh.** It raycasts against ARKit's *estimated
planes*, which come from plane detection. It was once guarded by `isSceneReconstructionEnabled`,
which was harmless only while the mesh happened to be on: once the mesh became on-demand, the whole
support-height fallback switched itself off and scans sat on "waiting for the surface" while leaning
on the much heavier depth path. Gate this on depth support, never on reconstruction.

**Each dimension remembers the view that could measure it.** Width and length come from the last
top-down view, height from the last side view. Without that, a side view — where the background
leaks into the footprint — would overwrite a good top-down measurement.

**The automatic finish is a windowed precision rule, not a timer.** The exact condition is written
out at the top of `Measurement/MeasurementConvergence.swift`, and `../PSEUDOCODE.md` Part 5 sets it
against the literature. In short: over the last 24 fits of each dimension, the 95% confidence
interval must be no wider than max(5 mm, 1% of the dimension), the two halves of that window must
agree to the same tolerance, and a support plane must exist.

Be careful with the attribution here. The precision test has the shape of Chow and Robbins' (1965)
fixed-width sequential rule, hₙ ≤ dₙ, but it is computed over a **sliding 24-frame window** rather
than an accumulating sample, so hₙ does not shrink towards zero and their guarantee does not
transfer. The window is the right engineering choice — the quantity being estimated really does move
as new faces come into view — but it means the rule should be described as a windowed precision
criterion that borrows the stopping form, not as the Chow–Robbins method. Every threshold in it
(24, 95%, 5 mm, 1%, the drift test, the 2.5 s timeout) is project-defined.

Progress is the fraction of the rule satisfied, taken as the minimum over its conditions, so the bar
shows the limiting one.

**The overlay is not torn down for the details sheet.** Rebuilding the whole hierarchy — glass
containers, mask layers, aimer, every card — in the same frame that presents an alert and cold-starts
the keyboard was a visible stall. Measurement has already stopped by then, so leaving it up is free.

**The segmentation pipeline is throttled, and its actor is reentrant.** Two things that were wrong
and are worth not reintroducing. The mask pass used to resubmit the moment the previous one
finished, driven by a 60 Hz display link, so Vision ran back to back forever and starved ARKit's own
tracking of CPU — which is what makes ARKit retain frames and drop camera output. There is now a
floor between passes that also backs off to the last pass's duration. And `ObjectMaskProcessor` is
an actor, so a cancelled pass sits suspended at its `await` while the next one enters and mutates
`trackedObjects`; any array index taken before an `await` has to be looked up again afterwards.

**A mask image is only rendered if something will draw it.** The overlay only ever draws the active
object's mask and the live preview, but the processor used to generate a full mask and a full-frame
CGImage for every finished object too, every pass, for the engine to throw away. That was the cost
that grew with each object measured.

**Box edges come from a pool.** Every entity beyond the prepared pool is built synchronously, and
twelve dashed edges at the per-edge maximum would need nearly 300 of them — a visible stall exactly
when the box first appears.

## Sources

Box fitting — both Full 3D and Top — follows Liu, Liu and Zhang, *Estimation of 2D Bounding Box Orientation with
Convex-Hull Points*, IV 2020: downsample to 100 points, Graham-scan hull with approximate
collinearity at τ = 0.01, every hull-point pair as a candidate direction, and the closeness score of
Zhang, Xu, Dong and Dolan (IV 2017). Three things are worth stating explicitly.

**Closeness is maximised, not minimised.** Liu's Algorithm 2 initialises `S = INT_MAX` and keeps
`Scur < S`. But closeness is Zhang's β = Σ 1/max(min(d₁,d₂), d₀), which is larger the better the
points hug the rectangle, and Zhang's own search takes the argmax. Minimising it would deliberately
select the worst-fitting orientation, so Algorithm 2's comparison is a misprint and the maximum is
taken here.

**Orientation uses the downsample; the extents use every point.** Liu downsamples once and works
from that set throughout, but the paper explicitly omits size — "we focus on evaluating the
orientation accuracy… and omit the size information" — and warns that size is the quantity most
damaged by missing points. This app is measuring size, and the samples a downsample discards are
disproportionately the extreme ones. The hull and the candidate-direction search are unchanged.

**Full 3D and Top share the fitter.** Full 3D used to take its orientation from a 2-D PCA about the
gravity axis, which follows the spread of whichever faces happen to be visible rather than the
object's edges — badly biased when one side is better sampled than another. Because the world is
gravity-aligned and the object stands on a horizontal plane, the box has a vertical axis by
construction, so the 3-D fit reduces to the same 2-D orientation problem Top already solved. Both
now run the same convex-hull search; they differ only in which points reach it. The PCA fit remains
as a fallback for a cloud too degenerate to hull.

**Downsampling is seeded reservoir sampling**, so a uniformly random subset, reproducible run to
run. Liu says "uniformly downsampled" without saying whether that means a random subset or a fixed
stride.

Side-by-side pseudocode for this and for the packing algorithms is in `../PSEUDOCODE.md`. The
packing side also has `Packing/METHODS.md`.

## Testing

`PayloadMeasureTests` covers the packing pipeline, box preparation, the AR suspension rules and the
decimal parsing. The AR and capture pipelines are not unit tested — they need a LiDAR device. Test
those by running a scan on hardware.
