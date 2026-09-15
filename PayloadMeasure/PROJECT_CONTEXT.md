# PROJECT_CONTEXT.md

# PayloadMeasure – Master's Thesis Context

## Overview

This repository contains the implementation of the research prototype developed as part of my Master's thesis.

**Thesis title**

> Using Computer Vision for Guiding Payload Distribution in Modular Drone Delivery Systems

The application is an iOS AR application intended to assist an operator during the **payload assessment and preparation** stage before a modular delivery drone is assembled and configured.

The project is a research prototype, not a commercial application.

---

# Research Background

The modular drone platform already supports AR-assisted drone reconfiguration. My contribution is the preceding workflow:

1. Assess the payload.
2. Measure the payload.
3. Estimate relevant properties.
4. Check compatibility with the modular drone platform.
5. Guide the operator during payload preparation.

The app should therefore act as an intelligent measurement and decision-support tool.

---

# Hardware

## Development machines

- Primary development machine: Apple-silicon M2 Mac with Xcode 26.5.
- The older-macOS/Xcode 16 setup was temporary and is no longer a supported project configuration.

## Target and test devices

- Original target: iPhone 13 Pro with LiDAR Scanner.
- Physical testing includes a LiDAR-capable iPhone; the iPhone 13 Pro remains the compatibility
  target for LiDAR scanning.
- An iPhone 15 Plus without LiDAR remains useful for validating the RGB-only fallback.
- The app must detect LiDAR capabilities at runtime and keep unsupported workflows explicit.
- RGB camera, world tracking, plane detection, and non-depth UI work can be tested on the iPhone 15 Plus.
- Scene depth, reconstructed mesh, and metric automatic object capture still require a LiDAR-capable device.

The simulator should **never** be considered a substitute for testing AR functionality.

---

# Technologies

- Swift
- SwiftUI
- ARKit
- RealityKit
- Vision
- CoreML (optional later)

Avoid Unity unless explicitly requested.

## OS and toolchain compatibility

- The application deployment target is iOS 26.5 and the supported development toolchain is Xcode 26.5.
- The target uses Xcode 26 concurrency defaults while retaining Swift 5 language mode; moving the
  complete AR/Vision pipeline to Swift 6 language mode is a separate migration.
- The HUD uses native iOS 26 Liquid Glass effects and glass button styles.
- LiDAR scene depth and scene reconstruction remain runtime capability checked because the RGB-only
  fallback still needs to explain unavailable metric capture on devices without LiDAR.
- The temporary Xcode 16/iOS 18 compatibility changes and their restoration are recorded in
  the Xcode 16 compatibility record (removed; see git history).

---

# Current Development Status

Current milestone:

✅ Xcode project created

✅ Code signing configured

✅ App runs on physical iPhone

✅ Initial ARView embedded inside SwiftUI

✅ Camera permission (`NSCameraUsageDescription`) configured via build settings (`INFOPLIST_KEY_NSCameraUsageDescription`).

✅ The operator-facing app is scan-only. The former Line/Box measurement workflow has been removed
outright — its mode picker, point placement and rendering are gone, not merely hidden. Information
contains the only selector, between the two automatic methods: Full 3D and Top.

✅ LiDAR depth-based automatic Scan workflow implemented with live multi-frame accumulation.

✅ An independent setup-menu LiDAR snapshot utility displays confidence-filtered points directly
from smoothed scene depth and saves RGB, point-only and combined PDFs from the same AR frame under
`StudyRuns/lidar/`. It does not enable scene reconstruction or plane detection. The GPU-backed live
overlay samples every second depth cell at roughly 8 Hz while PDFs retain every valid sample. Its
stable sub-cell scatter breaks up the depth sensor's raster without inventing samples. Its absolute
depth palette holds violet through 15 cm, traverses the full spectrum from 15–60 cm, and clamps
greater distances to red.

✅ Scan is the sole operator workflow and reports unsupported hardware explicitly on non-LiDAR
devices; its Full 3D and Top measurement methods share selection, naming, weight and saved objects.

✅ Live RGB foreground-instance mask preview runs in Scan mode on both LiDAR and non-LiDAR devices.

✅ RGB masks use independent AR world anchors plus global appearance/geometry reassignment on
both LiDAR and non-LiDAR devices. Up to 15 targets retain distinct colors and identities.

✅ The active production path uses Apple's native foreground-instance mask from the exact camera
frame. Between results, its display overlay follows the current projected AR anchor and camera
distance.

