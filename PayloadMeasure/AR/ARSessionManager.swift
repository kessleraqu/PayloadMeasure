import ARKit
import AVFoundation
import CoreVideo
import Observation
import simd

// Owns the ARKit session: configuration, capability checks, interruption handling and suspension.
//
// In:  lifecycle calls from the view, and ARKit delegate callbacks.
// Out: observable readiness flags the UI gates on - tracking state, scene depth, whether a usable
//      support plane exists, and whether the session is currently suspended.

@MainActor
@Observable
final class ARSessionManager: NSObject, ARSessionDelegate {
    private enum SuspensionReason: Hashable {
        case packingArrangement
        case applicationInactive
    }

    private weak var activeSession: ARSession?
    private var activeConfiguration: ARWorldTrackingConfiguration?
    private var initialRunOptions: ARSession.RunOptions = [
        .resetTracking,
        .removeExistingAnchors
    ]
    private var sessionStartTask: Task<Void, Never>?
    private var suspensionReasons: Set<SuspensionReason> = []
    private var isSessionRunning = false
    private var automaticRecoveryAttempts = 0
    /// When tracking last became normal, on the monotonic clock. Cleared whenever it stops being normal,
    /// so the settling time is always the *continuous* run of good tracking.
    private var normalTrackingSince: TimeInterval?
    private var horizontalPlaneAnchorIDs: Set<UUID> = []
    private var verticalPlaneAnchorIDs: Set<UUID> = []

    enum EnvironmentReadiness: Equatable {
        case preparing(String)
        case ready(String)

        var title: String {
            switch self {
            case .preparing:
                "Understanding environment"
            case .ready:
                "Environment ready"
            }
        }

        var detail: String {
            switch self {
            case .preparing(let message), .ready(let message):
                message
            }
        }

        var isReady: Bool {
            if case .ready = self {
                return true
            }
            return false
        }
    }

    enum TrackingStatus: Equatable {
        case starting
        case normal
        case limited(String)
        case unavailable
        case interrupted
        case failed(String)

        var title: String {
            switch self {
            case .starting:
                "Starting AR"
            case .normal:
                "Tracking ready"
            case .limited:
                "Tracking limited"
            case .unavailable:
                "Tracking unavailable"
            case .interrupted:
                "Session interrupted"
            case .failed:
                "Session failed"
            }
        }

        var detail: String {
            switch self {
            case .starting:
                "Move the iPhone slowly to map the payload area."
            case .normal:
                "AR tracking is stable enough for measurement setup."
            case .limited(let reason):
                reason
            case .unavailable:
                "ARKit cannot currently determine the device position."
            case .interrupted:
                "The AR session was interrupted. Keep the camera on the scene."
            case .failed(let message):
                message
            }
        }
    }

    private(set) var trackingStatus: TrackingStatus = .starting
    private(set) var isSceneDepthSupported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    private(set) var isSceneDepthEnabled = false
    private(set) var isSceneReconstructionSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    private(set) var isSceneReconstructionEnabled = false
    private var wantsSceneMesh = false
    private(set) var hasDetectedHorizontalPlane = false
    private(set) var hasDetectedVerticalPlane = false
    private(set) var hasReceivedSceneDepth = false
    private(set) var sceneDepthResolutionText = "Waiting for depth"
    private(set) var hasReconstructedMesh = false
    private(set) var worldMappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    private(set) var isCoachingActive = false
    private(set) var isTrackingSuspended = false
    /// The packing workflow owns the camera for its entire lifetime. ContentView uses this distinct
    /// flag to remove the measurement ARView from the hierarchy, rather than merely pausing its
    /// session and leaving a second RealityKit renderer underneath the packing renderer.
    private(set) var isPackingArrangementPresented = false
    private(set) var frameEpoch = 0
    private(set) var environmentReadiness: EnvironmentReadiness = .preparing(
        "Move the iPhone slowly across the object and its supporting surface."
    )

