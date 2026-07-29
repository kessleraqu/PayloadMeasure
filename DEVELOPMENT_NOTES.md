# DEVELOPMENT_NOTES.md

# PayloadMeasure Development Notes

This file records implementation changes in plain language so the research prototype remains explainable and easy to document later.

---

## Standing Development Instructions

These instructions should guide every future implementation step.

### Code quality

- Keep the code organized by responsibility, not by convenience.
- Prefer small Swift files with clear roles over large mixed-purpose files.
- Keep SwiftUI views focused on presentation and composition.
- Keep ARKit and RealityKit interaction logic outside the main SwiftUI view where practical.
- Avoid unnecessary dependencies and prefer native Apple frameworks.
- Do not add abstractions unless they make the code easier to reason about or prepare for a known next milestone.

### Research prototype quality

- Favor correctness, explainability, and repeatability over quick visual demos.
- Keep each milestone runnable on the physical iPhone.
- Record what changed, why it changed, and what limitations remain.
- Treat measurement accuracy as a research concern: document assumptions and avoid claiming more precision than the current method supports.

### AR measurement strategy

- Use ARKit raycasting for converting screen taps into 3D world positions.
- Prefer LiDAR-supported scene understanding when available because reconstructed meshes can improve placement on real surfaces.
- Keep the first measurement workflow manual and inspectable before adding automatic detection.
- Future accuracy improvements may include tracked raycasts, repeated sampling, scene-depth validation, corner refinement, plane/mesh fitting, and confidence scoring.

### Performance

- Enable only ARKit features that support the current milestone.
- Be careful with scene reconstruction, depth processing, and per-frame work because they can increase power and compute cost.
- Keep expensive analysis out of SwiftUI body rendering.

---

## 2026-06-29 - AR Foundation Status Layer

### Goal

Make the initial AR camera screen more reliable and informative before implementing measurement logic.

### What changed

- Added `ARSessionManager.swift`.
- Added `ARCameraView.swift`.
- Added `MeasurementOverlayView.swift`.
- Simplified `ContentView.swift` so it only composes the AR camera and overlay.

### How it works

`ARCameraView` is the SwiftUI bridge to RealityKit's `ARView`. It disables RealityKit's automatic AR session configuration so the app can explicitly control the ARKit setup.

`ARSessionManager` creates and runs an `ARWorldTrackingConfiguration` with horizontal and vertical plane detection enabled. If the device supports ARKit scene depth, it enables `.sceneDepth`. On the iPhone 13 Pro this should use the LiDAR-backed depth capability.

`ARSessionManager` also acts as the `ARSessionDelegate`. It listens for tracking state changes, plane anchors, interruptions, and failures. Those callbacks update simple state values used by the SwiftUI overlay.

`MeasurementOverlayView` displays:

- Current tracking status.
- Scene depth availability.
- Plane detection progress.

### Why this was necessary

Before measuring payload dimensions, the app needs to know whether AR tracking is stable, whether depth is available, and whether useful planes are being detected. This gives the operator feedback and gives the project a cleaner foundation for manual measurement.

### Current limitations

- Plane detection status only reports whether ARKit has detected horizontal or vertical plane anchors. It does not visualize planes yet.
- Scene depth is enabled when supported, but the app does not inspect depth pixels yet.
- No measurement points or distance calculations have been implemented yet.

### Validation

The project should be built in Xcode after this change and tested on the physical iPhone. The simulator is not a valid AR test environment for this milestone.

---

## 2026-06-29 - Manual Two-Point Measurement

### Goal

Add the first real measurement capability: tap two points in the AR view and display the distance between them.

### What changed

- Added `MeasurementPoint.swift`.
- Added `MeasurementEngine.swift`.
- Updated `ARCameraView.swift` with tap handling, AR raycasting, and RealityKit marker placement.
- Updated `MeasurementOverlayView.swift` to show measurement state, distance, and a reset button.
- Updated `ContentView.swift` to own and pass both the AR session manager and measurement engine.
- Updated `ARSessionManager.swift` to enable LiDAR scene reconstruction mesh support when available.

### How it works

When the user taps the camera view, `ARCameraView.Coordinator` receives the tap through `UITapGestureRecognizer`. It asks `ARView` to perform an ARKit raycast from that 2D screen point into the tracked 3D world.

The raycast uses `.estimatedPlane` with `.any` alignment. Apple documents this as the appropriate approach for locating points on reconstructed scene surfaces, especially when scene reconstruction is enabled on LiDAR devices. If no estimated surface is found, the code falls back to `.existingPlaneGeometry`.

When ARKit returns a raycast result, the app extracts the result's world-space translation and sends it to `MeasurementEngine`. The engine stores up to two `MeasurementPoint` values and computes the Euclidean distance between them with `simd_distance`.

RealityKit places a small sphere marker at each accepted point. Point A is green and point B is blue. The overlay displays the measurement status and distance in centimeters.

### Why this design

The design keeps responsibilities separate:

- `MeasurementEngine` owns measurement state and distance calculation.
- `MeasurementPoint` represents a measured world-space point.
- `ARCameraView` handles UIKit gestures, AR raycasts, and RealityKit marker rendering.
- `MeasurementOverlayView` displays state and controls reset.
- `ARSessionManager` owns ARKit session configuration and tracking status.

This organization keeps the current feature simple while leaving room for research-quality improvements later.

### Accuracy notes

The current distance is based on ARKit's estimated world positions at the tapped pixels. It is useful as a first manual prototype, but it should not yet be treated as a validated measurement instrument.

Accuracy depends on:

- Stable AR tracking.
- Good lighting.
- Textured surfaces.
- Correct tap placement by the operator.
- Quality of LiDAR mesh or ARKit surface estimation.
- Distance from the camera to the measured object.

Future accuracy work should compare app measurements against known physical dimensions and record error in centimeters and percentage.

### Apple API rationale

Apple's ARKit documentation recommends raycasting for finding real-world 3D positions from screen points. Apple also documents that LiDAR scene reconstruction creates a polygonal mesh of the environment and can improve locating points on real-world surfaces. This implementation uses those native capabilities instead of custom computer vision at this early stage.

Relevant Apple documentation:

- ARKit raycasting: https://developer.apple.com/documentation/arkit/environmental-analysis#Raycasting
- Scene reconstruction: https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/scenereconstruction
- Reconstructed scene interaction: https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene

### Current limitations

- Only one distance measurement is supported at a time.
- Markers are simple spheres; there is no line drawn between them yet.
- Points are not refined over time after placement.
- The app does not yet sample raw or smoothed scene depth at the tapped pixel.
- The app does not yet estimate length, width, height, or volume.

### Validation

Build the project in Xcode and test on the physical iPhone. Confirm this workflow:

1. Start the app and wait for `Tracking ready`.
2. Tap a real-world surface or payload point.
3. Confirm a green marker appears.
4. Tap a second point.
5. Confirm a blue marker appears and the overlay displays a centimeter distance.
6. Tap `Reset Measurement` and confirm both markers disappear.
---

## 2026-06-29 - Measurement Stability and Refinement Pass

### Goal

Improve the stability and inspectability of manual two-point measurements after early physical testing showed visible marker drift and measurement error.

### Observed issue

A known object measured at 179 cm was reported as about 173 cm. That is an error of about 6 cm, or about 3.4%. The markers also appeared to shift slightly when the phone moved or tilted.

### What changed

- Updated `MeasurementPoint.swift` so point positions can be refined after initial placement.
- Updated `MeasurementEngine.swift` so it can update point positions, mark points as refining or locked, and reject placement when tracking is not ready.
- Updated `ARSessionManager.swift` with an `isTrackingReady` helper.
- Updated `ARCameraView.swift` to use ARKit tracked raycasts for brief point refinement after each tap.
- Added a yellow RealityKit line between the two measured points.
- Added cleanup for active tracked raycasts during reset and teardown.

### How it works

The first tap still performs an immediate ARKit raycast so the app can place a marker without delay. After that, the app starts an `ARTrackedRaycast` at the same screen location. ARKit repeats that raycast while it improves its understanding of the surface. During this short refinement window, the marker and stored measurement point are updated together.

After about 1.5 seconds, the app stops the tracked raycast with `stopTracking()` and marks the point as locked. This avoids running indefinite tracked raycasts and avoids markers sliding forever as ARKit continues to refine the world.

When two points exist, the app draws a thin yellow line between them. This makes the measured segment visible, which is important for debugging tap placement and explaining the measurement process.

### Why this design

Apple recommends tracked raycasts when virtual content should update as ARKit refines its surface estimate. This is a good fit for measurement points because a one-time tap can land on an early, less accurate surface estimate. The app now uses a bounded refinement period so it gains the benefit of ARKit updates without leaving unbounded background work running.

The app also blocks point placement unless AR tracking is normal. This prevents collecting measurement points during initialization, relocalization, or limited tracking states.

### Accuracy notes

This improves stability, but it does not make the app a calibrated measuring instrument yet. Remaining error can still come from endpoint tap accuracy, viewing angle, surface quality, lighting, LiDAR/depth noise, world tracking drift, and the physical distance from the phone to the measured object.

The next accuracy milestone should be a validation workflow: measure known objects repeatedly, record app result versus ground truth, and compute error in centimeters and percent.

### Current limitations

- Refinement uses a fixed 1.5 second window rather than a confidence-based stop condition.
- The app does not yet sample smoothed scene depth at the tapped pixel.
- The app does not yet provide zoom/crosshair targeting for precise endpoint selection.
- The app does not yet support multiple repeated trials or error logging.

### Validation

Build the project in Xcode and test on the physical iPhone. Confirm this workflow:

1. Wait for `Tracking ready`.
2. Tap point A and hold the phone steady while the overlay says it is refining.
3. Confirm point A changes to locked after a short moment.
4. Tap point B and hold steady again.
5. Confirm a yellow line appears between points and the distance updates while refinement is active.
6. Confirm the final distance remains stable after both points lock.
7. Reset and repeat on a known physical object to compare error.

---

## 2026-06-29 - Marker Rendering Fix and Line Shape Improvement

### Goal

Fix a UI/rendering issue where the measurement line appeared and the distance calculation was correct, but the point markers did not remain visibly locked and the second marker sometimes did not appear.

### Cause

The measurement data was correct. The problem was in the RealityKit rendering path. The previous implementation placed each point inside its own `AnchorEntity` and then updated the anchor transform during tracked-raycast refinement. `AnchorEntity` is best treated as an anchoring root, not as the repeatedly mutated visual object. Updating those anchor transforms made marker rendering less reliable even though the stored measurement positions and line calculation were working.

### What changed

- Reworked marker rendering in `ARCameraView.swift`.
- Added one stable world-space `contentAnchor` for all measurement visuals.
- Markers are now `ModelEntity` children positioned inside that stable anchor.
- Refinement updates the marker entity position directly instead of mutating an anchor transform.
- The measurement line is now also a child entity of the same content anchor.
- Replaced the box-shaped yellow line with a thin cylinder so it reads visually as a line instead of a rectangular 3D block.
- Increased marker radius slightly so points are easier to see on device.

### Why this design

Keeping one stable RealityKit anchor and moving child entities gives the renderer a simpler hierarchy. The AR world anchor provides the coordinate space, while marker and line entities represent the measurement geometry. This matches the app's mental model: the measurement is one visual group containing two points and one line.

### Validation

Build and test on the physical iPhone. Confirm this workflow:

1. Wait for `Tracking ready`.
2. Tap point A and confirm the green marker appears.
3. Tap point B and confirm the blue marker appears.
4. Confirm both markers remain visible after refinement locks.
5. Confirm the yellow connector looks like a thin line rather than a box.
6. Confirm reset removes both markers and the line.

---

## 2026-06-29 - UI Polish Pass

### Goal

Improve the visual presentation without changing measurement or AR backend behavior.

### What changed

- Reduced the visual marker sphere radius in `ARCameraView.swift`.
- Slightly reduced the connector line radius so it reads as a thinner line.
- Redesigned `MeasurementOverlayView.swift` as a more iOS-style floating glass panel.
- Added a rounded translucent material background, subtle border, and shadow.
- Added a button to hide or show AR diagnostic details: tracking detail, depth, mesh, and planes.
- Kept the current tracking state visible in the header even when details are collapsed.
- Changed reset into a compact circular icon button.
- Made distance more prominent with rounded, monospaced digits.

