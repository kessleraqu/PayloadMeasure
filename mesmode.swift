import Foundation

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

enum MesMode: String, CaseIterable, Identifiable {
    case line
    case boundingBox
    case scan

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .line:
            "Line"
        case .boundingBox:
            "Box"
        case .scan:
            "Scan"
        }
    }

    var systemImageName: String {
        switch self {
        case .line:
            "ruler"
        case .boundingBox:
            "cube"
        case .scan:
            "viewfinder"
        }
    }
}