✅ On LiDAR hardware, automatic box geometry is fitted only from depth pixels admitted by the
time-synchronized object mask. Unmasked depth is restricted to support-plane height estimation.

✅ The center aimer previews the next object in its future lock color. Tapping selects that object;
its mask remains visible while measuring and disappears immediately when finalized, while its world
anchor, marker and same-colored 3D box remain.

✅ The live aimer and selected-object mask previews can be hidden without stopping segmentation.
Finalized masks are purged and late asynchronous frames cannot restore them.

✅ A display-only Visuals menu independently controls the live/selected mask, lock markers, LiDAR
object points, reconstructed mesh and 3D boxes.

✅ Mask-gated LiDAR uses direct registered-image coordinates and admits a depth sample only when at
least three of its four immediate depth-grid neighbours are also admitted and depth-continuous.
Five-millimetre object voxels, temporal transient rejection, dominant support-plane estimation and
bounded box refinements reduce table leakage and box growth.

✅ Cyan points are final-box inliers only. Direct bottom controls toggle masks, points and boxes,
and the diagnostics panel reports the device's actual ARKit depth-map resolution at runtime.

✅ Multi-object memory is bounded: source-aligned Vision masks are consumed sequentially, while
one-table voxel accumulators, per-object caps and a bounded debug-entity pool replace simultaneous
full-resolution masks and unbounded scene data.

✅ LiDAR frames are back-projected for the active object. Each object owns independent synchronized
mask points, support/table samples and an oriented 3D box retained after finalization.

✅ Non-LiDAR Scan mode is explicitly marked with a tappable limitations badge. RGB masking remains
available, while the sheet explains the absence of metric depth, automatic boxes and 3D table removal.

✅ Environment readiness is reported at runtime: all devices require normal tracking and a current
horizontal floor/table support plane; LiDAR workflows additionally wait for scene depth.

✅ Height baselines retain the selected horizontal `ARPlaneAnchor` identifier, validate its detailed
geometry around the object's footprint, and attach box presentation to that exact support. Plane
updates therefore keep the bottom face flush; Lock performs a final exact support snap, and a merged
or removed plane is reacquired for active and finalized boxes. Lock is enabled only when plane
geometry covers the active object's own footprint, and removed anchors fall back coherently to the
retained object anchor while the app waits for ARKit's replacement plane. Active measurement
evidence is restarted after that frame change.

✅ The functional app targets iOS 26.5. Native Liquid Glass styling and the Xcode 26 concurrency
configuration are restored without changing the segmentation, tracking, LiDAR measurement or box-fitting algorithms.

✅ AR-session lifecycle guards prevent selections before tracking, depth and layout are ready; stale
asynchronous frame results are discarded across interruption, failure and view recreation.

✅ Camera authorization is resolved before starting AR. A first-start session failure gets one safe
automatic recovery attempt before any measurement exists.

✅ Object selection waits for a real-frame recognition warmup. Transient Vision failures no longer
consume valid no-match retries, and a new selection is acknowledged before depth back-projection.

✅ Box fitting runs away from the main UI actor. Full 3D retains the established PCA/view-gated
algorithm; Top uses its separate convex-hull orientation algorithm. Optional cyan debug rendering is
capped at 600 displayed samples, and 3D box edges use a 3 mm thickness.

✅ Top follows the supplied Liu–Liu–Zhang IV 2020 method: uniform downsampling to `Nmax = 100`,
Graham-scan hull with approximate-collinearity `τ = 0.01`, every hull-point pair as a candidate yaw,
and the cited Zhang points-to-edges closeness score. The score is maximized as defined by the cited
primary paper; its `d0` floor is the app's 5 mm voxel size because neither paper specifies a value.

✅ Top measurements are built from gravity-aligned AR world points rather than the perspective camera
image. Collection enters at 12° from straight down and exits at 18° to avoid threshold flicker. The
2D paper fit supplies length/width; height is the maximum selected 3D point above the stable support.

✅ First-run tracking is hardened: failed support warmup is not marked as a completed fit, invalid
fit work is rejected by lifecycle/support guards, newer point snapshots follow immediately,
support-height candidates are median/deadband stabilized, and center/yaw presentation has bounded
temporal stabilization.

✅ Each measured box is rendered under its own exact AR anchor in anchor-local coordinates. Once
Lock is pressed, its last canonical local geometry remains attached to that anchor and cannot be
repainted from newer raw fit data. Published geometry keeps its matching anchor pose; Unlock and
material active-anchor corrections rebase the box and reacquire evidence rather than mixing world
frames. Lock is unavailable while camera tracking is not normal.