    var isTrackingReady: Bool {
        !isTrackingSuspended && trackingStatus == .normal
    }

    var isLiDARAvailable: Bool {
        isSceneDepthSupported && isSceneReconstructionSupported
    }

    var isObjectTrackingEnvironmentReady: Bool {
        environmentReadiness.isReady
    }

    var trackingHardwareText: String {
        isLiDARAvailable
            ? "LiDAR-assisted world tracking"
            : "Camera-based world tracking"
    }

    var isAutomaticObjectCaptureSupported: Bool {
        isSceneDepthSupported
    }

    var depthStatusText: String {
        if isSceneDepthEnabled {
            "Scene depth enabled"
        } else if isSceneDepthSupported {
            "Scene depth supported, not enabled"
        } else {
            "Scene depth unavailable"
        }
    }

    var sceneReconstructionStatusText: String {
        if isSceneReconstructionEnabled {
            "LiDAR mesh enabled"
        } else if isSceneReconstructionSupported {
            "LiDAR mesh supported, not enabled"
        } else {
            "LiDAR mesh unavailable"
        }
    }

    var planeStatusText: String {
        switch (hasDetectedHorizontalPlane, hasDetectedVerticalPlane) {
        case (true, true):
            "Horizontal and vertical planes detected"
        case (true, false):
            "Horizontal plane detected"
        case (false, true):
            "Vertical plane detected"
        case (false, false):
            "Scanning for planes"
        }
    }

    var worldMappingStatusText: String {
        switch worldMappingStatus {
        case .notAvailable:
            "Not available"
        case .limited:
            "Limited — improving"
        case .extending:
            "Extending"
        case .mapped:
            "Mapped"
        @unknown default:
            "Unknown"
        }
    }

    func configure(_ session: ARSession, resetsTracking: Bool = true) {
        sessionStartTask?.cancel()
        sessionStartTask = nil
        isSessionRunning = false
        automaticRecoveryAttempts = 0
        activeSession = session
        session.delegate = self
        isCoachingActive = false
        initialRunOptions = resetsTracking
            ? [.resetTracking, .removeExistingAnchors]
            : []

        // A rebuilt view hierarchy means no packing sheet is on screen any more. That suspension
        // reason is owned by a SwiftUI presentation, so if the view that set it is destroyed without
        // the sheet being dismissed — exactly what happens when the study moves from one payload box
        // to the next — nothing ever clears it. The session then stays paused forever and the HUD
        // sits on "understanding environment" that never completes. Application inactivity is not
        // cleared here: that one reflects real app state, not a presentation.
        suspensionReasons.remove(.packingArrangement)
        isPackingArrangementPresented = false
        isTrackingSuspended = !suspensionReasons.isEmpty
        frameEpoch &+= 1
        trackingStatus = .starting
        hasDetectedHorizontalPlane = false
        hasDetectedVerticalPlane = false
        horizontalPlaneAnchorIDs.removeAll()
        verticalPlaneAnchorIDs.removeAll()
        hasReceivedSceneDepth = false
        sceneDepthResolutionText = isSceneDepthSupported ? "Waiting for depth" : "Unavailable"
        hasReconstructedMesh = false
        worldMappingStatus = .notAvailable
        environmentReadiness = .preparing(
            isSceneDepthSupported
                ? "LiDAR is starting. Move slowly across the object and table."
                : "Move slowly across the object and table until a surface is detected."
        )

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        // Objects rest on horizontal surfaces, the coaching goal is a horizontal plane, and every
        // consumer filters vertical planes out. Detecting them was pure cost.
        configuration.planeDetection = [.horizontal]
        configuration.environmentTexturing = .none

        if isSceneDepthSupported {
            configuration.frameSemantics.insert(.sceneDepth)
            isSceneDepthEnabled = true
        } else {
            isSceneDepthEnabled = false
        }

        // The world mesh grows for as long as the session runs and is never cheap to maintain, and
        // the only thing that reads it is the mesh/occlusion toggle, which is off by default. Build
        // it on request rather than always.
        if isSceneReconstructionSupported, wantsSceneMesh {
            configuration.sceneReconstruction = .mesh
            isSceneReconstructionEnabled = true
        } else {
            isSceneReconstructionEnabled = false
        }

        activeConfiguration = configuration
        if !resetsTracking, let frame = session.currentFrame {
            updateEnvironmentAnchors(from: frame.anchors)
            worldMappingStatus = frame.worldMappingStatus
            if let depth = frame.sceneDepth {
                hasReceivedSceneDepth = true
                sceneDepthResolutionText = "\(CVPixelBufferGetWidth(depth.depthMap)) × \(CVPixelBufferGetHeight(depth.depthMap)) px"
            }
        }
        if isTrackingSuspended {
            session.pause()
            updateSuspendedReadiness()
        } else {
            startWhenCameraIsAuthorized(session, configuration: configuration)
        }
    }