### Scope

This was intentionally a UI-only change. Measurement state, AR session configuration, raycasting, refinement, and distance calculation were not changed.

### Validation

Build and test on the physical iPhone. Confirm this workflow:

1. The overlay looks like a compact rounded iOS control surface.
2. The info button hides and shows AR details.
3. Measurement distance and reset remain accessible when details are hidden.
4. Green and blue measurement points are smaller but still visible.
5. The yellow connector line is thinner and less visually bulky.

---

## 2026-06-29 - Targeting UI and Bounding Box Mode

### Goal

Add better targeting support and introduce a selectable bounding-box workflow without replacing the existing line measurement workflow.

### What changed

- Added `TargetingReticleView.swift`.
- Updated `ContentView.swift` to show a small center reticle over the AR camera.
- Added `MeasurementMode.swift` with two modes: `line` and `boundingBox`.
- Updated `MeasurementEngine.swift` to own the active measurement mode and mode-specific display text.
- Updated `MeasurementOverlayView.swift` with a segmented Line / Box picker.
- Updated `ARCameraView.swift` so line mode draws the existing yellow connector and box mode draws a cyan wireframe box.

### How it works

Line mode keeps the previous two-point distance workflow. The user taps point A and point B, and the app draws a line between them.

Bounding-box mode also uses two taps, but interprets them as opposite corners of a world-axis-aligned bounding box. Once two points are placed, the app builds the eight box corners and renders the twelve edges as thin RealityKit cylinders.

Switching between Line and Box resets the current measurement. This keeps the two workflows separate and avoids interpreting old line points as box corners or old box corners as a line.

### Why this design

This is a controlled first step toward object-scale measurement. It keeps the interaction simple and inspectable while preserving the line tool for quick distance checks. A manual bounding box is useful for early thesis work because it can estimate rough object dimensions before automatic object detection exists.

### Current limitations

- The bounding box is aligned to the AR world axes, not automatically aligned to the object.
- The box is created from two opposite tapped points, so user tap accuracy strongly affects dimensions.
- The reticle is now the placement target; taps confirm the centered reticle location instead of using the finger position.
- There is no automatic object segmentation or fitted oriented bounding box yet.

### Validation

Build and test on the physical iPhone. Confirm this workflow:

1. The reticle stays centered and does not block taps.
2. Line mode still places two points and draws a yellow line.
3. Box mode places two points and draws a cyan wireframe box.
4. Switching modes clears the current measurement.
5. The overlay displays distance in Line mode and dimensions/volume in Box mode.

---

## 2026-06-29 - Reticle Placement Fix

### Goal

Fix the mismatch where the reticle suggested center-screen targeting, but measurement points were still placed using the exact finger tap location.

### Cause

`TargetingReticleView` was centered on screen, but `ARCameraView` still called ARKit raycasts with `recognizer.location(in: arView)`. That meant the rendered point and line could appear away from the reticle if the user tapped anywhere except the center.

### What changed

- Updated `ARCameraView.swift` so placement raycasts use the center of the `ARView` bounds.
- Updated tracked-raycast refinement to use the same center target.
- Tapping now acts as a confirmation gesture: aim with the reticle, then tap anywhere to place the point.

### Validation

Build and test on the physical iPhone. Confirm this workflow:

1. Move the phone until the reticle is over the target point.
2. Tap anywhere on screen.
3. Confirm the marker appears at the reticle target, not under the finger.
4. Confirm Line and Box modes both use the reticle target consistently.

---

## 2026-06-29 - Clean HUD, Button Placement, and Dynamic Pointer

### Goal

Clean up the measurement UI and make targeting closer to the Apple Measure interaction model.

### What changed

- Removed the static SwiftUI reticle.
- Added a dynamic RealityKit pointer that raycasts from screen center every frame.
- The pointer sits on the detected surface, uses the raycast orientation, and scales based on camera distance.
- Replaced tap-to-place with an explicit `Add Point` button.
- Added a placement request counter in `MeasurementEngine.swift` so SwiftUI can request AR placement without directly touching ARKit.
- Reworked `MeasurementOverlayView.swift` into a cleaner HUD:
  - One top info button hides or shows the controls/status panel.
  - The measurement value appears separately in the bottom-right corner.
  - The add-point button sits at the bottom center.
- Changed placed points to white.
- Changed measurement lines and bounding-box edges to thinner yellow marks.
- Removed the unused `TargetingReticleView.swift` file.

### How it works

`ARCameraView` subscribes to RealityKit scene updates and performs a center-screen raycast. When a surface is found, the dynamic pointer is moved to that surface, oriented with the raycast transform, and scaled according to distance from the camera.

The SwiftUI `Add Point` button calls `measurementEngine.requestPointPlacement()`. `ARCameraView.updateUIView` observes the placement request revision and places a point at the current center raycast target. This keeps the UI and AR renderer separated while still allowing SwiftUI controls to drive AR actions.

### Why this design

Using a button makes placement intentional and avoids accidental point creation from screen taps. A dynamic AR-space pointer gives better feedback than a fixed 2D reticle because it shows where ARKit currently believes the target surface is.

### Current limitations

- The pointer is a simple RealityKit cross marker, not a full Apple Measure-style animated ring.
- The pointer depends on ARKit raycast quality; it can still jump if ARKit surface estimation changes.
- Bounding boxes are still world-axis-aligned, not object-oriented.

### Validation

Build and test on the physical iPhone. Confirm this workflow:

1. The top UI can collapse to a single info button.
2. The measurement value appears in the bottom-right corner.
3. Pressing `Add Point` places a point at the dynamic pointer.
4. The pointer rotates with the detected surface and changes apparent size with distance.
5. Points appear white and measurement marks appear yellow.
6. Line and Box modes both still work.

---

## 2026-06-29 - Pointer Stabilization and HUD Refinement

### Goal

Reduce visual wobble in the AR pointer and make the HUD cleaner and closer to the Apple Measure style.

### What changed

- Replaced the cross-shaped AR pointer with a single round yellow speck.
- Added smoothing for pointer position, orientation, and scale so it does not tremble as aggressively on small raycast changes.
- Moved the measurement readout to the top-left corner.
- Made the measurement readout smaller and applied SwiftUI Liquid Glass styling.
- Removed the Line / Box control from the hidden info panel.
- Added a compact always-visible Line / Box icon toggle in the bottom-right corner.
- Kept the top-right button as the single control for showing or hiding tracking/status details.

### How it works

`ARCameraView` still raycasts from the center of the screen, but the pointer no longer adopts every raw raycast result directly. It applies a low-pass smoothing step to position, orientation, and scale before updating the RealityKit pointer entity. This keeps the pointer responsive while reducing frame-to-frame jitter.

`MeasurementOverlayView` now separates persistent measurement controls from diagnostic information. The size readout is always visible at top-left, mode selection is always visible at bottom-right, and diagnostic/status information stays behind the top-right info button.

### Current limitations

- Smoothing reduces jitter but also adds a small amount of visual lag.
- The pointer can still jump if ARKit switches to a substantially different surface estimate.
- The pointer is a simple speck, not yet a full animated Apple Measure-style target ring.

### Validation

Build and test on the physical iPhone. Confirm this workflow:

1. The pointer appears as a round yellow speck rather than a cross.
2. The pointer jitters less while the phone is held still.
3. The measurement readout appears in the top-left corner.
4. Line / Box mode selection appears as a compact bottom-right icon toggle.
5. The hidden info panel no longer contains the mode selector.

---

## 2026-06-29 - Apple Measure Style Pass

### Goal

Make the UI language consistent with the compact glass Line / Box toggle, and make the center pointer closer to Apple Measure's surface dot behavior.

### Reference

Apple's Measure app instructions describe aligning the center dot with the point to measure and then tapping the Add button. The target is therefore a centered placement indicator, not a crosshair controlled by direct screen taps.

Relevant references:

- Apple Support: https://support.apple.com/guide/iphone/measure-dimensions-iphd8ac2cfea/ios
- Apple Measure App Store page: https://apps.apple.com/us/app/measure/id1383426740

### What changed

- Replaced the target sphere with a flat rounded RealityKit plane so it reads more like a 2D dot mapped onto the detected surface.
- Increased pointer smoothing responsiveness while keeping a small deadband to suppress tiny raycast tremors.
- Kept the pointer oriented by the ARKit raycast result so it follows the detected surface.
- Applied the same Liquid Glass style language from the Line / Box toggle to the Add Point and Reset controls.
- Preserved the successful compact Line / Box toggle design.

### Why this design

A flat surface marker communicates placement better than a 3D sphere because it appears attached to the detected surface instead of floating in space. The smoothing now responds faster than the previous version to reduce the feeling that the pointer lags behind the camera, while ignoring very small movement changes that usually come from raycast noise.

### Current limitations

- The dot is still generated from a simple RealityKit plane, not an exact replica of Apple's private Measure UI.
- If ARKit changes the underlying detected surface abruptly, the dot can still jump.
- The target does not yet animate into measurement endpoints.

### Validation

Build and test on the physical iPhone. Confirm this workflow:

1. The center target looks like a flat yellow surface dot, not a 3D ball or cross.
2. The target follows camera movement with less lag.
3. Small tremors are reduced when the phone is held still.
4. Add Point, Reset, and Line / Box share the same glass visual language.

---

## 2026-06-29 - Pointer Performance Fix

### Goal

Fix lag introduced by the dynamic AR pointer.

### Cause

The previous pointer implementation subscribed to RealityKit scene updates and performed a center-screen AR raycast every rendered frame. It also created a main-actor task on each frame. That was more work than needed for a small targeting marker and could make the AR camera feel laggy.

### What changed

- Replaced the per-frame RealityKit scene update subscription with a throttled timer.
- The pointer now updates about 15 times per second instead of every rendered frame.
- Kept the same center raycast, surface orientation, scale behavior, and smoothing.
- Removed the now-unneeded Combine import.

### Why this design

The pointer does not need 60 FPS AR raycasting to feel useful. Throttling reduces repeated ARKit raycasts and main-actor scheduling while preserving the visible targeting behavior.

### Validation

Build and test on the physical iPhone. Confirm that camera motion feels smoother and that the pointer still follows detected surfaces acceptably.

---

## 2026-06-29 - Flat Marker and Line Rendering Pass

### Goal

Make the AR measurement visuals feel closer to Apple Measure: responsive, flat, lightweight, and readable without 3D volume.

### What changed

- Updated `ARCameraView.swift`.
- Increased the center marker update rate from about 15 Hz to about 30 Hz.
- Reduced the target smoothing delay so the marker follows the center raycast more quickly.
- Changed the center marker color from yellow to white.
- Replaced placed point spheres with small flat white circular planes.
- Replaced cylinder measurement lines and box edges with thin flat yellow plane strips.
- Kept the measurement engine and AR placement logic unchanged.

### How it works

The center marker still uses a center-screen AR raycast and maps itself onto the detected surface. It is still throttled so the app does not raycast every rendered frame, but the cadence is higher than the previous performance pass.

Placed points now use the raycast transform to orient a flat disk onto the detected surface. The displayed disk is offset by 1 mm along the surface normal to avoid flickering against the real-world surface mesh.

Measurement lines now use flat RealityKit plane meshes instead of cylinders. The stored measurement positions remain exact world-space points; only the rendered representation changed.

### Current limitations

- The flat line strip is a visual aid, not a physical object mesh. Its screen-facing appearance can still vary with viewing angle.
- The pointer still depends on ARKit raycast stability. Bad lighting, low texture, or weak surface estimates can still cause visible movement.
- The app is not yet sampling raw depth around the target point to reject unstable hits.

### Validation

Build and test on the physical iPhone. Confirm that the camera feed stays smooth, the center marker is white and more responsive, and points/lines appear flat without sphere or cylinder volume.

---

## 2026-06-29 - White Billboard Points and Dashed Lines

### Goal

Refine the measurement styling so the visuals read as clean 2D UI markers in AR rather than shaded 3D geometry.

### What changed

- Updated `ARCameraView.swift`.
- Made the center spot fully white instead of slightly transparent white.
- Kept placed points as flat white disks, but changed their orientation so they face the camera instead of inheriting the detected surface angle.
- Changed measurement lines and bounding-box edges from solid yellow strips to dashed white strips.
- Kept the underlying measurement positions and distance calculation unchanged.

