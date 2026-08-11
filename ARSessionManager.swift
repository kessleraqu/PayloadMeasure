
import ARKit
import AVFoundation
import Observation

@MainActor
@Observable
final class ARSessionManager: NSObject, ARSessionDelegate {
    private enum SuspensionReason: Hashable {
        case packingArrangement
        case applicationInactive
    }

    private weak var activeSession: ARSession?
    private var activeConfiguration: ARWorldTrackingConfiguration?
    private var sessionStartTask: Task<Void, Never>?
    private var suspensionReasons: Set<SuspensionReason> = []
    private var isSessionRunning = false
    private var automaticRecoveryAttempts = 0
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
    private(set) var hasDetectedHorizontalPlane = false
    private(set) var hasDetectedVerticalPlane = false
    private(set) var hasReceivedSceneDepth = false
    private(set) var sceneDepthResolutionText = "Waiting for depth"
    private(set) var hasReconstructedMesh = false
    private(set) var worldMappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    private(set) var isCoachingActive = false
    /// True while some UI or lifecycle owner requires both AR capture and frame processing to stop.
    /// Multiple reasons may overlap; the session resumes only after the final reason is removed.
    private(set) var isTrackingSuspended = false
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

    func configure(_ session: ARSession) {
        sessionStartTask?.cancel()
        sessionStartTask = nil
        isSessionRunning = false
        automaticRecoveryAttempts = 0
        activeSession = session
        session.delegate = self
        isCoachingActive = false
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
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .none

        if isSceneDepthSupported {
            configuration.frameSemantics.insert(.sceneDepth)
            isSceneDepthEnabled = true
        } else {
            isSceneDepthEnabled = false
        }

        if isSceneReconstructionSupported {
            configuration.sceneReconstruction = .mesh
            isSceneReconstructionEnabled = true
        } else {
            isSceneReconstructionEnabled = false
        }

        activeConfiguration = configuration
        if isTrackingSuspended {
            session.pause()
            updateSuspendedReadiness()
        } else {
            startWhenCameraIsAuthorized(session, configuration: configuration)
        }
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
        isCoachingActive = false
    }

    /// Suspends camera capture for the lifetime of the packing/result presentation. Repeating the
    /// same value is intentionally a no-op so SwiftUI presentation and dismissal callbacks cannot
    /// cause duplicate session runs.
    func setPackingArrangementPresented(_ isPresented: Bool) {
        setSuspensionReason(.packingArrangement, isActive: isPresented)
    }

    /// Keeps a dismissed arrangement from restarting the camera while the scene is inactive.
    /// Tracking resumes once, when both this and every UI suspension reason have cleared.
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
            options: [.resetTracking, .removeExistingAnchors]
        )
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
            // No reset options: preserve the world map, anchors and every measured package.
            run(activeSession, configuration: activeConfiguration)
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
            // Plane transforms and detailed boundaries improve as ARKit observes more of the
            // surface. Keep readiness tied to the current anchor set, not only the first add event.
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
        guard worldMappingStatus != mappingStatus
                || (receivedDepth && !hasReceivedSceneDepth)
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
            setEnvironmentReadiness(.preparing(trackingStatus.detail))
            return
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
