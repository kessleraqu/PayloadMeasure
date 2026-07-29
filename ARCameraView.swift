
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

        /// A horizontal footprint (width × length + yaw + XZ position) captured from a top-down view.
        /// Height is stored separately and captured from a side view, so each dimension is measured
        /// from the viewpoint that sees it best and is not disturbed by the other.
        private struct ObjectFootprint {
            var widthAxis: SIMD3<Float>
            var width: Float
            var depth: Float
            var centerXZ: SIMD2<Float>
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

        /// The masked surface of one object, in the form RealityKit needs.
        private struct ObjectMaskSurfelSet {
            var surfels: [ObjectMaskSurfel]
            var color: ObjectMaskDisplayColor
            var fillAlpha: CGFloat
            var timestamp: TimeInterval
        }

        /// GPU-resident overlay for one object's mask.
        ///
        /// The vertex buffer is rewritten only when Vision produces a new
        /// keyframe. Between keyframes RealityKit redraws this geometry from the
        /// live camera pose at display rate, so the mask stays registered to the
        /// object with no per-frame CPU work and no latency of its own.
        private struct ObjectMaskSurfelEntity {
            let mesh: LowLevelMesh
            let entity: ModelEntity
            var capacity: Int
        }

        private struct ObjectMaskAlphaMap {
            let width: Int
            let height: Int
            let bytesPerRow: Int
            let bytesPerPixel: Int
            let alphaOffset: Int
            let pixels: Data

            init?(_ image: CGImage) {
                guard image.bitsPerComponent == 8,
                      image.bitsPerPixel % 8 == 0,
                      let data = image.dataProvider?.data else {
                    return nil
                }
                let bytesPerPixel = image.bitsPerPixel / 8
                let alphaOffset: Int
                switch image.alphaInfo {
                case .premultipliedLast, .last:
                    alphaOffset = bytesPerPixel - 1
                case .premultipliedFirst, .first:
                    alphaOffset = 0
                default:
                    return nil
                }
                guard bytesPerPixel > alphaOffset,
                      CFDataGetLength(data) >= image.bytesPerRow * image.height else {
                    return nil
                }
                width = image.width
                height = image.height
                bytesPerRow = image.bytesPerRow
                self.bytesPerPixel = bytesPerPixel
                self.alphaOffset = alphaOffset
                pixels = data as Data
            }

            func contains(_ point: CGPoint, radius: Int = 2) -> Bool {
                guard (0 ... 1).contains(point.x),
                      (0 ... 1).contains(point.y),
                      width > 0,
                      height > 0 else {
                    return false
                }
                let centerX = min(Int(point.x * CGFloat(width)), width - 1)
                let centerY = min(Int(point.y * CGFloat(height)), height - 1)
                for y in max(centerY - radius, 0) ... min(centerY + radius, height - 1) {
                    for x in max(centerX - radius, 0) ... min(centerX + radius, width - 1) {
                        let index = y * bytesPerRow + x * bytesPerPixel + alphaOffset
                        if pixels[index] > 16 {
                            return true
                        }
                    }
                }
                return false
            }

        }

        fileprivate static let iceWhiteMaterial = UnlitMaterial(color: .white, applyPostProcessToneMap: false)
        fileprivate static let selectionMaterial = UnlitMaterial(color: .cyan, applyPostProcessToneMap: false)
        fileprivate static let unitCubeMesh = MeshResource.generateBox(size: 1.0)
        fileprivate static let captureBoxEdgeThickness: Float = 0.006
        fileprivate static let captureBoxDashTargetPeriod: Float = 0.018
        fileprivate static let captureBoxMaximumDashCount = 24
        fileprivate static let captureBoxEdges = [
            (0, 1), (1, 3), (2, 3), (0, 2),
            (4, 5), (5, 7), (6, 7), (4, 6),
            (0, 4), (1, 5), (2, 6), (3, 7)
        ]
        fileprivate static let captureBoxEdgeFaces = [
            (2, 4), (1, 4), (3, 4), (0, 4),
            (2, 5), (1, 5), (3, 5), (0, 5),
            (0, 2), (1, 2), (0, 3), (1, 3)
        ]
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
        /// Mask surfels are octahedra rather than the tetrahedra used for
        /// selection points: an octahedron presents the same silhouette radius
        /// from every direction, so the overlay keeps a uniform density however
        /// the operator circles the object, for only six vertices.
        fileprivate static let maskSurfelOffsets = [
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(-1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, -1, 0),
            SIMD3<Float>(0, 0, 1),
            SIMD3<Float>(0, 0, -1)
        ]
        fileprivate static let maskSurfelIndices: [UInt32] = [
            0, 2, 4,  2, 1, 4,  1, 3, 4,  3, 0, 4,
            2, 0, 5,  1, 2, 5,  3, 1, 5,  0, 3, 5
        ]
        /// The silhouette tier is drawn slightly larger and far more opaque so
        /// the mask keeps the crisp outline the 2D overlay had.
        fileprivate static let maskSurfelBoundaryRadiusScale: Float = 1.35
        fileprivate static let maskSurfelBoundaryAlpha: CGFloat = 0.9
        /// Ceiling on splats drawn per object. Each depth sample of the mask
        /// wants one splat, so an object filling a third of the frame reaches
        /// roughly this many. Beyond it the fill is thinned rather than the
        /// buffers grown, which keeps the per-object mesh under ~3 MB.
        fileprivate static let maskSurfelDisplayLimit = 16_000
        fileprivate static let maskSurfelMinimumCapacity = 2_048

        private let sessionManager: ARSessionManager
        private let mesEngine: MesEngine
        private let captureEngine: ObjectCaptureEngine
        private weak var arView: ARView?
        private var contentAnchor: AnchorEntity?
        private var placedPoints: [PlacedPoint] = []
        private var mesEntities: [ModelEntity] = []
        private var previewMeasurementEntities: [ModelEntity] = []
        private var captureEntitiesByObject: [UUID: [ModelEntity]] = [:]
        private var captureBoxActiveSpanCountsByObject: [UUID: Int] = [:]
        private var captureBoxRearEdgeStatesByObject: [UUID: [Bool]] = [:]
        private var selectionPointMesh: LowLevelMesh?
        private var selectionPointEntity: ModelEntity?
        private var selectionPointMeshCapacity = 0
        private var selectionPointsByObject: [UUID: [SIMD3<Float>]] = [:]
        private var supportAccumulators: [UUID: PointAccumulator] = [:]
        private var maskedAccumulators: [UUID: PointAccumulator] = [:]
        private var newestMaskedPointTimestamp: [UUID: TimeInterval] = [:]
        private var fittedMaskedPointTimestamp: [UUID: TimeInterval] = [:]
        private var liveResultsByObject: [UUID: CaptureResult] = [:]
        // View-gated per-dimension memory: the footprint (width/length/yaw/position) is captured from
        // a top-down view and the height from a side view, and each is remembered so the other
        // viewpoint cannot disturb it (this also stops side-view background points widening W/L).
        private var capturedFootprintByObject: [UUID: ObjectFootprint] = [:]
        private var capturedHeightByObject: [UUID: Float] = [:]
        private var footprintFromTopObjects: Set<UUID> = []
        private var heightFromSideObjects: Set<UUID> = []
        private var acceptedSurfaceVoxelKeysByObject: [UUID: Set<SelectionVoxelKey>] = [:]
        private var manuallyRejectedVoxelKeysByObject: [UUID: Set<SelectionVoxelKey>] = [:]
        private let objectMaskProcessor = ObjectMaskProcessor()
        private let objectMaskDisplayTracker = ObjectMaskDisplayTracker()
        private var objectMaskSurfelSetsByID: [UUID: ObjectMaskSurfelSet] = [:]
        private var objectMaskSurfelEntitiesByID: [UUID: ObjectMaskSurfelEntity] = [:]
        private var scanTickCounter = 0
        private var lastAutomaticPointCleanupTimestamp: TimeInterval = -.greatestFiniteMagnitude
        private var consecutiveMaskMisses = 0
        private var consecutiveLiveMaskMisses = 0
        private var objectMaskTask: Task<Void, Never>?
        private var objectMaskTaskGeneration = 0
        private var lastObjectMaskSubmittedFrameTimestamp: TimeInterval =
            -.greatestFiniteMagnitude
        private var objectMaskDisplayTask: Task<Void, Never>?
        private var objectMaskDisplayTaskGeneration = 0
        private var objectMaskDisplaySeedsByID: [UUID: ObjectMaskDisplaySeed] = [:]
        private var liveObjectMaskDisplayID: UUID?
        private var objectMaskDisplayOrientation: CGImagePropertyOrientation?
        private var pendingObjectMaskToggleRequest: ObjectMaskToggleRequest?
        private var objectMaskToggleAttemptsRemaining = 0
        private var objectMaskAnchors: [UUID: ARAnchor] = [:]
        private var objectMaskMarkerStates: [UUID: ObjectMaskMarkerState] = [:]
        private var objectMaskColorsByID: [UUID: ObjectMaskDisplayColor] = [:]
        private var objectMaskTrackingGeneration = 0
        private var previewTargetPosition: SIMD3<Float>?
        private var lastAimerRaycastTransform: simd_float4x4?
        private var aimerUpdateTimer: Timer?
        private var maskDisplayLink: CADisplayLink?
        private var memoryWarningObserver: NSObjectProtocol?
        private var observedResetRevision = 0
        private var observedPlacementRequestRevision = 0
        private var observedMode: MesMode = .scan
        private var observedCaptureResetRevision = 0
        private var observedObjectMaskToggleRequestRevision = 0
        private var observedObjectWorkflowRequestRevision = 0
        private var observedPointCleanupRequestRevision = 0
        private var observedMeshVisible = false
        private var observedShowsSelectedPoints = false
        private var observedShowsBoundingBoxes = true
        private var observedShowsLockedMaskPreviews = true

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
            observedShowsLockedMaskPreviews =
                captureEngine.showsLockedMaskPreviews
            observedObjectWorkflowRequestRevision =
                captureEngine.objectWorkflowRequestRevision
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
                    self.updateCaptureBoxLineStyles(in: arView)
                }
            }

            let maskDisplayLink = CADisplayLink(
                target: self,
                selector: #selector(updateMaskDisplay)
            )
            maskDisplayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30,
                maximum: 60,
                preferred: 60
            )
            maskDisplayLink.add(to: .main, forMode: .common)
            self.maskDisplayLink = maskDisplayLink

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

        @objc private func updateMaskDisplay() {
            guard let arView else {
                return
            }
            updateFastObjectMaskMarkers(in: arView)
            updateFastObjectMaskPreview(in: arView)
            updateObjectMaskPreview(in: arView)
        }

        func detach() {
            aimerUpdateTimer?.invalidate()
            aimerUpdateTimer = nil
            maskDisplayLink?.invalidate()
            maskDisplayLink = nil
            if let memoryWarningObserver {
                NotificationCenter.default.removeObserver(memoryWarningObserver)
                self.memoryWarningObserver = nil
            }
            objectMaskTask?.cancel()
            objectMaskTaskGeneration &+= 1
            objectMaskTask = nil
            captureEngine.cancelObjectSelection()
            objectMaskDisplayTask?.cancel()
            objectMaskDisplayTaskGeneration &+= 1
            objectMaskDisplayTask = nil
            objectMaskDisplaySeedsByID.removeAll()
            removeAllObjectMaskSurfelOverlays()
            liveObjectMaskDisplayID = nil
            consecutiveLiveMaskMisses = 0
            objectMaskDisplayOrientation = nil
            let displayTracker = objectMaskDisplayTracker
            let trackingGeneration = objectMaskTrackingGeneration
            Task {
                await displayTracker.reset(
                    trackingGeneration: trackingGeneration
                )
            }
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
            objectMaskTaskGeneration &+= 1
            objectMaskTask = nil
            pendingObjectMaskToggleRequest = nil
            objectMaskToggleAttemptsRemaining = 0
            captureEngine.cancelObjectSelection()
            objectMaskDisplayTask?.cancel()
            objectMaskDisplayTaskGeneration &+= 1
            objectMaskDisplayTask = nil
            objectMaskDisplaySeedsByID.removeAll()
            removeAllObjectMaskSurfelOverlays()
            liveObjectMaskDisplayID = nil
            consecutiveLiveMaskMisses = 0
            objectMaskDisplayOrientation = nil
            let displayTracker = objectMaskDisplayTracker
            let trackingGeneration = objectMaskTrackingGeneration
            Task {
                await displayTracker.reset(
                    trackingGeneration: trackingGeneration
                )
            }
            captureEngine.updateObjectMaskDisplayBoundingBoxes([:])
        }

        private func observeEngineRevisions() {
            withObservationTracking {
                _ = mesEngine.placementRequestRevision
                _ = mesEngine.resetRevision
                _ = mesEngine.mode
                _ = captureEngine.resetRevision
                _ = captureEngine.objectMaskToggleRequestRevision
                _ = captureEngine.objectWorkflowRequestRevision
                _ = captureEngine.pointCleanupRequestRevision
                _ = captureEngine.isMeshVisible
                _ = captureEngine.showsSelectedPoints
                _ = captureEngine.showsBoundingBoxes
                _ = captureEngine.showsLockedMaskPreviews
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

            if captureEngine.objectWorkflowRequestRevision
                != observedObjectWorkflowRequestRevision {
                observedObjectWorkflowRequestRevision =
                    captureEngine.objectWorkflowRequestRevision
                applyObjectWorkflowRequest(captureEngine.objectWorkflowRequest)
            }

            if captureEngine.objectMaskToggleRequestRevision != observedObjectMaskToggleRequestRevision {
                observedObjectMaskToggleRequestRevision = captureEngine.objectMaskToggleRequestRevision
                pendingObjectMaskToggleRequest = captureEngine.objectMaskToggleRequest
                objectMaskToggleAttemptsRemaining = 4
            }

            if captureEngine.pointCleanupRequestRevision
                != observedPointCleanupRequestRevision {
                observedPointCleanupRequestRevision = captureEngine.pointCleanupRequestRevision
                if let arView {
                    removeVisiblePointsOutsideCurrentMask(
                        in: arView,
                        reportsFeedback: true
                    )
                } else {
                    captureEngine.failVisiblePointCleanup()
                }
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
                updateMeshVisibility()
            }

            if captureEngine.showsLockedMaskPreviews
                != observedShowsLockedMaskPreviews {
                observedShowsLockedMaskPreviews =
                    captureEngine.showsLockedMaskPreviews
                updateObjectMaskSurfelVisibility()
            }
        }

        private func applyObjectWorkflowRequest(
            _ request: ObjectWorkflowRequest?
        ) {
            guard let request else {
                return
            }
            objectMaskTask?.cancel()
            objectMaskTaskGeneration &+= 1
            objectMaskTask = nil
            pendingObjectMaskToggleRequest = nil
            objectMaskToggleAttemptsRemaining = 0

            switch request.kind {
            case .finalize:
                if let points = liveResultsByObject[request.id]?.surfacePoints {
                    selectionPointsByObject[request.id] = points
                }
                objectMaskDisplayTask?.cancel()
                objectMaskDisplayTaskGeneration &+= 1
                objectMaskDisplayTask = nil
                objectMaskDisplaySeedsByID.removeValue(forKey: request.id)
                captureEngine.clearObjectMaskDisplayTracking(id: request.id)
                if let state = objectMaskMarkerStates[request.id] {
                    objectMaskMarkerStates[request.id] = ObjectMaskMarkerState(
                        color: state.color,
                        isMaskVisible: false
                    )
                }
            case .reactivate:
                fittedMaskedPointTimestamp[request.id] =
                    -.greatestFiniteMagnitude
                removeObjectMaskSurfelOverlay(id: request.id)
                removeLiveObjectMaskDisplaySeed()
                captureEngine.clearLiveObjectMaskPreview()
            case .remove:
                objectMaskDisplayTask?.cancel()
                objectMaskDisplayTaskGeneration &+= 1
                objectMaskDisplayTask = nil
                objectMaskDisplaySeedsByID.removeValue(forKey: request.id)
                captureEngine.clearObjectMaskDisplayTracking(id: request.id)
                removeObjectMaskSurfelOverlay(id: request.id)
                if let anchor = objectMaskAnchors.removeValue(
                    forKey: request.id
                ), let arView {
                    arView.session.remove(anchor: anchor)
                }
                objectMaskMarkerStates.removeValue(forKey: request.id)
                objectMaskColorsByID.removeValue(forKey: request.id)
                supportAccumulators.removeValue(forKey: request.id)
                maskedAccumulators.removeValue(forKey: request.id)
                newestMaskedPointTimestamp.removeValue(forKey: request.id)
                fittedMaskedPointTimestamp.removeValue(forKey: request.id)
                liveResultsByObject.removeValue(forKey: request.id)
                acceptedSurfaceVoxelKeysByObject.removeValue(
                    forKey: request.id
                )
                manuallyRejectedVoxelKeysByObject.removeValue(
                    forKey: request.id
                )
                selectionPointsByObject.removeValue(forKey: request.id)
                clearCaptureContent(for: request.id)
            }
            updateSelectionVisualization()
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
                && !captureEngine.showsBoundingBoxes
            if shouldOcclude {
                arView.environment.sceneUnderstanding.options.insert(.occlusion)
            } else {
                arView.environment.sceneUnderstanding.options.remove(.occlusion)
            }
        }

        private func updateObjectMaskPreview(in arView: ARView) {
            guard mesEngine.mode == .scan,
                  objectMaskTask == nil,
                  let frame = arView.session.currentFrame,
                  frame.timestamp > lastObjectMaskSubmittedFrameTimestamp else {
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
            let input = ObjectMaskFrame(
                pixelBuffer: frame.capturedImage,
                orientation: orientation,
                viewportSize: viewportSize,
                imageToViewportTransform: imageToViewportTransform,
                toggleRequest: toggleRequest,
                anchorHints: objectMaskAnchorHints(frame: frame, in: arView),
                activeObjectID: captureEngine.activeObjectID,
                finalizedObjectIDs: captureEngine.finalizedObjectIDs,
                timestamp: frame.timestamp,
                trackingGeneration: objectMaskTrackingGeneration,
                depthSnapshot: captureEngine.activeObjectID != nil
                    || toggleRequest != nil
                    ? objectMaskDepthSnapshot(from: frame)
                    : nil
            )
            if submittedToggleRequest != nil {
                pendingObjectMaskToggleRequest = nil
                objectMaskToggleAttemptsRemaining = max(objectMaskToggleAttemptsRemaining - 1, 0)
            }
            let processor = objectMaskProcessor
            let submittedResetRevision = captureEngine.resetRevision
            lastObjectMaskSubmittedFrameTimestamp = frame.timestamp
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
                guard self.captureEngine.resetRevision
                        == submittedResetRevision else {
                    return
                }
                guard !wasCancelled, self.mesEngine.mode == .scan else {
                    return
                }

                let previousLockedObjectCount = self.captureEngine.lockedObjectMaskCount
                self.applyObjectMaskLockChange(result.lockChange, in: arView)
                if let lockChange = result.lockChange {
                    switch lockChange.kind {
                    case .added:
                        self.captureEngine.beginObjectMeasurement(id: lockChange.id)
                    case .focused:
                        self.captureEngine.focusFinalizedObject(id: lockChange.id)
                    }
                }
                for cloud in result.maskedPointClouds {
                    guard cloud.id == self.captureEngine.activeObjectID else {
                        continue
                    }
                    // The yellow world-space mask surfels were removed: they rebuilt
                    // up to ~96k vertices per frame purely to visualize the mask and
                    // had no effect on the measurement (which uses `acceptedPoints`
                    // below). The lightweight 2D mask preview remains as the highlight.
                    let acceptedPoints: [SIMD3<Float>]
                    if let rejectedKeys = self.manuallyRejectedVoxelKeysByObject[cloud.id],
                       !rejectedKeys.isEmpty {
                        acceptedPoints = cloud.points.filter {
                            !rejectedKeys.contains(self.selectionVoxelKey(for: $0))
                        }
                    } else {
                        acceptedPoints = cloud.points
                    }
                    guard !acceptedPoints.isEmpty else {
                        continue
                    }
                    if self.maskedAccumulators[cloud.id] == nil {
                        self.maskedAccumulators[cloud.id] = PointAccumulator(
                            voxelSize: ObjectCapturePipeline.voxelSize,
                            maxVoxels: ObjectCapturePipeline.maxObjectVoxels
                        )
                    }
                    let newlyStablePointCount = self.maskedAccumulators[cloud.id]?.add(
                        acceptedPoints,
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
                self.pruneObjectMaskSurfelOverlays()
                for marker in result.markers {
                    self.objectMaskColorsByID[marker.id] = marker.color
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

                if let preview = result.preview,
                   preview.layers.allSatisfy({
                       $0.trackingOrientation
                           == self.objectMaskDisplayOrientation
                   }) {
                    self.consecutiveMaskMisses = 0
                    let includesLiveMask = preview.layers.contains {
                        $0.trackedObjectID == nil
                    }
                    let didAddLock = result.lockChange.map {
                        if case .added = $0.kind {
                            return true
                        }
                        return false
                    } ?? false
                    if includesLiveMask {
                        self.consecutiveLiveMaskMisses = 0
                    } else if didAddLock {
                        self.consecutiveLiveMaskMisses = 3
                    } else {
                        self.consecutiveLiveMaskMisses += 1
                    }
                    self.updateObjectMaskDisplaySeeds(from: preview)
                    self.captureEngine.showObjectMaskPreview(preview)
                    if self.consecutiveLiveMaskMisses >= 3 {
                        self.removeLiveObjectMaskDisplaySeed()
                        self.captureEngine.clearLiveObjectMaskPreview()
                    }
                } else if result.preview == nil {
                    self.consecutiveMaskMisses += 1
                    self.consecutiveLiveMaskMisses += 1
                    if self.consecutiveLiveMaskMisses >= 3 {
                        self.removeLiveObjectMaskDisplaySeed()
                        self.captureEngine.clearLiveObjectMaskPreview()
                    }
                    if result.lockedObjectCount == 0,
                       result.didToggleLock
                        || result.lockedObjectCount < previousLockedObjectCount
                        || self.consecutiveMaskMisses >= 3 {
                        self.captureEngine.clearObjectMaskPreview()
                    }
                }
            }
        }

        private func updateFastObjectMaskPreview(in arView: ARView) {
            guard mesEngine.mode == .scan,
                  let frame = arView.session.currentFrame else {
                return
            }
            let orientation = cameraImageOrientation(in: arView)
            if objectMaskDisplayOrientation != orientation {
                objectMaskDisplayOrientation = orientation
                objectMaskDisplayTask?.cancel()
                objectMaskDisplayTaskGeneration &+= 1
                objectMaskDisplayTask = nil
                objectMaskDisplaySeedsByID.removeAll()
                liveObjectMaskDisplayID = nil
                captureEngine.clearTransientObjectMaskPreviews()
            }
            guard objectMaskDisplayTask == nil,
                  !objectMaskDisplaySeedsByID.isEmpty else {
                if objectMaskDisplaySeedsByID.isEmpty {
                    captureEngine.updateObjectMaskDisplayBoundingBoxes([:])
                }
                return
            }

            let input = ObjectMaskDisplayFrame(
                pixelBuffer: frame.capturedImage,
                orientation: orientation,
                imageToViewportTransform: frame.displayTransform(
                    for: interfaceOrientation(in: arView),
                    viewportSize: arView.bounds.size
                ),
                timestamp: frame.timestamp,
                trackingGeneration: objectMaskTrackingGeneration
            )
            let seeds = Array(objectMaskDisplaySeedsByID.values)
            let submittedSeedTimestamps = Dictionary(
                uniqueKeysWithValues: seeds.map { ($0.id, $0.timestamp) }
            )
            let tracker = objectMaskDisplayTracker
            objectMaskDisplayTaskGeneration &+= 1
            let taskGeneration = objectMaskDisplayTaskGeneration

            objectMaskDisplayTask = Task { [weak self] in
                let boundingBoxes = await tracker.boundingBoxes(
                    for: input,
                    seeds: seeds
                )
                let wasCancelled = Task.isCancelled
                guard let self,
                      self.objectMaskDisplayTaskGeneration == taskGeneration else {
                    return
                }

                self.objectMaskDisplayTask = nil
                guard !wasCancelled, self.mesEngine.mode == .scan else {
                    return
                }
                var applicableBoundingBoxes = self.captureEngine
                    .objectMaskDisplayBoundingBoxes
                    .filter {
                        self.objectMaskDisplaySeedsByID[$0.key] != nil
                    }
                for (id, timestamp) in submittedSeedTimestamps
                where self.objectMaskDisplaySeedsByID[id]?.timestamp == timestamp {
                    if let boundingBox = boundingBoxes[id] {
                        applicableBoundingBoxes[id] = boundingBox
                    }
                }
                self.captureEngine.updateObjectMaskDisplayBoundingBoxes(
                    applicableBoundingBoxes
                )
            }
        }

        private func updateObjectMaskDisplaySeeds(from preview: ObjectMaskPreview) {
            if let incomingLiveLayer = preview.layers.first(where: {
                $0.trackedObjectID == nil
            }) {
                if let liveObjectMaskDisplayID,
                   liveObjectMaskDisplayID != incomingLiveLayer.id {
                    objectMaskDisplaySeedsByID.removeValue(
                        forKey: liveObjectMaskDisplayID
                    )
                }
                liveObjectMaskDisplayID = incomingLiveLayer.id
            }
            for layer in preview.layers {
                guard let boundingBox = layer.trackingBoundingBox else {
                    continue
                }
                objectMaskDisplaySeedsByID[layer.id] = ObjectMaskDisplaySeed(
                    id: layer.id,
                    boundingBox: boundingBox,
                    orientation: layer.trackingOrientation,
                    preservesState: layer.trackedObjectID != nil,
                    timestamp: preview.timestamp
                )
            }
        }

        private func removeLiveObjectMaskDisplaySeed() {
            guard let liveObjectMaskDisplayID else {
                return
            }
            objectMaskDisplaySeedsByID.removeValue(
                forKey: liveObjectMaskDisplayID
            )
            self.liveObjectMaskDisplayID = nil
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

        private func removeVisiblePointsOutsideCurrentMask(
            in arView: ARView,
            reportsFeedback: Bool
        ) {
            guard mesEngine.mode == .scan,
                  sessionManager.isAutomaticObjectCaptureSupported,
                  sessionManager.isTrackingReady,
                  let frame = arView.session.currentFrame,
                  let objectID = captureEngine.activeObjectID,
                  var accumulator = maskedAccumulators[objectID],
                  let result = liveResultsByObject[objectID],
                  result.selectionPoints.count == result.surfacePoints.count,
                  !result.surfacePoints.isEmpty,
                  let layer = captureEngine.objectMaskPreview?.layers.first(where: {
                      $0.trackedObjectID == objectID
                  }),
                  layer.trackingOrientation == cameraImageOrientation(in: arView),
                  let marker = captureEngine.objectMaskMarkers.first(where: {
                      $0.id == objectID
                  }),
                  marker.isMaskVisible,
                  objectMaskMarkerStates[objectID]?.isMaskVisible == true,
                  let alphaMap = ObjectMaskAlphaMap(layer.image),
                  let sceneDepth = frame.sceneDepth,
                  arView.bounds.width > 0,
                  arView.bounds.height > 0 else {
                if reportsFeedback {
                    captureEngine.failVisiblePointCleanup()
                }
                return
            }

            let viewportSize = arView.bounds.size
            let orientation = interfaceOrientation(in: arView)
            let imageToViewport = frame.displayTransform(
                for: orientation,
                viewportSize: viewportSize
            )
            guard abs(
                imageToViewport.a * imageToViewport.d
                    - imageToViewport.b * imageToViewport.c
            ) > 0.000001 else {
                if reportsFeedback {
                    captureEngine.failVisiblePointCleanup()
                }
                return
            }
            let viewportToImage = imageToViewport.inverted()
            let referencePoint = layer.referenceAnchorPoint
                ?? CGPoint(x: 0.5, y: 0.5)
            let distanceScale: CGFloat
            if let referenceDistance = layer.referenceCameraDistance,
               referenceDistance > 0.05,
               marker.cameraDistance > 0.05 {
                distanceScale = min(
                    max(CGFloat(referenceDistance / marker.cameraDistance), 0.4),
                    2.5
                )
            } else {
                distanceScale = 1
            }

            let transformAnchor: CGPoint
            let transformOffset: CGPoint
            if let referenceBox = layer.referenceViewportBoundingBox,
               let currentBox = captureEngine.objectMaskDisplayBoundingBoxes[layer.id],
               referenceBox.width >= 0.005,
               referenceBox.height >= 0.005,
               currentBox.width >= 0.005,
               currentBox.height >= 0.005 {
                transformAnchor = CGPoint(
                    x: referenceBox.midX,
                    y: referenceBox.midY
                )
                transformOffset = CGPoint(
                    x: currentBox.midX - referenceBox.midX,
                    y: currentBox.midY - referenceBox.midY
                )
            } else {
                transformAnchor = referencePoint
                transformOffset = CGPoint(
                    x: marker.normalizedViewportPoint.x - referencePoint.x,
                    y: marker.normalizedViewportPoint.y - referencePoint.y
                )
            }

            let depthMap = sceneDepth.depthMap
            let confidenceMap = sceneDepth.confidenceMap
            let depthWidth = CVPixelBufferGetWidth(depthMap)
            let depthHeight = CVPixelBufferGetHeight(depthMap)
            let confidenceWidth = confidenceMap.map(CVPixelBufferGetWidth) ?? 0
            let confidenceHeight = confidenceMap.map(CVPixelBufferGetHeight) ?? 0
            let worldToCamera = frame.camera.transform.inverse
            let pairs = zip(
                result.selectionPoints,
                result.surfacePoints
            ).map { (selection: $0.0, surface: $0.1) }
            let maskSampleRadius = 2
            let viewportBorderX = max(
                2 / viewportSize.width,
                CGFloat(maskSampleRadius) * distanceScale / CGFloat(alphaMap.width)
            )
            let viewportBorderY = max(
                2 / viewportSize.height,
                CGFloat(maskSampleRadius) * distanceScale / CGFloat(alphaMap.height)
            )

            guard CVPixelBufferLockBaseAddress(depthMap, .readOnly)
                == kCVReturnSuccess else {
                if reportsFeedback {
                    captureEngine.failVisiblePointCleanup()
                }
                return
            }
            if let confidenceMap {
                guard CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
                    == kCVReturnSuccess else {
                    CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
                    if reportsFeedback {
                        captureEngine.failVisiblePointCleanup()
                    }
                    return
                }
            }
            guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
                if let confidenceMap {
                    CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
                }
                if reportsFeedback {
                    captureEngine.failVisiblePointCleanup()
                }
                return
            }
            let confidenceBase: UnsafeMutableRawPointer?
            if let confidenceMap {
                guard let base = CVPixelBufferGetBaseAddress(confidenceMap) else {
                    CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
                    CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
                    if reportsFeedback {
                        captureEngine.failVisiblePointCleanup()
                    }
                    return
                }
                confidenceBase = base
            } else {
                confidenceBase = nil
            }
            let removedIndices: Set<Int> = {
                defer {
                    CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
                    if let confidenceMap {
                        CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
                    }
                }
                let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
                let confidenceRowBytes = confidenceMap.map {
                    CVPixelBufferGetBytesPerRow($0)
                } ?? 0
                var removed: Set<Int> = []

                for index in pairs.indices {
                    let surfacePoint = pairs[index].surface
                    let cameraPoint = worldToCamera * SIMD4<Float>(surfacePoint, 1)
                    guard cameraPoint.z < -0.02 else {
                        continue
                    }
                    let projected = frame.camera.projectPoint(
                        surfacePoint,
                        orientation: orientation,
                        viewportSize: viewportSize
                    )
                    let viewportPoint = CGPoint(
                        x: projected.x / viewportSize.width,
                        y: projected.y / viewportSize.height
                    )
                    guard viewportPoint.x >= viewportBorderX,
                          viewportPoint.x <= 1 - viewportBorderX,
                          viewportPoint.y >= viewportBorderY,
                          viewportPoint.y <= 1 - viewportBorderY else {
                        continue
                    }

                    let imagePoint = viewportPoint.applying(viewportToImage)
                    guard (0 ... 1).contains(imagePoint.x),
                          (0 ... 1).contains(imagePoint.y) else {
                        continue
                    }
                    let centerX = min(
                        max(Int(imagePoint.x * CGFloat(depthWidth)), 0),
                        depthWidth - 1
                    )
                    let centerY = min(
                        max(Int(imagePoint.y * CGFloat(depthHeight)), 0),
                        depthHeight - 1
                    )
                    let pointDepth = -cameraPoint.z
                    func validDepth(x: Int, y: Int) -> Float? {
                        let depthRow = depthBase
                            .advanced(by: y * depthRowBytes)
                            .assumingMemoryBound(to: Float32.self)
                        if let confidenceBase,
                           confidenceWidth > 0,
                           confidenceHeight > 0 {
                            let confidenceX = min(
                                x * confidenceWidth / depthWidth,
                                confidenceWidth - 1
                            )
                            let confidenceY = min(
                                y * confidenceHeight / depthHeight,
                                confidenceHeight - 1
                            )
                            let confidenceRow = confidenceBase
                                .advanced(by: confidenceY * confidenceRowBytes)
                                .assumingMemoryBound(to: UInt8.self)
                            if confidenceRow[confidenceX] < 1 {
                                return nil
                            }
                        }
                        let measuredDepth = depthRow[x]
                        guard measuredDepth > 0.15,
                              measuredDepth < 3.5 else {
                            return nil
                        }
                        return measuredDepth
                    }

                    let visibleDepth: Float?
                    if let centerDepth = validDepth(x: centerX, y: centerY) {
                        visibleDepth = centerDepth
                    } else {
                        var neighborhoodDepths: [Float] = []
                        neighborhoodDepths.reserveCapacity(8)
                        for y in max(centerY - 1, 0) ... min(centerY + 1, depthHeight - 1) {
                            for x in max(centerX - 1, 0) ... min(centerX + 1, depthWidth - 1)
                            where x != centerX || y != centerY {
                                if let depth = validDepth(x: x, y: y) {
                                    neighborhoodDepths.append(depth)
                                }
                            }
                        }
                        neighborhoodDepths.sort()
                        if neighborhoodDepths.isEmpty {
                            visibleDepth = nil
                        } else {
                            visibleDepth = neighborhoodDepths[
                                neighborhoodDepths.count / 2
                            ]
                        }
                    }
                    guard let visibleDepth else {
                        continue
                    }
                    let occlusionTolerance = max(0.025, visibleDepth * 0.03)
                    guard pointDepth <= visibleDepth + occlusionTolerance else {
                        continue
                    }

                    let sourcePoint = CGPoint(
                        x: transformAnchor.x
                            + (
                                viewportPoint.x
                                    - transformOffset.x
                                    - transformAnchor.x
                            ) / distanceScale,
                        y: transformAnchor.y
                            + (
                                viewportPoint.y
                                    - transformOffset.y
                                    - transformAnchor.y
                            ) / distanceScale
                    )
                    if !alphaMap.contains(sourcePoint, radius: maskSampleRadius) {
                        removed.insert(index)
                    }
                }
                return removed
            }()

            guard !removedIndices.isEmpty else {
                if reportsFeedback {
                    captureEngine.finishVisiblePointCleanup(removedCount: 0)
                }
                return
            }

            let removedPairs = pairs.enumerated().compactMap {
                removedIndices.contains($0.offset) ? $0.element : nil
            }
            let retainedPairs = pairs.enumerated().compactMap {
                removedIndices.contains($0.offset) ? nil : $0.element
            }
            let removedSelections = removedPairs.map(\.selection)
            accumulator.removeVoxels(
                containing: removedPairs.flatMap {
                    [$0.selection, $0.surface]
                }
            )
            maskedAccumulators[objectID] = accumulator
            manuallyRejectedVoxelKeysByObject[objectID, default: []].formUnion(
                removedPairs.flatMap {
                    [
                        selectionVoxelKey(for: $0.selection),
                        selectionVoxelKey(for: $0.surface)
                    ]
                }
            )

            let retainedSelectionPoints = retainedPairs.map(\.selection)
            let retainedSurfacePoints = retainedPairs.map(\.surface)
            let cleanedObject = CapturedObject(
                dimensions: result.object.dimensions,
                center: result.object.center,
                axes: result.object.axes,
                corners: result.object.corners,
                volume: result.object.volume,
                sampleCount: retainedSurfacePoints.count
            )
            liveResultsByObject[objectID] = CaptureResult(
                object: cleanedObject,
                selectionPoints: retainedSelectionPoints,
                surfacePoints: retainedSurfacePoints
            )
            acceptedSurfaceVoxelKeysByObject[objectID] = Set(
                retainedSelectionPoints.filter {
                    result.object.contains(
                        $0,
                        tolerance: ObjectCapturePipeline.selectionTolerance
                    )
                }.map(selectionVoxelKey(for:))
            )
            fittedMaskedPointTimestamp[objectID] = -.greatestFiniteMagnitude
            selectionPointsByObject[objectID] = retainedSurfacePoints
            updateSelectionVisualization()
            captureEngine.updateCapture(id: objectID, object: cleanedObject)
            if reportsFeedback {
                captureEngine.finishVisiblePointCleanup(
                    removedCount: removedSelections.count
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
            return ObjectMaskDepthSnapshot(
                depthMap: sceneDepth.depthMap,
                confidenceMap: sceneDepth.confidenceMap,
                cameraTransform: frame.camera.transform,
                cameraIntrinsics: frame.camera.intrinsics,
                cameraImageResolution: frame.camera.imageResolution
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
                removeObjectMaskSurfelOverlay(id: change.id)
                supportAccumulators[change.id] = PointAccumulator(
                    voxelSize: ObjectCapturePipeline.supportVoxelSize,
                    maxVoxels: 4_000
                )
                newestMaskedPointTimestamp.removeValue(forKey: change.id)
                fittedMaskedPointTimestamp.removeValue(forKey: change.id)
                liveResultsByObject.removeValue(forKey: change.id)
                capturedFootprintByObject.removeValue(forKey: change.id)
                capturedHeightByObject.removeValue(forKey: change.id)
                footprintFromTopObjects.remove(change.id)
                heightFromSideObjects.remove(change.id)
                acceptedSurfaceVoxelKeysByObject.removeValue(forKey: change.id)
                manuallyRejectedVoxelKeysByObject.removeValue(forKey: change.id)
                let anchor = ARAnchor(name: "payload-mask-\(change.id.uuidString)", transform: transform)
                arView.session.add(anchor: anchor)
                objectMaskAnchors[change.id] = anchor
            case .focused:
                break
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
                  let activeObjectID = captureEngine.activeObjectID,
                  objectMaskAnchors[activeObjectID] != nil else {
                return
            }

            if frame.timestamp - lastAutomaticPointCleanupTimestamp >= 2 {
                lastAutomaticPointCleanupTimestamp = frame.timestamp
                if !captureEngine.isPointCleanupInProgress {
                    removeVisiblePointsOutsideCurrentMask(
                        in: arView,
                        reportsFeedback: false
                    )
                }
            }

            let visibleHints = objectMaskAnchorHints(frame: frame, in: arView).filter {
                $0.id == activeObjectID && $0.normalizedViewportPoint != nil
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
                supportAccumulators[activeObjectID]?.pruneTransient(
                        below: ObjectCapturePipeline.minObservations,
                        olderThan: 8
                    )
                supportAccumulators[activeObjectID]?.pruneStale(olderThan: 90)
                maskedAccumulators[activeObjectID]?.pruneTransient(
                        below: ObjectCapturePipeline.minObservations,
                        olderThan: 8
                    )
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
                            selectionPointsByObject[id] =
                                retainedResult.surfacePoints
                            updateSelectionVisualization()
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
                selectionPointsByObject[id] = acceptedResult.surfacePoints
                updateSelectionVisualization()
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
                let displayBox = viewGatedBox(
                    fitted: acceptedResult.object,
                    id: id,
                    base: planeSupportHeight,
                    camera: frame.camera.transform,
                    isActive: id == activeObjectID
                )
                addCapturedBox(displayBox, for: id)
                captureEngine.updateCapture(id: id, object: displayBox)
            }

            if liveResultsByObject[activeObjectID] != nil {
                captureEngine.focusCapture(id: activeObjectID)
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
            manuallyRejectedVoxelKeysByObject.removeAll()
            scanTickCounter = 0
            resetObjectMaskTracking()
        }

        private func resetObjectMaskTracking() {
            objectMaskTrackingGeneration &+= 1
            objectMaskTask?.cancel()
            objectMaskTaskGeneration &+= 1
            objectMaskTask = nil
            lastObjectMaskSubmittedFrameTimestamp = -.greatestFiniteMagnitude
            objectMaskDisplayTask?.cancel()
            objectMaskDisplayTaskGeneration &+= 1
            objectMaskDisplayTask = nil
            objectMaskDisplaySeedsByID.removeAll()
            removeAllObjectMaskSurfelOverlays()
            liveObjectMaskDisplayID = nil
            consecutiveLiveMaskMisses = 0
            objectMaskDisplayOrientation = nil
            let displayTracker = objectMaskDisplayTracker
            let trackingGeneration = objectMaskTrackingGeneration
            Task {
                await displayTracker.reset(
                    trackingGeneration: trackingGeneration
                )
            }
            pendingObjectMaskToggleRequest = nil
            consecutiveMaskMisses = 0
            consecutiveLiveMaskMisses = 0
            maskedAccumulators.removeAll()
            supportAccumulators.removeAll()
            newestMaskedPointTimestamp.removeAll()
            fittedMaskedPointTimestamp.removeAll()
            liveResultsByObject.removeAll()
            acceptedSurfaceVoxelKeysByObject.removeAll()
            manuallyRejectedVoxelKeysByObject.removeAll()
            removeAllObjectMaskAnchors()
            objectMaskMarkerStates.removeAll()
            objectMaskColorsByID.removeAll()
            captureEngine.updateLockedObjectMaskCount(0)
            captureEngine.updateObjectMaskTracking(visibleCount: 0, markers: [])
            captureEngine.updateObjectMaskDisplayBoundingBoxes([:])
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
            objectMaskColorsByID.removeAll()
            maskedAccumulators.removeAll()
            supportAccumulators.removeAll()
            removeAllObjectMaskSurfelOverlays()
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

        private func updateCaptureBoxLineStyles(in arView: ARView) {
            let objectIDs = Array(captureEntitiesByObject.keys)
            guard captureEngine.showsBoundingBoxes, !objectIDs.isEmpty else {
                return
            }
            let cameraPosition = arView.cameraTransform.translation
            for objectID in objectIDs {
                guard let object = liveResultsByObject[objectID]?.object
                        ?? captureEngine.capturedObjectsByID[objectID] else {
                    continue
                }
                renderCapturedBox(
                    object,
                    for: objectID,
                    cameraPosition: cameraPosition
                )
            }
        }

        private func captureBoxLineSpans(
            for object: CapturedObject,
            objectID: UUID,
            cameraPosition: SIMD3<Float>
        ) -> [(start: SIMD3<Float>, end: SIMD3<Float>)] {
            guard object.corners.count == 8 else {
                return []
            }
            let rearEdges = captureBoxRearEdges(
                for: object,
                objectID: objectID,
                cameraPosition: cameraPosition
            )
            var spans: [(start: SIMD3<Float>, end: SIMD3<Float>)] = []
            spans.reserveCapacity(Self.captureBoxEdges.count * 3)
            for (edgeIndex, edge) in Self.captureBoxEdges.enumerated() {
                let start = object.corners[edge.0]
                let end = object.corners[edge.1]
                if rearEdges[edgeIndex] {
                    spans.append(contentsOf: dashedCaptureBoxSpans(from: start, to: end))
                } else {
                    spans.append((start: start, end: end))
                }
            }
            return spans
        }

        private func captureBoxRearEdges(
            for object: CapturedObject,
            objectID: UUID,
            cameraPosition: SIMD3<Float>
        ) -> [Bool] {
            let half = object.dimensions / 2
            let normals = [
                -object.axes.width,
                object.axes.width,
                -object.axes.depth,
                object.axes.depth,
                -object.axes.height,
                object.axes.height
            ]
            let centers = [
                object.center - object.axes.width * half.x,
                object.center + object.axes.width * half.x,
                object.center - object.axes.depth * half.y,
                object.center + object.axes.depth * half.y,
                object.center - object.axes.height * half.z,
                object.center + object.axes.height * half.z
            ]
            let faceDistances = zip(normals, centers).map {
                simd_dot(cameraPosition - $0.1, $0.0)
            }
            let previous = captureBoxRearEdgeStatesByObject[objectID]
            let margin: Float = 0.004
            let states = Self.captureBoxEdgeFaces.enumerated().map { index, faces in
                let first = faceDistances[faces.0]
                let second = faceDistances[faces.1]
                guard previous?.count == Self.captureBoxEdges.count else {
                    return first <= 0 && second <= 0
                }
                if previous![index] {
                    return first <= margin && second <= margin
                }
                return first < -margin && second < -margin
            }
            captureBoxRearEdgeStatesByObject[objectID] = states
            return states
        }

        private func dashedCaptureBoxSpans(
            from start: SIMD3<Float>,
            to end: SIMD3<Float>
        ) -> [(start: SIMD3<Float>, end: SIMD3<Float>)] {
            let delta = end - start
            let length = simd_length(delta)
            guard length > 0.001 else {
                return []
            }
            let dashCount = min(
                max(Int((length / Self.captureBoxDashTargetPeriod).rounded()), 2),
                Self.captureBoxMaximumDashCount
            )
            let intervalCount = dashCount * 2 - 1
            return (0..<dashCount).map { index in
                let firstT = Float(index * 2) / Float(intervalCount)
                let lastT = Float(index * 2 + 1) / Float(intervalCount)
                return (
                    start: start + delta * firstT,
                    end: start + delta * lastT
                )
            }
        }

        private func capturedBoxMaterial(for id: UUID) -> UnlitMaterial {
            let color = objectMaskColorsByID[id]
                ?? objectMaskMarkerStates[id]?.color
                ?? ObjectMaskDisplayColor(red: 0.20, green: 0.95, blue: 0.42)
            return UnlitMaterial(
                color: UIColor(
                    red: CGFloat(color.red),
                    green: CGFloat(color.green),
                    blue: CGFloat(color.blue),
                    alpha: 1
                ),
                applyPostProcessToneMap: false
            )
        }

        private func renderCapturedBoxSpans(
            _ spans: [(start: SIMD3<Float>, end: SIMD3<Float>)],
            for objectID: UUID,
            material: UnlitMaterial? = nil
        ) {
            guard let contentAnchor else {
                return
            }
            let renderableSpans = spans.filter {
                simd_length($0.end - $0.start) > 0.001
            }
            var entities = captureEntitiesByObject[objectID] ?? []
            if entities.count < renderableSpans.count {
                let entityMaterial = material
                    ?? capturedBoxMaterial(for: objectID)
                while entities.count < renderableSpans.count {
                    let entity = ModelEntity(
                        mesh: Self.unitCubeMesh,
                        materials: [entityMaterial]
                    )
                    contentAnchor.addChild(entity)
                    entities.append(entity)
                }
            }
            for (index, span) in renderableSpans.enumerated() {
                updateCapturedBoxEdge(
                    entities[index],
                    from: span.start,
                    to: span.end,
                    material: material
                )
            }
            if entities.count > renderableSpans.count {
                for index in renderableSpans.count..<entities.count {
                    entities[index].isEnabled = false
                }
            }
            captureEntitiesByObject[objectID] = entities
            captureBoxActiveSpanCountsByObject[objectID] = renderableSpans.count
        }

        private func renderCapturedBox(
            _ object: CapturedObject,
            for id: UUID,
            cameraPosition: SIMD3<Float>?,
            material: UnlitMaterial? = nil
        ) {
            let spans: [(start: SIMD3<Float>, end: SIMD3<Float>)]
            if let cameraPosition {
                spans = captureBoxLineSpans(
                    for: object,
                    objectID: id,
                    cameraPosition: cameraPosition
                )
            } else {
                spans = Self.captureBoxEdges.map {
                    (
                        start: object.corners[$0.0],
                        end: object.corners[$0.1]
                    )
                }
            }
            renderCapturedBoxSpans(spans, for: id, material: material)
        }

        private func addCapturedBox(_ object: CapturedObject, for id: UUID) {
            guard object.corners.count == 8 else {
                return
            }

            renderCapturedBox(
                object,
                for: id,
                cameraPosition: arView?.cameraTransform.translation,
                material: capturedBoxMaterial(for: id)
            )
        }

        private func updateCapturedBoxEdge(
            _ bar: ModelEntity,
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            material: UnlitMaterial?
        ) {
            let delta = end - start
            let length = simd_length(delta)

            guard length > 0.001 else {
                bar.isEnabled = false
                return
            }

            if let material, var model = bar.model {
                model.materials = [material]
                bar.model = model
            }
            bar.scale = SIMD3<Float>(
                length,
                Self.captureBoxEdgeThickness,
                Self.captureBoxEdgeThickness
            )
            bar.position = start + delta / 2
            bar.orientation = orientation(alongX: delta)
            bar.isEnabled = captureEngine.showsBoundingBoxes
        }

        private func updateCaptureBoxVisibility() {
            if captureEngine.showsBoundingBoxes {
                if let arView {
                    updateCaptureBoxLineStyles(in: arView)
                } else {
                    for (objectID, entities) in captureEntitiesByObject {
                        let activeCount = captureBoxActiveSpanCountsByObject[objectID] ?? 0
                        for (index, entity) in entities.enumerated() {
                            entity.isEnabled = index < activeCount
                        }
                    }
                }
            } else {
                for entities in captureEntitiesByObject.values {
                    for entity in entities {
                        entity.isEnabled = false
                    }
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

        private func clearAllCaptureContent() {
            for entities in captureEntitiesByObject.values {
                for entity in entities {
                    entity.removeFromParent()
                }
            }
            captureEntitiesByObject.removeAll()
            captureBoxActiveSpanCountsByObject.removeAll()
            captureBoxRearEdgeStatesByObject.removeAll()
            capturedFootprintByObject.removeAll()
            capturedHeightByObject.removeAll()
            footprintFromTopObjects.removeAll()
            heightFromSideObjects.removeAll()
            hideAllSelectionMarkers()
            selectionPointsByObject.removeAll()
        }

        private func clearCaptureContent(for id: UUID) {
            for entity in captureEntitiesByObject.removeValue(forKey: id) ?? [] {
                entity.removeFromParent()
            }
            captureBoxActiveSpanCountsByObject.removeValue(forKey: id)
            captureBoxRearEdgeStatesByObject.removeValue(forKey: id)
            capturedFootprintByObject.removeValue(forKey: id)
            capturedHeightByObject.removeValue(forKey: id)
            footprintFromTopObjects.remove(id)
            heightFromSideObjects.remove(id)
        }

        // MARK: - View-gated per-dimension capture

        /// Classifies the camera viewpoint relative to gravity: a top-down view sees the footprint
        /// (width × length), a side view sees the height. `camera` is the ARKit camera transform.
        private func classifyView(_ camera: simd_float4x4) -> ObjectCaptureEngine.ScanViewHint {
            // ARKit cameras look down their local -Z. Its world Y component tells us the pitch.
            let forwardY = -camera.columns.2.y
            if forwardY < -0.55 {
                return .topDown
            }
            if abs(forwardY) < 0.4 {
                return .side
            }
            return .other
        }

        /// Wraps a freshly fitted box with per-dimension memory: width/length come from the last
        /// top-down view and height from the last side view. This is what makes the measurement
        /// "remember" each face and stops a side view (where background points can appear behind the
        /// object) from widening the footprint, and a top view from disturbing the height.
        private func viewGatedBox(
            fitted: CapturedObject,
            id: UUID,
            base: Float?,
            camera: simd_float4x4,
            isActive: Bool
        ) -> CapturedObject {
            let up = SIMD3<Float>(0, 1, 0)
            let view = classifyView(camera)

            var candidateAxis = SIMD3<Float>(fitted.axes.width.x, 0, fitted.axes.width.z)
            if simd_length(candidateAxis) < 1e-4 {
                candidateAxis = SIMD3<Float>(1, 0, 0)
            }
            candidateAxis = simd_normalize(candidateAxis)
            let candidateFootprint = ObjectFootprint(
                widthAxis: candidateAxis,
                width: fitted.dimensions.x,
                depth: fitted.dimensions.y,
                centerXZ: SIMD2<Float>(fitted.center.x, fitted.center.z)
            )
            let candidateHeight = fitted.dimensions.z
            let baseY = base ?? (fitted.center.y - fitted.dimensions.z / 2)

            // Bootstrap so a box appears immediately, before an ideal view has been shown.
            if capturedFootprintByObject[id] == nil {
                capturedFootprintByObject[id] = candidateFootprint
            }
            if capturedHeightByObject[id] == nil {
                capturedHeightByObject[id] = candidateHeight
            }

            switch view {
            case .topDown:
                capturedFootprintByObject[id] = alignFootprint(
                    candidateFootprint,
                    to: capturedFootprintByObject[id]
                )
                footprintFromTopObjects.insert(id)
            case .side:
                capturedHeightByObject[id] = candidateHeight
                heightFromSideObjects.insert(id)
            case .other:
                break
            }

            if isActive {
                captureEngine.updateScanGuidance(
                    view: view,
                    footprintFromTop: footprintFromTopObjects.contains(id),
                    heightFromSide: heightFromSideObjects.contains(id)
                )
            }

            let footprint = capturedFootprintByObject[id] ?? candidateFootprint
            let height = capturedHeightByObject[id] ?? candidateHeight
            return makeViewBox(
                footprint: footprint,
                height: height,
                base: baseY,
                up: up,
                sampleCount: fitted.sampleCount
            )
        }

        /// Re-expresses a fresh footprint in the orientation closest to the remembered one, so the
        /// box yaw stays stable across ticks instead of flipping between the min-area axes.
        private func alignFootprint(
            _ candidate: ObjectFootprint,
            to previous: ObjectFootprint?
        ) -> ObjectFootprint {
            guard let previous else {
                return candidate
            }
            let up = SIMD3<Float>(0, 1, 0)
            let perpendicular = simd_normalize(simd_cross(up, candidate.widthAxis))
            let options: [(axis: SIMD3<Float>, width: Float, depth: Float)] = [
                (candidate.widthAxis, candidate.width, candidate.depth),
                (-candidate.widthAxis, candidate.width, candidate.depth),
                (perpendicular, candidate.depth, candidate.width),
                (-perpendicular, candidate.depth, candidate.width)
            ]
            let best = options.max {
                simd_dot($0.axis, previous.widthAxis) < simd_dot($1.axis, previous.widthAxis)
            } ?? options[0]
            return ObjectFootprint(
                widthAxis: best.axis,
                width: best.width,
                depth: best.depth,
                centerXZ: candidate.centerXZ
            )
        }

        /// Builds an axis-aligned-in-its-own-frame box from a horizontal footprint, a height above
        /// the support, and the support height. Corner order matches `ObjectBoundingBox.make`.
        private func makeViewBox(
            footprint: ObjectFootprint,
            height: Float,
            base: Float,
            up: SIMD3<Float>,
            sampleCount: Int
        ) -> CapturedObject {
            let widthAxis = simd_normalize(footprint.widthAxis)
            let depthAxis = simd_normalize(simd_cross(up, widthAxis))
            let clampedHeight = max(height, 0.001)
            let dimensions = SIMD3<Float>(
                max(footprint.width, 0.001),
                max(footprint.depth, 0.001),
                clampedHeight
            )
            let center = SIMD3<Float>(
                footprint.centerXZ.x,
                base + clampedHeight / 2,
                footprint.centerXZ.y
            )
            let half = dimensions / 2
            var corners: [SIMD3<Float>] = []
            corners.reserveCapacity(8)
            for k in 0 ... 1 {
                for j in 0 ... 1 {
                    for i in 0 ... 1 {
                        let signX = Float(i) * 2 - 1
                        let signY = Float(j) * 2 - 1
                        let signZ = Float(k) * 2 - 1
                        corners.append(
                            center
                                + widthAxis * (signX * half.x)
                                + depthAxis * (signY * half.y)
                                + up * (signZ * half.z)
                        )
                    }
                }
            }
            return CapturedObject(
                dimensions: dimensions,
                center: center,
                axes: (widthAxis, depthAxis, up),
                corners: corners,
                volume: dimensions.x * dimensions.y * dimensions.z,
                sampleCount: sampleCount
            )
        }

        private func updateSelectionVisualization() {
            let selectionPoints = selectionPointsByObject.keys
                .sorted { $0.uuidString < $1.uuidString }
                .flatMap { selectionPointsByObject[$0] ?? [] }
            guard captureEngine.showsSelectedPoints, !selectionPoints.isEmpty,
                  let contentAnchor else {
                hideAllSelectionMarkers()
                return
            }

            guard let mesh = selectionPointMesh(
                in: contentAnchor,
                minimumCapacity: selectionPoints.count
            ) else {
                return
            }

            let verticesPerPoint = Self.selectionPointOffsets.count
            let indicesPerPoint = Self.selectionPointIndices.count
            let radius = Self.selectionPointRadius
            mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { buffer in
                let positions = buffer.bindMemory(to: SIMD3<Float>.self)
                for (pointIndex, point) in selectionPoints.enumerated() {
                    let vertexBase = pointIndex * verticesPerPoint
                    for offsetIndex in Self.selectionPointOffsets.indices {
                        positions[vertexBase + offsetIndex] =
                            point + Self.selectionPointOffsets[offsetIndex] * radius
                    }
                }
            }
            mesh.parts.replaceAll([
                LowLevelMesh.Part(
                    indexCount: selectionPoints.count * indicesPerPoint,
                    topology: .triangle,
                    bounds: selectionPointBounds(selectionPoints)
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

        // MARK: - World-anchored mask overlay
        //
        // The mask used to be a bitmap of an older camera frame that the overlay
        // stretched to guess where the object had moved. A similarity transform
        // cannot express perspective, so the silhouette always trailed the
        // object and skewed as soon as two faces of a box were visible at once.
        //
        // Instead the mask-admitted LiDAR surface is uploaded as world-space
        // geometry. RealityKit then draws it in the same pass as the camera
        // background, from the same pose, so registration is exact and free:
        // Vision only has to say *which* surface is masked, and it can take as
        // long as it likes doing so.

        private func updateObjectMaskSurfelOverlay(for id: UUID) {
            guard let set = objectMaskSurfelSetsByID[id],
                  !set.surfels.isEmpty,
                  captureEngine.showsLockedMaskPreviews,
                  let contentAnchor else {
                objectMaskSurfelEntitiesByID[id]?.entity.isEnabled = false
                refreshWorldSurfelMaskObjectIDs()
                return
            }

            let (ordered, fillCount, fillRadiusScale, boundaryRadiusScale) =
                objectMaskSurfelDrawOrder(set.surfels)
            guard !ordered.isEmpty else {
                objectMaskSurfelEntitiesByID[id]?.entity.isEnabled = false
                refreshWorldSurfelMaskObjectIDs()
                return
            }

            guard let overlay = objectMaskSurfelEntity(
                for: id,
                in: contentAnchor,
                minimumCapacity: ordered.count,
                color: set.color,
                fillAlpha: set.fillAlpha
            ) else {
                return
            }
            let verticesPerSurfel = Self.maskSurfelOffsets.count
            let indicesPerSurfel = Self.maskSurfelIndices.count

            overlay.mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { buffer in
                let positions = buffer.bindMemory(to: SIMD3<Float>.self)
                for (surfelIndex, surfel) in ordered.enumerated() {
                    let vertexBase = surfelIndex * verticesPerSurfel
                    let radius = surfel.isBoundary
                        ? surfel.radius * Self.maskSurfelBoundaryRadiusScale
                            * boundaryRadiusScale
                        : surfel.radius * fillRadiusScale
                    for offsetIndex in Self.maskSurfelOffsets.indices {
                        positions[vertexBase + offsetIndex] = surfel.position
                            + Self.maskSurfelOffsets[offsetIndex] * radius
                    }
                }
            }

            let bounds = objectMaskSurfelBounds(
                ordered,
                largestRadiusScale: max(
                    fillRadiusScale,
                    Self.maskSurfelBoundaryRadiusScale * boundaryRadiusScale
                )
            )
            var parts: [LowLevelMesh.Part] = []
            if fillCount > 0 {
                parts.append(
                    LowLevelMesh.Part(
                        indexOffset: 0,
                        indexCount: fillCount * indicesPerSurfel,
                        topology: .triangle,
                        materialIndex: 0,
                        bounds: bounds
                    )
                )
            }
            let boundaryCount = ordered.count - fillCount
            if boundaryCount > 0 {
                parts.append(
                    LowLevelMesh.Part(
                        indexOffset: fillCount * indicesPerSurfel
                            * MemoryLayout<UInt32>.stride,
                        indexCount: boundaryCount * indicesPerSurfel,
                        topology: .triangle,
                        materialIndex: 1,
                        bounds: bounds
                    )
                )
            }
            overlay.mesh.parts.replaceAll(parts)
            overlay.entity.isEnabled = true
            refreshWorldSurfelMaskObjectIDs()
        }

        /// Orders surfels so fill precedes silhouette, and thins the fill if the
        /// object covers more of the frame than the mesh budget allows.
        ///
        /// Fill surfels occupy the low vertex blocks and silhouette surfels the
        /// high ones, which lets the index buffer stay static: it is written once
        /// per capacity, and a keyframe only rewrites positions before splitting
        /// the fixed index range into a fill part and a rim part.
        ///
        /// The silhouette tier gets the budget first — the rim is one sample wide,
        /// so thinning it is immediately visible, whereas thinned fill can be
        /// compensated. Whichever tier is thinned has its splats grown by the
        /// square root of the drop ratio, which preserves covered area and keeps
        /// the overlay solid. The total is capped unconditionally, so the mesh
        /// buffers can never grow past the budget however noisy the depth is.
        private func objectMaskSurfelDrawOrder(
            _ surfels: [ObjectMaskSurfel]
        ) -> (
            ordered: [ObjectMaskSurfel],
            fillCount: Int,
            fillRadiusScale: Float,
            boundaryRadiusScale: Float
        ) {
            var fill: [ObjectMaskSurfel] = []
            var boundary: [ObjectMaskSurfel] = []
            fill.reserveCapacity(surfels.count)
            for surfel in surfels {
                if surfel.isBoundary {
                    boundary.append(surfel)
                } else {
                    fill.append(surfel)
                }
            }

            let budget = Self.maskSurfelDisplayLimit
            var boundaryRadiusScale: Float = 1
            if boundary.count > budget {
                (boundary, boundaryRadiusScale) = Self.thinned(boundary, to: budget)
            }
            var fillRadiusScale: Float = 1
            let fillBudget = max(budget - boundary.count, 0)
            if fill.count > fillBudget {
                (fill, fillRadiusScale) = Self.thinned(fill, to: fillBudget)
            }

            return (
                fill + boundary,
                fill.count,
                fillRadiusScale,
                boundaryRadiusScale
            )
        }

        /// Uniformly strides `surfels` down to at most `limit`, returning the
        /// radius scale that keeps the thinned set covering the same area.
        private static func thinned(
            _ surfels: [ObjectMaskSurfel],
            to limit: Int
        ) -> ([ObjectMaskSurfel], Float) {
            guard limit > 0 else {
                return ([], 1)
            }
            guard surfels.count > limit else {
                return (surfels, 1)
            }
            let step = max(
                Int((Double(surfels.count) / Double(limit)).rounded(.up)),
                1
            )
            var kept: [ObjectMaskSurfel] = []
            kept.reserveCapacity(limit)
            for index in Swift.stride(from: 0, to: surfels.count, by: step) {
                kept.append(surfels[index])
            }
            let scale = (Float(surfels.count) / Float(max(kept.count, 1)))
                .squareRoot()
            return (kept, scale)
        }

        private func objectMaskSurfelEntity(
            for id: UUID,
            in contentAnchor: AnchorEntity,
            minimumCapacity: Int,
            color: ObjectMaskDisplayColor,
            fillAlpha: CGFloat
        ) -> ObjectMaskSurfelEntity? {
            if let existing = objectMaskSurfelEntitiesByID[id],
               existing.capacity >= minimumCapacity {
                existing.entity.model?.materials = objectMaskSurfelMaterials(
                    color: color,
                    fillAlpha: fillAlpha
                )
                return existing
            }

            var capacity = Self.maskSurfelMinimumCapacity
            while capacity < minimumCapacity {
                capacity *= 2
            }
            let verticesPerSurfel = Self.maskSurfelOffsets.count
            let indicesPerSurfel = Self.maskSurfelIndices.count
            let descriptor = LowLevelMesh.Descriptor(
                vertexCapacity: capacity * verticesPerSurfel,
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
                indexCapacity: capacity * indicesPerSurfel,
                indexType: .uint32
            )
            guard let mesh = try? LowLevelMesh(descriptor: descriptor) else {
                return nil
            }
            mesh.replaceUnsafeMutableIndices { buffer in
                let indices = buffer.bindMemory(to: UInt32.self)
                for surfelIndex in 0 ..< capacity {
                    let vertexBase = UInt32(surfelIndex * verticesPerSurfel)
                    let indexBase = surfelIndex * indicesPerSurfel
                    for localIndex in Self.maskSurfelIndices.indices {
                        indices[indexBase + localIndex] =
                            vertexBase + Self.maskSurfelIndices[localIndex]
                    }
                }
            }
            guard let resource = try? MeshResource(from: mesh) else {
                return nil
            }

            let entity = ModelEntity(
                mesh: resource,
                materials: objectMaskSurfelMaterials(
                    color: color,
                    fillAlpha: fillAlpha
                )
            )
            objectMaskSurfelEntitiesByID[id]?.entity.removeFromParent()
            contentAnchor.addChild(entity)
            let overlay = ObjectMaskSurfelEntity(
                mesh: mesh,
                entity: entity,
                capacity: capacity
            )
            objectMaskSurfelEntitiesByID[id] = overlay
            return overlay
        }

        private func objectMaskSurfelMaterials(
            color: ObjectMaskDisplayColor,
            fillAlpha: CGFloat
        ) -> [UnlitMaterial] {
            [
                UnlitMaterial(
                    color: UIColor(
                        red: CGFloat(color.red),
                        green: CGFloat(color.green),
                        blue: CGFloat(color.blue),
                        alpha: fillAlpha
                    ),
                    applyPostProcessToneMap: false
                ),
                UnlitMaterial(
                    color: UIColor(
                        red: CGFloat(color.red),
                        green: CGFloat(color.green),
                        blue: CGFloat(color.blue),
                        alpha: Self.maskSurfelBoundaryAlpha
                    ),
                    applyPostProcessToneMap: false
                )
            ]
        }

        private func objectMaskSurfelBounds(
            _ surfels: [ObjectMaskSurfel],
            largestRadiusScale: Float
        ) -> BoundingBox {
            var minimum = surfels[0].position
            var maximum = surfels[0].position
            var largestRadius = surfels[0].radius
            for surfel in surfels.dropFirst() {
                minimum = simd_min(minimum, surfel.position)
                maximum = simd_max(maximum, surfel.position)
                largestRadius = max(largestRadius, surfel.radius)
            }
            let padding = SIMD3<Float>(
                repeating: largestRadius * largestRadiusScale
            )
            return BoundingBox(min: minimum - padding, max: maximum + padding)
        }

        private func removeObjectMaskSurfelOverlay(id: UUID) {
            objectMaskSurfelSetsByID.removeValue(forKey: id)
            objectMaskSurfelEntitiesByID.removeValue(forKey: id)?
                .entity.removeFromParent()
            refreshWorldSurfelMaskObjectIDs()
        }

        private func removeAllObjectMaskSurfelOverlays() {
            objectMaskSurfelSetsByID.removeAll()
            for overlay in objectMaskSurfelEntitiesByID.values {
                overlay.entity.removeFromParent()
            }
            objectMaskSurfelEntitiesByID.removeAll()
            refreshWorldSurfelMaskObjectIDs()
        }

        private func updateObjectMaskSurfelVisibility() {
            for id in Array(objectMaskSurfelSetsByID.keys) {
                updateObjectMaskSurfelOverlay(for: id)
            }
            refreshWorldSurfelMaskObjectIDs()
        }

        /// Drops overlays for objects that are no longer being measured or kept.
        ///
        /// A surfel overlay is world geometry, so a stale one keeps painting a
        /// surface the app has stopped tracking. Objects that are merely lost
        /// from view are deliberately left alone: their geometry is still correct
        /// where it stands, and it reappears registered when the camera returns.
        private func pruneObjectMaskSurfelOverlays() {
            let retained = Set([captureEngine.activeObjectID].compactMap { $0 })
                .union(captureEngine.finalizedObjectIDs)
            for id in Array(objectMaskSurfelSetsByID.keys)
            where !retained.contains(id) {
                removeObjectMaskSurfelOverlay(id: id)
            }
            for id in Array(objectMaskSurfelEntitiesByID.keys)
            where !retained.contains(id) {
                removeObjectMaskSurfelOverlay(id: id)
            }
        }

        /// Tells the 2D overlay which objects it must not draw. Only objects with
        /// a live, enabled surfel overlay qualify, so if the geometry path ever
        /// fails to build the bitmap path stays visible rather than the mask
        /// disappearing.
        private func refreshWorldSurfelMaskObjectIDs() {
            let ids = Set(
                objectMaskSurfelEntitiesByID
                    .filter { $0.value.entity.isEnabled }
                    .keys
            )
            captureEngine.updateWorldSurfelMaskObjectIDs(ids)
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
