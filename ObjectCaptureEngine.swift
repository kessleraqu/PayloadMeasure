
import Foundation
import Observation
import simd

enum ObjectWorkflowRequestKind: Sendable {
    case finalize
    case reactivate
    case remove
}

struct ObjectWorkflowRequest: Sendable {
    let id: UUID
    let kind: ObjectWorkflowRequestKind
}

@MainActor
@Observable
final class ObjectCaptureEngine {
    private(set) var capturedObjectsByID: [UUID: CapturedObject] = [:]
    private(set) var activeObjectID: UUID?
    private(set) var finalizedObjectIDs: Set<UUID> = []
    private(set) var objectMaskPreview: ObjectMaskPreview?
    private(set) var lockedObjectMaskCount = 0
    private(set) var visibleObjectMaskCount = 0
    private(set) var objectMaskMarkers: [ObjectMaskMarker] = []
    private(set) var objectMaskDisplayBoundingBoxes: [UUID: CGRect] = [:]
    private(set) var objectMaskFeedbackText: String?
    private(set) var objectMaskToggleRequest: ObjectMaskToggleRequest?
    private(set) var objectWorkflowRequest: ObjectWorkflowRequest?
    private(set) var isObjectSelectionPending = false
    private(set) var statusText = defaultPrompt
    private(set) var isMeshVisible = false
    private(set) var showsSelectedPoints = true
    private(set) var showsLiveMaskPreview = true
    private(set) var showsLockedMaskPreviews = true
    private(set) var showsBoundingBoxes = true
    private(set) var showsObjectMaskMarkers = true
    private(set) var resetRevision = 0
    private(set) var objectMaskToggleRequestRevision = 0
    private(set) var objectWorkflowRequestRevision = 0
    private(set) var pointCleanupRequestRevision = 0
    private(set) var isPointCleanupInProgress = false
    private(set) var pointCleanupFeedbackText: String?
    private var latestObjectMaskPreviewTimestamp: TimeInterval = -.greatestFiniteMagnitude
    private var pointCleanupFeedbackTask: Task<Void, Never>?
    private var captureOrder: [UUID] = []
    private var objectColorsByID: [UUID: ObjectMaskDisplayColor] = [:]
    private var objectWeightsInKilogramsByID: [UUID: Double] = [:]
    private(set) var focusedCaptureID: UUID?
    private var lockedMaskLayersByID: [UUID: ObjectMaskPreviewLayer] = [:]
    private var lockedMaskLayerOrder: [UUID] = []
    private var liveMaskLayer: ObjectMaskPreviewLayer?
    private var objectMaskMarkerMissCounts: [UUID: Int] = [:]

    private static let defaultPrompt = "Center or tap a highlighted object to select it for measurement."

    private var displayObject: CapturedObject? {
        if let focusedCaptureID, let focused = capturedObjectsByID[focusedCaptureID] {
            return focused
        }
        return captureOrder.last.flatMap { capturedObjectsByID[$0] }
    }

    var hasCapture: Bool {
        !capturedObjectsByID.isEmpty
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
        !capturedObjectsByID.isEmpty
            || activeObjectID != nil
            || !finalizedObjectIDs.isEmpty
            || isObjectSelectionPending
            || lockedObjectMaskCount > 0
    }

    var canFinalizeActiveObject: Bool {
        activeObjectID.flatMap { capturedObjectsByID[$0] } != nil
    }

    var canReactivateFocusedObject: Bool {
        guard activeObjectID == nil,
              !isObjectSelectionPending,
              let focusedCaptureID else {
            return false
        }
        return finalizedObjectIDs.contains(focusedCaptureID)
            && capturedObjectsByID[focusedCaptureID] != nil
    }

    var measuredObjectIDs: [UUID] {
        captureOrder.filter {
            finalizedObjectIDs.contains($0)
                && capturedObjectsByID[$0] != nil
        }
    }

    func objectNumber(for id: UUID) -> Int? {
        captureOrder.firstIndex(of: id).map { $0 + 1 }
    }

    func objectColor(for id: UUID) -> ObjectMaskDisplayColor? {
        objectColorsByID[id]
    }

    func weightInKilograms(for id: UUID) -> Double? {
        return objectWeightsInKilogramsByID[id]
    }

