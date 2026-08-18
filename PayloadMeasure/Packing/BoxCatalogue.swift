import Foundation
import Observation
import simd

// The boxes available for one payload module.
//
// In:  the payload being worked on, and whatever the operator adds or deletes.
// Out: the list the assignment step chooses from, saved per payload.
//
// Each module carries its own boxes: the two are stocked differently, so a shared list would offer
// the small module boxes that cannot go in it. The practice payload has no list of its own — it is the
// same size as the small module and is meant to stand in for it, so it uses the small module's boxes.
//
// The list is saved under a key that names the payload, and under a fresh key generation: the earlier
// build kept one shared list of fourteen boxes, and reusing its key would have restored those on
// upgrade instead of the sets the study actually uses.

@MainActor
@Observable
final class BoxCatalogue {
    private(set) var payload: StudyBox
    private(set) var presets: [PackingBoxPreset]

    init(payload: StudyBox = .small) {
        self.payload = payload
        self.presets = Self.load(for: payload)
    }

    func setPayload(_ payload: StudyBox) {
        guard payload != self.payload else { return }
        self.payload = payload
        presets = Self.load(for: payload)
    }

    /// Reloads from disk. Used when returning from a screen that may have edited the same payload.
    func reload() {
        presets = Self.load(for: payload)
    }

    @discardableResult
    func add(
        outerSizeMillimetres size: SIMD3<Double>,
        usableInnerSizeMillimetres inner: SIMD3<Double>? = nil
    ) -> PackingBoxPreset? {
        guard let preset = PackingBoxPreset.sized(
            outerSizeMillimetres: size,
            usableInnerSizeMillimetres: inner
        ),
              size.allFiniteAndPositive,
              inner.map(\.allFiniteAndPositive) ?? true,
              !presets.contains(where: { $0.outerSizeMillimetres == size }) else {
            return nil
        }
        presets.append(preset)
        save()
        return preset
    }

    func remove(id: String) {
        guard presets.contains(where: { $0.id == id }) else { return }
        presets.removeAll { $0.id == id }
        save()
    }

    func resetToDefaults() {
        presets = PackingBoxPreset.defaultCatalog(for: payload)
        save()
    }

    var isDefault: Bool {
        presets.map(\.id) == PackingBoxPreset.defaultCatalog(for: payload).map(\.id)
    }

    // MARK: - Persistence

    /// The generation moves whenever the stocked sizes change, because a saved list would otherwise
    /// restore the old ones on upgrade. v6: updated stocked dimensions and interior-first naming.
    private static func key(for payload: StudyBox) -> String {
        "packing.boxes.v6.\(payload.rawValue)"
    }

    private static func legacyKeyV5(for payload: StudyBox) -> String {
        "packing.boxes.v5.\(payload.rawValue)"
    }

    private static func load(for payload: StudyBox) -> [PackingBoxPreset] {
        if let data = UserDefaults.standard.data(forKey: key(for: payload)),
           let stored = try? JSONDecoder().decode([PackingBoxPreset].self, from: data) {
            return migrated(stored, for: payload)
        }
        if let data = UserDefaults.standard.data(forKey: legacyKeyV5(for: payload)),
           let stored = try? JSONDecoder().decode([PackingBoxPreset].self, from: data) {
            return migrated(stored, for: payload)
        }
        return PackingBoxPreset.defaultCatalog(for: payload)
    }

    private static func migrated(
        _ presets: [PackingBoxPreset],
        for payload: StudyBox
    ) -> [PackingBoxPreset] {
        var result: [PackingBoxPreset] = []
        var seenIDs: Set<String> = []
        for preset in presets {
            var outer = preset.outerSizeMillimetres
            var inner = preset.usableInnerSizeMillimetres

            if payload == .big, outer == SIMD3(35, 22, 115) {
                outer = SIMD3(35, 22, 120)
                inner = SIMD3(35, 22, 120)
            }
            if payload == .big, outer == SIMD3(95, 95, 160) {
                inner = SIMD3(100, 100, 160)
            }

            let id = PackingBoxPreset.identifier(for: outer)
            guard !seenIDs.contains(id),
                  let rebuilt = PackingBoxPreset.sized(
                      id: id,
                      outerSizeMillimetres: outer,
                      usableInnerSizeMillimetres: inner
                  ) else { continue }
            result.append(rebuilt)
            seenIDs.insert(id)
        }
        return result
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(for: payload))
    }
}

extension StudyStore {
    /// Which payload's boxes apply right now. The practice payload borrows the small module's.
    var catalogueOwner: StudyBox {
        isPractice ? .small : (currentBox ?? scheduledBox ?? .small)
    }
}
