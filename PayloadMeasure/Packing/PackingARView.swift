import ARKit
import RealityKit
import SwiftUI
import simd

/// Spacing rules for the room-scale guide. Collision uses the exact package sizes; only the
/// visible bars are inset so touching packages never draw two surfaces at the same depth.
nonisolated enum PackingARVisualGeometry {
    static func packageInset(for outlineThickness: Float) -> Float {
        min(0.00075, max(0.00035, outlineThickness * 0.25))
    }

    static func insetFrameSize(
        _ size: SIMD3<Float>,
        by inset: Float
    ) -> SIMD3<Float> {
        SIMD3(
            max(0.0001, size.x - inset * 2),
            max(0.0001, size.y - inset * 2),
            max(0.0001, size.z - inset * 2)
        )
    }

    static func faceInset(for outlineThickness: Float) -> Float {
        packageInset(for: outlineThickness) + max(0.00035, outlineThickness * 0.15)
    }

    static func markerCentre(
        face: Float,
        normalExtent: Float,
        markerDepth: Float,
        inset: Float
    ) -> Float {
        let magnitude = max(0, normalExtent / 2 - inset - markerDepth / 2)
        return (face < 0 ? -1 : 1) * magnitude
    }

    /// Maximum drag distance from where the module was placed, so a bad gesture can't send it off
    /// screen.
    static let maximumDragOffsetMetres: Float = 4

    static func clampedDragOffset(_ offset: SIMD3<Float>) -> SIMD3<Float> {
        func bounded(_ value: Float) -> Float {
            guard value.isFinite else { return 0 }
            return min(max(value, -maximumDragOffsetMetres), maximumDragOffsetMetres)
        }
        return SIMD3(bounded(offset.x), bounded(offset.y), bounded(offset.z))
    }

    /// New module offset after the finger moves between two points on the table. Both points are
    /// found by unprojecting onto the table plane, so the module follows the finger at any angle.
    static func draggedOffset(
        from startOffset: SIMD3<Float>,
        startingAt startWorldPoint: SIMD3<Float>,
        following currentWorldPoint: SIMD3<Float>
    ) -> SIMD3<Float> {
        let delta = currentWorldPoint - startWorldPoint
        // Dragging never changes the height.
        return clampedDragOffset(
            SIMD3(startOffset.x + delta.x, 0, startOffset.z + delta.z)
        )
    }
}

// The finished packing placed on a real table at full size, so the operator can walk around it
// while loading. Tap a surface to place it, tap a package to see its name, and step through the
// layers.
//
// The container is an open-topped green wire shell. Layers below the current one are shown
// faded so the stack is visible without hiding where the next package goes.