### How it works

The point marker still sits at the ARKit raycast position, but its plane orientation is updated toward the camera. This makes the visible point remain a clean circular disk from the operator's view instead of changing shape based on the surface normal.

Dashed lines are built from repeated short flat RealityKit plane segments with gaps between them. The app still stores only the true measured endpoints; the dashed rendering is only a visual representation.

### Current limitations

- The points are now visually screen-facing, so they are intentionally less surface-dependent than the center target.
- The dashed line is still rendered in AR world space, so extreme viewing angles can affect visibility.
- This pass does not change raycast accuracy or point refinement.

### Validation

Build and test on the physical iPhone. Confirm that the center spot and placed points are white, placed points stay visually circular, and the measured line appears as white dash-gap-dash segments.

---

## 2026-06-29 - Screen-Locked Pointer and Ice White AR Materials

### Goal

Fix the remaining pointer lag and make measurement visuals render as bright white instead of grey.

### Cause

The previous visible center pointer was a RealityKit entity placed in world space and updated by a timer. That made it look like it was following the screen center. Even with faster updates, a world-space marker can feel delayed because the camera feed moves continuously while the marker position is recomputed.

The grey appearance came from `SimpleMaterial`. Apple documents `SimpleMaterial` as responding to scene lighting, so a white material can still be shaded by the AR environment.

### What changed

- Updated `MeasurementOverlayView.swift`.
- Added a fixed SwiftUI center reticle that is always locked to the middle of the screen.
- Updated `ARCameraView.swift`.
- Removed the visible world-space center pointer entity and its smoothing state.
- Kept Add Point using an ARKit raycast from the exact center of the `ARView`.
- Kept a lightweight visual timer only for making already placed point and line visuals face the camera.
- Switched placed point and dashed line materials from `SimpleMaterial` to `UnlitMaterial`.

### How it works

The visible pointer is now screen-space UI, so it cannot lag behind the center. The AR placement logic still uses `centerPoint(in:)` and `ARView.raycast(from:allowing:alignment:)` to convert that center pixel into a real-world surface position when Add Point is pressed.

Placed measurement visuals are still RealityKit entities because they must remain anchored in the AR world. They use `UnlitMaterial(color: .white)` so they render as bright UI-like white instead of being darkened by scene lighting.

### Current limitations

- The center reticle is intentionally screen-locked, so it no longer tilts visually with the surface. The surface adaptation happens at placement time through the center raycast.
- Placed points and dashed lines still update their billboard orientation at a fixed cadence, not every camera frame.
- This pass does not change measurement accuracy or endpoint refinement.

### Validation

Build and test on the physical iPhone. Confirm that the center pointer stays fixed in the exact middle of the screen, Add Point still lands on the surface under that center pointer, and placed dots/lines appear brighter white.
---

## 2026-06-29 - Corrected Reticle Surface Behavior

### Goal

Fix the reticle model after testing showed that a purely fixed 2D marker was centered but no longer communicated the surface angle.

### What changed

- Updated `MeasurementEngine.swift` with lightweight reticle surface state.
- Updated `ARCameraView.swift` so it raycasts from the center pixel and publishes only reticle surface scale, rotation, and detection status.
- Updated `MeasurementOverlayView.swift` so the center reticle stays locked to the screen center but visually squashes and rotates based on the detected surface angle.
- Removed continuous reorientation work for all placed dashed line segments from the active update loop.
- Kept placed dots and dashed measurement lines on `UnlitMaterial(color: .white)` so they remain bright white.

### How it works

The center reticle is still SwiftUI, so it cannot lag behind the screen center. The AR layer performs a center raycast and estimates how much the detected surface normal faces the camera. The overlay uses that value to flatten the reticle and uses the normal direction to rotate it.

This gives the intended behavior: the marker is locked to the center as an aiming UI, but it still adapts visually to the surface under the center pixel.

Placed points and dashed lines remain AR world entities. They are not used as the live aiming reticle, and the app no longer loops over every dash segment just to refresh its orientation.

### Current limitations

- The reticle angle is a visual approximation from the raycast transform, not a rendered decal physically attached to the mesh.
- The reticle updates at a throttled cadence to avoid per-frame raycast cost.
- Measurement accuracy and point refinement behavior are unchanged.

### Validation

Build and test on the physical iPhone. Confirm that the reticle remains centered, changes shape/angle over surfaces, the camera feels smoother after a line is placed, and placed points/lines remain bright white.

---

## 2026-06-29 - AR Feed Performance Pass

### Goal

Investigate why the camera feed still felt laggy after the reticle rendering changes and reduce unnecessary work in the active AR session.

### What was likely causing lag

- `ARSessionManager` enabled LiDAR scene depth even though the app is not yet reading depth pixels.
- `ARSessionManager` enabled LiDAR scene reconstruction mesh even though the current visual flow does not render or inspect mesh anchors directly.
- `ARSessionManager` enabled automatic environment texturing even though measurement markers now use unlit UI-style materials.
- `ARCameraView` raycasted the center reticle at 30 Hz and published observable state every tick.
- The previous visual update helper could reorient all dashed measurement segments repeatedly, which scales poorly once a line or box is placed.

Apple's ARKit documentation warns that additional configuration options consume energy and compute cycles. For this milestone, the app needs stable world tracking and center raycasts more than full depth/mesh/environment analysis.

### What changed

- Updated `ARSessionManager.swift`.
- Disabled automatic environment texturing.
- Left scene depth supported but not enabled.
- Left LiDAR scene reconstruction supported but not enabled.
- Updated `ARCameraView.swift`.
- Reduced center reticle raycasting from 30 Hz to 15 Hz.
- Kept only placed point billboarding in the timer, which is at most two markers.
- Removed the active loop over all dashed line segments.
- Updated `MeasurementEngine.swift`.
- Added thresholds so reticle surface state only publishes meaningful changes to SwiftUI.

### Tradeoff

This should make the live camera feed smoother and reduce heat/compute pressure. The tradeoff is that center raycasts no longer benefit from the reconstructed scene mesh. For this stage, that is acceptable because the priority is an interactive baseline. Later accuracy work can re-enable mesh or scene depth behind a deliberate accuracy mode or only during point placement.

### Validation

Build and test on the physical iPhone. Confirm the live camera feed feels smoother before and after placing a line. Also confirm point placement still works on normal textured surfaces.

---

## 2026-06-29 - Accuracy-Oriented Anchored Points

### Goal

Move from prototype point storage toward the most accurate architecture currently practical in the app: LiDAR-assisted raycasts plus real AR anchors for finalized measurement points.

### What changed

- Updated `ARSessionManager.swift`.
- Re-enabled scene depth when the device supports it.
- Re-enabled LiDAR scene reconstruction mesh when the device supports it.
- Kept automatic environment texturing disabled because it affects realistic lighting/reflections, not measurement accuracy.
- Updated `ARCameraView.swift`.
- Each point still starts as an immediate raycast result so the user gets instant feedback.
- Each point still refines briefly with `ARTrackedRaycast`.
- When refinement finishes, the app now creates an `ARAnchor` at the latest refined transform.
- The visible point marker is moved under a RealityKit `AnchorEntity(anchor:)` that uses that `ARAnchor`.
- The app syncs stored measurement positions from the anchored marker's current world transform when ARKit updates it.
- Reset now removes both the RealityKit anchor entity and the underlying ARKit anchor.

### Why this is more accurate

The previous version stored a point mostly as a fixed world coordinate. That is simple, but it does not give ARKit an explicit object to maintain as the world map improves.

The new version tells ARKit: this measured point is a tracked location in the AR session. RealityKit then attaches the visible marker to that AR anchor. If ARKit refines the anchor's relationship to the world, the measurement state can follow the anchored marker's current world position.

Re-enabling LiDAR scene reconstruction also lets center raycasts intersect the reconstructed scene mesh, which can improve placement on surfaces that are not clean detected planes.

### Tradeoff

This version prioritizes accuracy over maximum camera-feed smoothness. Scene depth and mesh reconstruction cost compute. If performance becomes unacceptable again, the next step should not be to remove anchors; it should be to make depth/mesh optional or enable them only during placement/refinement.

### Validation

Build and test on the physical iPhone. Confirm this workflow:

1. Wait for tracking to become ready.
2. Add point A and hold steady until refinement finishes.
3. Add point B and hold steady until refinement finishes.
4. Move and tilt the phone slowly.
5. Confirm the points remain visually attached and the distance remains stable.
6. Compare repeated measurements of a known object against ground truth.
---

## 2026-06-29 - Measurement Controls and Live Preview Line

### Goal

Make the measurement workflow clearer while aiming at the second point.

### What changed

- Updated `MeasurementOverlayView.swift`.
- Moved Reset out of the hidden info panel and into the measurement readout next to the size.
- Kept the center reticle visually bright white.
- Added distance-based scaling to the center reticle.
- Updated `MeasurementEngine.swift`.
- Added reticle distance scale state with thresholding to avoid unnecessary SwiftUI updates.
- Updated `ARCameraView.swift`.
- Stored the current center raycast position as a preview target.
- When one point exists, the app now draws a dashed white preview line from point A to the current center target.
- When point B is added, the preview line is cleared and replaced by the final locked dashed line between the two measured points.
- Placed points, preview line, and final line all use `UnlitMaterial(color: .white)` so they remain ice white rather than scene-lit grey.

### How it works

The first point remains anchored after refinement. While aiming for the second point, the center raycast provides a live target position. `ARCameraView` draws preview dash segments between the first stored point and that live target. This gives the operator immediate feedback about the segment that will be measured before committing the second point.

The preview entities are separate from finalized measurement entities. Reset clears both sets.

### Current limitations

- The preview line is rebuilt as the center target changes, so very long dashed preview lines can still have a rendering cost.
- The final line is still a visual representation between the stored point positions; it is not a physical mesh fitted along the object surface.
- Bounding box mode still uses only two opposite corners and does not yet solve object orientation.

### Validation

Build and test on the physical iPhone. Confirm that Reset appears next to the measurement readout, the reticle grows slightly with distance, point/line visuals remain bright white, and after placing point A a live dashed line follows the center marker until point B is added.

---

## 2026-06-29 - Aimer Terminology and Distance Scaling

### Goal

Remove naming ambiguity between the center aiming dot and the placed measurement dots, and make the center aiming dot resize more clearly with target distance.

### Terminology

- `Aimer`: the dot in the middle of the screen used to aim at a surface before adding a point.
- `Marker`: a placed measurement dot left behind after pressing Add Point.

### What changed

- Updated `MeasurementEngine.swift`.
- Renamed reticle state to aimer state.
- Updated `MeasurementOverlayView.swift`.
- Renamed the center reticle view to `aimer`.
- Updated `ARCameraView.swift`.
- Renamed the reticle update path to the aimer update path.
- Increased the aimer's distance-scaling curve so it changes size more noticeably based on the distance of the surface currently under the center point.

### How it works

`ARCameraView` raycasts from the screen center. The distance from the camera to that raycast result is converted into `aimerDistanceScale`. `MeasurementOverlayView` applies that scale to the screen-locked aimer.

The placed measurement markers are separate AR entities and are not renamed to aimer.

### Validation

Build and test on the physical iPhone. Confirm that the center aimer stays centered and changes size more visibly as it points at closer or farther surfaces.

---

## 2026-06-29 - Aimer Distance Scaling Direction Fix

### Goal

Make the aimer actually appear to track the distance of the surface under it. The plumbing was already in place but the effect was barely visible and ran in the wrong direction.

### Cause

The previous formula in `ARCameraView.updateAimerSurface(in:)` computed `distance * 0.32 + 0.62` and clamped it to `[0.78, 1.65]`. That made the aimer grow with distance, which is the opposite of how a fixed-size mark on the surface would project onto the screen. It also produced a very small visible range across typical aiming distances (0.5 m to 1.5 m only moved the scale from about 0.78 to 1.10).

### What changed

- Updated `ARCameraView.swift`.
- Replaced the additive formula with an inverse-distance formula: `referenceDistance / distance`, with `referenceDistance = 0.7 m` and clamps `[0.55, 1.8]`.
- Guarded against very small distances with a `max(distance, 0.15)` floor to avoid extreme scales when the camera is almost touching a surface.