    /// Turning the mesh on re-runs the session with scene reconstruction. Tracking and anchors are
    /// kept, so the scan is not disturbed.
    func setSceneMeshEnabled(_ isEnabled: Bool) {
        guard isSceneReconstructionSupported, wantsSceneMesh != isEnabled else { return }
        wantsSceneMesh = isEnabled
        guard let activeSession, let activeConfiguration else { return }
        activeConfiguration.sceneReconstruction = isEnabled ? .mesh : []
        isSceneReconstructionEnabled = isEnabled
        guard !isTrackingSuspended else { return }
        run(activeSession, configuration: activeConfiguration)
    }

    func detach(_ session: ARSession) {
        guard activeSession === session else {
            return
        }
        sessionStartTask?.cancel()
        sessionStartTask = nil
        session.delegate = nil
        activeSession = nil
        activeConfiguration = nil
        isSessionRunning = false
        // detach is invoked by UIViewRepresentable.dismantleUIView during SwiftUI reconciliation.
        // Publishing here causes "Modifying state during view update". Clear the visible coaching
        // flag on the next turn, unless a new measurement renderer has already configured itself.
        Task { @MainActor [weak self] in
            guard let self, self.activeSession == nil else { return }
            self.isCoachingActive = false
        }
    }

    func setPackingArrangementPresented(_ isPresented: Bool) {
        if isPackingArrangementPresented != isPresented {
            isPackingArrangementPresented = isPresented
        }
        setSuspensionReason(.packingArrangement, isActive: isPresented)
    }

    func setApplicationActive(_ isActive: Bool) {
        setSuspensionReason(.applicationInactive, isActive: !isActive)
    }

    func updateCoachingState(isActive: Bool) {
        if isCoachingActive != isActive {
            isCoachingActive = isActive
        }
    }

    func restartTracking(_ session: ARSession) {
        guard activeSession === session,
              let activeConfiguration else {
            return
        }
        guard !isTrackingSuspended else { return }
        automaticRecoveryAttempts = 0
        frameEpoch &+= 1
        trackingStatus = .starting
        hasDetectedHorizontalPlane = false
        hasDetectedVerticalPlane = false
        horizontalPlaneAnchorIDs.removeAll()
        verticalPlaneAnchorIDs.removeAll()
        hasReceivedSceneDepth = false
        sceneDepthResolutionText = isSceneDepthSupported ? "Waiting for depth" : "Unavailable"
        hasReconstructedMesh = false
        worldMappingStatus = .notAvailable
        environmentReadiness = .preparing(
            "Restarting tracking. Move the iPhone slowly around the payload area."
        )
        run(
            session,
            configuration: activeConfiguration,
            options: [.resetTracking, .removeExistingAnchors]
        )
    }

    /// Accuracy protocols deliberately make consecutive readings independent. These helpers expose
    /// only the two pieces the protocol needs without handing a SwiftUI screen ownership of ARSession.
    func restartTracking() {
        guard let activeSession else { return }
        restartTracking(activeSession)
    }

