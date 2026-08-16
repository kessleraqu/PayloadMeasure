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
        .animation(.easeInOut(duration: 0.2), value: model.cameraWarning)
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

    /// Quarter turns either way, and the current angle between them. Twisting two fingers on a phone
    /// held in one hand is awkward, and lining the module up with a table edge is nearly always a
    /// right angle away.
    private var turnControls: some View {
        HStack(spacing: 10) {
            turnButton("rotate.left", radians: -.pi / 2, label: "Turn a quarter left")

            Text(String(format: "%.0f°", model.turnDegrees))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .frame(minWidth: 54)

            turnButton("rotate.right", radians: .pi / 2, label: "Turn a quarter right")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
    }

    private func turnButton(
        _ icon: String,
        radians: Float,
        label: String
    ) -> some View {
        Button {
            model.requestTurn(by: radians)
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .frame(width: 46, height: 40)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var placementPrompt: some View {
        Text(model.statusText)
            .font(.callout.weight(.medium))
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
    private(set) var statusText = "Point at the table and tap to put the module down."
    /// How far the module has been turned about the vertical, 0 to 360, for the readout.
    private(set) var turnDegrees: Double = 0
    /// Set while the camera is being taken back from whatever else grabbed it.
    private(set) var cameraWarning: String?
    /// Bumped whenever the AR side must rebuild what it is showing.
    private(set) var revision = 0
    /// Bumped when the operator wants to place the module again.
    private(set) var unplaceRevision = 0
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
        statusText = "Point at the table and tap to put the module down."
        unplaceRevision &+= 1
    }

    func reportNoSurface() {
        guard !isPlaced else { return }
        statusText = "Move the phone slowly across the table until a surface is found, then tap."
    }

    /// Whole degrees, and only when they change: this is called for every touch move, and the
    /// readout it feeds cannot show anything finer anyway.
    /// A turn asked for by the buttons. The AR side owns the actual rotation, so this is a request it
    /// picks up on the next sync rather than a value applied here.
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
        private var observedRevision = -1
        private var observedUnplaceRevision = 0
        private var observedTurnRequestRevision = 0
        private var searchTimer: Timer?
        private var watchdogTimer: Timer?
        private var lastFrameTime: TimeInterval = 0
        private var lastFrameTimestamp: TimeInterval = 0
        private var restartsRemaining = 4
        private var turn: Float = 0
        /// Suppresses the tap that ends a drag, so sliding the module does not also select a package.
        private var isDragging = false
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

            searchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.model.reportNoSurface() }
            }
            lastFrameTime = CACurrentMediaTime()
            watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkForStalledCamera() }
            }
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

        /// Only one ARKit session can hold the camera. If anything else takes it — the measuring
        /// session waking up behind this screen, a phone call, the app going away and coming back —
        /// this one simply stops being given frames and the picture sits there frozen, with no error
        /// and no interruption callback to react to. So the session's own frame clock is read once a
        /// second, and if it has stopped moving the session is told to run again.
        ///
        /// Once a second, from the session itself: no per-frame delegate work, which at sixty frames
        /// a second would cost more than the problem it is watching for.
        private func checkForStalledCamera() {
            guard let view, restartsRemaining > 0 else { return }
            let now = CACurrentMediaTime()
            guard let timestamp = view.session.currentFrame?.timestamp else { return }

            if timestamp != lastFrameTimestamp {
                lastFrameTimestamp = timestamp
                lastFrameTime = now
                restartsRemaining = 4
                model.clearCameraWarning()
                return
            }
            guard now - lastFrameTime > 2 else { return }
            restartsRemaining -= 1
            model.reportCameraRestarting()
            // No reset: the placed module and the tracked world are kept if the session comes back.
            view.session.run(Self.makeConfiguration())
            lastFrameTime = now
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
            case .changed:
                let point = recogniser.location(in: view)
                guard let result = view.raycast(
                    from: point,
                    allowing: .estimatedPlane,
                    alignment: .horizontal
                ).first else {
                    return
                }
                // Only the position follows the finger. Taking the raycast's whole transform would
                // also take the plane's own rotation and undo whatever turn has been dialled in.
                var transform = anchor.transform
                transform.translation = Transform(matrix: result.worldTransform).translation
                anchor.transform = transform
            case .ended, .cancelled, .failed:
                isDragging = false
            default:
                break
            }
        }

        /// A quarter turn at a time, for the operator who wants the module square to the table rather
        /// than approximately square. Twisting is still there for anything in between.
        func nudgeTurn(by radians: Float) {
            guard contentRoot != nil else { return }
            apply(turn: turn + radians, settling: true)
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
                addOpeningEdges(for: placement, on: box, extent: extent, colour: colour)
            }
        }

        /// The opening runs along the package's length, and the operator has to line the real box up
        /// with it. Drawn on both mirrored length edges of the top face, in a darker tone of the
        /// package's own colour, so whichever way the box is picked up one of them faces them.
        private func addOpeningEdges(
            for placement: BaldiPlacement,
            on box: ModelEntity,
            extent: SIMD3<Float>,
            colour: UIColor
        ) {
            let axis = BaldiOpeningMarker.containerAxis(for: placement)
            guard axis != 2 else { return }
            let along = axis == 0
            let lengthSpan = along ? extent.x : extent.y
            let acrossSpan = along ? extent.y : extent.x
            let bar = max(0.0015, min(lengthSpan, acrossSpan) * 0.05)
            guard lengthSpan > 0, acrossSpan > bar else { return }

            var material = SimpleMaterial(
                color: darkened(colour, by: 0.55).withAlphaComponent(0.85),
                isMetallic: false
            )
            material.roughness = 0.9
            let top = extent.z / 2 + bar / 2

            for side in [Float(-1), Float(1)] {
                let offset = (acrossSpan - bar) / 2 * side
                let line = ModelEntity(
                    mesh: .generateBox(
                        size: along
                            ? SIMD3(lengthSpan * 0.96, bar, bar)
                            : SIMD3(bar, bar, lengthSpan * 0.96)
                    ),
                    materials: [material]
                )
                line.position = along
                    ? SIMD3(0, top, offset)
                    : SIMD3(offset, top, 0)
                box.addChild(line)
            }
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
                }
            }
        }

        private func colours(for id: UUID) -> Color {
            model.colours[id] ?? .accentColor
        }
    }
}
