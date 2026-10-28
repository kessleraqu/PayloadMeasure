import Foundation

// Either measure everything first and box it afterwards, or box each object straight after
// measuring it.

enum MeasurementFlow: String, CaseIterable, Identifiable, Sendable {
    case batch
    case sequential

    var id: String { rawValue }

    var title: String {
        switch self {
        case .batch: "Measure, then box"
        case .sequential: "Box as you go"
        }
    }

    var detail: String {
        switch self {
        case .batch:
            "Measure every object first, then work through boxes and weights in one pass. Point at a finished object to edit it."
        case .sequential:
            "After each object, name it, see which box it goes in and enter its weight. Then straight on to the next one."
        }
    }

    var systemImage: String {
        switch self {
        case .batch: "square.grid.2x2"
        case .sequential: "arrow.trianglehead.branch"
        }
    }

    var tracksFinishedObjects: Bool {
        self == .batch
    }
}
