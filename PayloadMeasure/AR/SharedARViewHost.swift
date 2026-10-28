import ARKit
import RealityKit
import SwiftUI
import UIKit

// One ARView shared by every camera screen in the app.
//
// On iOS 26 a second ARView created later in the presentation hierarchy can get stuck showing
// an old camera texture while tracking keeps running underneath. Reusing the same ARView avoids
// that. The measurement and packing coordinators take turns owning it.

nonisolated enum SharedARRendererRole: Equatable, Sendable {
    case measurement
    case packing
    case lidarCapture
}

/// Ownership bookkeeping, kept free of UIKit so it can be unit tested.
nonisolated struct SharedARRendererOwnership: Equatable, Sendable {
    struct Lease: Equatable, Sendable {
        let id: UUID
        let role: SharedARRendererRole
    }

    private(set) var activeLease: Lease?

    mutating func acquire(
        _ role: SharedARRendererRole,
        id: UUID = UUID()
    ) -> Lease {
        let lease = Lease(id: id, role: role)
        activeLease = lease
        return lease
    }

    /// Only the current owner can release. A late dismantle from an old presentation must not
    /// pause the session for the new owner.
    mutating func release(_ lease: Lease) -> Bool {
        guard activeLease == lease else { return false }
        activeLease = nil
        return true
    }

    func owns(_ lease: Lease) -> Bool {
        activeLease == lease
    }
}

nonisolated struct MeasurementWorldResetRequest: Equatable, Sendable {
    private(set) var isPending = true

    mutating func request() {
        isPending = true
    }

    mutating func consume() -> Bool {
        defer { isPending = false }
        return isPending
    }
}

@MainActor
final class SharedARViewHost {
    let view: ARView

    private var ownership = SharedARRendererOwnership()
    private var revokeCurrentOwner: (() -> Void)?
    private var cameraFeedActivationTask: Task<Void, Never>?
    private var cameraFeedBaseline: (
        lease: SharedARRendererOwnership.Lease,
        timestamp: TimeInterval?
    )?
    /// Set at launch and at payload boundaries. Closing the packing flow for the same payload
    /// keeps the existing world.
    private var measurementWorldReset = MeasurementWorldResetRequest()

    init() {
        let view = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        view.backgroundColor = .black
        view.isOpaque = true
        // Start black and only rebind the camera feed once ARKit delivers a new frame, otherwise the
        // previous owner's last texture can stay on screen.
        view.environment.background = .color(.black)
        self.view = view
    }

    func acquire(
        _ role: SharedARRendererRole,
        mountingIn container: UIView,
        onRevocation: @escaping () -> Void
    ) -> SharedARRendererOwnership.Lease {
        if let revokeCurrentOwner {
            // If SwiftUI overlaps two presentations, make the old coordinator clean up and release its
            // lease now, so it can't touch the renderer after the new owner takes over.
            self.revokeCurrentOwner = nil
            revokeCurrentOwner()
        }
        if ownership.activeLease != nil {
            // Fallback in case a coordinator went away without handling revocation.
            view.session.delegate = nil
            view.session.pause()
            removeAllSceneAnchors()
        }

        cameraFeedActivationTask?.cancel()
        cameraFeedActivationTask = nil
        view.environment.background = .color(.black)
        let previousFrameTimestamp = view.session.currentFrame?.timestamp
        let lease = ownership.acquire(role)
        revokeCurrentOwner = onRevocation
        cameraFeedBaseline = (lease, previousFrameTimestamp)
        view.backgroundColor = .black
        view.isOpaque = true
        mountRenderer(in: container)
        return lease
    }

    /// Rebinds the camera feed once `session.run` has produced a new frame. Doing it immediately
    /// can pick up the texture left by the previous screen.
    func activateCameraFeed(
        for lease: SharedARRendererOwnership.Lease
    ) {
        guard ownership.owns(lease),
              let baseline = cameraFeedBaseline,
              baseline.lease == lease else {
            return
        }

        cameraFeedActivationTask?.cancel()
        let previousTimestamp = baseline.timestamp
        cameraFeedActivationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.ownership.owns(lease) {
                if let timestamp = self.view.session.currentFrame?.timestamp,
                   previousTimestamp.map({ timestamp > $0 }) ?? true {
                    self.view.environment.background = .cameraFeed()
                    self.cameraFeedBaseline = nil
                    self.cameraFeedActivationTask = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }

    func owns(_ lease: SharedARRendererOwnership.Lease) -> Bool {
        ownership.owns(lease)
    }

    var hasMeasurementOwner: Bool {
        ownership.activeLease?.role == .measurement
    }

    func requestNewMeasurementWorld() {
        measurementWorldReset.request()
    }

    func consumeMeasurementWorldRequest() -> Bool {
        measurementWorldReset.consume()
    }

    func release(_ lease: SharedARRendererOwnership.Lease) {
        guard ownership.release(lease) else { return }
        revokeCurrentOwner = nil
        cameraFeedActivationTask?.cancel()
        cameraFeedActivationTask = nil
        cameraFeedBaseline = nil
        // Drop the old camera texture. The next owner stays black until activateCameraFeed runs.
        view.environment.background = .color(.black)
        view.session.delegate = nil
        view.session.pause()
        removeAllSceneAnchors()
        view.removeFromSuperview()
    }

    private func mountRenderer(in container: UIView) {
        if view.superview !== container {
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
        }
    }

    private func removeAllSceneAnchors() {
        for anchor in view.scene.anchors {
            view.scene.removeAnchor(anchor)
        }
    }
}

nonisolated private struct SharedARViewHostEnvironmentKey: EnvironmentKey {
    static let defaultValue: SharedARViewHost? = nil
}

extension EnvironmentValues {
    var sharedARViewHost: SharedARViewHost? {
        get { self[SharedARViewHostEnvironmentKey.self] }
        set { self[SharedARViewHostEnvironmentKey.self] = newValue }
    }
}
