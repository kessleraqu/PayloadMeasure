import SwiftUI
import simd

/// A to-scale drawing of a 3BKP packing: a plan looking down on the knapsack floor and an elevation
/// from the side, both on the same horizontal scale.
///
/// Unlike the load-balanced arrangement, a 3BKP packing stacks, so the plan alone is ambiguous —
/// two boxes can share a footprint at different heights. Items are therefore drawn from the floor
/// upwards, every item above the floor has complete bottom-face support from one or more packages,
/// and the elevation shows the stacking directly.
struct BaldiPlanView: View {
    let solution: BaldiSolution
    let colours: [UUID: Color]
    var highlightedPackageID: UUID?

    private let marginFraction: CGFloat = 0.035

    private var extent: SIMD3<Double> {
        SIMD3(
            Double(solution.knapsack.size.x),
            Double(solution.knapsack.size.y),
            Double(solution.knapsack.size.z)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(
                "Plan — looking down",
                trailing: String(format: "%.0f × %.0f mm", extent.x, extent.y)
            )
            Canvas { context, size in
                drawPlan(in: context, size: size)
            }
            .aspectRatio(aspectRatio(forDepth: extent.y), contentMode: .fit)
            .accessibilityLabel(accessibilityLabel)

            header(
                "Elevation — from the side",
                trailing: String(format: "%.0f mm clear", extent.z)
            )
            Canvas { context, size in
                drawElevation(in: context, size: size)
            }
            .aspectRatio(aspectRatio(forDepth: extent.z), contentMode: .fit)
            .accessibilityHidden(true)
        }
    }

    private func aspectRatio(forDepth depth: Double) -> CGFloat {
        let usable = 1 - 2 * marginFraction
        let ratio = usable * depth / extent.x + 2 * marginFraction
        return 1 / max(ratio, 0.02)
    }

    private func geometry(for size: CGSize) -> (margin: CGFloat, scale: CGFloat) {
        let margin = size.width * marginFraction
        let scale = max(0.01, (size.width - 2 * margin) / extent.x)
        return (margin, scale)
    }

    /// Loading order: floor level first, then left to right, matching the placement list.
    private var numbering: [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (index, placement) in orderedPlacements.enumerated() {
            map[placement.id] = index + 1
        }
        return map
    }

    var orderedPlacements: [BaldiPlacement] {
        solution.placements.sorted { first, second in
            if first.origin.z != second.origin.z { return first.origin.z < second.origin.z }
            if first.origin.x != second.origin.x { return first.origin.x < second.origin.x }
            if first.origin.y != second.origin.y { return first.origin.y < second.origin.y }
            return first.id.uuidString < second.id.uuidString
        }
    }

    private var accessibilityLabel: String {
        let names = orderedPlacements.map(\.name).joined(separator: ", ")
        return "Plan of the supported 3D packing. Loading order: \(names)."
    }

