//
//  MeasurementMode.swift
//  PayloadMeasure
//
//  Created by Alexandre on 29/06/2026.
//

import Foundation

enum MeasurementMode: String, CaseIterable, Identifiable {
    case line
    case boundingBox

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .line:
            "Line"
        case .boundingBox:
            "Box"
        }
    }

    var systemImageName: String {
        switch self {
        case .line:
            "ruler"
        case .boundingBox:
            "cube"
        }
    }
}