struct PackingARView: View {
    let solution: BaldiSolution
    let colours: [UUID: Color]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.sharedARViewHost) private var sharedARViewHost
    @State private var model: PackingARModel

    init(solution: BaldiSolution, colours: [UUID: Color]) {
        self.solution = solution
        self.colours = colours
        _model = State(initialValue: PackingARModel(solution: solution, colours: colours))
    }

    var body: some View {
        ZStack {
            PackingARContainer(model: model, sharedViewHost: sharedARViewHost)
                .ignoresSafeArea()

            VStack {
                header
                if let warning = model.cameraWarning {
                    Text(warning)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                        .transition(.opacity)
                }
                Spacer()
                if model.isPlaced {
                    controls
                } else {
                    placementPrompt
                }
            }
            .padding(16)
        }
        .statusBarHidden()
        .animation(.easeInOut(duration: 0.2), value: model.cameraWarning)
        .animation(.easeInOut(duration: 0.2), value: model.isSurfaceReady)
    }

    private var header: some View {
        HStack(alignment: .top) {
            Button {
                dismiss()
            } label: {
                Label("Done", systemImage: "chevron.down")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .contentShape(Capsule())
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .accessibilityLabel("Close the three-dimensional view")

            Spacer(minLength: 8)

            if model.isPlaced {
                Button {
                    model.unplace()
                } label: {
                    Label("Place again", systemImage: "hand.tap")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Place the module somewhere else")
            }
        }
    }

    private var placementPrompt: some View {
        Label(
            model.statusText,
            systemImage: model.isSurfaceReady ? "hand.tap.fill" : "viewfinder"
        )
            .font(.callout.weight(.medium))
            .foregroundStyle(model.isSurfaceReady ? Color.green : Color.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 420)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .padding(.bottom, 28)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            selectedPackageLabel

            HStack(spacing: 10) {
                Button {
                    model.showPreviousLayer()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 52, height: 50)
                        .contentShape(Capsule())
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(!model.canShowPreviousLayer)
                .accessibilityLabel("Previous layer")

                VStack(spacing: 1) {
                    Text(model.layerTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(model.layerDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 132)
                .padding(.vertical, 6)

                Button {
                    model.showNextLayer()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 52, height: 50)
                        .contentShape(Capsule())
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .disabled(!model.canShowNextLayer)
                .accessibilityLabel("Next layer")
            }
            .padding(.horizontal, 8)
            .glassEffect(.regular, in: .capsule)

            Label("Use two fingers to rotate the module", systemImage: "rotate.3d")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)

            Text("Drag with one finger to slide it. Tap a package to read its name.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 24)
        .animation(.snappy(duration: 0.2), value: model.selectedPackageID)
        .animation(.snappy(duration: 0.2), value: model.visibleLayerIndex)
    }

    /// Name label for the tapped package, in its colour and with its guide number.
    @ViewBuilder
    private var selectedPackageLabel: some View {
        if let placement = model.selectedPlacement {
            let colour = model.selectedPackageColour
            VStack(spacing: 4) {
                HStack(spacing: 9) {
                    if let number = model.selectedPackageNumber {
                        Text("#\(number)")
                            .font(.title3.weight(.heavy).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .frame(minWidth: 42, minHeight: 34)
                            .background(colour, in: .rect(cornerRadius: 9))
                    }
                    Text(placement.name)
                        .font(.title.weight(.bold))
                        .foregroundStyle(colour)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                }
                Text(BaldiOpeningMarker.description(for: placement))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 420)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - State

@MainActor
@Observable
final class PackingARModel {
    let solution: BaldiSolution
    let colours: [UUID: Color]
    let layers: [BaldiLoadingLayer]
    /// Same numbering as the loading guide.
    let numbering: [UUID: Int]

    private(set) var isPlaced = false
    private(set) var visibleLayerIndex = 0
    private(set) var selectedPackageID: UUID?
    private(set) var statusText = PackingARModel.searchingText
    private(set) var cameraWarning: String?
    /// Incremented when the AR side needs to rebuild its content.
    private(set) var revision = 0
    /// Incremented when the operator wants to place the module again.
    private(set) var unplaceRevision = 0

    init(solution: BaldiSolution, colours: [UUID: Color]) {
        self.solution = solution
        self.colours = colours
        self.layers = BaldiLoadingGuide.layers(for: solution)
        self.numbering = BaldiLoadingGuide.numbering(for: solution)
    }

    var canShowPreviousLayer: Bool { visibleLayerIndex > 0 }
    var canShowNextLayer: Bool { visibleLayerIndex + 1 < layers.count }

    var selectedPlacement: BaldiPlacement? {
        guard let selectedPackageID else { return nil }
        return solution.placements.first { $0.id == selectedPackageID }
    }

    var selectedPackageNumber: Int? {
        selectedPackageID.flatMap { numbering[$0] }
    }

    var selectedPackageColour: Color {
        selectedPackageID.flatMap { colours[$0] } ?? .accentColor
    }

    var layerTitle: String {
        layers.isEmpty
            ? "No layers"
            : "Layer \(visibleLayerIndex + 1) of \(layers.count)"
    }

    var layerDetail: String {
        guard layers.indices.contains(visibleLayerIndex) else { return "" }
        let count = layers[visibleLayerIndex].placements.count
        return "\(count) package\(count == 1 ? "" : "s")"
    }

    func showNextLayer() {
        guard canShowNextLayer else { return }
        visibleLayerIndex += 1
        selectedPackageID = nil
        revision &+= 1
    }

    func showPreviousLayer() {
        guard canShowPreviousLayer else { return }
        visibleLayerIndex -= 1
        selectedPackageID = nil
        revision &+= 1
    }

    func markPlaced() {
        guard !isPlaced else { return }
        isPlaced = true
        statusText = ""
    }

    /// Set by the AR coordinator so "Place again" removes the module immediately instead of waiting
    /// for a SwiftUI update.
    @ObservationIgnored var unplaceHandler: (() -> Void)?

    func unplace() {
        isPlaced = false
        selectedPackageID = nil
        isSurfaceReady = false
        statusText = Self.searchingText
        unplaceRevision &+= 1
        unplaceHandler?()
    }

    static let searchingText = "Point the middle of the screen at the table or floor and move the phone slowly until the surface is found."

    /// Whether a surface is under the screen centre right now.
    private(set) var isSurfaceReady = false

    func reportSurface(found: Bool) {
        guard !isPlaced else { return }
        isSurfaceReady = found
        statusText = found
            ? "Ready. Tap to put the module down."
            : Self.searchingText
    }

    func reportNoSurface() {
        reportSurface(found: false)
    }

    func reportCameraRestarting() {
        cameraWarning = "Getting the camera back…"
    }

    func reportCameraStalled() {
        cameraWarning = "The camera has stopped. Close this view and open it again."
    }

    func clearCameraWarning() {
        guard cameraWarning != nil else { return }
        cameraWarning = nil
    }

    func select(packageID: UUID?) {
        guard let packageID,
              solution.placements.contains(where: { $0.id == packageID }) else {
            selectedPackageID = nil
            return
        }
        // Tapping the same package again hides the label.
        selectedPackageID = selectedPackageID == packageID ? nil : packageID
    }
}

// MARK: - AR

private struct PackingARContainer: UIViewRepresentable {
    let model: PackingARModel
    let sharedViewHost: SharedARViewHost?

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, sharedViewHost: sharedViewHost)
    }

    func makeUIView(context: Context) -> UIView {
        // SwiftUI owns this wrapper; SharedARViewHost mounts the shared ARView inside it.
        let container = UIView(frame: .zero)
        container.backgroundColor = .black
        container.isOpaque = true
        let view = context.coordinator.acquireView(mountingIn: container)
        // Turn off mesh debug drawing and occlusion that measurement may have left enabled.
        view.debugOptions.remove(.showSceneUnderstanding)
        view.environment.sceneUnderstanding.options.remove(.occlusion)
        view.session.delegate = context.coordinator
        context.coordinator.attach(to: view)
        let hasExistingWorld = view.session.configuration is ARWorldTrackingConfiguration
        view.session.run(
            Coordinator.makeConfiguration(),
            options: hasExistingWorld
                ? []
                : [.resetTracking, .removeExistingAnchors]
        )
        context.coordinator.activateCameraFeedWhenReady()
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Deferred until after SwiftUI's update and coalesced.
        context.coordinator.scheduleSync(with: model)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate, UIGestureRecognizerDelegate {
        /// Updated from updateUIView as a safeguard so the coordinator never drives an old model.
        private var model: PackingARModel
        private let sharedViewHost: SharedARViewHost?
        private var sharedViewLease: SharedARRendererOwnership.Lease?
        private weak var view: ARView?
        private var installedGestureRecognizers: [UIGestureRecognizer] = []
        private var syncTask: Task<Void, Never>?
        private var requestedSyncRevision = 0
        private var anchor: AnchorEntity?
        /// Child of the anchor holding all content, so it can be rotated without moving the anchor.
        private var contentRoot: Entity?
        private var packageEntities: [UUID: ModelEntity] = [:]
        /// Faces are inset from the collision volume and the outline so touching packages don't share
        /// transparent faces.
        private enum PackageVisualRole {
            case face
            case outline
            case lengthMarker
        }
        private var visualsByPackage: [UUID: [(entity: ModelEntity, role: PackageVisualRole)]] = [:]
        private var observedRevision = -1
        private var observedUnplaceRevision = 0
        private var searchTimer: Timer?
        private var watchdogTimer: Timer?
        private var lastFrameTime: TimeInterval = 0
        private var lastFrameTimestamp: TimeInterval = 0
        private var turn: Float = 0
        /// Content offset and table point at the start of a one-finger drag.
        private var dragStartContentOffset: SIMD3<Float>?
        private var dragStartSurfacePoint: SIMD3<Float>?
        private var turnAtGestureStart: Float = 0
        private var twoFingerTurnAtStart: Float = 0
        private var twistIsActive = false
        private var suppressTwoFingerPanUntilEnd = false
        /// Height of the surface last found under the screen centre. Placement prefers it.
        private var probedSurfaceHeight: Float?
        /// ARKit anchor for the module, which keeps it on the surface across tracking corrections.
        private var placedWorldAnchor: ARAnchor?

        /// Packing sizes are in millimetres.
        private let scale: Float = 0.001

        init(model: PackingARModel, sharedViewHost: SharedARViewHost?) {
            self.model = model
            self.sharedViewHost = sharedViewHost
        }

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
                .packing,
                mountingIn: container
            ) { [weak self] in
                self?.detach()
            }
            sharedViewLease = lease
            return sharedViewHost.view
        }

        func activateCameraFeedWhenReady() {
            guard let sharedViewHost, let sharedViewLease else { return }
            sharedViewHost.activateCameraFeed(for: sharedViewLease)
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

        private func updateModel(_ newModel: PackingARModel) {
            guard model !== newModel else { return }
            clearPlacement()
            model.unplaceHandler = nil
            model = newModel
            observedRevision = -1
            observedUnplaceRevision = newModel.unplaceRevision
            adoptUnplaceHandler()
        }

        private func adoptUnplaceHandler() {
            model.unplaceHandler = { [weak self] in
                guard let self, self.ownsSharedView else { return }
                self.observedUnplaceRevision = self.model.unplaceRevision
                self.clearPlacement()
            }
        }

        static func makeConfiguration() -> ARWorldTrackingConfiguration {
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.planeDetection = [.horizontal]
            configuration.environmentTexturing = .none
            // With scene depth, planes are found almost immediately, even on bare tables.
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }
            return configuration
        }

        func attach(to view: ARView) {
            self.view = view
            adoptUnplaceHandler()
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            view.addGestureRecognizer(tap)

            // One finger drags the module on the surface; a two-finger twist rotates it.
            let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
            drag.minimumNumberOfTouches = 1
            drag.maximumNumberOfTouches = 1
            drag.delegate = self
            view.addGestureRecognizer(drag)
            let twist = UIRotationGestureRecognizer(target: self, action: #selector(handleTwist))
            twist.delegate = self
            view.addGestureRecognizer(twist)
            // Also treat two fingers moving sideways together as rotation, since that often isn't enough
            // to trigger UIRotationGestureRecognizer.
            let twoFingerTurn = UIPanGestureRecognizer(
                target: self,
                action: #selector(handleTwoFingerTurn)
            )
            twoFingerTurn.minimumNumberOfTouches = 2
            twoFingerTurn.maximumNumberOfTouches = 2
            twoFingerTurn.delegate = self
            view.addGestureRecognizer(twoFingerTurn)
            tap.require(toFail: drag)
            tap.require(toFail: twist)
            tap.require(toFail: twoFingerTurn)
            installedGestureRecognizers = [tap, drag, twist, twoFingerTurn]

            startSurfaceProbe()
            lastFrameTime = CACurrentMediaTime()
            watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkForStalledCamera() }
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Let rotation take over if the one-finger pan already started when the second finger lands.
            let pair = [gestureRecognizer, otherGestureRecognizer]
            return pair.contains { $0 is UIRotationGestureRecognizer }
                && pair.contains { $0 is UIPanGestureRecognizer }
        }

        /// Only uses planes ARKit has actually detected; estimated planes could be the floor behind the
        /// table. Results are nearest first, so the first hit is the surface under the finger.
        private func stableSurfaceHit(
            at point: CGPoint,
            in view: ARView,
            matchingHeight expectedHeight: Float? = nil
        ) -> ARRaycastResult? {
            for target in [ARRaycastQuery.Target.existingPlaneGeometry, .existingPlaneInfinite] {
                if let hit = view.raycast(
                    from: point,
                    allowing: target,
                    alignment: .horizontal
                ).first(where: { result in
                    let height = result.worldTransform.columns.3.y
                    guard height.isFinite else { return false }
                    guard let expectedHeight else { return true }
                    return abs(height - expectedHeight) <= 0.025
                }) {
                    return hit
                }
            }
            return nil
        }

        /// Raycasts from the screen centre three times a second so the prompt can say when a surface is
        /// ready. Runs for the coordinator's whole lifetime so "Place again" works.
        private func startSurfaceProbe() {
            searchTimer?.invalidate()
            searchTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.probeForSurface() }
            }
        }

        private func stopSurfaceProbe() {
            searchTimer?.invalidate()
            searchTimer = nil
        }

        private func probeForSurface() {
            guard ownsSharedView, let view, !model.isPlaced else { return }
            let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let hit = stableSurfaceHit(at: centre, in: view)
            probedSurfaceHeight = hit?.worldTransform.columns.3.y
            model.reportSurface(found: hit != nil)
        }

        func detach() {
            syncTask?.cancel()
            syncTask = nil
            requestedSyncRevision &+= 1
            searchTimer?.invalidate()
            searchTimer = nil
            watchdogTimer?.invalidate()
            watchdogTimer = nil
            guard let view else {
                sharedViewLease = nil
                model.unplaceHandler = nil
                return
            }
            for recognizer in installedGestureRecognizers {
                view.removeGestureRecognizer(recognizer)
            }
            installedGestureRecognizers.removeAll()
            clearPlacement()
            if let sharedViewHost, let sharedViewLease {
                // A late dismantle must not clear the delegate once measurement owns the ARView again.
                if sharedViewHost.owns(sharedViewLease) {
                    view.session.delegate = nil
                    sharedViewHost.release(sharedViewLease)
                }
            } else {
                view.session.delegate = nil
                view.session.pause()
                view.removeFromSuperview()
            }
            self.view = nil
            sharedViewLease = nil
            model.unplaceHandler = nil
            // Last, since clearing the placement restarts the probe.
            stopSurfaceProbe()
        }

        // MARK: - Keeping the camera alive

        /// Also catches model changes that didn't go through `unplaceHandler`.
        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            Task { @MainActor [weak self] in
                self?.sync()
            }
        }

        nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
            Task { @MainActor [weak self] in
                guard let self, self.ownsSharedView else { return }
                self.restartSession(resettingTracking: true)
            }
        }

        nonisolated func sessionWasInterrupted(_ session: ARSession) {
            Task { @MainActor [weak self] in
                guard let self, self.ownsSharedView else { return }
                self.model.reportCameraRestarting()
            }
        }

        nonisolated func sessionInterruptionEnded(_ session: ARSession) {
            Task { @MainActor [weak self] in
                guard let self, self.ownsSharedView else { return }
                self.restartSession(resettingTracking: false)
            }
        }

        /// Only reports a stalled camera. Re-running the session here caused flicker, and interruptions
        /// are already handled through the delegate.
        private func checkForStalledCamera() {
            guard ownsSharedView, let view else { return }
            guard let timestamp = view.session.currentFrame?.timestamp else { return }
            let now = CACurrentMediaTime()

            if timestamp != lastFrameTimestamp {
                lastFrameTimestamp = timestamp
                lastFrameTime = now
                model.clearCameraWarning()
                return
            }
            if now - lastFrameTime > 3 {
                model.reportCameraStalled()
            }
        }

        private func restartSession(resettingTracking: Bool) {
            guard ownsSharedView, let view else { return }
            if resettingTracking {
                clearPlacement()
                model.unplace()
            }
            view.session.run(
                Self.makeConfiguration(),
                options: resettingTracking ? [.resetTracking, .removeExistingAnchors] : []
            )
            lastFrameTime = CACurrentMediaTime()
            lastFrameTimestamp = 0
        }

        // MARK: - Turning the module

        /// One finger moves the module across the surface. The content is offset inside the anchor; the
        /// anchor itself is left to ARKit, which keeps correcting it.
        @objc private func handleDrag(_ recogniser: UIPanGestureRecognizer) {
            guard ownsSharedView, let view, anchor != nil, let contentRoot else { return }
            switch recogniser.state {
            case .began:
                guard recogniser.numberOfTouches == 1, !twistIsActive else { return }
                dragStartContentOffset = contentRoot.position
                dragStartSurfacePoint = surfacePoint(
                    at: recogniser.location(in: view),
                    in: view
                )
            case .changed:
                guard recogniser.numberOfTouches == 1,
                      !twistIsActive,
                      let start = dragStartContentOffset,
                      let startSurfacePoint = dragStartSurfacePoint,
                      let currentSurfacePoint = surfacePoint(
                          at: recogniser.location(in: view),
                          in: view
                      ) else {
                    return
                }
                // The anchor has no rotation, so world-space movement applies directly to the child offset.
                contentRoot.position = PackingARVisualGeometry.draggedOffset(
                    from: start,
                    startingAt: startSurfacePoint,
                    following: currentSurfacePoint
                )
            case .ended, .cancelled, .failed:
                dragStartContentOffset = nil
                dragStartSurfacePoint = nil
            default:
                break
            }
        }

        /// Where a screen point meets the table plane. Works past the edge of the mapped plane.
        private func surfacePoint(at point: CGPoint, in view: ARView) -> SIMD3<Float>? {
            guard let frame = view.session.currentFrame,
                  view.bounds.width > 0,
                  view.bounds.height > 0 else {
                return nil
            }
            // Use the ARKit anchor's transform; the entity may not have caught up yet.
            guard let surfaceHeight = placedWorldAnchor?.transform.columns.3.y
                ?? anchor?.transform.translation.y else {
                return nil
            }
            var plane = matrix_identity_float4x4
            plane.columns.3 = SIMD4<Float>(0, surfaceHeight, 0, 1)
            return frame.camera.unprojectPoint(
                point,
                ontoPlane: plane,
                orientation: interfaceOrientation(in: view),
                viewportSize: view.bounds.size
            )
        }

        private func interfaceOrientation(in view: ARView) -> UIInterfaceOrientation {
            view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
        }

        @objc private func handleTwist(_ recogniser: UIRotationGestureRecognizer) {
            guard ownsSharedView, contentRoot != nil else { return }
            switch recogniser.state {
            case .began:
                twistIsActive = true
                suppressTwoFingerPanUntilEnd = true
                dragStartContentOffset = nil
                turnAtGestureStart = turn
            case .changed, .ended:
                apply(
                    turn: turnAtGestureStart - Float(recogniser.rotation),
                    settling: recogniser.state == .ended
                )
                if recogniser.state == .ended {
                    twistIsActive = false
                }
            case .cancelled, .failed:
                twistIsActive = false
            default:
                break
            }
        }

        /// Two-finger pan as rotation, at 8 milliradians per point.
        @objc private func handleTwoFingerTurn(_ recogniser: UIPanGestureRecognizer) {
            guard ownsSharedView, contentRoot != nil else { return }
            switch recogniser.state {
            case .began:
                // A twist can end without the pan reaching .ended, so clear its suppression here.
                if !twistIsActive {
                    suppressTwoFingerPanUntilEnd = false
                }
                twoFingerTurnAtStart = turn
            case .changed, .ended:
                guard !twistIsActive, !suppressTwoFingerPanUntilEnd else {
                    if recogniser.state == .ended {
                        suppressTwoFingerPanUntilEnd = false
                    }
                    return
                }
                let horizontal = Float(recogniser.translation(in: view).x)
                apply(
                    turn: twoFingerTurnAtStart - horizontal * 0.008,
                    settling: recogniser.state == .ended
                )
            case .cancelled, .failed:
                suppressTwoFingerPanUntilEnd = false
            default:
                break
            }
        }

        /// Snaps to the nearest right angle when close.
        private func apply(turn newTurn: Float, settling: Bool) {
            var value = newTurn
            if settling {
                let quarter = Float.pi / 2
                let nearest = (value / quarter).rounded() * quarter
                if abs(value - nearest) < 0.09 {
                    value = nearest
                }
            }
            turn = value
            contentRoot?.orientation = simd_quatf(angle: value, axis: SIMD3(0, 1, 0))
        }

        func scheduleSync(with newModel: PackingARModel) {
            requestedSyncRevision &+= 1
            let revision = requestedSyncRevision
            syncTask?.cancel()
            syncTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled,
                      let self,
                      self.requestedSyncRevision == revision,
                      self.ownsSharedView else {
                    return
                }
                self.updateModel(newModel)
                self.sync()
            }
        }

        private func sync() {
            guard ownsSharedView else { return }
            if model.unplaceRevision != observedUnplaceRevision {
                observedUnplaceRevision = model.unplaceRevision
                clearPlacement()
                return
            }
            guard anchor != nil, model.revision != observedRevision else { return }
            observedRevision = model.revision
            refreshLayerVisibility()
        }

        private var ownsSharedView: Bool {
            guard let sharedViewHost else { return true }
            guard let sharedViewLease else { return false }
            return sharedViewHost.owns(sharedViewLease)
        }

        /// Removes both the entity and the ARKit anchor. Leaving the anchor let RealityKit draw the old
        /// content again.
        private func clearPlacement() {
            if let anchor {
                view?.scene.removeAnchor(anchor)
                anchor.children.removeAll()
                anchor.removeFromParent()
            }
            if let placedWorldAnchor {
                view?.session.remove(anchor: placedWorldAnchor)
            }
            placedWorldAnchor = nil
            anchor = nil
            contentRoot = nil
            packageEntities.removeAll()
            visualsByPackage.removeAll()
            observedRevision = -1
            turn = 0
            twistIsActive = false
            suppressTwoFingerPanUntilEnd = false
            probedSurfaceHeight = nil
            dragStartContentOffset = nil
            startSurfaceProbe()
        }

        @objc private func handleTap(_ recogniser: UITapGestureRecognizer) {
            guard ownsSharedView, let view else { return }
            let point = recogniser.location(in: view)

            if anchor == nil {
                place(at: point, in: view)
                return
            }
            // Hit-test the packages to show a name.
            guard let hit = view.entity(at: point) as? ModelEntity,
                  let match = packageEntities.first(where: { $0.value === hit }) else {
                model.select(packageID: nil)
                return
            }
            model.select(packageID: match.key)
        }

        private func place(at point: CGPoint, in view: ARView) {
            // Prefer the probed surface, otherwise use whatever was tapped.
            let result = probedSurfaceHeight.flatMap {
                stableSurfaceHit(at: point, in: view, matchingHeight: $0)
            } ?? stableSurfaceHit(at: point, in: view)
            guard let result else {
                model.reportNoSurface()
                return
            }

            // Translation only: the module should be level, and its yaw comes from the rotate gesture.
            var stableTransform = matrix_identity_float4x4
            stableTransform.columns.3 = result.worldTransform.columns.3
            // A session anchor, so ARKit keeps it on the surface as tracking improves.
            let worldAnchor = ARAnchor(name: Self.moduleAnchorName, transform: stableTransform)
            view.session.add(anchor: worldAnchor)
            let placed = AnchorEntity(anchor: worldAnchor)
            let content = Entity()
            placed.addChild(content)
            view.scene.addAnchor(placed)
            placedWorldAnchor = worldAnchor
            anchor = placed
            contentRoot = content
            turn = 0
            build(into: content)
            observedRevision = model.revision
            refreshLayerVisibility()
            model.markPlaced()
        }

        private static let moduleAnchorName = "packing-module"

        // MARK: - Content

        private func build(into anchor: Entity) {
            let size = SIMD3<Float>(
                Float(model.solution.knapsack.size.x),
                Float(model.solution.knapsack.size.y),
                Float(model.solution.knapsack.size.z)
            ) * scale
            addOpenTopShell(size: size, to: anchor)

            for placement in model.solution.placements {
                let extent = SIMD3<Float>(
                    Float(placement.size.x),
                    Float(placement.size.y),
                    Float(placement.size.z)
                ) * scale
                let centre = SIMD3<Float>(
                    Float(placement.centreOfMass.x),
                    Float(placement.centreOfMass.z),
                    Float(placement.centreOfMass.y)
                ) * scale
                let colour = UIColor(colours(for: placement.id))
                let boxSize = SIMD3(extent.x, extent.z, extent.y)

                // This entity is the full-size hit volume; the visible geometry sits just inside it.
                let box = ModelEntity(
                    mesh: .generateBox(size: boxSize),
                    materials: [Self.unlitMaterial(colour)]
                )
                box.generateCollisionShapes(recursive: false)
                box.model = nil
                // Explicit collision shape, so the visual bars don't need their own.
                box.components.set(
                    CollisionComponent(shapes: [.generateBox(size: boxSize)])
                )
                // Packing is z-up, RealityKit is y-up, and the shell is centred on the anchor.
                box.position = SIMD3(
                    centre.x - size.x / 2,
                    centre.y,
                    centre.z - size.y / 2
                )
                anchor.addChild(box)
                packageEntities[placement.id] = box
                addPackageFaces(size: boxSize, colour: colour, on: box, id: placement.id)
                addPackageOutline(size: boxSize, colour: colour, on: box, id: placement.id)
                addFaceMarkings(for: placement, on: box, extent: extent, colour: colour, id: placement.id)
            }
        }

        /// Six separate translucent panels. A closed transparent cuboid looked solid.
        private func addPackageFaces(
            size: SIMD3<Float>,
            colour: UIColor,
            on box: ModelEntity,
            id: UUID
        ) {
            let thickness = Self.outlineThickness(for: size)
            let inset = PackingARVisualGeometry.faceInset(for: thickness)
            let inner = PackingARVisualGeometry.insetFrameSize(size, by: inset)
            let panelThickness: Float = 0.0002

            func addPanel(size panelSize: SIMD3<Float>, position: SIMD3<Float>) {
                let panel = ModelEntity(
                    mesh: .generateBox(size: panelSize),
                    materials: [Self.unlitMaterial(colour)]
                )
                panel.position = position
                panel.components.set(OpacityComponent(opacity: 0.10))
                box.addChild(panel)
                visualsByPackage[id, default: []].append((panel, .face))
            }

            for sign in [Float(-1), Float(1)] {
                addPanel(
                    size: SIMD3(panelThickness, inner.y, inner.z),
                    position: SIMD3(sign * inner.x / 2, 0, 0)
                )
                addPanel(
                    size: SIMD3(inner.x, panelThickness, inner.z),
                    position: SIMD3(0, sign * inner.y / 2, 0)
                )
                addPanel(
                    size: SIMD3(inner.x, inner.y, panelThickness),
                    position: SIMD3(0, 0, sign * inner.z / 2)
                )
            }
        }

        /// Twelve solid edge bars.
        private func addPackageOutline(
            size: SIMD3<Float>,
            colour: UIColor,
            on box: ModelEntity,
            id: UUID
        ) {
            let thickness = Self.outlineThickness(for: size)
            let inset = PackingARVisualGeometry.packageInset(for: thickness)
            let visibleSize = PackingARVisualGeometry.insetFrameSize(size, by: inset)
            addBoxFrame(size: visibleSize, thickness: thickness, colour: colour, to: box) { entity in
                self.visualsByPackage[id, default: []].append((entity, .outline))
            }
        }

        /// Draws a line along the package's length on both L x W faces, matching the box opening.
        /// `rotation.sourceAxis[c]` is the box axis (0 length, 1 width, 2 height) on container axis `c`,
        /// so the marked faces are perpendicular to whichever container axis carries axis 2.
        private func addFaceMarkings(
            for placement: BaldiPlacement,
            on box: ModelEntity,
            extent: SIMD3<Float>,
            colour: UIColor,
            id: UUID
        ) {
            // Objects that are their own box have no defined opening.
            guard !placement.isOwnBox,
                  let axes = BaldiOpeningMarker.faceAxes(for: placement) else { return }
            let normal = axes.normal
            let length = axes.length
            let width = axes.width
            guard extent[normal] > 0,
                  extent[length] > 0,
                  extent[width] > 0 else {
                return
            }

            let markerDepth = max(0.0012, min(0.003, extent[normal] * 0.025))
            let markerWidth = max(0.0018, min(0.005, extent[width] * 0.055))
            let lineColour = darkened(colour, by: 0.72)
            let boxSize = SIMD3(extent.x, extent.z, extent.y)
            let outlineThickness = Self.outlineThickness(for: boxSize)
            let inset = PackingARVisualGeometry.packageInset(
                for: outlineThickness
            )
            let coveredFaces = BaldiOpeningMarker.coveredFaceSigns(
                for: placement,
                among: model.solution.placements
            )

            /// Packing is z-up, RealityKit is y-up.
            func realityKit(_ values: [Float]) -> SIMD3<Float> {
                SIMD3(values[0], values[2], values[1])
            }

            for face in [Float(1), Float(-1)] {
                var lineSize = [Float](repeating: 0, count: 3)
                lineSize[normal] = markerDepth
                lineSize[width] = markerWidth

                var lineAt = [Float](repeating: 0, count: 3)
                // Keep the marker inside this package's face so it can't poke into a neighbour.
                lineAt[normal] = PackingARVisualGeometry.markerCentre(
                    face: face,
                    normalExtent: extent[normal],
                    markerDepth: markerDepth,
                    inset: inset
                )

                let fullLength = extent[length] * 0.78
                if coveredFaces.contains(face < 0 ? -1 : 1) {
                    let dashCount = 5
                    let dashLength = fullLength / Float(dashCount * 2 - 1)
                    for dash in 0..<dashCount {
                        lineSize[length] = dashLength
                        lineAt[length] = -fullLength / 2
                            + dashLength / 2
                            + Float(dash * 2) * dashLength
                        addPackageVisual(
                            size: realityKit(lineSize),
                            at: realityKit(lineAt),
                            colour: lineColour,
                            on: box,
                            id: id,
                            role: .lengthMarker
                        )
                    }
                } else {
                    lineSize[length] = fullLength
                    addPackageVisual(
                        size: realityKit(lineSize),
                        at: realityKit(lineAt),
                        colour: lineColour,
                        on: box,
                        id: id,
                        role: .lengthMarker
                    )
                }
            }
        }

        private func addPackageVisual(
            size: SIMD3<Float>,
            at position: SIMD3<Float>,
            colour: UIColor,
            on box: ModelEntity,
            id: UUID,
            role: PackageVisualRole
        ) {
            let entity = ModelEntity(
                mesh: .generateBox(size: size),
                materials: [Self.unlitMaterial(colour)]
            )
            entity.position = position
            box.addChild(entity)
            visualsByPackage[id, default: []].append((entity, role))
        }

        private func darkened(_ colour: UIColor, by amount: CGFloat) -> UIColor {
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            guard colour.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
                return colour
            }
            return UIColor(
                hue: hue,
                saturation: min(1, saturation + amount * 0.25),
                brightness: max(0.06, brightness * (1 - amount)),
                alpha: alpha
            )
        }

        /// Muted edge colour for finished layers. Their fill opacity is set in `refreshLayerVisibility`.
        private func mutedOpaque(_ colour: UIColor) -> UIColor {
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            var alpha: CGFloat = 0
            guard colour.getHue(
                &hue,
                saturation: &saturation,
                brightness: &brightness,
                alpha: &alpha
            ) else {
                return colour.withAlphaComponent(1)
            }
            return UIColor(
                hue: hue,
                saturation: saturation * 0.48,
                brightness: max(0.42, brightness * 0.72),
                alpha: 1
            )
        }

        private static func unlitMaterial(_ colour: UIColor) -> UnlitMaterial {
            UnlitMaterial(
                color: colour.withAlphaComponent(1),
                applyPostProcessToneMap: false
            )
        }

        private static func outlineThickness(for size: SIMD3<Float>) -> Float {
            max(0.0015, min(0.004, min(size.x, min(size.y, size.z)) * 0.035))
        }

        /// The twelve edges of a cuboid, inset by half their thickness so they meet cleanly at corners.
        private func addBoxFrame(
            size: SIMD3<Float>,
            thickness: Float,
            colour: UIColor,
            to parent: Entity,
            didAdd: ((ModelEntity) -> Void)? = nil
        ) {
            let axes = [0, 1, 2]
            let material = Self.unlitMaterial(colour)

            for lengthAxis in axes {
                let sideAxes = axes.filter { $0 != lengthAxis }
                for firstSide in [Float(-1), Float(1)] {
                    for secondSide in [Float(-1), Float(1)] {
                        var edgeSize = SIMD3<Float>(repeating: thickness)
                        edgeSize[lengthAxis] = max(
                            thickness,
                            size[lengthAxis] - thickness
                        )

                        var position = SIMD3<Float>.zero
                        position[sideAxes[0]] = firstSide
                            * max(0, size[sideAxes[0]] - thickness) / 2
                        position[sideAxes[1]] = secondSide
                            * max(0, size[sideAxes[1]] - thickness) / 2

                        let edge = ModelEntity(
                            mesh: .generateBox(size: edgeSize),
                            materials: [material]
                        )
                        edge.position = position
                        parent.addChild(edge)
                        didAdd?(edge)
                    }
                }
            }
        }

        /// Wire shell showing the module bounds. The top is open so the operator can see and reach in.
        private func addOpenTopShell(size: SIMD3<Float>, to anchor: Entity) {
            let shellSize = SIMD3(size.x, size.z, size.y)
            let thickness = max(0.0018, min(0.004, min(size.x, size.y) * 0.008))
            let shell = Entity()
            shell.position = SIMD3(0, size.z / 2, 0)
            anchor.addChild(shell)
            addBoxFrame(
                // Slightly outside the usable volume so packages at 0 touch its inner edge.
                size: shellSize + SIMD3<Float>(repeating: thickness * 2),
                thickness: thickness,
                colour: .systemGreen,
                to: shell
            )
        }

        /// Current layer in full colour, finished layers muted, future layers hidden.
        private func refreshLayerVisibility() {
            for (index, layer) in model.layers.enumerated() {
                let isVisible = index <= model.visibleLayerIndex
                let isCurrent = index == model.visibleLayerIndex
                for placement in layer.placements {
                    guard let entity = packageEntities[placement.id] else { continue }
                    entity.isEnabled = isVisible
                    guard isVisible else { continue }

                    let packageColour = UIColor(colours(for: placement.id))
                    let outlineColour = isCurrent
                        ? packageColour
                        : mutedOpaque(packageColour)
                    for visual in visualsByPackage[placement.id] ?? [] {
                        let visualColour: UIColor
                        switch visual.role {
                        case .face:
                            visual.entity.model?.materials = [Self.unlitMaterial(outlineColour)]
                            visual.entity.components.set(
                                OpacityComponent(opacity: isCurrent ? 0.10 : 0.04)
                            )
                            continue
                        case .outline:
                            visualColour = outlineColour
                        case .lengthMarker:
                            visualColour = darkened(outlineColour, by: isCurrent ? 0.72 : 0.5)
                        }
                        visual.entity.model?.materials = [Self.unlitMaterial(visualColour)]
                    }
                }
            }
        }

        private func colours(for id: UUID) -> Color {
            model.colours[id] ?? .accentColor
        }
    }
}
