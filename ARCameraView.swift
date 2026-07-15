//
//  ARCameraView.swift
//  PayloadMeasure
//
//  Created by Alexandre on 29/06/2026.
//

import ARKit
import ImageIO
import RealityKit
import SwiftUI
import UIKit

struct ARCameraView: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let measurementEngine: MeasurementEngine
    let captureEngine: ObjectCaptureEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionManager: sessionManager,
            measurementEngine: measurementEngine,
            captureEngine: captureEngine
        )
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        sessionManager.configure(arView.session)
        context.coordinator.attach(to: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // The coordinator observes MeasurementEngine directly via `withObservationTracking`, so
        // there is no SwiftUI-driven update work to do here. This stays empty intentionally.
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.detach()
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject {
        private struct PlacedPoint {
            let id: UUID
            let marker: ModelEntity
            var anchorEntity: AnchorEntity?
            var arAnchor: ARAnchor?
            var latestTransform: simd_float4x4
            var trackedRaycast: ARTrackedRaycast?
        }

        private struct ObjectMaskMarkerState {
            let color: ObjectMaskDisplayColor
            let isMaskVisible: Bool
        }

        // Bright UI-white for measurement visuals. `applyPostProcessToneMap: false` keeps the color
        // from being darkened by RealityKit's tone mapper, matching the on-screen SwiftUI aimer.
        fileprivate static let iceWhiteMaterial = UnlitMaterial(color: .white, applyPostProcessToneMap: false)
        // A distinct green for a captured object's box so it never reads as a manual measurement.
        fileprivate static let captureMaterial = UnlitMaterial(color: .systemGreen, applyPostProcessToneMap: false)
        // Cyan for the selected-cluster debug markers, so it is clearly separate from the box.
        fileprivate static let selectionMaterial = UnlitMaterial(color: .cyan, applyPostProcessToneMap: false)
        // One shared marker mesh reused by every selection point to avoid regenerating geometry.
        fileprivate static let selectionMarkerMesh = MeshResource.generateBox(size: 0.02)
        // A unit cube reused for every box edge (scaled per edge), since the box is rebuilt live.
        fileprivate static let unitCubeMesh = MeshResource.generateBox(size: 1.0)

        private let sessionManager: ARSessionManager
        private let measurementEngine: MeasurementEngine
        private let captureEngine: ObjectCaptureEngine
        private weak var arView: ARView?
        private var contentAnchor: AnchorEntity?
        private var placedPoints: [PlacedPoint] = []
        private var measurementEntities: [ModelEntity] = []
        private var previewMeasurementEntities: [ModelEntity] = []
        private var captureEntities: [ModelEntity] = []
        private var selectionPool: [ModelEntity] = []
        private var lastSelectionPoints: [SIMD3<Float>] = []
        private var accumulator = PointAccumulator(voxelSize: ObjectCapturePipeline.voxelSize)
        private var maskedAccumulators: [UUID: PointAccumulator] = [:]
        private let objectMaskProcessor = ObjectMaskProcessor()
        private let objectMaskMotionProcessor = ObjectMaskMotionProcessor()
        private var liveResult: CaptureResult?
        private var accumulationAnchor: SIMD3<Float>?
        private var selectedCaptureMaskID: UUID?
        private var isScanFrozen = false
        private var scanTickCounter = 0
        private var consecutiveMaskMisses = 0
        private var objectMaskTask: Task<Void, Never>?
        private var objectMaskMotionTask: Task<Void, Never>?
        private var pendingObjectMaskToggleRequest: ObjectMaskToggleRequest?
        private var objectMaskToggleAttemptsRemaining = 0
        private var objectMaskAnchors: [UUID: ARAnchor] = [:]
        private var objectMaskMarkerStates: [UUID: ObjectMaskMarkerState] = [:]
        private var objectMaskTrackingGeneration = 0
        private var previewTargetPosition: SIMD3<Float>?
        private var lastAimerRaycastTransform: simd_float4x4?
        private var aimerUpdateTimer: Timer?
        private var maskUpdateTimer: Timer?
        private var observedResetRevision = 0
        private var observedPlacementRequestRevision = 0
        private var observedMode: MeasurementMode = .scan
        private var observedCaptureRequestRevision = 0
        private var observedCaptureResetRevision = 0
        private var observedObjectMaskToggleRequestRevision = 0
        private var observedMeshVisible = true
        private var observedShowsSelectedPoints = true

        init(
            sessionManager: ARSessionManager,
            measurementEngine: MeasurementEngine,
            captureEngine: ObjectCaptureEngine
        ) {
            self.sessionManager = sessionManager
            self.measurementEngine = measurementEngine
            self.captureEngine = captureEngine
        }

        func attach(to arView: ARView) {
            self.arView = arView
            observedMode = measurementEngine.mode
            observedMeshVisible = captureEngine.isMeshVisible
            observedShowsSelectedPoints = captureEngine.showsSelectedPoints
            createContentAnchorIfNeeded(in: arView)
            updateMeshVisibility()

            aimerUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self, weak arView] _ in
                guard let self, let arView else {
                    return
                }

                Task { @MainActor in
                    self.updateAimerSurface(in: arView)
                    self.updatePlacedPointBillboards(in: arView)
                    self.updateScanLive(in: arView)
                }
            }

            // World-anchor projection is cheap enough to update at display cadence. Vision remains
            // single-flight below, so segmentation runs only as fast as the device can sustain.
            let maskTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak arView] _ in
                guard let self, let arView else {
                    return
                }

                Task { @MainActor in
                    self.updateFastObjectMaskMarkers(in: arView)
                    self.updateObjectMaskPreview(in: arView)
                }
            }
            maskTimer.tolerance = 1.0 / 240.0
            RunLoop.main.add(maskTimer, forMode: .common)
            maskUpdateTimer = maskTimer

            observeEngineRevisions()
        }

        func detach() {
            aimerUpdateTimer?.invalidate()
            aimerUpdateTimer = nil
            maskUpdateTimer?.invalidate()
            maskUpdateTimer = nil
            objectMaskTask?.cancel()
            objectMaskTask = nil
            objectMaskMotionTask?.cancel()
            objectMaskMotionTask = nil
            let motionProcessor = objectMaskMotionProcessor
            Task { await motionProcessor.reset() }
            pendingObjectMaskToggleRequest = nil
            removeAllObjectMaskAnchors()
            captureEngine.updateLockedObjectMaskCount(0)
            captureEngine.updateObjectMaskTracking(visibleCount: 0, markers: [])
            captureEngine.clearObjectMaskPreview()
            clearMeasurementContent()
            clearCaptureContent()

            for marker in selectionPool {
                marker.removeFromParent()
            }
            selectionPool.removeAll()

            if let contentAnchor, let arView {
                arView.scene.removeAnchor(contentAnchor)
            }

            arView = nil
            contentAnchor = nil
        }

        // Direct observation of MeasurementEngine revision counters. Using
        // `withObservationTracking` removes the dependency on SwiftUI choosing to re-render the
        // hosting view (which it would only do if some property read by a view body changed).
        // `placementRequestRevision` and `resetRevision` are not read from any view body, so the
        // previous `updateUIView` path could silently miss button presses.
        private func observeEngineRevisions() {
            withObservationTracking {
                _ = measurementEngine.placementRequestRevision
                _ = measurementEngine.resetRevision
                _ = measurementEngine.mode
                _ = captureEngine.captureRequestRevision
                _ = captureEngine.resetRevision
                _ = captureEngine.objectMaskToggleRequestRevision
                _ = captureEngine.isMeshVisible
                _ = captureEngine.showsSelectedPoints
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    self.observeEngineRevisions()
                    self.handleEngineRevisionChange()
                }
            }
        }

        private func handleEngineRevisionChange() {
            // A mode switch clears whatever the previous tool drew and refreshes the mesh overlay.
            if measurementEngine.mode != observedMode {
                let wasScanning = observedMode == .scan
                observedMode = measurementEngine.mode
                clearMeasurementContent()
                resetScanState()
                updateMeshVisibility()
                if wasScanning {
                    // Drop any stale captured/preview readout when leaving Scan.
                    captureEngine.reset()
                }
            }

            if measurementEngine.resetRevision != observedResetRevision {
                observedResetRevision = measurementEngine.resetRevision
                clearMeasurementContent()
            }

            if measurementEngine.placementRequestRevision != observedPlacementRequestRevision {
                observedPlacementRequestRevision = measurementEngine.placementRequestRevision
                if let arView {
                    placePointAtTarget(in: arView)
                }
            }

            if captureEngine.resetRevision != observedCaptureResetRevision {
                observedCaptureResetRevision = captureEngine.resetRevision
                resetScanState()
            }

            if captureEngine.captureRequestRevision != observedCaptureRequestRevision {
                observedCaptureRequestRevision = captureEngine.captureRequestRevision
                commitScanCapture()
            }

            if captureEngine.objectMaskToggleRequestRevision != observedObjectMaskToggleRequestRevision {
                observedObjectMaskToggleRequestRevision = captureEngine.objectMaskToggleRequestRevision
                pendingObjectMaskToggleRequest = captureEngine.objectMaskToggleRequest
                objectMaskToggleAttemptsRemaining = 4
            }

            if captureEngine.isMeshVisible != observedMeshVisible {
                observedMeshVisible = captureEngine.isMeshVisible
                updateMeshVisibility()
            }

            if captureEngine.showsSelectedPoints != observedShowsSelectedPoints {
                observedShowsSelectedPoints = captureEngine.showsSelectedPoints
                updateSelectionVisualization()
            }
        }

        private func updateMeshVisibility() {
            guard let arView else {
                return
            }

            // The reconstructed mesh overlay is only useful while scanning. RealityKit renders it
            // natively from the LiDAR scene-reconstruction data already enabled on the session.
            let shouldShow = measurementEngine.mode == .scan
                && sessionManager.isSceneReconstructionEnabled
                && captureEngine.isMeshVisible
            if shouldShow {
                arView.debugOptions.insert(.showSceneUnderstanding)
            } else {
                arView.debugOptions.remove(.showSceneUnderstanding)
            }
        }

        /// Offers frames to Vision at display cadence. Only one segmentation may be in flight, so
        /// actual mask throughput is device-dependent and stale frames never queue.
        private func updateObjectMaskPreview(in arView: ARView) {
            guard measurementEngine.mode == .scan,
                  let frame = arView.session.currentFrame else {
                return
            }

            updateObjectMaskMotion(
                pixelBuffer: frame.capturedImage,
                orientation: cameraImageOrientation(in: arView),
                timestamp: frame.timestamp
            )

            guard objectMaskTask == nil else {
                return
            }

            let submittedToggleRequest = pendingObjectMaskToggleRequest
            let toggleRequest = preparedObjectMaskToggleRequest(
                submittedToggleRequest,
                frame: frame,
                in: arView
            )
            let input = ObjectMaskFrame(
                pixelBuffer: frame.capturedImage,
                orientation: cameraImageOrientation(in: arView),
                viewportSize: arView.bounds.size,
                toggleRequest: toggleRequest,
                anchorHints: objectMaskAnchorHints(frame: frame, in: arView),
                timestamp: frame.timestamp,
                trackingGeneration: objectMaskTrackingGeneration,
                depthSnapshot: objectMaskDepthSnapshot(from: frame, in: arView)
            )
            if submittedToggleRequest != nil {
                pendingObjectMaskToggleRequest = nil
                objectMaskToggleAttemptsRemaining = max(objectMaskToggleAttemptsRemaining - 1, 0)
            }
            let processor = objectMaskProcessor
            let motionProcessor = objectMaskMotionProcessor

            objectMaskTask = Task { [weak self] in
                let result = await processor.makePreview(from: input)
                guard let self, !Task.isCancelled else {
                    return
                }

                var motionCorrectionPreview: ObjectMaskPreview?
                if let keyframe = result.motionKeyframe {
                    let catchUp = arView.session.currentFrame.map {
                        ObjectMaskMotionCatchUpFrame(
                            pixelBuffer: $0.capturedImage,
                            orientation: self.cameraImageOrientation(in: arView),
                            timestamp: $0.timestamp
                        )
                    }
                    motionCorrectionPreview = await motionProcessor.install(
                        keyframe,
                        catchUp: catchUp
                    )
                } else if result.lockedObjectCount == 0 {
                    await motionProcessor.reset()
                }
                guard !Task.isCancelled else {
                    return
                }

                self.objectMaskTask = nil
                guard self.measurementEngine.mode == .scan else {
                    return
                }

                let previousLockedObjectCount = self.captureEngine.lockedObjectMaskCount
                self.applyObjectMaskLockChange(result.lockChange, in: arView)
                for cloud in result.maskedPointClouds {
                    var accumulator = self.maskedAccumulators[cloud.id]
                        ?? PointAccumulator(voxelSize: ObjectCapturePipeline.voxelSize)
                    accumulator.add(cloud.points)
                    self.maskedAccumulators[cloud.id] = accumulator
                }
                for marker in result.markers {
                    self.objectMaskMarkerStates[marker.id] = ObjectMaskMarkerState(
                        color: marker.color,
                        isMaskVisible: marker.isMaskVisible
                    )
                }
                self.objectMaskMarkerStates = self.objectMaskMarkerStates.filter {
                    self.objectMaskAnchors[$0.key] != nil
                }
                self.captureEngine.updateLockedObjectMaskCount(result.lockedObjectCount)
                self.captureEngine.updateObjectMaskTracking(
                    visibleCount: result.visibleObjectCount,
                    markers: result.markers
                )
                if submittedToggleRequest != nil,
                   !result.didToggleLock,
                   self.pendingObjectMaskToggleRequest == nil,
                   self.objectMaskToggleAttemptsRemaining > 0 {
                    // Foreground-instance segmentation can miss an object for a single camera
                    // frame. Retry the same tap on a few fresh frames instead of silently losing it.
                    self.pendingObjectMaskToggleRequest = submittedToggleRequest
                } else if submittedToggleRequest != nil,
                          !result.didToggleLock,
                          self.pendingObjectMaskToggleRequest == nil {
                    self.captureEngine.reportObjectLockNotFound()
                } else if result.needsWorldSurface {
                    self.captureEngine.reportObjectLockNeedsSurface()
                }

                // EdgeTAM is the authoritative correction. Between these keyframes, the separate
                // high-rate worker moves each accepted mask with dense optical flow.
                if let preview = motionCorrectionPreview ?? result.preview {
                    self.consecutiveMaskMisses = 0
                    self.captureEngine.showObjectMaskPreview(preview)
                } else {
                    self.consecutiveMaskMisses += 1
                    if result.didToggleLock
                        || result.lockedObjectCount < previousLockedObjectCount
                        || self.consecutiveMaskMisses >= 3 {
                        self.captureEngine.clearObjectMaskPreview()
                    }
                }
            }
        }

        private func updateObjectMaskMotion(
            pixelBuffer: CVPixelBuffer,
            orientation: CGImagePropertyOrientation,
            timestamp: TimeInterval
        ) {
            guard captureEngine.lockedObjectMaskCount > 0,
                  objectMaskMotionTask == nil else {
                return
            }

            let processor = objectMaskMotionProcessor
            objectMaskMotionTask = Task { [weak self] in
                let preview = await processor.propagate(
                    pixelBuffer: pixelBuffer,
                    orientation: orientation,
                    timestamp: timestamp
                )
                guard let self, !Task.isCancelled else {
                    return
                }
                self.objectMaskMotionTask = nil
                guard self.measurementEngine.mode == .scan,
                      self.captureEngine.lockedObjectMaskCount > 0,
                      let preview else {
                    return
                }
                self.captureEngine.showObjectMaskPreview(preview)
            }
        }

        private func updateFastObjectMaskMarkers(in arView: ARView) {
            guard measurementEngine.mode == .scan,
                  let frame = arView.session.currentFrame else {
                captureEngine.updateObjectMaskMarkers([])
                return
            }

            let markers: [ObjectMaskMarker] = objectMaskAnchorHints(
                frame: frame,
                in: arView
            ).compactMap { hint -> ObjectMaskMarker? in
                guard let point = hint.normalizedViewportPoint,
                      let state = objectMaskMarkerStates[hint.id] else {
                    return nil
                }
                return ObjectMaskMarker(
                    id: hint.id,
                    normalizedViewportPoint: point,
                    color: state.color,
                    isMaskVisible: state.isMaskVisible
                )
            }
            captureEngine.updateObjectMaskMarkers(markers)
        }

        private func preparedObjectMaskToggleRequest(
            _ request: ObjectMaskToggleRequest?,
            frame: ARFrame,
            in arView: ARView
        ) -> ObjectMaskToggleRequest? {
            guard let request else {
                return nil
            }

            let viewportPoint = CGPoint(
                x: request.normalizedViewportPoint.x * arView.bounds.width,
                y: request.normalizedViewportPoint.y * arView.bounds.height
            )
            let worldTransform: simd_float4x4
            if let depthPoint = DepthPointCloud.worldPoint(
                from: frame,
                normalizedViewportPoint: request.normalizedViewportPoint,
                interfaceOrientation: interfaceOrientation(in: arView),
                viewportSize: arView.bounds.size
            ) {
                var depthTransform = matrix_identity_float4x4
                depthTransform.columns.3 = SIMD4<Float>(depthPoint, 1)
                worldTransform = depthTransform
            } else if let raycast = bestRaycastResult(from: viewportPoint, in: arView) {
                worldTransform = raycast.worldTransform
            } else if let ray = arView.ray(through: viewportPoint) {
                // RGB locking must not depend on LiDAR or on ARKit having detected a plane. A
                // provisional point along the camera ray gives the visual tracker a world-relative
                // reacquisition hint immediately; non-LiDAR devices can refine their map later.
                let direction = simd_normalize(ray.direction)
                let estimatedDistance = provisionalObjectDistance(
                    rayOrigin: ray.origin,
                    rayDirection: direction,
                    frame: frame
                )
                var provisionalTransform = matrix_identity_float4x4
                provisionalTransform.columns.3 = SIMD4<Float>(
                    ray.origin + direction * estimatedDistance,
                    1
                )
                worldTransform = provisionalTransform
            } else {
                // This should be rare (usually an invalid/zero-sized viewport). Existing locks can
                // still be removed from the raw Vision tap.
                return request
            }

            let distance = simd_distance(
                frame.camera.transform.translation,
                worldTransform.translation
            )
            return ObjectMaskToggleRequest(
                normalizedViewportPoint: request.normalizedViewportPoint,
                proposedLockID: UUID(),
                worldTransform: worldTransform,
                cameraDistance: distance
            )
        }

        /// Estimates distance for an RGB-only provisional anchor from sparse AR feature points
        /// close to the tap ray. A conservative one-metre fallback keeps locking available even in
        /// a texture-poor scene; this estimate is never used as metric object depth.
        private func provisionalObjectDistance(
            rayOrigin: SIMD3<Float>,
            rayDirection: SIMD3<Float>,
            frame: ARFrame
        ) -> Float {
            guard let featurePoints = frame.rawFeaturePoints?.points else {
                return 1.0
            }

            var candidates: [Float] = []
            for point in featurePoints {
                let displacement = point - rayOrigin
                let distanceAlongRay = simd_dot(displacement, rayDirection)
                guard (0.2 ... 4.0).contains(distanceAlongRay) else {
                    continue
                }
                let perpendicular = displacement - rayDirection * distanceAlongRay
                let tolerance = max(0.035, distanceAlongRay * 0.035)
                if simd_length_squared(perpendicular) <= tolerance * tolerance {
                    candidates.append(distanceAlongRay)
                }
            }

            guard !candidates.isEmpty else {
                return 1.0
            }
            candidates.sort()
            // Prefer the nearest coherent surface rather than a wall or table behind the object.
            return candidates[min(candidates.count / 4, candidates.count - 1)]
        }

        private func objectMaskAnchorHints(frame: ARFrame, in arView: ARView) -> [ObjectMaskAnchorHint] {
            let orientation = interfaceOrientation(in: arView)
            let viewportSize = arView.bounds.size
            guard viewportSize.width > 0, viewportSize.height > 0 else {
                return []
            }

            return objectMaskAnchors.map { lockID, anchor in
                let worldPosition = anchor.transform.translation
                let pointInCamera = frame.camera.transform.inverse * SIMD4<Float>(worldPosition, 1)
                let isInFrontOfCamera = pointInCamera.z < -0.02
                let projectedPoint = frame.camera.projectPoint(
                    worldPosition,
                    orientation: orientation,
                    viewportSize: viewportSize
                )
                let normalizedPoint = CGPoint(
                    x: projectedPoint.x / viewportSize.width,
                    y: projectedPoint.y / viewportSize.height
                )
                let isInsideViewport = isInFrontOfCamera
                    && (-0.05 ... 1.05).contains(normalizedPoint.x)
                    && (-0.05 ... 1.05).contains(normalizedPoint.y)
                return ObjectMaskAnchorHint(
                    id: lockID,
                    normalizedViewportPoint: isInsideViewport ? normalizedPoint : nil,
                    cameraDistance: simd_distance(frame.camera.transform.translation, worldPosition),
                    worldPosition: worldPosition
                )
            }
        }

        private func objectMaskDepthSnapshot(
            from frame: ARFrame,
            in arView: ARView
        ) -> ObjectMaskDepthSnapshot? {
            // Raw scene depth is preferred here because it belongs to this exact RGB timestamp.
            // Temporal averaging happens later in the per-object voxel accumulator.
            guard let sceneDepth = frame.sceneDepth ?? frame.smoothedSceneDepth else {
                return nil
            }
            return ObjectMaskDepthSnapshot(
                depthMap: sceneDepth.depthMap,
                confidenceMap: sceneDepth.confidenceMap,
                cameraTransform: frame.camera.transform,
                cameraIntrinsics: frame.camera.intrinsics,
                cameraImageResolution: frame.camera.imageResolution,
                imageToViewportTransform: frame.displayTransform(
                    for: interfaceOrientation(in: arView),
                    viewportSize: arView.bounds.size
                )
            )
        }

        private func applyObjectMaskLockChange(_ change: ObjectMaskLockChange?, in arView: ARView) {
            guard let change else {
                return
            }

            switch change.kind {
            case .added:
                guard let transform = change.worldTransform else {
                    return
                }
                let anchor = ARAnchor(name: "payload-mask-\(change.id.uuidString)", transform: transform)
                arView.session.add(anchor: anchor)
                objectMaskAnchors[change.id] = anchor
            case .removed:
                if let anchor = objectMaskAnchors.removeValue(forKey: change.id) {
                    arView.session.remove(anchor: anchor)
                }
                maskedAccumulators.removeValue(forKey: change.id)
            }
        }

        /// ARKit supplies the rear-camera buffer in its native landscape orientation. Vision needs
        /// the current interface orientation so its selected mask is upright for display.
        private func cameraImageOrientation(in arView: ARView) -> CGImagePropertyOrientation {
            switch interfaceOrientation(in: arView) {
            case .portraitUpsideDown:
                .left
            case .landscapeLeft:
                .up
            case .landscapeRight:
                .down
            case .portrait, .unknown:
                .right
            @unknown default:
                .right
            }
        }

        private func interfaceOrientation(in arView: ARView) -> UIInterfaceOrientation {
            arView.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        }

        /// Throttled live scanning: accumulate depth around the reticle across frames and keep a
        /// running cluster + box so the operator sees what will be captured before pressing Capture.
        private func updateScanLive(in arView: ARView) {
            guard measurementEngine.mode == .scan,
                  sessionManager.isAutomaticObjectCaptureSupported,
                  !isScanFrozen else {
                return
            }

            // The aimer timer fires at 15 Hz; segment roughly every 5th tick (~3 Hz) to keep cost low.
            scanTickCounter &+= 1
            guard scanTickCounter % 5 == 0 else {
                return
            }

            guard sessionManager.isTrackingReady,
                  let frame = arView.session.currentFrame,
                  let aimerTransform = lastAimerRaycastTransform else {
                return
            }

            let seed = aimerTransform.translation
            let selectedLockedObject: (id: UUID, anchor: ARAnchor)?
            if objectMaskAnchors.isEmpty {
                selectedLockedObject = nil
            } else {
                let centeredHint = objectMaskAnchorHints(frame: frame, in: arView)
                    .compactMap { hint -> (hint: ObjectMaskAnchorHint, distance: CGFloat)? in
                        guard let point = hint.normalizedViewportPoint else {
                            return nil
                        }
                        return (hint, hypot(point.x - 0.5, point.y - 0.5))
                    }
                    .min { $0.distance < $1.distance }?.hint
                guard let centeredHint,
                      let anchor = objectMaskAnchors[centeredHint.id] else {
                    // Locked masks exist, but none is currently visible. Never substitute an
                    // unrelated raw cloud while the selected object is outside the camera.
                    return
                }
                selectedLockedObject = (centeredHint.id, anchor)
            }
            let gatherSeed = selectedLockedObject?.anchor.transform.translation ?? seed

            // If the operator has aimed at a clearly different place (farther than the gather
            // radius), start a fresh accumulation. This keeps the buffer bounded and makes the tool
            // track the object currently being aimed at instead of piling up the whole scene.
            if let anchor = accumulationAnchor {
                let deltaX = gatherSeed.x - anchor.x
                let deltaZ = gatherSeed.z - anchor.z
                let jump = ObjectCapturePipeline.accumulationRadius
                if deltaX * deltaX + deltaZ * deltaZ > jump * jump {
                    // Re-aiming the LiDAR capture box must not erase independently locked object
                    // masks. Only reset the depth accumulator here.
                    resetCaptureAccumulation()
                }
            }
            if accumulationAnchor == nil {
                accumulationAnchor = gatherSeed
            }

            let points = DepthPointCloud.worldPoints(
                from: frame,
                near: gatherSeed,
                radius: ObjectCapturePipeline.accumulationRadius
            )

            guard !points.isEmpty else {
                return
            }

            accumulator.add(points)

            // Every ~3 s (at this ~3 Hz cadence), drop voxels seen only once: transient noise that
            // was never reconfirmed. This bounds the buffer and keeps the box from creeping outward.
            if scanTickCounter % 45 == 0 {
                accumulator.pruneTransient(below: 2)
            }

            let supportPoints = accumulator.points(
                minObservations: ObjectCapturePipeline.minObservations
            )
            let captureOutcome: CaptureOutcome
            if let lockedObject = selectedLockedObject {
                let lockID = lockedObject.id
                let objectSeed = lockedObject.anchor.transform.translation
                if selectedCaptureMaskID != lockID {
                    selectedCaptureMaskID = lockID
                    clearCaptureContent()
                    liveResult = nil
                    captureEngine.clearPreview()
                }
                // Once a mask is locked there is intentionally no raw-depth fallback: falling back
                // would silently reintroduce the table/bigger-object failure this path prevents.
                guard let objectPoints = maskedAccumulators[lockID]?.points(minObservations: 2),
                      !objectPoints.isEmpty else {
                    return
                }
                captureOutcome = ObjectCapturePipeline.capture(
                    objectPoints: objectPoints,
                    supportPoints: supportPoints,
                    seed: objectSeed,
                    up: SIMD3<Float>(0, 1, 0)
                )
            } else {
                selectedCaptureMaskID = nil
                captureOutcome = ObjectCapturePipeline.capture(
                    points: supportPoints,
                    seed: seed,
                    up: SIMD3<Float>(0, 1, 0)
                )
            }

            // ARKit world Y is gravity-aligned (`.gravity` world alignment), so up is (0, 1, 0).
            guard case .success(let result) = captureOutcome else {
                return
            }

            liveResult = result
            createContentAnchorIfNeeded(in: arView)
            addCapturedBox(result.object)
            lastSelectionPoints = result.selectionPoints
            updateSelectionVisualization()
            captureEngine.showPreview(result.object)
        }

        /// Locks in the latest live result as the committed capture and stops live updating.
        private func commitScanCapture() {
            guard sessionManager.isTrackingReady else {
                captureEngine.reportTrackingNotReady()
                return
            }

            guard let liveResult else {
                captureEngine.reportNotEnoughMesh()
                return
            }

            isScanFrozen = true
            captureEngine.applyCapture(liveResult.object)
            // The box and selection markers are already rendered from the last live tick.
        }

        private func resetScanState() {
            resetCaptureAccumulation()
            resetObjectMaskTracking()
        }

        private func resetCaptureAccumulation() {
            clearCaptureContent()
            accumulator.reset()
            liveResult = nil
            accumulationAnchor = nil
            selectedCaptureMaskID = nil
            isScanFrozen = false
            scanTickCounter = 0
            captureEngine.clearPreview()
        }

        private func resetObjectMaskTracking() {
            objectMaskTrackingGeneration &+= 1
            objectMaskMotionTask?.cancel()
            objectMaskMotionTask = nil
            let motionProcessor = objectMaskMotionProcessor
            Task { await motionProcessor.reset() }
            pendingObjectMaskToggleRequest = nil
            consecutiveMaskMisses = 0
            maskedAccumulators.removeAll()
            removeAllObjectMaskAnchors()
            objectMaskMarkerStates.removeAll()
            captureEngine.updateLockedObjectMaskCount(0)
            captureEngine.updateObjectMaskTracking(visibleCount: 0, markers: [])
            captureEngine.clearObjectMaskPreview()
        }

        private func removeAllObjectMaskAnchors() {
            guard let arView else {
                objectMaskAnchors.removeAll()
                return
            }
            for anchor in objectMaskAnchors.values {
                arView.session.remove(anchor: anchor)
            }
            objectMaskAnchors.removeAll()
            objectMaskMarkerStates.removeAll()
            maskedAccumulators.removeAll()
        }

        private func placePointAtTarget(in arView: ARView) {
            guard sessionManager.isTrackingReady else {
                measurementEngine.reportTrackingNotReady()
                return
            }

            if !measurementEngine.canAcceptPoint {
                measurementEngine.reset()
                clearMeasurementContent()
                observedResetRevision = measurementEngine.resetRevision
            }

            let targetLocation = centerPoint(in: arView)

            // The visible aimer already represents a successful center raycast. Use its cached
            // transform as the primary source of truth so the marker always lands exactly where
            // the user sees the aimer, even if a fresh raycast transiently fails on this frame.
            // Fall back to a fresh raycast only when the aimer cache is absent.
            let initialTransform: simd_float4x4
            if let cached = lastAimerRaycastTransform {
                initialTransform = cached
            } else if let immediate = bestRaycastResult(from: targetLocation, in: arView) {
                initialTransform = immediate.worldTransform
            } else {
                measurementEngine.reportPlacementFailure()
                return
            }

            createContentAnchorIfNeeded(in: arView)

            let position = initialTransform.translation
            let pointID = measurementEngine.addPoint(at: position)
            let placedPoint = addMarker(id: pointID, transform: initialTransform)
            placedPoints.append(placedPoint)
            updateMeasurementVisual()
            startRefining(pointID: pointID, targetLocation: targetLocation, in: arView)
        }

        private func createContentAnchorIfNeeded(in arView: ARView) {
            guard contentAnchor == nil else {
                return
            }

            let anchor = AnchorEntity(world: .zero)
            arView.scene.addAnchor(anchor)
            contentAnchor = anchor
        }

        private func centerPoint(in arView: ARView) -> CGPoint {
            CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        }

        private func updateAimerSurface(in arView: ARView) {
            guard let result = bestRaycastResult(from: centerPoint(in: arView), in: arView) else {
                previewTargetPosition = nil
                lastAimerRaycastTransform = nil
                clearPreviewMeasurementEntities()
                measurementEngine.updateAimerSurface(
                    scaleY: 1,
                    rotationDegrees: 0,
                    distanceScale: 1,
                    isDetected: false
                )
                return
            }

            previewTargetPosition = result.worldTransform.translation
            lastAimerRaycastTransform = result.worldTransform
            let surfaceNormal = SIMD3<Float>(
                result.worldTransform.columns.1.x,
                result.worldTransform.columns.1.y,
                result.worldTransform.columns.1.z
            )
            let normalizedNormal = simd_length(surfaceNormal) > 0 ? simd_normalize(surfaceNormal) : SIMD3<Float>(0, 1, 0)
            let cameraDirection = simd_normalize(arView.cameraTransform.translation - result.worldTransform.translation)
            let facingAmount = abs(simd_dot(normalizedNormal, cameraDirection))
            let scaleY = Double(min(max(0.34 + facingAmount * 0.66, 0.34), 1.0))
            let distance = simd_distance(arView.cameraTransform.translation, result.worldTransform.translation)
            // Inverse-distance scaling so the aimer behaves like a fixed-world-size disc projected
            // onto the screen: closer surfaces enlarge the aimer, farther surfaces shrink it.
            let referenceDistance: Float = 0.7
            let safeDistance = max(distance, 0.15)
            let distanceScale = Double(min(max(referenceDistance / safeDistance, 0.55), 1.8))
            // The aimer's squish axis should follow the surface's tilt as seen in the camera image,
            // not the world-space yaw of the normal. Transform the world normal into camera space,
            // project it onto the camera image plane (SwiftUI Y is inverted relative to camera Y),
            // and rotate so the squish direction aligns with the projected tilt.
            let inverseCamera = arView.cameraTransform.matrix.inverse
            let normalInCamera4 = inverseCamera * SIMD4<Float>(normalizedNormal, 0)
            let normalInCamera = SIMD3<Float>(normalInCamera4.x, normalInCamera4.y, normalInCamera4.z)
            let projectedLength = hypot(normalInCamera.x, normalInCamera.y)
            let rotation: Double = projectedLength > 0.05
                ? Double(atan2(normalInCamera.x, -normalInCamera.y) * 180 / .pi)
                : 0

            measurementEngine.updateAimerSurface(
                scaleY: scaleY,
                rotationDegrees: rotation,
                distanceScale: distanceScale,
                isDetected: true
            )
            updatePreviewMeasurementVisual()
        }

        private func bestRaycastResult(from point: CGPoint, in arView: ARView) -> ARRaycastResult? {
            if let detectedSurface = arView.raycast(
                from: point,
                allowing: .existingPlaneGeometry,
                alignment: .any
            ).first {
                return detectedSurface
            }

            return arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first
        }

        private func startRefining(pointID: UUID, targetLocation: CGPoint, in arView: ARView) {
            guard let trackedRaycast = arView.trackedRaycast(
                from: targetLocation,
                allowing: .estimatedPlane,
                alignment: .any,
                updateHandler: { [weak self] results in
                    Task { @MainActor in
                        self?.applyRefinedResult(results.first, to: pointID)
                    }
                }
            ) else {
                measurementEngine.finishRefiningPoint(id: pointID)
                return
            }

            updateTrackedRaycast(trackedRaycast, for: pointID)

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                stopRefining(pointID: pointID)
            }
        }

        private func applyRefinedResult(_ result: ARRaycastResult?, to pointID: UUID) {
            guard let result,
                  let index = placedPoints.firstIndex(where: { $0.id == pointID }) else {
                return
            }

            let position = result.worldTransform.translation
            placedPoints[index].latestTransform = result.worldTransform
            placedPoints[index].marker.position = position
            if let arView {
                orientBillboard(placedPoints[index].marker, at: position, in: arView)
            }
            measurementEngine.updatePoint(id: pointID, position: position)
            updateMeasurementVisual()
        }

        private func stopRefining(pointID: UUID) {
            guard let index = placedPoints.firstIndex(where: { $0.id == pointID }) else {
                return
            }

            placedPoints[index].trackedRaycast?.stopTracking()
            placedPoints[index].trackedRaycast = nil
            lockPointToARAnchor(at: index)
            measurementEngine.finishRefiningPoint(id: pointID)
        }

        private func updateTrackedRaycast(_ trackedRaycast: ARTrackedRaycast, for pointID: UUID) {
            guard let index = placedPoints.firstIndex(where: { $0.id == pointID }) else {
                trackedRaycast.stopTracking()
                return
            }

            placedPoints[index].trackedRaycast = trackedRaycast
        }

        private func addMarker(id: UUID, transform: simd_float4x4) -> PlacedPoint {
            let marker = ModelEntity(
                mesh: .generatePlane(width: 0.014, depth: 0.014, cornerRadius: 0.007),
                materials: [Coordinator.iceWhiteMaterial]
            )
            marker.position = transform.translation
            if let arView {
                orientBillboard(marker, at: transform.translation, in: arView)
            }
            contentAnchor?.addChild(marker)
            return PlacedPoint(
                id: id,
                marker: marker,
                anchorEntity: nil,
                arAnchor: nil,
                latestTransform: transform,
                trackedRaycast: nil
            )
        }

        private func lockPointToARAnchor(at index: Int) {
            guard let arView,
                  placedPoints[index].anchorEntity == nil else {
                return
            }

            let pointID = placedPoints[index].id
            let marker = placedPoints[index].marker
            let latestTransform = placedPoints[index].latestTransform
            let arAnchor = ARAnchor(
                name: "MeasurementPoint-\(pointID.uuidString)",
                transform: latestTransform
            )
            let anchorEntity = AnchorEntity(anchor: arAnchor)

            arView.session.add(anchor: arAnchor)
            arView.scene.addAnchor(anchorEntity)

            marker.removeFromParent()
            marker.position = .zero
            anchorEntity.addChild(marker)
            orientBillboard(marker, at: latestTransform.translation, in: arView)

            placedPoints[index].arAnchor = arAnchor
            placedPoints[index].anchorEntity = anchorEntity
            measurementEngine.updatePoint(id: pointID, position: latestTransform.translation)
            updateMeasurementVisual()
        }

        private func updateMeasurementVisual() {
            clearMeasurementEntities()
            clearPreviewMeasurementEntities()

            guard measurementEngine.points.count == 2 else {
                updatePreviewMeasurementVisual()
                return
            }

            switch measurementEngine.mode {
            case .line:
                addDashedLine(from: measurementEngine.points[0].position, to: measurementEngine.points[1].position)
            case .boundingBox:
                addBoundingBox(from: measurementEngine.points[0].position, to: measurementEngine.points[1].position)
            case .scan:
                // Scan mode draws its captured box separately; nothing to do for tapped points.
                break
            }
        }

        private func updatePreviewMeasurementVisual() {
            clearPreviewMeasurementEntities()

            guard measurementEngine.points.count == 1,
                  let previewTargetPosition else {
                return
            }

            addDashedLine(
                from: measurementEngine.points[0].position,
                to: previewTargetPosition,
                into: &previewMeasurementEntities
            )
        }

        private func addBoundingBox(from firstCorner: SIMD3<Float>, to secondCorner: SIMD3<Float>) {
            let minCorner = simd_min(firstCorner, secondCorner)
            let maxCorner = simd_max(firstCorner, secondCorner)

            let corners: [SIMD3<Float>] = [
                SIMD3<Float>(minCorner.x, minCorner.y, minCorner.z),
                SIMD3<Float>(maxCorner.x, minCorner.y, minCorner.z),
                SIMD3<Float>(maxCorner.x, minCorner.y, maxCorner.z),
                SIMD3<Float>(minCorner.x, minCorner.y, maxCorner.z),
                SIMD3<Float>(minCorner.x, maxCorner.y, minCorner.z),
                SIMD3<Float>(maxCorner.x, maxCorner.y, minCorner.z),
                SIMD3<Float>(maxCorner.x, maxCorner.y, maxCorner.z),
                SIMD3<Float>(minCorner.x, maxCorner.y, maxCorner.z)
            ]

            let edges = [
                (0, 1), (1, 2), (2, 3), (3, 0),
                (4, 5), (5, 6), (6, 7), (7, 4),
                (0, 4), (1, 5), (2, 6), (3, 7)
            ]

            for edge in edges {
                addDashedLine(from: corners[edge.0], to: corners[edge.1], radius: 0.0012)
            }
        }

        private func addDashedLine(
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            radius: Float = 0.0015,
            into targetEntities: inout [ModelEntity]
        ) {
            let delta = end - start
            let length = simd_length(delta)

            guard length > 0.001 else {
                return
            }

            let direction = simd_normalize(delta)
            let width = max(radius * 2.0, 0.002)
            let dashLength: Float = 0.035
            let gapLength: Float = 0.02
            let stepLength = dashLength + gapLength
            var distance: Float = 0

            while distance < length {
                let segmentLength = min(dashLength, length - distance)
                let segmentCenter = start + direction * (distance + segmentLength / 2)
                let dash = ModelEntity(
                    mesh: .generatePlane(width: segmentLength, depth: width, cornerRadius: width / 2),
                    materials: [Coordinator.iceWhiteMaterial]
                )
                dash.position = segmentCenter
                dash.orientation = lineOrientation(at: segmentCenter, direction: direction)

                contentAnchor?.addChild(dash)
                targetEntities.append(dash)
                distance += stepLength
            }
        }

        private func addDashedLine(
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            radius: Float = 0.0015
        ) {
            addDashedLine(from: start, to: end, radius: radius, into: &measurementEntities)
        }

        private func updatePlacedPointBillboards(in arView: ARView) {
            for placedPoint in placedPoints {
                let worldPosition = placedPoint.marker.transformMatrix(relativeTo: nil).translation
                orientBillboard(placedPoint.marker, at: worldPosition, in: arView)
                syncAnchoredPositionIfNeeded(for: placedPoint, worldPosition: worldPosition)
            }
        }

        private func syncAnchoredPositionIfNeeded(for placedPoint: PlacedPoint, worldPosition: SIMD3<Float>) {
            guard placedPoint.anchorEntity != nil,
                  let storedPosition = measurementEngine.points.first(where: { $0.id == placedPoint.id })?.position,
                  simd_distance(storedPosition, worldPosition) > 0.001 else {
                return
            }

            measurementEngine.updatePoint(id: placedPoint.id, position: worldPosition)
            updateMeasurementVisual()
        }

        private func orientBillboard(_ entity: Entity, at position: SIMD3<Float>, in arView: ARView) {
            let cameraDirection = arView.cameraTransform.translation - position
            guard simd_length(cameraDirection) > 0 else {
                return
            }

            let orientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: simd_normalize(cameraDirection)
            )
            entity.setOrientation(orientation, relativeTo: nil)
        }

        private func lineOrientation(at position: SIMD3<Float>, direction: SIMD3<Float>) -> simd_quatf {
            guard let arView else {
                return simd_quatf(from: SIMD3<Float>(1, 0, 0), to: direction)
            }

            let cameraDirection = simd_normalize(arView.cameraTransform.translation - position)
            let projectedNormal = cameraDirection - direction * simd_dot(cameraDirection, direction)
            let fallbackNormal = SIMD3<Float>(0, 1, 0)
            let yAxis = simd_length(projectedNormal) > 0.001 ? simd_normalize(projectedNormal) : fallbackNormal
            let zAxis = simd_normalize(simd_cross(direction, yAxis))
            let correctedYAxis = simd_normalize(simd_cross(zAxis, direction))

            let matrix = simd_float3x3(columns: (
                direction,
                correctedYAxis,
                zAxis
            ))

            return simd_quatf(matrix)
        }

        private func clearMeasurementContent() {
            stopTrackedRaycasts()

            for placedPoint in placedPoints {
                if let arAnchor = placedPoint.arAnchor {
                    arView?.session.remove(anchor: arAnchor)
                }

                placedPoint.anchorEntity?.removeFromParent()
                placedPoint.marker.removeFromParent()
            }

            clearMeasurementEntities()
            clearPreviewMeasurementEntities()
            placedPoints.removeAll()
        }

        private func clearMeasurementEntities() {
            for entity in measurementEntities {
                entity.removeFromParent()
            }

            measurementEntities.removeAll()
        }

        private func clearPreviewMeasurementEntities() {
            for entity in previewMeasurementEntities {
                entity.removeFromParent()
            }

            previewMeasurementEntities.removeAll()
        }

        private func addCapturedBox(_ object: CapturedObject) {
            clearCaptureContent()

            guard object.corners.count == 8 else {
                return
            }

            // Edges for the `i + 2*j + 4*k` corner layout: base face, top face, vertical edges.
            let edges = [
                (0, 1), (1, 3), (2, 3), (0, 2),
                (4, 5), (5, 7), (6, 7), (4, 6),
                (0, 4), (1, 5), (2, 6), (3, 7)
            ]

            for edge in edges {
                addCapturedBoxEdge(from: object.corners[edge.0], to: object.corners[edge.1])
            }
        }

        private func addCapturedBoxEdge(from start: SIMD3<Float>, to end: SIMD3<Float>) {
            let delta = end - start
            let length = simd_length(delta)

            guard length > 0.001 else {
                return
            }

            // A thin 3D bar (rather than a flat strip) so the box reads correctly from any angle as
            // the operator walks around the captured object. Reuses a shared unit cube, scaled to
            // length, because the box is rebuilt on every live tick.
            let thickness: Float = 0.006
            let bar = ModelEntity(
                mesh: Coordinator.unitCubeMesh,
                materials: [Coordinator.captureMaterial]
            )
            bar.scale = SIMD3<Float>(length, thickness, thickness)
            bar.position = start + delta / 2
            bar.orientation = orientation(alongX: delta)

            contentAnchor?.addChild(bar)
            captureEntities.append(bar)
        }

        /// A rotation that maps a box's local +X axis onto `direction`, built from a stable
        /// orthonormal basis. Unlike `simd_quatf(from:to:)` this stays well-defined when the
        /// direction points opposite the reference axis (e.g. a box edge along world -X).
        private func orientation(alongX direction: SIMD3<Float>) -> simd_quatf {
            let xAxis = simd_normalize(direction)
            var reference = SIMD3<Float>(0, 1, 0)
            if abs(simd_dot(xAxis, reference)) > 0.99 {
                reference = SIMD3<Float>(1, 0, 0)
            }
            let zAxis = simd_normalize(simd_cross(xAxis, reference))
            let yAxis = simd_cross(zAxis, xAxis)
            return simd_quatf(simd_float3x3(columns: (xAxis, yAxis, zAxis)))
        }

        private func clearCaptureContent() {
            for entity in captureEntities {
                entity.removeFromParent()
            }

            captureEntities.removeAll()
            hideAllSelectionMarkers()
            lastSelectionPoints = []
        }

        /// Updates the cyan markers showing which voxel cluster the last capture selected. Reuses a
        /// persistent pool of entities (repositioning and enabling/disabling them) instead of
        /// recreating entities every live tick, which would churn hundreds of allocations per second.
        private func updateSelectionVisualization() {
            guard captureEngine.showsSelectedPoints, !lastSelectionPoints.isEmpty,
                  let contentAnchor else {
                hideAllSelectionMarkers()
                return
            }

            // Keep the visible marker count bounded; stride through the voxel centers when over the cap.
            let maxMarkers = 250
            let step = max(1, lastSelectionPoints.count / maxMarkers)

            var shown = 0
            var index = 0
            while index < lastSelectionPoints.count {
                let marker: ModelEntity
                if shown < selectionPool.count {
                    marker = selectionPool[shown]
                } else {
                    marker = ModelEntity(
                        mesh: Coordinator.selectionMarkerMesh,
                        materials: [Coordinator.selectionMaterial]
                    )
                    contentAnchor.addChild(marker)
                    selectionPool.append(marker)
                }
                marker.position = lastSelectionPoints[index]
                marker.isEnabled = true
                shown += 1
                index += step
            }

            for poolIndex in shown..<selectionPool.count {
                selectionPool[poolIndex].isEnabled = false
            }
        }

        private func hideAllSelectionMarkers() {
            for marker in selectionPool {
                marker.isEnabled = false
            }
        }

        private func stopTrackedRaycasts() {
            for index in placedPoints.indices {
                placedPoints[index].trackedRaycast?.stopTracking()
                placedPoints[index].trackedRaycast = nil
            }
        }
    }
}

private extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

private extension Transform {
    var translation: SIMD3<Float> {
        matrix.translation
    }
}
