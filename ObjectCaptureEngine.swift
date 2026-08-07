
import Foundation
import Observation
import simd

enum ObjectWorkflowRequestKind: Sendable {
    case pauseFinalization
    case resumeFinalization
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
    private(set) var measurementMode: MeasurementWorkflowMode = .spatial3D
    private(set) var capturedObjectsByID: [UUID: CapturedObject] = [:]
    private(set) var activeObjectID: UUID?
    private(set) var pendingFinalizationObjectID: UUID?
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
    private(set) var showsSelectedObjectMaskPreview = true
    private(set) var showsBoundingBoxes = true
    private(set) var showsObjectMaskMarkers = true
    private(set) var hasCompletedObjectRecognitionWarmup = false
    private(set) var resetRevision = 0
    private(set) var objectMaskToggleRequestRevision = 0
    private(set) var objectWorkflowRequestRevision = 0
    private var latestObjectMaskPreviewTimestamp: TimeInterval = -.greatestFiniteMagnitude
    private var captureOrder: [UUID] = []
    private var objectColorsByID: [UUID: ObjectMaskDisplayColor] = [:]
    private var objectNamesByID: [UUID: String] = [:]
    private var objectWeightsInKilogramsByID: [UUID: Double] = [:]
    private(set) var focusedCaptureID: UUID?
    private var lockedMaskLayersByID: [UUID: ObjectMaskPreviewLayer] = [:]
    private var lockedMaskLayerOrder: [UUID] = []
    private var liveMaskLayer: ObjectMaskPreviewLayer?
    private var objectMaskMarkerMissCounts: [UUID: Int] = [:]

    /// Which camera viewpoint the operator currently holds relative to the active object. Drives the
    /// on-screen face guide: width/length are captured from a top-down view, height from a side view.
    enum ScanViewHint: Equatable {
        case topDown
        case side
        case other
    }

    private(set) var scanViewHint: ScanViewHint = .other
    /// Whether the active object's footprint (width × length, from a top view) and height (from a
    /// side view) have converged — held steady for several fits. Guidance only, not measurement.
    private(set) var footprintSatisfied = false
    private(set) var heightSatisfied = false
    private(set) var topViewDeviationDegrees: Int?
    private(set) var isTopViewAligned = false
    private(set) var topMeasurementStable = false
    /// A definitive ARKit plane currently covers the active object's footprint. A global plane
    /// elsewhere in the scene is not sufficient for committing a height measurement.
    private(set) var hasDefinitiveSupportPlaneForActiveObject = false

    /// True once both the footprint and height have converged — the object is fully measured.
    var measurementSatisfied: Bool {
        switch measurementMode {
        case .spatial3D:
            footprintSatisfied && heightSatisfied
        case .top:
            topMeasurementStable
        }
    }

    private static let defaultPrompt = "Center or tap a highlighted object to select it for measurement."

    private var activeMeasurementPrompt: String {
        switch measurementMode {
        case .spatial3D:
            "Move around the selected object to measure all visible surfaces."
        case .top:
            "Move above the selected object and point the camera straight down."
        }
    }

    private var idleMeasurementPrompt: String {
        measurementMode == .top
            ? "Top mode ready. Point down and select an object."
            : Self.defaultPrompt
    }

    private var activeMaskFeedback: String {
        measurementMode == .top
            ? "Measuring one object from above. Hold the phone pointed down, then lock it."
            : "Measuring one object. Lock it before selecting another."
    }

