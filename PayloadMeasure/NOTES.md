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

**Package boxes are per payload, and the practice payload borrows the small module's.** The two modules
are stocked differently, so one shared list would offer the small module boxes that cannot go in it.
`BoxCatalogue` holds one list per `StudyBox` and `StudyStore.catalogueOwner` decides which applies —
`.small` while practising, since the practice payload is the same size and stands in for it.
`PackingStore.setPayload` is called when the measuring screen appears, which is also what picks up an
edit made on the setup screen: both write to the same saved list rather than keeping a copy each.

The defaults are saved under `packing.boxes.v2.<payload>`. The generation in that key matters — an
earlier build kept one shared list of fourteen boxes under `packing.boxPresets`, and reusing the old key
would have restored those on upgrade instead of the sets the study actually uses.

**The drawn box's height follows the current fit; its footprint does not.** Both used to be seeded from
the first frame of a measurement and then refreshed only from a matching view — the footprint while
`classifyView` said `.topDown`, the height while it said `.side`. Hovering over an object is `.topDown`
or the gap between the two, so the height kept whatever the first frame guessed while the point cloud
filled in and settled underneath it, and the top of the box was left hanging above the dots.

The height is now updated every frame, through the same deadband, and the gating is kept for the
footprint alone. The asymmetry is the point: the height is the highest reading above the support plane,
and how high a point is does not depend on where it was seen from, whereas a footprint measured from an
oblique view genuinely is foreshortened. The coverage counters and the observations fed to the stopping
rule were left inside the view cases, so what the app asks of the operator is unchanged.

`BoundingBoxHeightTests` pins what the height means — top on the highest reading, bottom on the support
plane — so the drawn box has something to be held to. The fitter was never at fault here, and an
earlier attempt to explain this as the footprint spreading across the tabletop was wrong: it added a
clearance nothing in either paper calls for, and has been removed.

**The measurement renderer is removed for the whole packing workflow.** Pausing its `ARSession` was
not sufficient: the old `ARView` and camera texture remained underneath the room view. `ContentView`
now unmounts measurement while packing is presented, and both modes lease the one persistent renderer
from `SharedARViewHost`. Dismantling measurement also stops its timers/display link, cancels frame work,
removes coaching and scene content, and releases its lease before packing can acquire it.

**How long a measurement takes is set by where the phone has been, not by the object.** In Full 3D,
`viewGatedBox` records width and depth *only* while `classifyView` says `.topDown`, and height *only*
while it says `.side`. The stopping rule needs 24 samples on each of the three axes, so a measurement
cannot finish until the phone has spent enough time in both poses, and the same object measured along
a different path can take several times longer. Two consequences worth knowing:

- `classifyView` leaves a dead band. It is `.topDown` below −0.55 of forward Y (steeper than about
  33° down) and `.side` within 0.4 (about 24° of horizontal), so a tilt between roughly 24° and 33°
  down — a very natural way to hold a phone over a table — is `.other`, and `.other` records nothing
  for any axis. Time spent there is simply lost. Closing the gap would be a one-line change, but the
  gap is what keeps a tilted view from contributing a perspective-biased height, so it should not be
  closed without measuring the effect on accuracy first.
- The 2.5 s evidence-exhausted exit cannot rescue a starved axis. It fires when *no* observation has
  arrived recently, and holding a top-down view keeps width and depth arriving, so height can starve
  indefinitely while the rule still considers itself fed.

The HUD's job is therefore to say which pose is missing. `MeasurementConvergence` already reports
`.needsTopView` / `.needsSideView`, and the progress ring shows that text — it must not be reduced to
"hold steady", which is what it said when the ring was first written and is why a stalled measurement
looked like a slow one.

**The accuracy test compares sorted side lengths, not axes.** A reading and its reference are both
sorted largest first before being compared. The app cannot know which side the operator thought of as
the width, and it can come out differently from one round to the next depending on how the object was
approached, so pairing raw axes would report a rotation as an error. Sorted comparison measures what
is being asked — whether the three side lengths are right. The raw triple is stored as recorded, so
this can be redone differently later.

