//
//  ObjectCaptureEngine.swift
//  PayloadMeasure
//
//  Created by Alexandre on 29/06/2026.
//

import Foundation
import Observation
import simd

/// Owns the LiDAR object-scan workflow: mesh/point display state, saved captures, and the
/// request/reset counters the AR layer observes to do its work.
///
/// This deliberately mirrors the revision-counter pattern in `MeasurementEngine`: SwiftUI controls
/// bump a counter, and `ARCameraView.Coordinator` reacts via `withObservationTracking`.
@MainActor
@Observable
final class ObjectCaptureEngine {
    private(set) var capturedObjectsByID: [UUID: CapturedObject] = [:]
    private(set) var previewObject: CapturedObject?
    private(set) var objectMaskPreview: ObjectMaskPreview?
    private(set) var lockedObjectMaskCount = 0
    private(set) var visibleObjectMaskCount = 0
    private(set) var objectMaskMarkers: [ObjectMaskMarker] = []
    private(set) var objectMaskFeedbackText: String?
    private(set) var objectMaskToggleRequest: ObjectMaskToggleRequest?
    private(set) var statusText = defaultPrompt
    private(set) var isMeshVisible = false
    private(set) var showsSelectedPoints = false
    private(set) var showsLiveMaskPreview = true
    private(set) var showsLockedMaskPreviews = true
    private(set) var showsBoundingBoxes = true
    private(set) var showsObjectMaskMarkers = true
    private(set) var isCapturing = false
    private(set) var captureRequestRevision = 0
    private(set) var resetRevision = 0
    private(set) var objectMaskToggleRequestRevision = 0
    private var latestObjectMaskPreviewTimestamp: TimeInterval = -.greatestFiniteMagnitude
    private var captureOrder: [UUID] = []
    private var focusedCaptureID: UUID?
    private var lockedMaskLayersByID: [UUID: ObjectMaskPreviewLayer] = [:]
    private var lockedMaskLayerOrder: [UUID] = []
    private var liveMaskLayer: ObjectMaskPreviewLayer?

    private static let defaultPrompt = "Center or tap a highlighted object to lock it."
    private static let scanningPrompt = "Scanning masked depth — move slightly to reveal its sides."

    /// The live box being refined, otherwise the most recently saved box.
    private var displayObject: CapturedObject? {
        if let previewObject {
            return previewObject
        }
        if let focusedCaptureID, let focused = capturedObjectsByID[focusedCaptureID] {
            return focused
        }
        return captureOrder.last.flatMap { capturedObjectsByID[$0] }
    }

    var hasCapture: Bool {
        !capturedObjectsByID.isEmpty
    }

    var capturedObjectCount: Int {
        capturedObjectsByID.count
    }

    var hasObjectMaskPreview: Bool {
        objectMaskPreview != nil
    }

    var showsSegmentationOverlays: Bool {
        showsLiveMaskPreview || showsLockedMaskPreviews
    }

    var lostObjectMaskCount: Int {
        max(lockedObjectMaskCount - visibleObjectMaskCount, 0)
    }

    var canReset: Bool {
        !capturedObjectsByID.isEmpty || previewObject != nil || lockedObjectMaskCount > 0
    }

    var statusHeadline: String {
        if isCapturing {
            return "Capturing"
        }
        if previewObject != nil {
            return "Scanning masked objects"
        }
        if !capturedObjectsByID.isEmpty {
            return capturedObjectsByID.count == 1
                ? "1 object saved"
                : "\(capturedObjectsByID.count) objects saved"
        }
        return "Scan mode"
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
        let saved = capturedObjectsByID.isEmpty ? "" : "Ready \(capturedObjectsByID.count) · "
        return saved + String(
            format: "Volume %.1f L · %d pts",
            object.volume * 1000,
            object.sampleCount
        )
    }

    func toggleMesh() {
        isMeshVisible.toggle()
    }

    func toggleSelectedPoints() {
        showsSelectedPoints.toggle()
    }

    func toggleLiveMaskPreview() {
        showsLiveMaskPreview.toggle()
    }

    func toggleLockedMaskPreviews() {
        showsLockedMaskPreviews.toggle()
    }

    func toggleSegmentationOverlays() {
        let shouldShow = !showsSegmentationOverlays
        showsLiveMaskPreview = shouldShow
        showsLockedMaskPreviews = shouldShow
    }