    func setMeasurementMode(_ mode: MeasurementWorkflowMode) {
        guard measurementMode != mode else {
            return
        }
        measurementMode = mode
        reset()
        statusText = idleMeasurementPrompt
    }

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
        showsLiveMaskPreview || showsSelectedObjectMaskPreview
    }

    var lostObjectMaskCount: Int {
        max(lockedObjectMaskCount - visibleObjectMaskCount, 0)
    }

    var canReset: Bool {
        !capturedObjectsByID.isEmpty
            || activeObjectID != nil
            || pendingFinalizationObjectID != nil
            || !finalizedObjectIDs.isEmpty
            || isObjectSelectionPending
            || lockedObjectMaskCount > 0
    }

    var canFinalizeActiveObject: Bool {
        pendingFinalizationObjectID == nil
            && activeObjectID.flatMap { capturedObjectsByID[$0] } != nil
            && hasDefinitiveSupportPlaneForActiveObject
    }

    var isFinalizationPending: Bool {
        pendingFinalizationObjectID != nil
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

    var focusedObjectID: UUID? {
        focusedCaptureID
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

    func name(for id: UUID) -> String? {
        objectNamesByID[id]
    }

    var statusHeadline: String {
        if isFinalizationPending {
            return "Measurement paused"
        }
        if activeObjectID != nil {
            return "Measuring object"
        }
        if !finalizedObjectIDs.isEmpty {
            return finalizedObjectIDs.count == 1
                ? "1 object locked"
                : "\(finalizedObjectIDs.count) objects locked"
        }
        return "Ready to scan"
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

    func toggleSelectedObjectMaskPreview() {
        showsSelectedObjectMaskPreview.toggle()
    }

    func toggleSegmentationOverlays() {
        let shouldShow = !showsSegmentationOverlays
        showsLiveMaskPreview = shouldShow
        showsSelectedObjectMaskPreview = shouldShow
    }

    func toggleBoundingBoxes() {
        showsBoundingBoxes.toggle()
    }

    func toggleObjectMaskMarkers() {
        showsObjectMaskMarkers.toggle()
    }

    func hideAllScanVisuals() {
        showsLiveMaskPreview = false
        showsSelectedObjectMaskPreview = false
        showsBoundingBoxes = false
        showsSelectedPoints = false
        isMeshVisible = false
        showsObjectMaskMarkers = false
    }

    func showResultsOnly() {
        showsLiveMaskPreview = false
        showsSelectedObjectMaskPreview = false
        showsBoundingBoxes = true
        showsSelectedPoints = false
        isMeshVisible = false
        showsObjectMaskMarkers = false
    }

    func showObjectMaskPreview(_ preview: ObjectMaskPreview) {
        guard pendingFinalizationObjectID == nil else {
            return
        }
        guard preview.timestamp >= latestObjectMaskPreviewTimestamp else {
            return
        }
        latestObjectMaskPreviewTimestamp = preview.timestamp
        for layer in preview.layers {
            if let id = layer.trackedObjectID {
                if finalizedObjectIDs.contains(id) {
                    hideObjectMask(id: id, timestamp: preview.timestamp)
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
        if isFinalizationPending {
            objectMaskFeedbackText = "Measurement paused. Save to lock it, or Cancel to continue."
        } else if isObjectSelectionPending {
            objectMaskFeedbackText = "Selecting object…"
        } else if activeObjectID != nil {
            objectMaskFeedbackText = lostCount > 0
                ? "The object being measured is currently outside the view. Its anchor is retained."
                : activeMaskFeedback
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

    func reportObjectSelectionNotReady() {
        isObjectSelectionPending = false
        objectMaskFeedbackText = "Wait for Environment ready before selecting an object."
    }

    func reportObjectRecognitionPreparing() {
        isObjectSelectionPending = false
        objectMaskFeedbackText = "Object recognition is preparing. Keep an object near the center for a moment."
    }

    func reportObjectRecognitionFailure() {
        isObjectSelectionPending = false
        objectMaskFeedbackText = "Object recognition had a temporary problem. Hold steady and tap the object again."
    }

    func markObjectRecognitionWarmupCompleted() {
        hasCompletedObjectRecognitionWarmup = true
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
              pendingFinalizationObjectID == nil,
              !finalizedObjectIDs.contains(id),
              activeObjectID == nil || activeObjectID == id else {
            return
        }
        resetScanGuidance()
        hasDefinitiveSupportPlaneForActiveObject = false
        activeObjectID = id
        focusedCaptureID = id
        isObjectSelectionPending = false
        statusText = activeMeasurementPrompt
        objectMaskFeedbackText = activeMaskFeedback
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

    @discardableResult
    func beginFinalization() -> UUID? {
        guard pendingFinalizationObjectID == nil,
              let id = activeObjectID else {
            return nil
        }
        guard capturedObjectsByID[id] != nil else {
            objectMaskFeedbackText = "Keep measuring until the object has a LiDAR box, then lock it."
            return nil
        }
        guard hasDefinitiveSupportPlaneForActiveObject else {
            objectMaskFeedbackText = "Scan the floor or table directly beneath this object before locking it."
            return nil
        }

        pendingFinalizationObjectID = id
        isObjectSelectionPending = false
        clearTransientObjectMaskPreviews()
        objectWorkflowRequest = ObjectWorkflowRequest(
            id: id,
            kind: .pauseFinalization
        )
        objectWorkflowRequestRevision += 1
        statusText = "Measurement paused at the current dimensions."
        objectMaskFeedbackText = "Save to lock it, or Cancel to continue measuring."
        return id
    }

    /// Cancels a Lock that raced with an ARKit plane removal between the button tap and commit.
    func rejectPendingFinalizationWithoutSupportPlane() {
        guard let id = pendingFinalizationObjectID else {
            return
        }
        pendingFinalizationObjectID = nil
        hasDefinitiveSupportPlaneForActiveObject = false
        guard activeObjectID == id,
              capturedObjectsByID[id] != nil else {
            return
        }
        objectWorkflowRequest = ObjectWorkflowRequest(
            id: id,
            kind: .resumeFinalization
        )
        objectWorkflowRequestRevision += 1
        statusText = activeMeasurementPrompt
        objectMaskFeedbackText = "Support moved. Scan the floor or table beneath the object, then lock again."
    }

    func cancelPendingFinalization() {
        guard let id = pendingFinalizationObjectID else {
            return
        }
        pendingFinalizationObjectID = nil
        guard activeObjectID == id,
              capturedObjectsByID[id] != nil else {
            return
        }
        objectWorkflowRequest = ObjectWorkflowRequest(
            id: id,
            kind: .resumeFinalization
        )
        objectWorkflowRequestRevision += 1
        statusText = activeMeasurementPrompt
        objectMaskFeedbackText = "Measurement resumed. Lock it when the box is ready."
    }

    func finalizeActiveObject(
        name: String,
        weightInKilograms: Double
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            objectMaskFeedbackText = "Enter a name before locking this object."
            return
        }
        guard weightInKilograms.isFinite,
              weightInKilograms > 0 else {
            objectMaskFeedbackText = "Enter a valid weight greater than zero before locking this object."
            return
        }
        guard hasDefinitiveSupportPlaneForActiveObject else {
            rejectPendingFinalizationWithoutSupportPlane()
            return
        }
        guard let id = activeObjectID,
              pendingFinalizationObjectID == id else {
            objectMaskFeedbackText = "Select an object to measure before locking it."
            return
        }
        guard capturedObjectsByID[id] != nil else {
            objectMaskFeedbackText = "Keep measuring until the object has a LiDAR box, then lock it."
            return
        }
        pendingFinalizationObjectID = nil
        activeObjectID = nil
        hasDefinitiveSupportPlaneForActiveObject = false
        finalizedObjectIDs.insert(id)
        resetScanGuidance()
        hideObjectMask(id: id)
        objectNamesByID[id] = trimmedName
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

    func updateDetails(
        id: UUID,
        name: String,
        weightInKilograms: Double
    ) {
        guard finalizedObjectIDs.contains(id) else {
            objectMaskFeedbackText = "Only a locked object can have its details updated."
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            objectMaskFeedbackText = "Enter a name for this object."
            return
        }
        guard weightInKilograms.isFinite,
              weightInKilograms > 0 else {
            objectMaskFeedbackText = "Enter a valid weight greater than zero."
            return
        }
        objectNamesByID[id] = trimmedName
        objectWeightsInKilogramsByID[id] = weightInKilograms
        objectMaskFeedbackText = "Object name and weight updated."
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
        objectNamesByID.removeValue(forKey: id)
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
            statusText = idleMeasurementPrompt
            objectMaskFeedbackText = "Locked object removed."
        } else {
            statusText = finalizedObjectIDs.count == 1
                ? "1 object locked."
                : "\(finalizedObjectIDs.count) objects locked."
            objectMaskFeedbackText = "Locked object removed."
        }
    }

    func reactivateFocusedObject() {
        guard activeObjectID == nil,
              pendingFinalizationObjectID == nil else {
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
        resetScanGuidance()
        hasDefinitiveSupportPlaneForActiveObject = false
        activeObjectID = id
        isObjectSelectionPending = false
        objectWorkflowRequest = ObjectWorkflowRequest(id: id, kind: .reactivate)
        objectWorkflowRequestRevision += 1
        statusText = measurementMode == .top
            ? "Object unlocked. Continue measuring it from above."
            : "Object unlocked. Continue measuring it."
        objectMaskFeedbackText = activeMaskFeedback
    }

    /// Publishes the current viewpoint and per-dimension capture status for the face guide.
    func updateScanGuidance(view: ScanViewHint, footprintSatisfied: Bool, heightSatisfied: Bool) {
        if scanViewHint != view {
            scanViewHint = view
        }
        if self.footprintSatisfied != footprintSatisfied {
            self.footprintSatisfied = footprintSatisfied
        }
        if self.heightSatisfied != heightSatisfied {
            self.heightSatisfied = heightSatisfied
        }
    }

    func updateTopViewAlignment(
        deviationDegrees: Int?,
        isAligned: Bool
    ) {
        if topViewDeviationDegrees != deviationDegrees {
            topViewDeviationDegrees = deviationDegrees
        }
        if isTopViewAligned != isAligned {
            isTopViewAligned = isAligned
        }
    }

    func updateTopMeasurementGuidance(isStable: Bool) {
        if topMeasurementStable != isStable {
            topMeasurementStable = isStable
        }
        updateScanGuidance(
            view: .topDown,
            footprintSatisfied: isStable,
            heightSatisfied: isStable
        )
    }

    func updateActiveSupportPlaneAvailability(
        id: UUID,
        isAvailable: Bool
    ) {
        guard activeObjectID == id,
              pendingFinalizationObjectID == nil else {
            return
        }
        if hasDefinitiveSupportPlaneForActiveObject != isAvailable {
            hasDefinitiveSupportPlaneForActiveObject = isAvailable
        }
    }

    func resetScanGuidance() {
        scanViewHint = .other
        footprintSatisfied = false
        heightSatisfied = false
        topMeasurementStable = false
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

    private func hideObjectMask(
        id: UUID,
        timestamp: TimeInterval? = nil
    ) {
        lockedMaskLayersByID.removeValue(forKey: id)
        lockedMaskLayerOrder.removeAll(where: { $0 == id })
        objectMaskDisplayBoundingBoxes.removeValue(forKey: id)
        rebuildObjectMaskPreview(
            timestamp: timestamp ?? latestObjectMaskPreviewTimestamp
        )
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
        guard activeObjectID == id,
              pendingFinalizationObjectID != id else {
            return
        }
        if capturedObjectsByID[id] == nil {
            captureOrder.append(id)
        }
        capturedObjectsByID[id] = object
        focusedCaptureID = id
        statusText = measurementMode == .top
            ? "Overhead LiDAR fit ready. Hold steady or lock this object."
            : "LiDAR box ready. Continue scanning or lock this object."
    }

    /// Updates geometry while the coordinator changes only its ARKit support-anchor frame. Unlike
    /// a live fit, this is also valid during the Lock sheet and for an already locked object.
    func updateAnchoredCapture(id: UUID, object: CapturedObject) {
        guard capturedObjectsByID[id] != nil,
              activeObjectID == id || finalizedObjectIDs.contains(id) else {
            return
        }
        capturedObjectsByID[id] = object
    }

    func focusCapture(id: UUID) {
        guard capturedObjectsByID[id] != nil else { return }
        focusedCaptureID = id
    }

    func reset() {
        capturedObjectsByID.removeAll()
        activeObjectID = nil
        pendingFinalizationObjectID = nil
        hasDefinitiveSupportPlaneForActiveObject = false
        finalizedObjectIDs.removeAll()
        captureOrder.removeAll()
        objectColorsByID.removeAll()
        objectNamesByID.removeAll()
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
        objectMaskToggleRequest = nil
        statusText = idleMeasurementPrompt
        hasCompletedObjectRecognitionWarmup = false
        resetScanGuidance()
        topViewDeviationDegrees = nil
        isTopViewAligned = false
        resetRevision += 1
    }
}
