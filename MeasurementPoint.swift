//
//  MeasurementPoint.swift
//  PayloadMeasure
//
//  Created by Alexandre on 29/06/2026.
//

import Foundation
import simd

struct MeasurementPoint: Identifiable, Equatable {
    let id = UUID()
    let index: Int
    var position: SIMD3<Float>
    var isRefining = true
    let createdAt = Date()
}
