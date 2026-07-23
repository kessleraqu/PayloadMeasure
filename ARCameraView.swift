
import ARKit
import CoreVideo
import ImageIO
import Metal
import RealityKit
import SwiftUI
import UIKit

struct ARCameraView: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let mesEngine: MesEngine
    let captureEngine: ObjectCaptureEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionManager: sessionManager,
            mesEngine: mesEngine,
            captureEngine: captureEngine
        )
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        sessionManager.configure(arView.session)
        context.coordinator.attach(to: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
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

        private struct SelectionVoxelKey: Hashable {
            let x: Int32
            let y: Int32
            let z: Int32
        }

        fileprivate static let iceWhiteMaterial = UnlitMaterial(color: .white, applyPostProcessToneMap: false)
        fileprivate static let selectionMaterial = UnlitMaterial(color: .cyan, applyPostProcessToneMap: false)
        fileprivate static let unitCubeMesh = MeshResource.generateBox(size: 1.0)
        fileprivate static let selectionPointRadius: Float = 0.00075
        fileprivate static let selectionPointOffsets = [
            SIMD3<Float>(1, 1, 1),
            SIMD3<Float>(1, -1, -1),
            SIMD3<Float>(-1, 1, -1),
            SIMD3<Float>(-1, -1, 1)
        ]
        fileprivate static let selectionPointIndices: [UInt32] = [
            0, 1, 2,
            0, 3, 1,
            0, 2, 3,
            1, 3, 2
        ]

        private let sessionManager: ARSessionManager
        private let mesEngine: MesEngine
        private let captureEngine: ObjectCaptureEngine
        private weak var arView: ARView?
        private var contentAnchor: AnchorEntity?
        private var placedPoints: [PlacedPoint] = []
        private var mesEntities: [ModelEntity] = []
        private var previewMeasurementEntities: [ModelEntity] = []
        private var captureEntitiesByObject: [UUID: [ModelEntity]] = [:]
        private var selectionPointMesh: LowLevelMesh?
        private var selectionPointEntity: ModelEntity?
        private var selectionPointMeshCapacity = 0
        private var lastSelectionPoints: [SIMD3<Float>] = []
        private var lastSelectionObjectID: UUID?
        private var supportAccumulators: [UUID: PointAccumulator] = [:]
        private var maskedAccumulators: [UUID: PointAccumulator] = [:]
        private var newestMaskedPointTimestamp: [UUID: TimeInterval] = [:]
        private var fittedMaskedPointTimestamp: [UUID: TimeInterval] = [:]
        private var liveResultsByObject: [UUID: CaptureResult] = [:]
        private var acceptedSurfaceVoxelKeysByObject: [UUID: Set<SelectionVoxelKey>] = [:]
        private let objectMaskProcessor = ObjectMaskProcessor()
        private var scanTickCounter = 0
        private var consecutiveMaskMisses = 0
        private var objectMaskTask: Task<Void, Never>?
        private var objectMaskTaskGeneration = 0
        private var objectMaskCameraBufferPool: CVPixelBufferPool?
        private var objectMaskDepthBufferPool: CVPixelBufferPool?
        private var objectMaskConfidenceBufferPool: CVPixelBufferPool?
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
        private var observedMode: MesMode = .scan
        private var observedCaptureResetRevision = 0
        private var observedObjectMaskToggleRequestRevision = 0
        private var observedMeshVisible = false
        private var observedShowsSelectedPoints = false
        private var observedShowsBoundingBoxes = true

        init(
            sessionManager: ARSessionManager,
            mesEngine: MesEngine,
            captureEngine: ObjectCaptureEngine
        ) {
            self.sessionManager = sessionManager
            self.mesEngine = mesEngine
            self.captureEngine = captureEngine
        }

        func attach(to arView: ARView) {
            self.arView = arView
            observedMode = mesEngine.mode
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
                    self.updateSessionFrameStatus(in: arView)
                    self.updateAimerSurface(in: arView)
                    self.updatePlacedPointBillboards(in: arView)
                    self.updateScanLive(in: arView)
                }
            }

            let maskTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self, weak arView] _ in
                guard let self, let arView else {
                    return
                }

                Task { @MainActor in
                    self.updateFastObjectMaskMarkers(in: arView)
                    self.updateObjectMaskPreview(in: arView)
                }
            }
            maskTimer.tolerance = 1.0 / 120.0
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
            objectMaskTaskGeneration &+= 1
            objectMaskTask = nil
            objectMaskCameraBufferPool = nil
            objectMaskDepthBufferPool = nil
            objectMaskConfidenceBufferPool = nil
            pendingObjectMaskToggleRequest = nil
            removeAllObjectMaskAnchors()
            captureEngine.updateLockedObjectMaskCount(0)
            captureEngine.updateObjectMaskTracking(visibleCount: 0, markers: [])
            captureEngine.clearObjectMaskPreview()
            clearMeasurementContent()
            clearAllCaptureContent()

            removeSelectionPointEntity()

            if let contentAnchor, let arView {
                arView.scene.removeAnchor(contentAnchor)
            }

            arView = nil
            contentAnchor = nil
        }

        private func releaseRebuildableScanCaches() {
            objectMaskTask?.cancel()
            objectMaskCameraBufferPool = nil
            objectMaskDepthBufferPool = nil
            objectMaskConfidenceBufferPool = nil
            supportAccumulators.removeAll(keepingCapacity: false)
            maskedAccumulators.removeAll(keepingCapacity: false)
            newestMaskedPointTimestamp.removeAll(keepingCapacity: false)
            fittedMaskedPointTimestamp.removeAll(keepingCapacity: false)
            liveResultsByObject.removeAll(keepingCapacity: false)
            acceptedSurfaceVoxelKeysByObject.removeAll(keepingCapacity: false)
            captureEngine.clearObjectMaskPreview()
            lastSelectionPoints.removeAll(keepingCapacity: false)
            lastSelectionObjectID = nil
            removeSelectionPointEntity()
        }

        private func observeEngineRevisions() {
            withObservationTracking {
                _ = mesEngine.placementRequestRevision
                _ = mesEngine.resetRevision
                _ = mesEngine.mode
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
            if mesEngine.mode != observedMode {
                let wasScanning = observedMode == .scan
                observedMode = mesEngine.mode
                clearMeasurementContent()
                resetScanState()
                updateMeshVisibility()
                if wasScanning {
                    captureEngine.reset()
                }
            }

            if mesEngine.resetRevision != observedResetRevision {
                observedResetRevision = mesEngine.resetRevision
                clearMeasurementContent()
            }

            if mesEngine.placementRequestRevision != observedPlacementRequestRevision {
                observedPlacementRequestRevision = mesEngine.placementRequestRevision
                if let arView {
                    placePointAtTarget(in: arView)
                }
            }

            if captureEngine.resetRevision != observedCaptureResetRevision {
                observedCaptureResetRevision = captureEngine.resetRevision
                resetScanState()
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
                updateMeshVisibility()
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

            let shouldShow = mesEngine.mode == .scan
                && sessionManager.isSceneReconstructionEnabled
                && captureEngine.isMeshVisible
            if shouldShow {
                arView.debugOptions.insert(.showSceneUnderstanding)
            } else {
                arView.debugOptions.remove(.showSceneUnderstanding)
            }
            let shouldOcclude = mesEngine.mode == .scan
                && sessionManager.isSceneReconstructionEnabled
                && captureEngine.showsSelectedPoints
            if shouldOcclude {
                arView.environment.sceneUnderstanding.options.insert(.occlusion)
            } else {
                arView.environment.sceneUnderstanding.options.remove(.occlusion)
            }
        }

        private func updateObjectMaskPreview(in arView: ARView) {
            guard mesEngine.mode == .scan,
                  objectMaskTask == nil,
                  let frame = arView.session.currentFrame else {
                return
            }

            let orientation = cameraImageOrientation(in: arView)
            let viewportSize = arView.bounds.size
            let imageToViewportTransform = frame.displayTransform(
                for: interfaceOrientation(in: arView),
                viewportSize: viewportSize
            )

            let submittedToggleRequest = pendingObjectMaskToggleRequest
            let toggleRequest = preparedObjectMaskToggleRequest(
                submittedToggleRequest,
                frame: frame,
                in: arView
            )
            guard let cameraImage = Self.copiedPixelBuffer(
                frame.capturedImage,
                using: &objectMaskCameraBufferPool
            ) else {
                return
            }
            let input = ObjectMaskFrame(
                pixelBuffer: cameraImage,
                orientation: orientation,
                viewportSize: viewportSize,
                imageToViewportTransform: imageToViewportTransform,
                toggleRequest: toggleRequest,
                anchorHints: objectMaskAnchorHints(frame: frame, in: arView),
                timestamp: frame.timestamp,
                trackingGeneration: objectMaskTrackingGeneration,
                depthSnapshot: objectMaskDepthSnapshot(from: frame)
            )
            if submittedToggleRequest != nil {
                pendingObjectMaskToggleRequest = nil
                objectMaskToggleAttemptsRemaining = max(objectMaskToggleAttemptsRemaining - 1, 0)
            }
            let processor = objectMaskProcessor
            objectMaskTaskGeneration &+= 1
            let taskGeneration = objectMaskTaskGeneration

            objectMaskTask = Task { [weak self] in
                let result = await processor.makePreview(from: input)
                let wasCancelled = Task.isCancelled
                guard let self,
                      self.objectMaskTaskGeneration == taskGeneration else {
                    return
                }

                self.objectMaskTask = nil
                guard !wasCancelled, self.mesEngine.mode == .scan else {
                    return
                }

                let previousLockedObjectCount = self.captureEngine.lockedObjectMaskCount
                self.applyObjectMaskLockChange(result.lockChange, in: arView)
                for cloud in result.maskedPointClouds {
                    if self.maskedAccumulators[cloud.id] == nil {
                        self.maskedAccumulators[cloud.id] = PointAccumulator(
                            voxelSize: ObjectCapturePipeline.voxelSize,
                            maxVoxels: ObjectCapturePipeline.maxObjectVoxels
                        )
                    }
                    let newlyStablePointCount = self.maskedAccumulators[cloud.id]?.add(
                        cloud.points,
                        timestamp: cloud.timestamp,
                        stabilizationObservations: ObjectCapturePipeline.minObservations
                    ) ?? 0
                    if newlyStablePointCount > 0 {
                        self.newestMaskedPointTimestamp[cloud.id] = max(
                            self.newestMaskedPointTimestamp[cloud.id] ?? -.greatestFiniteMagnitude,
                            cloud.timestamp
                        )
                    }
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
            guard mesEngine.mode == .scan else {
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

        private func updateSessionFrameStatus(in arView: ARView) {
            guard let frame = arView.session.currentFrame else {
                return
            }
            sessionManager.updateFrameStatus(from: frame)
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
            return candidates[min(candidates.count / 4, candidates.count - 1)]
        }

        private func objectMaskAnchorHints(frame: ARFrame, in arView: ARView) -> [ObjectMaskAnchorHint] {
            let orientation = interfaceOrientation(in: arView)
            let viewportSize = arView.bounds.size
            guard viewportSize.width > 0, viewportSize.height > 0 else {
                return []
            }
            let worldToCamera = frame.camera.transform.inverse
            let cameraPosition = frame.camera.transform.translation

            return objectMaskAnchors.map { lockID, anchor in
                let worldPosition = anchor.transform.translation
                let pointInCamera = worldToCamera * SIMD4<Float>(worldPosition, 1)
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
                    cameraDistance: simd_distance(cameraPosition, worldPosition),
                    worldPosition: worldPosition
                )
            }
        }

        private func objectMaskDepthSnapshot(from frame: ARFrame) -> ObjectMaskDepthSnapshot? {
            guard case .normal = frame.camera.trackingState,
                  let sceneDepth = frame.sceneDepth else {
                return nil
            }
            guard let depthMap = Self.copiedPixelBuffer(
                sceneDepth.depthMap,
                using: &objectMaskDepthBufferPool
            ) else {
                return nil
            }
            let confidenceMap: CVPixelBuffer?
            if let sourceConfidenceMap = sceneDepth.confidenceMap {
                guard let copiedConfidenceMap = Self.copiedPixelBuffer(
                    sourceConfidenceMap,
                    using: &objectMaskConfidenceBufferPool
                ) else {
                    return nil
                }
                confidenceMap = copiedConfidenceMap
            } else {
                confidenceMap = nil
            }
            return ObjectMaskDepthSnapshot(
                depthMap: depthMap,
                confidenceMap: confidenceMap,
                cameraTransform: frame.camera.transform,
                cameraIntrinsics: frame.camera.intrinsics,
                cameraImageResolution: frame.camera.imageResolution
            )
        }

        private static func copiedPixelBuffer(
            _ source: CVPixelBuffer,
            using pool: inout CVPixelBufferPool?
        ) -> CVPixelBuffer? {
            let width = CVPixelBufferGetWidth(source)
            let height = CVPixelBufferGetHeight(source)
            let pixelFormat = CVPixelBufferGetPixelFormatType(source)
            var destination: CVPixelBuffer?

            if let pool,
               CVPixelBufferPoolCreatePixelBuffer(
                   kCFAllocatorDefault,
                   pool,
                   &destination
               ) != kCVReturnSuccess
                    || destination.map({
                        CVPixelBufferGetWidth($0) != width
                            || CVPixelBufferGetHeight($0) != height
                            || CVPixelBufferGetPixelFormatType($0) != pixelFormat
                    }) == true {
                destination = nil
            }

            if destination == nil {
                let poolAttributes: [CFString: Any] = [
                    kCVPixelBufferPoolMinimumBufferCountKey: 2
                ]
                let pixelBufferAttributes: [CFString: Any] = [
                    kCVPixelBufferWidthKey: width,
                    kCVPixelBufferHeightKey: height,
                    kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                    kCVPixelBufferIOSurfacePropertiesKey: [:]
                ]
                var newPool: CVPixelBufferPool?
                guard CVPixelBufferPoolCreate(
                    kCFAllocatorDefault,
                    poolAttributes as CFDictionary,
                    pixelBufferAttributes as CFDictionary,
                    &newPool
                ) == kCVReturnSuccess,
                      let newPool,
                      CVPixelBufferPoolCreatePixelBuffer(
                          kCFAllocatorDefault,
                          newPool,
                          &destination
                      ) == kCVReturnSuccess else {
                    pool = nil
                    return nil
                }
                pool = newPool
            }

            guard let destination else {
                return nil
            }

            guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else {
                return nil
            }
            guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else {
                CVPixelBufferUnlockBaseAddress(source, .readOnly)
                return nil
            }
            defer {
                CVPixelBufferUnlockBaseAddress(destination, [])
                CVPixelBufferUnlockBaseAddress(source, .readOnly)
            }

            let planeCount = CVPixelBufferGetPlaneCount(source)
            if planeCount > 0 {
                guard planeCount == CVPixelBufferGetPlaneCount(destination) else {
                    return nil
                }
                for plane in 0..<planeCount {
                    guard let sourceAddress = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                          let destinationAddress = CVPixelBufferGetBaseAddressOfPlane(
                              destination,
                              plane
                          ) else {
                        return nil
                    }
                    let rowCount = min(
                        CVPixelBufferGetHeightOfPlane(source, plane),
                        CVPixelBufferGetHeightOfPlane(destination, plane)
                    )
                    let sourceRowBytes = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                    let destinationRowBytes = CVPixelBufferGetBytesPerRowOfPlane(
                        destination,
                        plane
                    )
                    let copiedRowBytes = min(sourceRowBytes, destinationRowBytes)
                    for row in 0..<rowCount {
                        destinationAddress
                            .advanced(by: row * destinationRowBytes)
                            .copyMemory(
                                from: sourceAddress.advanced(by: row * sourceRowBytes),
                                byteCount: copiedRowBytes
                            )
                    }
                }
            } else {
                guard let sourceAddress = CVPixelBufferGetBaseAddress(source),
                      let destinationAddress = CVPixelBufferGetBaseAddress(destination) else {
                    return nil
                }
                let rowCount = min(
                    CVPixelBufferGetHeight(source),
                    CVPixelBufferGetHeight(destination)
                )
                let sourceRowBytes = CVPixelBufferGetBytesPerRow(source)
                let destinationRowBytes = CVPixelBufferGetBytesPerRow(destination)
                let copiedRowBytes = min(sourceRowBytes, destinationRowBytes)
                for row in 0..<rowCount {
                    destinationAddress
                        .advanced(by: row * destinationRowBytes)
                        .copyMemory(
                            from: sourceAddress.advanced(by: row * sourceRowBytes),
                            byteCount: copiedRowBytes
                        )
                }
            }

            CVBufferPropagateAttachments(source, destination)
            return destination
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
                acceptedSurfaceVoxelKeysByObject.removeValue(forKey: change.id)
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
                acceptedSurfaceVoxelKeysByObject.removeValue(forKey: change.id)
                if lastSelectionObjectID == change.id {
                    lastSelectionObjectID = nil
                    lastSelectionPoints = []
                    hideAllSelectionMarkers()
                }
                clearCaptureContent(for: change.id)
                captureEngine.removeObjectMaskLayer(id: change.id)
                captureEngine.removeCapture(id: change.id)
            }
        }

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

        private func updateScanLive(in arView: ARView) {
            guard mesEngine.mode == .scan,
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

            if scanTickCounter % 3 == 1 {
                let supportPointsByObject = DepthPointCloud.worldPoints(
                    from: frame,
                    near: seeds,
                    radius: ObjectCapturePipeline.accumulationRadius,
                    pixelStride: 3
                )

                for (id, points) in supportPointsByObject where !points.isEmpty {
                    if supportAccumulators[id] == nil {
                        supportAccumulators[id] = PointAccumulator(
                            voxelSize: ObjectCapturePipeline.supportVoxelSize,
                            maxVoxels: 4_000
                        )
                    }
                    supportAccumulators[id]?.add(points, timestamp: frame.timestamp)
                }
            }

            if scanTickCounter % 45 == 0 {
                for id in Array(supportAccumulators.keys) {
                    supportAccumulators[id]?.pruneTransient(
                        below: ObjectCapturePipeline.minObservations,
                        olderThan: 8
                    )
                    supportAccumulators[id]?.pruneStale(olderThan: 90)
                }
                for id in Array(maskedAccumulators.keys) {
                    maskedAccumulators[id]?.pruneTransient(
                        below: ObjectCapturePipeline.minObservations,
                        olderThan: 8
                    )
                }
            }

            guard scanTickCounter % 3 == 0 else {
                return
            }

            createContentAnchorIfNeeded(in: arView)
            for hint in visibleHints {
                let id = hint.id
                guard let maskTimestamp = newestMaskedPointTimestamp[id],
                      maskTimestamp > fittedMaskedPointTimestamp[id, default: -.greatestFiniteMagnitude],
                      let objectAccumulator = maskedAccumulators[id],
                      let anchor = objectMaskAnchors[id] else {
                    continue
                }
                let supportReference = liveResultsByObject[id]?.object.center
                    ?? anchor.transform.translation
                let planeSupportHeight = ObjectCapturePipeline.supportPlaneHeight(
                    from: frame.anchors,
                    beneath: supportReference
                )
                let supportPoints = supportAccumulators[id]?.points(
                    minObservations: ObjectCapturePipeline.minObservations
                ) ?? []
                guard planeSupportHeight != nil || !supportPoints.isEmpty else {
                    continue
                }
                let objectPoints = objectAccumulator.confirmedPoints(
                    minObservations: ObjectCapturePipeline.minObservations
                )
                guard !objectPoints.isEmpty else {
                    continue
                }

                let outcome = ObjectCapturePipeline.capture(
                    objectPoints: objectPoints,
                    supportPoints: supportPoints,
                    seed: anchor.transform.translation,
                    up: SIMD3<Float>(0, 1, 0),
                    supportHeight: planeSupportHeight
                )
                guard case .success(let result) = outcome else {
                    continue
                }

                fittedMaskedPointTimestamp[id] = maskTimestamp
                if let previous = liveResultsByObject[id],
                   previous.selectionPoints == result.selectionPoints {
                    continue
                }
                var acceptedSurfaceExpansion = false
                if let previous = liveResultsByObject[id] {
                    let requiresExpansionEvidence =
                        !isPlausibleBoxRefinement(result.object, from: previous.object)
                        || objectAccumulator.isAtCapacity
                    if requiresExpansionEvidence {
                        acceptedSurfaceExpansion = hasConfirmedSurfaceExpansion(
                            result,
                            from: previous,
                            for: id
                        )
                        if !acceptedSurfaceExpansion {
                            let supportedPairs = zip(
                                result.selectionPoints,
                                result.surfacePoints
                            ).filter { pair in
                                previous.object.contains(
                                    pair.0,
                                    tolerance: ObjectCapturePipeline.selectionTolerance
                                )
                                    && previous.object.contains(
                                        pair.1
                                    )
                            }
                            let retainedResult = CaptureResult(
                                object: previous.object,
                                selectionPoints: mergedSelectionPoints(
                                    previous.selectionPoints,
                                    supportedPairs.map(\.0)
                                ),
                                surfacePoints: mergedSelectionPoints(
                                    previous.surfacePoints,
                                    supportedPairs.map(\.1)
                                )
                            )
                            liveResultsByObject[id] = retainedResult
                            continue
                        }
                    }
                }
                var acceptedResult = result
                if objectAccumulator.isAtCapacity,
                   let previous = liveResultsByObject[id] {
                    let retainedSurfacePoints = mergedSelectionPoints(
                        previous.surfacePoints,
                        result.surfacePoints
                    )
                    acceptedResult = CaptureResult(
                        object: ObjectBoundingBox.enclosing(
                            retainedSurfacePoints,
                            around: result.object
                        ),
                        selectionPoints: result.selectionPoints,
                        surfacePoints: retainedSurfacePoints
                    )
                }
                liveResultsByObject[id] = acceptedResult
                if acceptedSurfaceVoxelKeysByObject[id] == nil
                    || acceptedSurfaceExpansion {
                    acceptedSurfaceVoxelKeysByObject[id] = Set(
                        acceptedResult.selectionPoints.filter {
                            acceptedResult.object.contains(
                                $0,
                                tolerance: ObjectCapturePipeline.selectionTolerance
                            )
                        }.map(selectionVoxelKey(for:))
                    )
                } else {
                    for point in acceptedResult.selectionPoints where acceptedResult.object.contains(
                        point,
                        tolerance: ObjectCapturePipeline.selectionTolerance
                    ) {
                        acceptedSurfaceVoxelKeysByObject[id, default: []].insert(
                            selectionVoxelKey(for: point)
                        )
                    }
                }
                addCapturedBox(acceptedResult.object, for: id)
                captureEngine.updateCapture(id: id, object: acceptedResult.object)
            }

            if let centeredID = visibleHints.compactMap({ hint -> (UUID, CGFloat)? in
                guard let point = hint.normalizedViewportPoint else { return nil }
                return (hint.id, hypot(point.x - 0.5, point.y - 0.5))
            }).min(by: { $0.1 < $1.1 })?.0,
               let centeredResult = liveResultsByObject[centeredID] {
                if lastSelectionObjectID != centeredID
                    || lastSelectionPoints != centeredResult.surfacePoints {
                    lastSelectionObjectID = centeredID
                    lastSelectionPoints = centeredResult.surfacePoints
                    updateSelectionVisualization()
                }
                captureEngine.focusCapture(id: centeredID)
            }
        }

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

        private func hasConfirmedSurfaceExpansion(
            _ candidate: CaptureResult,
            from previous: CaptureResult,
            for id: UUID
        ) -> Bool {
            let acceptedKeys = acceptedSurfaceVoxelKeysByObject[id]
                ?? Set(previous.selectionPoints.map(selectionVoxelKey(for:)))
            let requiredEvidence = max(
                8,
                min(20, acceptedKeys.count / 16)
            )
            var outsideKeys: Set<SelectionVoxelKey> = []
            outsideKeys.reserveCapacity(candidate.selectionPoints.count)
            for point in candidate.selectionPoints {
                if !previous.object.contains(
                    point,
                    tolerance: ObjectCapturePipeline.selectionTolerance
                ) {
                    outsideKeys.insert(selectionVoxelKey(for: point))
                }
            }
            return hasConnectedSelectionPatch(
                outsideKeys,
                adjacentTo: acceptedKeys,
                minimumCount: requiredEvidence
            )
        }

        private func hasConnectedSelectionPatch(
            _ keys: Set<SelectionVoxelKey>,
            adjacentTo acceptedKeys: Set<SelectionVoxelKey>,
            minimumCount: Int
        ) -> Bool {
            guard keys.count >= minimumCount else {
                return false
            }

            var remaining = keys
            while let seed = remaining.popFirst() {
                var pending = [seed]
                var patchCount = 1
                var touchesAcceptedSurface = selectionVoxelKey(
                    seed,
                    isNearAny: acceptedKeys
                )
                while let key = pending.popLast() {
                    if !touchesAcceptedSurface {
                        touchesAcceptedSurface = selectionVoxelKey(
                            key,
                            isNearAny: acceptedKeys
                        )
                    }
                    for dx in -2...2 {
                        for dy in -2...2 {
                            for dz in -2...2 where dx != 0 || dy != 0 || dz != 0 {
                                let neighbour = SelectionVoxelKey(
                                    x: key.x + Int32(dx),
                                    y: key.y + Int32(dy),
                                    z: key.z + Int32(dz)
                                )
                                if remaining.remove(neighbour) != nil {
                                    patchCount += 1
                                    if patchCount >= minimumCount,
                                       touchesAcceptedSurface {
                                        return true
                                    }
                                    pending.append(neighbour)
                                }
                            }
                        }
                    }
                }
                if patchCount >= minimumCount, touchesAcceptedSurface {
                    return true
                }
            }
            return false
        }

        private func selectionVoxelKey(
            _ key: SelectionVoxelKey,
            isNearAny acceptedKeys: Set<SelectionVoxelKey>
        ) -> Bool {
            for dx in -3...3 {
                for dy in -3...3 {
                    for dz in -3...3 {
                        if acceptedKeys.contains(
                            SelectionVoxelKey(
                                x: key.x + Int32(dx),
                                y: key.y + Int32(dy),
                                z: key.z + Int32(dz)
                            )
                        ) {
                            return true
                        }
                    }
                }
            }
            return false
        }

        private func resetScanState() {
            clearAllCaptureContent()
            supportAccumulators.removeAll()
            maskedAccumulators.removeAll()
            newestMaskedPointTimestamp.removeAll()
            fittedMaskedPointTimestamp.removeAll()
            liveResultsByObject.removeAll()
            acceptedSurfaceVoxelKeysByObject.removeAll()
            scanTickCounter = 0
            resetObjectMaskTracking()
        }

        private func resetObjectMaskTracking() {
            objectMaskTrackingGeneration &+= 1
            objectMaskTask?.cancel()
            pendingObjectMaskToggleRequest = nil
            consecutiveMaskMisses = 0
            maskedAccumulators.removeAll()
            supportAccumulators.removeAll()
            newestMaskedPointTimestamp.removeAll()
            fittedMaskedPointTimestamp.removeAll()
            liveResultsByObject.removeAll()
            acceptedSurfaceVoxelKeysByObject.removeAll()
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
                mesEngine.reportTrackingNotReady()
                return
            }

            if !mesEngine.canAcceptPoint {
                mesEngine.reset()
                clearMeasurementContent()
                observedResetRevision = mesEngine.resetRevision
            }

            let targetLocation = centerPoint(in: arView)

            let initialTransform: simd_float4x4
            if let cached = lastAimerRaycastTransform {
                initialTransform = cached
            } else if let immediate = bestRaycastResult(from: targetLocation, in: arView) {
                initialTransform = immediate.worldTransform
            } else {
                mesEngine.reportPlacementFailure()
                return
            }

            createContentAnchorIfNeeded(in: arView)

            let position = initialTransform.translation
            let pointID = mesEngine.addPoint(at: position)
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
                mesEngine.updateAimerSurface(
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
            let referenceDistance: Float = 0.7
            let safeDistance = max(distance, 0.15)
            let distanceScale = Double(min(max(referenceDistance / safeDistance, 0.55), 1.8))
            let inverseCamera = arView.cameraTransform.matrix.inverse
            let normalInCamera4 = inverseCamera * SIMD4<Float>(normalizedNormal, 0)
            let normalInCamera = SIMD3<Float>(normalInCamera4.x, normalInCamera4.y, normalInCamera4.z)
            let projectedLength = hypot(normalInCamera.x, normalInCamera.y)
            let rotation: Double = projectedLength > 0.05
                ? Double(atan2(normalInCamera.x, -normalInCamera.y) * 180 / .pi)
                : 0

            mesEngine.updateAimerSurface(
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
                mesEngine.finishRefiningPoint(id: pointID)
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
            mesEngine.updatePoint(id: pointID, position: position)
            updateMeasurementVisual()
        }

        private func stopRefining(pointID: UUID) {
            guard let index = placedPoints.firstIndex(where: { $0.id == pointID }) else {
                return
            }

            placedPoints[index].trackedRaycast?.stopTracking()
            placedPoints[index].trackedRaycast = nil
            lockPointToARAnchor(at: index)
            mesEngine.finishRefiningPoint(id: pointID)
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
                name: "MesPoint-\(pointID.uuidString)",
                transform: latestTransform
            )
            let anchorEntity = AnchorEntity(.anchor(identifier: arAnchor.identifier))

            arView.session.add(anchor: arAnchor)
            arView.scene.addAnchor(anchorEntity)

            marker.removeFromParent()
            marker.position = .zero
            anchorEntity.addChild(marker)
            orientBillboard(marker, at: latestTransform.translation, in: arView)

            placedPoints[index].arAnchor = arAnchor
            placedPoints[index].anchorEntity = anchorEntity
            mesEngine.updatePoint(id: pointID, position: latestTransform.translation)
            updateMeasurementVisual()
        }

        private func updateMeasurementVisual() {
            clearMeasurementEntities()
            clearPreviewMeasurementEntities()

            guard mesEngine.points.count == 2 else {
                updatePreviewMeasurementVisual()
                return
            }

            switch mesEngine.mode {
            case .line:
                addDashedLine(from: mesEngine.points[0].position, to: mesEngine.points[1].position)
            case .boundingBox:
                addBoundingBox(from: mesEngine.points[0].position, to: mesEngine.points[1].position)
            case .scan:
                break
            }
        }

        private func updatePreviewMeasurementVisual() {
            clearPreviewMeasurementEntities()

            guard mesEngine.points.count == 1,
                  let previewTargetPosition else {
                return
            }

            addDashedLine(
                from: mesEngine.points[0].position,
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
            addDashedLine(from: start, to: end, radius: radius, into: &mesEntities)
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
                  let storedPosition = mesEngine.points.first(where: { $0.id == placedPoint.id })?.position,
                  simd_distance(storedPosition, worldPosition) > 0.001 else {
                return
            }

            mesEngine.updatePoint(id: placedPoint.id, position: worldPosition)
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
            for entity in mesEntities {
                entity.removeFromParent()
            }

            mesEntities.removeAll()
        }

        private func clearPreviewMeasurementEntities() {
            for entity in previewMeasurementEntities {
                entity.removeFromParent()
            }

            previewMeasurementEntities.removeAll()
        }

        private func addCapturedBox(_ object: CapturedObject, for id: UUID) {
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

            let edges = [
                (0, 1), (1, 3), (2, 3), (0, 2),
                (4, 5), (5, 7), (6, 7), (4, 6),
                (0, 4), (1, 5), (2, 6), (3, 7)
            ]

            var bars = captureEntitiesByObject[id] ?? []
            while bars.count < edges.count {
                let bar = ModelEntity(
                    mesh: Coordinator.unitCubeMesh,
                    materials: [material]
                )
                contentAnchor?.addChild(bar)
                bars.append(bar)
            }

            for (index, edge) in edges.enumerated() {
                updateCapturedBoxEdge(
                    bars[index],
                    from: object.corners[edge.0],
                    to: object.corners[edge.1],
                    material: material
                )
            }
            captureEntitiesByObject[id] = bars
        }

        private func updateCapturedBoxEdge(
            _ bar: ModelEntity,
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            material: UnlitMaterial
        ) {
            let delta = end - start
            let length = simd_length(delta)

            guard length > 0.001 else {
                bar.isEnabled = false
                return
            }

            let thickness: Float = 0.006
            if var model = bar.model {
                model.materials = [material]
                bar.model = model
            }
            bar.scale = SIMD3<Float>(length, thickness, thickness)
            bar.position = start + delta / 2
            bar.orientation = orientation(alongX: delta)
            bar.isEnabled = captureEngine.showsBoundingBoxes
        }

        private func updateCaptureBoxVisibility() {
            for entities in captureEntitiesByObject.values {
                for entity in entities {
                    entity.isEnabled = captureEngine.showsBoundingBoxes
                }
            }
        }

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
            lastSelectionObjectID = nil
        }

        private func updateSelectionVisualization() {
            guard captureEngine.showsSelectedPoints, !lastSelectionPoints.isEmpty,
                  let contentAnchor else {
                hideAllSelectionMarkers()
                return
            }

            guard let mesh = selectionPointMesh(
                in: contentAnchor,
                minimumCapacity: lastSelectionPoints.count
            ) else {
                return
            }

            let verticesPerPoint = Self.selectionPointOffsets.count
            let indicesPerPoint = Self.selectionPointIndices.count
            let radius = Self.selectionPointRadius
            mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { buffer in
                let positions = buffer.bindMemory(to: SIMD3<Float>.self)
                for (pointIndex, point) in lastSelectionPoints.enumerated() {
                    let vertexBase = pointIndex * verticesPerPoint
                    for offsetIndex in Self.selectionPointOffsets.indices {
                        positions[vertexBase + offsetIndex] =
                            point + Self.selectionPointOffsets[offsetIndex] * radius
                    }
                }
            }
            mesh.parts.replaceAll([
                LowLevelMesh.Part(
                    indexCount: lastSelectionPoints.count * indicesPerPoint,
                    topology: .triangle,
                    bounds: selectionPointBounds(lastSelectionPoints)
                )
            ])
            selectionPointEntity?.isEnabled = true
        }

        private func selectionPointMesh(
            in contentAnchor: AnchorEntity,
            minimumCapacity: Int
        ) -> LowLevelMesh? {
            if let selectionPointMesh,
               selectionPointMeshCapacity >= minimumCapacity {
                return selectionPointMesh
            }

            var capacity = 1_024
            while capacity < minimumCapacity {
                capacity *= 2
            }
            let descriptor = LowLevelMesh.Descriptor(
                vertexCapacity: capacity * Self.selectionPointOffsets.count,
                vertexAttributes: [
                    LowLevelMesh.Attribute(
                        semantic: .position,
                        format: .float3,
                        offset: 0
                    )
                ],
                vertexLayouts: [
                    LowLevelMesh.Layout(
                        bufferIndex: 0,
                        bufferStride: MemoryLayout<SIMD3<Float>>.stride
                    )
                ],
                indexCapacity: capacity * Self.selectionPointIndices.count,
                indexType: .uint32
            )
            guard let mesh = try? LowLevelMesh(descriptor: descriptor) else {
                return nil
            }
            mesh.replaceUnsafeMutableIndices { buffer in
                let indices = buffer.bindMemory(to: UInt32.self)
                let verticesPerPoint = Self.selectionPointOffsets.count
                let indicesPerPoint = Self.selectionPointIndices.count
                for pointIndex in 0..<capacity {
                    let vertexBase = UInt32(pointIndex * verticesPerPoint)
                    let indexBase = pointIndex * indicesPerPoint
                    for localIndex in Self.selectionPointIndices.indices {
                        indices[indexBase + localIndex] =
                            vertexBase + Self.selectionPointIndices[localIndex]
                    }
                }
            }
            guard let resource = try? MeshResource(from: mesh) else {
                return nil
            }

            let entity = ModelEntity(
                mesh: resource,
                materials: [Coordinator.selectionMaterial]
            )
            selectionPointEntity?.removeFromParent()
            contentAnchor.addChild(entity)
            selectionPointMesh = mesh
            selectionPointEntity = entity
            selectionPointMeshCapacity = capacity
            return mesh
        }

        private func selectionPointBounds(_ points: [SIMD3<Float>]) -> BoundingBox {
            var minimum = points[0]
            var maximum = points[0]
            for point in points.dropFirst() {
                minimum = simd_min(minimum, point)
                maximum = simd_max(maximum, point)
            }
            let padding = SIMD3<Float>(repeating: Self.selectionPointRadius)
            return BoundingBox(min: minimum - padding, max: maximum + padding)
        }

        private func selectionVoxelKey(
            for point: SIMD3<Float>
        ) -> SelectionVoxelKey {
            let cellSize = ObjectCapturePipeline.voxelSize
            return SelectionVoxelKey(
                x: Int32(floor(point.x / cellSize)),
                y: Int32(floor(point.y / cellSize)),
                z: Int32(floor(point.z / cellSize))
            )
        }

        private func mergedSelectionPoints(
            _ retained: [SIMD3<Float>],
            _ additions: [SIMD3<Float>]
        ) -> [SIMD3<Float>] {
            var pointsByKey: [SelectionVoxelKey: SIMD3<Float>] = [:]
            pointsByKey.reserveCapacity(retained.count + additions.count)
            for point in retained {
                pointsByKey[selectionVoxelKey(for: point)] = point
            }
            for point in additions {
                let key = selectionVoxelKey(for: point)
                if pointsByKey[key] == nil {
                    pointsByKey[key] = point
                }
            }
            return pointsByKey.keys.sorted(by: selectionVoxelKey(_:precedes:)).compactMap {
                pointsByKey[$0]
            }
        }

        private func selectionVoxelKey(
            _ left: SelectionVoxelKey,
            precedes right: SelectionVoxelKey
        ) -> Bool {
            if left.x != right.x { return left.x < right.x }
            if left.y != right.y { return left.y < right.y }
            return left.z < right.z
        }

        private func hideAllSelectionMarkers() {
            selectionPointEntity?.isEnabled = false
        }

        private func removeSelectionPointEntity() {
            selectionPointEntity?.removeFromParent()
            selectionPointEntity = nil
            selectionPointMesh = nil
            selectionPointMeshCapacity = 0
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
