`# DEVELOPMENT_NOTES.md

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
