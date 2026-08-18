import ARKit
import CoreVideo
import ImageIO
import Metal
import RealityKit
import SwiftUI
import UIKit

// The AR view and the coordinator that drives everything happening in it: session lifecycle, the
// object mask, the scan loop, support-plane tracking and all the RealityKit content.
//
// In:  the session manager, aimer state, capture engine and the chosen measurement method.
// Out: an ARView on screen, and measurement results pushed into ObjectCaptureEngine.
//
// It is one long type on purpose - the coordinator owns mutable per-frame state that would have to
// be made internal to spread across files. Use the MARK sections to navigate.

struct ARCameraView: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let aimerState: AimerState
    let captureEngine: ObjectCaptureEngine
    let workflowMode: MeasurementWorkflowMode
    let sharedViewHost: SharedARViewHost?

    init(
        sessionManager: ARSessionManager,
        aimerState: AimerState,
        captureEngine: ObjectCaptureEngine,
        workflowMode: MeasurementWorkflowMode,
        sharedViewHost: SharedARViewHost? = nil
    ) {
        self.sessionManager = sessionManager
        self.aimerState = aimerState
        self.captureEngine = captureEngine
        self.workflowMode = workflowMode
        self.sharedViewHost = sharedViewHost
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionManager: sessionManager,
            aimerState: aimerState,
            captureEngine: captureEngine,
            workflowMode: workflowMode,
            sharedViewHost: sharedViewHost
        )
    }

    func makeUIView(context: Context) -> UIView {
        // SwiftUI owns this lightweight wrapper, never the persistent ARView itself. Measurement
        // and packing each get a distinct wrapper, so a late presentation teardown cannot remove or
        // snapshot the renderer after its next owner has mounted it elsewhere.
        let container = UIView(frame: .zero)
        container.backgroundColor = .black
        container.isOpaque = true
        let arView = context.coordinator.acquireView(mountingIn: container)
        // ContentView resets the capture engine and requests a new world only at real payload
        // boundaries. A remount after closing the packing workflow is the same payload, so erasing
        // every measured object here would be a destructive lifecycle side effect.
        let resetsTracking = sharedViewHost?.consumeMeasurementWorldRequest() ?? true
        context.coordinator.attach(to: arView)
        context.coordinator.scheduleSessionStart(resetsTracking: resetsTracking)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // UIViewRepresentable updates run inside SwiftUI's view transaction. setWorkflowMode also
        // publishes through the capture engine, so doing it synchronously here produces Xcode's
        // "Modifying state during view update" warning and undefined reconciliation behaviour.
        context.coordinator.scheduleWorkflowMode(workflowMode)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, ARCoachingOverlayViewDelegate {
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

        fileprivate static let unitCubeMesh = MeshResource.generateBox(size: 1.0)
        fileprivate static let captureBoxEdgeThickness: Float = 0.003
        fileprivate static let captureBoxDashTargetPeriod: Float = 0.018
        nonisolated fileprivate static let captureBoxMaximumDashCount = 24
        fileprivate static let captureBoxDashBudget = 60
        fileprivate static let preparedCaptureBoxEntityCount = 48
        private static let finalizeThumbnailMaximumDimension: CGFloat = 512
        private static let finalizeThumbnailFallbackMaximumDimension: CGFloat = 320
        private static let finalizeThumbnailMaximumByteCount = 512_000
        fileprivate static let automaticPointCleanupBatchSize = 1_024
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
        private let aimerState: AimerState
        private let captureEngine: ObjectCaptureEngine
        private let sharedViewHost: SharedARViewHost?
        private var sharedViewLease: SharedARRendererOwnership.Lease?
        private var workflowMode: MeasurementWorkflowMode
        private var requestedWorkflowModeRevision = 0
        private var workflowModeUpdateTask: Task<Void, Never>?
        private var sessionStartTask: Task<Void, Never>?
        private var requestedSessionStartRevision = 0
        private weak var arView: ARView?
        private var coachingOverlayView: ARCoachingOverlayView?
        private var contentAnchor: AnchorEntity?
        private var captureEntitiesByObject: [UUID: [ModelEntity]] = [:]
        private var captureAnchorEntitiesByObject: [UUID: AnchorEntity] = [:]
        private var capturePresentationPlaneIDsByObject: [UUID: UUID] = [:]
        private var renderAnchorTransformByObject: [UUID: simd_float4x4] = [:]
        private var latestPresentationRebaseByObject: [UUID: simd_float4x4] = [:]
        private var objectsAwaitingSupportPlane: Set<UUID> = []
        private var publishedAnchorTransformByObject: [UUID: simd_float4x4] = [:]
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
        private var footprintFromTopObjects: Set<UUID> = []
        private var heightFromSideObjects: Set<UUID> = []
        private var footprintStableTicks: [UUID: Int] = [:]
        private var heightStableTicks: [UUID: Int] = [:]
        private static let dimensionDeadband: Float = 0.004
        private static let dimensionRelativeDeadband: Float = 0.03
        private static let dimensionBlend: Float = 0.35
        private static let positionDeadband: Float = 0.004
        private static let orientationDeadbandDegrees: Float = 1.5
        private static let orientationBlend: Float = 0.2
        private static let depthSupportDeadband: Float = 0.001
        private static let depthSupportMaximumStep: Float = 0.002
        private static let supportHistoryCount = 7
        private static let minimumSupportSamples = 3
        private static let satisfiedTickCount = 6
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
        /// Idle segmentation runs at roughly 6 Hz. Retain a small/far live object through brief
        /// Vision misses while the participant changes distance, but still clear a stale mask.
        ///
        /// Back to twelve, about two seconds. It was cut to six when a stale mask also meant a mask stuck
        /// at the wrong size and place; now that the mask is followed through the world, a retained one
        /// stays on its object and only its silhouette is slightly old. Clearing it sooner than Vision
        /// recovers is what made the mask blink out and come back.
        private static let liveMaskMissTolerance = 12
        private static let topAlignmentEnterDegrees: Float = 12
        private static let topAlignmentExitDegrees: Float = 18
        private var topAlignmentAccepted = false
        private var acceptedSurfaceVoxelKeysByObject: [UUID: Set<SelectionVoxelKey>] = [:]
        private var manuallyRejectedVoxelKeysByObject: [UUID: Set<SelectionVoxelKey>] = [:]
        /// Consecutive frames whose silhouette placed a retained voxel outside the object. Reset the
        /// moment a frame agrees with the voxel; see `carvePointsOutside`.
        private var silhouetteDisagreementsByObject: [UUID: [SelectionVoxelKey: Int]] = [:]
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
        private var lastObjectMaskFinishedAt: CFTimeInterval = 0
        private var lastObjectMaskDuration: CFTimeInterval = 0
        private var lastObjectMaskSubmittedFrameTimestamp: TimeInterval =
            -.greatestFiniteMagnitude
        private var objectMaskDisplayTask: Task<Void, Never>?
        private var objectMaskDisplayTaskGeneration = 0
        private var objectMaskDisplaySeedsByID: [UUID: ObjectMaskDisplaySeed] = [:]
        /// The point in the room that the live mask on screen was sampled at, kept so it can be
        /// reprojected every frame. Cleared with the live mask itself.
        private var liveMaskWorldPoint: SIMD3<Float>?
        /// The point sampled by the newest segmentation, which becomes the one above only if that
        /// segmentation's mask is actually put on screen. Holding the picture while moving the point it is
        /// positioned by is what made a held mask twitch.
        private var pendingLiveMaskWorldPoint: SIMD3<Float>?
        /// When the mask now on screen was accepted, and whether the newest segmentation was held back.
        private var liveMaskAcceptedTimestamp: TimeInterval = -.greatestFiniteMagnitude
        private var isHoldingLiveMask = false
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
        private var isRealtimeProcessingSuspended = true
        private var memoryWarningObserver: NSObjectProtocol?
        private var observedCaptureResetRevision = 0
        private var observedObjectMaskToggleRequestRevision = 0
        private var observedObjectWorkflowRequestRevision = 0
        private var observedMeshVisible = false
        private var observedShowsSelectedPoints = false
        /// Whether the scene graph is currently being drawn. See handleEngineRevisionChange.
        private var isSceneContentEnabled = true
        private var observedShowsBoundingBoxes = true
        private var observedFrameEpoch = 0

        init(
            sessionManager: ARSessionManager,
            aimerState: AimerState,
            captureEngine: ObjectCaptureEngine,
            workflowMode: MeasurementWorkflowMode,
            sharedViewHost: SharedARViewHost?
        ) {
            self.sessionManager = sessionManager
            self.aimerState = aimerState
            self.captureEngine = captureEngine
            self.workflowMode = workflowMode
            self.sharedViewHost = sharedViewHost
        }

        // MARK: - Lifecycle

        func acquireView(mountingIn container: UIView) -> ARView {
            guard let sharedViewHost else {
                let view = ARView(
                    frame: .zero,
                    cameraMode: .ar,
                    automaticallyConfigureSession: false
                )
                mount(view, in: container)
                return view
            }
            let lease = sharedViewHost.acquire(
                .measurement,
                mountingIn: container
            ) { [weak self] in
                self?.detach()
            }
            sharedViewLease = lease
            return sharedViewHost.view
        }

        private func mount(_ view: ARView, in container: UIView) {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }

        func prepareForNewWorld() {
            captureEngine.reset()
        }

        func attach(to arView: ARView) {
            self.arView = arView
            installCoachingOverlay(in: arView)
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
            // The shared session keeps the same coordinate frame while the operator briefly visits
            // packing. Its old RealityKit entities were correctly removed during hand-off, so rebuild
            // the saved measurement outlines in the new coordinator without altering their data.
            for (id, object) in captureEngine.capturedObjectsByID {
                objectMaskColorsByID[id] = captureEngine.objectColor(for: id)
                addCapturedBox(object, for: id)
            }
            updateMeshVisibility()

            synchronizeRealtimeProcessing()

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

        /// UIViewRepresentable construction happens during SwiftUI reconciliation. Configuring the
        /// observable session/capture models synchronously there triggers "Modifying state during
        /// view update". Yield one actor turn, then start only if this coordinator still owns the
        /// renderer; a cover can be presented or dismissed during that turn.
        func scheduleSessionStart(resetsTracking: Bool) {
            requestedSessionStartRevision &+= 1
            let revision = requestedSessionStartRevision
            sessionStartTask?.cancel()
            sessionStartTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled,
                      let self,
                      self.requestedSessionStartRevision == revision,
                      self.ownsSharedView,
                      let arView = self.arView else {
                    return
                }
                self.sessionManager.configure(
                    arView.session,
                    resetsTracking: resetsTracking
                )
                self.captureEngine.setMeasurementMode(self.workflowMode)
                if let sharedViewHost = self.sharedViewHost,
                   let sharedViewLease = self.sharedViewLease {
                    sharedViewHost.activateCameraFeed(for: sharedViewLease)
                } else {
                    arView.environment.background = .cameraFeed()
                }
                self.sessionStartTask = nil
            }
        }

        func scheduleWorkflowMode(_ mode: MeasurementWorkflowMode) {
            guard workflowMode != mode else { return }
            requestedWorkflowModeRevision &+= 1
            let revision = requestedWorkflowModeRevision
            workflowModeUpdateTask?.cancel()
            workflowModeUpdateTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled,
                      let self,
                      self.requestedWorkflowModeRevision == revision,
                      self.ownsSharedView else {
                    return
                }
                self.setWorkflowMode(mode)
            }
        }

        private func setWorkflowMode(_ mode: MeasurementWorkflowMode) {
            guard workflowMode != mode else {
                return
            }
            workflowMode = mode
            captureEngine.setMeasurementMode(mode)
            resetScanState()
            updateTopViewAlignment(from: arView?.session.currentFrame)
        }

        @objc private func updateMaskDisplay() {
            guard !sessionManager.isTrackingSuspended,
                  let arView else {
                return
            }
            updateFastObjectMaskPreview(in: arView)
            updateObjectMaskPreview(in: arView)
        }

        private func synchronizeRealtimeProcessing() {
            let shouldSuspend = sessionManager.isTrackingSuspended
            guard shouldSuspend != isRealtimeProcessingSuspended else {
                return
            }
            if shouldSuspend {
                isRealtimeProcessingSuspended = true
                stopRealtimeProcessing()
            } else {
                guard arView != nil else {
                    return
                }
                isRealtimeProcessingSuspended = false
                startRealtimeProcessingIfNeeded()
            }
        }

        private func startRealtimeProcessingIfNeeded() {
            guard !sessionManager.isTrackingSuspended,
                  let arView else {
                return
            }

            if rendererWarmupTask == nil {
                rendererWarmupTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else {
                        return
                    }
                    await self?.prepareRenderersForFirstCapture()
                }
            }

            if aimerUpdateTimer == nil {
                aimerUpdateTimer = Timer.scheduledTimer(
                    withTimeInterval: 1.0 / 15.0,
                    repeats: true
                ) { [weak self, weak arView] _ in
                    guard let self, let arView else {
                        return
                    }

                    Task { @MainActor in
                        self.handleEngineRevisionChange()
                        guard !self.sessionManager.isTrackingSuspended else {
                            return
                        }
                        self.updateSessionFrameStatus(in: arView)
                        self.updateAimerSurface(in: arView)
                        self.updateFastObjectMaskMarkers(in: arView)
                        self.updateScanLive(in: arView)
                        self.refreshSupportPlaneBindings(in: arView)
                        self.updateCaptureBoxLineStyles(in: arView)
                    }
                }
            }

            if maskDisplayLink == nil {
                let displayLink = CADisplayLink(
                    target: self,
                    selector: #selector(updateMaskDisplay)
                )
                displayLink.preferredFrameRateRange = CAFrameRateRange(
                    minimum: 30,
                    maximum: 60,
                    preferred: 60
                )
                displayLink.add(to: .main, forMode: .common)
                maskDisplayLink = displayLink
            }
        }

        private func stopRealtimeProcessing(publishesCancellation: Bool = true) {
            aimerUpdateTimer?.invalidate()
            aimerUpdateTimer = nil
            maskDisplayLink?.invalidate()
            maskDisplayLink = nil
            rendererWarmupTask?.cancel()
            rendererWarmupTask = nil
            invalidateInFlightFrameWork(publishesCancellation: publishesCancellation)
        }

        func detach() {
            sessionStartTask?.cancel()
            sessionStartTask = nil
            requestedSessionStartRevision &+= 1
            workflowModeUpdateTask?.cancel()
            workflowModeUpdateTask = nil
            requestedWorkflowModeRevision &+= 1
            isRealtimeProcessingSuspended = true
            stopRealtimeProcessing(publishesCancellation: false)
            coachingOverlayView?.delegate = nil
            coachingOverlayView?.session = nil
            coachingOverlayView?.removeFromSuperview()
            coachingOverlayView = nil
            if let memoryWarningObserver {
                NotificationCenter.default.removeObserver(memoryWarningObserver)
                self.memoryWarningObserver = nil
            }
            objectMaskTask?.cancel()
            objectMaskTaskGeneration &+= 1
            objectMaskTask = nil
            cancelCaptureFit()
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
            removeAllObjectMaskAnchors()
            clearAllCaptureContent(publishesScanReset: false)

            removeSelectionPointEntity()
            captureBoxEntityPool.removeAll()

            if let contentAnchor, let arView {
                arView.scene.removeAnchor(contentAnchor)
            }

            if let arView {
                if let sharedViewHost, let sharedViewLease {
                    // A SwiftUI dismantle can arrive after the next screen has acquired this same
                    // ARView. In that case this coordinator is stale and must not clear the new
                    // owner's delegate or pause its session.
                    if sharedViewHost.owns(sharedViewLease) {
                        sessionManager.detach(arView.session)
                        sharedViewHost.release(sharedViewLease)
                    }
                } else {
                    sessionManager.detach(arView.session)
                    arView.session.delegate = nil
                    arView.session.pause()
                    arView.removeFromSuperview()
                }
            }

            arView = nil
            sharedViewLease = nil
            contentAnchor = nil

            // Observable UI cleanup cannot be published from dismantleUIView's SwiftUI update
            // transaction. Do it on the next main-actor turn, and never let a stale dismantle clear
            // state after a new measurement renderer has already acquired the shared view.
            let captureEngine = captureEngine
            let sharedViewHost = sharedViewHost
            Task { @MainActor [weak captureEngine, weak sharedViewHost] in
                guard sharedViewHost?.hasMeasurementOwner != true else { return }
                captureEngine?.cancelObjectSelection()
                captureEngine?.updateLockedObjectMaskCount(0)
                captureEngine?.updateObjectMaskTracking(visibleCount: 0, markers: [])
                captureEngine?.clearObjectMaskPreview()
                captureEngine?.resetScanGuidance()
            }
        }

        private var ownsSharedView: Bool {
            guard let sharedViewHost else { return true }
            guard let sharedViewLease else { return false }
            return sharedViewHost.owns(sharedViewLease)
        }

        // MARK: - Coaching overlay

        private func installCoachingOverlay(in arView: ARView) {
            let coachingOverlay = ARCoachingOverlayView()
            coachingOverlay.translatesAutoresizingMaskIntoConstraints = false
            coachingOverlay.delegate = self
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

        /// Frees the point clouds and voxel bookkeeping an object needed *while it was being measured*.
        ///
        /// These are the largest things the scan holds — the accumulated depth points, the selected and
        /// surface point arrays of the last fit, the accepted/rejected voxel keys — and they were being
        /// kept for every finished object until the payload ended. Ten objects into a payload that is a
        /// great deal of memory held for nothing, on a screen that is also running ARKit, LiDAR depth,
        /// Vision segmentation and RealityKit. Nothing reads them once the object is finished: editing it
        /// again calls `rebaseAndRestartMeasurement`, which clears exactly this set and starts over.
        ///
        /// Deliberately *not* freed: the support height and plane bindings, the fitted footprint and
        /// height, the anchors and the drawn box. A finished object still gets re-snapped when its plane
        /// is refined, and that needs them.
        private func releaseMeasurementScratch(for id: UUID) {
            supportAccumulators.removeValue(forKey: id)
            maskedAccumulators.removeValue(forKey: id)
            liveResultsByObject.removeValue(forKey: id)
            acceptedSurfaceVoxelKeysByObject.removeValue(forKey: id)
            manuallyRejectedVoxelKeysByObject.removeValue(forKey: id)
            silhouetteDisagreementsByObject.removeValue(forKey: id)
            automaticPointCleanupCursorByObject.removeValue(forKey: id)
            newestMaskedPointTimestamp.removeValue(forKey: id)
            fittedMaskedPointTimestamp.removeValue(forKey: id)
            footprintStableTicks.removeValue(forKey: id)
            heightStableTicks.removeValue(forKey: id)
            footprintFromTopObjects.remove(id)
            heightFromSideObjects.remove(id)
        }

        private func releaseRebuildableScanCaches() {
            // Under memory pressure, every object that is not being measured right now gives up its
            // scratch immediately rather than waiting for the payload to end.
            for id in captureEngine.finalizedObjectIDs
            where id != captureEngine.activeObjectID {
                releaseMeasurementScratch(for: id)
            }
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

        // MARK: - Reacting to engine state

        private func observeEngineRevisions() {
            withObservationTracking {
                _ = captureEngine.resetRevision
                _ = captureEngine.objectMaskToggleRequestRevision
                _ = captureEngine.objectWorkflowRequestRevision
                _ = captureEngine.isMeshVisible
                _ = captureEngine.showsSelectedPoints
                _ = captureEngine.showsBoundingBoxes
                _ = sessionManager.isTrackingSuspended
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

        private func handleEngineRevisionChange() {
            synchronizeRealtimeProcessing()

            // Put the scene down while the session is suspended. Pausing the session stops the camera
            // but leaves this ARView drawing every box, every dashed edge, the point cloud and the
            // world mesh on each frame against a frozen image — and while the packing screens are up
            // the room view has a second ARView rendering on top of it. Two RealityKit renderers, the
            // heavier of them drawing something nobody can see, and by the second payload this scene
            // is at its largest.
            //
            // RealityKit has no equivalent of SceneKit's `isPaused`, so what is switched off is the
            // content: only the top-level anchors, so each entity keeps its own visibility for when it
            // comes back. Set before the guard below, which returns as soon as the session is
            // suspended.
            if let arView, isSceneContentEnabled == sessionManager.isTrackingSuspended {
                isSceneContentEnabled = !sessionManager.isTrackingSuspended
                for anchor in arView.scene.anchors {
                    anchor.isEnabled = isSceneContentEnabled
                }
            }

            guard !sessionManager.isTrackingSuspended else {
                return
            }

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
                sessionManager.setSceneMeshEnabled(observedMeshVisible)
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

        private func invalidateInFlightFrameWork(
            publishesCancellation: Bool = true
        ) {
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
            if publishesCancellation {
                captureEngine.cancelObjectSelection()
            }
            lastObjectMaskSubmittedFrameTimestamp = -.greatestFiniteMagnitude
            lastAutomaticPointCleanupTimestamp = -.greatestFiniteMagnitude
            previewTargetPosition = nil
            lastAimerRaycastTransform = nil
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
                if let arView {
                    captureFinalizeThumbnail(
                        for: request.id,
                        normalizedViewportBoundingBox:
                            request.snapshotViewportBoundingBox,
                        in: arView
                    )
                }
                _ = snapCaptureToCurrentSupportPlane(
                    for: request.id,
                    isCommitting: true
                )
                // Redraw it solid now that it is finished, releasing its dash entities.
                if let finishedObject = captureEngine.capturedObjectsByID[request.id] {
                    renderCapturedBoxSpans(
                        captureBoxLineSpans(
                            for: finishedObject,
                            objectID: request.id,
                            cameraPosition: .zero
                        ),
                        for: request.id
                    )
                }
                selectionPointsByObject.removeValue(forKey: request.id)
                releaseMeasurementScratch(for: request.id)
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

        // MARK: - Finalize thumbnail

        private func captureFinalizeThumbnail(
            for id: UUID,
            normalizedViewportBoundingBox: CGRect?,
            in arView: ARView
        ) {
            arView.snapshot(saveToHDR: false) { [weak self, weak arView] image in
                guard let self, let arView, let image else {
                    return
                }
                Task { @MainActor [weak self, weak arView] in
                    guard let self,
                          let arView,
                          self.arView === arView,
                          self.captureEngine.finalizedObjectIDs.contains(id),
                          let data = Self.thumbnailJPEGData(
                              from: image,
                              normalizedViewportBoundingBox:
                                  normalizedViewportBoundingBox
                          ) else {
                        return
                    }
                    self.captureEngine.setSnapshotJPEGData(data, for: id)
                }
            }
        }

        private static func thumbnailJPEGData(
            from image: UIImage,
            normalizedViewportBoundingBox: CGRect?
        ) -> Data? {
            guard image.size.width.isFinite,
                  image.size.height.isFinite,
                  image.size.width > 0,
                  image.size.height > 0 else {
                return nil
            }

            let normalizedCrop = safeNormalizedThumbnailCrop(
                normalizedViewportBoundingBox
            )
            guard let primary = renderedThumbnail(
                from: image,
                normalizedCrop: normalizedCrop,
                maximumDimension: finalizeThumbnailMaximumDimension
            ) else {
                return nil
            }
            for quality in [0.72, 0.58, 0.44] {
                if let data = primary.jpegData(compressionQuality: quality),
                   data.count <= finalizeThumbnailMaximumByteCount {
                    return data
                }
            }

            guard let fallback = renderedThumbnail(
                from: image,
                normalizedCrop: normalizedCrop,
                maximumDimension: finalizeThumbnailFallbackMaximumDimension
            ),
            let data = fallback.jpegData(compressionQuality: 0.4),
            data.count <= finalizeThumbnailMaximumByteCount else {
                return nil
            }
            return data
        }

        private static func safeNormalizedThumbnailCrop(
            _ boundingBox: CGRect?
        ) -> CGRect {
            let fullViewport = CGRect(x: 0, y: 0, width: 1, height: 1)
            guard let boundingBox,
                  boundingBox.origin.x.isFinite,
                  boundingBox.origin.y.isFinite,
                  boundingBox.width.isFinite,
                  boundingBox.height.isFinite,
                  boundingBox.width >= 0.01,
                  boundingBox.height >= 0.01,
                  boundingBox.intersects(fullViewport) else {
                return fullViewport
            }

            let horizontalPadding = max(boundingBox.width * 0.4, 0.06)
            let verticalPadding = max(boundingBox.height * 0.4, 0.06)
            let padded = boundingBox.insetBy(
                dx: -horizontalPadding,
                dy: -verticalPadding
            ).intersection(fullViewport)
            guard !padded.isNull,
                  padded.width >= 0.01,
                  padded.height >= 0.01 else {
                return fullViewport
            }
            return padded
        }

        private static func renderedThumbnail(
            from image: UIImage,
            normalizedCrop: CGRect,
            maximumDimension: CGFloat
        ) -> UIImage? {
            let sourceCrop = CGRect(
                x: normalizedCrop.minX * image.size.width,
                y: normalizedCrop.minY * image.size.height,
                width: normalizedCrop.width * image.size.width,
                height: normalizedCrop.height * image.size.height
            )
            guard sourceCrop.width.isFinite,
                  sourceCrop.height.isFinite,
                  sourceCrop.width > 0,
                  sourceCrop.height > 0 else {
                return nil
            }

            let scale = min(
                maximumDimension / max(sourceCrop.width, sourceCrop.height),
                1
            )
            let outputSize = CGSize(
                width: max(floor(sourceCrop.width * scale), 1),
                height: max(floor(sourceCrop.height * scale), 1)
            )
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
            return renderer.image { context in
                UIColor.black.setFill()
                context.fill(CGRect(origin: .zero, size: outputSize))
                image.draw(
                    in: CGRect(
                        x: -sourceCrop.minX * scale,
                        y: -sourceCrop.minY * scale,
                        width: image.size.width * scale,
                        height: image.size.height * scale
                    )
                )
            }
        }

        @discardableResult
        // MARK: - Support plane

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
                    rebaseAndRestartMeasurement(for: id)
                    if !didReacquireSupport {
                        objectsAwaitingSupportPlane.insert(id)
                    }
                }
            }
        }

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
            silhouetteDisagreementsByObject.removeValue(forKey: id)
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

        // MARK: - Object mask

        private func updateMeshVisibility() {
            guard let arView else {
                return
            }

            let shouldShow = sessionManager.isSceneReconstructionEnabled
                && captureEngine.isMeshVisible
            if shouldShow {
                arView.debugOptions.insert(.showSceneUnderstanding)
            } else {
                arView.debugOptions.remove(.showSceneUnderstanding)
            }
            let shouldOcclude = sessionManager.isSceneReconstructionEnabled
                && captureEngine.showsSelectedPoints
                && !captureEngine.showsBoundingBoxes
            if shouldOcclude {
                arView.environment.sceneUnderstanding.options.insert(.occlusion)
            } else {
                arView.environment.sceneUnderstanding.options.remove(.occlusion)
            }
        }

        /// Segmentation is resubmitted the instant the previous pass finishes, which pins the neural
        /// engine and starves ARKit's own tracking of the CPU. Hold a floor between passes, and back
        /// off further on a device where a pass is slow, so the pipeline never takes more than about
        /// half the time. A pending selection is urgent and gets the fastest cadence.
        private var objectMaskInterval: CFTimeInterval {
            let floor: CFTimeInterval = pendingObjectMaskToggleRequest != nil
                ? 1.0 / 20
                : captureEngine.activeObjectID != nil ? 1.0 / 12 : 1.0 / 6
            return max(floor, lastObjectMaskDuration)
        }

        private func updateObjectMaskPreview(in arView: ARView) {
            let now = CACurrentMediaTime()
            guard objectMaskTask == nil,
                  now - lastObjectMaskFinishedAt >= objectMaskInterval,
                  arView.window != nil,
                  arView.bounds.width > 0,
                  arView.bounds.height > 0,
                  sessionManager.isTrackingReady,
                  let frame = arView.session.currentFrame,
                  case .normal = frame.camera.trackingState,
                  frame.timestamp > lastObjectMaskSubmittedFrameTimestamp else {
                return
            }
            let submittedAt = now

            let orientation = cameraImageOrientation(in: arView)
            let viewportSize = arView.bounds.size
            let imageToViewportTransform = frame.displayTransform(
                for: interfaceOrientation(in: arView),
                viewportSize: viewportSize
            )

            let submittedToggleRequest: ObjectMaskToggleRequest?
            if pendingObjectMaskToggleRequest != nil,
               !sessionManager.isObjectTrackingEnvironmentReady {
                // Keep the user's accepted selection queued while ARKit finishes finding the
                // supporting surface. Rejecting it here made the framing screen's Start action
                // appear ineffective even though the user had already accepted the framing.
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

                self.lastObjectMaskDuration = CACurrentMediaTime() - submittedAt
                self.lastObjectMaskFinishedAt = CACurrentMediaTime()
                self.objectMaskTask = nil
                guard self.captureEngine.resetRevision
                        == submittedResetRevision else {
                    return
                }
                guard self.sessionManager.frameEpoch == submittedFrameEpoch,
                      !wasCancelled,
                      self.workflowMode == submittedWorkflowMode,
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
                    if let silhouette = cloud.silhouette {
                        self.carvePointsOutside(silhouette, for: cloud.id)
                    }
                    self.captureEngine.updateActiveMeasurementDetail(
                        id: cloud.id,
                        stablePointCount: self.maskedAccumulators[cloud.id]?
                            .stablePointCount ?? 0
                    )
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
                    // The whole live mask — picture, its reference point, the point in the room it is
                    // followed by, and the tracker seed — is one set of facts from one segmentation. If
                    // the new mask is the same view as the one on screen, *none* of it is replaced. Taking
                    // some and holding the rest is what left the mask twitching: the picture stayed put
                    // while the point it was being positioned by moved to a new sample.
                    let preview = self.previewByHoldingUnchangedLiveMask(
                        self.previewByAddingLiveObjectDistance(
                            preview,
                            frame: currentFrame,
                            in: arView
                        )
                    )
                    self.consecutiveMaskMisses = 0
                    let includesLiveMask = preview.layers.contains {
                        $0.trackedObjectID == nil
                    } || self.isHoldingLiveMask
                    let didAddLock = result.lockChange.map {
                        if case .added = $0.kind {
                            return true
                        }
                        return false
                    } ?? false
                    if includesLiveMask {
                        self.consecutiveLiveMaskMisses = 0
                    } else if didAddLock {
                        self.consecutiveLiveMaskMisses = Self.liveMaskMissTolerance
                    } else {
                        self.consecutiveLiveMaskMisses += 1
                    }
                    self.updateObjectMaskDisplaySeeds(from: preview)
                    self.captureEngine.showObjectMaskPreview(
                        preview,
                        viewportSize: arView.bounds.size
                    )
                    if self.consecutiveLiveMaskMisses >= Self.liveMaskMissTolerance {
                        self.removeLiveObjectMaskDisplaySeed()
                        self.captureEngine.clearLiveObjectMaskPreview()
                    }
                } else if result.preview == nil {
                    self.consecutiveMaskMisses += 1
                    self.consecutiveLiveMaskMisses += 1
                    if self.consecutiveLiveMaskMisses >= Self.liveMaskMissTolerance {
                        self.removeLiveObjectMaskDisplaySeed()
                        self.captureEngine.clearLiveObjectMaskPreview()
                    }
                    if result.lockedObjectCount == 0,
                       result.didToggleLock
                        || result.lockedObjectCount < previousLockedObjectCount
                        || self.consecutiveMaskMisses >= Self.liveMaskMissTolerance {
                        self.captureEngine.clearObjectMaskPreview()
                    }
                }
            }
        }

        /// Vision identifies the next object before it is anchored, but its live mask previously
        /// carried no distance. Sample LiDAR at mask-covered points and attach the median surface
        /// distance for preflight guidance. Once selected, the fitted centre remains authoritative.
        private func previewByAddingLiveObjectDistance(
            _ preview: ObjectMaskPreview,
            frame: ARFrame,
            in arView: ARView
        ) -> ObjectMaskPreview {
            let cameraPosition = frame.camera.transform.translation
            let orientation = interfaceOrientation(in: arView)
            let viewportSize = arView.bounds.size
            let sampleFractions: [CGFloat] = [0.28, 0.5, 0.72]
            // Cleared first. A segmentation that finds no depth inside its mask must not leave the
            // previous one's point behind to be adopted: the mask would then be positioned by a point
            // belonging to somewhere else, which is a jump rather than a wobble.
            pendingLiveMaskWorldPoint = nil

            let layers = preview.layers.map { layer in
                guard layer.trackedObjectID == nil,
                      let box = layer.referenceViewportBoundingBox,
                      let alphaMap = ObjectMaskAlphaMap(layer.image) else {
                    return layer
                }

                var samples: [(point: CGPoint, distance: Float, world: SIMD3<Float>)] = []
                for yFraction in sampleFractions {
                    for xFraction in sampleFractions {
                        let point = CGPoint(
                            x: box.minX + box.width * xFraction,
                            y: box.minY + box.height * yFraction
                        )
                        guard alphaMap.contains(point, radius: 1),
                              let worldPoint = DepthPointCloud.worldPoint(
                                  from: frame,
                                  normalizedViewportPoint: point,
                                  interfaceOrientation: orientation,
                                  viewportSize: viewportSize
                              ) else {
                            continue
                        }
                        samples.append((
                            point: point,
                            distance: simd_distance(cameraPosition, worldPoint),
                            world: worldPoint
                        ))
                    }
                }
                guard !samples.isEmpty else { return layer }
                samples.sort { $0.distance < $1.distance }
                let sample = samples[samples.count / 2]
                // Where this mask is in the room. From here on the mask is kept on the object by
                // reprojecting this point every frame, which works at any distance and any apparent size
                // — unlike Vision's object tracker, which gives up once the target is small in frame.
                pendingLiveMaskWorldPoint = sample.world

                return ObjectMaskPreviewLayer(
                    id: layer.id,
                    image: layer.image,
                    trackedObjectID: layer.trackedObjectID,
                    referenceAnchorPoint: sample.point,
                    referenceCameraDistance: sample.distance,
                    referenceViewportBoundingBox: layer.referenceViewportBoundingBox,
                    trackingBoundingBox: layer.trackingBoundingBox,
                    trackingOrientation: layer.trackingOrientation
                )
            }
            return ObjectMaskPreview(layers: layers, timestamp: preview.timestamp)
        }

        /// Drops the incoming live mask when it is the same view of the same object as the one already on
        /// screen, leaving that one — and everything that positions it — exactly as it is.
        ///
        /// Vision re-segments several times a second and its silhouette is never quite the same twice, so
        /// replacing the picture every time is a permanent shimmer. Size and position do not need the new
        /// picture: the mask is followed through the world, which resizes and moves it continuously
        /// between segmentations. Only a genuinely different view is worth swapping in, and a hold is
        /// capped in time so a mask cannot go stale.
        private func previewByHoldingUnchangedLiveMask(
            _ preview: ObjectMaskPreview
        ) -> ObjectMaskPreview {
            guard let incoming = preview.layers.first(where: { $0.trackedObjectID == nil }) else {
                isHoldingLiveMask = false
                return preview
            }
            let onScreen = captureEngine.objectMaskPreview?.layers.first {
                $0.trackedObjectID == nil
            }
            guard ObjectMaskPreviewHold.holdsExistingLayer(
                existing: onScreen?.referenceViewportBoundingBox,
                incoming: incoming.referenceViewportBoundingBox,
                secondsHeld: preview.timestamp - liveMaskAcceptedTimestamp
            ) else {
                isHoldingLiveMask = false
                liveMaskAcceptedTimestamp = preview.timestamp
                liveMaskWorldPoint = pendingLiveMaskWorldPoint
                return preview
            }
            isHoldingLiveMask = true
            return ObjectMaskPreview(
                layers: preview.layers.filter { $0.trackedObjectID != nil },
                timestamp: preview.timestamp
            )
        }

        private func updateFastObjectMaskPreview(in arView: ARView) {
            guard                   sessionManager.isTrackingReady,
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
                    applicableBoundingBoxes,
                    viewportSize: arView.bounds.size
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
                // A mask too small for Vision to track is followed through the world instead. Seeding the
                // tracker with it only produces a decaying box, which is worse than no box at all.
                //
                // The tracker is deliberately still run for everything above that size: its box is no
                // longer what places the mask, but it is what the centring advice and the finished
                // object's snapshot bounds are read from.
                guard MaskTrackerEligibility.isTrackable(
                    boundingBox: layer.referenceViewportBoundingBox
                ) else {
                    objectMaskDisplaySeedsByID.removeValue(forKey: layer.id)
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
            liveMaskWorldPoint = nil
            pendingLiveMaskWorldPoint = nil
            isHoldingLiveMask = false
            liveMaskAcceptedTimestamp = -.greatestFiniteMagnitude
            captureEngine.updateLiveMaskTracking(nil)
            guard let liveObjectMaskDisplayID else {
                return
            }
            objectMaskDisplaySeedsByID.removeValue(
                forKey: liveObjectMaskDisplayID
            )
            self.liveObjectMaskDisplayID = nil
        }

        private func updateFastObjectMaskMarkers(in arView: ARView) {
            guard                   sessionManager.isTrackingReady,
                  let frame = arView.session.currentFrame,
                  case .normal = frame.camera.trackingState else {
                captureEngine.updateObjectMaskMarkers([])
                captureEngine.updateLiveMaskTracking(nil)
                return
            }
            captureEngine.updateObjectMaskMarkers(currentObjectMaskMarkers(in: arView))
            updateLiveMaskTracking(frame: frame, in: arView)
        }

        /// Reprojects the live mask's own point in the room, every frame. This is what keeps a small
        /// object's mask on the object at the distance the accuracy rule asks for: ARKit can place a
        /// world point on screen however few pixels the object covers.
        private func updateLiveMaskTracking(frame: ARFrame, in arView: ARView) {
            guard let worldPoint = liveMaskWorldPoint,
                  captureEngine.objectMaskPreview?.layers.contains(where: {
                      $0.trackedObjectID == nil
                  }) == true else {
                captureEngine.updateLiveMaskTracking(nil)
                return
            }
            let viewportSize = arView.bounds.size
            guard viewportSize.width > 0, viewportSize.height > 0 else { return }
            // A point behind the camera still projects, to nonsense. Turning away from the object would
            // otherwise fling its mask across the screen before the mask was dropped.
            let inCamera = frame.camera.transform.inverse * SIMD4<Float>(worldPoint, 1)
            guard inCamera.z < -0.01 else {
                captureEngine.updateLiveMaskTracking(nil)
                return
            }
            let projected = frame.camera.projectPoint(
                worldPoint,
                orientation: interfaceOrientation(in: arView),
                viewportSize: viewportSize
            )
            let point = CGPoint(
                x: projected.x / viewportSize.width,
                y: projected.y / viewportSize.height
            )
            guard point.x.isFinite,
                  point.y.isFinite,
                  (-0.5 ... 1.5).contains(point.x),
                  (-0.5 ... 1.5).contains(point.y) else {
                captureEngine.updateLiveMaskTracking(nil)
                return
            }
            captureEngine.updateLiveMaskTracking(
                ObjectMaskWorldTracking(
                    normalizedViewportPoint: point,
                    cameraDistance: simd_distance(
                        frame.camera.transform.translation,
                        worldPoint
                    )
                )
            )
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

        /// Space carving against one frame's silhouette, exactly.
        ///
        /// Points are only ever added to an accumulator, so a frame on which the mask jumped to the
        /// wrong segment leaves foreign points behind for the rest of the scan, and the box — the
        /// literal extent of the points — grows to contain them. This is the standard silhouette
        /// argument (visual hull / space carving): a point inside the frustum, unoccluded, and outside
        /// the object's silhouette cannot be part of the object.
        ///
        /// Unlike `removeVisiblePointsOutsideCurrentMask`, which warps viewport coordinates by an
        /// approximate scale-and-offset because its mask may be up to 0.2 s stale, everything used here
        /// comes from one frame — silhouette, pose, intrinsics, depth — so the projection is exact and
        /// needs no motion compensation at all.
        ///
        /// A point is removed after `minObservations` frames have independently placed it outside the
        /// silhouette, mirroring the same constant that a point needs to be trusted in the first place:
        /// evidence to drop a point is held to the standard as evidence to keep one. A single frame is
        /// never enough, so one bad segmentation cannot erase a real surface.
        private func carvePointsOutside(_ silhouette: ObjectMaskSilhouette, for objectID: UUID) {
            guard var accumulator = maskedAccumulators[objectID] else {
                return
            }
            let retained = accumulator.stablePointsSnapshot()
            guard !retained.isEmpty else {
                return
            }

            var carved: [SIMD3<Float>] = []
            var stillOutside: Set<SelectionVoxelKey> = []

            for point in retained {
                guard let hit = silhouette.pixel(for: point.position) else {
                    continue
                }
                guard silhouette.isClearlyOutside(column: hit.column, row: hit.row) else {
                    continue
                }
                // Depth is measured to the nearest surface along the ray, so anything nearer than the
                // point means the point is hidden this frame — including by the object's own front face
                // when the point is on its far side. A hidden point is not evidence of empty space, so
                // this frame says nothing about it and it keeps whatever doubt it already had. One voxel
                // of slack absorbs sensor noise about "same surface".
                let measured = silhouette.depths[hit.row * silhouette.width + hit.column]
                if measured > 0, measured < hit.depth - ObjectCapturePipeline.voxelSize {
                    continue
                }
                let key = selectionVoxelKey(for: point.position)
                stillOutside.insert(key)
                if (silhouetteDisagreementsByObject[objectID]?[key] ?? 0) + 1
                    >= ObjectCapturePipeline.minObservations {
                    carved.append(point.position)
                    carved.append(point.observedPosition)
                }
            }

            var counts = silhouetteDisagreementsByObject[objectID] ?? [:]
            // A point that this frame agrees with loses its accumulated doubt: only *repeated*
            // disagreement carves, and it has to be repeated without a frame vouching for the point
            // in between.
            for key in Array(counts.keys) where !stillOutside.contains(key) {
                counts.removeValue(forKey: key)
            }
            for key in stillOutside {
                counts[key, default: 0] += 1
            }
            silhouetteDisagreementsByObject[objectID] = counts

            guard !carved.isEmpty else {
                return
            }
            cancelCaptureFit()
            accumulator.removeVoxels(containing: carved)
            maskedAccumulators[objectID] = accumulator
            for point in carved {
                silhouetteDisagreementsByObject[objectID]?
                    .removeValue(forKey: selectionVoxelKey(for: point))
            }
        }

        private func removeVisiblePointsOutsideCurrentMask(in arView: ARView) {
            guard                   sessionManager.isAutomaticObjectCaptureSupported,
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
            let cleanedResult = CaptureResult(
                object: cleanedObject,
                selectionPoints: retainedSelectionPoints,
                surfacePoints: retainedSurfacePoints
            )
            liveResultsByObject[objectID] = cleanedResult
            acceptedSurfaceVoxelKeysByObject[objectID] = Set(
                retainedSelectionPoints.filter {
                    result.object.contains(
                        $0,
                        tolerance: ObjectCapturePipeline.selectionTolerance
                    )
                }.map(selectionVoxelKey(for:))
            )
            fittedMaskedPointTimestamp[objectID] = -.greatestFiniteMagnitude
            selectionPointsByObject[objectID] = selectionVisualizationPoints(
                for: cleanedResult
            )
            updateSelectionVisualization()
        }

        // MARK: - Frame status and selection requests

        private func updateSessionFrameStatus(in arView: ARView) {
            guard let frame = arView.session.currentFrame else {
                updateTopViewAlignment(from: nil)
                return
            }
            sessionManager.updateFrameStatus(from: frame)
            updateTopViewAlignment(from: frame)
            updatePointingAtFinishedObject(from: frame, in: arView)
        }

        /// Whether the crosshair is on something already measured, so the button can say so.
        ///
        /// Worked out from the stored boxes rather than from tracking: a handful of ray-versus-box
        /// tests per frame, against nothing per frame at all now that finished objects have been
        /// dropped from the mask tracker. That is the whole point — the answer to "have I measured
        /// this?" does not need Vision to keep following it around.
        private func updatePointingAtFinishedObject(from frame: ARFrame, in arView: ARView) {
            let finalized = captureEngine.finalizedObjectIDs
            guard !finalized.isEmpty, captureEngine.activeObjectID == nil else {
                captureEngine.setPointingAtFinishedObject(false)
                return
            }

            let origin = SIMD3<Float>(
                frame.camera.transform.columns.3.x,
                frame.camera.transform.columns.3.y,
                frame.camera.transform.columns.3.z
            )
            let direction = simd_normalize(
                -SIMD3<Float>(
                    frame.camera.transform.columns.2.x,
                    frame.camera.transform.columns.2.y,
                    frame.camera.transform.columns.2.z
                )
            )

            let isPointing = finalized.contains { id in
                guard let object = captureEngine.capturedObjectsByID[id] else { return false }
                return Self.ray(
                    origin: origin,
                    direction: direction,
                    hits: object
                )
            }
            captureEngine.setPointingAtFinishedObject(isPointing)
        }

        /// Ray against an oriented box, by putting the ray into the box's own frame and running the
        /// usual slab test. Sampled along the ray rather than solved, because the box is small on
        /// screen and a coarse answer is all a button label needs.
        private static func ray(
            origin: SIMD3<Float>,
            direction: SIMD3<Float>,
            hits object: CapturedObject
        ) -> Bool {
            let axes = [object.axes.width, object.axes.depth, object.axes.height]
            let half = object.dimensions / 2
            var near: Float = 0.05
            var far: Float = 4

            for index in 0..<3 {
                let axis = axes[index]
                let extent = half[index]
                let originOnAxis = simd_dot(origin - object.center, axis)
                let directionOnAxis = simd_dot(direction, axis)
                if abs(directionOnAxis) < 1e-6 {
                    if abs(originOnAxis) > extent { return false }
                    continue
                }
                let first = (-extent - originOnAxis) / directionOnAxis
                let second = (extent - originOnAxis) / directionOnAxis
                near = max(near, min(first, second))
                far = min(far, max(first, second))
                if near > far { return false }
            }
            return true
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
                silhouetteDisagreementsByObject.removeValue(forKey: change.id)
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

        // MARK: - Scan loop

        private func updateScanLive(in arView: ARView) {
            guard                   sessionManager.isAutomaticObjectCaptureSupported else {
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
            // An ARKit plane anchor is the best support evidence, not the only kind the app trusts:
            // the box being drawn is already sitting on whatever `resolvedSupportHeight` returned,
            // raycast or depth histogram included. Requiring the plane anchor here as well is what
            // left small objects — the ones whose table ARKit is slowest to bound — measuring to
            // 100% and then refusing to finish, with no manual finish to fall back on.
            captureEngine.updateActiveSupportPlaneAvailability(
                id: activeObjectID,
                isAvailable: planeSupportMatch != nil
                    || supportHeightStateByObject[activeObjectID]?.value != nil
            )

            updateTopViewAlignment(from: frame)
            guard workflowMode != .top || topAlignmentAccepted else {
                return
            }

            // Do not spend the cleanup interval on a stale Vision result. Previously the timestamp
            // advanced first and `removeVisiblePointsOutsideCurrentMask` then rejected the stale
            // preview, so an unlucky phase between the two loops could prevent cleanup repeatedly.
            if frame.timestamp - lastAutomaticPointCleanupTimestamp >= 0.5,
               let preview = captureEngine.objectMaskPreview,
               abs(frame.timestamp - preview.timestamp) <= 0.2 {
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
            captureEngine.updateActiveMeasurementDetail(
                id: id,
                stablePointCount: objectPoints.count
            )
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
                        self.captureEngine.reportActiveMeasurementNeedsMoreDetail(id: id)
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
                        selectionPointsByObject[id] = selectionVisualizationPoints(
                            for: retainedResult
                        )
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
            selectionPointsByObject[id] = selectionVisualizationPoints(
                for: acceptedResult
            )
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

        // MARK: - Resetting

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
            silhouetteDisagreementsByObject.removeAll()
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
            silhouetteDisagreementsByObject.removeAll()
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
        // MARK: - Aimer

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
                aimerState.updateAimerSurface(
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

            aimerState.updateAimerSurface(
                scaleY: scaleY,
                rotationDegrees: rotation,
                distanceScale: distanceScale,
                isDetected: true
            )
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
        // MARK: - Drawing the captured box

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
            // Dashed rear edges are a live-scan affordance, and each dash is its own entity. A
            // finished box keeps its entities for the rest of the session, so 12 solid edges rather
            // than up to 60 dashes is the difference between a scene that stays fast and one that
            // gains hundreds of draw calls per object measured.
            guard !captureEngine.finalizedObjectIDs.contains(objectID) else {
                return Self.captureBoxEdges.map {
                    (start: object.corners[$0.0], end: object.corners[$0.1])
                }
            }
            let rearEdges = captureBoxRearEdges(
                for: object,
                objectID: objectID,
                cameraPosition: cameraPosition
            )
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
                    let surplus = entities[index]
                    surplus.isEnabled = false
                    surplus.removeFromParent()
                    if captureBoxEntityPool.count < Self.preparedCaptureBoxEntityCount {
                        captureBoxEntityPool.append(surplus)
                    }
                }
                entities.removeSubrange(renderableSpans.count..<entities.count)
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

        private func clearAllCaptureContent(publishesScanReset: Bool = true) {
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
            if publishesScanReset {
                captureEngine.resetScanGuidance()
            }
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

        // MARK: - View-gated box fitting

        private func classifyView(_ camera: simd_float4x4) -> ObjectCaptureEngine.ScanViewHint {
            let forwardY = -camera.columns.2.y
            // A footprint taken from a steep three-quarter angle grows with segmentation/depth
            // spill, which showed up as repeatable over-reading in accuracy tests. Reserve the top
            // fit for a genuinely overhead view (within about 35° of vertical). The remaining useful
            // downward-to-level range supplies height, so Full 3D accepts either an isometric or a
            // lateral second view instead of forcing the phone exactly level with the object.
            if forwardY < -0.82 {
                return .topDown
            }
            if forwardY <= 0.4 {
                return .side
            }
            return .other
        }

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

            if capturedFootprintByObject[id] == nil {
                capturedFootprintByObject[id] = candidateFootprint
            }
            if capturedHeightByObject[id] == nil {
                capturedHeightByObject[id] = candidateHeight
            }

            // The footprint of the current fit, expressed in the stored footprint's axis convention
            // so that width and depth cannot swap places between frames.
            let aligned = alignFootprint(candidateFootprint, to: capturedFootprintByObject[id])

            switch view {
            case .topDown:
                if isActive {
                    captureEngine.recordDimensionObservation(.width, value: aligned.width)
                    captureEngine.recordDimensionObservation(.depth, value: aligned.depth)
                }
                if let stored = capturedFootprintByObject[id] {
                    let width = stabilize(stored.width, aligned.width)
                    let depth = stabilize(stored.depth, aligned.depth)
                    let center = stabilizePosition(stored.centerXZ, aligned.centerXZ)
                    let axis = stabilizeOrientation(stored.widthAxis, aligned.widthAxis)
                    footprintStableTicks[id] = (
                        width.stable && depth.stable
                            && center.stable && axis.stable
                    )
                        ? (footprintStableTicks[id, default: 0] + 1)
                        : 0
                } else {
                    footprintStableTicks[id] = 0
                }
                // Stabilization decides only whether the scan has settled. Drawing or publishing
                // its blended/deadband value makes the box geometrically different from the current
                // full-cloud rectangle, which is visible at the far edge in a top view.
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
                    heightStableTicks[id] = stabilize(stored, candidateHeight).stable
                        ? (heightStableTicks[id, default: 0] + 1)
                        : 0
                } else {
                    heightStableTicks[id] = 0
                }
                if (heightStableTicks[id] ?? 0) >= Self.satisfiedTickCount {
                    heightFromSideObjects.insert(id)
                }
            case .other:
                break
            }

            // The drawn height follows the current fit exactly, whichever way the phone is pointing.
            //
            // It used to be seeded from the very first frame and then updated only while the view was
            // classified `.side`. Hover over an object — which is `.topDown`, or the gap between the
            // two — and the height stayed at whatever that first frame guessed, while the point cloud
            // filled in and settled to the real extent underneath it. That is the top of the box
            // hanging above the dots.
            //
            // Nothing here is gated, because nothing needs to be: the height is the highest point
            // above the support plane, and how high a point is does not depend on where it was seen
            // from. A deadband here could leave the top as much as 4 mm (or 3%) above the current
            // cloud even after an outlying point had been mask-filtered. The convergence rule still
            // uses its observation window; only the geometric box is kept exact. The paper-derived
            // 2D footprint orientation and extents are untouched.
            capturedHeightByObject[id] = candidateHeight
            // The drawn footprint follows the current fit for exactly the same reason, and used to
            // carry exactly the same defect: it was published only while the view was classified
            // `.topDown`, so approaching an object from any other angle drew whatever rectangle the
            // first frame guessed — over a cloud that had since filled in and settled underneath it.
            // That is the box standing off the dots on every side.
            //
            // Publishing it every frame cannot make the box shrink as the phone moves, because
            // `fitted` is the fit over the *accumulated* cloud, not the current frame's: the masked
            // accumulator retains points from every earlier view and is only ever `pruneTransient`-ed,
            // so a face that has been seen stays seen. The view classification keeps its real job,
            // which is deciding when width/depth have been observed well enough to call the scan
            // settled — it just no longer decides what geometry is drawn.
            capturedFootprintByObject[id] = aligned

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
                recordTopViewObservations(footprint: aligned, height: candidateHeight)
            }
            let width = stabilize(previousFootprint.width, aligned.width)
            let depth = stabilize(previousFootprint.depth, aligned.depth)
            let heightStability = stabilize(previousHeight, candidateHeight)
            let center = stabilizePosition(previousFootprint.centerXZ, aligned.centerXZ)
            let axis = stabilizeOrientation(previousFootprint.widthAxis, aligned.widthAxis)
            // Keep the comparison against the previous exact fit for stability, but publish the
            // current fit itself. Liu/Zhang determines `aligned.widthAxis`; the application takes
            // the full-cloud min/max extents, and neither should be altered by display smoothing.
            capturedFootprintByObject[id] = aligned
            // As in Full 3D, render and publish the current fitted height. Smoothing this value made
            // the upper face visibly detach from the point that defined it after mask cleanup.
            capturedHeightByObject[id] = candidateHeight

            if width.stable && depth.stable && heightStability.stable
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
            let sine = simd_dot(up, simd_cross(stored, candidate))
            let angle = atan2(sine, cosine) * Self.orientationBlend
            let rotated = simd_quatf(angle: angle, axis: up).act(stored)
            guard simd_length(rotated) > 1e-5 else {
                return (stored, false)
            }
            return (simd_normalize(rotated), false)
        }

        // MARK: - Support geometry

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
            let refreshed = SupportPlaneMatch(
                anchorIdentifier: held.anchorIdentifier,
                height: anchor.transform.columns.3.y,
                anchorTransform: anchor.transform
            )
            lastSupportPlaneMatchByObject[id] = refreshed
            return refreshed
        }

        private func raycastSupportHeight(
            in session: ARSession,
            footprint: SupportFootprint?,
            reference: SIMD3<Float>,
            timestamp: TimeInterval,
            for id: UUID
        ) -> Float? {
            // Raycasts against ARKit's *estimated planes*, which come from plane detection and not
            // from scene reconstruction. Gating this on the world mesh was always wrong, and became
            // load-bearing the moment the mesh stopped being built by default: the support-height
            // fallback silently switched off, so a scan could sit on "waiting for the surface"
            // indefinitely and lean on the much heavier depth path instead.
            guard sessionManager.isSceneDepthSupported,
                  let footprint else {
                return nil
            }
            if let cached = supportRaycastCacheByObject[id],
               timestamp - cached.timestamp < Self.supportRaycastInterval {
                return cached.height
            }
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
                    alignment: .any
                )
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
            let previous = state.value
            if state.source != source {
                state.source = source
                state.value = nil
                state.recentCandidates.removeAll(keepingCapacity: true)
            }

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

        // MARK: - Selection point cloud

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

            if let selectionPointEntity, var model = selectionPointEntity.model {
                model.materials = [selectionPointMaterial()]
                selectionPointEntity.model = model
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

        /// Points for objects still being worked on, thinned to a fixed budget.
        ///
        /// Finished objects are left out on purpose. Their box is already drawn, so the cloud only
        /// added clutter — and because the budget is split evenly between objects, keeping them
        /// meant the live object's cloud got sparser with every object saved, which read as the
        /// points appearing at random.
        private func displayedSelectionPoints() -> [SIMD3<Float>] {
            let finalized = captureEngine.finalizedObjectIDs
            let pointGroups = selectionPointsByObject.keys
                .sorted { $0.uuidString < $1.uuidString }
                .compactMap { id -> [SIMD3<Float>]? in
                    guard !finalized.contains(id),
                          let points = selectionPointsByObject[id],
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
                stableDisplaySubset(
                    points,
                    limit: max(baseQuota + (index < extraQuota ? 1 : 0), 1)
                )
            }
        }

        /// Raw depth samples are what the operator should see, but the fitted cloud uses each
        /// stable voxel's mean as well. Include the highest fitted mean when it sits above every raw
        /// sample so the cyan cloud always contains the exact point that can set the upper face.
        private func selectionVisualizationPoints(
            for result: CaptureResult
        ) -> [SIMD3<Float>] {
            guard let fittedTop = result.selectionPoints.max(by: { $0.y < $1.y }) else {
                return result.surfacePoints
            }
            let observedTop = result.surfacePoints.max(by: { $0.y < $1.y })?.y
                ?? -Float.greatestFiniteMagnitude
            guard fittedTop.y > observedTop else {
                return result.surfacePoints
            }
            var points = result.surfacePoints
            points.append(fittedTop)
            return points
        }

        /// Which points to draw. See SelectionPointDisplay for why this is not a stride.
        private func stableDisplaySubset(
            _ points: [SIMD3<Float>],
            limit: Int
        ) -> [SIMD3<Float>] {
            SelectionPointDisplay.subsetPreservingCoordinateExtrema(
                points,
                limit: limit
            ) { point in
                let key = selectionVoxelKey(for: point)
                return SelectionPointDisplay.hash(x: key.x, y: key.y, z: key.z)
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
                materials: [selectionPointMaterial()]
            )
            selectionPointEntity?.removeFromParent()
            contentAnchor.addChild(entity)
            selectionPointMesh = mesh
            selectionPointEntity = entity
            selectionPointMeshCapacity = capacity
            return mesh
        }

        private func selectionPointMaterial() -> UnlitMaterial {
            let id = captureEngine.activeObjectID
            let colour = id.flatMap { captureEngine.objectColor(for: $0) }
                ?? id.flatMap { objectMaskColorsByID[$0] }
                ?? ObjectMaskDisplayColor(red: 0.10, green: 0.82, blue: 1.00)
            return UnlitMaterial(
                color: UIColor(
                    red: CGFloat(colour.red),
                    green: CGFloat(colour.green),
                    blue: CGFloat(colour.blue),
                    alpha: 1
                ),
                applyPostProcessToneMap: false
            )
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
