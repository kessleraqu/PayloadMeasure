import SceneKit
import SwiftUI
import UIKit

// Drawings for the 3D knapsack result: a rotatable SceneKit view of the whole load, and flat
// per-layer footprints for the step-by-step loading guide.
//
// In:  a BaldiSolution, a colour per package and the current selection.
// Out: on screen only.

nonisolated struct BaldiLoadingLayer: Identifiable {
    let index: Int
    let baseHeight: Double
    let placements: [BaldiPlacement]

    var id: Int { index }
    var isFloorLayer: Bool {
        abs(baseHeight) <= BaldiVerticalSupport.contactTolerance
    }
}

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

/// Which way a package's measured length is pointing once placed. Length is the box's longest side
/// and runs parallel to its opening, so this is what the operator lines up when loading.
nonisolated enum BaldiOpeningMarker {
    static func containerAxis(for placement: BaldiPlacement) -> Int {
        placement.rotation.sourceAxis.firstIndex(of: 0) ?? 0
    }

    /// Container-space axes for the package's two L x W faces and their centre line.
    ///
    /// `sourceAxis[c]` is the measured package axis carried by container axis `c`. The two
    /// L x W faces are therefore normal to measured height (axis 2), while the line on them runs
    /// along measured length (axis 0). Keeping this mapping in one place prevents the 3D guide from
    /// silently treating every package as though its L x W faces were horizontal.
    static func faceAxes(
        for placement: BaldiPlacement
    ) -> (normal: Int, length: Int, width: Int)? {
        let axes = placement.rotation.sourceAxis
        guard let normal = axes.firstIndex(of: 2),
              let length = axes.firstIndex(of: 0),
              let width = axes.firstIndex(of: 1) else { return nil }
        return (normal, length, width)
    }

    /// L × W faces that touch another package. Their orientation line remains useful, but is dotted
    /// to show that the physical face is covered rather than exposed.
    static func coveredFaceSigns(
        for placement: BaldiPlacement,
        among placements: [BaldiPlacement],
        tolerance: Double = 1e-6
    ) -> Set<Int> {
        guard let axes = faceAxes(for: placement) else { return [] }
        let normal = axes.normal
        let sideAxes = [0, 1, 2].filter { $0 != normal }
        var covered: Set<Int> = []
        for other in placements where other.id != placement.id {
            let overlapsFace = sideAxes.allSatisfy { axis in
                min(placement.maximum[axis], other.maximum[axis])
                    - max(placement.origin[axis], other.origin[axis]) > tolerance
            }
            guard overlapsFace else { continue }
            if abs(other.maximum[normal] - placement.origin[normal]) <= tolerance {
                covered.insert(-1)
            }
            if abs(other.origin[normal] - placement.maximum[normal]) <= tolerance {
                covered.insert(1)
            }
        }
        return covered
    }

    static func description(for placement: BaldiPlacement) -> String {
        guard !placement.isOwnBox else {
            return "Already its own box — no catalogue opening to line up"
        }
        return switch containerAxis(for: placement) {
        case 0: "Opening and length along the container"
        case 1: "Opening and length across the container"
        default: "Opening and length vertical"
        }
    }
}

struct BaldiPlanView: View {
    let solution: BaldiSolution
    let colours: [UUID: Color]
    @Binding var highlightedPackageID: UUID?

    @State private var cameraResetToken = 0