### How it works

The aimer now behaves like a disc of fixed world size projected onto the screen: closer surfaces enlarge it, farther surfaces shrink it. The publishing path through `MeasurementEngine.updateAimerSurface` and the `.scaleEffect(aimerDistanceScale)` in `MeasurementOverlayView.aimer` were already correct and were not changed.

### Validation

Build and test on the physical iPhone. Confirm that the aimer grows visibly when pointed at near surfaces (e.g. 0.3 m away) and shrinks when pointed at far surfaces (e.g. 2 m away), with smooth transitions in between.

---

## 2026-06-29 - Aimer Tilt, Add Point Reliability, Ice-White Materials

### Goal

Fix three remaining issues observed during physical testing:

1. The aimer's tilt did not always match the angle of the surface under it, while Apple Measure's dot tilts correctly.
2. Pressing Add Point sometimes did nothing for one or two presses before finally placing a point.
3. Placed markers did not look as bright/ice-white as the dashed connector line.

### Cause

1. **Wrong rotation reference frame.** The aimer rotation was computed from the world-space yaw of the surface normal: `atan2(normal.x, normal.z)`. That ignored the camera's orientation, so the visible tilt only happened to line up with the surface when the camera was looking down a world axis. Apple Measure projects the surface tilt into the camera's image plane, not into world space.
2. **Transient raycast failures.** The Add Point handler called `bestRaycastResult(...)` once and gave up on `nil`. ARKit's center raycast can briefly return no result on the exact frame the user taps even when the live aimer (which raycasts at ~15 Hz) is clearly locked onto the surface.
3. **Tone-mapped material.** Both markers and dashed lines already used `UnlitMaterial(color: .white)`, but RealityKit's default post-process tone mapping was darkening the color. Apple's docs recommend `applyPostProcessToneMap: false` for "more accurate colors" with unlit materials.

### What changed

- Updated `ARCameraView.swift`.
- Aimer rotation now projects the surface normal through the inverse camera transform, computes its (x, y) on the image plane, and rotates the aimer so the squish axis aligns with the projected tilt. Camera-space Y is negated because SwiftUI's screen Y points down.
- When `bestRaycastResult` returns `nil` for an Add Point press, the placement now falls back to the most recent successful aimer raycast transform (`lastAimerRaycastTransform`). This is reset to `nil` whenever the aimer also fails to find a surface, so the fallback only kicks in when the operator was visibly aiming at something.
- Marker and dashed-line `UnlitMaterial` calls are replaced by a shared `Coordinator.iceWhiteMaterial` built with `UnlitMaterial(color: .white, applyPostProcessToneMap: false)`. Sharing one static material also avoids reallocating it per dash segment.

### Why this design

- Projecting the normal into camera space is the correct geometric description of "how does the surface appear tilted on screen" — the same reasoning a graphics engine uses for foreshortening. This eliminates the dependence on world-axis alignment.
- The Add Point fallback prefers the live aimer state because that state is what the operator is actually seeing on screen. If the aimer indicator is visible, the user expects a tap to place at the same location, regardless of whether the next raycast frame succeeds.
- `applyPostProcessToneMap: false` is the documented way to render UI-style unlit materials at their true color. Caching the material as a static avoids needless reallocation.

### Current limitations

- The fallback transform can be up to one aimer tick (~66 ms) old, so very fast camera motion between the last aimer update and the Add Point press will use a slightly stale target.
- The rotation guard ignores rotation when the projected normal is shorter than 0.05 (nearly face-on surface). At that angle the ellipse is essentially round, so rotation is not visually meaningful.
- This pass does not change measurement accuracy or the refinement loop.

### Validation

Build and test on the physical iPhone. Confirm this workflow:

1. Aim the phone at a tilted real-world surface (floor seen at an angle, wall seen at an angle, a slanted box face). Confirm the aimer ellipse squishes in the direction the surface tilts away in the image, matching the behavior of Apple's Measure app.
2. With the aimer clearly resting on a surface, press Add Point rapidly several times in different positions. Confirm each press lands a marker without needing multiple taps.
3. Compare a placed marker and the dashed connector line side-by-side. Confirm both appear the same bright ice white, with no perceptible grey tint on the markers.

---

## 2026-06-29 - Direct Engine Observation for Reliable Add Point

### Goal

Fully fix the residual Add Point misses that remained after the raycast fallback was added.

### Cause

The previous design routed Add Point through SwiftUI: pressing the button incremented `placementRequestRevision` on `MeasurementEngine`, and `ARCameraView.updateUIView` read that property to trigger placement. With `@Observable`, SwiftUI only re-renders a view (and therefore only calls `updateUIView` on a wrapped `UIViewRepresentable`) when a property read inside that view's body changes. No view body ever read `placementRequestRevision`, so `updateUIView` only fired when some other observed property happened to change at the same time. That made the button feel unreliable.

### What changed

- Updated `ARCameraView.swift`.
- The `Coordinator` now observes `placementRequestRevision` and `resetRevision` directly using `withObservationTracking`, re-establishing the observation after every fired change.
- The change handler runs on the main actor via `Task { @MainActor in ... }` and routes through a new `handleEngineRevisionChange()` helper.
- `updateUIView` is now intentionally empty.

### Why this design

`withObservationTracking` is the documented Observation API for reacting to `@Observable` changes outside of SwiftUI's view rendering. Using it makes Add Point and Reset deterministic: every revision bump is guaranteed to drive AR placement work, with no dependency on whether SwiftUI decided to re-render a host view.

### Validation

Build and test on the physical iPhone. Confirm this workflow:

1. With the aimer on a textured surface, tap Add Point twenty times in a row, repositioning between taps. Every tap should produce a marker (subject only to the documented `lastAimerRaycastTransform` fallback when the aimer itself is on a surface).
2. Tap Reset, confirm both markers and the line disappear, then place two more points to verify the reset path is still wired up.

---

## 2026-06-29 - LiDAR Mesh Object Capture (Scan Mode)

> Implemented on branch `feature/lidar-mesh-object-capture`. This is the first step toward the
> project's real goal: capture an object's full 3D extent quickly from the LiDAR mesh, building
> toward later multi-object packing optimisation. Manual Line/Box tools are unchanged.

### Goal

Move from manual point-by-point measurement toward automatic object capture. The app already
enabled LiDAR scene reconstruction but never read or visualised the mesh. This milestone surfaces
the mesh and turns it into an automatic oriented bounding box with dimensions and volume.

### What changed

- Added `ObjectCapture.swift`:
  - `CapturedObject` describes an oriented box (dimensions, center, axes, eight corners, volume, sample count).
  - `ObjectBoundingBox.make(from:up:)` builds a gravity-aligned oriented box. The vertical axis is gravity (ARKit world Y); the two horizontal axes come from a 2D PCA of the object's footprint, so the box follows the object's orientation instead of the world axes.
  - `MeshGeometryReader` reads world-space vertices out of `ARMeshAnchor` geometry and isolates an object by support-plane height band plus a horizontal radius.
- Added `ObjectCaptureEngine.swift`: an `@Observable` engine holding scan state (mesh visibility, captured object, status text) and the request/reset revision counters, mirroring `MeasurementEngine`.
- Updated `MeasurementMode.swift`: added a `.scan` mode (viewfinder icon).
- Updated `ARSessionManager`-driven session already enables scene depth and LiDAR mesh; no change needed.
- Updated `ARCameraView.swift`:
  - The coordinator now also observes the capture engine and the active mode via `withObservationTracking`.
  - Scan mode shows the reconstructed mesh through RealityKit's native `.showSceneUnderstanding` debug overlay.
  - Capture reads the current frame's mesh and plane anchors, isolates object vertices around the live aimer raycast, computes the oriented box, and renders it as thin green 3D bars (visible from any angle).
- Updated `ContentView.swift` and `MeasurementOverlayView.swift`: a third Scan toggle, a Capture button, a mesh-visibility toggle, and a capture readout (dimensions, volume in litres, sample count).

### How it works

In Scan mode the operator aims the center reticle at an object resting on a floor or table and
presses Capture. The app finds the highest horizontal plane below the aimed point as the support
surface, gathers mesh vertices within 0.8 m horizontally and between 2 cm and 1.5 m above that
surface, and fits a gravity-aligned oriented bounding box to them. The box and its L×W×H + volume
are displayed; capturing again after moving around the object refines the result.

### Why this design

- Reading the LiDAR mesh directly uses the device's most accurate native 3D sensing, rather than inferring dimensions from a couple of taps.
- Gravity gives a reliable vertical axis for free; PCA only has to solve the horizontal yaw, which is robust and cheap.
- Capture is a one-shot button press, so the heavy vertex scan never runs per frame.

### Current limitations

- Object isolation is geometric (support-plane height band + fixed radius). It does not yet use mesh face classification or clustering, so nearby clutter within the radius can be included.
- The horizontal box uses PCA, not a true minimum-area rectangle; very irregular footprints can be slightly over-sized.
- A horizontal support plane must be detected; capture asks the operator to scan the surface first if none is found.
- Switching out of Scan mode clears the rendered box; the last dimensions remain in the readout until the next capture or reset.

### Validation

Build and test on the physical iPhone. Confirm this workflow:

1. Switch to Scan mode and confirm the reconstructed mesh appears as a wireframe overlay.
2. Toggle the mesh button and confirm the overlay hides/shows.
3. Scan an object on a table from several angles, aim at it, and press Capture.
4. Confirm a green oriented box appears around the object with sensible L×W×H and volume.
5. Move around and capture again; confirm the box updates.
6. Switch to Line/Box mode and confirm the mesh overlay and box disappear and manual tools still work.

### Next steps in this branch before merging

- Render the eight corners and/or a faint footprint to make the box easier to read.
- Improve isolation (mesh classification or connected-component clustering) so the radius is not a hard limit.
- Consider a minimum-area rectangle fit for the horizontal footprint.
- Persist captured objects so multiple payloads can be collected — the input for the later packing-optimisation milestone.

---

## 2026-06-30 - Scan Isolation: Classification + Connected-Component Clustering

### Problem

The first Scan implementation captured a box meters larger than the object. It kept every mesh
vertex within a fixed 0.8 m radius and a height band, then fit a box around all of it — so the
box swallowed the table, walls, and surrounding clutter. A fixed radius is the wrong tool: the
reticle should *seed a segmentation*, not bound a region.

### What changed

- `ARSessionManager.swift`: scene reconstruction now uses `.meshWithClassification` when the device supports it (falling back to `.mesh`), so mesh faces carry floor/wall/ceiling/table labels.
- `ObjectCapture.swift` was reworked around a real segmentation pipeline (`ObjectCapturePipeline`):
  1. **Support-plane removal** — find the highest horizontal plane below the aimed point and drop everything within 2 cm of it. This is essential: without it, the object stays connected to the floor and the whole room clusters together.
  2. **Classification filtering** — `MeshGeometryReader` now reads mesh *faces* and discards those classified as wall/floor/ceiling/window/door before anything else. (Reads handle 2- or 4-byte face indices and skip filtering gracefully when classification is unavailable.)
  3. **Connected-component clustering** (`VoxelCluster`) — the surviving points are placed in a ~4 cm voxel grid; a breadth-first flood fill over 26-connected occupied voxels grows the component containing (or nearest) the reticle. Only that component is kept, so spatially separate clutter is dropped automatically. The fixed radius is now only a loose 2 m compute bound.
  4. The oriented box is fit to the cluster as before.
- `ObjectCaptureEngine.swift`: added a `showsSelectedPoints` toggle.
- `ARCameraView.swift`: capture now calls `ObjectCapturePipeline.capture(...)` and maps its outcome (`noSupport` / `notEnoughMesh` / `success`) to status messages. On success it renders the green box and, when enabled, cyan markers at the selected cluster's voxel centers (shared marker mesh, count-capped) so the operator can see exactly what was captured.
- `MeasurementOverlayView.swift`: added a second scan toggle for the selected-point overlay.

### Why this design

Once the support surface is removed, an object resting on it is a spatially disconnected blob.
Growing a connected component from the aimed voxel is therefore a direct, native, on-device way to
isolate it — no model, no training, and it stays entirely in metric 3D, which is what the later
packing milestone needs. Classification pre-strips the big room surfaces so they can never merge
into the object's component and to cut work.

### Current limitations

