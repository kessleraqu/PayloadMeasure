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
    func add(outerSizeMillimetres size: SIMD3<Double>) -> PackingBoxPreset? {
        guard let preset = PackingBoxPreset.sized(outerSizeMillimetres: size),
              size.allFiniteAndPositive,
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

    private static func key(for payload: StudyBox) -> String {
        "packing.boxes.v2.\(payload.rawValue)"
    }

    private static func load(for payload: StudyBox) -> [PackingBoxPreset] {
        guard let data = UserDefaults.standard.data(forKey: key(for: payload)),
              let stored = try? JSONDecoder().decode([PackingBoxPreset].self, from: data) else {
            return PackingBoxPreset.defaultCatalog(for: payload)
        }
        return stored
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