**The accuracy test has its own session and engine, and throws each object away.** It does not go
through `MesOverlayView`: that view is already at the body-type-complexity ceiling, and the test needs
none of the naming, boxing or packing around it. Each reading finalises the object, reads its size and
then removes it, so the scene never accumulates and the tenth reading is as quick as the first.
`AccuracyStore` is owned by `ContentView` rather than the setup screen, so a test survives that screen
being rebuilt and can be left and resumed — the only removal anywhere in the app is
`undoLastReading`, deliberately limited to the reading just taken.

**Reset and "this payload is done" are two different closures, deliberately.** `MesOverlayView` takes
both `onFullReset` and `onPayloadFinished`. They were one closure, which meant the Reset button
advanced the study to the next box — and once the practice payload existed, it also let a participant
leave practice and start the recorded study without the operator's password. Reset now clears the
measurements and starts the *same* payload again. The only way forward is the button inside the
loading plan, behind `StudyStore.nextBoxPassword`.

**The practice payload is not recorded, and that is enforced in one place.** `StudyStore.currentBox`
returns nil while `isPractice`, and every write path — `endCurrentPhase`, `recordCurrentBox`,
`storePhoto` — resolves the box before writing anything, so they all become no-ops on their own. No
box result is created until the practice ends, so the first box's `startedAt` is when the study really
began. The run's report carries a `Practice` line, because nothing else records that it happened.

**Each screen clocks its own study phase.** `StudyStore` only starts the measuring phase itself. The
other two are started by the screens that are that phase: `PreparationView`'s preparation stage
starts `.pack`, its arrangement stage starts `.payload`, and in the one-by-one method the package
details sheet starts `.pack` on appear and hands the clock back to `.measure` on dismiss. Starting
`.pack` from the packing sheet's presentation instead — which is what it used to do — could not tell
boxing apart from loading, and nothing started `.payload` at all, so two of the three timings were
always blank in the app and in the report.

**Finished objects keep their point cloud but stop drawing it.** The cyan selection points and the
marker dot are both suppressed once an object is finished: its box is already drawn, so they were
clutter, and the point budget is split evenly between objects, so keeping finished ones made the
object actually being measured sparser with every object saved. The data stays, because a remeasure
merges into it and the marker is how the app knows a saved object is on screen.

**The room view watches its own frame clock but never restarts a merely slow session.** It reads
`session.currentFrame?.timestamp` once a second and shows a clear warning if frames stop. Session
restart is reserved for ARKit's interruption/failure callbacks. The earlier watchdog repeatedly ran
the configuration while frames were delayed, which could itself create camera flicker. Camera
ownership is instead prevented at the source by the shared renderer and lease hand-off.

**Reports are saved through the system's save panel.** `ShareLink` alone was not enough; the ask was
a file on the device. `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` also expose the
app's Documents folder as Files › On My iPhone › PayloadMeasure, so every run can be collected
without the app's help. Neither the app nor the Files folder has any delete path.

**`UIFileSharingEnabled` needs the partial `Info.plist` at the project root**, not a build setting.
Xcode honours only a fixed list of `INFOPLIST_KEY_*` settings and silently drops the rest, so
`INFOPLIST_KEY_UIFileSharingEnabled = YES` built without complaint and produced an app with the key
missing — while `INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace` beside it worked. The target keeps
`GENERATE_INFOPLIST_FILE = YES` and points `INFOPLIST_FILE` at that file, so the generated keys are
merged into it. The file is outside `PayloadMeasure/` because that folder is a synchronised group and
a plist inside it would also be copied into the bundle as a resource. If a plist key ever seems to be
ignored, check the built `PayloadMeasure.app/Info.plist` rather than the build setting.

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
