import Foundation

// The two automatic measurement methods the operator can choose between in Information.

enum MeasurementWorkflowMode: String, CaseIterable, Identifiable, Sendable {
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
            "Measure the footprint from above and height from the side."
        case .top:
            "Measure only from above using the paper's convex-hull orientation fit and LiDAR height above the support."
        }
    }
}
