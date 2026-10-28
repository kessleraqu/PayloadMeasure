import Foundation
import Observation
import simd

// The boxes available for one payload module, saved per payload. Each list starts empty and is
// filled in by the operator.

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

    /// Reloads from disk after another screen may have edited the same list.
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

    // MARK: - Persistence

    /// Bump the version to start every payload with an empty list again.
    private static func key(for payload: StudyBox) -> String {
        "packing.boxes.v7.\(payload.rawValue)"
    }

    private static func load(for payload: StudyBox) -> [PackingBoxPreset] {
        guard let data = UserDefaults.standard.data(forKey: key(for: payload)),
              let stored = try? JSONDecoder().decode([PackingBoxPreset].self, from: data) else {
            return []
        }
        return stored
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(for: payload))
    }
}

extension StudyStore {
    var catalogueOwner: StudyBox {
        currentBox ?? scheduledBox ?? .small
    }
}
