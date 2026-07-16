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
        // Cyan for the selected-cluster debug markers, so it is clearly separate from the box.
        fileprivate static let selectionMaterial = UnlitMaterial(color: .cyan, applyPostProcessToneMap: false)
        // Small dots expose the admitted LiDAR samples without covering the object. The previous
        // 2 cm cubes obscured both the mask and the fitted box at typical payload distances.
        fileprivate static let selectionMarkerMesh = MeshResource.generateSphere(radius: 0.0035)
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
        private var captureEntitiesByObject: [UUID: [ModelEntity]] = [:]
        private var selectionPool: [ModelEntity] = []
        private var lastSelectionPoints: [SIMD3<Float>] = []
        private var supportAccumulators: [UUID: PointAccumulator] = [:]
        private var maskedAccumulators: [UUID: PointAccumulator] = [:]
        private var newestMaskedPointTimestamp: [UUID: TimeInterval] = [:]
        private var fittedMaskedPointTimestamp: [UUID: TimeInterval] = [:]
        private var liveResultsByObject: [UUID: CaptureResult] = [:]
        private let objectMaskProcessor = ObjectMaskProcessor()
        private var scanTickCounter = 0
        private var consecutiveMaskMisses = 0
        private var objectMaskTask: Task<Void, Never>?
        private var pendingObjectMaskToggleRequest: ObjectMaskToggleRequest?
        private var objectMaskToggleAttemptsRemaining = 0
        private var objectMaskAnchors: [UUID: ARAnchor] = [:]
        private var objectMaskMarkerStates: [UUID: ObjectMaskMarkerState] = [:]
        private var objectMaskTrackingGeneration = 0
        private var previewTargetPosition: SIMD3<Float>?
        private var lastAimerRaycastTransform: simd_float4x4?
        private var aimerUpdateTimer: Timer?
        private var maskUpdateTimer: Timer?
        private var memoryWarningObserver: NSObjectProtocol?
        private var observedResetRevision = 0
        private var observedPlacementRequestRevision = 0
        private var observedMode: MeasurementMode = .scan
        private var observedCaptureRequestRevision = 0
        private var observedCaptureResetRevision = 0
        private var observedObjectMaskToggleRequestRevision = 0
        private var observedMeshVisible = false
        private var observedShowsSelectedPoints = false
        private var observedShowsBoundingBoxes = true

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
            observedShowsBoundingBoxes = captureEngine.showsBoundingBoxes
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

            memoryWarningObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.releaseRebuildableScanCaches()
                }
            }

            observeEngineRevisions()
        }

        func detach() {
            aimerUpdateTimer?.invalidate()
            aimerUpdateTimer = nil
            maskUpdateTimer?.invalidate()
            maskUpdateTimer = nil
            if let memoryWarningObserver {
                NotificationCenter.default.removeObserver(memoryWarningObserver)
                self.memoryWarningObserver = nil
            }
            objectMaskTask?.cancel()
            objectMaskTask = nil
            pendingObjectMaskToggleRequest = nil
            removeAllObjectMaskAnchors()
            captureEngine.updateLockedObjectMaskCount(0)
            captureEngine.updateObjectMaskTracking(visibleCount: 0, markers: [])
            captureEngine.clearObjectMaskPreview()
            clearMeasurementContent()
            clearAllCaptureContent()

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

        /// Keeps lock identities and already rendered boxes, but drops data that fresh synchronized
        /// frames can reconstruct. This is preferable to iOS terminating the process under stress.
        private func releaseRebuildableScanCaches() {
            objectMaskTask?.cancel()
            objectMaskTask = nil
            supportAccumulators.removeAll(keepingCapacity: false)
            maskedAccumulators.removeAll(keepingCapacity: false)
            newestMaskedPointTimestamp.removeAll(keepingCapacity: false)
            fittedMaskedPointTimestamp.removeAll(keepingCapacity: false)
            liveResultsByObject.removeAll(keepingCapacity: false)
            captureEngine.clearObjectMaskPreview()
            lastSelectionPoints.removeAll(keepingCapacity: false)
            for marker in selectionPool {
                marker.removeFromParent()
            }
            selectionPool.removeAll(keepingCapacity: false)
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
                _ = captureEngine.showsBoundingBoxes
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

            if captureEngine.showsBoundingBoxes != observedShowsBoundingBoxes {
                observedShowsBoundingBoxes = captureEngine.showsBoundingBoxes
                updateCaptureBoxVisibility()
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

            let orientation = cameraImageOrientation(in: arView)
            let viewportSize = arView.bounds.size
            let imageToViewportTransform = frame.displayTransform(
                for: interfaceOrientation(in: arView),
                viewportSize: viewportSize
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
                orientation: orientation,
                viewportSize: viewportSize,
                imageToViewportTransform: imageToViewportTransform,
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

            objectMaskTask = Task { [weak self] in
                let result = await processor.makePreview(from: input)
                guard let self, !Task.isCancelled else {
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
                        ?? PointAccumulator(
                            voxelSize: ObjectCapturePipeline.voxelSize,
                            maxVoxels: 10_000
                        )
                    accumulator.add(cloud.points)
                    self.maskedAccumulators[cloud.id] = accumulator
                    self.newestMaskedPointTimestamp[cloud.id] = max(
                        self.newestMaskedPointTimestamp[cloud.id] ?? -.greatestFiniteMagnitude,
                        cloud.timestamp
                    )
                }
                for marker in result.markers {
                    self.objectMaskMarkerStates[marker.id] = ObjectMaskMarkerState(
                        color: marker.color,
                        isMaskVisible: marker.isMaskVisible
                    )
                }
                let correctedMarkerIDs = Set(result.markers.map(\.id))
                for id in Array(self.objectMaskMarkerStates.keys)
                where !correctedMarkerIDs.contains(id) {
                    guard let state = self.objectMaskMarkerStates[id] else { continue }
                    self.objectMaskMarkerStates[id] = ObjectMaskMarkerState(
                        color: state.color,
                        isMaskVisible: false
                    )
                }
                self.objectMaskMarkerStates = self.objectMaskMarkerStates.filter {
                    self.objectMaskAnchors[$0.key] != nil
                }
                self.captureEngine.updateLockedObjectMaskCount(result.lockedObjectCount)
                self.captureEngine.updateObjectMaskTracking(
                    visibleCount: result.visibleObjectCount,
                    markers: self.currentObjectMaskMarkers(in: arView)
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
                    if result.lockedObjectCount >= 15 {
                        self.captureEngine.reportObjectLimitReached()
                    } else {
                        self.captureEngine.reportObjectLockNotFound()
                    }
                } else if result.needsWorldSurface {
                    self.captureEngine.reportObjectLockNeedsSurface()
                }

                if submittedToggleRequest != nil, let lockChange = result.lockChange {
                    switch lockChange.kind {
                    case .added:
                        self.captureEngine.finishObjectSelection(didAdd: true)
                    case .removed:
                        self.captureEngine.finishObjectSelection(didAdd: false)
                    }
                }

                // Pixel shapes come only from exact segmentation frames. Between corrections,
                // SwiftUI reprojects each locked layer from its own AR anchor; no optical-flow warp
                // can merge identities or feed an invented boundary into LiDAR measurement.
                if let preview = result.preview {
                    self.consecutiveMaskMisses = 0
                    self.captureEngine.showObjectMaskPreview(preview)
                } else {
                    self.consecutiveMaskMisses += 1
                    self.captureEngine.clearLiveObjectMaskPreview()
                    if result.lockedObjectCount == 0,
                       result.didToggleLock
                        || result.lockedObjectCount < previousLockedObjectCount
                        || self.consecutiveMaskMisses >= 3 {
                        self.captureEngine.clearObjectMaskPreview()
                    }
                }
            }
        }

        private func updateFastObjectMaskMarkers(in arView: ARView) {
            guard measurementEngine.mode == .scan else {
                captureEngine.updateObjectMaskMarkers([])
                return
            }
            captureEngine.updateObjectMaskMarkers(currentObjectMaskMarkers(in: arView))
        }

        private func currentObjectMaskMarkers(in arView: ARView) -> [ObjectMaskMarker] {
            guard let frame = arView.session.currentFrame else {
                return []
            }
            return objectMaskAnchorHints(
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
                    cameraDistance: hint.cameraDistance,
                    color: state.color,
                    isMaskVisible: state.isMaskVisible
                )
            }
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
                if let previousAnchor = objectMaskAnchors.removeValue(forKey: change.id) {
                    arView.session.remove(anchor: previousAnchor)
                }
                maskedAccumulators.removeValue(forKey: change.id)
                supportAccumulators[change.id] = PointAccumulator(
                    voxelSize: ObjectCapturePipeline.supportVoxelSize,
                    maxVoxels: 4_000
                )
                newestMaskedPointTimestamp.removeValue(forKey: change.id)
                fittedMaskedPointTimestamp.removeValue(forKey: change.id)
                liveResultsByObject.removeValue(forKey: change.id)
                let anchor = ARAnchor(name: "payload-mask-\(change.id.uuidString)", transform: transform)
                arView.session.add(anchor: anchor)
                objectMaskAnchors[change.id] = anchor
            case .removed:
                if let anchor = objectMaskAnchors.removeValue(forKey: change.id) {
                    arView.session.remove(anchor: anchor)
                }
                maskedAccumulators.removeValue(forKey: change.id)
                supportAccumulators.removeValue(forKey: change.id)
                newestMaskedPointTimestamp.removeValue(forKey: change.id)
                fittedMaskedPointTimestamp.removeValue(forKey: change.id)
                liveResultsByObject.removeValue(forKey: change.id)
                clearCaptureContent(for: change.id)
                captureEngine.removeObjectMaskLayer(id: change.id)
                captureEngine.removeCapture(id: change.id)
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

        /// Updates every visible locked object from one LiDAR frame. Scene depth is back-projected
        /// once and partitioned around the world anchors; each target then owns independent support
        /// and mask-approved accumulators, so neighbouring objects cannot overwrite one another.
        private func updateScanLive(in arView: ARView) {
            guard measurementEngine.mode == .scan,
                  sessionManager.isAutomaticObjectCaptureSupported else {
                return
            }

            scanTickCounter &+= 1

            guard sessionManager.isTrackingReady,
                  let frame = arView.session.currentFrame,
                  !objectMaskAnchors.isEmpty else {
                return
            }

            let visibleHints = objectMaskAnchorHints(frame: frame, in: arView).filter {
                $0.normalizedViewportPoint != nil
            }
            let seeds = Dictionary(uniqueKeysWithValues: visibleHints.compactMap { hint in
                objectMaskAnchors[hint.id].map { (hint.id, $0.transform.translation) }
            })
            guard !seeds.isEmpty else {
                return
            }

            let supportPointsByObject = DepthPointCloud.worldPoints(
                from: frame,
                near: seeds,
                radius: ObjectCapturePipeline.accumulationRadius,
                pixelStride: 3
            )

            for (id, points) in supportPointsByObject where !points.isEmpty {
                var support = supportAccumulators[id]
                    ?? PointAccumulator(
                        voxelSize: ObjectCapturePipeline.supportVoxelSize,
                        maxVoxels: 4_000
                    )
                support.add(points)
                if scanTickCounter % 45 == 0 {
                    support.pruneTransient(below: 2, olderThan: 8)
                    support.pruneStale(olderThan: 90)
                }
                supportAccumulators[id] = support
            }

            if scanTickCounter % 45 == 0 {
                for id in Array(maskedAccumulators.keys) {
                    guard var masked = maskedAccumulators[id] else { continue }
                    masked.pruneTransient(below: 2, olderThan: 8)
                    // Keep roughly a full walk-around rather than only the most recent face. This
                    // remains finite, but preserves side and vertical samples while the operator
                    // moves to a second viewpoint.
                    masked.pruneStale(olderThan: 180)
                    maskedAccumulators[id] = masked
                }
            }

            createContentAnchorIfNeeded(in: arView)
            for hint in visibleHints {
                let id = hint.id
                guard let maskTimestamp = newestMaskedPointTimestamp[id],
                      maskTimestamp > fittedMaskedPointTimestamp[id, default: -.greatestFiniteMagnitude],
                      let objectPoints = maskedAccumulators[id]?.points(minObservations: 2),
                      let supportPoints = supportAccumulators[id]?.points(
                          minObservations: ObjectCapturePipeline.minObservations
                      ),
                      !objectPoints.isEmpty,
                      !supportPoints.isEmpty,
                      let anchor = objectMaskAnchors[id] else {
                    continue
                }

                let outcome = ObjectCapturePipeline.capture(
                    objectPoints: objectPoints,
                    supportPoints: supportPoints,
                    seed: anchor.transform.translation,
                    up: SIMD3<Float>(0, 1, 0)
                )
                guard case .success(let result) = outcome else {
                    continue
                }

                fittedMaskedPointTimestamp[id] = maskTimestamp
                if let previous = liveResultsByObject[id],
                   !isPlausibleBoxRefinement(result.object, from: previous.object) {
                    // Keep the last stable box. Fresh mask/depth frames can still shrink it or
                    // propose a bounded refinement on the next update.
                    continue
                }
                liveResultsByObject[id] = result
                addCapturedBox(result.object, for: id)
                captureEngine.updateCapture(id: id, object: result.object)
            }

            // The debug point cloud and dimension readout follow the object nearest the aimer;
            // every other fitted box remains rendered and stored independently.
            if let centeredID = visibleHints.compactMap({ hint -> (UUID, CGFloat)? in
                guard let point = hint.normalizedViewportPoint else { return nil }
                return (hint.id, hypot(point.x - 0.5, point.y - 0.5))
            }).min(by: { $0.1 < $1.1 })?.0,
               let centeredResult = liveResultsByObject[centeredID] {
                lastSelectionPoints = centeredResult.selectionPoints
                updateSelectionVisualization()
                captureEngine.focusCapture(id: centeredID)
            }
        }

        /// Prevents a single leaked support/background component from turning a stable object box
        /// into a table-sized result. Axis order can swap as PCA settles, so dimensions are compared
        /// sorted; contractions remain unrestricted because they often correct earlier leakage.
        private func isPlausibleBoxRefinement(
            _ candidate: CapturedObject,
            from previous: CapturedObject
        ) -> Bool {
            let previousDimensions = [
                previous.dimensions.x,
                previous.dimensions.y,
                previous.dimensions.z
            ].sorted()
            let candidateDimensions = [
                candidate.dimensions.x,
                candidate.dimensions.y,
                candidate.dimensions.z
            ].sorted()

            for (old, new) in zip(previousDimensions, candidateDimensions) {
                let maximumGrowth = max(old * 1.18, old + 0.025)
                if new > maximumGrowth {
                    return false
                }
            }

            let previousLargestDimension = previousDimensions.last ?? 0.1
            let maximumCenterShift = max(0.05, previousLargestDimension * 0.30)
            return simd_distance(candidate.center, previous.center) <= maximumCenterShift
        }

        /// Retained as a programmatic center-selection entry point. Scan mode no longer exposes a
        /// visible center-lock button; normal selection is performed by tapping the object itself.
        private func commitScanCapture() {
            guard captureEngine.isCapturing else {
                pendingObjectMaskToggleRequest = nil
                objectMaskToggleAttemptsRemaining = 0
                return
            }

            guard sessionManager.isTrackingReady else {
                captureEngine.reportTrackingNotReady()
                return
            }

            pendingObjectMaskToggleRequest = ObjectMaskToggleRequest(
                normalizedViewportPoint: CGPoint(x: 0.5, y: 0.5)
            )
            objectMaskToggleAttemptsRemaining = 4
        }

        private func resetScanState() {
            clearAllCaptureContent()
            supportAccumulators.removeAll()
            maskedAccumulators.removeAll()
            newestMaskedPointTimestamp.removeAll()
            fittedMaskedPointTimestamp.removeAll()
            liveResultsByObject.removeAll()
            scanTickCounter = 0
            captureEngine.clearPreview()
            resetObjectMaskTracking()
        }

        private func resetObjectMaskTracking() {
            objectMaskTrackingGeneration &+= 1
            objectMaskTask?.cancel()
            objectMaskTask = nil
            pendingObjectMaskToggleRequest = nil
            consecutiveMaskMisses = 0
            maskedAccumulators.removeAll()
            supportAccumulators.removeAll()
            newestMaskedPointTimestamp.removeAll()
            fittedMaskedPointTimestamp.removeAll()
            liveResultsByObject.removeAll()
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
            supportAccumulators.removeAll()
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

        private func addCapturedBox(_ object: CapturedObject, for id: UUID) {
            clearCaptureContent(for: id)

            guard object.corners.count == 8 else {
                return
            }

            let displayColor = objectMaskMarkerStates[id]?.color
                ?? ObjectMaskDisplayColor(red: 0.20, green: 0.95, blue: 0.42)
            let material = UnlitMaterial(
                color: UIColor(
                    red: CGFloat(displayColor.red),
                    green: CGFloat(displayColor.green),
                    blue: CGFloat(displayColor.blue),
                    alpha: 1
                ),
                applyPostProcessToneMap: false
            )

            // Edges for the `i + 2*j + 4*k` corner layout: base face, top face, vertical edges.
            let edges = [
                (0, 1), (1, 3), (2, 3), (0, 2),
                (4, 5), (5, 7), (6, 7), (4, 6),
                (0, 4), (1, 5), (2, 6), (3, 7)
            ]

            for edge in edges {
                addCapturedBoxEdge(
                    from: object.corners[edge.0],
                    to: object.corners[edge.1],
                    material: material,
                    objectID: id
                )
            }
        }

        private func addCapturedBoxEdge(
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            material: UnlitMaterial,
            objectID: UUID
        ) {
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
                materials: [material]
            )
            bar.scale = SIMD3<Float>(length, thickness, thickness)
            bar.position = start + delta / 2
            bar.orientation = orientation(alongX: delta)

            contentAnchor?.addChild(bar)
            bar.isEnabled = captureEngine.showsBoundingBoxes
            captureEntitiesByObject[objectID, default: []].append(bar)
        }

        private func updateCaptureBoxVisibility() {
            for entities in captureEntitiesByObject.values {
                for entity in entities {
                    entity.isEnabled = captureEngine.showsBoundingBoxes
                }
            }
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

        private func clearCaptureContent(for id: UUID) {
            for entity in captureEntitiesByObject.removeValue(forKey: id) ?? [] {
                entity.removeFromParent()
            }
        }

        private func clearAllCaptureContent() {
            for entities in captureEntitiesByObject.values {
                for entity in entities {
                    entity.removeFromParent()
                }
            }
            captureEntitiesByObject.removeAll()
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
            // RealityKit entities are much heavier than point values. A bounded reusable pool
            // keeps the debug view informative without allocating hundreds of extra scene nodes.
            let maxMarkers = 360
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