- Objects touching a wall rely on classification to separate them; with classification off, contact merges them.
- Two objects touching each other (closer than ~one voxel) cluster as one.
- Mesh reads run synchronously on the main actor for a single button press; very large rooms add a brief hitch. Reading ARKit mesh buffers while the session updates them is a known low-probability race to revisit if it ever surfaces.
- Still PCA for the horizontal footprint (not a minimum-area rectangle).

### Validation

Build and test on the physical iPhone. Confirm this workflow:

1. In Scan mode, sweep the object and its support surface so both are reconstructed.
2. Aim at the object and Capture. Confirm the cyan selected-points overlay covers the object and not the floor/walls, and the green box now hugs the object.
3. Toggle the selected-points button on/off and the mesh button on/off independently.
4. Try an object near (not touching) a wall — confirm the wall is excluded.
5. Reset and re-capture from another angle to confirm stability.

---

## 2026-06-30 - Scan Source Switched to Dense Depth (mesh was too coarse)

### Problem

On a real ~20×10×5 cm object the mesh-based capture produced a box meters in size and showed no
selected points. Two root causes:

1. **The LiDAR scene mesh is too coarse** (faces several cm across). A 5 cm object is fused into the
   tabletop in the reconstruction, so it never forms a separable connected component — clustering
   the mesh cannot isolate it.
2. **Support detection depended on a detected tabletop plane.** When only the floor plane existed,
   the height band reached 1.5 m above the floor and clustered the whole room.

### What changed

The capture now reads the **dense LiDAR depth map** (`ARFrame.sceneDepth`, 256×192 metric depth,
far finer than the mesh) instead of mesh vertices:

- `DepthPointCloud` (new in `ObjectCapture.swift`) back-projects depth pixels to world space using
  the camera intrinsics (scaled to depth resolution) and `frame.camera.transform`, keeping
  confident, in-range samples within a horizontal radius of the reticle.
- `ObjectCapturePipeline.capture` now takes those points and estimates the **support height from
  the points themselves** — a low percentile of the heights near the reticle — so it no longer
  needs ARKit to have detected the tabletop as a plane.
- Isolation (support removal → voxel connected-component clustering seeded at the reticle → oriented
  box) is unchanged, but the voxel size dropped to 2 cm to suit the denser, finer points.
- `ObjectBoundingBox.make` gained a `groundHeight` parameter: the box base is anchored to the
  support height, so dropping the bottom `floorClearance` for isolation no longer shortens the
  reported height.
- `ARSessionManager` reverted to plain `.mesh` (classification was only useful to the old
  mesh-clustering path); the mesh now only feeds the optional wireframe overlay.

### Why this design

LiDAR depth resolves small objects that the reconstructed mesh cannot, and back-projecting it keeps
everything in metric 3D so the existing clustering and oriented-box code apply unchanged. Estimating
the support from the local point heights removes the brittle dependence on plane detection.

### Risks / things to watch

- The depth→world back-projection relies on the camera-space convention `(x, -y, -depth)` with
  intrinsics scaled to the depth map. If the box appears mirrored or offset, this is the first thing
  to check.
- Support estimate assumes the object rests on a surface visible around it; an object on a very small
  pedestal (floor visible within 0.35 m) could pick the floor as support.
- Still PCA for the horizontal footprint; objects flush against a wall are not separated (no
  appearance-based segmentation yet — that would be the Vision-mask step).

### Validation

Build and test on the physical iPhone:

1. Place the ~20×10×5 cm object on a table, Scan mode, aim at it, Capture.
2. Confirm the cyan selected points now cover just the object and the green box matches its real size.
3. Check the reported L×W×H against a tape measure.
4. Toggle mesh and selected-point overlays independently; reset and re-capture from another angle.

---

## 2026-06-30 - Live Preview, Multi-Frame Accumulation, Noise Fixes

### Motivation

On-device the depth capture worked but: (a) the cyan/box only appeared after pressing Capture, with
no live feedback, and (b) accuracy was rough and sometimes offset, because each capture was a single
depth snapshot that only saw the faces pointing at the camera.

### What changed

- **Live preview + multi-frame accumulation.** While in Scan mode, a throttled loop (~3 Hz, off the
  existing 15 Hz aimer timer) back-projects the depth around the reticle each tick and adds it to a
  `PointAccumulator` — a voxel grid that averages the points falling in each voxel. The segmentation
  (support removal → connected-component cluster → oriented box) runs on the accumulated cloud every
  tick, so the green box and cyan selection update live as the operator walks around the object, and
  coverage improves from multiple viewpoints instead of one. `Capture` simply freezes the latest live
  result as the committed object; `Reset` clears the accumulator and resumes live scanning.
- **Noise fixes.**
  - `ARSessionManager` now also enables `.smoothedSceneDepth`, and `DepthPointCloud` prefers the
    smoothed depth map (less frame-to-frame noise).
  - Per-voxel averaging in the accumulator further suppresses noise.
  - `ObjectBoundingBox` extents are now robust: each axis trims the extreme 2% before taking the
    span, so a few stray depth points can no longer stretch the box.
- **Engine/UI.** `ObjectCaptureEngine` gained a `previewObject` (live) distinct from `capturedObject`
  (committed); the readout shows whichever applies with a "Scanning"/"Object captured" headline, and
  Reset is available during live scanning. Rendering reuses shared meshes (unit cube for box edges,
  one marker mesh for selection) and caps live markers, since the visuals are rebuilt each tick.

### Why this design

Accumulating across frames is the real accuracy fix: a single viewpoint can only see ~half the
object, so the box was biased toward the camera. Averaging in world space (ARKit tracks pose) gives
full coverage, and combined with smoothed depth and trimmed extents the box is both stable and
correctly sized. Running the same pipeline continuously is what makes the preview live for free.

### Risks / things to watch

- The live loop rebuilds the box and up to ~500 selection markers ~3×/second; if the feed stutters,
  toggle the selected-points overlay off (or lower the cadence / marker cap).
- The accumulator is bounded to a 0.5 m radius around the reticle; wandering far while scanning grows
  it. Reset clears it.
- Objects flush against a wall still are not separated (would need the Vision-mask step).

### Validation

Build and test on the physical iPhone:

1. Scan mode, aim at the object — confirm the green box and cyan points appear and refine *before* pressing Capture as you move around it.
2. Capture freezes the result; confirm the box stops updating and the readout says "Object captured".
3. Compare L×W×H to a tape measure; confirm it is closer and more stable than the single-shot version.
4. Reset and confirm live scanning resumes from empty.

---

## 2026-06-30 - Fix Scan Crash from Unbounded Accumulation

### Problem

The live accumulator grew without bound. Sweeping around — and especially aiming at a new object —
kept adding the whole swept region into one buffer, so memory and per-tick clustering cost climbed
until iOS killed the app. (It appeared to "work on the Nth try" only because a fresh object sometimes
accumulated enough before the buffer became fatal.)

### What changed

- **Hard cap on the accumulator** (`PointAccumulator`): a maximum number of distinct voxels (20000).
  Once reached, existing voxels keep averaging but no new voxels are added, so memory and compute are
  bounded no matter how long the session runs.
- **Auto re-anchor on aim change** (`ARCameraView.updateScanLive`): the accumulation records the
  world point it started at; if the reticle moves farther than the gather radius (0.5 m), the buffer
  is cleared and restarted at the new location. So panning to a different object drops the old data
  and builds the new object, instead of merging everything.
- `resetScanState` also clears the re-anchor point and the engine's live preview.

### Result

Aiming at one object builds and shows its box/cyan live (improving from multiple viewpoints, as
before); aiming at a different object seamlessly restarts on that object; the buffer never runs away,
so it no longer crashes between objects. Capture still freezes the current result; Reset clears.

### Validation

On the physical iPhone: scan one object (box appears), pan to a different object across the table
(box re-anchors to the new one), repeat many times — confirm no crash and that each object is
captured on its own. Leave it scanning a while to confirm memory stays flat.

### Follow-up - the real cause was the gather volume

The cap/re-anchor above were not enough on device. The deeper problem: each frame gathered depth
within a horizontal radius but **unbounded vertically and out to 2.5 m**, i.e. a tall column of the
whole room (floor, walls, background). Orbiting kept revealing new background, so the buffer filled
with non-object data and the per-tick clustering grew until iOS killed the app — "too much
information." Additional fixes:

- **Gather a tight 3D sphere** around the reticle (`accumulationRadius` 0.4 m, distance now measured
  in 3D, not just horizontally), so accumulation only covers the object and its immediate
  surroundings. This is the main fix.
- **Non-finite guard**: skip any depth pixel whose world coordinate is NaN/Inf — otherwise the
  `Int(floor(...))` voxel conversion would hard-trap.
- Lowered the accumulator cap to 12000 voxels.
- **Pooled the selection markers**: the cyan markers are now a reused, enable/disable pool instead of
  hundreds of entities created and destroyed every tick.

### Follow-up - converging box instead of an ever-growing one

After the crash was fixed, the box still only ever grew: pure accumulation takes the max extent and
never forgets, so depth noise and tracking drift pushed the box outward indefinitely, and the buffer
trended toward the cap. Made the capture confidence-based so it refines and converges:

- The accumulator counts how many times each voxel is observed. Only voxels seen at least
  `minObservations` (3) times count toward the box fit, so single-frame noise never enlarges it;
  real surfaces — re-seen as the operator moves around — solidify and persist.
- Every ~3 s the accumulator prunes voxels seen only once (un-reconfirmed noise), which keeps the
  buffer lean and stops the box creeping outward.

Result: for a static object the box settles after ~1 s and stays put; moving around the object only
extends it to genuinely-new, repeatedly-observed surface (true refinement) rather than ballooning.

---

## 2026-07-14 - Capability-Aware Scan and Compact Mode Menu

### Goal

Make automatic object capture the primary workflow while ensuring the app behaves clearly on the
currently available iPhone 15 Plus, which does not provide LiDAR scene depth.

### What changed

- Scan is now the default mode at app launch.
- Replaced the always-visible three-icon mode toggle with one compact `Mode` menu. The menu still
  exposes Scan, Line, and Box without changing the existing manual measurement implementations.
- Added an explicit automatic-capture capability derived from ARKit's scene-depth support check.
- On a non-LiDAR device, Scan now:
  - shows `Scan unavailable` and explains that automatic capture requires LiDAR;
  - replaces Capture with a disabled `LiDAR Required` control;
  - hides mesh and selected-depth-point controls;
  - skips the background live-depth update loop entirely.
- The RealityKit scene-understanding overlay is now shown only when scene reconstruction is actually
  enabled, as well as when Scan mode and mesh visibility are selected.

### Why this design

Automatic capture is the project's main workflow, so it remains the default instead of falling back
silently to a manual tool. Capability-aware presentation makes the hardware boundary visible and
prevents an unsupported device from misleadingly reporting that it merely needs more mesh data.

### Scope

The Line and Box measurement, raycasting, refinement, anchoring, rendering, and calculations were
not changed.

### Validation

- Generic iOS Debug build succeeded with Xcode 26.6.
- On an iPhone 15 Plus, confirm Scan opens by default, displays the LiDAR requirement, and exposes
  all three workflows through the Mode menu.
- On a LiDAR device, confirm Scan controls and the live depth workflow remain available.

---

## 2026-07-14 - RGB Object Mask Preview for Non-LiDAR Devices

### Goal

Detect and display the aimed object's RGB boundary in Scan mode on the available iPhone 15 Plus,
without requiring scene depth or changing the manual Line and Box tools.

### What changed

- Added `ObjectMaskProcessor.swift`.
- The processor runs Vision's foreground-instance mask request on the AR camera image.
- The instance beneath the center aimer is selected. If the exact center is background in Vision's
  lower-resolution result, the processor searches a small ring around it rather than selecting an
  unrelated object elsewhere in the image.
- The selected mask is converted with Core Image into a translucent cyan fill and a brighter
  morphology-derived boundary.
- `ARCameraView.Coordinator` requests an RGB mask at about 3 Hz while Scan mode is active.
- Vision processing is isolated in an actor, and only one request may be in flight. Intermediate
  frames are dropped when processing is busy, preventing a growing queue from slowing the AR feed.
