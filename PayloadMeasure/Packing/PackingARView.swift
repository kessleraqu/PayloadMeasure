import ARKit
import RealityKit
import SwiftUI
import simd

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
    @State private var model: PackingARModel
    /// Which turn button is being held, and the ticker that keeps it turning.
    @State private var heldDirection: Float?

    init(solution: BaldiSolution, colours: [UUID: Color]) {
        self.solution = solution
        self.colours = colours
        _model = State(initialValue: PackingARModel(solution: solution, colours: colours))
    }

    var body: some View {
        ZStack {
            PackingARContainer(model: model)
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
        .onAppear { model.beginSession() }
        .animation(.easeInOut(duration: 0.2), value: model.cameraWarning)
        .animation(.easeInOut(duration: 0.2), value: model.isSurfaceReady)
        // 3° every 40 ms while held: a full turn in about five seconds, slow enough to stop where you
        // meant to.
        .task(id: heldDirection) {
            guard let heldDirection else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(40))
                if Task.isCancelled { return }
                model.requestTurn(by: heldDirection * .pi / 60)
            }
        }
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

    /// Hold one side or the other and it turns, for as long as you hold it.
    ///
    /// Twisting two fingers on a phone that is being held in one hand while the other hand holds a box
    /// does not work, and tapping a quarter turn at a time is too coarse for lining up with a table
    /// edge. Holding is the gesture that suits the situation: press, watch it turn, let go when it looks
    /// right. Each side steps a small angle on a timer, so a tap is a nudge and a hold is a sweep.
    private var turnControls: some View {
        HStack(spacing: 12) {
            turnButton("rotate.left", direction: -1, label: "Hold to turn left")

            VStack(spacing: 0) {
                Text(String(format: "%.0f°", model.turnDegrees))
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                Text("hold to turn")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 78)

            turnButton("rotate.right", direction: 1, label: "Hold to turn right")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    private func turnButton(
        _ icon: String,
        direction: Float,
        label: String
    ) -> some View {
        Image(systemName: icon)
            .font(.title3.weight(.semibold))
            .frame(width: 62, height: 46)
            .contentShape(Capsule())
            .background(
                heldDirection == direction ? Color.accentColor.opacity(0.28) : Color.clear,
                in: Capsule()
            )
            // A press, not a tap: zero minimum distance so it reports the moment the finger lands, and
            // the gesture stays alive while it is held.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard heldDirection != direction else { return }
                        heldDirection = direction
                        model.requestTurn(by: direction * .pi / 60)
                    }
                    .onEnded { _ in heldDirection = nil }
            )
            .accessibilityLabel(label)
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

            turnControls

            Text("Drag to slide it, twist to turn it. Tap a package to read its name.")
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
    /// How far the module has been turned about the vertical, 0 to 360, for the readout.
    private(set) var turnDegrees: Double = 0
    /// Set while the camera is being taken back from whatever else grabbed it.
    private(set) var cameraWarning: String?
    /// Bumped whenever the AR side must rebuild what it is showing.
    private(set) var revision = 0
    /// Bumped when the operator wants to place the module again.
    private(set) var unplaceRevision = 0
    /// Bumped each time this screen appears, so the AR side restarts its session even when the view
    /// itself has been reused.
    private(set) var sessionEpoch = 0
    /// Bumped by the turn buttons; the delta is in radians about the vertical.
    private(set) var turnRequestRevision = 0
    private(set) var requestedTurnDelta: Float = 0

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
        turnDegrees = 0
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

    /// Whole degrees, and only when they change: this is called for every touch move, and the
    /// readout it feeds cannot show anything finer anyway.
    /// A turn asked for by the buttons. The AR side owns the actual rotation, so this is a request it
    /// picks up on the next sync rather than a value applied here.
    func beginSession() {
        sessionEpoch &+= 1
        isPlaced = false
        selectedPackageName = nil
        turnDegrees = 0
        cameraWarning = nil
        statusText = Self.searchingText
    }

    func requestTurn(by radians: Float) {
        requestedTurnDelta = radians
        turnRequestRevision &+= 1
    }

    func reportTurn(radians: Float) {
        var degrees = (Double(radians) * 180 / .pi).rounded().truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        guard degrees != turnDegrees else { return }
        turnDegrees = degrees
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

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session.delegate = context.coordinator
        view.session.run(
            Coordinator.makeConfiguration(),
            options: [.resetTracking, .removeExistingAnchors]
        )
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.sync()
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.delegate = nil
        uiView.session.pause()
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        private let model: PackingARModel
        private weak var view: ARView?
        private var anchor: AnchorEntity?
        /// Child of the anchor. Everything is built into this so it can be turned without disturbing
        /// the anchor's alignment with the real surface.
        private var contentRoot: Entity?
        private var packageEntities: [UUID: ModelEntity] = [:]
        /// The lid and hinge parts, with the colour each was built from, so they can be faded with the
        /// layer they belong to instead of staying solid over a faint package.
        private var decorationsByPackage: [UUID: [(entity: ModelEntity, colour: UIColor)]] = [:]
        private var observedRevision = -1
        private var observedUnplaceRevision = 0
        private var observedTurnRequestRevision = 0
        private var observedSessionEpoch = 0
        private var searchTimer: Timer?
        private var watchdogTimer: Timer?
        private var lastFrameTime: TimeInterval = 0
        private var lastFrameTimestamp: TimeInterval = 0
        private var restartsRemaining = 4
        private var turn: Float = 0
        /// Suppresses the tap that ends a drag, so sliding the module does not also select a package.
        private var isDragging = false
        /// Where the module sat relative to the first raycast hit of the current drag.
        private var dragOffset: SIMD2<Float>?
        private var turnAtGestureStart: Float = 0

        /// Millimetres to metres. Everything in the packing is in millimetres.
        private let scale: Float = 0.001

        init(model: PackingARModel) {
            self.model = model
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

            // Turning the module: drag with one finger, or twist with two. Both do the same thing,
            // because neither is obvious on its own and the operator is usually holding the phone
            // with one hand and a box with the other.
            let drag = UIPanGestureRecognizer(target: self, action: #selector(handleDrag))
            drag.maximumNumberOfTouches = 1
            view.addGestureRecognizer(drag)
            let twist = UIRotationGestureRecognizer(target: self, action: #selector(handleTwist))
            view.addGestureRecognizer(twist)

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
            guard let view, !model.isPlaced else { return }
            let centre = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            let found = !view.raycast(
                from: centre,
                allowing: .estimatedPlane,
                alignment: .horizontal
            ).isEmpty
            model.reportSurface(found: found)
        }

        func detach() {
            searchTimer?.invalidate()
            searchTimer = nil
            watchdogTimer?.invalidate()
            watchdogTimer = nil
            view = nil
        }

        // MARK: - Keeping the camera alive

        nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
            Task { @MainActor [weak self] in
                self?.restartSession(resettingTracking: true)
            }
        }

        nonisolated func sessionWasInterrupted(_ session: ARSession) {
            Task { @MainActor [weak self] in
                self?.model.reportCameraRestarting()
            }
        }

        nonisolated func sessionInterruptionEnded(_ session: ARSession) {
            Task { @MainActor [weak self] in
                self?.restartSession(resettingTracking: false)
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
            guard let view else { return }
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
            guard let view else { return }
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
            guard let view, let anchor, contentRoot != nil else { return }
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

        /// One step of a held turn. Deliberately does not snap to a right angle: the buttons step a few
        /// degrees at a time, and snapping on every step would stick the module to each right angle
        /// instead of letting it turn through them. The twist gesture still snaps when it is let go.
        func nudgeTurn(by radians: Float) {
            guard contentRoot != nil else { return }
            apply(turn: turn + radians, settling: false)
        }

        @objc private func handleTwist(_ recogniser: UIRotationGestureRecognizer) {
            guard contentRoot != nil else { return }
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
            model.reportTurn(radians: value)
        }

        func sync() {
            // The container can be reused when this screen is presented a second time — for the second
            // payload, most of all. `makeUIView` is then not called again, so the session paused by the
            // first dismissal is never restarted, and the view keeps showing the last frame it drew while
            // anchors and gestures carry on working underneath. That is the frozen picture on the second
            // box, with a live plan on top of a still image.
            if model.sessionEpoch != observedSessionEpoch {
                observedSessionEpoch = model.sessionEpoch
                if let view {
                    view.session.run(
                        Self.makeConfiguration(),
                        options: [.resetTracking, .removeExistingAnchors]
                    )
                    clearPlacement()
                    lastFrameTimestamp = 0
                    lastFrameTime = CACurrentMediaTime()
                }
            }
            if model.turnRequestRevision != observedTurnRequestRevision {
                observedTurnRequestRevision = model.turnRequestRevision
                nudgeTurn(by: model.requestedTurnDelta)
            }
            if model.unplaceRevision != observedUnplaceRevision {
                observedUnplaceRevision = model.unplaceRevision
                clearPlacement()
                return
            }
            guard anchor != nil, model.revision != observedRevision else { return }
            observedRevision = model.revision
            refreshLayerVisibility()
        }

        private func clearPlacement() {
            anchor?.removeFromParent()
            anchor = nil
            contentRoot = nil
            packageEntities.removeAll()
            decorationsByPackage.removeAll()
            observedRevision = -1
            turn = 0
        }

        @objc private func handleTap(_ recogniser: UITapGestureRecognizer) {
            guard let view else { return }
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
                let box = ModelEntity(
                    mesh: .generateBox(size: SIMD3(extent.x, extent.z, extent.y), cornerRadius: 0.002),
                    materials: [SimpleMaterial(color: colour, isMetallic: false)]
                )
                // Packing is z-up, RealityKit is y-up, and the shell is centred on the anchor, so
                // the horizontal axes are offset by half the container's width and depth.
                box.position = SIMD3(
                    centre.x - size.x / 2,
                    centre.y,
                    centre.z - size.y / 2
                )
                box.generateCollisionShapes(recursive: false)
                anchor.addChild(box)
                packageEntities[placement.id] = box
                addFaceMarkings(for: placement, on: box, extent: extent, colour: colour, id: placement.id)
            }
        }

        /// The opening runs along the package's length, and the operator has to line the real box up
        /// with it. Drawn on both mirrored length edges of the top face, in a darker tone of the
        /// package's own colour, so whichever way the box is picked up one of them faces them.
        /// The two l × w faces darker, each with a line down the middle along the length.
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
            let sourceAxis = placement.rotation.sourceAxis
            guard let normal = sourceAxis.firstIndex(of: 2),
                  let length = sourceAxis.firstIndex(of: 0),
                  let width = sourceAxis.firstIndex(of: 1),
                  extent[normal] > 0, extent[length] > 0, extent[width] > 0 else {
                return
            }

            let plate = max(0.0010, extent[normal] * 0.02)
            let line = max(0.0015, extent[width] * 0.06)
            let faceColour = darkened(colour, by: 0.4)
            let lineColour = darkened(colour, by: 0.75)

            /// Packing is z-up, RealityKit is y-up, so the two vertical axes swap.
            func realityKit(_ values: [Float]) -> SIMD3<Float> {
                SIMD3(values[0], values[2], values[1])
            }

            for face in [Float(1), Float(-1)] {
                let offset = face * (extent[normal] / 2 - plate / 2)

                var faceSize = [Float](repeating: 0, count: 3)
                faceSize[normal] = plate
                faceSize[length] = extent[length] * 0.99
                faceSize[width] = extent[width] * 0.99

                var faceAt = [Float](repeating: 0, count: 3)
                faceAt[normal] = offset

                add(
                    size: realityKit(faceSize),
                    at: realityKit(faceAt),
                    colour: faceColour,
                    on: box,
                    id: id
                )

                var lineSize = [Float](repeating: 0, count: 3)
                lineSize[normal] = plate * 1.8
                lineSize[length] = extent[length] * 0.9
                lineSize[width] = line

                var lineAt = [Float](repeating: 0, count: 3)
                lineAt[normal] = face * (extent[normal] / 2 - plate * 0.9)

                add(
                    size: realityKit(lineSize),
                    at: realityKit(lineAt),
                    colour: lineColour,
                    on: box,
                    id: id
                )
            }
        }

        private func add(
            size: SIMD3<Float>,
            at position: SIMD3<Float>,
            colour: UIColor,
            on box: ModelEntity,
            id: UUID
        ) {
            var material = SimpleMaterial(color: colour, isMetallic: false)
            material.roughness = 0.9
            let entity = ModelEntity(mesh: .generateBox(size: size), materials: [material])
            entity.position = position
            box.addChild(entity)
            decorationsByPackage[id, default: []].append((entity, colour))
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

        /// Four thin walls and a floor. No lid, so the operator can see and reach in.
        private func addOpenTopShell(size: SIMD3<Float>, to anchor: Entity) {
            let wall: Float = 0.002
            let green = UIColor.systemGreen.withAlphaComponent(0.3)
            var material = SimpleMaterial(color: green, isMetallic: false)
            material.roughness = 0.9

            func panel(_ dimensions: SIMD3<Float>, at position: SIMD3<Float>) {
                let entity = ModelEntity(
                    mesh: .generateBox(size: dimensions),
                    materials: [material]
                )
                entity.position = position
                anchor.addChild(entity)
            }

            let halfX = size.x / 2
            let halfY = size.y / 2      // container depth, along the world z axis
            let height = size.z

            panel(SIMD3(size.x, wall, size.y), at: SIMD3(0, wall / 2, 0))
            panel(SIMD3(size.x, height, wall), at: SIMD3(0, height / 2, -halfY))
            panel(SIMD3(size.x, height, wall), at: SIMD3(0, height / 2, halfY))
            panel(SIMD3(wall, height, size.y), at: SIMD3(-halfX, height / 2, 0))
            panel(SIMD3(wall, height, size.y), at: SIMD3(halfX, height / 2, 0))
        }

        /// The layer being loaded is solid; the ones under it stay visible but faint, so the stack
        /// reads as a stack without hiding where the next package goes. Layers above are hidden —
        /// they have not been loaded yet.
        private func refreshLayerVisibility() {
            for (index, layer) in model.layers.enumerated() {
                let opacity: Float
                // Deliberately see-through: the operator puts the real box down on top of the
                // rendered one, so a solid model would hide exactly what they are aiming at.
                if index == model.visibleLayerIndex {
                    opacity = 0.42
                } else if index < model.visibleLayerIndex {
                    opacity = 0.12
                } else {
                    opacity = 0
                }
                for placement in layer.placements {
                    guard let entity = packageEntities[placement.id] else { continue }
                    entity.isEnabled = opacity > 0
                    var material = SimpleMaterial(
                        color: UIColor(colours(for: placement.id))
                            .withAlphaComponent(CGFloat(opacity)),
                        isMetallic: false
                    )
                    material.roughness = 0.85
                    entity.model?.materials = [material]

                    // The face markings fade with their package. They are darker than it, so they are
                    // given a little more alpha — at the layer opacities used here they would otherwise
                    // disappear before the box does, and the hinge is the part worth seeing.
                    for decoration in decorationsByPackage[placement.id] ?? [] {
                        var decorated = SimpleMaterial(
                            color: decoration.colour.withAlphaComponent(
                                CGFloat(min(opacity * 1.6, 1))
                            ),
                            isMetallic: false
                        )
                        decorated.roughness = 0.9
                        decoration.entity.model?.materials = [decorated]
                    }
                }
            }
        }

        private func colours(for id: UUID) -> Color {
            model.colours[id] ?? .accentColor
        }
    }
}
