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

    var isTrackingReady: Bool {
        trackingStatus == .normal
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

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .none

        if isSceneDepthSupported {
            configuration.frameSemantics.insert(.sceneDepth)
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
            updateDetectedPlanes(from: anchors)
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            trackingStatus = .interrupted
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            trackingStatus = .starting
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            trackingStatus = .failed(error.localizedDescription)
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

    private func updateDetectedPlanes(from anchors: [ARAnchor]) {
        for anchor in anchors {
            guard let planeAnchor = anchor as? ARPlaneAnchor else {
                continue
            }

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
