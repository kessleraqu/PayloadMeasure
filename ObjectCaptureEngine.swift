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
    private(set) var previewObject: CapturedObject?
    private(set) var statusText = defaultPrompt
    private(set) var isMeshVisible = true
    private(set) var showsSelectedPoints = true
    private(set) var isCapturing = false
    private(set) var captureRequestRevision = 0
    private(set) var resetRevision = 0

    private static let defaultPrompt = "Aim at an object on a flat surface, then Capture."
    private static let scanningPrompt = "Scanning — move slowly around the object, then Capture."

    /// The committed capture if there is one, otherwise the live preview being built.
    private var displayObject: CapturedObject? {
        capturedObject ?? previewObject
    }

    var hasCapture: Bool {
        capturedObject != nil
    }

    var canReset: Bool {
        capturedObject != nil || previewObject != nil
    }

    var statusHeadline: String {
        if isCapturing {
            return "Capturing"
        }
        if capturedObject != nil {
            return "Object captured"
        }
        return previewObject != nil ? "Scanning" : "Scan mode"
    }

    var primaryText: String {
        guard let object = displayObject else {
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
        guard let object = displayObject else {
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

    /// Called continuously by the AR layer while live-scanning to show the box being built.
    func showPreview(_ object: CapturedObject) {
        guard capturedObject == nil else {
            return
        }
        previewObject = object
        isCapturing = false
        if statusText != Self.scanningPrompt {
            statusText = Self.scanningPrompt
        }
    }

    func requestCapture() {
        isCapturing = true
        captureRequestRevision += 1
    }

    func applyCapture(_ object: CapturedObject) {
        capturedObject = object
        previewObject = nil
        isCapturing = false
        statusText = "Captured. Reset to scan a different object."
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
        previewObject = nil
        isCapturing = false
        statusText = Self.defaultPrompt
        resetRevision += 1
    }
}
