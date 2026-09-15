import ARKit
import RealityKit
import SwiftUI
import UIKit

// One RealityKit renderer for every camera-backed screen in the app.
//
// iOS can leave the camera background of a later ARView on an old texture when another ARView has
// already existed earlier in the presentation hierarchy. Tracking and raycasts can still be live,
// which makes that failure look exactly like a still photograph laid over working AR. Reusing the
// same ARView (and therefore the same CAMetalLayer and ARSession) avoids that renderer hand-off
// entirely. The measurement and packing coordinators take turns owning it.

nonisolated enum SharedARRendererRole: Equatable, Sendable {
    case measurement
    case packing
    case lidarCapture
}

/// Pure ownership state, separate from UIKit so the important stale-release rule can be tested.
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

    /// Returns true only for the current owner. A late dismantle from an old SwiftUI presentation
    /// must never pause the session after a new presentation has acquired it.
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
    /// True at launch and after a real payload boundary. Merely closing the loading workflow for the
    /// same payload must not reset its measurements or world coordinates.
    private var measurementWorldReset = MeasurementWorldResetRequest()

    init() {
        let view = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        view.backgroundColor = .black
        view.isOpaque = true
        // A lease starts on an opaque frame. The live feed is rebound only after ARKit has produced
        // a frame newer than the one used by the previous screen; otherwise RealityKit can keep the
        // previous role's last camera texture even while tracking and raycasts continue to advance.
        view.environment.background = .color(.black)
        self.view = view
    }

    func acquire(
        _ role: SharedARRendererRole,
        mountingIn container: UIView,
        onRevocation: @escaping () -> Void
    ) -> SharedARRendererOwnership.Lease {
        if let revokeCurrentOwner {
            // Normal flow dismantles the old representable first. If SwiftUI overlaps presentation
            // transactions, synchronously ask the old coordinator to cancel its tasks/timers,
            // remove overlays/gestures, detach its manager and release its lease before reassignment.
            // Merely stealing the ARSession would leave that old coordinator able to mutate the new
            // owner's renderer later.
            self.revokeCurrentOwner = nil
            revokeCurrentOwner()
        }
        if ownership.activeLease != nil {
            // Defensive fallback if a coordinator disappeared without honoring revocation.
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

    /// Rebinds RealityKit's camera texture only after `session.run` has yielded a genuinely new
    /// ARFrame. Waiting on the timestamp is important: assigning `.cameraFeed()` immediately can
    /// bind the still-valid texture from the screen that just released the renderer.
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
        // Drop RealityKit's reference to the previous camera texture before another screen starts.
        // The next owner stays black until `activateCameraFeed` observes its first fresh ARFrame.
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
