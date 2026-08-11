import SwiftUI

// To-scale drawing of a Balance arrangement: a plan looking down on the module floor and an
// elevation from the side, both on the same horizontal scale so a package lines up with its own
// footprint.
//
// In:  a PackingSolution and a colour per package.
// Out: on screen only.

struct PackingPlanView: View {
    let solution: PackingSolution
    let colours: [UUID: Color]
    var highlightedPackageID: UUID?
    var showsElevation = true

    private let marginFraction: CGFloat = 0.035

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header("Plan — looking down", trailing: dimensionLabel)
            Canvas { context, size in
                drawPlan(in: context, size: size)
            }
            .aspectRatio(aspectRatio(forDepth: solution.module.widthMillimetres), contentMode: .fit)
            .accessibilityLabel(planAccessibilityLabel)

            if showsElevation {
                header("Elevation — from the side", trailing: heightLabel)
                Canvas { context, size in
                    drawElevation(in: context, size: size)
                }
                .aspectRatio(aspectRatio(forDepth: solution.module.heightMillimetres), contentMode: .fit)
                .accessibilityHidden(true)
            }
        }
    }

    private func aspectRatio(forDepth depth: Double) -> CGFloat {
        let usable = 1 - 2 * marginFraction
        let ratio = usable * depth / solution.module.lengthMillimetres + 2 * marginFraction
        return 1 / max(ratio, 0.02)
    }

    private func geometry(for size: CGSize) -> (margin: CGFloat, scale: CGFloat) {
        let margin = size.width * marginFraction
        let scale = max(0.01, (size.width - 2 * margin) / solution.module.lengthMillimetres)
        return (margin, scale)
    }

    private var numbering: [UUID: Int] {
        var map: [UUID: Int] = [:]
        for (index, package) in solution.packages.sorted(by: { $0.centre.x < $1.centre.x }).enumerated() {
            map[package.id] = index + 1
        }
        return map
    }

    private var dimensionLabel: String {
        String(
            format: "%.0f × %.0f mm",
            solution.module.lengthMillimetres,
            solution.module.widthMillimetres
        )
    }

    private var heightLabel: String {
        String(format: "%.0f mm clear", solution.module.heightMillimetres)
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

    private var planAccessibilityLabel: String {
        let names = solution.packages
            .sorted { $0.centre.x < $1.centre.x }
            .map(\.name)
            .joined(separator: ", ")
        return "Plan of the payload module. From the rear: \(names)."
    }

    // MARK: - Plan

    private func drawPlan(in context: GraphicsContext, size: CGSize) {
        let module = solution.module
        let (_, scale) = geometry(for: size)
        let origin = CGPoint(x: size.width / 2, y: size.height / 2)
        let labels = numbering

        let outline = CGRect(
            x: origin.x - module.lengthMillimetres / 2 * scale,
            y: origin.y - module.widthMillimetres / 2 * scale,
            width: module.lengthMillimetres * scale,
            height: module.widthMillimetres * scale
        )
        drawModuleShell(context, rect: outline, clearance: module.minimumWallClearance * scale)
        drawGrid(context, rect: outline, scale: scale)

        for package in solution.packages {
            let rect = CGRect(
                x: origin.x + package.minimumX * scale,
                y: origin.y - package.maximumY * scale,
                width: package.footprint.x * scale,
                height: package.footprint.y * scale
            )
            draw(package: package, in: context, rect: rect, label: labels[package.id])
        }

        drawTargetMarker(
            context,
            at: CGPoint(
                x: origin.x + module.targetCentreOfMass.x * scale,
                y: origin.y - module.targetCentreOfMass.y * scale
            )
        )
        drawCentreOfMassMarker(
            context,
            at: CGPoint(
                x: origin.x + solution.centreOfMass.x * scale,
                y: origin.y - solution.centreOfMass.y * scale
            )
        )
    }

    // MARK: - Elevation

    private func drawElevation(in context: GraphicsContext, size: CGSize) {
        let module = solution.module
        let (margin, scale) = geometry(for: size)
        let originX = size.width / 2
        let floor = size.height - margin

        let outline = CGRect(
            x: originX - module.lengthMillimetres / 2 * scale,
            y: floor - module.heightMillimetres * scale,
            width: module.lengthMillimetres * scale,
            height: module.heightMillimetres * scale
        )
        drawModuleShell(context, rect: outline, clearance: 0)

        for package in solution.packages.sorted(by: { $0.height > $1.height }) {
            let rect = CGRect(
                x: originX + package.minimumX * scale,
                y: floor - package.height * scale,
                width: package.footprint.x * scale,
                height: package.height * scale
            )
            draw(package: package, in: context, rect: rect, label: nil)
        }

        let centreY = floor - solution.centreOfMass.z * scale
        var line = Path()
        line.move(to: CGPoint(x: outline.minX, y: centreY))
        line.addLine(to: CGPoint(x: outline.maxX, y: centreY))
        context.stroke(line, with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
        drawCentreOfMassMarker(
            context,
            at: CGPoint(x: originX + solution.centreOfMass.x * scale, y: centreY)
        )
    }

    // MARK: - Pieces

    private func drawModuleShell(_ context: GraphicsContext, rect: CGRect, clearance: CGFloat) {
        let shell = Path(roundedRect: rect, cornerRadius: 4)
        context.fill(shell, with: .color(.primary.opacity(0.05)))
        context.stroke(shell, with: .color(.primary.opacity(0.45)), lineWidth: 1.5)
        if clearance > 0.5 {
            let inner = Path(roundedRect: rect.insetBy(dx: clearance, dy: clearance), cornerRadius: 3)
            context.stroke(
                inner,
                with: .color(.primary.opacity(0.2)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
        }
    }

    private func drawGrid(_ context: GraphicsContext, rect: CGRect, scale: CGFloat) {
        let spacing = 100.0 * scale
        guard spacing > 8 else { return }
        var path = Path()
        var offset = spacing
        while offset < rect.width / 2 {
            path.move(to: CGPoint(x: rect.midX + offset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX + offset, y: rect.maxY))
            path.move(to: CGPoint(x: rect.midX - offset, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX - offset, y: rect.maxY))
            offset += spacing
        }
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        context.stroke(path, with: .color(.primary.opacity(0.12)), lineWidth: 0.75)
    }

    private func draw(package: PlacedPackage, in context: GraphicsContext, rect: CGRect, label: Int?) {
        let colour = colours[package.id] ?? .accentColor
        let isHighlighted = highlightedPackageID == package.id
        let shape = Path(roundedRect: rect, cornerRadius: min(3, rect.height / 4))
        context.fill(shape, with: .color(colour.opacity(isHighlighted ? 0.55 : 0.3)))
        context.stroke(shape, with: .color(colour), lineWidth: isHighlighted ? 2.5 : 1.5)

        guard let label, rect.width > 13, rect.height > 12 else { return }
        let text = Text("\(label)")
            .font(.system(size: min(12, rect.height * 0.5), weight: .bold, design: .rounded))
            .foregroundStyle(.primary)
        context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
    }

    private func drawTargetMarker(_ context: GraphicsContext, at point: CGPoint) {
        let radius: CGFloat = 8
        let circle = Path(
            ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        )
        context.stroke(circle, with: .color(.secondary), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
    }

    private func drawCentreOfMassMarker(_ context: GraphicsContext, at point: CGPoint) {
        let arm: CGFloat = 7
        var cross = Path()
        cross.move(to: CGPoint(x: point.x - arm, y: point.y))
        cross.addLine(to: CGPoint(x: point.x + arm, y: point.y))
        cross.move(to: CGPoint(x: point.x, y: point.y - arm))
        cross.addLine(to: CGPoint(x: point.x, y: point.y + arm))
        context.stroke(cross, with: .color(Color(white: 1, opacity: 0.85)), lineWidth: 5)
        context.stroke(cross, with: .color(.orange), lineWidth: 2.5)
    }
}