    func toggleBoundingBoxes() {
        showsBoundingBoxes.toggle()
    }

    func toggleObjectMaskMarkers() {
        showsObjectMaskMarkers.toggle()
    }

    /// Hides only visualization layers. Tracking, segmentation, LiDAR accumulation, and saved
    /// measurements continue unchanged so the operator can return to any display combination.
    func hideAllScanVisuals() {
        showsLiveMaskPreview = false
        showsLockedMaskPreviews = false
        showsBoundingBoxes = false
        showsSelectedPoints = false
        isMeshVisible = false
        showsObjectMaskMarkers = false
    }

    /// A presentation-friendly view: retain the selected masks and measured boxes without the
    /// diagnostic mesh, raw LiDAR points, transient preview, or anchor markers.
    func showResultsOnly() {
        showsLiveMaskPreview = false
        showsLockedMaskPreviews = true
        showsBoundingBoxes = true
        showsSelectedPoints = false
        isMeshVisible = false
        showsObjectMaskMarkers = false
    }

    func showObjectMaskPreview(_ preview: ObjectMaskPreview) {
        guard preview.timestamp >= latestObjectMaskPreviewTimestamp else {
            return
        }
        latestObjectMaskPreviewTimestamp = preview.timestamp
        liveMaskLayer = nil
        for layer in preview.layers {
            if let id = layer.trackedObjectID {
                if lockedMaskLayersByID[id] == nil {
                    lockedMaskLayerOrder.append(id)
                }
                lockedMaskLayersByID[id] = layer
            } else {
                liveMaskLayer = layer
            }
        }
        rebuildObjectMaskPreview(timestamp: preview.timestamp)
    }

    func updateLockedObjectMaskCount(_ count: Int) {
        lockedObjectMaskCount = count
        visibleObjectMaskCount = min(visibleObjectMaskCount, count)
        if count == 0 {
            objectMaskMarkers = []
            objectMaskFeedbackText = nil
        }
    }

    func updateObjectMaskTracking(visibleCount: Int, markers: [ObjectMaskMarker]) {
        visibleObjectMaskCount = min(max(visibleCount, 0), lockedObjectMaskCount)
        objectMaskMarkers = markers
        let lostCount = lostObjectMaskCount
        if lostCount > 0 {
            objectMaskFeedbackText = "\(lockedObjectMaskCount) locked · \(lostCount) currently outside the view. Their anchors are retained."
        } else if lockedObjectMaskCount >= 15 {
            objectMaskFeedbackText = "Maximum 15 objects locked. Tap a locked object to remove it before adding another."
        } else if lockedObjectMaskCount > 0 {
            objectMaskFeedbackText = "\(lockedObjectMaskCount) object\(lockedObjectMaskCount == 1 ? "" : "s") locked. Point at another preview to add it."
        } else {
            objectMaskFeedbackText = nil
        }
    }

    /// Called from the inexpensive AR-anchor projection loop so lost/lock markers keep up with
    /// fast phone motion even while a slower Vision segmentation request is still running.
    func updateObjectMaskMarkers(_ markers: [ObjectMaskMarker]) {
        if objectMaskMarkers != markers {
            objectMaskMarkers = markers
        }
    }

    func reportObjectLockNeedsSurface() {
        isCapturing = false
        objectMaskFeedbackText = "No stable surface was found at that point. Move slowly around it, then tap again."
    }

    func reportObjectLockNotFound() {
        isCapturing = false
        objectMaskFeedbackText = "No separate object mask was found there. Keep the object fully visible and tap near its center."
    }

    func reportObjectLimitReached() {
        isCapturing = false
        objectMaskFeedbackText = "Maximum 15 objects locked. Remove one before adding another."
    }

    func requestObjectMaskToggle(at normalizedViewportPoint: CGPoint) {
        objectMaskToggleRequest = ObjectMaskToggleRequest(
            normalizedViewportPoint: normalizedViewportPoint
        )
        objectMaskFeedbackText = "Selecting object…"
        objectMaskToggleRequestRevision += 1
    }

    func finishObjectSelection(didAdd: Bool) {
        isCapturing = false
        statusText = didAdd
            ? "Object locked. Point at another highlighted object to add it."
            : "Object removed. Its mask and LiDAR box were cleared."
    }

