import SceneKit
import SwiftUI
import UIKit

/// One bottom-up loading stage. Placements with the same bottom height can be prepared together:
/// no package in the stage can be a vertical supporter for another package in that same stage.
nonisolated struct BaldiLoadingLayer: Identifiable {
    let index: Int
    let baseHeight: Double
    let placements: [BaldiPlacement]

    var id: Int { index }
    var isFloorLayer: Bool {
        abs(baseHeight) <= BaldiVerticalSupport.contactTolerance
    }
}

/// The one deterministic ordering shared by the 3D labels and the loading guide.
nonisolated enum BaldiLoadingGuide {
    static func layers(for solution: BaldiSolution) -> [BaldiLoadingLayer] {
        var groups: [(baseHeight: Double, placements: [BaldiPlacement])] = []

        for placement in orderedPlacements(in: solution) {
            if let last = groups.indices.last,
               abs(groups[last].baseHeight - placement.origin.z)
                   <= BaldiVerticalSupport.contactTolerance {
                groups[last].placements.append(placement)
            } else {
                groups.append((placement.origin.z, [placement]))
            }
        }

        return groups.enumerated().map { index, group in
            BaldiLoadingLayer(
                index: index,
                baseHeight: group.baseHeight,
                placements: group.placements
            )
        }
    }

    static func orderedPlacements(in solution: BaldiSolution) -> [BaldiPlacement] {
        solution.placements.sorted(by: placementOrder)
    }

    static func numbering(for solution: BaldiSolution) -> [UUID: Int] {
        Dictionary(
            uniqueKeysWithValues: orderedPlacements(in: solution).enumerated().map {
                ($0.element.id, $0.offset + 1)
            }
        )
    }

    static func placementOrder(_ first: BaldiPlacement, _ second: BaldiPlacement) -> Bool {
        if first.origin.z != second.origin.z { return first.origin.z < second.origin.z }
        if first.origin.x != second.origin.x { return first.origin.x < second.origin.x }
        if first.origin.y != second.origin.y { return first.origin.y < second.origin.y }
        return first.id.uuidString < second.id.uuidString
    }
}

/// UI meaning of the measured package's original axis 0 after a Baldi rotation.
nonisolated enum BaldiOpeningMarker {
    static func containerAxis(for placement: BaldiPlacement) -> Int {
        placement.rotation.sourceAxis.firstIndex(of: 0) ?? 0
    }

    static func description(for placement: BaldiPlacement) -> String {
        switch containerAxis(for: placement) {
        case 0: "Opening edge along container"
        case 1: "Opening edge across container"
        default: "Opening edge vertical"
        }
    }
}

/// A native SceneKit presentation of the verified packing.
///
/// SceneKit's camera controller supplies orbit, pan and pinch-to-zoom interactions. Geometry is
/// normalised before rendering, so millimetre-scale inputs cannot create an unusably large scene.
struct BaldiPlanView: View {
    let solution: BaldiSolution
    let colours: [UUID: Color]
    @Binding var highlightedPackageID: UUID?
    var selectedLayerIndex: Int?

    @State private var cameraResetToken = 0

