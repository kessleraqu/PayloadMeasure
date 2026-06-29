//
//  MeasurementEngine.swift
//  PayloadMeasure
//
//  Created by Alexandre on 29/06/2026.
//

import Foundation
import Observation
import simd

@MainActor
@Observable
final class MeasurementEngine {
    var mode: MeasurementMode = .line {
        didSet {
            if mode != oldValue {
                reset()
            }
        }
    }

    private(set) var points: [MeasurementPoint] = []
    private(set) var lastMessage = "Aim at a point, then press Add Point."
    private(set) var resetRevision = 0
    private(set) var placementRequestRevision = 0
    private(set) var aimerSurfaceScaleY: Double = 1
    private(set) var aimerSurfaceRotationDegrees: Double = 0
    private(set) var aimerDistanceScale: Double = 1
    private(set) var isAimerOnSurface = false

    var distanceInMeters: Float? {
        guard points.count == 2 else {
            return nil
        }

        return simd_distance(points[0].position, points[1].position)
    }

    var boundingBoxDimensionsInMeters: SIMD3<Float>? {
        guard points.count == 2 else {
            return nil
        }

        return abs(points[1].position - points[0].position)
    }

    var boundingBoxVolumeInCubicMeters: Float? {
        guard let dimensions = boundingBoxDimensionsInMeters else {
            return nil
        }

        return dimensions.x * dimensions.y * dimensions.z
    }

    var measurementStatusText: String {
        if points.contains(where: \.isRefining) {
            return "Refining point placement"
        }

        switch (mode, points.count) {
        case (.line, 0):
            return "Line mode"
        case (.line, 1):
            return "Point A locked. Aim point B."
        case (.line, 2):
            return "Distance locked"
        case (.boundingBox, 0):
            return "Bounding box mode"
        case (.boundingBox, 1):
            return "Corner A locked. Aim opposite corner."
        case (.boundingBox, 2):
            return "Bounding box locked"
        default:
            return "Ready"
        }
    }

    var primaryMeasurementText: String {
        switch mode {
        case .line:
            formattedDistance
        case .boundingBox:
            formattedBoundingBoxDimensions
        }
    }

    var secondaryMeasurementText: String? {
        switch mode {
        case .line:
            return nil
        case .boundingBox:
            guard let volume = boundingBoxVolumeInCubicMeters else {
                return nil
            }

            return String(format: "Volume %.3f m³", volume)
        }
    }

    var formattedDistance: String {
        guard let distanceInMeters else {
            return "--"
        }

        return String(format: "%.1f cm", distanceInMeters * 100)
    }

    var formattedBoundingBoxDimensions: String {
        guard let dimensions = boundingBoxDimensionsInMeters else {
            return "--"
        }

        return String(
            format: "%.1f × %.1f × %.1f cm",
            dimensions.x * 100,
            dimensions.y * 100,
            dimensions.z * 100
        )
    }

    var canReset: Bool {
        !points.isEmpty
    }

    var canAcceptPoint: Bool {
        points.count < 2
    }

    func requestPointPlacement() {
        placementRequestRevision += 1
    }

    func updateAimerSurface(scaleY: Double, rotationDegrees: Double, distanceScale: Double, isDetected: Bool) {
        let rotationChange = abs(shortestAngleDelta(from: aimerSurfaceRotationDegrees, to: rotationDegrees))
        guard isDetected != isAimerOnSurface ||
              abs(scaleY - aimerSurfaceScaleY) > 0.025 ||
              abs(distanceScale - aimerDistanceScale) > 0.04 ||
              rotationChange > 3 else {
            return
        }

        aimerSurfaceScaleY = scaleY
        aimerSurfaceRotationDegrees = rotationDegrees
        aimerDistanceScale = distanceScale
        isAimerOnSurface = isDetected
    }

    @discardableResult
    func addPoint(at position: SIMD3<Float>) -> UUID {
        if points.count == 2 {
            reset()
        }

        let point = MeasurementPoint(index: points.count + 1, position: position)
        points.append(point)
        updateMessage()
        return point.id
    }

    func updatePoint(id: UUID, position: SIMD3<Float>) {
        guard let index = points.firstIndex(where: { $0.id == id }) else {
            return
        }

        points[index].position = position
        updateMessage()
    }

    func finishRefiningPoint(id: UUID) {
        guard let index = points.firstIndex(where: { $0.id == id }) else {
            return
        }

        points[index].isRefining = false
        updateMessage()
    }

    func reportPlacementFailure() {
        lastMessage = "No reliable surface at the pointer. Move slowly and try a textured area."
    }

    func reportTrackingNotReady() {
        lastMessage = "Wait for Tracking ready before adding points."
    }

    func reset() {
        points.removeAll()
        lastMessage = initialMessage
        resetRevision += 1
    }

    private var initialMessage: String {
        switch mode {
        case .line:
            "Aim at two points and press Add Point for each."
        case .boundingBox:
            "Aim at two opposite corners and press Add Point for each."
        }
    }

    private func updateMessage() {
        if points.contains(where: \.isRefining) {
            lastMessage = "Hold steady while ARKit refines the point position."
            return
        }

        switch (mode, points.count) {
        case (.line, 2):
            lastMessage = String(format: "Locked distance: %.1f cm", (distanceInMeters ?? 0) * 100)
        case (.line, 1):
            lastMessage = "Point A locked. Aim at point B and press Add Point."
        case (.boundingBox, 2):
            lastMessage = "Bounding box estimated from two opposite corners."
        case (.boundingBox, 1):
            lastMessage = "Corner A locked. Aim at the opposite corner and press Add Point."
        default:
            lastMessage = initialMessage
        }
    }

    private func shortestAngleDelta(from current: Double, to target: Double) -> Double {
        var delta = target - current

        while delta > 180 {
            delta -= 360
        }

        while delta < -180 {
            delta += 360
        }

        return delta
    }
}