    func cameraDistanceMetres(to worldPosition: SIMD3<Float>) -> Double? {
        guard let frame = activeSession?.currentFrame,
              case .normal = frame.camera.trackingState else {
            return nil
        }
        let column = frame.camera.transform.columns.3
        let cameraPosition = SIMD3<Float>(column.x, column.y, column.z)
        return Double(simd_distance(cameraPosition, worldPosition))
    }

    private func startWhenCameraIsAuthorized(
        _ session: ARSession,
        configuration: ARWorldTrackingConfiguration
    ) {
        guard activeSession === session,
              !isTrackingSuspended,
              !isSessionRunning else {
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession(session, configuration: configuration)
        case .notDetermined:
            guard sessionStartTask == nil else {
                return
            }
            environmentReadiness = .preparing(
                "Allow camera access, then move slowly across the payload area."
            )
            sessionStartTask = Task { @MainActor [weak self, weak session] in
                let isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
                guard !Task.isCancelled,
                      let self,
                      let session,
                      self.activeSession === session,
                      !self.isTrackingSuspended else {
                    return
                }
                self.sessionStartTask = nil
                if isAuthorized {
                    self.startSession(session, configuration: configuration)
                } else {
                    self.reportCameraPermissionFailure()
                }
            }
        case .denied, .restricted:
            reportCameraPermissionFailure()
        @unknown default:
            reportCameraPermissionFailure()
        }
    }

    private func startSession(
        _ session: ARSession,
        configuration: ARWorldTrackingConfiguration
    ) {
        guard activeSession === session,
              !isTrackingSuspended,
              !isSessionRunning else {
            return
        }
        trackingStatus = .starting
        run(
            session,
            configuration: configuration,
            options: initialRunOptions
        )
        initialRunOptions = []
    }

    private func setSuspensionReason(
        _ reason: SuspensionReason,
        isActive: Bool
    ) {
        let didChange = isActive
            ? suspensionReasons.insert(reason).inserted
            : suspensionReasons.remove(reason) != nil
        guard didChange else {
            return
        }

        let shouldSuspend = !suspensionReasons.isEmpty
        guard shouldSuspend != isTrackingSuspended else {
            return
        }
        isTrackingSuspended = shouldSuspend
        frameEpoch &+= 1

        if shouldSuspend {
            suspendActiveSession()
        } else {
            resumeActiveSessionIfPossible()
        }
    }

    private func suspendActiveSession() {
        sessionStartTask?.cancel()
        sessionStartTask = nil
        if let activeSession, isSessionRunning {
            activeSession.pause()
        }
        isSessionRunning = false
        updateSuspendedReadiness()
    }

