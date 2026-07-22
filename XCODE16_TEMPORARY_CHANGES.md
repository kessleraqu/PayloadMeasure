# Xcode 16 Temporary Compatibility Changes

Date: 2026-07-22

Purpose: make this temporary project copy compile with Xcode 16.2 (16C5032a), the bundled Swift 6.0.3 compiler, and the iOS 18.2 SDK on macOS Sonoma 14.8.7 while preserving runtime behavior.

## Files changed

- `ObjectMaskProcessor.swift`
- `PayloadMeasure/EdgeTAMSegmenter.swift`
- `ARCameraView.swift`
- `XCODE16_TEMPORARY_CHANGES.md` (this record; newly created)

`PayloadMeasure.xcodeproj/project.pbxproj` was not changed.

## Temporary source compatibility adjustments

Only 19 type declaration headers and one RealityKit initializer expression were changed. No segmentation, tracking, ARKit session flow, Vision, Core ML, depth processing, concurrency implementation, rendering behavior, constants, or thresholds were changed.

### ObjectMaskProcessor.swift

Xcode 16.2's Swift 6.0.3 compiler rejects the Xcode 26 declaration-level `nonisolated` syntax. Each temporary replacement removes only the unsupported modifier and retains the original protocol conformances, including `Sendable` and `@unchecked Sendable`.

- Original: `nonisolated struct ObjectMaskPreviewLayer: @unchecked Sendable {`
  Temporary: `struct ObjectMaskPreviewLayer: @unchecked Sendable {`
- Original: `nonisolated struct ObjectMaskPreview: @unchecked Sendable {`
  Temporary: `struct ObjectMaskPreview: @unchecked Sendable {`
- Original: `nonisolated struct ObjectMaskToggleRequest: @unchecked Sendable {`
  Temporary: `struct ObjectMaskToggleRequest: @unchecked Sendable {`
- Original: `nonisolated struct ObjectMaskAnchorHint: @unchecked Sendable {`
  Temporary: `struct ObjectMaskAnchorHint: @unchecked Sendable {`
- Original: `nonisolated struct ObjectMaskDisplayColor: Sendable, Hashable {`
  Temporary: `struct ObjectMaskDisplayColor: Sendable, Hashable {`
- Original: `nonisolated struct ObjectMaskMarker: Identifiable, Equatable, @unchecked Sendable {`
  Temporary: `struct ObjectMaskMarker: Identifiable, Equatable, @unchecked Sendable {`
- Original: `nonisolated enum ObjectMaskLockChangeKind: Sendable {`
  Temporary: `enum ObjectMaskLockChangeKind: Sendable {`
- Original: `nonisolated struct ObjectMaskLockChange: @unchecked Sendable {`
  Temporary: `struct ObjectMaskLockChange: @unchecked Sendable {`
- Original: `nonisolated struct ObjectMaskFrame: @unchecked Sendable {`
  Temporary: `struct ObjectMaskFrame: @unchecked Sendable {`
- Original: `nonisolated struct ObjectMaskDepthSnapshot: @unchecked Sendable {`
  Temporary: `struct ObjectMaskDepthSnapshot: @unchecked Sendable {`
- Original: `nonisolated struct ObjectMaskDepthPointCloud: @unchecked Sendable {`
  Temporary: `struct ObjectMaskDepthPointCloud: @unchecked Sendable {`
- Original: `nonisolated struct ObjectMaskMotionLayer: @unchecked Sendable {`
  Temporary: `struct ObjectMaskMotionLayer: @unchecked Sendable {`
- Original: `nonisolated struct ObjectMaskMotionKeyframe: @unchecked Sendable {`
  Temporary: `struct ObjectMaskMotionKeyframe: @unchecked Sendable {`
- Original: `nonisolated struct ObjectMaskMotionCatchUpFrame: @unchecked Sendable {`
  Temporary: `struct ObjectMaskMotionCatchUpFrame: @unchecked Sendable {`
- Original: `nonisolated struct ObjectMaskProcessingResult: @unchecked Sendable {`
  Temporary: `struct ObjectMaskProcessingResult: @unchecked Sendable {`

### PayloadMeasure/EdgeTAMSegmenter.swift

- Original: `nonisolated struct EdgeTAMFrameFeatures: @unchecked Sendable {`
  Temporary: `struct EdgeTAMFrameFeatures: @unchecked Sendable {`
