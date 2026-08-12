import Foundation

// How the operator works through a load: measure everything and box it afterwards, or box each
// object the moment it is measured.
//
// In:  chosen on the start screen.
// Out: read by the HUD to decide whether the box-and-weight sheet appears after every measurement,
//      and whether a finished object stays tracked so it can be edited by pointing at it.

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

    /// A finished object only needs to stay tracked if you can still point at it and edit it.
    var tracksFinishedObjects: Bool {
        self == .batch
    }
}
