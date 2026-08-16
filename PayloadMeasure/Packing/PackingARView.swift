import ARKit
import RealityKit
import SwiftUI
import simd

/// Small, renderer-independent spacing rules for the room-scale guide. Collision and placement keep
/// the exact package dimensions; only the visible bars move inward far enough that touching packages
/// never ask the depth buffer to draw two differently coloured surfaces at the same position.
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

    /// Keeps a translucent face behind the edge bars and away from a neighbouring package's face.
    static func fillInset(for outlineThickness: Float) -> Float {
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
}

// The finished packing, placed on a real table at full size so the operator can walk around it while
// loading.
//
// In:  a verified BaldiSolution and the colours the rest of the screens use for each package.
// Out: on screen only. Tap a surface to put the plan there, tap a package to read its name, step
//      through the layers one at a time.
//
// The container is drawn as a thin open-topped green shell so you can see and reach into it. Layers
// below the one being loaded stay visible but faint, so the stack reads as a stack without hiding
// where the next package goes.

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
            if let name = model.selectedPackageName {
                Text(name)
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
                    .transition(.opacity)
            }

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
        .animation(.snappy(duration: 0.2), value: model.selectedPackageName)
        .animation(.snappy(duration: 0.2), value: model.visibleLayerIndex)
    }
}

// MARK: - State

@MainActor
@Observable
final class PackingARModel {
    let solution: BaldiSolution
    let colours: [UUID: Color]
    let layers: [BaldiLoadingLayer]

    private(set) var isPlaced = false
    private(set) var visibleLayerIndex = 0
    private(set) var selectedPackageName: String?
    private(set) var statusText = PackingARModel.searchingText
    /// Set while the camera is being taken back from whatever else grabbed it.
    private(set) var cameraWarning: String?
    /// Bumped whenever the AR side must rebuild what it is showing.
    private(set) var revision = 0
    /// Bumped when the operator wants to place the module again.
    private(set) var unplaceRevision = 0

    init(solution: BaldiSolution, colours: [UUID: Color]) {
        self.solution = solution
        self.colours = colours
        self.layers = BaldiLoadingGuide.layers(for: solution)
    }