    var body: some View {
        ZStack {
            BaldiPackingSceneView(
                solution: solution,
                colours: colours,
                highlightedPackageID: $highlightedPackageID,
                cameraResetToken: cameraResetToken
            )
            .frame(height: 380)
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
        .overlay(alignment: .bottom) {
            // Whichever package was tapped, said loudly and in that package's own colour. A caption in
            // the corner made the operator hunt for the answer to the question they had just asked.
            if let placement = selectedPlacement {
                let colour = colours[placement.id] ?? .accentColor
                VStack(spacing: 3) {
                    HStack(spacing: 8) {
                        Text("#\(numbering[placement.id] ?? 0)")
                            .font(.title3.weight(.heavy).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .frame(minWidth: 38, minHeight: 30)
                            .background(colour, in: .rect(cornerRadius: 8))
                        Text(placement.name)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(colour)
                            .lineLimit(2)
                            .minimumScaleFactor(0.6)
                            .multilineTextAlignment(.leading)
                    }
                    Text(BaldiOpeningMarker.description(for: placement))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial, in: .rect(cornerRadius: 12))
                .padding(8)
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

    /// Shades the opening side of the footprint and rules a darker line straight across the package
    /// along its length, which is the direction the operator has to line the box up with.
    ///
    /// Drawn only for a package boxed from the catalogue: the line marks the length/opening
    /// convention of one of *our* presets, which is not a fact about an object that already arrived
    /// as its own box — nothing chose an opening for it to match.
    private func drawOpeningMarker(
        for placement: BaldiPlacement,
        in rect: CGRect,
        context: GraphicsContext
    ) {
        guard !placement.isOwnBox else { return }
        let axis = BaldiOpeningMarker.containerAxis(for: placement)
        guard rect.width >= 11, rect.height >= 11 else { return }

        // Length is vertical, so neither the opening side nor the length shows in a plan view.
        if axis == 2 {
            let inset = min(3.5, min(rect.width, rect.height) * 0.16)
            context.stroke(
                Path(roundedRect: rect.insetBy(dx: inset, dy: inset), cornerRadius: 2),
                with: .color(.black.opacity(0.55)),
                style: StrokeStyle(lineWidth: 1.6, dash: [3, 2.5])
            )
            return
        }

        let bandDepth = min(7, (axis == 0 ? rect.height : rect.width) * 0.3)
        let band = axis == 0
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: bandDepth)
            : CGRect(x: rect.minX, y: rect.minY, width: bandDepth, height: rect.height)
        context.fill(Path(band), with: .color(.black.opacity(0.34)))

        let inset = min(2.5, (axis == 0 ? rect.width : rect.height) * 0.08)
        var length = Path()
        if axis == 0 {
            length.move(to: CGPoint(x: rect.minX + inset, y: rect.midY))
            length.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.midY))
        } else {
            length.move(to: CGPoint(x: rect.midX, y: rect.minY + inset))
            length.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - inset))
        }
        let topLWFaceIsCovered = BaldiOpeningMarker.faceAxes(for: placement)?.normal == 2
            && BaldiOpeningMarker.coveredFaceSigns(
                for: placement,
                among: solution.placements
            ).contains(1)
        context.stroke(
            length,
            with: .color(.black.opacity(0.82)),
            style: StrokeStyle(
                lineWidth: 2.4,
                lineCap: .round,
                dash: topLWFaceIsCovered ? [5, 4] : []
            )
        )
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
    let cameraResetToken: Int

    final class Coordinator: NSObject {
        let cameraNode = SCNNode()
        var lastResetToken: Int?
        var lastSceneState: SceneState?
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
        rebuildContentIfNeeded(in: view, coordinator: context.coordinator, force: true)
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
        rebuildContentIfNeeded(in: view, coordinator: context.coordinator)
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

    /// SwiftUI may call `updateUIView` for surrounding scroll and animation state which has nothing
    /// to do with this scene. Removing and recreating the complete node tree on every such update
    /// produced a blank/double-rendered frame while the user rotated it. Rebuild only when a value
    /// which changes the drawing has actually changed.
    private func rebuildContentIfNeeded(
        in view: SCNView,
        coordinator: Coordinator,
        force: Bool = false
    ) {
        guard let root = view.scene?.rootNode else { return }
        let state = SceneState(
            solution: solution,
            highlightedPackageID: highlightedPackageID,
            colours: colours,
            interfaceStyle: view.traitCollection.userInterfaceStyle.rawValue
        )
        guard force || coordinator.lastSceneState != state else { return }

        let content = SCNNode()
        content.name = "packing-content"

        let metrics = SceneMetrics(knapsack: solution.knapsack)
        SceneBuilder.addContainer(to: content, metrics: metrics)
        SceneBuilder.addBalanceMarkers(solution: solution, to: content, metrics: metrics)

        let numbering = BaldiLoadingGuide.numbering(for: solution)

        for placement in BaldiLoadingGuide.orderedPlacements(in: solution) {
            let presentation = PackagePresentation(
                isHighlighted: highlightedPackageID == placement.id,
                hasPackageHighlight: highlightedPackageID != nil
            )
            SceneBuilder.addPackage(
                placement,
                among: solution.placements,
                number: numbering[placement.id],
                colour: UIColor(colours[placement.id] ?? .accentColor),
                presentation: presentation,
                to: content,
                metrics: metrics
            )
        }

        // Build off-tree, then swap both trees in one transaction. SceneKit never renders the
        // half-built scene and there is no implicit fade between two identical sets of geometry.
        let previous = root.childNode(withName: "packing-content", recursively: false)
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        root.addChildNode(content)
        previous?.removeFromParentNode()
        SCNTransaction.commit()
        coordinator.lastSceneState = state
    }

    private func addLighting(to root: SCNNode) {
        let ambientNode = SCNNode()
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 850
        ambient.color = UIColor(white: 0.94, alpha: 1)
        ambientNode.light = ambient
        root.addChildNode(ambientNode)

        let keyNode = SCNNode()
        let key = SCNLight()
        key.type = .directional
        key.intensity = 650
        // This is an instructional diagram, not a photorealistic render. Shadow maps on adjacent
        // cuboids caused dark seams and shimmer as the camera moved.
        key.castsShadow = false
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
        let layerDescription = "All loading layers are shown together."
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

private struct SceneState: Equatable {
    struct Placement: Equatable {
        let id: UUID
        let origin: SIMD3<Double>
        let size: SIMD3<Int>
        let sourceAxis: [Int]
    }

    let knapsackSize: SIMD3<Int>
    let domainLower: SIMD3<Double>
    let domainUpper: SIMD3<Double>
    let idealCentreOfMass: SIMD3<Double>
    let actualCentreOfMass: SIMD3<Double>
    let placements: [Placement]
    let colourDescriptions: [String]
    let highlightedPackageID: UUID?
    let interfaceStyle: Int

    init(
        solution: BaldiSolution,
        highlightedPackageID: UUID?,
        colours: [UUID: Color],
        interfaceStyle: Int
    ) {
        knapsackSize = solution.knapsack.size
        domainLower = solution.knapsack.domainLower
        domainUpper = solution.knapsack.domainUpper
        idealCentreOfMass = solution.knapsack.idealCentreOfMass
        actualCentreOfMass = solution.centreOfMass
        placements = BaldiLoadingGuide.orderedPlacements(in: solution).map {
            Placement(
                id: $0.id,
                origin: $0.origin,
                size: $0.size,
                sourceAxis: $0.rotation.sourceAxis
            )
        }
        colourDescriptions = placements.map {
            String(reflecting: colours[$0.id] ?? Color.accentColor)
        }
        self.highlightedPackageID = highlightedPackageID
        self.interfaceStyle = interfaceStyle
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
    let isHighlighted: Bool
    let hasPackageHighlight: Bool

    /// Visible boxes stay opaque. Muting by colour rather than alpha avoids SceneKit having to sort
    /// six transparent faces for every touching package on every camera frame.
    var softening: CGFloat {
        if isHighlighted { return 0 }
        return hasPackageHighlight ? 0.52 : 0.06
    }

    var showsLabel: Bool { true }
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
            colour: UIColor(white: 0.22, alpha: 1),
            opacity: 0.45,
            lightingModel: .constant
        )
        let floorNode = SCNNode(geometry: floor)
        // Its top sits a hair below the package bottoms rather than intersecting them.
        floorNode.position.y = Float(
            -metrics.containerHeight / 2 - metrics.edgeThickness / 2 - metrics.edgeThickness * 0.02
        )
        root.addChildNode(floorNode)

        addBoxEdges(
            width: metrics.containerWidth,
            height: metrics.containerHeight,
            depth: metrics.containerDepth,
            centre: SCNVector3Zero,
            thickness: metrics.edgeThickness,
            colour: UIColor.systemGray2,
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

        // A transparent enclosing solid tinted whichever package faces happened to be behind it and
        // had to be depth-sorted on every camera move. The wireframe communicates the same admissible
        // region without changing any package colour.
        addBoxEdges(
            width: domainWidth,
            height: domainHeight,
            depth: domainDepth,
            centre: domainCentre,
            thickness: metrics.edgeThickness * 0.65,
            colour: UIColor.systemGreen,
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
        among allPlacements: [BaldiPlacement],
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
        package.materials = packageMaterials(
            for: placement,
            among: allPlacements,
            colour: colour,
            softening: presentation.softening,
            highlighted: presentation.isHighlighted
        )

        let node = SCNNode(geometry: package)
        node.name = "package-\(placement.id.uuidString)"
        node.position = metrics.point(placement.centreOfMass)
        root.addChildNode(node)

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
            to: root
        )
    }

    private static func softened(_ colour: UIColor, by amount: CGFloat) -> UIColor {
        guard amount > 0 else { return colour }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard colour.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else { return colour }
        return UIColor(
            hue: hue,
            saturation: saturation * (1 - amount * 0.72),
            brightness: brightness + (1 - brightness) * amount * 0.32,
            alpha: alpha
        )
    }

    /// A darker tone of the same hue, so the marker still reads as part of its package.
    private static func darkened(_ colour: UIColor, by amount: CGFloat) -> UIColor {
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

    private static func addNumberLabel(
        _ number: Int,
        packageID: UUID,
        above top: CGFloat,
        x: CGFloat,
        z: CGFloat,
        metrics: SceneMetrics,
        to root: SCNNode
    ) {
        let text = SCNText(string: String(number), extrusionDepth: 0.012)
        text.font = UIFont.monospacedDigitSystemFont(ofSize: 1, weight: .bold)
        text.flatness = 0.08
        text.firstMaterial = material(
            colour: UIColor.label,
            opacity: 1,
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

    /// Matches the AR package without adding geometry on top of, inside, or outside the cuboid.
    /// Both true L x W faces get a shaded material with a centred length line baked into it. Because
    /// these are the SCNBox's own faces, touching packages cannot create coplanar marker surfaces or
    /// have a marker protrude into their neighbour.
    private static func packageMaterials(
        for placement: BaldiPlacement,
        among allPlacements: [BaldiPlacement],
        colour: UIColor,
        softening: CGFloat,
        highlighted: Bool
    ) -> [SCNMaterial] {
        let baseColour = softened(colour, by: softening)
        let base = material(colour: baseColour, opacity: 1, lightingModel: .lambert)
        base.ambient.contents = baseColour
        if highlighted {
            base.emission.contents = colour.withAlphaComponent(0.32)
        }

        // SCNBox material order is front(+z), right(+x), back(-z), left(-x), top(+y), bottom(-y).
        var result = Array(repeating: base, count: 6)
        // The length/opening convention only describes one of our own catalogue presets: an object
        // that already arrived as its own box was never given an opening to match.
        guard !placement.isOwnBox,
              let axes = BaldiOpeningMarker.faceAxes(for: placement) else { return result }
        let markedFaces: [(index: Int, sign: Int)]
        let lineIsHorizontal: Bool
        switch axes.normal {
        case 0:
            markedFaces = [(1, 1), (3, -1)]
            lineIsHorizontal = axes.length == 1
        case 1:
            markedFaces = [(0, 1), (2, -1)]
            lineIsHorizontal = axes.length == 0
        default:
            markedFaces = [(4, 1), (5, -1)]
            lineIsHorizontal = axes.length == 0
        }

        let covered = BaldiOpeningMarker.coveredFaceSigns(
            for: placement,
            among: allPlacements
        )
        for face in markedFaces {
            result[face.index] = markedFaceMaterial(
                colour: baseColour,
                lineIsHorizontal: lineIsHorizontal,
                isDotted: covered.contains(face.sign)
            )
        }
        return result
    }

    /// No highlight wash here, unlike the package's other faces: an emission tint over this baked
    /// texture is what used to fade the line out right when selecting a package was supposed to make
    /// it easier to read. Selection is already shown unambiguously by the highlighted edges
    /// `addBoxEdges` draws around the whole package, so the opening line stays at full contrast.
    private static func markedFaceMaterial(
        colour: UIColor,
        lineIsHorizontal: Bool,
        isDotted: Bool
    ) -> SCNMaterial {
        let faceColour = darkened(colour, by: 0.4)
        let lineColour = darkened(colour, by: 0.75)
        let side: CGFloat = 96
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format
        ).image { context in
            faceColour.setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            let inset = side * 0.05
            let path = UIBezierPath()
            if lineIsHorizontal {
                path.move(to: CGPoint(x: inset, y: side / 2))
                path.addLine(to: CGPoint(x: side - inset, y: side / 2))
            } else {
                path.move(to: CGPoint(x: side / 2, y: inset))
                path.addLine(to: CGPoint(x: side / 2, y: side - inset))
            }
            path.lineWidth = side * 0.06
            path.lineCapStyle = .round
            if isDotted {
                path.setLineDash([side * 0.09, side * 0.075], count: 2, phase: 0)
            }
            lineColour.setStroke()
            path.stroke()
        }

        let marked = material(colour: faceColour, opacity: 1, lightingModel: .lambert)
        marked.diffuse.contents = image
        marked.ambient.contents = image
        marked.diffuse.magnificationFilter = .linear
        marked.diffuse.minificationFilter = .linear
        marked.diffuse.mipFilter = .linear
        marked.diffuse.wrapS = .clamp
        marked.diffuse.wrapT = .clamp
        return marked
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
        // Alpha comes only from the explicit `opacity` argument. UIColor system roles often carry
        // an implicit alpha of their own; letting that leak into intersecting edge rods recreated
        // the dark-corner sorting artefact even when `transparency` was one.
        material.diffuse.contents = colour.withAlphaComponent(1)
        material.transparency = opacity
        material.lightingModel = lightingModel
        // All geometry built here is closed. Drawing back faces made transparent boxes accumulate
        // their colour twice and change darkness as SceneKit's sort order changed.
        material.isDoubleSided = false
        if opacity < 1 {
            material.transparencyMode = .singleLayer
        }
        return material
    }
}
