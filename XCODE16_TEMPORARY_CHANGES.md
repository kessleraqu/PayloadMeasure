# Xcode 16 Temporary Compatibility Changes

Historical development record. See the root README for the current toolchain and run instructions.

Date: 2026-07-22

Purpose: make this temporary project copy compile with Xcode 16.2 (16C5032a), the bundled Swift 6.0.3 compiler, and the iOS 18.2 SDK on macOS Sonoma 14.8.7 while preserving runtime behavior.

## Files changed

- `objectmaskprocessor.swift`
- `arcameraview.swift`
- `XCODE16_TEMPORARY_CHANGES.md` (this record; newly created)

`PayloadMeasure.xcodeproj/project.pbxproj` was not changed.

## Temporary source compatibility adjustments

Only type declaration headers and one RealityKit initializer expression were changed. No segmentation, tracking, ARKit session flow, Vision, depth processing, concurrency implementation, rendering behavior, constants, or thresholds were changed.

### objectmaskprocessor.swift

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
- Original: `nonisolated struct ObjectMaskProcessingResult: @unchecked Sendable {`
  Temporary: `struct ObjectMaskProcessingResult: @unchecked Sendable {`

### arcameraview.swift

Xcode 16.2's iPhoneOS RealityKit interface contains `AnchorEntity(anchor: ARAnchor)`, but its iPhoneSimulator RealityKit interface omits that convenience initializer. Both SDK interfaces support an anchor target identified by the same `ARAnchor` UUID. The following one-line spelling compiles for device and simulator and continues to bind the RealityKit entity to the exact `ARAnchor` added to the `ARSession` immediately afterward.

- Original: `let anchorEntity = AnchorEntity(anchor: arAnchor)`
  Temporary: `let anchorEntity = AnchorEntity(.anchor(identifier: arAnchor.identifier))`

The supported method-level `nonisolated` modifiers on the seven `ARSessionDelegate` methods in `arsessionmanager.swift` were intentionally retained. They are accepted by Swift 6.0 and are part of the existing concurrency architecture.

## Later unreachable-code cleanup

Date: 2026-07-23

The uninstantiated optical-flow motion pipeline was later removed from `objectmaskprocessor.swift`. This cleanup was independent of Xcode 16 compatibility and did not change the temporary syntax replacements listed above.

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

- `objectmaskprocessor.swift` exists once, has one `PBXFileReference`, one `PBXBuildFile`, and one entry in the sole target's `PBXSourcesBuildPhase`. It is outside the synchronized `PayloadMeasure/` group, so it is compiled exactly once.

## Build verification

- Generic iOS device, Debug, iOS 18.2 SDK, signing disabled: succeeded.
- Generic iOS Simulator, Debug, iOS 18.2 SDK: succeeded for the complete generic simulator build after the RealityKit compatibility adjustment.
- Remaining compiler errors: none.

## Xcode 26.5 restoration completed

Date: 2026-08-06

- Restored declaration-level `nonisolated` annotations used by the cross-actor mask value types.
- Restored `AnchorEntity(anchor:)` for anchors created from exact `ARAnchor` instances.
- Raised the project deployment setting inherited by the app target to iOS 26.5.
- Restored Xcode 26 concurrency settings: approachable concurrency, MainActor default isolation and
  member-import visibility. Swift 5 language mode remains intentional.
- Restored the HUD with native Liquid Glass effects and glass button styles.
- Removed development Markdown files from the application bundle while retaining them in the project.
- Verified the active app with Xcode 26.5 using unsigned generic-device Debug and clean Release builds,
  followed by Xcode static analysis.

No Git command was used while restoring or verifying these changes.