- Three consecutive misses are required before removing the last mask, reducing preview flicker.
- `ObjectCaptureEngine` now exposes the latest display-ready mask to SwiftUI.
- `MeasurementOverlayView` scales the upright mask over the camera feed and reports either
  `Finding object` or `Object detected` on a non-LiDAR device.
- On the iPhone 15 Plus, metric Capture remains disabled and the UI explains that RGB detection is
  available while LiDAR is still required for 3D dimensions.

### Why a mask instead of raw edge detection

Raw image contours include table edges, shadows, labels, and surface texture. A foreground-instance
mask first determines which pixels belong to the object under the aimer. Its boundary can then be
used as the meaningful object edge, and the filled mask can later reject table pixels before depth
points enter the 3D accumulator.

### Current limitations

- This milestone is preview-only. The RGB mask is not yet applied to LiDAR depth samples.
- Vision's generic foreground segmentation can still merge an object with its support when their
  appearance is very similar, or miss transparent, reflective, very small, or low-contrast objects.
- The preview is intentionally throttled and can lag briefly during fast camera movement.
- Camera-to-overlay alignment and mask quality still require physical-device validation in portrait
  and both supported landscape orientations.

### Validation

- Generic iOS Debug build succeeded with Xcode 26.6 without source warnings.
- On the iPhone 15 Plus, open Scan, aim the center marker at a distinct object, and confirm a cyan
  fill and edge appear over only that object.
- Move the aimer onto the table or another object and confirm the selected mask changes after a
  short delay.
- Switch to Line or Box and confirm the RGB mask disappears and both manual tools behave unchanged.

---

## 2026-07-15 - RGB Mask Alignment and Refresh Fix

### Observed issue

Physical-device testing showed that the RGB object mask was rotated, did not align with the object
in the AR camera feed, and updated too slowly to remain useful during quicker camera movement.

### Cause

Vision received the raw landscape camera buffer together with orientation metadata. The generated
full-resolution mask was then explicitly rotated again in Core Image. That left the output-space
contract ambiguous and produced a rotated mask on the tested device. Mask requests were also
throttled to every fifth 15 Hz update tick, limiting the preview to about 3 Hz.

### What changed

- The camera buffer is now converted to a lazily oriented `CIImage` before it enters Vision.
- Vision processes that upright image without separate orientation metadata, so its scaled mask is
  already in the same upright coordinate space used by the SwiftUI camera overlay.
- The redundant post-segmentation mask rotation was removed.
- The foreground-mask request is reused between frames instead of recreated for every update.
- The request cadence increased from every fifth timer tick to every second tick: approximately
  7.5 Hz instead of 3 Hz when the device can complete requests at that rate.
- The existing single-in-flight rule remains, so slow devices still drop stale intermediate frames
  rather than accumulating latency.

### Validation

- Build the generic iOS target in Debug configuration.
- On the physical iPhone, verify portrait and both landscape orientations.
- Confirm the cyan fill and edge cover the selected object without a 90-degree rotation or offset.
- Pan the camera briskly and confirm the preview updates at least twice as often as before without
  visibly reducing AR camera responsiveness.

---

## 2026-07-15 - Faster Multi-Object Mask Tracking

### Goal

Make the RGB mask follow quicker phone movement and allow the operator to retain several visually
distinct object selections.

### What changed

- The mask pipeline now accepts every 15 Hz coordinator tick instead of every second tick. The
  existing single-in-flight rule still drops intermediate frames when Vision is busy, so requests
  never form a stale backlog.
- A transparent Scan-mode interaction layer captures spatial taps without blocking the existing
  controls.
- Tap coordinates are mapped through the same centered aspect-fill crop as the camera preview and
  converted into Vision's normalized lower-left coordinate system.
- Tapping a segmented object creates a Vision `TrackObjectRequest` initialized from that instance's
  mask bounds. Tapping the same tracked object again removes its lock.
- On each new segmentation, the stateful tracker predicts the object's current region. The processor
  samples that region to associate it with the newest frame-local instance number, preventing color
  identity from depending on instance numbers remaining stable between frames.
- A lock survives up to 20 missed processing frames so short blur, rapid motion, or a temporary
  segmentation miss does not immediately delete it.
- Up to eight objects can be locked. Each uses a distinct high-contrast color; cyan remains reserved
  for the unlocked object currently beneath the center aimer.
- Reset, mode changes, and AR view teardown clear the tracked masks and their UI count.

### Current limitations

- Foreground segmentation still determines the visible object boundary. Tracking can preserve the
  search region through motion, but it cannot create a good mask when Vision cannot segment the
  object in the new frame.
- Tracking is image-based rather than a persistent semantic identity. Long occlusion or two very
  similar objects crossing inside the same region can still cause the association to be lost.
- More simultaneous colored masks require additional high-resolution compositing work, so physical
  device testing should include one, several, and the maximum eight locks.

### Validation

- Generic iOS Debug build succeeds with Xcode 26.6.
- On a physical iPhone, tap one object and confirm its cyan preview changes to a locked palette color.
- Move the phone quickly and confirm the colored mask follows the object and survives brief blur.
- Tap a second and third object and confirm each retains a different color.
- Tap a locked object again and confirm only that object's colored mask is removed.
- Press Reset or switch modes and confirm all locked masks and their count are cleared.

---

## 2026-07-15 - Locked Mask Drift and Background-Switch Fix

### Observed issue

After locking an object, moving the phone could make its colored mask jump to the table or appear
like a large inverse mask. Adding another lock could also produce confusing overlapping overlays.

### Root cause

The tracker used its predicted rectangle only as a sampling region and then selected whichever
foreground instance occupied most of that rectangle. There were no area or size checks. When the
rectangle drifted down or expanded, the support surface could become the most frequent instance and
replace the payload in one update.

The unlocked cyan center preview also remained active while objects were locked. Panning the aimer
off the payload frequently selected the table in cyan and composited it with the colored locks,
which looked like an inverted or overlapping tracked mask.

Finally, the tap-to-remove fallback treated any tap inside a tracked bounding rectangle as removal,
even when Vision positively identified a different object under that tap.

### What changed

- Every candidate mask is now measured for normalized pixel area, bounding width and height, center,
  and overlap with the tracker prediction.
- A candidate is accepted only if its area changes by at most 35% and each bounding dimension changes
  by at most 25% from the previous accepted frame. Moving closer or farther still changes the mask,
  but the change must happen progressively instead of jumping from an object to the whole table.
- Implausibly large, small, or displaced tracker predictions are discarded before they can search
  unrelated parts of the scene.
- After a candidate passes validation, the stateful tracker is reinitialized from the accepted mask
  bounds. This corrects accumulated rectangle growth and drift on every successful frame.
- If no candidate passes validation, the lock records a temporary miss and renders no replacement
  mask. Losing the overlay briefly is safer than displaying a confidently wrong surface.
- The cyan center preview is now shown only when there are no locks. New objects can still be tapped
  directly while existing colored locks remain visible.
- Rectangle-based tap removal is used only when segmentation found nothing at the tap. A positively
  identified different instance can now be added instead of accidentally deleting an overlapping
  tracked rectangle.
- RGB mask scheduling moved to a dedicated 30 Hz timer, double the previous 15 Hz offer rate. The
  single-in-flight guard remains, so actual throughput is limited by the device's Vision processing
  speed and never builds a stale frame queue.

### Validation

- Generic iOS Debug build succeeds with Xcode 26.6.
- On a physical device, lock a payload on a table and pan so the aimer crosses the table. Confirm no
  cyan table mask appears while a lock exists.
- Move closer and farther gradually and confirm the locked mask changes size progressively.
- Move abruptly or briefly blur the frame and confirm the lock disappears temporarily instead of
  switching to the table or background.
- Lock two nearby objects and confirm each retains its own non-overlapping frame-local instance and
  color; tap each again to remove it independently.

---

## 2026-07-15 - Persistent World-Anchored Object Locks

### Architecture

- Each new RGB mask lock now requires a world-space surface result and creates a dedicated
  `ARAnchor`. LiDAR devices use the depth/mesh-assisted AR session; non-LiDAR devices use detected
  or estimated planes through the same code path.
- On LiDAR hardware, the tap samples the aligned depth map first so the anchor lands on the object's
  physical surface. If depth is unavailable, the implementation falls back to the plane raycast.
- Lock records no longer expire after a fixed number of missed Vision frames. They remain until the
  operator taps the colored object/marker again, presses Reset, or leaves Scan mode.
- The anchor is projected into every camera frame and becomes the authoritative reacquisition search
  area. Vision's rectangle tracker remains a short-term hint rather than the lock's identity.
- Expected mask scale is derived from camera-to-anchor distance. This allows genuine close/far
  motion while rejecting unexplained jumps from a payload to a whole table.
- A small normalized color/luminance signature is stored when locking and used with anchor position,
  mask size, and geometry when choosing a segmentation candidate after a miss.
- Colored anchor markers update at 60 Hz independently of the single-flight segmentation request.
  A dashed location marker represents a temporarily lost mask; the lock itself is still retained.
- Moving the LiDAR capture aimer to a new accumulation region now resets only the depth accumulator,
  not the independently locked RGB objects.

### Device adaptation and readiness

- `ARSessionManager` detects scene depth and scene-reconstruction support at runtime.
- LiDAR readiness waits for a depth frame plus a mesh or detected plane.
- Non-LiDAR readiness waits for camera-based plane detection and explains that more movement may be
  needed to build a reliable visual map.
- Both paths include ARKit world-mapping status. The Scan UI shows an "Understanding environment"
  banner until the map is usable, and the information panel identifies the active tracking mode.

### Validation

- Generic iOS Debug build succeeds with the iOS 26.5 SDK.
- Physical-device tests should cover an iPhone 15/15 Plus without LiDAR and an iPhone 13 Pro with
  LiDAR: lock several static objects, leave the view, return at a different distance, and confirm
  the same colored anchors guide reacquisition without attaching to the support surface.

---

## 2026-07-15 - Optical-Flow Masks and Mask-Gated LiDAR Capture

### Root cause addressed

The previous overlay displayed the result of the last completed segmentation request until another
segmentation completed. During fast camera movement that bitmap belonged to an older camera pose,
which created severe ghosting even though its world-anchor marker was current. The LiDAR capture
also still accumulated an unmasked sphere around the reticle, so the table could enter the fitted
geometry independently of what the RGB overlay showed.

### Tracking architecture

- Foreground instance segmentation is now a correction keyframe rather than the only source of
  visible updates.
- A separate `ObjectMaskMotionProcessor` runs one stateful dense Vision optical-flow request over a
  compact upright RGB stream. It propagates every locked binary mask independently between slower
  segmentation corrections.
- The optical-flow worker is single-flight and always consumes the newest available AR frame. At a
  60 Hz offer cadence it updates as quickly as the device can sustain without queuing stale frames.
- Per-pixel motion is constrained around each mask's median flow. A single update may change mask
  area by at most 28%; an outlier falls back to a rigid translation instead of expanding onto the
  table or collapsing.
- Small one-pixel holes are closed after warping. Each object retains its own binary state and
  color; partial segmentation corrections cannot erase another on-screen mask still carried by
  optical flow.
- Segmentation candidates for all locked objects are now assigned globally with a one-to-one
  maximum-score search. This replaces order-dependent greedy matching, where an early lock could
  take the instance belonging to a later lock.
- New locks reject masks occupying nearly the entire image. This makes selecting the table as an
  apparent inverse/background mask less likely.

### Measurement architecture

- The RGB image, raw scene-depth map, confidence map, camera pose, intrinsics, viewport transform,
  and timestamp are retained as one processing input.
- For every accepted locked instance, only depth pixels inside that exact frame's mask are
  back-projected into its own world-space point accumulator.
- Samples must also pass LiDAR confidence, camera-depth proximity to the object's anchor, and a
  bounded world-space distance from that anchor.
- `ObjectCapturePipeline` now accepts separate `objectPoints` and `supportPoints`. Width, depth,
  height, clustering, and box fitting use only mask-approved object points. Unmasked surrounding
  depth can estimate the table/support height but can never enlarge the object's fitted bounds.
- Once any mask is locked, capture deliberately has no unmasked fallback. If the mask is outside
  the view or lacks enough confirmed depth, the app waits instead of measuring a different surface.
- With multiple visible locks, the one closest to the screen center drives the live 3D box.

### Literature alignment

