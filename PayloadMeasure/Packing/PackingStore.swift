import Foundation
import Observation
import SwiftUI
import simd

/// Bridges the measured objects into the packing optimiser and holds the arrangement for the UI.
///
/// The solve runs off the main actor. It is pure computation on value types with a hard time limit,
/// so it cannot block the AR session, and a superseded solve is cancelled rather than left to
/// finish and overwrite a newer one.
@MainActor
@Observable
final class PackingStore {
    /// Geometry and mass properties of the payload module, editable in the arrangement settings.
    var module: PayloadModule = .standard
    var options = PackingOptions()
    /// Clearance applied to every package unless it has its own override, in millimetres.
    var defaultPackageClearance: Double = 5
    /// Packages the operator marked as "this way up".
    var uprightPackageIDs: Set<UUID> = []
    /// Restricts the achieved centre of mass to a box around the target, chapter eq. (adapted COM
    /// envelope). Expressed to the operator as a tolerance rather than absolute bounds.
    var restrictsCentreOfMass = false
    var centreOfMassTolerance = SIMD3<Double>(20, 10, 50)
    var limitsPayloadMass = false
    var maximumPayloadMass: Double = 5

    private(set) var result: PackingResult?
    private(set) var isSolving = false
    /// Identifies the inputs the current result was produced from, so the sheet can say when the
    /// arrangement no longer matches what has been measured.
    private(set) var solvedSignature: String?

    private var solveTask: Task<Void, Never>?
    private var solveWork: Task<PackingResult, Never>?

    /// The module as the optimiser sees it, with the operator's envelope and mass limit folded in.
    var effectiveModule: PayloadModule {
        var configured = module
        configured.centreOfMassEnvelope = restrictsCentreOfMass
            ? CentreOfMassEnvelope(
                minimum: module.targetCentreOfMass - centreOfMassTolerance,
                maximum: module.targetCentreOfMass + centreOfMassTolerance
            )
            : .unbounded
        configured.maximumPayloadMassKilograms = limitsPayloadMass ? maximumPayloadMass : nil
        return configured
    }

    // MARK: - Inputs

    /// Builds the optimiser's package list from every locked measurement.
    func packages(from engine: ObjectCaptureEngine) -> [PackingItem] {
        engine.measuredObjectIDs.compactMap { id in
            guard let captured = engine.capturedObjectsByID[id] else { return nil }
            return PackingItem(
                id: id,
                name: engine.name(for: id) ?? "Object \(engine.objectNumber(for: id) ?? 0)",
                size: SIMD3(
                    Double(captured.widthInMeters) * 1000,
                    Double(captured.depthInMeters) * 1000,
                    Double(captured.heightInMeters) * 1000
                ),
                massKilograms: engine.weightInKilograms(for: id) ?? 0,
                horizontalClearance: defaultPackageClearance,
                keepsUpright: uprightPackageIDs.contains(id)
            )
        }
    }

    /// Locked measurements that cannot be arranged yet because no weight has been entered.
    func packagesMissingWeight(from engine: ObjectCaptureEngine) -> [UUID] {
        engine.measuredObjectIDs.filter { engine.weightInKilograms(for: $0) == nil }
    }

    func colour(for id: UUID, in engine: ObjectCaptureEngine) -> Color {
        guard let colour = engine.objectColor(for: id) else { return .accentColor }
        return Color(red: colour.red, green: colour.green, blue: colour.blue)
    }

    /// True when the measurements or settings have changed since the displayed arrangement.
    func isStale(for packages: [PackingItem]) -> Bool {
        result != nil && solvedSignature != signature(for: packages)
    }

    // MARK: - Solving

    func solve(packages: [PackingItem]) {
        solveTask?.cancel()
        guard !packages.isEmpty else {
            result = nil
            solvedSignature = nil
            return
        }

        isSolving = true
        let problem = PackingProblem(module: effectiveModule, items: packages)
        let options = options
        let expected = signature(for: packages)

        // The work itself is held separately so cancelling really stops it: cancelling a parent
        // task does not propagate into a detached one, and the branch-and-bound search polls its
        // own task's cancellation between nodes.
        let work = Task.detached(priority: .userInitiated) {
            PackingOptimizer.solve(problem, options: options)
        }
        solveWork = work

        solveTask = Task { [weak self] in
            let outcome = await work.value
            guard !Task.isCancelled else { return }
            self?.result = outcome
            self?.solvedSignature = expected
            self?.isSolving = false
        }
    }

    func cancel() {
        solveWork?.cancel()
        solveWork = nil
        solveTask?.cancel()
        solveTask = nil
        isSolving = false
    }

    func clear() {
        cancel()
        result = nil
        solvedSignature = nil
    }

    /// Everything the arrangement depends on. Any change makes the displayed result stale, and the
    /// result screen uses it as the identity of the work it needs done.
    func signature(for packages: [PackingItem]) -> String {
        let module = effectiveModule
        var parts: [String] = [
            String(
                format: "%.2f/%.2f/%.2f/%.2f",
                module.lengthMillimetres,
                module.widthMillimetres,
                module.heightMillimetres,
                module.minimumWallClearance
            ),
            String(
                format: "t%.2f,%.2f,%.2f w%.2f,%.2f,%.2f",
                module.targetCentreOfMass.x, module.targetCentreOfMass.y, module.targetCentreOfMass.z,
                module.axisWeights.x, module.axisWeights.y, module.axisWeights.z
            ),
            String(
                format: "m%.3f,%.3f",
                module.emptyMassKilograms,
                module.airframeMassKilograms
            ),
            options.minimisesFootprintAfterBalance ? "compact" : "balance",
            String(format: "lim%.2f/%.2f", options.balanceTimeLimitSeconds, options.compactnessTimeLimitSeconds),
            restrictsCentreOfMass
                ? String(format: "env%.1f,%.1f,%.1f", centreOfMassTolerance.x, centreOfMassTolerance.y, centreOfMassTolerance.z)
                : "env-",
            limitsPayloadMass ? String(format: "cap%.2f", maximumPayloadMass) : "cap-",
        ]
        for package in packages.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            parts.append(
                String(
                    format: "%@:%.2f,%.2f,%.2f,%.4f,%.2f,%d",
                    package.id.uuidString,
                    package.size.x, package.size.y, package.size.z,
                    package.massKilograms,
                    package.horizontalClearance,
                    package.keepsUpright ? 1 : 0
                )
            )
        }
        return parts.joined(separator: "|")
    }
}