✅ The persisted Full 3D/Top selector exists only inside Information. Switching while measurement
state exists requires destructive confirmation and clears the incompatible scan state. Top has one
compact red/green overhead-alignment card instead of sharing space with the Full 3D face guide.

✅ The top HUD shows exactly one compact contextual card at a time. Opening Information replaces the
other top cards instead of squeezing or stacking beside them.

✅ Environment preparation is explicitly red and the ready states are green. Reset is an
always-available labeled neutral-glass control with a red icon and destructive-action confirmation
instead of an ambiguous icon-only arrow.

✅ Live LiDAR readiness follows the pipeline's real prerequisites: normal AR camera tracking plus a
received scene-depth frame. `worldMappingStatus` remains diagnostic and no longer blocks measurement;
Apple's automatic tracking coach supplies standard initialization and limited-tracking guidance.

✅ Bottom actions have their own row above the visualization toolbar and use high-contrast neutral
glass. Lock is the larger primary action while Reset is narrower but retains a 44-point tap target.
At Accessibility text sizes, saved objects move to their own row so the actions cannot collide.

✅ Lock is transactional: tapping it immediately pauses mask, depth accumulation, automatic cleanup
and box fitting at the displayed dimensions. Save finalizes that snapshot; Cancel resumes the same
active object without discarding its accumulated measurement.

✅ Every finalized box stores an operator-entered name and weight. A compact saved-object count opens
a scrollable inline panel above the controls; full-width rows select the focused result and expose
direct Edit and Remove actions without nested system menus.

✅ Mask-based point cleanup is an automatic part of the active scan loop. The former manual Enhance
button and request/feedback plumbing have been removed. Cleanup uses rotating bounded batches so it
cannot synchronously inspect the complete maximum-size object cloud in one UI frame.

✅ Recognition readiness now includes a real-frame warmup of the same exhaustive mask-candidate path
used by the first selection tap, avoiding first-use Vision/Core Image cache work during interaction.

✅ Selection-point buffers and a pool of shared-mesh box-edge entities are prepared in small idle-time
batches before the first fit, avoiding a burst of first-box renderer allocation on the main actor.

✅ The experimental EdgeTAM adapter and its Core ML packages have been removed. They were excluded
from the app target and never compiled or shipped; the approach is still recorded under the
deferred tracking upgrade below.

✅ Payload arrangement is implemented in `Packing/`. After measuring, the operator opens Arrange
payload from the saved-objects panel and gets a load-balanced placement for every measured package
inside the 20 × 80 × 10 cm payload module: a to-scale plan and side elevation, the resulting centre
of mass against its target, and a numbered loading order. See `Packing/NOTES.md` and `Packing/METHODS.md`.

✅ The arrangement follows Kaluzny & Shaw (2009) with the project chapter's adaptations: axis-aligned
three-dimensional orientations selected by the optimiser, the module height limit, a weighted
three-axis centre-of-mass objective and envelope, and the empty module and airframe masses folded
into the centre of mass of the complete connected aircraft. Position, orientation and every pairwise
relative placement are decided simultaneously as one mixed-integer linear program; nothing is placed
sequentially and nothing is repositioned afterwards. Two modules, the choice of module connection
and stacking with load-bearing constraints remain outside the model.

✅ A second arrangement formulation is implemented in `Packing/Baldi/` as a documented hybrid
heuristic. Baldi, Perboli & Tadei (2012) supply 3BKP-H: package selection, six orthogonal rotations,
Extreme Points, containment, non-overlap and a hard cargo-centre-of-mass domain. Every package has
equal value `p_i = 1`, so the search objective is loaded-package count, and package centres of mass
are assumed to be at their geometric centres, as in Baldi's benchmark instances. Junqueira,
Morabito & Yamashita's (2012) area-based vertical-support principle is evaluated directly on the
continuous placements with `alpha = 1`, requiring complete bottom-face support for every non-floor
package. The app computes both a Paper mode, which stops COM movement at first valid balance as
Baldi §5.2 states, and a disclosed Centred mode, which uses cargo-COM proximity only between
equal-count feasible candidates and never changes the cardinality objective.

✅ The production Baldi–Junqueira path is heuristic-only. Every Extreme Point insertion and every
centre-of-mass movement preserves full support, and an independent final verifier recomputes
containment, rotations, non-overlap, loaded/unloaded membership, support and cargo COM before a
result is exposed. It returns the highest-cardinality verified feasible packing found within the
search time; global optimality is not claimed, and failure to find a packing is not reported as a
proof of infeasibility. `Knapsack/KnapsackReferenceModel.swift` remains a clearly labelled reference for
equations (5)–(20), including the documented Eq. (10) and Eq. (16) corrections. It contains no
Junqueira support constraint and is not a production hybrid solver. See
`Packing/NOTES.md` (code) and `Packing/METHODS.md` (sources, deviations and scope).

