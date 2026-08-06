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
  `XCODE16_TEMPORARY_CHANGES.md`.

---

# Current Development Status

Current milestone:

✅ Xcode project created

✅ Code signing configured

✅ App runs on physical iPhone

✅ Initial ARView embedded inside SwiftUI

✅ Camera permission (`NSCameraUsageDescription`) configured via build settings (`INFOPLIST_KEY_NSCameraUsageDescription`).

✅ The operator-facing app is scan-only. The former Line/Box mode picker and manual controls are no
longer exposed, and the measurement mode is fixed to Scan.

✅ LiDAR depth-based automatic Scan workflow implemented with live multi-frame accumulation.

✅ Scan is the sole workflow and reports unsupported hardware explicitly on non-LiDAR devices.

✅ Live RGB foreground-instance mask preview runs in Scan mode on both LiDAR and non-LiDAR devices.

✅ RGB masks use independent AR world anchors plus global appearance/geometry reassignment on
both LiDAR and non-LiDAR devices. Up to 15 targets retain distinct colors and identities.

✅ The active production path uses Apple's native foreground-instance mask from the exact camera
frame. Between results, its display overlay follows the current projected AR anchor and camera
distance; the experimental EdgeTAM and dense optical-flow paths remain bypassed.

✅ On LiDAR hardware, automatic box geometry is fitted only from depth pixels admitted by the
time-synchronized object mask. Unmasked depth is restricted to support-plane height estimation.

✅ The center aimer previews the next object in its future lock color. Tapping selects that object;
its mask remains visible while measuring and disappears immediately when finalized, while its world
anchor, marker and same-colored 3D box remain.

✅ The live aimer and selected-object mask previews can be hidden without stopping segmentation.
Finalized masks are purged and late asynchronous frames cannot restore them.

✅ A display-only Visuals menu independently controls the live/selected mask, lock markers, LiDAR
object points, reconstructed mesh and 3D boxes.

✅ Mask-gated LiDAR uses direct registered-image coordinates, a conservative two-depth-pixel mask
interior and depth-edge rejection. One-centimetre object voxels, temporal voxel expiry, dominant
support-plane estimation and bounded box refinements reduce table leakage and box growth.

✅ Cyan points are final-box inliers only. Direct bottom controls toggle masks, points and boxes,
and the diagnostics panel reports the device's actual ARKit depth-map resolution at runtime.

✅ Multi-object memory is bounded: source-aligned Vision masks are consumed sequentially, while
one-table voxel accumulators, per-object caps and a bounded debug-entity pool replace simultaneous
full-resolution masks and unbounded scene data.

✅ LiDAR frames are back-projected for the active object. Each object owns independent synchronized
mask points, support/table samples and an oriented 3D box retained after finalization.

✅ Non-LiDAR Scan mode is explicitly marked with a tappable limitations badge. RGB masking remains
available, while the sheet explains the absence of metric depth, automatic boxes and 3D table removal.

✅ Environment readiness is reported at runtime: LiDAR devices wait for depth/mesh data, while
non-LiDAR devices guide the operator until camera-based plane mapping is stable.

✅ The functional app targets iOS 26.5. Native Liquid Glass styling and the Xcode 26 concurrency
configuration are restored without changing the segmentation, tracking, LiDAR measurement or box-fitting algorithms.

✅ AR-session lifecycle guards prevent selections before tracking, depth and layout are ready; stale
asynchronous frame results are discarded across interruption, failure and view recreation.

✅ Camera authorization is resolved before starting AR. A first-start session failure gets one safe
automatic recovery attempt before any measurement exists.

✅ Object selection waits for a real-frame recognition warmup. Transient Vision failures no longer
consume valid no-match retries, and a new selection is acknowledged before depth back-projection.

✅ Box fitting runs away from the main UI actor with the same inputs and algorithm. Optional cyan
debug rendering is capped at 600 displayed samples, and 3D box edges use a 3 mm thickness.

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

✅ The retained experimental EdgeTAM adapter and model packages are excluded from the app target so
they remain available for future research without being compiled or shipped in the production app.

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

# Expected Project Structure

PayloadMeasure/
- payloadmeasureapp.swift
- contentview.swift
- arcameraview.swift
- arsessionmanager.swift
- mesengine.swift
- mesmode.swift
- mesoverlayview.swift
- mespoint.swift
- objectcapture.swift
- objectcaptureengine.swift
- objectmaskprocessor.swift
- PayloadMeasurement.swift
- CompatibilityChecker.swift
- ExportManager.swift

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
