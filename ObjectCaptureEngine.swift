//
//  ObjectCaptureEngine.swift
//  PayloadMeasure
//
//  Created by Alexandre on 29/06/2026.
//

import Foundation
import Observation
import simd

/// Owns the state of the LiDAR object-scan workflow: whether the mesh overlay is shown, the most
/// recent captured object, and the request/reset counters the AR layer observes to do its work.
///
/// This deliberately mirrors the revision-counter pattern in `MeasurementEngine`: SwiftUI controls
/// bump a counter, and `ARCameraView.Coordinator` reacts via `withObservationTracking`.
@MainActor
@Observable
final class ObjectCaptureEngine {
    private(set) var capturedObject: CapturedObject?
    private(set) var statusText = defaultPrompt
    private(set) var isMeshVisible = true
    private(set) var showsSelectedPoints = true
    private(set) var isCapturing = false
    private(set) var captureRequestRevision = 0
    private(set) var resetRevision = 0

    private static let defaultPrompt = "Aim at an object on a flat surface, then Capture."

    var hasCapture: Bool {
        capturedObject != nil
    }

    var statusHeadline: String {
        if isCapturing {
            return "Capturing"
        }
        return hasCapture ? "Object captured" : "Scan mode"
    }

    var primaryText: String {
        guard let object = capturedObject else {
            return "--"
        }
        return String(
            format: "%.1f × %.1f × %.1f cm",
            object.widthInMeters * 100,
            object.depthInMeters * 100,
            object.heightInMeters * 100
        )
    }

    var secondaryText: String? {
        guard let object = capturedObject else {
            return nil
        }
        // Liters read more naturally than cubic meters at payload scale (1 m³ = 1000 L).
        return String(format: "Volume %.1f L · %d pts", object.volume * 1000, object.sampleCount)
    }

    func toggleMesh() {
        isMeshVisible.toggle()
    }

    func toggleSelectedPoints() {
        showsSelectedPoints.toggle()
    }

    func requestCapture() {
        isCapturing = true
        statusText = "Capturing object mesh…"
        captureRequestRevision += 1
    }

    func applyCapture(_ object: CapturedObject) {
        capturedObject = object
        isCapturing = false
        statusText = "Captured. Move around the object and capture again to refine."
    }

    func reportNoSupport() {
        isCapturing = false
        statusText = "Scan the surface the object rests on, then capture."
    }

    func reportNotEnoughMesh() {
        isCapturing = false
        statusText = "Not enough mesh yet. Move slowly around the object and retry."
    }

    func reportTrackingNotReady() {
        isCapturing = false
        statusText = "Wait for tracking to stabilise before capturing."
    }

    func reset() {
        capturedObject = nil
        isCapturing = false
        statusText = Self.defaultPrompt
        resetRevision += 1
    }
}