✅ The support-aware result screen is an operator loading guide rather than an algorithm report. A
top comparison control switches between the two precomputed packings. It presents a tappable 3D
load followed by bottom-to-top coloured floor plans; package names stay out of the drawings until a
package is selected. The same opening-edge marker appears in 2D and 3D, with the measured package
length defined parallel to that marker so the operator can match the physical orientation.

✅ Opening the arrangement workflow suspends measurement, stops its frame-driven mask, projection,
fitting and display loops, and removes its `ARView` from the hierarchy. Measurement and room-scale
packing lease one persistent `ARView`/`ARSession` rather than competing through separate camera
renderers. Packing changes to a lightweight configuration without resetting the coordinate frame;
dismissal therefore resumes the same payload world and does not erase measured packages. A real
payload transition requests exactly one tracking reset. Scene inactivity and packing presentation
remain independent suspension reasons.

✅ The separate floor-only mixed-integer program uses a self-contained exact solver: a
bounded-variable primal and dual simplex with refactorisation and a Harris ratio test, driven by a
warm-started depth-first branch and bound. No third-party solver is linked. A result is only called
optimal when the search proved it; otherwise the arrangement is reported with its true optimality
gap, and an independent geometric check re-derives containment, clearances and the centre of mass
from the reported placement alone.

---

# Long-Term Roadmap

## Phase 1 — Foundation

- Launch AR camera
- Start AR session
- Plane detection
- Scene depth
- Verify LiDAR

## Phase 2 — Manual Measurement

- Tap 3D points
- Compute distances
- Measure box dimensions
- Display dimensions

## Phase 3 — Assisted Measurement

- Automatic box detection
- Corner refinement
- Measurement confidence
- Export results

## Phase 4 — Payload Intelligence

Estimate:

- Length
- Width
- Height
- Volume
- Weight (estimated or entered)
- Center of mass (future)

Evaluate:

- Platform compatibility
- Arrangement possibilities
- Payload constraints

## Deferred Tracking Upgrade

After the presentation-safe native Vision version is validated, evaluate replacing foreground-mask
selection with pretrained promptable video segmentation. The leading option is EdgeTAM exported to
Core ML: tap prompts select arbitrary objects, one image encoding is shared across locks, and AR
anchor reprojection plus temporal mask state supports reacquisition. Keep synchronized mask-gated
LiDAR points for metric capture. EfficientTAM is a secondary candidate if its iOS deployment path
matures; fixed-class YOLO segmentation is appropriate only with a payload-specific training set.

---

# Software Design Principles

- Build incrementally.
- Keep every commit runnable.
- Prefer readability over abstraction.
- Explain every architectural decision.
- Minimize dependencies.
- Test on the physical iPhone after every milestone.

---

# Project Structure

```
PayloadMeasure/
  PayloadMeasureApp.swift
  ContentView.swift
  MeasurementOverlayView.swift
  NOTES.md                      how the measurement side works
  PROJECT_CONTEXT.md            this file
  AR/         ARCameraView, ARSessionManager, AimerState
  Capture/    ObjectMaskProcessor, ObjectCapture, ObjectCaptureEngine
  Measurement/  MeasurementWorkflowMode, MeasurementConvergence
  Packing/    preparation, and the two arrangement methods (own NOTES.md and METHODS.md)
  Utilities/  PositiveDecimalText
```

The whole folder is a synchronised Xcode group, so new files need no project-file edit.


---

# Coding Guidelines for AI

When modifying the project:

- Read this document first.
- Make the smallest reasonable change.
- Keep the project compiling.
- Explain why each change is necessary.
- Do not perform unnecessary refactoring.
- Prefer native Apple APIs.
- Ask before introducing new frameworks.

When implementing features:

1. First explain the approach.
2. Then implement.
3. Keep code modular.
4. Add comments only where they improve understanding.

---

# Role of the AI Assistant

Act as a senior iOS + ARKit engineer.

Priorities:

1. Correctness
2. Simplicity
3. Maintainability
4. Research quality
5. Measurement accuracy

The objective is not simply to build an app, but to produce a research-quality prototype suitable for inclusion in a Master's thesis.

Always keep the research objective in mind when proposing implementations.