    var statusHeadline: String {
        if activeObjectID != nil {
            return "Measuring object"
        }
        if !finalizedObjectIDs.isEmpty {
            return finalizedObjectIDs.count == 1
                ? "1 object locked"
                : "\(finalizedObjectIDs.count) objects locked"
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
        let prefix: String
        if activeObjectID != nil {
            prefix = "Measuring · "
        } else if finalizedObjectIDs.isEmpty {
            prefix = ""
        } else {
            prefix = "Locked \(finalizedObjectIDs.count) · "
        }
        return prefix + String(
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

    func requestVisiblePointCleanup() {
        guard !isPointCleanupInProgress else {
            return
        }
        guard let activeObjectID,
              capturedObjectsByID[activeObjectID] != nil else {
            pointCleanupFeedbackTask?.cancel()
            pointCleanupFeedbackText = "Select an object to measure, or unlock a finished object, before enhancing its cyan points."
            schedulePointCleanupFeedbackClear()
            return
        }
        pointCleanupFeedbackTask?.cancel()
        isPointCleanupInProgress = true
        pointCleanupFeedbackText = "Checking visible cyan points against the current mask…"
        pointCleanupRequestRevision += 1
    }

    func finishVisiblePointCleanup(removedCount: Int) {
        isPointCleanupInProgress = false
        if removedCount == 0 {
            pointCleanupFeedbackText = "All visible cyan points are inside the current mask."
        } else {
            pointCleanupFeedbackText = "\(removedCount) outside point\(removedCount == 1 ? "" : "s") removed."
        }
        schedulePointCleanupFeedbackClear()
    }

    func failVisiblePointCleanup() {
        isPointCleanupInProgress = false
        pointCleanupFeedbackText = "Keep the object being measured and its cyan points in view, then try again."
        schedulePointCleanupFeedbackClear()
    }

    func hideAllScanVisuals() {
        showsLiveMaskPreview = false
        showsLockedMaskPreviews = false
        showsBoundingBoxes = false
        showsSelectedPoints = false
        isMeshVisible = false
        showsObjectMaskMarkers = false
    }

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
        for layer in preview.layers {
            if let id = layer.trackedObjectID {
                if finalizedObjectIDs.contains(id), lockedMaskLayersByID[id] != nil {
                    continue
                }
                if lockedMaskLayersByID[id] == nil {
                    lockedMaskLayerOrder.append(id)
                }
                lockedMaskLayersByID[id] = layer
            } else {
                if let liveMaskLayer, liveMaskLayer.id != layer.id {
                    objectMaskDisplayBoundingBoxes.removeValue(
                        forKey: liveMaskLayer.id
                    )
                }
                liveMaskLayer = layer
            }
            if objectMaskDisplayBoundingBoxes[layer.id] == nil,
               let referenceBoundingBox = layer.referenceViewportBoundingBox {
                objectMaskDisplayBoundingBoxes[layer.id] = referenceBoundingBox
            }
        }
        rebuildObjectMaskPreview(timestamp: preview.timestamp)
    }

    func updateObjectMaskDisplayBoundingBoxes(_ boundingBoxes: [UUID: CGRect]) {
        let activeBoundingBoxes = boundingBoxes.filter {
            !finalizedObjectIDs.contains($0.key)
        }
        if objectMaskDisplayBoundingBoxes != activeBoundingBoxes {
            objectMaskDisplayBoundingBoxes = activeBoundingBoxes
        }
    }

    func updateLockedObjectMaskCount(_ count: Int) {
        lockedObjectMaskCount = count
        visibleObjectMaskCount = min(visibleObjectMaskCount, count)
        if count == 0 {
            objectMaskMarkers = []
            objectMaskMarkerMissCounts.removeAll()
            objectMaskFeedbackText = nil
        }
    }

    func updateObjectMaskTracking(visibleCount: Int, markers: [ObjectMaskMarker]) {
        visibleObjectMaskCount = min(max(visibleCount, 0), lockedObjectMaskCount)
        let retainedMarkers = retainedObjectMaskMarkers(markers)
        cacheObjectMaskColors(from: retainedMarkers)
        objectMaskMarkers = stabilizedObjectMaskMarkers(retainedMarkers)
        let lostCount = lostObjectMaskCount
        if isObjectSelectionPending {
            objectMaskFeedbackText = "Selecting object…"
        } else if activeObjectID != nil {
            objectMaskFeedbackText = lostCount > 0
                ? "The object being measured is currently outside the view. Its anchor is retained."
                : "Measuring one object. Lock it before selecting another."
        } else if lostCount > 0 {
            objectMaskFeedbackText = "\(finalizedObjectIDs.count) locked · \(lostCount) currently outside the view. Their results are retained."
        } else if finalizedObjectIDs.count >= 15 {
            objectMaskFeedbackText = "Maximum 15 objects reached."
        } else if !finalizedObjectIDs.isEmpty {
            objectMaskFeedbackText = "\(finalizedObjectIDs.count) object\(finalizedObjectIDs.count == 1 ? "" : "s") locked. Select another object to measure."
        } else {
            objectMaskFeedbackText = nil
        }
    }

    func updateObjectMaskMarkers(_ markers: [ObjectMaskMarker]) {
        let retainedMarkers = retainedObjectMaskMarkers(markers)
        cacheObjectMaskColors(from: retainedMarkers)
        let stabilizedMarkers = stabilizedObjectMaskMarkers(retainedMarkers)
        if objectMaskMarkers != stabilizedMarkers {
            objectMaskMarkers = stabilizedMarkers
        }
    }

    func reportObjectLockNeedsSurface() {
        isObjectSelectionPending = false
        objectMaskFeedbackText = "No stable surface was found at that point. Move slowly around it, then tap again."
    }

    func reportObjectLockNotFound() {
        isObjectSelectionPending = false
        objectMaskFeedbackText = "No separate object mask was found there. Keep the object fully visible and tap near its center."
    }

    func reportObjectLimitReached() {
        isObjectSelectionPending = false
        objectMaskFeedbackText = "Maximum 15 objects reached."
    }

    func requestObjectMaskToggle(at normalizedViewportPoint: CGPoint) {
        guard activeObjectID == nil else {
            objectMaskFeedbackText = "Lock the object being measured before selecting another."
            return
        }
        guard !isObjectSelectionPending else {
            objectMaskFeedbackText = "Object selection is already in progress."
            return
        }
        isObjectSelectionPending = true
        objectMaskToggleRequest = ObjectMaskToggleRequest(
            normalizedViewportPoint: normalizedViewportPoint
        )
        objectMaskFeedbackText = "Selecting object…"
        objectMaskToggleRequestRevision += 1
    }

    func cancelObjectSelection() {
        guard isObjectSelectionPending else {
            return
        }
        isObjectSelectionPending = false
        objectMaskFeedbackText = "Object selection was interrupted. Tap the object again."
    }

    func beginObjectMeasurement(id: UUID) {
        guard isObjectSelectionPending,
              !finalizedObjectIDs.contains(id),
              activeObjectID == nil || activeObjectID == id else {
            return
        }
        activeObjectID = id
        focusedCaptureID = id
        isObjectSelectionPending = false
        statusText = "Move around the selected object to measure all visible surfaces."
        objectMaskFeedbackText = "Measuring one object. Lock it before selecting another."
    }

    func focusFinalizedObject(id: UUID) {
        guard activeObjectID == nil,
              finalizedObjectIDs.contains(id),
              capturedObjectsByID[id] != nil else {
            return
        }
        focusedCaptureID = id
        isObjectSelectionPending = false
        objectMaskFeedbackText = "This object is locked. Unlock it to continue measuring it."
    }

    func finalizeActiveObject(weightInKilograms: Double) {
        guard weightInKilograms.isFinite,
              weightInKilograms > 0 else {
            objectMaskFeedbackText = "Enter a valid weight greater than zero before locking this object."
            return
        }
        guard let id = activeObjectID else {
            objectMaskFeedbackText = "Select an object to measure before locking it."
            return
        }
        guard capturedObjectsByID[id] != nil else {
            objectMaskFeedbackText = "Keep measuring until the object has a LiDAR box, then lock it."
            return
        }
        activeObjectID = nil
        finalizedObjectIDs.insert(id)
        objectWeightsInKilogramsByID[id] = weightInKilograms
        focusedCaptureID = id
        isObjectSelectionPending = false
        objectWorkflowRequest = ObjectWorkflowRequest(id: id, kind: .finalize)
        objectWorkflowRequestRevision += 1
        statusText = finalizedObjectIDs.count == 1
            ? "1 object locked. Select another object to measure."
            : "\(finalizedObjectIDs.count) objects locked. Select another object to measure."
        objectMaskFeedbackText = statusText
    }

    func updateWeight(id: UUID, weightInKilograms: Double) {
        guard finalizedObjectIDs.contains(id) else {
            objectMaskFeedbackText = "Only a locked object can have its saved weight updated."
            return
        }
        guard weightInKilograms.isFinite,
              weightInKilograms > 0 else {
            objectMaskFeedbackText = "Enter a valid weight greater than zero."
            return
        }
        objectWeightsInKilogramsByID[id] = weightInKilograms
        objectMaskFeedbackText = "Object weight updated."
    }

    func removeFinalizedObject(id: UUID) {
        guard finalizedObjectIDs.contains(id) else {
            return
        }
        guard !isObjectSelectionPending else {
            objectMaskFeedbackText = "Wait for the current object selection to finish before removing a locked object."
            return
        }
        finalizedObjectIDs.remove(id)
        capturedObjectsByID.removeValue(forKey: id)
        captureOrder.removeAll(where: { $0 == id })
        objectWeightsInKilogramsByID.removeValue(forKey: id)
        objectColorsByID.removeValue(forKey: id)
        lockedMaskLayersByID.removeValue(forKey: id)
        lockedMaskLayerOrder.removeAll(where: { $0 == id })
        objectMaskDisplayBoundingBoxes.removeValue(forKey: id)
        objectMaskMarkers.removeAll(where: { $0.id == id })
        objectMaskMarkerMissCounts.removeValue(forKey: id)
        if focusedCaptureID == id {
            focusedCaptureID = activeObjectID ?? measuredObjectIDs.last
        }
        rebuildObjectMaskPreview(timestamp: latestObjectMaskPreviewTimestamp)
        objectWorkflowRequest = ObjectWorkflowRequest(id: id, kind: .remove)
        objectWorkflowRequestRevision += 1
        if activeObjectID != nil {
            statusText = "Measuring object."
            objectMaskFeedbackText = "Locked object removed. The active measurement was not changed."
        } else if finalizedObjectIDs.isEmpty {
            statusText = Self.defaultPrompt
            objectMaskFeedbackText = "Locked object removed."
        } else {
            statusText = finalizedObjectIDs.count == 1
                ? "1 object locked."
                : "\(finalizedObjectIDs.count) objects locked."
            objectMaskFeedbackText = "Locked object removed."
        }
    }

    func reactivateFocusedObject() {
        guard activeObjectID == nil else {
            objectMaskFeedbackText = "Lock the object being measured before unlocking another."
            return
        }
        guard !isObjectSelectionPending else {
            objectMaskFeedbackText = "Wait for the current object selection to finish."
            return
        }
        guard let id = focusedCaptureID,
              finalizedObjectIDs.contains(id),
              capturedObjectsByID[id] != nil else {
            objectMaskFeedbackText = "Select a locked object to unlock it."
            return
        }
        finalizedObjectIDs.remove(id)
        activeObjectID = id
        isObjectSelectionPending = false
        objectWorkflowRequest = ObjectWorkflowRequest(id: id, kind: .reactivate)
        objectWorkflowRequestRevision += 1
        statusText = "Object unlocked. Continue measuring it."
        objectMaskFeedbackText = "Measuring one object. Lock it before selecting another."
    }

    func clearObjectMaskPreview() {
        objectMaskPreview = nil
        lockedMaskLayersByID.removeAll()
        lockedMaskLayerOrder.removeAll()
        liveMaskLayer = nil
        objectMaskDisplayBoundingBoxes.removeAll()
        latestObjectMaskPreviewTimestamp = -.greatestFiniteMagnitude
    }

    func clearLiveObjectMaskPreview() {
        if let liveMaskLayer {
            objectMaskDisplayBoundingBoxes.removeValue(forKey: liveMaskLayer.id)
        }
        liveMaskLayer = nil
        rebuildObjectMaskPreview(timestamp: latestObjectMaskPreviewTimestamp)
    }

    func clearTransientObjectMaskPreviews() {
        if let liveMaskLayer {
            objectMaskDisplayBoundingBoxes.removeValue(forKey: liveMaskLayer.id)
        }
        liveMaskLayer = nil
        if let activeObjectID {
            lockedMaskLayersByID.removeValue(forKey: activeObjectID)
            lockedMaskLayerOrder.removeAll(where: { $0 == activeObjectID })
            objectMaskDisplayBoundingBoxes.removeValue(forKey: activeObjectID)
        }
        rebuildObjectMaskPreview(timestamp: latestObjectMaskPreviewTimestamp)
    }

    func clearObjectMaskDisplayTracking(id: UUID) {
        objectMaskDisplayBoundingBoxes.removeValue(forKey: id)
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

    private func stabilizedObjectMaskMarkers(
        _ incoming: [ObjectMaskMarker]
    ) -> [ObjectMaskMarker] {
        let incomingIDs = Set(incoming.map(\.id))
        var result = incoming
        for marker in objectMaskMarkers where !incomingIDs.contains(marker.id) {
            let misses = (objectMaskMarkerMissCounts[marker.id] ?? 0) + 1
            if misses <= 3 {
                objectMaskMarkerMissCounts[marker.id] = misses
                result.append(marker)
            } else {
                objectMaskMarkerMissCounts.removeValue(forKey: marker.id)
            }
        }
        for id in incomingIDs {
            objectMaskMarkerMissCounts.removeValue(forKey: id)
        }
        return result
    }

    private func cacheObjectMaskColors(from markers: [ObjectMaskMarker]) {
        for marker in markers
        where activeObjectID == marker.id
            || finalizedObjectIDs.contains(marker.id)
            || capturedObjectsByID[marker.id] != nil {
            objectColorsByID[marker.id] = marker.color
        }
    }

    private func retainedObjectMaskMarkers(
        _ markers: [ObjectMaskMarker]
    ) -> [ObjectMaskMarker] {
        markers.filter {
            activeObjectID == $0.id
                || finalizedObjectIDs.contains($0.id)
                || capturedObjectsByID[$0.id] != nil
        }
    }

    func updateCapture(id: UUID, object: CapturedObject) {
        guard activeObjectID == id else {
            return
        }
        if capturedObjectsByID[id] == nil {
            captureOrder.append(id)
        }
        capturedObjectsByID[id] = object
        focusedCaptureID = id
        statusText = "LiDAR box ready. Continue scanning or lock this object."
    }

    func focusCapture(id: UUID) {
        guard capturedObjectsByID[id] != nil else { return }
        focusedCaptureID = id
    }

    private func schedulePointCleanupFeedbackClear() {
        pointCleanupFeedbackTask?.cancel()
        pointCleanupFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else {
                return
            }
            self?.pointCleanupFeedbackText = nil
        }
    }

    func reset() {
        pointCleanupFeedbackTask?.cancel()
        pointCleanupFeedbackTask = nil
        capturedObjectsByID.removeAll()
        activeObjectID = nil
        finalizedObjectIDs.removeAll()
        captureOrder.removeAll()
        objectColorsByID.removeAll()
        objectWeightsInKilogramsByID.removeAll()
        focusedCaptureID = nil
        isObjectSelectionPending = false
        objectWorkflowRequest = nil
        objectMaskPreview = nil
        lockedMaskLayersByID.removeAll()
        lockedMaskLayerOrder.removeAll()
        liveMaskLayer = nil
        objectMaskDisplayBoundingBoxes.removeAll()
        latestObjectMaskPreviewTimestamp = -.greatestFiniteMagnitude
        lockedObjectMaskCount = 0
        visibleObjectMaskCount = 0
        objectMaskMarkers = []
        objectMaskMarkerMissCounts.removeAll()
        objectMaskFeedbackText = nil
        pointCleanupFeedbackText = nil
        isPointCleanupInProgress = false
        objectMaskToggleRequest = nil
        statusText = Self.defaultPrompt
        resetRevision += 1
    }
}