    private func header(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(trailing)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Plan

    private func drawPlan(in context: GraphicsContext, size: CGSize) {
        let (margin, scale) = geometry(for: size)
        let originPoint = CGPoint(x: margin, y: margin)
        let outline = CGRect(
            x: originPoint.x,
            y: originPoint.y,
            width: extent.x * scale,
            height: extent.y * scale
        )
        drawShell(context, rect: outline)
        drawGrid(context, rect: outline, scale: scale)
        drawDomain(context, rect: outline, scale: scale)

        let labels = numbering
        // Floor level first, so a stacked item is drawn over its one or more supporters.
        for placement in solution.placements.sorted(by: { $0.origin.z < $1.origin.z }) {
            let rect = CGRect(
                x: originPoint.x + placement.origin.x * scale,
                y: originPoint.y + placement.origin.y * scale,
                width: Double(placement.size.x) * scale,
                height: Double(placement.size.y) * scale
            )
            draw(placement: placement, in: context, rect: rect, label: labels[placement.id])
        }

        drawTarget(
            context,
            at: CGPoint(
                x: originPoint.x + solution.knapsack.idealCentreOfMass.x * scale,
                y: originPoint.y + solution.knapsack.idealCentreOfMass.y * scale
            )
        )
        let centre = solution.centreOfMass
        drawCentreOfMass(
            context,
            at: CGPoint(x: originPoint.x + centre.x * scale, y: originPoint.y + centre.y * scale),
            isInside: solution.isBalanced
        )
    }

    // MARK: - Elevation

    private func drawElevation(in context: GraphicsContext, size: CGSize) {
        let (margin, scale) = geometry(for: size)
        let floor = size.height - margin
        let outline = CGRect(
            x: margin,
            y: floor - extent.z * scale,
            width: extent.x * scale,
            height: extent.z * scale
        )
        drawShell(context, rect: outline)

        // The vertical slice of the allowable domain.
        let domainRect = CGRect(
            x: margin + solution.knapsack.domainLower.x * scale,
            y: floor - solution.knapsack.domainUpper.z * scale,
            width: (solution.knapsack.domainUpper.x - solution.knapsack.domainLower.x) * scale,
            height: (solution.knapsack.domainUpper.z - solution.knapsack.domainLower.z) * scale
        )
        context.fill(Path(domainRect), with: .color(.green.opacity(0.08)))
        context.stroke(
            Path(domainRect),
            with: .color(.green.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
        )

        let labels = numbering
        for placement in solution.placements.sorted(by: { $0.origin.y > $1.origin.y }) {
            let rect = CGRect(
                x: margin + placement.origin.x * scale,
                y: floor - placement.maximum.z * scale,
                width: Double(placement.size.x) * scale,
                height: Double(placement.size.z) * scale
            )
            draw(placement: placement, in: context, rect: rect, label: labels[placement.id])
        }

        let centre = solution.centreOfMass
        drawCentreOfMass(
            context,
            at: CGPoint(x: margin + centre.x * scale, y: floor - centre.z * scale),
            isInside: solution.isBalanced
        )
    }

    // MARK: - Pieces

    private func drawShell(_ context: GraphicsContext, rect: CGRect) {
        let shell = Path(roundedRect: rect, cornerRadius: 4)
        context.fill(shell, with: .color(.primary.opacity(0.05)))
        context.stroke(shell, with: .color(.primary.opacity(0.45)), lineWidth: 1.5)
    }

    private func drawGrid(_ context: GraphicsContext, rect: CGRect, scale: CGFloat) {
        let spacing = 100.0 * scale
        guard spacing > 8 else { return }
        var path = Path()
        var offset = spacing
        while offset < rect.width {
            path.move(to: CGPoint(x: rect.minX + offset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
            offset += spacing
        }
        context.stroke(path, with: .color(.primary.opacity(0.1)), lineWidth: 0.75)
    }

    /// The allowable centre-of-mass domain `[L¹,U¹] × [L²,U²]`, projected on the floor.
    private func drawDomain(_ context: GraphicsContext, rect: CGRect, scale: CGFloat) {
        let lower = solution.knapsack.domainLower
        let upper = solution.knapsack.domainUpper
        let domain = CGRect(
            x: rect.minX + lower.x * scale,
            y: rect.minY + lower.y * scale,
            width: (upper.x - lower.x) * scale,
            height: (upper.y - lower.y) * scale
        )
        context.fill(Path(domain), with: .color(.green.opacity(0.08)))
        context.stroke(
            Path(domain),
            with: .color(.green.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
        )
    }

    private func draw(
        placement: BaldiPlacement,
        in context: GraphicsContext,
        rect: CGRect,
        label: Int?
    ) {
        let colour = colours[placement.id] ?? .accentColor
        let isHighlighted = highlightedPackageID == placement.id
        let isStacked = placement.origin.z > 1e-6
        let shape = Path(roundedRect: rect, cornerRadius: min(3, rect.height / 4))
        // A stacked package may be carried by one or more packages, so it is kept translucent enough
        // to leave the supporting layer underneath readable.
        let fill = isHighlighted ? 0.6 : (isStacked ? 0.2 : 0.32)
        context.fill(shape, with: .color(colour.opacity(fill)))
        context.stroke(
            shape,
            with: .color(colour),
            style: StrokeStyle(
                lineWidth: isHighlighted ? 2.5 : 1.5,
                dash: isStacked ? [5, 2] : []
            )
        )

        guard let label, rect.width > 13, rect.height > 12 else { return }
        let text = Text("\(label)")
            .font(.system(size: min(12, rect.height * 0.5), weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
        context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
    }

    private func drawTarget(_ context: GraphicsContext, at point: CGPoint) {
        let radius: CGFloat = 8
        let circle = Path(
            ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        )
        context.stroke(circle, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
    }

    private func drawCentreOfMass(_ context: GraphicsContext, at point: CGPoint, isInside: Bool) {
        let arm: CGFloat = 7
        var cross = Path()
        cross.move(to: CGPoint(x: point.x - arm, y: point.y))
        cross.addLine(to: CGPoint(x: point.x + arm, y: point.y))
        cross.move(to: CGPoint(x: point.x, y: point.y - arm))
        cross.addLine(to: CGPoint(x: point.x, y: point.y + arm))
        context.stroke(cross, with: .color(Color(white: 1, opacity: 0.85)), lineWidth: 5)
        context.stroke(cross, with: .color(isInside ? .orange : .red), lineWidth: 2.5)
    }
}
