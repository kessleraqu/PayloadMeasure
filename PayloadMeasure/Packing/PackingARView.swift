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

    /// Keeps each translucent face behind the edge bars and away from a neighbouring package's face.
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

    /// How far the module may be slid from where it was put down. A drag is a nudge across a table,
    /// not a throw across the building, and without a bound an unlucky gesture could put the module
    /// tens of metres away — off screen, with no way back except placing it again.
    static let maximumDragOffsetMetres: Float = 4

    /// Keeps a dragged offset finite and within `maximumDragOffsetMetres` of the anchor.
    static func clampedDragOffset(_ offset: SIMD3<Float>) -> SIMD3<Float> {
        func bounded(_ value: Float) -> Float {
            guard value.isFinite else { return 0 }
            return min(max(value, -maximumDragOffsetMetres), maximumDragOffsetMetres)
        }
        return SIMD3(bounded(offset.x), bounded(offset.y), bounded(offset.z))
    }

    /// Where the module ends up after the finger has moved from one point on the table to another.
    ///
    /// The two world points come from unprojecting the touch onto the table itself, so the module keeps
    /// up with the finger exactly, at any camera angle. What this replaced converted screen points into
    /// metres through a fixed fudge factor and derived its two horizontal directions by normalising the
    /// camera's axes — which collapses when the phone is held upright, because the axis being
    /// normalised is then nearly vertical and its horizontal part is mostly noise. That is what made
    /// the module wander off at odd angles and at the wrong speed.
    static func draggedOffset(
        from startOffset: SIMD3<Float>,
        startingAt startWorldPoint: SIMD3<Float>,
        following currentWorldPoint: SIMD3<Float>
    ) -> SIMD3<Float> {
        let delta = currentWorldPoint - startWorldPoint
        // Vertical is not the drag's business: the module stays on the surface it was put down on.
        return clampedDragOffset(
            SIMD3(startOffset.x + delta.x, 0, startOffset.z + delta.z)
        )
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

    /// The answer to "which one is this?", at the size of the question. The name carries the package's
    /// own colour and its guide number, so the box in the hand, the box on the screen and the numbered
    /// step in the loading guide are obviously the same package.
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
    /// The same numbering the printed loading guide uses, so "#3" means the same thing on both.
    let numbering: [UUID: Int]

    private(set) var isPlaced = false
    private(set) var visibleLayerIndex = 0
    private(set) var selectedPackageID: UUID?
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

    /// Set by the AR coordinator so that "Place again" tears the module down there and then.
    ///
    /// This used to be published as a revision for the coordinator to notice on its next SwiftUI update
    /// pass. When that update did not arrive, the old payload stayed in the scene and its anchor stayed
    /// in place — so the next tap hit the old module's packages instead of the table, and nothing could
    /// be placed again. A button whose whole job is to remove something calls the code that removes it.
    @ObservationIgnored var unplaceHandler: (() -> Void)?

    func unplace() {
        isPlaced = false
        selectedPackageID = nil
        isSurfaceReady = false
        statusText = Self.searchingText
        unplaceRevision &+= 1
        unplaceHandler?()
    }

    /// Says where to aim, not just to wave the phone about: the surface is looked for under the middle
    /// of the screen, so sweeping the room while pointing elsewhere finds nothing.
    static let searchingText = "Point the middle of the screen at the table or floor and move the phone slowly until the surface is found."

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
              solution.placements.contains(where: { $0.id == packageID }) else {
            selectedPackageID = nil
            return
        }
        // Tapping the same package again clears it, so the label can be dismissed without hunting for
        // an empty piece of table to tap.
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
    final class Coordinator: NSObject, ARSessionDelegate, UIGestureRecognizerDelegate {
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
        /// Each face is inset from both the exact collision volume and the opaque outline. This keeps
        /// touching packages from sharing transparent faces while still giving each target a clear,
        /// lightly coloured volume.
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
        /// The content's offset inside the anchor when a one-finger drag began, and the point on the
        /// table the finger started from. Movement is the difference between the two, so the module
        /// follows the finger exactly.
        private var dragStartContentOffset: SIMD3<Float>?
        private var dragStartSurfacePoint: SIMD3<Float>?
        private var turnAtGestureStart: Float = 0
        private var twoFingerTurnAtStart: Float = 0
        private var twistIsActive = false
        private var suppressTwoFingerPanUntilEnd = false
        /// The height of the surface last found under the middle of the screen. Placing prefers it, so
        /// a tap lands on the surface the prompt was talking about rather than on a floor behind it.
        private var probedSurfaceHeight: Float?
        /// The ARKit anchor the module hangs from. ARKit keeps it on the real surface across tracking
        /// corrections, which a bare world transform is not.
        private var placedWorldAnchor: ARAnchor?

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
            // Plane detection without depth waits for enough visual features, which on a bare table
            // can be most of a minute of sweeping — the measuring screens have always run with depth
            // and find surfaces at once. Same hardware, same session; there was no reason for this
            // screen to be the slow one.
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

            // One finger slides the module across the support plane; twisting with two fingers turns
            // it about the vertical axis.
            let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
            drag.minimumNumberOfTouches = 1
            drag.maximumNumberOfTouches = 1
            drag.delegate = self
            view.addGestureRecognizer(drag)
            let twist = UIRotationGestureRecognizer(target: self, action: #selector(handleTwist))
            twist.delegate = self
            view.addGestureRecognizer(twist)
            // Some users move two fingers as a pair without producing enough angular delta for
            // UIRotationGestureRecognizer to begin. Treat that horizontal two-finger motion as yaw
            // too, while a real twist remains the primary gesture.
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
            // A one-finger pan may already be considering the first touch when the second finger
            // lands. Let the rotation recognizer take over instead of losing that two-finger twist.
            let pair = [gestureRecognizer, otherGestureRecognizer]
            return pair.contains { $0 is UIRotationGestureRecognizer }
                && pair.contains { $0 is UIPanGestureRecognizer }
        }

        /// Uses only a plane ARKit has actually detected. The infinite target is merely an extension
        /// of that detected plane; estimated planes can be the floor behind a table and were the
        /// reason a placement could appear underneath the surface.
        ///
        /// Planes classified as floors used to be rejected outright, to stop a tap on a table landing
        /// on the floor visible behind it. That also made the guide impossible to use on a floor — and
        /// ARKit calls plenty of large surfaces floors — so nothing ever locked. Results come back
        /// nearest-first, so taking the first is already the surface under the finger; the height match
        /// below does the rest of that job.
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

        /// Three times a second, is there a surface under the middle of the screen? One raycast, and it
        /// is what lets the prompt say "ready" instead of leaving the operator tapping hopefully.
        ///
        /// It runs for the whole life of the coordinator. Placing the module used to stop it, and
        /// nothing ever started it again — so after "Place again" no surface was ever found and the
        /// module could not be put down a second time.
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
            model.unplaceHandler = nil
            // Last, because clearing the placement arms the probe again for the next placement — and
            // there is no next one after a detach.
            stopSurfaceProbe()
        }

        // MARK: - Keeping the camera alive

        /// Also the safety net for placement state. `unplaceHandler` does the work the moment the button
        /// is pressed; this catches anything that changed the model without going through it, without
        /// depending on a SwiftUI update pass arriving.
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
        ///
        /// The module is moved by offsetting the content *inside* the anchor, never by writing to the
        /// anchor itself. An anchor's transform belongs to ARKit — it is corrected as tracking improves
        /// and rewritten wholesale after a relocalisation — so an app that also writes to it is in a
        /// fight it cannot win, and the visible result is a module that jumps somewhere absurd.
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
                // The anchor's own rotation is identity, so its axes are the world's and a world-space
                // movement can be applied to the child offset directly.
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

        /// Where a point on screen meets the table the module is standing on. Unprojecting onto the
        /// plane itself is what makes dragging one-to-one with the finger; it needs no plane polygon, so
        /// it keeps working past the edge of what ARKit has mapped.
        private func surfacePoint(at point: CGPoint, in view: ARView) -> SIMD3<Float>? {
            guard let frame = view.session.currentFrame,
                  view.bounds.width > 0,
                  view.bounds.height > 0 else {
                return nil
            }
            // ARKit's own anchor transform, not the entity's: RealityKit adopts an anchor's transform on
            // its own schedule, and a height read a frame too early would put the plane on the floor.
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

        /// Reliable fallback for a two-finger turn when the fingers travel together rather than
        /// describing a clear twist. Eight milliradians per screen point keeps it controllable.
        @objc private func handleTwoFingerTurn(_ recogniser: UIPanGestureRecognizer) {
            guard ownsSharedView, contentRoot != nil else { return }
            switch recogniser.state {
            case .began:
                // A real twist may end without the companion pan recognizer ever reaching `.ended`.
                // Clear that gesture's suppression here so the next two-finger motion is never lost.
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

        /// Takes the module out of the scene *and* out of the session. Removing the entity alone left
        /// ARKit's anchor behind, and RealityKit will happily draw a previously bound anchor's content
        /// again — which is why "Place again" appeared to leave the old payload standing there.
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
            // Whatever is being put down next needs a surface of its own found first.
            startSurfaceProbe()
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
            // Prefer the surface the prompt was talking about — the one under the middle of the screen —
            // and fall back to whatever was actually tapped. Insisting on the probed height meant a tap
            // on a different but perfectly good surface did nothing at all.
            let result = probedSurfaceHeight.flatMap {
                stableSurfaceHit(at: point, in: view, matchingHeight: $0)
            } ?? stableSurfaceHit(at: point, in: view)
            guard let result else {
                model.reportNoSurface()
                return
            }

            // Raycast orientation can carry a small tilt or arbitrary yaw. The module is meant to sit
            // level and gets its yaw only from the two-finger gesture, so anchor it with translation
            // alone in the gravity-aligned world frame.
            var stableTransform = matrix_identity_float4x4
            stableTransform.columns.3 = result.worldTransform.columns.3
            // A session anchor rather than a bare world transform: ARKit then owns keeping it on the
            // real surface as tracking is refined, instead of the module drifting off the table.
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
                addPackageFaces(size: boxSize, colour: colour, on: box, id: placement.id)
                addPackageOutline(size: boxSize, colour: colour, on: box, id: placement.id)
                addFaceMarkings(for: placement, on: box, extent: extent, colour: colour, id: placement.id)
            }
        }

        /// Six separate low-opacity panels leave the interior genuinely clear. The previous closed
        /// transparent cuboid accumulated front and back faces until the package looked fully yellow.
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
            let coveredFaces = BaldiOpeningMarker.coveredFaceSigns(
                for: placement,
                among: model.solution.placements
            )

            /// Packing is z-up, RealityKit is y-up, so the two vertical axes swap.
            func realityKit(_ values: [Float]) -> SIMD3<Float> {
                SIMD3(values[0], values[2], values[1])
            }

            for face in [Float(1), Float(-1)] {
                var lineSize = [Float](repeating: 0, count: 3)
                lineSize[normal] = markerDepth
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
