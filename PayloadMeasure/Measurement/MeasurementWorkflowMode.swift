import Foundation

// The two automatic measurement methods.

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

    /// Protocol text for the accuracy test. Full 3D needs two views: overhead for the footprint,
    /// then isometric or lateral for the height.
    var accuracyInstruction: String {
        switch self {
        case .spatial3D:
            "Capture the top first, then lower the phone for an isometric or lateral view."
        case .top:
            "Hold the phone directly above the object and point straight down."
        }
    }
}