The supplied literature-review summaries support mask-gated geometry as a sound design:

- `Weng.2019` explicitly uses instance masks instead of 2D boxes to produce cleaner object-specific
  point-cloud frustums.
- `Zheng.2026` combines instance segmentation, RGB-D registration/fusion, and later geometric
  measurement; it is the closest end-to-end analogue in the chapter.
- `Feng.2024` combines RGB segmentation with coarse mobile AR depth and boundary fitting.
- `Foroutannia.2026` projects camera detections into a LiDAR frustum before 3D segmentation.
- `CamachoMunoz.2026` is the closest cited work on maintaining multiple geometric object tracks
  through occlusion and changing views.

None of the supplied summaries directly studies dense optical-flow propagation of instance masks
for mobile AR measurement. That is a literature gap to cover with video-object-segmentation or
mask-propagation papers in the final review.

### Validation

- Generic iOS Debug build succeeds with the iOS 26.5 SDK.
- Validate the optical-flow direction and upright coordinate convention on both physical devices;
  these cannot be established by the simulator.
- On iPhone 15/15 Plus, test RGB propagation, multi-lock identity, off-screen persistence, and
  reacquisition. Metric automatic capture remains unavailable without scene depth.
- On iPhone 13 Pro, additionally display selected points and confirm every fitted point lies inside
  the current object silhouette; scan the same object on a bare table from several distances.
- Record sustained optical-flow rate and thermal state. If the A15 cannot sustain `.high` accuracy
  at the desired cadence, reduce the 320-pixel working long edge before lowering flow accuracy.

---

## 2026-07-15 - Non-LiDAR Lock Regression Fix

- Object locking no longer waits for scene depth, a detected plane, or full environment readiness.
- When neither depth nor a raycast surface is available, the tap ray gets a provisional visual-only
  world anchor. Nearby AR feature points estimate its distance, with a conservative fallback; this
  estimate is never used as metric depth.
- The initial-mask guard now rejects only near-full-frame/background masks instead of also rejecting
  legitimate close-up objects that occupy a large part of the camera image.
- RGB mask tracking and lock markers continue while ARKit world tracking is temporarily limited;
  environment readiness still gates metric capture where appropriate, not visual selection.
- A tap missed by one segmentation frame is retried on fresh frames. Selection prefers the exact
  instance but can accept a nearby plausible mask, and the UI reports when no mask can be separated.
- Generic iOS Debug build succeeds with the iOS 26.5 SDK.

### Temporary presentation mode

- The cyan center preview is hidden: an overlay appears only after a tap creates a real colored lock.
- Dense optical-flow display propagation is temporarily disabled. Colored masks come only from fresh
  segmentation frames, preventing a newer stale flow overlay from hiding object-position corrections.
- Consecutive-frame 2D Vision tracking is authoritative on RGB-only hardware; provisional AR depth is
  only a secondary reacquisition hint.
- Non-LiDAR banners, the unavailable Capture button, and explicit depth/mesh-unavailable rows are
  hidden for the presentation. Restore capability messaging when measurement development resumes.

---

## 2026-07-16 - Fast Sequential Mask-Gated Object Scanning

### Initial decision (superseded by the multi-object batch scanner below)

The measurement goal is to acquire 3–15 object boxes quickly, not to maintain many persistent video
object identities. The production workflow therefore keeps one active object, saves its masked LiDAR
box, clears only that active target, and immediately accepts the next object. The pre-change native
Vision presentation version remains available in `main` history at commit `642c46d`. The former
backup branch was removed after its commit became part of `main` history.

### What changed

- One press on Capture selects the foreground instance under the center point and waits for stable,
  mask-approved LiDAR samples; a second press can cancel only that acquisition.
- Saved objects and their RealityKit boxes remain while the next object is scanned. Boxes cycle
  through eight high-contrast colors and the engine retains every `CapturedObject` result.
- Apple's native foreground-instance request is the active A15/A16-compatible segmentation path.
  The incomplete image-only EdgeTAM export and speculative optical-flow overlay are bypassed.
- Segmentation is single-flight and always accepts the newest camera frame; stale frames never queue.
  The visual overlay raster is smaller, while metric gating still samples the full-resolution mask.
- Masked depth accumulation and live 3D box fitting now run at the full 15 Hz acquisition cadence,
  five times the previous three-Hz cadence.
- Metric samples use the RGB mask and scene depth captured at the same AR frame. Approximately one
  LiDAR pixel is eroded from the mask boundary to reject RGB/depth calibration leakage from tables.
- There is no unmasked box-fitting fallback. A missing or lost mask waits/cancels instead of silently
  measuring the table or another object.

### Intended physical-device test

On an iPhone 13 Pro, center an isolated object on a flat surface and press Capture once. Move the
phone slightly to reveal its sides until the colored box is saved, then repeat for several objects.
Use Cancel if a difficult object does not converge; prior boxes must remain. An iPhone 15 without
LiDAR can exercise RGB selection, but cannot produce metric automatic boxes.

### 2026-07-16 follow-up: low-latency anchored display

- Scan mode no longer shows the manual Add Point control. Manual point placement is available only
  in the manual measurement modes.
- Every exact segmentation preview now records the selected object's world-anchor projection and
  camera distance from its source frame.
- At display cadence, ARKit reprojects that anchor. SwiftUI translates and distance-scales the last
  exact mask immediately, so it follows a static object as the phone moves instead of remaining at
  the old screen position.
- This prediction is display-only. Mask-gated LiDAR points still come exclusively from RGB and
  depth captured in the same AR frame, preventing visual reprojection error from enlarging a box.

---

## 2026-07-16 - Multi-Object LiDAR Batch Scanner

- Restored independent multi-object locks while retaining the corrected viewport/depth transforms
  and global one-to-one Vision instance assignment.
- Scan mode previews the unclaimed foreground instance under the center aimer before selection.
  Its color is the next free lock color; tapping preserves that color and advances the preview palette.
- Expanded the mask palette to 15 objects. Each locked instance retains its own AR anchor,
  synchronized masked-depth accumulator, local support accumulator, capture result and box entities.
- A LiDAR depth frame is back-projected once, then its points are partitioned around all visible
  object anchors. This avoids repeating the expensive depth-map conversion for every lock.
- Table/support points estimate only the local support height. Box dimensions and clustering still
  use mask-approved points exclusively, with the conservative boundary erosion retained.
- Boxes are inserted/refined by object ID and use the mask's color. Removing a mask removes only its
  accumulators, stored result and RealityKit box; other objects continue scanning.
- Locked objects are not deleted when off-screen. Their anchors and appearance state remain for
  reacquisition, and their world-space boxes remain attached to the stable content anchor.
- Non-LiDAR devices show a tappable `No LiDAR` badge. Its information sheet documents what remains
  available in RGB-only mode and why metric boxes/table separation require scene depth.
- Manual Add Point is still hidden in Scan mode. `Lock Center` is an optional one-handed equivalent
  to tapping the highlighted object; direct taps can add/remove locks anywhere in the view.
- A Live Mask eye control hides only the unselected mask under the aimer. Foreground segmentation
  continues at the same rate while hidden, so tapping can still lock the object immediately.
- Fresh segmentation corrections are merged into a retained per-lock display cache instead of
  replacing the complete layer set. All locked objects that project into the current frame can now
  show their masks together; removing one lock clears only its cached mask.
- Scan display layers are independently switchable from a single Visuals menu: live preview,
  locked masks, anchor markers, admitted LiDAR object points, scene mesh and fitted 3D boxes.
  `Results only` and `Hide all overlays` presets provide clean presentation views. These controls
  never pause segmentation, depth accumulation, object association or measurement.
- Diagnostic LiDAR points and the reconstructed mesh now default to hidden. When enabled, admitted
  points use small 7 mm spherical dots instead of the previous 2 cm cyan cubes, reducing occlusion.

### 2026-07-16 follow-up: mask/depth registration and stable boxes

- Depth pixels now map directly from ARKit's native registered camera coordinates into the upright
  Vision mask. This removes an unnecessary raw-image → cropped-viewport → raw-image round trip.
- Metric admission erodes approximately two oriented LiDAR pixels from every mask edge and rejects
  samples across a local depth discontinuity. These checks target foreground/background mixing at
  the silhouette without changing the visible 2D mask.
- Object accumulation and connected-component fitting now use 1 cm voxels instead of 2 cm voxels.
  Up to 900 small cyan points can be shown, producing a denser and more legible object surface.
- Accumulated voxels record when they were last observed. Unconfirmed and stale geometry expires
  instead of remaining forever and causing slow outward box creep.
- Support height now comes from the dominant local horizontal height layer rather than a low
  percentile. A lower shelf or floor can therefore no longer pull the base down and turn the real
  tabletop into part of the object cluster.
- A fitted object rejects any single update that grows a sorted dimension by more than 18% or
  2.5 cm, or moves the box center implausibly far. Shrinking corrections remain permitted.
- The center `Lock` button was removed. In Scan mode, tapping a highlighted object is the only
  visible add/remove interaction, leaving a simpler camera UI.

### 2026-07-16 follow-up: point/box consistency and quick display controls

- The robust box intentionally trims extreme samples. Cyan visualization now filters those same
  samples through the final oriented box, so a displayed cyan point cannot contradict the box.
- Confirmed masked voxels remain in the rolling cloud for 180 mask updates, preserving side and
  vertical surfaces during a normal walk-around while still allowing old geometry to expire.
- The bottom Scan UI exposes direct `Mask`, `Points`, and `Box` switches. A compact `More` menu keeps
  separate live/locked mask controls, lock markers, scene mesh and presentation presets.
- The information panel reports the depth-map pixel dimensions supplied by the current device at
  runtime and distinguishes that native map from the filtered 1 cm object voxel model.

### 2026-07-16 follow-up: bounded scan memory

- Native Vision rendering generates a source-image-aligned mask for one selection at a time,
  immediately derives its small display layer and masked depth points, then drains an autorelease
  pool before processing the next selection. This retains exact RGB/depth registration without
  holding full-camera-resolution Float32 masks for every visible lock simultaneously.
- `PointAccumulator` stores sum, count and age in one compact hash-table value with 32-bit voxel
  keys. The former three dictionaries multiplied both key and allocator overhead.
- Masked clouds are capped at 10,000 voxels per object and support clouds at 4,000. These limits
  still exceed normal object-surface requirements while keeping 15-object memory deterministic.
- The reusable RealityKit cyan-marker pool is capped at 360 entities instead of 900. The underlying
  1 cm measurement cloud is unchanged; only the debug display is subsampled.
- Local support-plane sampling uses every third depth pixel because it only estimates a dominant
  height. Mask-gated object sampling continues to inspect every native depth pixel.
- On an iOS memory warning, the app releases only rebuildable masks, depth accumulators and debug
  entities. Locks and already fitted boxes remain, and fresh synchronized frames rebuild the caches.

#### Registration correction

An initial memory optimization used Vision's compact observation-space mask directly. Although it
was smaller, that buffer does not guarantee the source-image geometry required for registered ARKit
scene depth, so mask-approved LiDAR samples could fall to zero and no cyan cloud or box would appear.
Sequential source-aligned mask processing above fixes that regression without restoring the original
multi-mask memory peak.

---

## 2026-07-17 - iOS 18 Deployment and Liquid Glass Removal

### Goal

Allow the same measurement and segmentation implementation to build with an iOS 18 deployment
target, including on an older development Mac that can run Xcode 16.3 or 16.4.

### What changed

- Lowered the Debug and Release deployment targets from iOS 26.5 to iOS 18.0.
- Replaced every iOS 26-only SwiftUI `glassEffect` with `ultraThinMaterial` backgrounds. The HUD
  retains readable translucent controls but no longer requires Liquid Glass.
- Removed the Xcode 26-only approachable-concurrency, default-MainActor and member-import project
  settings after confirming the source builds with their older defaults.
- Kept all functional Scan visuals unchanged: live and locked masks, LiDAR points, reconstructed
  mesh, lock markers and fitted boxes are still calculated and remain independently switchable.
- Consolidated the current two feature commits into the local `main` branch and removed the fully
  merged local feature and presentation-backup branches. No commit or remote operation was made.

### Backup and restoration

The exact pre-change Liquid Glass source is commit `00ed3f0` in `main` history and is also marked by
the local tag `backup/ios26-liquid-glass-2026-07-17`. To inspect or restore only that view later:

