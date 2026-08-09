
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
    let workflowMode: MeasurementWorkflowMode

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionManager: sessionManager,
            mesEngine: mesEngine,
            captureEngine: captureEngine,
            workflowMode: workflowMode
        )
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        context.coordinator.prepareForNewWorld()
        sessionManager.configure(arView.session)
        context.coordinator.attach(to: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.setWorkflowMode(workflowMode)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.detach()
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject, ARCoachingOverlayViewDelegate {
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

        private enum SupportHeightSource: Equatable, Sendable {
            case plane(UUID)
            case raycast
            case depth
        }

        private struct SupportHeightState {
            var recentCandidates: [Float] = []
            var value: Float?
            var source: SupportHeightSource?
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
        fileprivate static let captureBoxEdgeThickness: Float = 0.003
        fileprivate static let captureBoxDashTargetPeriod: Float = 0.018
        fileprivate static let captureBoxMaximumDashCount = 24
        /// Total dash segments a single box may draw, shared across its dashed edges. Keeps the
        /// entity count near the prepared pool so a box never has to build a few hundred entities
        /// in one main-thread pass.
        fileprivate static let captureBoxDashBudget = 60
        fileprivate static let preparedCaptureBoxEntityCount = 48
        // Keep mask cleanup time-sliced so a Lock tap never waits behind a
        // multi-thousand-point projection pass on the main actor.
        fileprivate static let automaticPointCleanupBatchSize = 512
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
        fileprivate static let maximumDisplayedSelectionPointCount = 600
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
        private var workflowMode: MeasurementWorkflowMode
        private weak var arView: ARView?
        private var coachingOverlayView: ARCoachingOverlayView?
        private var contentAnchor: AnchorEntity?
        private var placedPoints: [PlacedPoint] = []
        private var refinementTasks: [UUID: Task<Void, Never>] = [:]
        private var mesEntities: [ModelEntity] = []
        private var previewMeasurementEntities: [ModelEntity] = []
        private var captureEntitiesByObject: [UUID: [ModelEntity]] = [:]
        private var captureAnchorEntitiesByObject: [UUID: AnchorEntity] = [:]
        /// A box normally follows its object anchor while evidence is acquired. Once ARKit has a
        /// definitive supporting plane, presentation is rebound to that exact plane identifier so
        /// later plane refinements keep the bottom face on the physical surface.
        private var capturePresentationPlaneIDsByObject: [UUID: UUID] = [:]
        private var renderAnchorTransformByObject: [UUID: simd_float4x4] = [:]
        /// Last transform from each stored plane snapshot into the plane's latest world pose. It
        /// preserves visual continuity if ARKit removes that identifier while merging planes.
        private var latestPresentationRebaseByObject: [UUID: simd_float4x4] = [:]
        private var objectsAwaitingSupportPlane: Set<UUID> = []
        /// Anchor pose used when the current canonical box was published. It
        /// lets an unlocked box be rebased after ARKit refines that anchor.
        private var publishedAnchorTransformByObject: [UUID: simd_float4x4] = [:]
        /// World frame in which the active voxel evidence was accumulated.
        /// Kept separate from presentation so small anchor refinements can be
        /// rendered coherently and larger ones trigger a clean reacquisition.
        private var evidenceAnchorTransformByObject: [UUID: simd_float4x4] = [:]
        private var captureBoxActiveSpanCountsByObject: [UUID: Int] = [:]
        private var captureBoxRearEdgeStatesByObject: [UUID: [Bool]] = [:]
        private var selectionPointMesh: LowLevelMesh?
        private var selectionPointEntity: ModelEntity?
        private var selectionPointMeshCapacity = 0
        private var rendererWarmupTask: Task<Void, Never>?
        private var captureBoxEntityPool: [ModelEntity] = []
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
        private var supportHeightStateByObject: [UUID: SupportHeightState] = [:]
        private var supportPlaneAnchorIDsByObject: [UUID: UUID] = [:]
        private var fittedSupportHeightByObject: [UUID: Float] = [:]
        private var bootstrapSupportFootprintByObject: [
            UUID: (pointCount: Int, footprint: SupportFootprint)
        ] = [:]
        private var supportRaycastMissTicks: [UUID: Int] = [:]
        private var lastSupportPlaneMatchByObject: [UUID: SupportPlaneMatch] = [:]
        private var supportPlaneMissTicks: [UUID: Int] = [:]
        private var supportRaycastCacheByObject: [
            UUID: (timestamp: TimeInterval, height: Float?)
        ] = [:]
        // "Satisfied" sets: a dimension is added once it has held steady for several fits in its
        // ideal view (the convergence heuristic that tells the operator a face is done).
        private var footprintFromTopObjects: Set<UUID> = []
        private var heightFromSideObjects: Set<UUID> = []
        private var footprintStableTicks: [UUID: Int] = [:]
        private var heightStableTicks: [UUID: Int] = [:]
        private static let dimensionDeadband: Float = 0.004
        private static let dimensionRelativeDeadband: Float = 0.03
        private static let dimensionBlend: Float = 0.35
        private static let positionDeadband: Float = 0.004
        private static let orientationDeadbandDegrees: Float = 1.5
        /// Slower than `dimensionBlend`: yaw is the noisiest output of the footprint fit, and it
        /// is also the change the eye notices most, so it is filtered harder.
        private static let orientationBlend: Float = 0.2
        private static let depthSupportDeadband: Float = 0.001
        private static let depthSupportMaximumStep: Float = 0.002
        private static let supportHistoryCount = 7
        private static let minimumSupportSamples = 3
        private static let satisfiedTickCount = 6
        /// How far outside the object's footprint the support is probed. Large enough to clear
        /// the object's own silhouette in the depth cloud, small enough to stay on the same
        /// physical surface the object rests on.
        private static let supportPerimeterMargin: Float =
            ObjectCapturePipeline.supportExclusionMargin
        private static let supportRaycastLift: Float = 0.05
        private static let supportRaycastNormalTolerance: Float = 0.94
        private static let minimumSupportRaycastHits = 2
        private static let supportRaycastCount = 4
        private static let supportRaycastInterval: TimeInterval = 0.4
        private static let bootstrapFootprintRefreshPoints = 64
        private static let supportRaycastMissTolerance = 4
        private static let supportPlaneMissTolerance = 6
        private static let topAlignmentEnterDegrees: Float = 12
        private static let topAlignmentExitDegrees: Float = 18
        private var topAlignmentAccepted = false
        private var acceptedSurfaceVoxelKeysByObject: [UUID: Set<SelectionVoxelKey>] = [:]
        private var manuallyRejectedVoxelKeysByObject: [UUID: Set<SelectionVoxelKey>] = [:]
        private let objectCaptureFitter = ObjectCaptureFitter()
        private var captureFitTask: Task<Void, Never>?
        private var captureFitTaskGeneration = 0
        private let objectMaskProcessor = ObjectMaskProcessor()
        private let objectMaskDisplayTracker = ObjectMaskDisplayTracker()
        private var scanTickCounter = 0
        private var lastSupportBindingRefreshTimestamp: TimeInterval =
            -.greatestFiniteMagnitude
        private var lastAutomaticPointCleanupTimestamp: TimeInterval = -.greatestFiniteMagnitude
        private var automaticPointCleanupCursorByObject: [UUID: Int] = [:]
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
        private var objectMaskProcessingFailuresRemaining = 0
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
        private var observedMeshVisible = false
        private var observedShowsSelectedPoints = false
        private var observedShowsBoundingBoxes = true
        private var observedFrameEpoch = 0

        init(
            sessionManager: ARSessionManager,
            mesEngine: MesEngine,
            captureEngine: ObjectCaptureEngine,
            workflowMode: MeasurementWorkflowMode
        ) {
            self.sessionManager = sessionManager
            self.mesEngine = mesEngine
            self.captureEngine = captureEngine
            self.workflowMode = workflowMode
        }

        func prepareForNewWorld() {
            mesEngine.reset()
            captureEngine.reset()
        }

        func attach(to arView: ARView) {
            self.arView = arView
            captureEngine.setMeasurementMode(workflowMode)
            installCoachingOverlay(in: arView)
            observedResetRevision = mesEngine.resetRevision
            observedPlacementRequestRevision = mesEngine.placementRequestRevision
            observedMode = mesEngine.mode
            observedCaptureResetRevision = captureEngine.resetRevision
            observedObjectMaskToggleRequestRevision =
                captureEngine.objectMaskToggleRequestRevision
            observedMeshVisible = captureEngine.isMeshVisible
            observedShowsSelectedPoints = captureEngine.showsSelectedPoints
            observedShowsBoundingBoxes = captureEngine.showsBoundingBoxes
            observedObjectWorkflowRequestRevision =
                captureEngine.objectWorkflowRequestRevision
            observedFrameEpoch = sessionManager.frameEpoch
            createContentAnchorIfNeeded(in: arView)
            updateMeshVisibility()

            rendererWarmupTask?.cancel()
            rendererWarmupTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else {
                    return
                }
                await self?.prepareRenderersForFirstCapture()
            }

            aimerUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self, weak arView] _ in
                guard let self, let arView else {
                    return
                }

                Task { @MainActor in
                    // First and unconditional: this is the backstop that applies the pause and
                    // finalize workflow requests, so it has to run even while the rest is idle.
                    self.handleEngineRevisionChange()
                    self.updateSessionFrameStatus(in: arView)
                    self.updateAimerSurface(in: arView)
                    self.updatePlacedPointBillboards(in: arView)
                    self.updateFastObjectMaskMarkers(in: arView)
                    self.updateScanLive(in: arView)
                    self.refreshSupportPlaneBindings(in: arView)
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

        func setWorkflowMode(_ mode: MeasurementWorkflowMode) {
            guard workflowMode != mode else {
                return
            }
            workflowMode = mode
            captureEngine.setMeasurementMode(mode)
            resetScanState()
            updateTopViewAlignment(from: arView?.session.currentFrame)
        }

        @objc private func updateMaskDisplay() {
            guard let arView else {
                return
            }
            updateFastObjectMaskPreview(in: arView)
            updateObjectMaskPreview(in: arView)
        }

        func detach() {
            coachingOverlayView?.delegate = nil
            coachingOverlayView?.session = nil
            coachingOverlayView?.removeFromSuperview()
            coachingOverlayView = nil
            sessionManager.updateCoachingState(isActive: false)
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
            cancelCaptureFit()
            captureEngine.cancelObjectSelection()
            objectMaskDisplayTask?.cancel()
            objectMaskDisplayTaskGeneration &+= 1
            objectMaskDisplayTask = nil
            objectMaskDisplaySeedsByID.removeAll()
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
            objectMaskToggleAttemptsRemaining = 0
            objectMaskProcessingFailuresRemaining = 0
            rendererWarmupTask?.cancel()
            rendererWarmupTask = nil
            removeAllObjectMaskAnchors()
            captureEngine.updateLockedObjectMaskCount(0)
            captureEngine.updateObjectMaskTracking(visibleCount: 0, markers: [])
            captureEngine.clearObjectMaskPreview()
            clearMeasurementContent()
            clearAllCaptureContent()

            removeSelectionPointEntity()
            captureBoxEntityPool.removeAll()

            if let contentAnchor, let arView {
                arView.scene.removeAnchor(contentAnchor)
            }

            if let arView {
                sessionManager.detach(arView.session)
            }

            arView = nil
            contentAnchor = nil
        }

        private func installCoachingOverlay(in arView: ARView) {
            let coachingOverlay = ARCoachingOverlayView()
            coachingOverlay.translatesAutoresizingMaskIntoConstraints = false
            coachingOverlay.delegate = self
            // A reliable horizontal support is a prerequisite for height. Apple keeps this goal
            // active until movement has produced a detected floor/table plane.
            coachingOverlay.goal = .horizontalPlane
            coachingOverlay.activatesAutomatically = true
            coachingOverlay.session = arView.session
            arView.addSubview(coachingOverlay)
            NSLayoutConstraint.activate([
                coachingOverlay.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
                coachingOverlay.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
                coachingOverlay.topAnchor.constraint(equalTo: arView.topAnchor),
                coachingOverlay.bottomAnchor.constraint(equalTo: arView.bottomAnchor)
            ])
            coachingOverlayView = coachingOverlay
        }

        func coachingOverlayViewWillActivate(
            _ coachingOverlayView: ARCoachingOverlayView
        ) {
            sessionManager.updateCoachingState(isActive: true)
        }

        func coachingOverlayViewDidDeactivate(
            _ coachingOverlayView: ARCoachingOverlayView
        ) {
            sessionManager.updateCoachingState(isActive: false)
        }

        func coachingOverlayViewDidRequestSessionReset(
            _ coachingOverlayView: ARCoachingOverlayView
        ) {
            guard let arView else {
                return
            }
            prepareForNewWorld()
            sessionManager.restartTracking(arView.session)
        }

        private func releaseRebuildableScanCaches() {
            objectMaskTask?.cancel()
            objectMaskTaskGeneration &+= 1
            objectMaskTask = nil
            cancelCaptureFit()
            pendingObjectMaskToggleRequest = nil
            objectMaskToggleAttemptsRemaining = 0
            objectMaskProcessingFailuresRemaining = 0
            captureEngine.cancelObjectSelection()
            objectMaskDisplayTask?.cancel()
            objectMaskDisplayTaskGeneration &+= 1
            objectMaskDisplayTask = nil
            objectMaskDisplaySeedsByID.removeAll()
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
                _ = captureEngine.isMeshVisible
                _ = captureEngine.showsSelectedPoints
                _ = captureEngine.showsBoundingBoxes
                _ = sessionManager.frameEpoch
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

        /// `withObservationTracking` delivers `onChange` exactly once and then stops tracking until
        /// it is re-registered, and the re-registration here has to hop through a `Task` to get
        /// back on the main actor. Anything mutated inside that gap is never delivered.
        ///
        /// That is not a cosmetic loss. A lock bumps the workflow revision to tell the
        /// coordinator to commit the box onto its support plane; if that bump falls in the gap the
        /// commit never happens, and no further revision change is coming to break the tie. The
        /// gap is widest exactly when the main thread is busiest, on startup.
        ///
        /// Every branch below is guarded by an `observed… != current` comparison that it then
        /// syncs, so the whole thing is idempotent and safe to poll. The scan timer calls it each
        /// tick as a backstop; the observation path still provides the immediate response.
        private func handleEngineRevisionChange() {
            if sessionManager.frameEpoch != observedFrameEpoch {
                observedFrameEpoch = sessionManager.frameEpoch
                invalidateInFlightFrameWork()
                if !captureEngine.hasCapture,
                   captureEngine.activeObjectID == nil,
                   let arView {
                    _ = sessionManager.recoverFailedSessionIfPossible(
                        arView.session
                    )
                }
            }

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
                objectMaskProcessingFailuresRemaining = 8
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

        }

        private func invalidateInFlightFrameWork() {
            objectMaskTask?.cancel()
            objectMaskTaskGeneration &+= 1
            objectMaskTask = nil
            objectMaskDisplayTask?.cancel()
            objectMaskDisplayTaskGeneration &+= 1
            objectMaskDisplayTask = nil
            cancelCaptureFit()
            pendingObjectMaskToggleRequest = nil
            objectMaskToggleAttemptsRemaining = 0
            objectMaskProcessingFailuresRemaining = 0
            captureEngine.cancelObjectSelection()
            lastObjectMaskSubmittedFrameTimestamp = -.greatestFiniteMagnitude
            lastAutomaticPointCleanupTimestamp = -.greatestFiniteMagnitude
            previewTargetPosition = nil
            lastAimerRaycastTransform = nil
            clearPreviewMeasurementEntities()
            cancelRefinementTasks(markPointsFinished: true)
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
            cancelCaptureFit()
            pendingObjectMaskToggleRequest = nil
            objectMaskToggleAttemptsRemaining = 0
            objectMaskProcessingFailuresRemaining = 0

            switch request.kind {
            case .finalize:
                // The commit that used to happen when the operator pressed Save. Best effort now:
                // the engine has already locked the dimensions, so a plane that slipped away in
                // the same frame leaves the box on its last good geometry rather than throwing
                // the measurement away.
                _ = snapCaptureToCurrentSupportPlane(
                    for: request.id,
                    isCommitting: true
                )
                selectionPointsByObject.removeValue(forKey: request.id)
                // The point cloud entity keeps whatever it last drew, so without this the locked
                // object's points stay on screen after its own points have been dropped.
                updateSelectionVisualization()
                objectMaskDisplayTask?.cancel()
                objectMaskDisplayTaskGeneration &+= 1
                objectMaskDisplayTask = nil
                objectMaskDisplaySeedsByID.removeValue(forKey: request.id)
                removeLiveObjectMaskDisplaySeed()
                captureEngine.clearTransientObjectMaskPreviews()
                captureEngine.clearObjectMaskDisplayTracking(id: request.id)
                if let state = objectMaskMarkerStates[request.id] {
                    objectMaskMarkerStates[request.id] = ObjectMaskMarkerState(
                        color: state.color,
                        isMaskVisible: false
                    )
                }
            case .reactivate:
                rebaseAndRestartMeasurement(for: request.id)
                removeLiveObjectMaskDisplaySeed()
                captureEngine.clearLiveObjectMaskPreview()
            case .remove:
                objectMaskDisplayTask?.cancel()
                objectMaskDisplayTaskGeneration &+= 1
                objectMaskDisplayTask = nil
                objectMaskDisplaySeedsByID.removeValue(forKey: request.id)
                captureEngine.clearObjectMaskDisplayTracking(id: request.id)
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
                automaticPointCleanupCursorByObject.removeValue(
                    forKey: request.id
                )
                selectionPointsByObject.removeValue(forKey: request.id)
                publishedAnchorTransformByObject.removeValue(forKey: request.id)
                evidenceAnchorTransformByObject.removeValue(forKey: request.id)
                clearCaptureContent(for: request.id)
            }
            updateSelectionVisualization()
        }

        /// Lock is the commit boundary: resolve the latest geometry for the retained support plane,
        /// put the box bottom exactly on it, and preserve the already-observed top face.
        @discardableResult
        /// `isCommitting` marks the one call that turns a live measurement into a locked one.
        /// The object is already in `finalizedObjectIDs` by then — the engine locks first now —
        /// but this call still has to re-measure the height against the plane rather than take
        /// the frozen-dimension path that later plane merges use.
        private func snapCaptureToCurrentSupportPlane(
            for id: UUID,
            isCommitting: Bool = false
        ) -> Bool {
            guard let arView,
                  let frame = arView.session.currentFrame,
                  case .normal = frame.camera.trackingState,
                  let storedObject = captureEngine.capturedObjectsByID[id],
                  let objectAnchor = currentObjectAnchor(
                      id: id,
                      frame: frame,
                      fallback: objectMaskAnchors[id]
                  ) else {
                return false
            }

            // Bring the canonical box into its *visible* current world frame. Once presentation is
            // plane-bound, that frame comes from the plane anchor rather than the mask/object anchor;
            // using the latter would turn different local refinements into a false height change.
            let presentationRebase: simd_float4x4
            if let planeID = capturePresentationPlaneIDsByObject[id],
               let currentPlane = frame.anchors.first(where: {
                   $0.identifier == planeID
               }) as? ARPlaneAnchor,
               let renderReference = renderAnchorTransformByObject[id] {
                presentationRebase = currentPlane.transform * renderReference.inverse
                latestPresentationRebaseByObject[id] = presentationRebase
            } else if capturePresentationPlaneIDsByObject[id] != nil,
                      let latestPresentationRebase =
                        latestPresentationRebaseByObject[id] {
                presentationRebase = latestPresentationRebase
            } else {
                let publishedObjectAnchorTransform = publishedAnchorTransformByObject[id]
                    ?? objectMaskAnchors[id]?.transform
                    ?? objectAnchor.transform
                presentationRebase = objectAnchor.transform
                    * publishedObjectAnchorTransform.inverse
            }
            let object = transformedCapturedObject(
                storedObject,
                by: presentationRebase
            )

            let reference = objectAnchor.transform.translation
            let currentFootprint = ObjectFootprint(
                widthAxis: object.axes.width,
                width: object.dimensions.x,
                depth: object.dimensions.y,
                centerXZ: SIMD2<Float>(object.center.x, object.center.z)
            )
            guard let match = ObjectCapturePipeline.supportPlaneMatch(
                from: frame.anchors,
                beneath: reference,
                validating: supportPlaneValidationPoints(
                    for: currentFootprint,
                    reference: reference
                ),
                preferredAnchorIdentifier: supportPlaneAnchorIDsByObject[id]
            ) else {
                return false
            }

            let snappedObject: CapturedObject
            let snappedHeight: Float
            if captureEngine.finalizedObjectIDs.contains(id), !isCommitting {
                // A lock freezes dimensions. If ARKit merges/replaces its plane, translate the
                // fixed box onto the replacement instead of measuring it again.
                snappedHeight = object.dimensions.z
                var translation = matrix_identity_float4x4
                translation.columns.3 = SIMD4<Float>(
                    0,
                    match.height - (object.center.y - snappedHeight / 2),
                    0,
                    1
                )
                snappedObject = transformedCapturedObject(object, by: translation)
            } else {
                let observedTop = object.center.y + object.dimensions.z / 2
                snappedHeight = observedTop - match.height
                guard snappedHeight >= 0.005,
                      snappedHeight <= ObjectCapturePipeline.maxHeight else {
                    return false
                }
                snappedObject = makeViewBox(
                    footprint: currentFootprint,
                    height: snappedHeight,
                    base: match.height,
                    up: SIMD3<Float>(0, 1, 0),
                    sampleCount: object.sampleCount
                )
            }

            publishedAnchorTransformByObject[id] = objectAnchor.transform
            supportPlaneAnchorIDsByObject[id] = match.anchorIdentifier
            _ = stabilizedSupportHeight(
                candidate: match.height,
                source: .plane(match.anchorIdentifier),
                for: id
            )
            capturedHeightByObject[id] = snappedHeight
            supportHeightStateByObject[id]?.value = match.height
            fittedSupportHeightByObject[id] = match.height
            configureCapturePresentationAnchor(
                for: id,
                supportPlaneMatch: match
            )
            latestPresentationRebaseByObject[id] = matrix_identity_float4x4
            objectsAwaitingSupportPlane.remove(id)
            captureEngine.updateAnchoredCapture(id: id, object: snappedObject)
            addCapturedBox(snappedObject, for: id)
            return true
        }

        /// ARKit can merge plane anchors and remove the older identifier. Plane-bound boxes normally
        /// follow refinements automatically; this reacquires or safely falls back when that exact
        /// identifier disappears, for both active and finalized objects.
        private func refreshSupportPlaneBindings(in arView: ARView) {
            guard !capturePresentationPlaneIDsByObject.isEmpty
                    || !objectsAwaitingSupportPlane.isEmpty,
                  let frame = arView.session.currentFrame,
                  case .normal = frame.camera.trackingState else {
                return
            }
            let currentPlanes = Dictionary(uniqueKeysWithValues: frame.anchors.compactMap {
                anchor -> (UUID, ARPlaneAnchor)? in
                guard let plane = anchor as? ARPlaneAnchor,
                      plane.alignment == .horizontal,
                      plane.classification != .ceiling else {
                    return nil
                }
                return (plane.identifier, plane)
            })

            // Retain the most recent visible pose before ARKit replaces an anchor during a merge.
            for (objectID, planeID) in capturePresentationPlaneIDsByObject {
                if let plane = currentPlanes[planeID],
                   let renderReference = renderAnchorTransformByObject[objectID] {
                    latestPresentationRebaseByObject[objectID] =
                        plane.transform * renderReference.inverse
                }
            }
            let missingSupportIDs = capturePresentationPlaneIDsByObject.compactMap {
                objectID, planeID -> UUID? in
                captureEngine.capturedObjectsByID[objectID] != nil
                    && currentPlanes[planeID] == nil
                    ? objectID
                    : nil
            }
            let objectsNeedingSupport = Set(missingSupportIDs).union(
                objectsAwaitingSupportPlane.filter {
                    captureEngine.capturedObjectsByID[$0] != nil
                }
            )
            guard !objectsNeedingSupport.isEmpty,
                  frame.timestamp - lastSupportBindingRefreshTimestamp >= 0.5 else {
                return
            }
            lastSupportBindingRefreshTimestamp = frame.timestamp
            for id in objectsNeedingSupport {
                let wasBoundToRemovedPlane =
                    capturePresentationPlaneIDsByObject[id] != nil
                supportPlaneAnchorIDsByObject.removeValue(forKey: id)
                objectsAwaitingSupportPlane.insert(id)
                let didReacquireSupport =
                    snapCaptureToCurrentSupportPlane(for: id)
                if !didReacquireSupport {
                    moveCaptureFromRemovedPlaneToObjectAnchor(
                        id: id,
                        frame: frame
                    )
                }
                if wasBoundToRemovedPlane,
                   captureEngine.activeObjectID == id {
                    // Whether support was replaced immediately or temporarily fell back, the
                    // presentation changed coordinate frames. Never mix old depth evidence into it.
                    rebaseAndRestartMeasurement(for: id)
                    if !didReacquireSupport {
                        objectsAwaitingSupportPlane.insert(id)
                    }
                }
            }
        }

        /// Never leave content parented to an ARPlaneAnchor that ARKit has removed. Keep the last
        /// visible world pose on the object's retained anchor and continue looking for a replacement.
        private func moveCaptureFromRemovedPlaneToObjectAnchor(
            id: UUID,
            frame: ARFrame
        ) {
            guard let storedObject = captureEngine.capturedObjectsByID[id],
                  let objectAnchor = currentObjectAnchor(
                      id: id,
                      frame: frame,
                      fallback: objectMaskAnchors[id]
                  ) else {
                configureCapturePresentationAnchor(
                    for: id,
                    supportPlaneMatch: nil
                )
                return
            }

            let worldRebase: simd_float4x4
            if capturePresentationPlaneIDsByObject[id] != nil {
                worldRebase = latestPresentationRebaseByObject[id]
                    ?? matrix_identity_float4x4
            } else {
                let publishedTransform = publishedAnchorTransformByObject[id]
                    ?? objectAnchor.transform
                worldRebase = objectAnchor.transform * publishedTransform.inverse
            }
            let rebasedObject = transformedCapturedObject(
                storedObject,
                by: worldRebase
            )
            publishedAnchorTransformByObject[id] = objectAnchor.transform
            configureCapturePresentationAnchor(
                for: id,
                supportPlaneMatch: nil
            )
            renderAnchorTransformByObject[id] = objectAnchor.transform
            latestPresentationRebaseByObject[id] = matrix_identity_float4x4
            captureEngine.updateAnchoredCapture(id: id, object: rebasedObject)
            addCapturedBox(rebasedObject, for: id)
        }

        /// ARKit can refine an anchor while an object is locked. Its rendered
        /// box follows automatically, but the old depth voxels remain expressed
        /// in the earlier world frame. Rebase the canonical box, then reacquire
        /// evidence so an unlock never combines those two coordinate frames.
        private func rebaseAndRestartMeasurement(for id: UUID) {
            objectsAwaitingSupportPlane.remove(id)
            let frame = arView?.session.currentFrame
            let currentAnchor = currentObjectAnchor(
                id: id,
                frame: frame,
                fallback: objectMaskAnchors[id]
            )
            if let object = captureEngine.capturedObjectsByID[id],
               let currentAnchor {
                let worldRebase: simd_float4x4
                let usesCurrentPlanePresentation: Bool
                if let planeID = capturePresentationPlaneIDsByObject[id],
                   let currentPlane = frame?.anchors.first(where: {
                       $0.identifier == planeID
                   }) as? ARPlaneAnchor,
                   let renderReference = renderAnchorTransformByObject[id] {
                    worldRebase = currentPlane.transform * renderReference.inverse
                    renderAnchorTransformByObject[id] = currentPlane.transform
                    usesCurrentPlanePresentation = true
                } else {
                    let publishedTransform = publishedAnchorTransformByObject[id]
                        ?? objectMaskAnchors[id]?.transform
                        ?? currentAnchor.transform
                    worldRebase = currentAnchor.transform * publishedTransform.inverse
                    usesCurrentPlanePresentation = false
                }
                let rebasedObject = transformedCapturedObject(
                    object,
                    by: worldRebase
                )
                publishedAnchorTransformByObject[id] = currentAnchor.transform
                evidenceAnchorTransformByObject[id] = currentAnchor.transform
                if !usesCurrentPlanePresentation {
                    // A removed/merged plane cannot remain the presentation target while evidence
                    // restarts. Return to the current object anchor until support is reacquired.
                    configureCapturePresentationAnchor(
                        for: id,
                        supportPlaneMatch: nil
                    )
                    renderAnchorTransformByObject[id] = currentAnchor.transform
                }
                captureEngine.updateCapture(id: id, object: rebasedObject)
                addCapturedBox(rebasedObject, for: id)
            }
            if let currentAnchor {
                publishedAnchorTransformByObject[id] = currentAnchor.transform
                evidenceAnchorTransformByObject[id] = currentAnchor.transform
            }

            supportAccumulators.removeValue(forKey: id)
            maskedAccumulators.removeValue(forKey: id)
            newestMaskedPointTimestamp.removeValue(forKey: id)
            fittedMaskedPointTimestamp.removeValue(forKey: id)
            liveResultsByObject.removeValue(forKey: id)
            acceptedSurfaceVoxelKeysByObject.removeValue(forKey: id)
            manuallyRejectedVoxelKeysByObject.removeValue(forKey: id)
            automaticPointCleanupCursorByObject.removeValue(forKey: id)
            selectionPointsByObject.removeValue(forKey: id)
            capturedFootprintByObject.removeValue(forKey: id)
            capturedHeightByObject.removeValue(forKey: id)
            supportHeightStateByObject.removeValue(forKey: id)
            fittedSupportHeightByObject.removeValue(forKey: id)
            bootstrapSupportFootprintByObject.removeValue(forKey: id)
            supportRaycastMissTicks.removeValue(forKey: id)
            lastSupportPlaneMatchByObject.removeValue(forKey: id)
            supportPlaneMissTicks.removeValue(forKey: id)
            supportRaycastCacheByObject.removeValue(forKey: id)
            footprintFromTopObjects.remove(id)
            heightFromSideObjects.remove(id)
            footprintStableTicks.removeValue(forKey: id)
            heightStableTicks.removeValue(forKey: id)
            captureBoxRearEdgeStatesByObject.removeValue(forKey: id)
            captureEngine.resetScanGuidance()
        }

        /// Preserve the anchored box but discard world-space evidence after a
        /// material map correction, preventing old and corrected coordinates
        /// from entering the same fit.
        @discardableResult
        private func restartActiveMeasurementAfterAnchorCorrectionIfNeeded(
            frame: ARFrame,
            cancelMaskTask: Bool
        ) -> Bool {
            guard let id = captureEngine.activeObjectID,
                  let previous = evidenceAnchorTransformByObject[id],
                  let current = currentObjectAnchor(
                      id: id,
                      frame: frame,
                      fallback: objectMaskAnchors[id]
                  )?.transform else {
                return false
            }
            let translationDelta = current.translation - previous.translation
            let horizontalTranslationShift = hypot(
                translationDelta.x,
                translationDelta.z
            )
            let verticalTranslationShift = abs(translationDelta.y)
            let previousRotation = simd_quatf(rotationMatrix(of: previous))
            let currentRotation = simd_quatf(rotationMatrix(of: current))
            let quaternionDot = min(
                max(abs(simd_dot(previousRotation.vector, currentRotation.vector)), 0),
                1
            )
            let rotationShift = 2 * acos(quaternionDot)
            // Vertical support errors are conspicuous at only a few millimetres. Reacquire before
            // old world-space evidence can be combined with a vertically corrected anchor frame;
            // retain the wider horizontal threshold to avoid needless restarts from lateral noise.
            guard horizontalTranslationShift > 0.008
                    || verticalTranslationShift > 0.0015
                    || rotationShift > (Float.pi / 180) else {
                return false
            }

            if cancelMaskTask {
                objectMaskTask?.cancel()
                objectMaskTaskGeneration &+= 1
                objectMaskTask = nil
            }
            cancelCaptureFit()
            rebaseAndRestartMeasurement(for: id)
            return true
        }

        private func rotationMatrix(
            of transform: simd_float4x4
        ) -> simd_float3x3 {
            simd_float3x3(columns: (
                SIMD3<Float>(
                    transform.columns.0.x,
                    transform.columns.0.y,
                    transform.columns.0.z
                ),
                SIMD3<Float>(
                    transform.columns.1.x,
                    transform.columns.1.y,
                    transform.columns.1.z
                ),
                SIMD3<Float>(
                    transform.columns.2.x,
                    transform.columns.2.y,
                    transform.columns.2.z
                )
            ))
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
                  arView.window != nil,
                  arView.bounds.width > 0,
                  arView.bounds.height > 0,
                  sessionManager.isTrackingReady,
                  let frame = arView.session.currentFrame,
                  case .normal = frame.camera.trackingState,
                  frame.timestamp > lastObjectMaskSubmittedFrameTimestamp else {
                return
            }

            let orientation = cameraImageOrientation(in: arView)
            let viewportSize = arView.bounds.size
            let imageToViewportTransform = frame.displayTransform(
                for: interfaceOrientation(in: arView),
                viewportSize: viewportSize
            )

            let submittedToggleRequest: ObjectMaskToggleRequest?
            if pendingObjectMaskToggleRequest != nil,
               !sessionManager.isObjectTrackingEnvironmentReady {
                pendingObjectMaskToggleRequest = nil
                objectMaskToggleAttemptsRemaining = 0
                objectMaskProcessingFailuresRemaining = 0
                captureEngine.reportObjectSelectionNotReady()
                submittedToggleRequest = nil
            } else {
                submittedToggleRequest = pendingObjectMaskToggleRequest
            }
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
                requiresDepthWarmup: sessionManager.isAutomaticObjectCaptureSupported,
                depthSnapshot: captureEngine.activeObjectID != nil
                    || toggleRequest != nil
                    || !captureEngine.hasCompletedObjectRecognitionWarmup
                    ? objectMaskDepthSnapshot(from: frame)
                    : nil
            )
            if submittedToggleRequest != nil {
                pendingObjectMaskToggleRequest = nil
            }
            let processor = objectMaskProcessor
            updateTopViewAlignment(from: frame)
            let submittedWorkflowMode = workflowMode
            let submittedTopAlignmentAccepted = topAlignmentAccepted
            let submittedResetRevision = captureEngine.resetRevision
            let submittedFrameEpoch = sessionManager.frameEpoch
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
                guard self.sessionManager.frameEpoch == submittedFrameEpoch,
                      !wasCancelled,
                      self.workflowMode == submittedWorkflowMode,
                      self.mesEngine.mode == .scan,
                      self.sessionManager.isTrackingReady,
                      let currentFrame = arView.session.currentFrame,
                      case .normal = currentFrame.camera.trackingState,
                      currentFrame.timestamp >= input.timestamp else {
                    return
                }

                switch result.status {
                case .cancelled:
                    return
                case .failed:
                    if let submittedToggleRequest,
                       self.captureEngine.isObjectSelectionPending {
                        self.objectMaskProcessingFailuresRemaining = max(
                            self.objectMaskProcessingFailuresRemaining - 1,
                            0
                        )
                        if self.objectMaskProcessingFailuresRemaining > 0 {
                            self.pendingObjectMaskToggleRequest = submittedToggleRequest
                        } else {
                            self.objectMaskToggleAttemptsRemaining = 0
                            self.captureEngine.reportObjectRecognitionFailure()
                        }
                    }
                    return
                case .succeeded:
                    if result.isSelectionPipelineWarmed {
                        self.captureEngine.markObjectRecognitionWarmupCompleted()
                    }
                    if submittedToggleRequest != nil {
                        self.objectMaskToggleAttemptsRemaining = max(
                            self.objectMaskToggleAttemptsRemaining - 1,
                            0
                        )
                    }
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
                let restartedForAnchorCorrection =
                    self.restartActiveMeasurementAfterAnchorCorrectionIfNeeded(
                        frame: currentFrame,
                        cancelMaskTask: false
                    )
                for cloud in result.maskedPointClouds {
                    if restartedForAnchorCorrection {
                        continue
                    }
                    if submittedWorkflowMode == .top,
                       !submittedTopAlignmentAccepted {
                        continue
                    }
                    guard cloud.id == self.captureEngine.activeObjectID else {
                        continue
                    }
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
                if result.needsWorldSurface {
                    self.pendingObjectMaskToggleRequest = nil
                    self.objectMaskToggleAttemptsRemaining = 0
                    self.objectMaskProcessingFailuresRemaining = 0
                    self.captureEngine.reportObjectLockNeedsSurface()
                } else if submittedToggleRequest != nil,
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
                  sessionManager.isTrackingReady,
                  let frame = arView.session.currentFrame,
                  case .normal = frame.camera.trackingState else {
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
            let submittedFrameEpoch = sessionManager.frameEpoch
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
                guard self.sessionManager.frameEpoch == submittedFrameEpoch,
                      !wasCancelled,
                      self.mesEngine.mode == .scan,
                      self.sessionManager.isTrackingReady,
                      let currentFrame = arView.session.currentFrame,
                      case .normal = currentFrame.camera.trackingState,
                      currentFrame.timestamp >= input.timestamp else {
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
            guard mesEngine.mode == .scan,
                  sessionManager.isTrackingReady,
                  let frame = arView.session.currentFrame,
                  case .normal = frame.camera.trackingState else {
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

        private func removeVisiblePointsOutsideCurrentMask(in arView: ARView) {
            guard mesEngine.mode == .scan,
                  sessionManager.isAutomaticObjectCaptureSupported,
                  sessionManager.isTrackingReady,
                  let frame = arView.session.currentFrame,
                  case .normal = frame.camera.trackingState,
                  let objectID = captureEngine.activeObjectID,
                  var accumulator = maskedAccumulators[objectID],
                  let result = liveResultsByObject[objectID],
                  result.selectionPoints.count == result.surfacePoints.count,
                  !result.surfacePoints.isEmpty,
                  let preview = captureEngine.objectMaskPreview,
                  abs(frame.timestamp - preview.timestamp) <= 0.2,
                  let layer = preview.layers.first(where: {
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
            let pointCount = result.surfacePoints.count
            let batchCount = min(
                pointCount,
                Self.automaticPointCleanupBatchSize
            )
            let batchStart = automaticPointCleanupCursorByObject[
                objectID,
                default: 0
            ] % pointCount
            let candidateIndices = (0..<batchCount).map {
                (batchStart + $0) % pointCount
            }
            let nextCursor = (batchStart + batchCount) % pointCount
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
                return
            }
            if let confidenceMap {
                guard CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
                    == kCVReturnSuccess else {
                    CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
                    return
                }
            }
            guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
                CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
                if let confidenceMap {
                    CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
                }
                return
            }
            let confidenceBase: UnsafeMutableRawPointer?
            if let confidenceMap {
                guard let base = CVPixelBufferGetBaseAddress(confidenceMap) else {
                    CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
                    CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
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

                for index in candidateIndices {
                    let surfacePoint = result.surfacePoints[index]
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
            automaticPointCleanupCursorByObject[objectID] = nextCursor

            guard !removedIndices.isEmpty else {
                return
            }

            // The point set is the fit's input. Invalidate any result that was
            // computed from the pre-cleanup snapshot before changing it.
            cancelCaptureFit()

            let removedPairs = removedIndices.map {
                (
                    selection: result.selectionPoints[$0],
                    surface: result.surfacePoints[$0]
                )
            }
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

            let retainedSelectionPoints = result.selectionPoints.enumerated().compactMap {
                removedIndices.contains($0.offset) ? nil : $0.element
            }
            let retainedSurfacePoints = result.surfacePoints.enumerated().compactMap {
                removedIndices.contains($0.offset) ? nil : $0.element
            }
            if retainedSurfacePoints.isEmpty {
                automaticPointCleanupCursorByObject.removeValue(forKey: objectID)
            } else if let nextRetainedOriginalIndex = (0..<pointCount)
                .lazy
                .map({ (nextCursor + $0) % pointCount })
                .first(where: { !removedIndices.contains($0) }) {
                let removedBeforeNext = removedIndices.reduce(into: 0) {
                    if $1 < nextRetainedOriginalIndex {
                        $0 += 1
                    }
                }
                automaticPointCleanupCursorByObject[objectID] =
                    nextRetainedOriginalIndex - removedBeforeNext
            }
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
        }

        private func updateSessionFrameStatus(in arView: ARView) {
            guard let frame = arView.session.currentFrame else {
                updateTopViewAlignment(from: nil)
                return
            }
            sessionManager.updateFrameStatus(from: frame)
            updateTopViewAlignment(from: frame)
        }

        private func updateTopViewAlignment(from frame: ARFrame?) {
            guard workflowMode == .top,
                  let frame,
                  case .normal = frame.camera.trackingState else {
                topAlignmentAccepted = false
                captureEngine.updateTopViewAlignment(
                    deviationDegrees: nil,
                    isAligned: false
                )
                return
            }

            let cameraForward = simd_normalize(
                -SIMD3<Float>(
                    frame.camera.transform.columns.2.x,
                    frame.camera.transform.columns.2.y,
                    frame.camera.transform.columns.2.z
                )
            )
            let worldDown = SIMD3<Float>(0, -1, 0)
            let cosine = min(max(simd_dot(cameraForward, worldDown), -1), 1)
            let deviation = acos(cosine) * 180 / .pi
            if topAlignmentAccepted {
                topAlignmentAccepted = deviation <= Self.topAlignmentExitDegrees
            } else {
                topAlignmentAccepted = deviation <= Self.topAlignmentEnterDegrees
            }
            captureEngine.updateTopViewAlignment(
                deviationDegrees: Int(deviation.rounded()),
                isAligned: topAlignmentAccepted
            )
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

            return objectMaskAnchors.compactMap { lockID, storedAnchor in
                guard let anchor = currentObjectAnchor(
                    id: lockID,
                    frame: frame,
                    fallback: storedAnchor
                ) else {
                    return nil
                }
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

        private func currentObjectAnchor(
            id: UUID,
            frame: ARFrame?,
            fallback: ARAnchor? = nil
        ) -> ARAnchor? {
            guard let stored = fallback ?? objectMaskAnchors[id] else {
                return nil
            }
            return frame?.anchors.first(where: {
                $0.identifier == stored.identifier
            }) ?? stored
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
                supportAccumulators[change.id] = PointAccumulator(
                    voxelSize: ObjectCapturePipeline.supportVoxelSize,
                    maxVoxels: 4_000
                )
                newestMaskedPointTimestamp.removeValue(forKey: change.id)
                fittedMaskedPointTimestamp.removeValue(forKey: change.id)
                liveResultsByObject.removeValue(forKey: change.id)
                capturedFootprintByObject.removeValue(forKey: change.id)
                capturedHeightByObject.removeValue(forKey: change.id)
                supportHeightStateByObject.removeValue(forKey: change.id)
                supportPlaneAnchorIDsByObject.removeValue(forKey: change.id)
                fittedSupportHeightByObject.removeValue(forKey: change.id)
                bootstrapSupportFootprintByObject.removeValue(forKey: change.id)
                supportRaycastMissTicks.removeValue(forKey: change.id)
                lastSupportPlaneMatchByObject.removeValue(forKey: change.id)
                supportPlaneMissTicks.removeValue(forKey: change.id)
                supportRaycastCacheByObject.removeValue(forKey: change.id)
                footprintFromTopObjects.remove(change.id)
                heightFromSideObjects.remove(change.id)
                footprintStableTicks.removeValue(forKey: change.id)
                heightStableTicks.removeValue(forKey: change.id)
                acceptedSurfaceVoxelKeysByObject.removeValue(forKey: change.id)
                manuallyRejectedVoxelKeysByObject.removeValue(forKey: change.id)
                let anchor = ARAnchor(name: "payload-mask-\(change.id.uuidString)", transform: transform)
                captureAnchorEntitiesByObject.removeValue(forKey: change.id)?
                    .removeFromParent()
                capturePresentationPlaneIDsByObject.removeValue(forKey: change.id)
                latestPresentationRebaseByObject.removeValue(forKey: change.id)
                objectsAwaitingSupportPlane.remove(change.id)
                let captureAnchor = AnchorEntity(anchor: anchor)
                arView.session.add(anchor: anchor)
                arView.scene.addAnchor(captureAnchor)
                objectMaskAnchors[change.id] = anchor
                captureAnchorEntitiesByObject[change.id] = captureAnchor
                renderAnchorTransformByObject[change.id] = anchor.transform
                publishedAnchorTransformByObject[change.id] = anchor.transform
                evidenceAnchorTransformByObject[change.id] = anchor.transform
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
                  case .normal = frame.camera.trackingState,
                  let activeObjectID = captureEngine.activeObjectID,
                  objectMaskAnchors[activeObjectID] != nil else {
                if let activeObjectID = captureEngine.activeObjectID {
                    captureEngine.updateActiveSupportPlaneAvailability(
                        id: activeObjectID,
                        isAvailable: false
                    )
                }
                return
            }

            _ = restartActiveMeasurementAfterAnchorCorrectionIfNeeded(
                frame: frame,
                cancelMaskTask: true
            )

            guard let activeAnchor = currentObjectAnchor(
                id: activeObjectID,
                frame: frame,
                fallback: objectMaskAnchors[activeObjectID]
            ) else {
                captureEngine.updateActiveSupportPlaneAvailability(
                    id: activeObjectID,
                    isAvailable: false
                )
                return
            }
            let supportReference = activeAnchor.transform.translation
            let activeSupportFootprint = supportFootprint(for: activeObjectID)
            let supportValidationPoints = supportPlaneValidationPoints(
                for: activeSupportFootprint,
                reference: supportReference
            )
            let planeSupportMatch = heldSupportPlaneMatch(
                ObjectCapturePipeline.supportPlaneMatch(
                    from: frame.anchors,
                    beneath: supportReference,
                    validating: supportValidationPoints,
                    preferredAnchorIdentifier: supportPlaneAnchorIDsByObject[
                        activeObjectID
                    ]
                ),
                anchors: frame.anchors,
                for: activeObjectID
            )
            if let planeSupportMatch {
                supportPlaneAnchorIDsByObject[activeObjectID] =
                    planeSupportMatch.anchorIdentifier
            } else {
                supportPlaneAnchorIDsByObject.removeValue(
                    forKey: activeObjectID
                )
            }
            captureEngine.updateActiveSupportPlaneAvailability(
                id: activeObjectID,
                isAvailable: planeSupportMatch != nil
            )

            updateTopViewAlignment(from: frame)
            guard workflowMode != .top || topAlignmentAccepted else {
                return
            }

            if frame.timestamp - lastAutomaticPointCleanupTimestamp >= 0.5 {
                lastAutomaticPointCleanupTimestamp = frame.timestamp
                removeVisiblePointsOutsideCurrentMask(in: arView)
            }

            let visibleHints = objectMaskAnchorHints(frame: frame, in: arView).filter {
                $0.id == activeObjectID && $0.normalizedViewportPoint != nil
            }
            let seeds = Dictionary(uniqueKeysWithValues: visibleHints.map { hint in
                (hint.id, hint.worldPosition)
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

            guard captureFitTask == nil,
                  let hint = visibleHints.first else {
                return
            }
            createContentAnchorIfNeeded(in: arView)
            let id = hint.id
            guard let maskTimestamp = newestMaskedPointTimestamp[id],
                  let objectAccumulator = maskedAccumulators[id] else {
                return
            }
            let anchor = activeAnchor
            // The ARAnchor is the tracked spatial reference; a previously
            // published world-space center can lag behind an anchor correction.
            let supportPoints = supportAccumulators[id]?.points(
                minObservations: ObjectCapturePipeline.minObservations
            ) ?? []
            let seed = anchor.transform.translation
            var raycastSupport: Float?
            if planeSupportMatch != nil {
                supportRaycastMissTicks.removeValue(forKey: id)
            } else {
                raycastSupport = raycastSupportHeight(
                    in: arView.session,
                    footprint: activeSupportFootprint,
                    reference: supportReference,
                    timestamp: frame.timestamp,
                    for: id
                )
                if raycastSupport != nil {
                    supportRaycastMissTicks.removeValue(forKey: id)
                } else if supportHeightStateByObject[id]?.source == .raycast,
                          let held = supportHeightStateByObject[id]?.value {
                    // A gap in mesh coverage for a tick or two must not drop the base back to
                    // the coarser depth histogram: that swap moves the box, and swapping back
                    // moves it again. Hold the last raycast base instead.
                    let misses = supportRaycastMissTicks[id, default: 0] + 1
                    supportRaycastMissTicks[id] = misses
                    if misses <= Self.supportRaycastMissTolerance {
                        raycastSupport = held
                    }
                }
            }
            guard let supportCandidate = ObjectCapturePipeline.resolvedSupportHeight(
                planeHeight: planeSupportMatch?.height,
                raycastHeight: raycastSupport,
                supportPoints: supportPoints,
                seed: seed,
                footprint: activeSupportFootprint
            ) else {
                return
            }
            let supportSource: SupportHeightSource
            if let planeSupportMatch {
                supportSource = .plane(planeSupportMatch.anchorIdentifier)
            } else if raycastSupport != nil {
                supportSource = .raycast
            } else {
                supportSource = .depth
            }
            guard let resolvedSupportHeight = stabilizedSupportHeight(
                candidate: supportCandidate,
                source: supportSource,
                for: id
            ) else {
                return
            }
            let requiresPointFit = maskTimestamp > fittedMaskedPointTimestamp[
                id,
                default: -.greatestFiniteMagnitude
            ]
            let requiresSupportFit = fittedSupportHeightByObject[id].map {
                abs($0 - resolvedSupportHeight) > 0.0005
            } ?? true
            let isSupportOnlyFit = requiresSupportFit && !requiresPointFit
            guard requiresPointFit || requiresSupportFit else {
                if workflowMode == .top,
                   !captureEngine.topMeasurementStable,
                   let previous = liveResultsByObject[id] {
                    let displayBox = topViewBox(
                        fitted: previous.object,
                        id: id,
                        base: resolvedSupportHeight,
                        isActive: true
                    )
                    addCapturedBox(displayBox, for: id)
                    captureEngine.updateCapture(id: id, object: displayBox)
                }
                return
            }
            let objectPoints = objectAccumulator.stablePointsSnapshot()
            guard !objectPoints.isEmpty else {
                return
            }

            let fitter = objectCaptureFitter
            let wasAtCapacity = objectAccumulator.isAtCapacity
            let cameraTransform = frame.camera.transform
            let submittedWorkflowMode = workflowMode
            let submittedResetRevision = captureEngine.resetRevision
            let submittedFrameEpoch = sessionManager.frameEpoch
            captureFitTaskGeneration &+= 1
            let taskGeneration = captureFitTaskGeneration
            captureFitTask = Task { [weak self] in
                let outcome = await fitter.capture(
                    objectPoints: objectPoints,
                    supportPoints: supportPoints,
                    seed: seed,
                    supportHeight: resolvedSupportHeight,
                    footprint: activeSupportFootprint,
                    mode: submittedWorkflowMode
                )
                let wasCancelled = Task.isCancelled
                guard let self,
                      self.captureFitTaskGeneration == taskGeneration else {
                    return
                }
                self.captureFitTask = nil
                guard !wasCancelled,
                      self.captureEngine.resetRevision == submittedResetRevision,
                      self.sessionManager.frameEpoch == submittedFrameEpoch,
                      self.workflowMode == submittedWorkflowMode,
                      self.captureEngine.activeObjectID == id,
                      self.supportHeightStateByObject[id]?.value.map({
                          abs($0 - resolvedSupportHeight) <= 0.0005
                      }) == true,
                      self.supportHeightStateByObject[id]?.source == supportSource else {
                    return
                }
                guard case .success(let result) = outcome else {
                    if case .notEnoughMesh = outcome {
                        self.fittedMaskedPointTimestamp[id] = maskTimestamp
                        self.fittedSupportHeightByObject[id] = resolvedSupportHeight
                    }
                    return
                }
                let didPublish = self.applyCaptureResult(
                    result,
                    id: id,
                    accumulatorWasAtCapacity: wasAtCapacity && !isSupportOnlyFit,
                    supportHeight: resolvedSupportHeight,
                    supportPlaneMatch: planeSupportMatch,
                    cameraTransform: cameraTransform
                )
                self.fittedMaskedPointTimestamp[id] = maskTimestamp
                if didPublish {
                    self.fittedSupportHeightByObject[id] = resolvedSupportHeight
                }
            }
        }

        private func applyCaptureResult(
            _ result: CaptureResult,
            id: UUID,
            accumulatorWasAtCapacity: Bool,
            supportHeight: Float?,
            supportPlaneMatch: SupportPlaneMatch?,
            cameraTransform: simd_float4x4
        ) -> Bool {
            var acceptedSurfaceExpansion = false
            if let previous = liveResultsByObject[id] {
                let requiresExpansionEvidence =
                    !isPlausibleBoxRefinement(result.object, from: previous.object)
                    || accumulatorWasAtCapacity
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
                            ) && previous.object.contains(pair.1)
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
                        selectionPointsByObject[id] = retainedResult.surfacePoints
                        updateSelectionVisualization()
                        return false
                    }
                }
            }
            var acceptedResult = result
            if workflowMode == .spatial3D,
               accumulatorWasAtCapacity,
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
                for point in acceptedResult.selectionPoints
                where acceptedResult.object.contains(
                    point,
                    tolerance: ObjectCapturePipeline.selectionTolerance
                ) {
                    acceptedSurfaceVoxelKeysByObject[id, default: []].insert(
                        selectionVoxelKey(for: point)
                    )
                }
            }
            let displayBox: CapturedObject
            switch workflowMode {
            case .spatial3D:
                displayBox = viewGatedBox(
                    fitted: acceptedResult.object,
                    id: id,
                    base: supportHeight,
                    camera: cameraTransform,
                    isActive: captureEngine.activeObjectID == id
                )
            case .top:
                displayBox = topViewBox(
                    fitted: acceptedResult.object,
                    id: id,
                    base: supportHeight,
                    isActive: captureEngine.activeObjectID == id
                )
            }
            if let evidenceTransform = evidenceAnchorTransformByObject[id] {
                publishedAnchorTransformByObject[id] = evidenceTransform
            }
            configureCapturePresentationAnchor(
                for: id,
                supportPlaneMatch: supportPlaneMatch
            )
            addCapturedBox(displayBox, for: id)
            captureEngine.updateCapture(id: id, object: displayBox)
            captureEngine.focusCapture(id: id)
            return true
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
            topAlignmentAccepted = false
            clearAllCaptureContent()
            supportAccumulators.removeAll()
            maskedAccumulators.removeAll()
            newestMaskedPointTimestamp.removeAll()
            fittedMaskedPointTimestamp.removeAll()
            liveResultsByObject.removeAll()
            acceptedSurfaceVoxelKeysByObject.removeAll()
            manuallyRejectedVoxelKeysByObject.removeAll()
            scanTickCounter = 0
            lastSupportBindingRefreshTimestamp = -.greatestFiniteMagnitude
            lastAutomaticPointCleanupTimestamp = -.greatestFiniteMagnitude
            automaticPointCleanupCursorByObject.removeAll()
            resetObjectMaskTracking()
        }

        private func resetObjectMaskTracking() {
            cancelCaptureFit()
            objectMaskTrackingGeneration &+= 1
            objectMaskTask?.cancel()
            objectMaskTaskGeneration &+= 1
            objectMaskTask = nil
            lastObjectMaskSubmittedFrameTimestamp = -.greatestFiniteMagnitude
            objectMaskDisplayTask?.cancel()
            objectMaskDisplayTaskGeneration &+= 1
            objectMaskDisplayTask = nil
            objectMaskDisplaySeedsByID.removeAll()
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
            objectMaskToggleAttemptsRemaining = 0
            objectMaskProcessingFailuresRemaining = 0
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

        private func cancelCaptureFit() {
            captureFitTask?.cancel()
            captureFitTask = nil
            captureFitTaskGeneration &+= 1
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
            if let immediate = bestRaycastResult(from: targetLocation, in: arView) {
                initialTransform = immediate.worldTransform
            } else if let cached = lastAimerRaycastTransform {
                initialTransform = cached
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

            refinementTasks[pointID]?.cancel()
            refinementTasks[pointID] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else {
                    return
                }
                self?.stopRefining(pointID: pointID)
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
            refinementTasks.removeValue(forKey: pointID)?.cancel()
            guard let index = placedPoints.firstIndex(where: { $0.id == pointID }) else {
                return
            }

            placedPoints[index].trackedRaycast?.stopTracking()
            placedPoints[index].trackedRaycast = nil
            if sessionManager.isTrackingReady {
                lockPointToARAnchor(at: index)
            }
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
            let anchorEntity = AnchorEntity(anchor: arAnchor)

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
            guard let frame = arView?.session.currentFrame,
                  case .normal = frame.camera.trackingState,
                  placedPoint.anchorEntity != nil,
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
            guard captureEngine.showsBoundingBoxes,
                  !objectIDs.isEmpty,
                  observedObjectWorkflowRequestRevision
                    == captureEngine.objectWorkflowRequestRevision,
                  sessionManager.isTrackingReady,
                  let frame = arView.session.currentFrame,
                  case .normal = frame.camera.trackingState else {
                return
            }
            let cameraPosition = frame.camera.transform.translation
            for objectID in objectIDs {
                guard !captureEngine.finalizedObjectIDs.contains(objectID) else {
                    continue
                }
                guard let object = captureEngine.capturedObjectsByID[objectID] else {
                    continue
                }
                let cameraPositionInPublishedFrame: SIMD3<Float>
                if let publishedTransform = publishedAnchorTransformByObject[objectID],
                   let currentAnchor = currentObjectAnchor(
                       id: objectID,
                       frame: frame,
                       fallback: objectMaskAnchors[objectID]
                   ) {
                    cameraPositionInPublishedFrame = transformedPoint(
                        cameraPosition,
                        by: publishedTransform * currentAnchor.transform.inverse
                    )
                } else {
                    cameraPositionInPublishedFrame = cameraPosition
                }
                let previousRearEdges = captureBoxRearEdgeStatesByObject[objectID]
                let spans = captureBoxLineSpans(
                    for: object,
                    objectID: objectID,
                    cameraPosition: cameraPositionInPublishedFrame
                )
                guard captureBoxRearEdgeStatesByObject[objectID]
                        != previousRearEdges else {
                    continue
                }
                renderCapturedBoxSpans(spans, for: objectID)
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
            // Each span is a separate entity, and every entity beyond the prepared pool is built
            // synchronously. Twelve edges all dashed at the per-edge maximum would demand nearly
            // 300, which is a visible stall at the moment the box first appears — the lock. Share
            // a fixed dash budget across whichever edges are actually dashed instead.
            let dashedEdgeCount = rearEdges.count { $0 }
            let dashBudget = dashedEdgeCount > 0
                ? max(Self.captureBoxDashBudget / dashedEdgeCount, 2)
                : Self.captureBoxMaximumDashCount
            var spans: [(start: SIMD3<Float>, end: SIMD3<Float>)] = []
            spans.reserveCapacity(Self.captureBoxDashBudget + Self.captureBoxEdges.count)
            for (edgeIndex, edge) in Self.captureBoxEdges.enumerated() {
                let start = object.corners[edge.0]
                let end = object.corners[edge.1]
                if rearEdges[edgeIndex] {
                    spans.append(
                        contentsOf: dashedCaptureBoxSpans(
                            from: start,
                            to: end,
                            maximumDashCount: dashBudget
                        )
                    )
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
            to end: SIMD3<Float>,
            maximumDashCount: Int = captureBoxMaximumDashCount
        ) -> [(start: SIMD3<Float>, end: SIMD3<Float>)] {
            let delta = end - start
            let length = simd_length(delta)
            guard length > 0.001 else {
                return []
            }
            let dashCount = min(
                max(Int((length / Self.captureBoxDashTargetPeriod).rounded()), 2),
                min(maximumDashCount, Self.captureBoxMaximumDashCount)
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
            guard let renderAnchor = captureAnchorEntitiesByObject[objectID]
                    ?? contentAnchor else {
                return
            }
            // Box coordinates belong to the world frame captured alongside
            // `publishedAnchorTransform`. Keeping that exact inverse as the
            // child transform lets RealityKit apply later anchor corrections
            // without repainting the box back into stale world coordinates.
            let worldToRenderAnchor = renderAnchorTransformByObject[objectID]?
                .inverse
                ?? publishedAnchorTransformByObject[objectID]?.inverse
                ?? currentObjectAnchor(
                    id: objectID,
                    frame: arView?.session.currentFrame,
                    fallback: objectMaskAnchors[objectID]
                )?.transform.inverse
                ?? matrix_identity_float4x4
            let renderableSpans = spans.filter {
                simd_length($0.end - $0.start) > 0.001
            }
            var entities = captureEntitiesByObject[objectID] ?? []
            if entities.count < renderableSpans.count {
                let entityMaterial = material
                    ?? capturedBoxMaterial(for: objectID)
                while entities.count < renderableSpans.count {
                    let entity: ModelEntity
                    if let preparedEntity = captureBoxEntityPool.popLast() {
                        entity = preparedEntity
                        entity.removeFromParent()
                        renderAnchor.addChild(entity)
                        if var model = entity.model {
                            model.materials = [entityMaterial]
                            entity.model = model
                        }
                    } else {
                        entity = ModelEntity(
                            mesh: Self.unitCubeMesh,
                            materials: [entityMaterial]
                        )
                        renderAnchor.addChild(entity)
                    }
                    entities.append(entity)
                }
            }
            for (index, span) in renderableSpans.enumerated() {
                updateCapturedBoxEdge(
                    entities[index],
                    from: transformedPoint(
                        span.start,
                        by: worldToRenderAnchor
                    ),
                    to: transformedPoint(
                        span.end,
                        by: worldToRenderAnchor
                    ),
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

        private func transformedPoint(
            _ point: SIMD3<Float>,
            by transform: simd_float4x4
        ) -> SIMD3<Float> {
            let transformed = transform * SIMD4<Float>(point, 1)
            return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
        }

        private func transformedDirection(
            _ direction: SIMD3<Float>,
            by transform: simd_float4x4
        ) -> SIMD3<Float> {
            let transformed = transform * SIMD4<Float>(direction, 0)
            let vector = SIMD3<Float>(
                transformed.x,
                transformed.y,
                transformed.z
            )
            return simd_length(vector) > 0.000_001
                ? simd_normalize(vector)
                : direction
        }

        private func transformedCapturedObject(
            _ object: CapturedObject,
            by transform: simd_float4x4
        ) -> CapturedObject {
            CapturedObject(
                dimensions: object.dimensions,
                center: transformedPoint(object.center, by: transform),
                axes: (
                    transformedDirection(object.axes.width, by: transform),
                    transformedDirection(object.axes.depth, by: transform),
                    transformedDirection(object.axes.height, by: transform)
                ),
                corners: object.corners.map {
                    transformedPoint($0, by: transform)
                },
                volume: object.volume,
                sampleCount: object.sampleCount
            )
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
                for (objectID, entities) in captureEntitiesByObject {
                    let activeCount = captureBoxActiveSpanCountsByObject[objectID] ?? 0
                    for (index, entity) in entities.enumerated() {
                        entity.isEnabled = index < activeCount
                    }
                }
                if let arView {
                    updateCaptureBoxLineStyles(in: arView)
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
            for anchor in captureAnchorEntitiesByObject.values {
                anchor.removeFromParent()
            }
            captureEntitiesByObject.removeAll()
            captureAnchorEntitiesByObject.removeAll()
            capturePresentationPlaneIDsByObject.removeAll()
            renderAnchorTransformByObject.removeAll()
            latestPresentationRebaseByObject.removeAll()
            objectsAwaitingSupportPlane.removeAll()
            publishedAnchorTransformByObject.removeAll()
            evidenceAnchorTransformByObject.removeAll()
            captureBoxActiveSpanCountsByObject.removeAll()
            captureBoxRearEdgeStatesByObject.removeAll()
            capturedFootprintByObject.removeAll()
            capturedHeightByObject.removeAll()
            supportHeightStateByObject.removeAll()
            supportPlaneAnchorIDsByObject.removeAll()
            fittedSupportHeightByObject.removeAll()
            bootstrapSupportFootprintByObject.removeAll()
            supportRaycastMissTicks.removeAll()
            lastSupportPlaneMatchByObject.removeAll()
            supportPlaneMissTicks.removeAll()
            supportRaycastCacheByObject.removeAll()
            footprintFromTopObjects.removeAll()
            heightFromSideObjects.removeAll()
            footprintStableTicks.removeAll()
            heightStableTicks.removeAll()
            captureEngine.resetScanGuidance()
            hideAllSelectionMarkers()
            selectionPointsByObject.removeAll()
        }

        private func clearCaptureContent(for id: UUID) {
            for entity in captureEntitiesByObject.removeValue(forKey: id) ?? [] {
                entity.removeFromParent()
            }
            captureAnchorEntitiesByObject.removeValue(forKey: id)?
                .removeFromParent()
            capturePresentationPlaneIDsByObject.removeValue(forKey: id)
            renderAnchorTransformByObject.removeValue(forKey: id)
            latestPresentationRebaseByObject.removeValue(forKey: id)
            objectsAwaitingSupportPlane.remove(id)
            publishedAnchorTransformByObject.removeValue(forKey: id)
            evidenceAnchorTransformByObject.removeValue(forKey: id)
            captureBoxActiveSpanCountsByObject.removeValue(forKey: id)
            captureBoxRearEdgeStatesByObject.removeValue(forKey: id)
            capturedFootprintByObject.removeValue(forKey: id)
            capturedHeightByObject.removeValue(forKey: id)
            supportHeightStateByObject.removeValue(forKey: id)
            supportPlaneAnchorIDsByObject.removeValue(forKey: id)
            fittedSupportHeightByObject.removeValue(forKey: id)
            bootstrapSupportFootprintByObject.removeValue(forKey: id)
            supportRaycastMissTicks.removeValue(forKey: id)
            lastSupportPlaneMatchByObject.removeValue(forKey: id)
            supportPlaneMissTicks.removeValue(forKey: id)
            supportRaycastCacheByObject.removeValue(forKey: id)
            footprintFromTopObjects.remove(id)
            heightFromSideObjects.remove(id)
            footprintStableTicks.removeValue(forKey: id)
            heightStableTicks.removeValue(forKey: id)
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
                let aligned = alignFootprint(candidateFootprint, to: capturedFootprintByObject[id])
                if isActive {
                    // Raw observation, before the display deadband below: the stopping rule needs
                    // the estimator's real fit-to-fit spread, and only a top-down view measures
                    // the footprint at all.
                    captureEngine.recordDimensionObservation(.width, value: aligned.width)
                    captureEngine.recordDimensionObservation(.depth, value: aligned.depth)
                }
                if var stored = capturedFootprintByObject[id] {
                    let width = stabilize(stored.width, aligned.width)
                    let depth = stabilize(stored.depth, aligned.depth)
                    let center = stabilizePosition(stored.centerXZ, aligned.centerXZ)
                    let axis = stabilizeOrientation(stored.widthAxis, aligned.widthAxis)
                    stored.width = width.value
                    stored.depth = depth.value
                    stored.widthAxis = axis.value
                    stored.centerXZ = center.value
                    capturedFootprintByObject[id] = stored
                    footprintStableTicks[id] = (
                        width.stable && depth.stable
                            && center.stable && axis.stable
                    )
                        ? (footprintStableTicks[id, default: 0] + 1)
                        : 0
                } else {
                    capturedFootprintByObject[id] = aligned
                    footprintStableTicks[id] = 0
                }
                if (footprintStableTicks[id] ?? 0) >= Self.satisfiedTickCount {
                    footprintFromTopObjects.insert(id)
                }
            case .side:
                if isActive {
                    captureEngine.recordDimensionObservation(
                        .height,
                        value: candidateHeight
                    )
                }
                if let stored = capturedHeightByObject[id] {
                    let height = stabilize(stored, candidateHeight)
                    capturedHeightByObject[id] = height.value
                    heightStableTicks[id] = height.stable
                        ? (heightStableTicks[id, default: 0] + 1)
                        : 0
                } else {
                    capturedHeightByObject[id] = candidateHeight
                    heightStableTicks[id] = 0
                }
                if (heightStableTicks[id] ?? 0) >= Self.satisfiedTickCount {
                    heightFromSideObjects.insert(id)
                }
            case .other:
                break
            }

            if isActive {
                captureEngine.updateScanGuidance(
                    view: view,
                    footprintSatisfied: footprintFromTopObjects.contains(id),
                    heightSatisfied: heightFromSideObjects.contains(id)
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

        /// Stabilizes repeated applications of the paper's bird's-eye fit. The fit itself remains
        /// entirely world-space; this only adds a small temporal deadband so depth noise does not
        /// make an otherwise unchanged result breathe while the user is holding the phone still.
        private func topViewBox(
            fitted: CapturedObject,
            id: UUID,
            base: Float?,
            isActive: Bool
        ) -> CapturedObject {
            let up = SIMD3<Float>(0, 1, 0)
            var candidateAxis = SIMD3<Float>(
                fitted.axes.width.x,
                0,
                fitted.axes.width.z
            )
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
            let baseY = base ?? (fitted.center.y - candidateHeight / 2)

            guard let previousFootprint = capturedFootprintByObject[id],
                  let previousHeight = capturedHeightByObject[id] else {
                capturedFootprintByObject[id] = candidateFootprint
                capturedHeightByObject[id] = candidateHeight
                footprintStableTicks[id] = 0
                if isActive {
                    recordTopViewObservations(
                        footprint: candidateFootprint,
                        height: candidateHeight
                    )
                    captureEngine.updateTopMeasurementGuidance(isStable: false)
                }
                return makeViewBox(
                    footprint: candidateFootprint,
                    height: candidateHeight,
                    base: baseY,
                    up: up,
                    sampleCount: fitted.sampleCount
                )
            }

            let aligned = alignFootprint(candidateFootprint, to: previousFootprint)
            if isActive {
                // The overhead fit measures every dimension in one view, so all three are
                // observed here. Raw values again, before the deadband applied just below.
                recordTopViewObservations(footprint: aligned, height: candidateHeight)
            }
            let width = stabilize(previousFootprint.width, aligned.width)
            let depth = stabilize(previousFootprint.depth, aligned.depth)
            let height = stabilize(previousHeight, candidateHeight)
            let center = stabilizePosition(previousFootprint.centerXZ, aligned.centerXZ)
            let axis = stabilizeOrientation(previousFootprint.widthAxis, aligned.widthAxis)
            capturedFootprintByObject[id] = ObjectFootprint(
                widthAxis: axis.value,
                width: width.value,
                depth: depth.value,
                centerXZ: center.value
            )
            capturedHeightByObject[id] = height.value

            if width.stable && depth.stable && height.stable
                && center.stable && axis.stable {
                footprintStableTicks[id, default: 0] += 1
            } else {
                footprintStableTicks[id] = 0
            }
            if footprintStableTicks[id, default: 0] >= Self.satisfiedTickCount {
                footprintFromTopObjects.insert(id)
            }
            if isActive {
                captureEngine.updateTopMeasurementGuidance(
                    isStable: footprintFromTopObjects.contains(id)
                )
            }

            return makeViewBox(
                footprint: capturedFootprintByObject[id] ?? aligned,
                height: capturedHeightByObject[id] ?? candidateHeight,
                base: baseY,
                up: up,
                sampleCount: fitted.sampleCount
            )
        }

        private func recordTopViewObservations(
            footprint: ObjectFootprint,
            height: Float
        ) {
            captureEngine.recordDimensionObservation(.width, value: footprint.width)
            captureEngine.recordDimensionObservation(.depth, value: footprint.depth)
            captureEngine.recordDimensionObservation(.height, value: height)
        }

        /// Deadband + light smoothing for a remembered dimension: within tolerance the stored value
        /// is held (so the box does not "breathe" on per-frame fit noise, and the tick counts as
        /// stable for convergence); beyond it, the value eases toward the new measurement.
        private func stabilize(_ stored: Float, _ candidate: Float) -> (value: Float, stable: Bool) {
            let tolerance = max(
                Self.dimensionDeadband,
                stored * Self.dimensionRelativeDeadband
            )
            if abs(candidate - stored) <= tolerance {
                return (stored, true)
            }
            return (stored + (candidate - stored) * Self.dimensionBlend, false)
        }

        private func stabilizePosition(
            _ stored: SIMD2<Float>,
            _ candidate: SIMD2<Float>
        ) -> (value: SIMD2<Float>, stable: Bool) {
            let delta = candidate - stored
            if simd_length(delta) <= Self.positionDeadband {
                return (stored, true)
            }
            return (stored + delta * Self.dimensionBlend, false)
        }

        /// Deadband + light smoothing for the footprint's yaw, matching what `stabilize` and
        /// `stabilizePosition` already do for the other remembered quantities.
        ///
        /// This one used to snap straight to the candidate whenever the change exceeded the
        /// deadband, on the reasoning that a blended yaw is not a rectangle fit of any actual
        /// data. In practice the minimum-area fit's yaw is by far the least stable thing it
        /// produces — a near-square or rounded footprint has two nearly equal minima — so
        /// snapping turned that into a box that visibly spins back and forth between them.
        ///
        /// A rectangle's orientation is axial with 90° period, so it cannot be averaged as a
        /// plain angle; `alignFootprint` first reduces the candidate to the representative
        /// nearest the remembered axis, which is the standard treatment of axial data (Mardia &
        /// Jupp, *Directional Statistics*, 2000, §2). Once reduced, the two directions are within
        /// ±45° and an ordinary exponential filter on the rotation between them is well defined.
        private func stabilizeOrientation(
            _ stored: SIMD3<Float>,
            _ candidate: SIMD3<Float>
        ) -> (value: SIMD3<Float>, stable: Bool) {
            let up = SIMD3<Float>(0, 1, 0)
            let cosine = min(max(simd_dot(stored, candidate), -1), 1)
            let degrees = acos(cosine) * 180 / .pi
            if degrees <= Self.orientationDeadbandDegrees {
                return (stored, true)
            }
            // Signed rotation about gravity, so the filter turns the short way round.
            let sine = simd_dot(up, simd_cross(stored, candidate))
            let angle = atan2(sine, cosine) * Self.orientationBlend
            let rotated = simd_quatf(angle: angle, axis: up).act(stored)
            guard simd_length(rotated) > 1e-5 else {
                return (stored, false)
            }
            return (simd_normalize(rotated), false)
        }

        /// The object's horizontal extent, for keeping the object itself out of every support
        /// estimate. Before the first fit publishes a footprint there is still an accumulated
        /// object point cloud, and using it matters: the previous fixed 5.5 cm bootstrap ring sat
        /// *on top of* any object wider than about 11 cm, so from a top-down view the object's own
        /// top face passed plane validation and became the support.
        private func supportFootprint(for id: UUID) -> SupportFootprint? {
            if let footprint = capturedFootprintByObject[id] {
                return SupportFootprint(
                    widthAxis: footprint.widthAxis,
                    width: footprint.width,
                    depth: footprint.depth,
                    centerXZ: footprint.centerXZ
                )
            }
            return bootstrapSupportFootprint(for: id)
        }

        /// A world-axis-aligned extent over the object's accumulated points. It only has to be
        /// large enough to cover the object; the fitted footprint replaces it after the first fit.
        /// Recomputed only as the point cloud actually grows, because this runs on every scan
        /// tick for as long as no fit has succeeded.
        private func bootstrapSupportFootprint(for id: UUID) -> SupportFootprint? {
            let points = maskedAccumulators[id]?.stablePointsSnapshot() ?? []
            guard points.count >= 8 else {
                return nil
            }
            if let cached = bootstrapSupportFootprintByObject[id],
               points.count - cached.pointCount < Self.bootstrapFootprintRefreshPoints {
                return cached.footprint
            }
            var minimum = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
            var maximum = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
            for point in points {
                let xz = SIMD2<Float>(point.position.x, point.position.z)
                minimum = simd_min(minimum, xz)
                maximum = simd_max(maximum, xz)
            }
            let size = maximum - minimum
            guard size.x.isFinite, size.y.isFinite else {
                return nil
            }
            let footprint = SupportFootprint(
                widthAxis: SIMD3<Float>(1, 0, 0),
                width: size.x,
                depth: size.y,
                centerXZ: (minimum + maximum) / 2
            )
            bootstrapSupportFootprintByObject[id] = (points.count, footprint)
            return footprint
        }

        /// Tests ARKit's detailed plane boundary around the outside of the object's footprint, not
        /// only beneath its center. This rejects small horizontal patches on the object itself while
        /// allowing the actual floor/table plane that surrounds it.
        private func supportPlaneValidationPoints(
            for id: UUID,
            reference: SIMD3<Float>
        ) -> [SIMD3<Float>] {
            supportPlaneValidationPoints(
                for: supportFootprint(for: id),
                reference: reference
            )
        }

        private func supportPlaneValidationPoints(
            for footprint: ObjectFootprint?,
            reference: SIMD3<Float>
        ) -> [SIMD3<Float>] {
            supportPlaneValidationPoints(
                for: footprint.map {
                    SupportFootprint(
                        widthAxis: $0.widthAxis,
                        width: $0.width,
                        depth: $0.depth,
                        centerXZ: $0.centerXZ
                    )
                },
                reference: reference
            )
        }

        private func supportPlaneValidationPoints(
            for footprint: SupportFootprint?,
            reference: SIMD3<Float>
        ) -> [SIMD3<Float>] {
            guard let footprint else {
                let radius: Float = 0.055
                return [
                    reference + SIMD3<Float>(radius, 0, 0),
                    reference + SIMD3<Float>(-radius, 0, 0),
                    reference + SIMD3<Float>(0, 0, radius),
                    reference + SIMD3<Float>(0, 0, -radius)
                ]
            }
            return footprint.perimeterPoints(
                y: reference.y,
                margin: Self.supportPerimeterMargin
            )
        }

        /// Carries the last accepted support plane across a tick or two where boundary validation
        /// happens to fail — ARKit re-cuts a plane's boundary polygon as it refines it, so the
        /// ring of validation points can fall outside it for a frame even though the surface is
        /// unchanged. Without this the base drops to the raycast or depth source and back again,
        /// and every swap moves the box.
        private func heldSupportPlaneMatch(
            _ match: SupportPlaneMatch?,
            anchors: [ARAnchor],
            for id: UUID
        ) -> SupportPlaneMatch? {
            if let match {
                lastSupportPlaneMatchByObject[id] = match
                supportPlaneMissTicks.removeValue(forKey: id)
                return match
            }
            // Only the *identity* is held. If the anchor is still there the live transform is
            // re-read, so a held tick tracks ARKit's refinements exactly as an accepted one
            // would; if ARKit has removed or merged the anchor there is nothing to hold and the
            // base falls through to the raycast immediately.
            guard let held = lastSupportPlaneMatchByObject[id],
                  let anchor = anchors.first(where: {
                      $0.identifier == held.anchorIdentifier
                  }) as? ARPlaneAnchor,
                  anchor.alignment == .horizontal else {
                lastSupportPlaneMatchByObject.removeValue(forKey: id)
                supportPlaneMissTicks.removeValue(forKey: id)
                return nil
            }
            let misses = supportPlaneMissTicks[id, default: 0] + 1
            supportPlaneMissTicks[id] = misses
            guard misses <= Self.supportPlaneMissTolerance else {
                lastSupportPlaneMatchByObject.removeValue(forKey: id)
                return nil
            }
            // A horizontal plane anchor is gravity-aligned, so its origin height is the surface.
            let refreshed = SupportPlaneMatch(
                anchorIdentifier: held.anchorIdentifier,
                height: anchor.transform.columns.3.y,
                anchorTransform: anchor.transform
            )
            lastSupportPlaneMatchByObject[id] = refreshed
            return refreshed
        }

        /// Apple's documented way to find the real surface below a point before plane detection
        /// has classified anything: an `ARRaycastQuery` allowing `.estimatedPlane`. With the
        /// session's `sceneReconstruction` set to `.mesh` — as `ARSessionManager` does — such a
        /// raycast also intersects the LiDAR scene mesh, so it returns the table or floor even
        /// where ARKit has not yet published an `ARPlaneAnchor`.
        ///
        /// Rays are cast straight down from just outside the object so they cannot land on the
        /// payload itself, and the median hit is taken so one ray slipping past a table edge onto
        /// the floor cannot move the base.
        ///
        /// Throttled and cached, because it is expensive in exactly the situation that invokes it.
        /// A raycast allowing `.estimatedPlane` traverses the reconstruction mesh, which grows for
        /// as long as the session runs, and this fallback only runs while no plane anchor covers
        /// the object — the opening seconds of a scan. Casting a fanful of rays on every fit tick
        /// there put a steadily worsening load on the main thread. The support surface does not
        /// move, so re-casting a few times a second is ample.
        private func raycastSupportHeight(
            in session: ARSession,
            footprint: SupportFootprint?,
            reference: SIMD3<Float>,
            timestamp: TimeInterval,
            for id: UUID
        ) -> Float? {
            guard sessionManager.isSceneReconstructionEnabled,
                  let footprint else {
                return nil
            }
            if let cached = supportRaycastCacheByObject[id],
               timestamp - cached.timestamp < Self.supportRaycastInterval {
                return cached.height
            }
            // Only the four edge midpoints. `perimeterPoints` puts them first and the corners
            // last; the corners are the rays most likely to slip off a table edge anyway.
            let origins = footprint.perimeterPoints(
                y: reference.y + Self.supportRaycastLift,
                margin: Self.supportPerimeterMargin
            ).prefix(Self.supportRaycastCount)
            let direction = SIMD3<Float>(0, -1, 0)
            var hits: [Float] = []
            hits.reserveCapacity(origins.count)
            for origin in origins {
                let query = ARRaycastQuery(
                    origin: origin,
                    direction: direction,
                    allowing: .estimatedPlane,
                    // `.any` is required for the scene mesh to be a valid target; the result's
                    // own normal is checked below so only level surfaces are accepted.
                    alignment: .any
                )
                // Results are ordered nearest-first, so the first level surface below the origin
                // is the one the object rests on — a table rather than the floor under it. A
                // nearer non-level hit is the object's own side in the scene mesh; skip past it.
                let height = session.raycast(query).lazy.filter { result in
                    result.targetAlignment == .horizontal
                        && abs(result.worldTransform.columns.1.y)
                            >= Self.supportRaycastNormalTolerance
                }.map {
                    $0.worldTransform.columns.3.y
                }.first { height in
                    height.isFinite
                        && reference.y - height >= 0.005
                        && reference.y - height <= ObjectCapturePipeline.maxHeight + 0.1
                }
                guard let height else {
                    continue
                }
                hits.append(height)
            }
            guard hits.count >= Self.minimumSupportRaycastHits else {
                supportRaycastCacheByObject[id] = (timestamp, nil)
                return nil
            }
            hits.sort()
            let height = hits[hits.count / 2]
            supportRaycastCacheByObject[id] = (timestamp, height)
            return height
        }

        /// Reparents only the box presentation to the chosen support plane. Object masking and
        /// evidence continue to use their dedicated nearby ARAnchor.
        private func configureCapturePresentationAnchor(
            for id: UUID,
            supportPlaneMatch: SupportPlaneMatch?
        ) {
            guard let arView else {
                return
            }

            let latestPlaneAnchor = supportPlaneMatch.flatMap { match in
                arView.session.currentFrame?.anchors.first(where: {
                    $0.identifier == match.anchorIdentifier
                }) as? ARPlaneAnchor
            }

            if let supportPlaneMatch, let latestPlaneAnchor {
                if capturePresentationPlaneIDsByObject[id]
                    != supportPlaneMatch.anchorIdentifier {
                    replaceCapturePresentationAnchor(
                        for: id,
                        with: AnchorEntity(anchor: latestPlaneAnchor),
                        in: arView
                    )
                    capturePresentationPlaneIDsByObject[id] =
                        supportPlaneMatch.anchorIdentifier
                }
                // Geometry was computed in this exact plane snapshot. RealityKit then applies any
                // later update to the same plane identifier to the local child coordinates.
                renderAnchorTransformByObject[id] = supportPlaneMatch.anchorTransform
                latestPresentationRebaseByObject[id] = matrix_identity_float4x4
                return
            }

            if capturePresentationPlaneIDsByObject.removeValue(forKey: id) != nil,
               let objectAnchor = currentObjectAnchor(
                   id: id,
                   frame: arView.session.currentFrame,
                   fallback: objectMaskAnchors[id]
               ) {
                replaceCapturePresentationAnchor(
                    for: id,
                    with: AnchorEntity(anchor: objectAnchor),
                    in: arView
                )
            }
            renderAnchorTransformByObject[id] = publishedAnchorTransformByObject[id]
                ?? evidenceAnchorTransformByObject[id]
                ?? objectMaskAnchors[id]?.transform
        }

        private func replaceCapturePresentationAnchor(
            for id: UUID,
            with replacement: AnchorEntity,
            in arView: ARView
        ) {
            arView.scene.addAnchor(replacement)
            for entity in captureEntitiesByObject[id] ?? [] {
                entity.removeFromParent()
                replacement.addChild(entity)
            }
            captureAnchorEntitiesByObject.removeValue(forKey: id)?
                .removeFromParent()
            captureAnchorEntitiesByObject[id] = replacement
        }

        private func stabilizedSupportHeight(
            candidate: Float,
            source: SupportHeightSource,
            for id: UUID
        ) -> Float? {
            guard candidate.isFinite else {
                return nil
            }
            var state = supportHeightStateByObject[id] ?? SupportHeightState()
            // The last published base, kept across a source change so the box's captured top is
            // still preserved when the base jumps between sources.
            let previous = state.value
            if state.source != source {
                // A different source is a different measurement basis, not a refinement of the
                // old one. Dropping the retained value as well lets a better source (a plane
                // anchor, or a mesh raycast replacing the depth histogram) take effect at once
                // instead of creeping toward it at `depthSupportMaximumStep` per tick.
                state.source = source
                state.value = nil
                state.recentCandidates.removeAll(keepingCapacity: true)
            }

            // ARPlaneAnchor geometry is already ARKit's tracked, definitive support. Applying a
            // display deadband here was the direct cause of a visible 1–3 mm hover, so plane-backed
            // bases follow the latest anchor exactly. Filtering remains only for noisy depth fallback.
            if case .plane = source {
                state.value = candidate
                state.recentCandidates = [candidate]
                supportHeightStateByObject[id] = state
                preserveCapturedTop(
                    whenSupportMovesFrom: previous,
                    to: candidate,
                    for: id
                )
                return candidate
            }

            state.recentCandidates.append(candidate)
            if state.recentCandidates.count > Self.supportHistoryCount {
                state.recentCandidates.removeFirst(
                    state.recentCandidates.count - Self.supportHistoryCount
                )
            }
            guard state.recentCandidates.count >= Self.minimumSupportSamples else {
                supportHeightStateByObject[id] = state
                return nil
            }

            let ordered = state.recentCandidates.sorted()
            let median = ordered[ordered.count / 2]
            if let stored = state.value {
                let delta = median - stored
                if abs(delta) > Self.depthSupportDeadband {
                    state.value = stored + min(
                        max(delta, -Self.depthSupportMaximumStep),
                        Self.depthSupportMaximumStep
                    )
                }
            } else {
                state.value = median
            }
            supportHeightStateByObject[id] = state
            preserveCapturedTop(
                whenSupportMovesFrom: previous,
                to: state.value ?? median,
                for: id
            )
            return state.value
        }

        /// When ARKit refines a support plane, keep the already-observed top face fixed while the
        /// base snaps to the new plane. This turns a base correction into the corresponding height
        /// correction instead of translating the whole box vertically.
        private func preserveCapturedTop(
            whenSupportMovesFrom previous: Float?,
            to current: Float,
            for id: UUID
        ) {
            guard let previous,
                  abs(current - previous) > 0.000_001,
                  let storedHeight = capturedHeightByObject[id] else {
                return
            }
            capturedHeightByObject[id] = max(
                storedHeight + previous - current,
                0.001
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
            let selectionPoints = displayedSelectionPoints()
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

        /// UIKit builds the keyboard lazily, on the first responder that asks for it. That first
        /// build is the single largest hitch in this app's lifetime, and until now it landed on
        /// the first lock — over a running AR session, at the exact moment the commit was also
        /// snapping the box to its plane. Paying for it here, during the idle warm-up that
        /// already exists, moves it somewhere nobody is measuring.
        ///
        /// The field is offscreen and resigns in the same run loop turn, so no keyboard is ever
        /// shown; only the machinery behind it gets built.
        private static var hasPrewarmedKeyboard = false

        private func prewarmKeyboard(in arView: ARView) {
            guard !Self.hasPrewarmedKeyboard,
                  let window = arView.window else {
                return
            }
            Self.hasPrewarmedKeyboard = true
            let field = UITextField(frame: .zero)
            field.isHidden = true
            window.addSubview(field)
            field.becomeFirstResponder()
            field.resignFirstResponder()
            field.removeFromSuperview()
        }

        private func prepareRenderersForFirstCapture() async {
            if let arView {
                prewarmKeyboard(in: arView)
            }
            guard let contentAnchor else {
                return
            }
            _ = selectionPointMesh(
                in: contentAnchor,
                minimumCapacity: Self.maximumDisplayedSelectionPointCount
            )
            selectionPointEntity?.isEnabled = false

            let material = capturedBoxMaterial(for: UUID())
            while captureBoxEntityPool.count < Self.preparedCaptureBoxEntityCount {
                guard !Task.isCancelled else {
                    return
                }
                let batchEnd = min(
                    captureBoxEntityPool.count + 6,
                    Self.preparedCaptureBoxEntityCount
                )
                while captureBoxEntityPool.count < batchEnd {
                    let entity = ModelEntity(
                        mesh: Self.unitCubeMesh,
                        materials: [material]
                    )
                    entity.isEnabled = false
                    contentAnchor.addChild(entity)
                    captureBoxEntityPool.append(entity)
                }
                if captureBoxEntityPool.count < Self.preparedCaptureBoxEntityCount {
                    try? await Task.sleep(for: .milliseconds(25))
                }
            }
        }

        private func displayedSelectionPoints() -> [SIMD3<Float>] {
            let pointGroups = selectionPointsByObject.keys
                .sorted { $0.uuidString < $1.uuidString }
                .compactMap { id -> [SIMD3<Float>]? in
                    guard let points = selectionPointsByObject[id],
                          !points.isEmpty else {
                        return nil
                    }
                    return points
                }
            guard !pointGroups.isEmpty else {
                return []
            }

            let limit = Self.maximumDisplayedSelectionPointCount
            let baseQuota = limit / pointGroups.count
            let extraQuota = limit % pointGroups.count
            return pointGroups.enumerated().flatMap { index, points in
                let quota = max(baseQuota + (index < extraQuota ? 1 : 0), 1)
                guard points.count > quota else {
                    return points
                }
                let stride = Double(points.count) / Double(quota)
                return (0..<quota).map { sampleIndex in
                    points[min(Int(Double(sampleIndex) * stride), points.count - 1)]
                }
            }
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
            cancelRefinementTasks(markPointsFinished: false)
            for index in placedPoints.indices {
                placedPoints[index].trackedRaycast?.stopTracking()
                placedPoints[index].trackedRaycast = nil
            }
        }

        private func cancelRefinementTasks(markPointsFinished: Bool) {
            for task in refinementTasks.values {
                task.cancel()
            }
            refinementTasks.removeAll()
            if markPointsFinished {
                for point in placedPoints {
                    mesEngine.finishRefiningPoint(id: point.id)
                }
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