- Original: `nonisolated struct EdgeTAMMask: @unchecked Sendable {`
  Temporary: `struct EdgeTAMMask: @unchecked Sendable {`
- Original: `nonisolated enum EdgeTAMSegmenterError: LocalizedError {`
  Temporary: `enum EdgeTAMSegmenterError: LocalizedError {`
- Original: `nonisolated final class EdgeTAMSegmenter: @unchecked Sendable {`
  Temporary: `final class EdgeTAMSegmenter: @unchecked Sendable {`

### ARCameraView.swift

Xcode 16.2's iPhoneOS RealityKit interface contains `AnchorEntity(anchor: ARAnchor)`, but its iPhoneSimulator RealityKit interface omits that convenience initializer. Both SDK interfaces support an anchor target identified by the same `ARAnchor` UUID. The following one-line spelling compiles for device and simulator and continues to bind the RealityKit entity to the exact `ARAnchor` added to the `ARSession` immediately afterward.

- Original: `let anchorEntity = AnchorEntity(anchor: arAnchor)`
  Temporary: `let anchorEntity = AnchorEntity(.anchor(identifier: arAnchor.identifier))`

The supported method-level `nonisolated` modifiers on the seven `ARSessionDelegate` methods in `ARSessionManager.swift` were intentionally retained. They are accepted by Swift 6.0 and are part of the existing concurrency architecture.

## Project settings

No project setting was changed. Original and current relevant values are:

- Project Debug `IPHONEOS_DEPLOYMENT_TARGET`: `18.0` (unchanged)
- Project Release `IPHONEOS_DEPLOYMENT_TARGET`: `18.0` (unchanged)
- Target Debug `SWIFT_VERSION`: `5.0` language mode (unchanged)
- Target Release `SWIFT_VERSION`: `5.0` language mode (unchanged)
- Project `objectVersion`: `77` (unchanged)
- Project `preferredProjectObjectVersion`: `77` (unchanged)
- Project `LastSwiftUpdateCheck`: `2650` (unchanged)
- Project `LastUpgradeCheck`: `2650` (unchanged)
- Target `CreatedOnToolsVersion`: `26.5` (unchanged)

The build used Xcode 16.2's Swift 6.0.3 compiler. `CODE_SIGNING_ALLOWED=NO` and `COMPILER_INDEX_STORE_ENABLE=NO` were command-line-only build overrides and were not saved in the project. A simulator diagnostic check also used command-line-only `ARCHS=arm64` and `ONLY_ACTIVE_ARCH=YES`; neither was saved in the project.

The deployment target remains iOS 18.0. No dependency was added, removed, or upgraded.

## Source and model membership verification

- `ObjectMaskProcessor.swift` exists once, has one `PBXFileReference`, one `PBXBuildFile`, and one entry in the sole target's `PBXSourcesBuildPhase`. It is outside the synchronized `PayloadMeasure/` group, so it is compiled exactly once.
- These Core ML packages remain under the target's synchronized `PayloadMeasure/` root group with no membership exception and were all compiled into the app during verification:
  - `PayloadMeasure/Models/EdgeTAM/edgetam_image_encoder.mlpackage`
  - `PayloadMeasure/Models/EdgeTAM/edgetam_prompt_encoder.mlpackage`
  - `PayloadMeasure/Models/EdgeTAM/edgetam_mask_decoder.mlpackage`

## Build verification

- Generic iOS device, Debug, iOS 18.2 SDK, signing disabled: succeeded.
- Generic iOS Simulator, Debug, iOS 18.2 SDK: succeeded for the complete generic simulator build after the RealityKit compatibility adjustment.
- Remaining compiler errors: none.

## Restoring the Xcode 26 syntax next week

1. In `ObjectMaskProcessor.swift`, restore `nonisolated ` immediately before each of the 15 type declarations listed above.
2. In `PayloadMeasure/EdgeTAMSegmenter.swift`, restore `nonisolated ` immediately before each of the four type declarations listed above.
3. In `ARCameraView.swift`, replace `let anchorEntity = AnchorEntity(.anchor(identifier: arAnchor.identifier))` with `let anchorEntity = AnchorEntity(anchor: arAnchor)`.
4. Do not change the retained method-level `nonisolated` modifiers in `ARSessionManager.swift`.
5. No project setting needs to be restored because none was changed.
6. Rebuild with Xcode 26 and confirm all three Core ML models still compile and `ObjectMaskProcessor.swift` remains present once in Compile Sources.

No Git command was used while making or verifying these temporary changes.