```sh
git show 00ed3f0:MeasurementOverlayView.swift
git restore --source 00ed3f0 -- MeasurementOverlayView.swift
```

The restore command modifies the working tree only; review it before committing.

### Compatibility boundary

- The core path uses iOS 18 Vision APIs (`GenerateForegroundInstanceMaskRequest`,
  `TrackObjectRequest` and `ImageRequestHandler`) and therefore remains iOS 18 or newer.
- ARKit world tracking, LiDAR scene depth and scene reconstruction do not raise that minimum.
- iOS 26.5 devices can run the iOS 18-targeted binary and use their installed ARKit, Vision and
  Core ML runtimes. Lowering the deployment target does not reduce behavior on newer devices.
- Two generic-device builds succeed with the installed Xcode 26.6 toolchain: the normal project
  configuration and a compatibility build with approachable concurrency, default MainActor
  isolation and member-import visibility disabled to approximate the older compiler defaults.
- Opening and building with Xcode 16.3/16.4 must still be verified on the older Mac because this
  machine cannot reproduce that compiler and project-editor version exactly.
- App Store uploads after April 28, 2026 still require a final archive produced with Xcode 26 and
  the iOS 26 SDK, even though the app's minimum deployment target is iOS 18.

---

## 2026-07-22 - Additive and Stable Object Surface Points

### Observed problem

While walking around a locked object, the cyan points appeared to move continuously rather than
settle onto the measured surface. Previously visible sides could also disappear after the camera
stopped seeing them, and adding new coverage could reshuffle most of the displayed markers.

### Causes

- Observation counts were incremented once per raw depth pixel. Several pixels from a single AR
  frame could therefore make a voxel look temporally confirmed without any later-frame evidence.
- Confirmed masked voxels expired after a rolling scan window, so an old face was eventually removed
  while the operator viewed another face.
- The cyan debug markers used geometric voxel centers rather than the measured depth positions.
- The final robust bounding box also filtered the debug cloud. A legitimate boundary point could
  disappear when the robust box refined even though the accumulated measurement still existed.
- Connected-component output and marker subsampling depended on unordered collection traversal, so
  adding a point could assign many reusable marker entities to different positions.
- One-centimetre mask-edge erosion could leave a one-cell gap between surfaces acquired from
  different viewpoints, keeping a valid new face outside the seed component.

The reconstructed ARKit scene mesh and the cached 2D display mask were not responsible for deleting
points. The mesh is a visual overlay, and the 2D mask only gates synchronized incoming depth.

### What changed

- Raw pixels are coalesced to one centroid per voxel per synchronized AR frame. A voxel must now be
  seen in three distinct frames before it is admitted as stable geometry. Duplicate or out-of-order
  deliveries of the same source timestamp cannot increase that count.
- The measured centroid is frozen when a masked voxel becomes stable. Later observations can update
  internal evidence but cannot make an admitted cyan point wander.
- Stable masked voxels remain until that object is unlocked or its rebuildable cache is explicitly
  cleared. Periodic cleanup removes only candidates that never reached three-frame confirmation.
- When a capped accumulator needs space, old unconfirmed candidates are removed before newly seen
  geometry is rejected; confirmed geometry is never evicted by that replacement path.
- A box/cloud refit is requested only when at least one new voxel becomes stable. Repeated views of
  already confirmed geometry no longer rebuild the same result every segmentation update.
- Cyan markers now use measured surface representatives for every voxel in the selected connected
  component. Robust trimming still protects dimension fitting, but no longer hides valid surface
  coverage merely because it lies outside the current trimmed box.
- Connectivity uses a conservative two-voxel Euclidean neighbourhood. This bridges a single empty
  one-centimetre seam while avoiding the broad diagonal reach of a complete 5-by-5-by-5 stencil.
- Component traversal is deterministic. If more than 360 debug points exist, a stable voxel-key hash
  chooses the displayed subset, so adding coverage changes at most the necessary subset rather than
  arbitrarily reshuffling the cloud.
- If the existing plausibility guard rejects a sudden box expansion, the last accepted dimensions
  remain locked while newly confirmed surface coverage is still retained and displayed.

No segmentation model, mask/depth registration rule, depth-discontinuity rejection, erosion amount,
one-centimetre measurement voxel size, 10,000-voxel per-object cap, 360-marker display cap, oriented
box fitting rule, dimension threshold, or scene-mesh behavior was changed.

### Build validation

- Xcode 16.2 (`16C5032a`) generic iOS device Debug build: succeeded with code signing disabled.
- Xcode 16.2 (`16C5032a`) generic iOS Simulator Debug build: succeeded with code signing disabled.
- LiDAR acquisition behavior still requires a physical device; a simulator build cannot validate
  scene depth, mask/depth registration, or a real walk-around scan.

### Physical-device validation

On the LiDAR device, enable `Points`, lock one isolated object on a bare support surface, and hold
each newly revealed face in view for at least three synchronized segmentation/depth frames. Walk a
full circle around it and confirm:

1. Points already acquired on the first face remain fixed and visible when that face leaves view.
2. Newly revealed sides add points without moving or removing the established surface cloud.
3. Cyan marker centers lie on the measured object surface rather than on an artificial grid center.
4. Repeatedly viewing an already-covered face does not continuously rebuild its points or dimensions.
5. A suspicious abrupt box expansion remains rejected while legitimate new cyan coverage remains.
6. Unlocking one object clears only that object's accumulated surface; other locked objects remain.
7. A long multi-object scan remains within the existing 10,000 stable-voxel limit per object and
   acceptable device memory/thermal behavior.

### 2026-07-22 follow-up: continued coverage and quarantined outliers

Physical testing exposed two different forms of apparent point-cloud saturation. The renderer could
show only 360 globally hash-ranked markers, so acquisition often continued without placing a marker
on a small newly revealed face. Separately, a masked accumulator whose 10,000 slots had all become
stable could no longer admit a new voxel. Stable disconnected points and old mask/depth leaks also
occupied those slots indefinitely.

The exterior cyan points had a separate, intentional cause in the preceding implementation. The
oriented box robustly trims the outer four percent of projections, but the debug cloud displayed
every point in the connected component. If a proposed box failed the growth plausibility guard, the
old box was retained while all points from the rejected proposal were still displayed. A point could
therefore appear outside the box precisely because that box did not accept it. Every point had been
inside a synchronized mask when sampled, but a leak lasting three processed frames could remain
after a later mask correction because historical surfaces are deliberately not tested against the
current 2D mask.

The follow-up changes are:

- A capture result exposes only measured representatives contained by its robust box, with a
  half-centimetre tolerance to avoid boundary flicker. Rejected tail samples remain quarantined in
  the accumulator for possible later reevaluation rather than being rendered as accepted geometry.
- When a proposed box fails the existing plausibility guard, the old box and its prior points remain.
  Newly confirmed points are added to that display only when the retained box also supports them.
- The accumulator permanently marks voxels once an accepted result has used them. A later box
  contraction therefore cannot make previously accepted historical evidence replaceable. Under
  capacity pressure it first reclaims unconfirmed noise, then the oldest stable voxels that have
  never been accepted because they remain disconnected or robustly rejected. It never chooses a
  protected historical surface for this replacement path, and replaces at most 256 stable
  candidates per processed mask frame so one noisy frame cannot discard a whole pending face.
- The bounded masked-cloud allowance is now 16,000 one-centimetre voxels per object instead of
  10,000. This provides room for larger multi-face payloads while remaining well below the former
  unsafe 30,000-voxel design.
- The optional cyan debug pool is now capped at 600 markers instead of 360. Its sampler first places
  one deterministic representative in each occupied coarse spatial cell, then spends remaining
  markers on detail. New faces therefore receive visible coverage after the pool is full instead of
  competing only by a global random-looking hash rank.

The three-distinct-frame confirmation requirement was not lowered, connectivity was not widened,
and no segmentation, mask erosion, depth registration, depth-discontinuity threshold, box trim,
box-growth guard, or one-centimetre measurement resolution was changed. Historical points are also
not removed merely because they are absent from the current 2D mask: from another viewpoint they may
be off-screen or occluded, so such a test would again erase valid previously scanned faces.

#### Follow-up physical-device validation

1. Scan one face until it has stable cyan coverage, then reveal several previously empty faces.
   Confirm each new spatial region gains markers even after the displayed pool is full.
2. Continue a long scan and verify the reported fitted-point count can grow beyond 10,000 without
   stopping at that former boundary.
3. Deliberately include a small mask-edge leak or background sliver. Confirm points rejected by the
   accepted box do not remain visible outside it.
4. Turn the first face away from the camera and confirm its accepted points remain protected.
5. Repeat with several simultaneous locks and watch memory pressure and thermal state because the
   per-object measurement allowance and optional RealityKit marker pool are both larger.

---

## 2026-07-29 - Remove yellow surfels; view-gated per-dimension capture; face guide

### Removed the yellow mask surfels (performance)

Selecting an object rendered its mask as a world-anchored surfel cloud (octahedra, up to ~16k =
~96k vertices) rebuilt every Vision frame in the object's colour (the first colour is yellow). It
was cosmetic — the measurement uses the separate `maskedAccumulators` / `acceptedPoints`. Dropped
the surfel build in the depth loop in `ARCameraView`; the lightweight 2D mask preview remains as the
highlight, and measurement is unchanged. The surfel overlay functions are now dormant (never fed).

### View-gated per-dimension capture (fixes side-view widening + remembers faces)

Problem: from a side view, background points behind the object were admitted and widened the box;
from the top the mask removed them, but returning to the side re-admitted them. Root cause: the box
was fully refit every tick from an accumulator that persists points.

Fix (in `ARCameraView.Coordinator`): the fitted box is post-processed by `viewGatedBox(...)` which
keeps per-object memory — a horizontal `ObjectFootprint` (width/length/yaw/XZ) captured only from a
**top-down** view and a **height** captured only from a **side** view (`classifyView` uses the
camera-forward · gravity). Each dimension is remembered and the other viewpoint cannot change it, so
side-view background can no longer widen width/length, and a top view cannot disturb the height.
`alignFootprint` keeps the yaw stable across ticks; `makeViewBox` rebuilds the box (corner order
matches `ObjectBoundingBox.make`). Bootstraps from the first fit so a box still appears immediately.
Per-object memory is cleared on remove / re-add / reset.

### Face-capture guide (`MesOverlayView.faceCaptureGuide`)

While measuring an object, a small HUD card shows two rows — “Top view → width × length” and
“Side view → height” — highlighting the current viewpoint (`captureEngine.scanViewHint`) and marking
each as saved once captured (`footprintCapturedFromTop` / `heightCapturedFromSide`).

### Validation (on device, Xcode ⌘R)

1. Select an object: the yellow point spam is gone and the app stays smooth; a light 2D highlight remains.
2. Aim top-down: the guide highlights “Top view” and width×length lock in.
3. Aim from the side: the guide highlights “Side view” and height locks in; width/length do NOT change.
4. Returning to the side no longer widens the box; each face shows “saved”.

---

## 2026-07-29 - Fix mask "breathing"; add convergence ("satisfied") heuristic

### Mask breathing (visual + measurement)

- Visual: the 2D mask preview scaled the bitmap by a tracked bounding-box ratio
  (`current.width / reference.width`) that jitters between Vision frames, so the highlight pulsed a
  couple times a second (now visible on the active object because the surfels were removed). Fixed in
  `MesOverlayView.trackedObjectMaskPreview`: size follows camera **distance** only; the tracked box
  is used for position, not scale.
- Measurement: the box itself jittered because `viewGatedBox` overwrote the stored dimensions from
  every fit. Added `stabilize(_:_:)` — a deadband (max(4 mm, 3%)) plus light easing (blend 0.35), so
  within tolerance the stored value is held and the box stops breathing; larger changes ease in.

### "Satisfied" convergence heuristic + guide

A dimension is now considered **captured** only once it holds within the deadband for
`satisfiedTickCount` (6) consecutive fits in its ideal view — a real convergence test rather than
"seen once". The engine exposes `footprintSatisfied` / `heightSatisfied` / `measurementSatisfied`.
The face guide marks each row done (green "saved") when its dimension converges and shows
"Measurement ready — lock it in" once both are satisfied.
