//
//  ARSessionManager.swift
//  PayloadMeasure
//
//  Created by Alexandre on 29/06/2026.
//

import ARKit
import Observation

@MainActor
@Observable
final class ARSessionManager: NSObject, ARSessionDelegate {
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
    private(set) var environmentReadiness: EnvironmentReadiness = .preparing(
        "Move the iPhone slowly across the object and its supporting surface."
    )

    var isTrackingReady: Bool {
        trackingStatus == .normal
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

    /// Automatic object capture currently depends on the per-frame LiDAR depth map.
    var isAutomaticObjectCaptureSupported: Bool {
        isSceneDepthSupported
    }

    var automaticObjectCaptureAvailabilityText: String {
        isAutomaticObjectCaptureSupported
            ? "Automatic object capture available"
            : "RGB object detection is available. LiDAR is required for 3D dimensions."
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

    func configure(_ session: ARSession) {
        session.delegate = self
        trackingStatus = .starting
        hasDetectedHorizontalPlane = false
        hasDetectedVerticalPlane = false
        hasReceivedSceneDepth = false
        sceneDepthResolutionText = isSceneDepthSupported ? "Waiting for depth" : "Unavailable"
        hasReconstructedMesh = false
        worldMappingStatus = .notAvailable
        environmentReadiness = .preparing(
            isLiDARAvailable
                ? "LiDAR is starting. Move slowly across the object and table."
                : "Move slowly across the object and table until a surface is detected."
        )

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .none

        if isSceneDepthSupported {
            configuration.frameSemantics.insert(.sceneDepth)
            // Smoothed depth is temporally filtered and noticeably less noisy; the capture pipeline
            // prefers it when available.
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            }
            isSceneDepthEnabled = true
        } else {
            isSceneDepthEnabled = false
        }

        if isSceneReconstructionSupported {
            // The mesh drives the optional on-screen wireframe overlay. Object capture itself uses
            // the dense depth map, not the mesh, so a plain mesh is sufficient here.
            configuration.sceneReconstruction = .mesh
            isSceneReconstructionEnabled = true
        } else {
            isSceneReconstructionEnabled = false
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        Task { @MainActor in
            updateTrackingStatus(from: camera.trackingState)
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        Task { @MainActor in
            updateEnvironmentAnchors(from: anchors)
            refreshEnvironmentReadiness()
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        Task { @MainActor in
            updateEnvironmentAnchors(from: anchors)
            refreshEnvironmentReadiness()
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let mappingStatus = frame.worldMappingStatus
        let depthData = frame.sceneDepth ?? frame.smoothedSceneDepth
        let receivedDepth = depthData != nil
        let depthResolutionText = depthData.map {
            "\(CVPixelBufferGetWidth($0.depthMap)) × \(CVPixelBufferGetHeight($0.depthMap)) px"
        }
        Task { @MainActor in
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
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            trackingStatus = .interrupted
            refreshEnvironmentReadiness()
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            trackingStatus = .starting
            refreshEnvironmentReadiness()
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
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
            "ARKit is initializing the world map."
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
                    hasDetectedHorizontalPlane = true
                case .vertical:
                    hasDetectedVerticalPlane = true
                @unknown default:
                    continue
                }
            }
        }
    }

    private func refreshEnvironmentReadiness() {
        guard trackingStatus == .normal else {
            setEnvironmentReadiness(.preparing(trackingStatus.detail))
            return
        }

        if isLiDARAvailable {
            guard hasReceivedSceneDepth else {
                setEnvironmentReadiness(.preparing(
                    "LiDAR depth is starting. Keep the camera pointed at the payload area."
                ))
                return
            }

            guard hasReconstructedMesh || hasDetectedHorizontalPlane || hasDetectedVerticalPlane else {
                setEnvironmentReadiness(.preparing(
                    "Move slowly across the object and table while LiDAR builds the surface map."
                ))
                return
            }
        } else if !hasDetectedHorizontalPlane && !hasDetectedVerticalPlane {
            setEnvironmentReadiness(.preparing(
                "This iPhone has no LiDAR. Move slowly across the table until a stable surface is detected."
            ))
            return
        }

        switch worldMappingStatus {
        case .notAvailable, .limited:
            setEnvironmentReadiness(.preparing(
                "Continue moving slowly from side to side so returning to locked objects is reliable."
            ))
        case .extending:
            setEnvironmentReadiness(.ready(
                isLiDARAvailable
                    ? "LiDAR and world tracking are ready. You can lock objects now."
                    : "A stable surface is available. You can lock objects while the visual map improves."
            ))
        case .mapped:
            setEnvironmentReadiness(.ready(
                "The environment map is stable. Locked objects can be recovered after leaving the view."
            ))
        @unknown default:
            setEnvironmentReadiness(.preparing(
                "Continue moving slowly while ARKit finishes understanding the environment."
            ))
        }
    }

    private func setEnvironmentReadiness(_ readiness: EnvironmentReadiness) {
        if environmentReadiness != readiness {
            environmentReadiness = readiness
        }
    }
}
