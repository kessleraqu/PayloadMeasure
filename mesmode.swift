import Foundation

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