    func clearObjectMaskPreview() {
        objectMaskPreview = nil
        lockedMaskLayersByID.removeAll()
        lockedMaskLayerOrder.removeAll()
        liveMaskLayer = nil
        latestObjectMaskPreviewTimestamp = -.greatestFiniteMagnitude
    }

    /// Clears only the transient aimer preview. Cached locked layers remain available for
    /// simultaneous display and immediate world-anchor reprojection after returning to an object.
    func clearLiveObjectMaskPreview() {
        liveMaskLayer = nil
        rebuildObjectMaskPreview(timestamp: latestObjectMaskPreviewTimestamp)
    }

    func removeObjectMaskLayer(id: UUID) {
        lockedMaskLayersByID.removeValue(forKey: id)
        lockedMaskLayerOrder.removeAll(where: { $0 == id })
        rebuildObjectMaskPreview(timestamp: latestObjectMaskPreviewTimestamp)
    }

    private func rebuildObjectMaskPreview(timestamp: TimeInterval) {
        var layers = lockedMaskLayerOrder.compactMap { lockedMaskLayersByID[$0] }
        if let liveMaskLayer {
            layers.append(liveMaskLayer)
        }
        objectMaskPreview = layers.isEmpty
            ? nil
            : ObjectMaskPreview(layers: layers, timestamp: timestamp)
    }

    /// Called continuously by the AR layer while live-scanning to show the box being built.
    func showPreview(_ object: CapturedObject) {
        previewObject = object
        if statusText != Self.scanningPrompt {
            statusText = Self.scanningPrompt
        }
    }

    /// Clears the live preview without a full reset (used when the scan re-anchors to a new object).
    func clearPreview() {
        previewObject = nil
        let prompt = capturedObjectsByID.isEmpty
            ? Self.defaultPrompt
            : "\(capturedObjectsByID.count) boxes ready. Point at another object to add it."
        if statusText != prompt {
            statusText = prompt
        }
    }

    func requestCapture() {
        objectMaskFeedbackText = nil
        isCapturing = true
        statusText = "Locking the object under the center point."
        captureRequestRevision += 1
    }

    /// Cancels only the active acquisition. Previously saved objects and their boxes remain.
    func cancelCapture() {
        guard isCapturing else {
            return
        }
        isCapturing = false
        statusText = capturedObjectsByID.isEmpty
            ? Self.defaultPrompt
            : "\(capturedObjectsByID.count) boxes ready. Point at another object to add it."
        captureRequestRevision += 1
    }

    func applyCapture(_ object: CapturedObject) {
        updateCapture(id: UUID(), object: object)
    }

    /// Inserts or refines one mask-owned 3D box without disturbing any other object.
    func updateCapture(id: UUID, object: CapturedObject) {
        if capturedObjectsByID[id] == nil {
            captureOrder.append(id)
        }
        capturedObjectsByID[id] = object
        focusedCaptureID = id
        previewObject = nil
        isCapturing = false
        statusText = "\(capturedObjectsByID.count) LiDAR box\(capturedObjectsByID.count == 1 ? "" : "es") ready."
    }

    func focusCapture(id: UUID) {
        guard capturedObjectsByID[id] != nil else { return }
        focusedCaptureID = id
    }

    func removeCapture(id: UUID) {
        capturedObjectsByID.removeValue(forKey: id)
        captureOrder.removeAll(where: { $0 == id })
        if focusedCaptureID == id {
            focusedCaptureID = captureOrder.last
        }
        statusText = capturedObjectsByID.isEmpty
            ? Self.defaultPrompt
            : "\(capturedObjectsByID.count) LiDAR box\(capturedObjectsByID.count == 1 ? "" : "es") ready."
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
        capturedObjectsByID.removeAll()
        captureOrder.removeAll()
        focusedCaptureID = nil
        previewObject = nil
        objectMaskPreview = nil
        lockedMaskLayersByID.removeAll()
        lockedMaskLayerOrder.removeAll()
        liveMaskLayer = nil
        latestObjectMaskPreviewTimestamp = -.greatestFiniteMagnitude
        lockedObjectMaskCount = 0
        visibleObjectMaskCount = 0
        objectMaskMarkers = []
        objectMaskFeedbackText = nil
        objectMaskToggleRequest = nil
        isCapturing = false
        statusText = Self.defaultPrompt
        resetRevision += 1
    }
}
