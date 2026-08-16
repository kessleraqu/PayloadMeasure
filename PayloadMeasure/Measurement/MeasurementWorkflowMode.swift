import Foundation

// The two automatic measurement methods the operator can choose between in Information.

enum MeasurementWorkflowMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case spatial3D
    case top

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .spatial3D:
            "3D"
        case .top:
            "Top"
        }
    }

    var title: String {
        switch self {
        case .spatial3D:
            "Full 3D scan"
        case .top:
            "Top measurement"
        }
    }

    var detail: String {
        switch self {
        case .spatial3D:
            "Measure the footprint from above and height from an isometric or lateral view."
        case .top:
            "Measure only from above using the paper's convex-hull orientation fit and LiDAR height above the support."
        }
    }

    /// Short protocol text used by the accuracy test. Full 3D deliberately needs two viewpoints:
    /// an overhead view for the footprint, then either an isometric or lateral view for height.
    var accuracyInstruction: String {
        switch self {
        case .spatial3D:
            "Capture the top first, then lower the phone for an isometric or lateral view."
        case .top:
            "Hold the phone directly above the object and point straight down."
        }
    }
}