    private func resumeActiveSessionIfPossible() {
        guard !isTrackingSuspended,
              let activeSession,
              let activeConfiguration,
              !isSessionRunning else {
            return
        }

        trackingStatus = .starting
        environmentReadiness = .preparing(
            "Resuming AR tracking. Keep the camera pointed at the payload area."
        )

        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            run(
                activeSession,
                configuration: activeConfiguration,
                options: initialRunOptions
            )
            initialRunOptions = []
        } else {
            startWhenCameraIsAuthorized(
                activeSession,
                configuration: activeConfiguration
            )
        }
    }

    private func run(
        _ session: ARSession,
        configuration: ARWorldTrackingConfiguration,
        options: ARSession.RunOptions = []
    ) {
        guard activeSession === session,
              !isTrackingSuspended else {
            return
        }
        session.run(configuration, options: options)
        isSessionRunning = true
    }

    private func updateSuspendedReadiness() {
        environmentReadiness = .preparing(
            "Camera capture and AR tracking are paused."
        )
    }

    private func reportCameraPermissionFailure() {
        trackingStatus = .failed(
            "Camera access is required. Enable it for PayloadMeasure in Settings, then reopen the app."
        )
        refreshEnvironmentReadiness()
    }

    @discardableResult
    func recoverFailedSessionIfPossible(_ session: ARSession) -> Bool {
        guard activeSession === session,
              !isTrackingSuspended,
              case .failed = trackingStatus,
              automaticRecoveryAttempts == 0,
              AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              let activeConfiguration else {
            return false
        }
        automaticRecoveryAttempts += 1
        frameEpoch &+= 1
        trackingStatus = .starting
        hasDetectedHorizontalPlane = false
        hasDetectedVerticalPlane = false
        horizontalPlaneAnchorIDs.removeAll()
        verticalPlaneAnchorIDs.removeAll()
        hasReceivedSceneDepth = false
        sceneDepthResolutionText = isSceneDepthSupported ? "Waiting for depth" : "Unavailable"
        hasReconstructedMesh = false
        worldMappingStatus = .notAvailable
        environmentReadiness = .preparing(
            "Restarting AR tracking. Move slowly across the payload area."
        )
        run(
            session,
            configuration: activeConfiguration,
            options: [.resetTracking, .removeExistingAnchors]
        )
        return true
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor in
            guard activeSession === session,
                  !isTrackingSuspended else {
                return
            }
            updateTrackingStatus(from: camera.trackingState)
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        Task { @MainActor in
            guard activeSession === session,
                  !isTrackingSuspended else {
                return
            }
            updateEnvironmentAnchors(from: anchors)
            refreshEnvironmentReadiness()
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        Task { @MainActor in
            guard activeSession === session,
                  !isTrackingSuspended else {
                return
            }
            updateEnvironmentAnchors(from: anchors)
            refreshEnvironmentReadiness()
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        Task { @MainActor in
            guard activeSession === session,
                  !isTrackingSuspended else {
                return
            }
            for anchor in anchors {
                horizontalPlaneAnchorIDs.remove(anchor.identifier)
                verticalPlaneAnchorIDs.remove(anchor.identifier)
            }
            hasDetectedHorizontalPlane = !horizontalPlaneAnchorIDs.isEmpty
            hasDetectedVerticalPlane = !verticalPlaneAnchorIDs.isEmpty
            refreshEnvironmentReadiness()
        }
    }

    func updateFrameStatus(from frame: ARFrame) {
        guard !isTrackingSuspended else {
            return
        }
        let mappingStatus = frame.worldMappingStatus
        let depthData = frame.sceneDepth
        let receivedDepth = depthData != nil
        let depthResolutionText = depthData.map {
            "\(CVPixelBufferGetWidth($0.depthMap)) × \(CVPixelBufferGetHeight($0.depthMap)) px"
        }
        // While still preparing, readiness is re-examined on every frame: part of it is how long
        // tracking has been normal, and a clock does not announce itself with a state change.
        guard worldMappingStatus != mappingStatus
                || (receivedDepth && !hasReceivedSceneDepth)
                || !environmentReadiness.isReady
                || (depthResolutionText != nil
                    && depthResolutionText != sceneDepthResolutionText) else {
            return
        }
        worldMappingStatus = mappingStatus
        hasReceivedSceneDepth = hasReceivedSceneDepth || receivedDepth
        if let depthResolutionText {
            sceneDepthResolutionText = depthResolutionText
        }
        refreshEnvironmentReadiness()
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            guard activeSession === session else {
                return
            }
            isSessionRunning = false
            frameEpoch &+= 1
            trackingStatus = .interrupted
            refreshEnvironmentReadiness()
        }
    }

    nonisolated func sessionShouldAttemptRelocalization(
        _ session: ARSession
    ) -> Bool {
        true
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            guard activeSession === session else {
                return
            }
            guard !isTrackingSuspended else {
                updateSuspendedReadiness()
                return
            }
            resumeActiveSessionIfPossible()
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            guard activeSession === session else {
                return
            }
            isSessionRunning = false
            frameEpoch &+= 1
            trackingStatus = .failed(error.localizedDescription)
            refreshEnvironmentReadiness()
        }
    }

    private func updateTrackingStatus(from trackingState: ARCamera.TrackingState) {
        switch trackingState {
        case .normal:
            trackingStatus = .normal
        case .notAvailable:
            trackingStatus = .unavailable
        case .limited(let reason):
            trackingStatus = .limited(limitedTrackingMessage(for: reason))
        }
        refreshEnvironmentReadiness()
    }

    private func limitedTrackingMessage(for reason: ARCamera.TrackingState.Reason) -> String {
        switch reason {
        case .initializing:
            "AR tracking is starting. Move the iPhone slowly in a small arc."
        case .excessiveMotion:
            "The iPhone is moving too quickly. Slow down for better tracking."
        case .insufficientFeatures:
            "The scene has too few visual features. Aim at textured surfaces."
        case .relocalizing:
            "ARKit is trying to recover its previous position."
        @unknown default:
            "Tracking is limited for an unknown reason."
        }
    }

    private func updateEnvironmentAnchors(from anchors: [ARAnchor]) {
        for anchor in anchors {
            if anchor is ARMeshAnchor {
                hasReconstructedMesh = true
            }

            if let planeAnchor = anchor as? ARPlaneAnchor {
                switch planeAnchor.alignment {
                case .horizontal:
                    if planeAnchor.classification == .ceiling {
                        horizontalPlaneAnchorIDs.remove(planeAnchor.identifier)
                    } else {
                        horizontalPlaneAnchorIDs.insert(planeAnchor.identifier)
                    }
                case .vertical:
                    verticalPlaneAnchorIDs.insert(planeAnchor.identifier)
                @unknown default:
                    continue
                }
            }
        }
        hasDetectedHorizontalPlane = !horizontalPlaneAnchorIDs.isEmpty
        hasDetectedVerticalPlane = !verticalPlaneAnchorIDs.isEmpty
    }

    private func refreshEnvironmentReadiness() {
        guard !isTrackingSuspended else {
            updateSuspendedReadiness()
            return
        }
        guard trackingStatus == .normal else {
            normalTrackingSince = nil
            setEnvironmentReadiness(.preparing(trackingStatus.detail))
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        let normalTrackingSeconds = now - (normalTrackingSince ?? now)
        if normalTrackingSince == nil {
            normalTrackingSince = now
        }

        if isSceneDepthSupported {
            guard hasReceivedSceneDepth else {
                setEnvironmentReadiness(.preparing(
                    "LiDAR depth is starting. Keep the camera pointed at the payload area."
                ))
                return
            }
        }

        guard hasDetectedHorizontalPlane else {
            setEnvironmentReadiness(.preparing(
                "Move slowly across the floor or table until its horizontal support plane is detected."
            ))
            return
        }

        // Tracking says normal within a frame or two of starting, while anchors and planes are still
        // being corrected underneath whatever is measured against them. Wait for the world to settle.
        guard WorldSettlingRule.isSettled(
            normalTrackingSeconds: normalTrackingSeconds,
            mappingStatus: worldMappingStatus
        ) else {
            setEnvironmentReadiness(.preparing(
                WorldSettlingRule.waitingDetail(
                    normalTrackingSeconds: normalTrackingSeconds,
                    mappingStatus: worldMappingStatus
                )
            ))
            return
        }

        let detail: String
        if isSceneDepthSupported {
            detail = switch worldMappingStatus {
            case .mapped:
                "LiDAR depth, tracking and the supporting plane are ready."
            case .extending:
                "The supporting plane is ready. The wider environment map is improving."
            case .notAvailable, .limited:
                "The supporting plane is ready. Keep scanning to improve the wider map."
            @unknown default:
                "LiDAR depth, tracking and the supporting plane are ready."
            }
        } else {
            detail = "Tracking and a stable surface are ready."
        }
        setEnvironmentReadiness(.ready(detail))
    }

    private func setEnvironmentReadiness(_ readiness: EnvironmentReadiness) {
        if environmentReadiness != readiness {
            environmentReadiness = readiness
        }
    }
}