    var canShowPreviousLayer: Bool { visibleLayerIndex > 0 }
    var canShowNextLayer: Bool { visibleLayerIndex + 1 < layers.count }

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
        selectedPackageName = nil
        revision &+= 1
    }

    func showPreviousLayer() {
        guard canShowPreviousLayer else { return }
        visibleLayerIndex -= 1
        selectedPackageName = nil
        revision &+= 1
    }

    func markPlaced() {
        guard !isPlaced else { return }
        isPlaced = true
        statusText = ""
    }

    func unplace() {
        isPlaced = false
        selectedPackageName = nil
        isSurfaceReady = false
        statusText = Self.searchingText
        unplaceRevision &+= 1
    }

    static let searchingText = "Move the phone slowly across the table until a surface is found."

    /// Whether a surface is under the middle of the screen right now, so the prompt can say when it is
    /// worth tapping instead of leaving the operator to guess.
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

    /// Frames have stopped arriving and nothing is being done automatically, so this says what to do.
    func reportCameraStalled() {
        cameraWarning = "The camera has stopped. Close this view and open it again."
    }

    func clearCameraWarning() {
        guard cameraWarning != nil else { return }
        cameraWarning = nil
    }

    func select(packageID: UUID?) {
        guard let packageID,
              let placement = solution.placements.first(where: { $0.id == packageID }) else {
            selectedPackageName = nil
            return
        }
        selectedPackageName = placement.name
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
        // SwiftUI owns a presentation-local wrapper. The single camera-backed ARView is mounted as
        // its child by SharedARViewHost, avoiding ambiguous UIKit ownership when covers transition.
        let container = UIView(frame: .zero)
        container.backgroundColor = .black
        container.isOpaque = true
        let view = context.coordinator.acquireView(mountingIn: container)
        // Measurement may have left mesh debug drawing or occlusion enabled on this persistent
        // renderer. Neither belongs in the loading guide; retaining them adds dark/flickering
        // geometry and unnecessary GPU work behind the package outlines.
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
        // Defer synchronization until after SwiftUI's representable update transaction and coalesce
        // repeated updates.
        context.coordinator.scheduleSync(with: model)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        /// Normally immutable for one presentation. It is still updated from `updateUIView` so a
        /// coordinator can never keep driving an old model if SwiftUI reconciles more aggressively
        /// than expected. The presentation ID above should make this a defensive path only.
        private var model: PackingARModel
        private let sharedViewHost: SharedARViewHost?
        private var sharedViewLease: SharedARRendererOwnership.Lease?
        private weak var view: ARView?
        private var installedGestureRecognizers: [UIGestureRecognizer] = []
        private var syncTask: Task<Void, Never>?
        private var requestedSyncRevision = 0
        private var anchor: AnchorEntity?
        /// Child of the anchor. Everything is built into this so it can be turned without disturbing
        /// the anchor's alignment with the real surface.
        private var contentRoot: Entity?
        private var packageEntities: [UUID: ModelEntity] = [:]
        /// The fill is inset from both the exact collision volume and the opaque outline. This keeps
        /// touching packages from sharing transparent faces while still giving each target a clear,
        /// lightly coloured volume.
        private enum PackageVisualRole {
            case fill
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
        /// Suppresses the tap that ends a drag, so sliding the module does not also select a package.
        private var isDragging = false
        /// Where the module sat relative to the first raycast hit of the current drag.
        private var dragOffset: SIMD2<Float>?
        private var turnAtGestureStart: Float = 0

        /// Millimetres to metres. Everything in the packing is in millimetres.
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
            model = newModel
            observedRevision = -1
            observedUnplaceRevision = newModel.unplaceRevision
        }

        static func makeConfiguration() -> ARWorldTrackingConfiguration {
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.planeDetection = [.horizontal]
            configuration.environmentTexturing = .none
            return configuration
        }

        func attach(to view: ARView) {
            self.view = view
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            view.addGestureRecognizer(tap)

            // One finger slides the module across the support plane; twisting with two fingers turns
            // it about the vertical axis.
            let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
            drag.maximumNumberOfTouches = 1
            view.addGestureRecognizer(drag)
            let twist = UIRotationGestureRecognizer(target: self, action: #selector(handleTwist))
            view.addGestureRecognizer(twist)
            installedGestureRecognizers = [tap, drag, twist]

            // Twice a second, is there a surface under the middle of the screen? One raycast, and it is
            // what lets the prompt say "ready" instead of leaving the operator tapping hopefully.
            searchTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.probeForSurface() }
            }
            lastFrameTime = CACurrentMediaTime()
            watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkForStalledCamera() }
            }
        }

        private func probeForSurface() {
            guard ownsSharedView, let view, !model.isPlaced else { return }
            let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let found = !view.raycast(
                from: centre,
                allowing: .estimatedPlane,
                alignment: .horizontal
            ).isEmpty
            model.reportSurface(found: found)
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
                return
            }
            for recognizer in installedGestureRecognizers {
                view.removeGestureRecognizer(recognizer)
            }
            installedGestureRecognizers.removeAll()
            clearPlacement()
            if let sharedViewHost, let sharedViewLease {
                // A late dismantle from an old cover must not clear the measurement coordinator's
                // delegate after it has already reacquired this shared ARView.
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
        }

        // MARK: - Keeping the camera alive

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

        /// Reports a stalled camera; it no longer tries to fix one.
        ///
        /// This used to call `session.run` again every couple of seconds while frames were not arriving.
        /// That was a bad trade: re-running a session restarts its camera pipeline, so on a session that
        /// was merely slow the watchdog produced exactly the flicker it was meant to prevent, several
        /// times over. Interruption and failure are still handled through the delegate, which is the
        /// path ARKit actually tells us about. If frames stop for another reason the operator is told,
        /// and nothing is done behind their back.
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

        /// One finger slides the module across the surface, which is what everyone tries first and
        /// what every other AR app does. It used to turn it, which meant the module spun when you
        /// tried to nudge it and there was no way to move it at all short of putting it down again.
        @objc private func handleDrag(_ recogniser: UIPanGestureRecognizer) {
            guard ownsSharedView, let view, let anchor, contentRoot != nil else { return }
            switch recogniser.state {
            case .began:
                isDragging = true
                dragOffset = nil
            case .changed:
                let point = recogniser.location(in: view)
                guard let result = view.raycast(
                    from: point,
                    allowing: .estimatedPlane,
                    alignment: .horizontal
                ).first else {
                    return
                }
                // Move by how far the finger has moved, not to where it is. Setting the position to the
                // hit point put the module's own origin under the finger, so it jumped the moment the
                // drag started — grabbing a corner teleported the whole thing. The offset between the
                // module and the first hit is taken once and held for the rest of the gesture.
                //
                // Height is left alone: the raycast happily returns the floor once the finger passes the
                // edge of the table, and following it dropped the module off the table mid-drag.
                var transform = anchor.transform
                let hit = Transform(matrix: result.worldTransform).translation
                if dragOffset == nil {
                    dragOffset = SIMD2(
                        transform.translation.x - hit.x,
                        transform.translation.z - hit.z
                    )
                }
                let offset = dragOffset ?? .zero
                transform.translation = SIMD3(
                    hit.x + offset.x,
                    transform.translation.y,
                    hit.z + offset.y
                )
                anchor.transform = transform
            case .ended, .cancelled, .failed:
                isDragging = false
            default:
                break
            }
        }

        @objc private func handleTwist(_ recogniser: UIRotationGestureRecognizer) {
            guard ownsSharedView, contentRoot != nil else { return }
            switch recogniser.state {
            case .began:
                turnAtGestureStart = turn
            case .changed, .ended:
                apply(
                    turn: turnAtGestureStart - Float(recogniser.rotation),
                    settling: recogniser.state == .ended
                )
            default:
                break
            }
        }

        /// Lets go on a right angle when it is nearly there. The module is being lined up with a real
        /// table, and square is almost always what was meant.
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

        private func clearPlacement() {
            anchor?.removeFromParent()
            anchor = nil
            contentRoot = nil
            packageEntities.removeAll()
            visualsByPackage.removeAll()
            observedRevision = -1
            turn = 0
        }

        @objc private func handleTap(_ recogniser: UITapGestureRecognizer) {
            guard ownsSharedView, let view else { return }
            let point = recogniser.location(in: view)

            if anchor == nil {
                place(at: point, in: view)
                return
            }
            // Naming a package: hit-test the rendered boxes.
            guard let hit = view.entity(at: point) as? ModelEntity,
                  let match = packageEntities.first(where: { $0.value === hit }) else {
                model.select(packageID: nil)
                return
            }
            model.select(packageID: match.key)
        }

        private func place(at point: CGPoint, in view: ARView) {
            guard let result = view.raycast(
                from: point,
                allowing: .estimatedPlane,
                alignment: .horizontal
            ).first else {
                model.reportNoSurface()
                return
            }
            searchTimer?.invalidate()
            searchTimer = nil

            let placed = AnchorEntity(world: result.worldTransform)
            let content = Entity()
            placed.addChild(content)
            view.scene.addAnchor(placed)
            anchor = placed
            contentRoot = content
            turn = 0
            build(into: content)
            observedRevision = model.revision
            refreshLayerVisibility()
            model.markPlaced()
        }

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

                // This entity remains the exact full-size hit volume. Visible geometry is attached
                // just inside it so touching targets never place two transparent faces at exactly the
                // same depth.
                let box = ModelEntity(
                    mesh: .generateBox(size: boxSize),
                    materials: [Self.unlitMaterial(colour)]
                )
                box.generateCollisionShapes(recursive: false)
                box.model = nil
                // Keep the selectable volume explicit after removing the render model. This also
                // means the thin visual bars do not need their own collision shapes.
                box.components.set(
                    CollisionComponent(shapes: [.generateBox(size: boxSize)])
                )
                // Packing is z-up, RealityKit is y-up, and the shell is centred on the anchor, so
                // the horizontal axes are offset by half the container's width and depth.
                box.position = SIMD3(
                    centre.x - size.x / 2,
                    centre.y,
                    centre.z - size.y / 2
                )
                anchor.addChild(box)
                packageEntities[placement.id] = box
                addPackageFill(size: boxSize, colour: colour, on: box, id: placement.id)
                addPackageOutline(size: boxSize, colour: colour, on: box, id: placement.id)
                addFaceMarkings(for: placement, on: box, extent: extent, colour: colour, id: placement.id)
            }
        }

        /// A low-opacity solid behind the frame makes the target read as a box while leaving the real
        /// module and the packages already loaded visible through it.
        private func addPackageFill(
            size: SIMD3<Float>,
            colour: UIColor,
            on box: ModelEntity,
            id: UUID
        ) {
            let thickness = Self.outlineThickness(for: size)
            let inset = PackingARVisualGeometry.fillInset(for: thickness)
            let visibleSize = PackingARVisualGeometry.insetFrameSize(size, by: inset)
            let fill = ModelEntity(
                mesh: .generateBox(size: visibleSize),
                materials: [Self.translucentMaterial(colour, opacity: 0.24)]
            )
            box.addChild(fill)
            visualsByPackage[id, default: []].append((fill, .fill))
        }

        /// Twelve solid bars keep the edges legible around the translucent filled target.
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

        /// The opening runs along the package's length, and the operator has to line the real box up
        /// with it. Both L × W faces carry a centred line along measured length, so the same
        /// orientation cue is visible from either side.
        ///
        /// Which faces those are depends on how the package was turned. `placement.size` is already in
        /// container axes, so the box's own length, width and height can be pointing along any of them —
        /// a package stood on its end has its l × w faces vertical. The first version marked the
        /// horizontal faces regardless, which is why the line kept appearing on the w × h side.
        ///
        /// `rotation.sourceAxis[c]` gives the box's own axis carried by container axis `c`: 0 is its
        /// length, 1 its width, 2 its height. The faces to mark are the two perpendicular to whichever
        /// container axis carries axis 2, and the line runs along whichever carries axis 0.
        private func addFaceMarkings(
            for placement: BaldiPlacement,
            on box: ModelEntity,
            extent: SIMD3<Float>,
            colour: UIColor,
            id: UUID
        ) {
            guard let axes = BaldiOpeningMarker.faceAxes(for: placement) else { return }
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

            /// Packing is z-up, RealityKit is y-up, so the two vertical axes swap.
            func realityKit(_ values: [Float]) -> SIMD3<Float> {
                SIMD3(values[0], values[2], values[1])
            }

            for face in [Float(1), Float(-1)] {
                var lineSize = [Float](repeating: 0, count: 3)
                lineSize[normal] = markerDepth
                lineSize[length] = extent[length] * 0.78
                lineSize[width] = markerWidth

                var lineAt = [Float](repeating: 0, count: 3)
                // Sit wholly inside this package's true face. A marker on a touching face can no
                // longer penetrate its neighbour or occupy the same depth as the neighbour's frame.
                lineAt[normal] = PackingARVisualGeometry.markerCentre(
                    face: face,
                    normalExtent: extent[normal],
                    markerDepth: markerDepth,
                    inset: inset
                )

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

        /// A lower layer's edge frame must remain recognisable without adding more transparent edge
        /// geometry. Its fill gets the lower opacity separately in `refreshLayerVisibility`.
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

        private static func translucentMaterial(
            _ colour: UIColor,
            opacity: CGFloat
        ) -> UnlitMaterial {
            UnlitMaterial(
                color: colour.withAlphaComponent(min(max(opacity, 0), 1)),
                applyPostProcessToneMap: false
            )
        }

        private static func outlineThickness(for size: SIMD3<Float>) -> Float {
            max(0.0015, min(0.004, min(size.x, min(size.y, size.z)) * 0.035))
        }

        /// Adds the twelve edges of a cuboid. Each edge is inset by half its thickness, so bars meet
        /// at the corners without leaving coincident surfaces that can fight over the same depth.
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

        /// An open wire shell shows the payload bounds without putting five overlapping translucent
        /// panels around the packages. The top has only its perimeter, so the operator can still see
        /// and reach into the module.
        private func addOpenTopShell(size: SIMD3<Float>, to anchor: Entity) {
            let shellSize = SIMD3(size.x, size.z, size.y)
            let thickness = max(0.0018, min(0.004, min(size.x, size.y) * 0.008))
            let shell = Entity()
            shell.position = SIMD3(0, size.z / 2, 0)
            anchor.addChild(shell)
            addBoxFrame(
                // Keep the green shell just outside the usable volume. Packages at x/y/z = 0 then
                // touch its inner edge instead of occupying the same pixels with another colour.
                size: shellSize + SIMD3<Float>(repeating: thickness * 2),
                thickness: thickness,
                colour: .systemGreen,
                to: shell
            )
        }

        /// The active layer keeps its package colours. Completed layers are muted and more transparent;
        /// future layers are disabled.
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
                        case .fill:
                            visual.entity.model?.materials = [
                                Self.translucentMaterial(
                                    outlineColour,
                                    opacity: isCurrent ? 0.24 : 0.10
                                )
                            ]
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