    var body: some View {
        ZStack {
            BaldiPackingSceneView(
                solution: solution,
                colours: colours,
                highlightedPackageID: $highlightedPackageID,
                selectedLayerIndex: selectedLayerIndex,
                cameraResetToken: cameraResetToken
            )
            .frame(height: 320)
            .clipShape(.rect(cornerRadius: 14))
        }
        .overlay(alignment: .topTrailing) {
            Button {
                cameraResetToken &+= 1
            } label: {
                Label("Reset view", systemImage: "view.3d")
                    .labelStyle(.iconOnly)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: .circle)
            .padding(10)
            .accessibilityLabel("Reset 3D view")
            .accessibilityHint("Returns the packing to its original camera angle and zoom.")
        }
        .overlay(alignment: .bottomLeading) {
            if let placement = selectedPlacement {
                VStack(alignment: .leading, spacing: 2) {
                    Text("#\(numbering[placement.id] ?? 0)  \(placement.name)")
                        .font(.caption.weight(.semibold))
                    Text(BaldiOpeningMarker.description(for: placement))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: .rect(cornerRadius: 9))
                .padding(10)
                .accessibilityElement(children: .combine)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var numbering: [UUID: Int] {
        BaldiLoadingGuide.numbering(for: solution)
    }

    private var selectedPlacement: BaldiPlacement? {
        guard let highlightedPackageID else { return nil }
        return solution.placements.first { $0.id == highlightedPackageID }
    }
}

/// A compact top view used inside each loading stage. It shows the current packages and outlines
/// the packages immediately supporting that stage, rather than flattening every tier together.
struct BaldiLayerFootprintView: View {
    let solution: BaldiSolution
    let layer: BaldiLoadingLayer
    let colours: [UUID: Color]
    let numbering: [UUID: Int]
    @Binding var highlightedPackageID: UUID?

    private let margin: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard let geometry = geometry(for: size) else { return }
                let shell = geometry.shell
                let scale = geometry.scale

                context.fill(Path(shell), with: .color(.primary.opacity(0.035)))
                context.stroke(Path(shell), with: .color(.primary.opacity(0.28)), lineWidth: 1)

                let supporters = directSupporters
                for placement in solution.placements where supporters.contains(placement.id) {
                    let rect = footprint(of: placement, in: shell, scale: scale)
                    context.stroke(
                        Path(roundedRect: rect, cornerRadius: 2),
                        with: .color(.green.opacity(0.75)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                }

                for placement in layer.placements {
                    let rect = footprint(of: placement, in: shell, scale: scale)
                    let colour = colours[placement.id] ?? .accentColor
                    let selected = highlightedPackageID == placement.id
                    let shape = Path(roundedRect: rect, cornerRadius: min(4, rect.height / 5))
                    context.fill(shape, with: .color(colour.opacity(selected ? 0.68 : 0.42)))
                    context.stroke(
                        shape,
                        with: .color(selected ? Color.primary : colour),
                        lineWidth: selected ? 2.5 : 1.5
                    )
                    drawOpeningMarker(for: placement, in: rect, context: context)

                    if let number = numbering[placement.id], rect.width > 14, rect.height > 13 {
                        context.draw(
                            Text("\(number)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(.primary),
                            at: CGPoint(x: rect.midX, y: rect.midY)
                        )
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { tap in
                    selectPackage(at: tap.location, canvasSize: proxy.size)
                }
            )
        }
        .frame(height: 150)
        .background(Color.primary.opacity(0.025), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private func geometry(for size: CGSize) -> (shell: CGRect, scale: CGFloat)? {
        let containerWidth = Double(solution.knapsack.size.x)
        let containerDepth = Double(solution.knapsack.size.y)
        guard containerWidth > 0, containerDepth > 0 else { return nil }
        let scale: CGFloat = min(
            (size.width - margin * 2) / CGFloat(containerWidth),
            (size.height - margin * 2) / CGFloat(containerDepth)
        )
        let shell = CGRect(
            x: (size.width - containerWidth * scale) / 2,
            y: (size.height - containerDepth * scale) / 2,
            width: containerWidth * scale,
            height: containerDepth * scale
        )
        return (shell, scale)
    }

    private func selectPackage(at point: CGPoint, canvasSize: CGSize) {
        guard let geometry = geometry(for: canvasSize),
              let placement = layer.placements.reversed().first(where: {
                  footprint(of: $0, in: geometry.shell, scale: geometry.scale).contains(point)
              }) else { return }
        highlightedPackageID = highlightedPackageID == placement.id ? nil : placement.id
    }

    private func drawOpeningMarker(
        for placement: BaldiPlacement,
        in rect: CGRect,
        context: GraphicsContext
    ) {
        let axis = BaldiOpeningMarker.containerAxis(for: placement)
        guard rect.width >= 11, rect.height >= 11 else { return }

        if axis == 2 {
            let point = CGPoint(x: rect.minX + min(10, rect.width * 0.22), y: rect.minY + min(10, rect.height * 0.22))
            let badge = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
            context.fill(Path(ellipseIn: badge), with: .color(.white.opacity(0.78)))
            context.stroke(Path(ellipseIn: badge), with: .color(.primary.opacity(0.75)), lineWidth: 1)
            context.draw(
                Text("↕")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.yellow),
                at: point
            )
            return
        }

        let inset = min(7, (axis == 0 ? rect.width : rect.height) * 0.2)
        let start: CGPoint
        let end: CGPoint
        if axis == 0 {
            let y = rect.minY + min(7, rect.height * 0.2)
            start = CGPoint(x: rect.minX + inset, y: y)
            end = CGPoint(x: rect.maxX - inset, y: y)
        } else {
            let x = rect.minX + min(7, rect.width * 0.2)
            start = CGPoint(x: x, y: rect.minY + inset)
            end = CGPoint(x: x, y: rect.maxY - inset)
        }
        drawDoubleArrow(from: start, to: end, context: context)
    }

    private func drawDoubleArrow(
        from start: CGPoint,
        to end: CGPoint,
        context: GraphicsContext
    ) {
        var line = Path()
        line.move(to: start)
        line.addLine(to: end)
        context.stroke(line, with: .color(.primary.opacity(0.72)), lineWidth: 4)
        context.stroke(line, with: .color(.yellow), lineWidth: 2.2)

        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length
        let uy = dy / length
        let px = -uy
        let py = ux
        for (tip, direction) in [(end, -1.0), (start, 1.0)] {
            let base = CGPoint(x: tip.x + ux * 4.5 * direction, y: tip.y + uy * 4.5 * direction)
            var triangle = Path()
            triangle.move(to: tip)
            triangle.addLine(to: CGPoint(x: base.x + px * 2.5, y: base.y + py * 2.5))
            triangle.addLine(to: CGPoint(x: base.x - px * 2.5, y: base.y - py * 2.5))
            triangle.closeSubpath()
            context.fill(triangle, with: .color(.yellow))
            context.stroke(triangle, with: .color(.primary.opacity(0.72)), lineWidth: 0.8)
        }
    }

    private var directSupporters: Set<UUID> {
        Set(
            layer.placements.flatMap {
                BaldiVerticalSupport.report(for: $0, among: solution.placements).supporterIDs
            }
        )
    }

    private func footprint(
        of placement: BaldiPlacement,
        in shell: CGRect,
        scale: CGFloat
    ) -> CGRect {
        CGRect(
            x: shell.minX + placement.origin.x * scale,
            y: shell.minY + placement.origin.y * scale,
            width: placement.extent.x * scale,
            height: placement.extent.y * scale
        )
    }

    private var accessibilityDescription: String {
        let packageNames = layer.placements.map { placement in
            let number = numbering[placement.id].map(String.init) ?? ""
            return "package \(number), \(placement.name)"
        }
        let support = layer.isFloorLayer
            ? "supported by the payload floor"
            : "with direct supporters outlined"
        return "Top view of layer \(layer.index + 1), \(support): "
            + packageNames.joined(separator: ", ") + "."
    }
}

// MARK: - SceneKit bridge

private struct BaldiPackingSceneView: UIViewRepresentable {
    let solution: BaldiSolution
    let colours: [UUID: Color]
    @Binding var highlightedPackageID: UUID?
    let selectedLayerIndex: Int?
    let cameraResetToken: Int

    final class Coordinator: NSObject {
        let cameraNode = SCNNode()
        var lastResetToken: Int?
        var selectPackage: (UUID?) -> Void = { _ in }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let view = recognizer.view as? SCNView else { return }
            let point = recognizer.location(in: view)
            for hit in view.hitTest(point, options: nil) {
                var candidate: SCNNode? = hit.node
                while let node = candidate {
                    if let name = node.name,
                       name.hasPrefix("package-"),
                       let id = UUID(uuidString: String(name.dropFirst("package-".count))) {
                        selectPackage(id)
                        return
                    }
                    candidate = node.parent
                }
            }
            selectPackage(nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        let scene = SCNScene()
        view.scene = scene
        view.backgroundColor = .clear
        view.isOpaque = false
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.inertiaEnabled = true
        view.preferredFramesPerSecond = 30
        context.coordinator.selectPackage = selectionHandler
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        let camera = SCNCamera()
        camera.fieldOfView = 52
        camera.automaticallyAdjustsZRange = true
        context.coordinator.cameraNode.camera = camera
        context.coordinator.cameraNode.name = "packing-camera"
        scene.rootNode.addChildNode(context.coordinator.cameraNode)
        view.pointOfView = context.coordinator.cameraNode

        addLighting(to: scene.rootNode)
        rebuildContent(in: view)
        resetCamera(in: view, coordinator: context.coordinator)
        context.coordinator.lastResetToken = cameraResetToken

        view.isAccessibilityElement = true
        view.accessibilityTraits = .image
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityHint = "Tap a package to reveal its name. Drag to rotate, pinch to zoom, or use two fingers to move the view."
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.selectPackage = selectionHandler
        rebuildContent(in: view)
        view.accessibilityLabel = accessibilityLabel

        if context.coordinator.lastResetToken != cameraResetToken {
            resetCamera(in: view, coordinator: context.coordinator)
            context.coordinator.lastResetToken = cameraResetToken
        }
    }

    private var selectionHandler: (UUID?) -> Void {
        { id in
            guard let id else {
                highlightedPackageID = nil
                return
            }
            highlightedPackageID = highlightedPackageID == id ? nil : id
        }
    }

    private func rebuildContent(in view: SCNView) {
        guard let root = view.scene?.rootNode else { return }
        root.childNode(withName: "packing-content", recursively: false)?.removeFromParentNode()

        let content = SCNNode()
        content.name = "packing-content"
        root.addChildNode(content)

        let metrics = SceneMetrics(knapsack: solution.knapsack)
        SceneBuilder.addContainer(to: content, metrics: metrics)
        SceneBuilder.addBalanceMarkers(solution: solution, to: content, metrics: metrics)

        let layers = BaldiLoadingGuide.layers(for: solution)
        let numbering = BaldiLoadingGuide.numbering(for: solution)
        let layerByPackage = Dictionary(
            uniqueKeysWithValues: layers.flatMap { layer in
                layer.placements.map { ($0.id, layer.index) }
            }
        )
        let selectedLayer = selectedLayerIndex.flatMap { selected in
            layers.first { $0.index == selected }
        }
        let selectedSupporters = Set(
            selectedLayer?.placements.flatMap {
                BaldiVerticalSupport.report(for: $0, among: solution.placements).supporterIDs
            } ?? []
        )

        for placement in BaldiLoadingGuide.orderedPlacements(in: solution) {
            let packageLayer = layerByPackage[placement.id]
            let presentation = PackagePresentation(
                isInSelectedLayer: selectedLayer.map { packageLayer == $0.index } ?? true,
                isDirectSupporter: selectedSupporters.contains(placement.id),
                isHighlighted: highlightedPackageID == placement.id,
                hasLayerSelection: selectedLayer != nil,
                hasPackageHighlight: highlightedPackageID != nil
            )
            SceneBuilder.addPackage(
                placement,
                number: numbering[placement.id],
                colour: UIColor(colours[placement.id] ?? .accentColor),
                presentation: presentation,
                to: content,
                metrics: metrics
            )
        }
    }

    private func addLighting(to root: SCNNode) {
        let ambientNode = SCNNode()
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 650
        ambient.color = UIColor(white: 0.82, alpha: 1)
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        let keyNode = SCNNode()
        let key = SCNLight()
        key.type = .directional
        key.intensity = 1_000
        key.castsShadow = true
        key.shadowRadius = 5
        key.shadowColor = UIColor.black.withAlphaComponent(0.22)
        keyNode.light = key
        keyNode.eulerAngles = SCNVector3(-0.85, 0.65, 0)
        root.addChildNode(keyNode)
    }

    private func resetCamera(in view: SCNView, coordinator: Coordinator) {
        let metrics = SceneMetrics(knapsack: solution.knapsack)
        let radius = max(
            2,
            sqrt(
                metrics.containerWidth * metrics.containerWidth
                    + metrics.containerHeight * metrics.containerHeight
                    + metrics.containerDepth * metrics.containerDepth
            ) / 2
        )
        let halfFieldOfView = Float((52.0 / 2) * .pi / 180)
        let distance = Float(radius) / tan(halfFieldOfView) * 1.35
        let direction = SIMD3<Float>(1.05, 0.78, 1.25)
        let normalised = direction / simd_length(direction)

        coordinator.cameraNode.simdPosition = normalised * distance
        coordinator.cameraNode.look(at: SCNVector3Zero)
        view.defaultCameraController.target = SCNVector3Zero
    }

    private var accessibilityLabel: String {
        let layerDescription: String
        if let selectedLayerIndex {
            layerDescription = "Layer \(selectedLayerIndex + 1) is highlighted and its direct supporters remain visible."
        } else {
            layerDescription = "All loading layers are shown."
        }
        let selectedName = highlightedPackageID.flatMap { id in
            solution.placements.first { $0.id == id }.map {
                "Selected package \($0.name). \(BaldiOpeningMarker.description(for: $0))."
            }
        } ?? "No package is selected."
        let packageNames = BaldiLoadingGuide.orderedPlacements(in: solution).enumerated().map {
            "package \($0.offset + 1), \($0.element.name)"
        }.joined(separator: ", ")
        return "Interactive 3D view of \(solution.loadedCount) packed packages: \(packageNames). \(layerDescription) \(selectedName) The orange marker is the actual cargo centre of mass, the purple rings are the ideal target, and the green box is the allowable domain."
    }
}

// MARK: - Scene construction

private struct SceneMetrics {
    let scale: CGFloat
    let containerWidth: CGFloat
    let containerHeight: CGFloat
    let containerDepth: CGFloat
    let edgeThickness: CGFloat

    init(knapsack: BaldiKnapsack) {
        let width = max(CGFloat(knapsack.size.x), 1)
        let depth = max(CGFloat(knapsack.size.y), 1)
        let height = max(CGFloat(knapsack.size.z), 1)
        scale = 8 / max(width, depth, height)
        containerWidth = width * scale
        containerHeight = height * scale
        containerDepth = depth * scale
        edgeThickness = max(0.012, min(containerWidth, containerHeight, containerDepth) * 0.006)
    }

    func point(_ point: SIMD3<Double>) -> SCNVector3 {
        SCNVector3(
            CGFloat(point.x) * scale - containerWidth / 2,
            CGFloat(point.z) * scale - containerHeight / 2,
            CGFloat(point.y) * scale - containerDepth / 2
        )
    }
}

private struct PackagePresentation {
    let isInSelectedLayer: Bool
    let isDirectSupporter: Bool
    let isHighlighted: Bool
    let hasLayerSelection: Bool
    let hasPackageHighlight: Bool

    var opacity: CGFloat {
        if isHighlighted { return 1 }
        if hasLayerSelection {
            if isInSelectedLayer { return 0.88 }
            if isDirectSupporter { return 0.42 }
            return 0.09
        }
        return hasPackageHighlight ? 0.28 : 0.8
    }

    var showsLabel: Bool {
        !hasLayerSelection || isInSelectedLayer || isHighlighted
    }
}

private enum SceneBuilder {
    static func addContainer(to root: SCNNode, metrics: SceneMetrics) {
        let floor = SCNBox(
            width: metrics.containerWidth,
            height: metrics.edgeThickness,
            length: metrics.containerDepth,
            chamferRadius: 0
        )
        floor.firstMaterial = material(
            colour: UIColor.secondarySystemFill,
            opacity: 0.42,
            lightingModel: .constant
        )
        let floorNode = SCNNode(geometry: floor)
        floorNode.position.y = Float(-metrics.containerHeight / 2)
        root.addChildNode(floorNode)

        addBoxEdges(
            width: metrics.containerWidth,
            height: metrics.containerHeight,
            depth: metrics.containerDepth,
            centre: SCNVector3Zero,
            thickness: metrics.edgeThickness,
            colour: UIColor.secondaryLabel.withAlphaComponent(0.65),
            to: root
        )
    }

    static func addBalanceMarkers(
        solution: BaldiSolution,
        to root: SCNNode,
        metrics: SceneMetrics
    ) {
        let lower = solution.knapsack.domainLower
        let upper = solution.knapsack.domainUpper
        let domainSize = SIMD3<Double>(
            max(upper.x - lower.x, 0),
            max(upper.y - lower.y, 0),
            max(upper.z - lower.z, 0)
        )
        let minimumDomainSide = metrics.edgeThickness * 2
        let domainWidth = max(CGFloat(domainSize.x) * metrics.scale, minimumDomainSide)
        let domainHeight = max(CGFloat(domainSize.z) * metrics.scale, minimumDomainSide)
        let domainDepth = max(CGFloat(domainSize.y) * metrics.scale, minimumDomainSide)
        let domainCentre = metrics.point((lower + upper) / 2)

        let domain = SCNBox(
            width: domainWidth,
            height: domainHeight,
            length: domainDepth,
            chamferRadius: 0
        )
        let domainMaterial = material(
            colour: UIColor.systemGreen,
            opacity: 0.1,
            lightingModel: .constant
        )
        domainMaterial.writesToDepthBuffer = false
        domain.firstMaterial = domainMaterial
        let domainNode = SCNNode(geometry: domain)
        domainNode.position = domainCentre
        domainNode.renderingOrder = 20
        root.addChildNode(domainNode)
        addBoxEdges(
            width: domainWidth,
            height: domainHeight,
            depth: domainDepth,
            centre: domainCentre,
            thickness: metrics.edgeThickness * 0.65,
            colour: UIColor.systemGreen.withAlphaComponent(0.72),
            to: root,
            renderingOrder: 21
        )

        let markerRadius = max(0.105, metrics.edgeThickness * 5)
        let actualGeometry = SCNSphere(radius: markerRadius)
        let actualMaterial = material(
            colour: UIColor.systemOrange,
            opacity: 1,
            lightingModel: .constant
        )
        actualMaterial.emission.contents = UIColor.systemOrange.withAlphaComponent(0.8)
        // A cargo COM commonly lies inside a package volume. Keep the marker readable through the
        // boxes while its position remains fixed in the scene's coordinate system.
        actualMaterial.readsFromDepthBuffer = false
        actualMaterial.writesToDepthBuffer = false
        actualGeometry.firstMaterial = actualMaterial
        let actualNode = SCNNode(geometry: actualGeometry)
        actualNode.position = metrics.point(solution.centreOfMass)
        actualNode.renderingOrder = 40
        root.addChildNode(actualNode)

        let targetPosition = metrics.point(solution.knapsack.idealCentreOfMass)
        for rotation in [SCNVector3Zero, SCNVector3(0, 0, Float.pi / 2)] {
            let ring = SCNTorus(ringRadius: markerRadius * 1.65, pipeRadius: markerRadius * 0.16)
            let targetMaterial = material(
                colour: UIColor.systemPurple,
                opacity: 1,
                lightingModel: .constant
            )
            targetMaterial.emission.contents = UIColor.systemPurple.withAlphaComponent(0.65)
            targetMaterial.readsFromDepthBuffer = false
            targetMaterial.writesToDepthBuffer = false
            ring.firstMaterial = targetMaterial
            let ringNode = SCNNode(geometry: ring)
            ringNode.position = targetPosition
            ringNode.eulerAngles = rotation
            ringNode.renderingOrder = 39
            root.addChildNode(ringNode)
        }
    }

    static func addPackage(
        _ placement: BaldiPlacement,
        number: Int?,
        colour: UIColor,
        presentation: PackagePresentation,
        to root: SCNNode,
        metrics: SceneMetrics
    ) {
        let width = CGFloat(placement.size.x) * metrics.scale
        let height = CGFloat(placement.size.z) * metrics.scale
        let depth = CGFloat(placement.size.y) * metrics.scale
        let package = SCNBox(
            width: width,
            height: height,
            length: depth,
            chamferRadius: min(width, height, depth) * 0.025
        )
        let packageMaterial = material(
            colour: colour,
            opacity: presentation.opacity,
            lightingModel: .physicallyBased
        )
        packageMaterial.roughness.contents = 0.78
        packageMaterial.metalness.contents = 0
        if presentation.isHighlighted {
            packageMaterial.emission.contents = colour.withAlphaComponent(0.32)
        }
        package.firstMaterial = packageMaterial

        let node = SCNNode(geometry: package)
        node.name = "package-\(placement.id.uuidString)"
        node.position = metrics.point(placement.centreOfMass)
        root.addChildNode(node)

        addOpeningMarker(
            for: placement,
            width: width,
            height: height,
            depth: depth,
            centre: node.simdPosition,
            opacity: max(0.16, presentation.opacity),
            thickness: metrics.edgeThickness,
            to: root
        )

        if presentation.isHighlighted {
            addBoxEdges(
                width: width + metrics.edgeThickness,
                height: height + metrics.edgeThickness,
                depth: depth + metrics.edgeThickness,
                centre: node.position,
                thickness: metrics.edgeThickness * 1.35,
                colour: UIColor.label,
                to: root,
                renderingOrder: 30
            )
        }

        guard presentation.showsLabel, let number else { return }
        addNumberLabel(
            number,
            packageID: placement.id,
            above: CGFloat(node.position.y) + height / 2,
            x: CGFloat(node.position.x),
            z: CGFloat(node.position.z),
            metrics: metrics,
            opacity: max(0.5, presentation.opacity),
            to: root
        )
    }

    private static func addNumberLabel(
        _ number: Int,
        packageID: UUID,
        above top: CGFloat,
        x: CGFloat,
        z: CGFloat,
        metrics: SceneMetrics,
        opacity: CGFloat,
        to root: SCNNode
    ) {
        let text = SCNText(string: String(number), extrusionDepth: 0.012)
        text.font = UIFont.monospacedDigitSystemFont(ofSize: 1, weight: .bold)
        text.flatness = 0.08
        text.firstMaterial = material(
            colour: UIColor.label,
            opacity: opacity,
            lightingModel: .constant
        )

        let textNode = SCNNode(geometry: text)
        textNode.name = "package-\(packageID.uuidString)"
        let bounds = text.boundingBox
        textNode.pivot = SCNMatrix4MakeTranslation(
            (bounds.min.x + bounds.max.x) / 2,
            bounds.min.y,
            0
        )
        let scale = max(0.18, metrics.edgeThickness * 8)
        textNode.scale = SCNVector3(scale, scale, scale)
        textNode.position = SCNVector3(x, top + scale * 0.12, z)
        textNode.constraints = [SCNBillboardConstraint()]
        textNode.renderingOrder = 50
        root.addChildNode(textNode)
    }

    private static func addOpeningMarker(
        for placement: BaldiPlacement,
        width: CGFloat,
        height: CGFloat,
        depth: CGFloat,
        centre: SIMD3<Float>,
        opacity: CGFloat,
        thickness: CGFloat,
        to root: SCNNode
    ) {
        let axis = BaldiOpeningMarker.containerAxis(for: placement)
        let direction: SIMD3<Float>
        let length: Float
        let markerCentre: SIMD3<Float>
        let surfaceOffset = Float(max(0.025, thickness * 1.8))

        switch axis {
        case 0:
            direction = SIMD3(1, 0, 0)
            length = Float(width * 0.72)
            markerCentre = centre + SIMD3(0, Float(height) / 2 + surfaceOffset, 0)
        case 1:
            direction = SIMD3(0, 0, 1)
            length = Float(depth * 0.72)
            markerCentre = centre + SIMD3(0, Float(height) / 2 + surfaceOffset, 0)
        default:
            direction = SIMD3(0, 1, 0)
            length = Float(height * 0.72)
            markerCentre = centre + SIMD3(0, 0, Float(depth) / 2 + surfaceOffset)
        }

        guard length > 0.04 else { return }
        let start = markerCentre - direction * (length / 2)
        let end = markerCentre + direction * (length / 2)
        let markerMaterial = material(
            colour: UIColor.systemYellow,
            opacity: opacity,
            lightingModel: .constant
        )
        markerMaterial.emission.contents = UIColor.systemYellow.withAlphaComponent(0.6)
        markerMaterial.readsFromDepthBuffer = false
        markerMaterial.writesToDepthBuffer = false
        let packageName = "package-\(placement.id.uuidString)"
        let radius = Float(max(0.012, thickness * 0.7))

        let shaft = SCNCylinder(radius: CGFloat(radius), height: CGFloat(length))
        shaft.firstMaterial = markerMaterial
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.name = packageName
        shaftNode.simdPosition = markerCentre
        shaftNode.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: direction)
        shaftNode.renderingOrder = 45
        root.addChildNode(shaftNode)

        let headHeight = max(radius * 4.2, 0.07)
        let headRadius = max(radius * 2.5, 0.04)
        for (tip, outward) in [(end, direction), (start, -direction)] {
            let cone = SCNCone(
                topRadius: 0,
                bottomRadius: CGFloat(headRadius),
                height: CGFloat(headHeight)
            )
            cone.firstMaterial = markerMaterial
            let headNode = SCNNode(geometry: cone)
            headNode.name = packageName
            headNode.simdPosition = tip - outward * (headHeight / 2)
            headNode.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: outward)
            headNode.renderingOrder = 45
            root.addChildNode(headNode)
        }
    }

    private static func addBoxEdges(
        width: CGFloat,
        height: CGFloat,
        depth: CGFloat,
        centre: SCNVector3,
        thickness: CGFloat,
        colour: UIColor,
        to root: SCNNode,
        renderingOrder: Int = 10
    ) {
        let edgeMaterial = material(colour: colour, opacity: 1, lightingModel: .constant)

        func addEdge(
            width edgeWidth: CGFloat,
            height edgeHeight: CGFloat,
            depth edgeDepth: CGFloat,
            offset: SCNVector3
        ) {
            let box = SCNBox(
                width: max(edgeWidth, thickness),
                height: max(edgeHeight, thickness),
                length: max(edgeDepth, thickness),
                chamferRadius: thickness / 3
            )
            box.firstMaterial = edgeMaterial
            let node = SCNNode(geometry: box)
            node.position = SCNVector3(
                centre.x + offset.x,
                centre.y + offset.y,
                centre.z + offset.z
            )
            node.renderingOrder = renderingOrder
            root.addChildNode(node)
        }

        for y in [-height / 2, height / 2] {
            for z in [-depth / 2, depth / 2] {
                addEdge(width: width, height: thickness, depth: thickness, offset: SCNVector3(0, y, z))
            }
        }
        for x in [-width / 2, width / 2] {
            for z in [-depth / 2, depth / 2] {
                addEdge(width: thickness, height: height, depth: thickness, offset: SCNVector3(x, 0, z))
            }
        }
        for x in [-width / 2, width / 2] {
            for y in [-height / 2, height / 2] {
                addEdge(width: thickness, height: thickness, depth: depth, offset: SCNVector3(x, y, 0))
            }
        }
    }

    private static func material(
        colour: UIColor,
        opacity: CGFloat,
        lightingModel: SCNMaterial.LightingModel
    ) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = colour
        material.transparency = opacity
        material.lightingModel = lightingModel
        material.isDoubleSided = true
        return material
    }
}
