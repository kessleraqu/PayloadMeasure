import CoreGraphics
import Foundation
import Observation
import simd

// The measurement session's state: which object is being measured, which are finished, their names
// and weights, and everything the HUD reads.
//
// In:  fit results and guidance from the AR coordinator, and operator actions from the overlay.
// Out: observable state. Also raises workflow requests - finalize, reactivate, remove - that the
//      coordinator acts on.

nonisolated enum ObjectFramingGuidance: String, Sendable, Equatable, CaseIterable {
    case moveCloser
    case moveFarther
    case okay
}

enum ObjectWorkflowRequestKind: Sendable {
    case finalize
    case reactivate
    case remove
}

struct ObjectWorkflowRequest: @unchecked Sendable {
    let id: UUID
    let kind: ObjectWorkflowRequestKind
    let snapshotViewportBoundingBox: CGRect?

    init(
        id: UUID,
        kind: ObjectWorkflowRequestKind,
        snapshotViewportBoundingBox: CGRect? = nil
    ) {
        self.id = id
        self.kind = kind
        self.snapshotViewportBoundingBox = snapshotViewportBoundingBox
    }
}

@MainActor
@Observable
final class ObjectCaptureEngine {
    private enum MeasurementDetailStatus {
        case unknown
        case needsCloser
        case sufficient
    }

    private static let maximumSnapshotJPEGByteCount = 512_000
    private(set) var measurementMode: MeasurementWorkflowMode = .spatial3D
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
    private(set) var showsLiveMaskPreview = false
    private(set) var showsSelectedObjectMaskPreview = false
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
    private var snapshotJPEGDataByObjectID: [UUID: Data] = [:]
    private(set) var focusedCaptureID: UUID?
    private var lockedMaskLayersByID: [UUID: ObjectMaskPreviewLayer] = [:]
    private var lockedMaskLayerOrder: [UUID] = []
    private var liveMaskLayer: ObjectMaskPreviewLayer?
    private var objectMaskMarkerMissCounts: [UUID: Int] = [:]

    enum ScanViewHint: Equatable {
        case topDown
        case side
        case other
    }

    private(set) var scanViewHint: ScanViewHint = .other
    private(set) var footprintSatisfied = false
    private(set) var heightSatisfied = false
    private(set) var topViewDeviationDegrees: Int?
    private(set) var isTopViewAligned = false
    private(set) var topMeasurementStable = false
    private(set) var hasDefinitiveSupportPlaneForActiveObject = false
    private(set) var framingGuidance: ObjectFramingGuidance?
    private var measurementDetailStatus: MeasurementDetailStatus = .unknown
    private var didEncounterInsufficientFit = false

    // MARK: - Automatic lock

    private(set) var convergence: MeasurementConvergence = .idle
    private(set) var isAutomaticLockEnabled = true
    private(set) var automaticLockRequest: UUID?
    private(set) var automaticLockRequestRevision = 0
    private var convergenceMonitor = MeasurementConvergenceMonitor()
    private var automaticLockOfferedObjectIDs: Set<UUID> = []

    var isAutomaticLockDisarmedForActiveObject: Bool {
        guard isAutomaticLockEnabled, let activeObjectID else {
            return false
        }
        return automaticLockOfferedObjectIDs.contains(activeObjectID)
    }

    func setAutomaticLockEnabled(_ isEnabled: Bool) {
        guard isAutomaticLockEnabled != isEnabled else {
            return
        }
        isAutomaticLockEnabled = isEnabled
        if isEnabled, let activeObjectID {
            automaticLockOfferedObjectIDs.remove(activeObjectID)
        }
        refreshConvergence()
    }

    private func resetConvergence() {
        convergenceMonitor.reset()
        if convergence != .idle {
            convergence = .idle
        }
        automaticLockRequest = nil
    }

    func recordDimensionObservation(_ axis: MeasurementAxis, value: Float) {
        guard activeObjectID != nil else {
            return
        }
        convergenceMonitor.record(
            axis,
            value: value,
            at: ProcessInfo.processInfo.systemUptime
        )
    }

    func refreshConvergence() {
        let isMeasuring = activeObjectID != nil
        let coverage = MeasurementConvergenceMonitor.Coverage(
            isMeasuring: isMeasuring,
            hasSupportPlane: hasDefinitiveSupportPlaneForActiveObject,
            reportsSideViewSeparately: measurementMode == .spatial3D
        )
        let updated = convergenceMonitor.evaluate(
            coverage: coverage,
            now: ProcessInfo.processInfo.systemUptime
        )
        if convergence != updated {
            convergence = updated
        }
        requestAutomaticLockIfConverged()
    }

    private func requestAutomaticLockIfConverged() {
        guard isAutomaticLockEnabled,
              convergence.isConverged,
              canFinalizeActiveObject,
              let id = activeObjectID,
              !automaticLockOfferedObjectIDs.contains(id) else {
            return
        }
        automaticLockOfferedObjectIDs.insert(id)
        automaticLockRequest = id
        automaticLockRequestRevision += 1
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
            ? "Measuring one object from above. Hold the phone pointed down, then finish it."
            : "Measuring one object. Finish it before selecting another."
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
            || !finalizedObjectIDs.isEmpty
            || isObjectSelectionPending
            || lockedObjectMaskCount > 0
    }

    var canFinalizeActiveObject: Bool {
        activeObjectID.flatMap { capturedObjectsByID[$0] } != nil
            && hasDefinitiveSupportPlaneForActiveObject
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

    /// Editing is offered only while the operator is actually pointing at a finished object, so the
    /// focus has to be backed by a marker visible in this frame rather than by whatever was last
    /// looked at.
    var canEditFocusedObject: Bool {
        guard canReactivateFocusedObject, let focusedCaptureID else { return false }
        return objectMaskMarkers.contains { $0.id == focusedCaptureID }
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

    func weightInGrams(for id: UUID) -> Double? {
        guard let kilograms = objectWeightsInKilogramsByID[id] else {
            return nil
        }
        let grams = kilograms * 1_000
        return grams.isFinite ? grams : nil
    }

    func name(for id: UUID) -> String? {
        objectNamesByID[id]
    }

    func snapshotJPEGData(for id: UUID) -> Data? {
        snapshotJPEGDataByObjectID[id]
    }

    func setSnapshotJPEGData(_ data: Data, for id: UUID) {
        guard finalizedObjectIDs.contains(id),
              capturedObjectsByID[id] != nil,
              !data.isEmpty,
              data.count <= Self.maximumSnapshotJPEGByteCount else {
            return
        }
        snapshotJPEGDataByObjectID[id] = data
    }

    func clearSnapshotJPEGData(for id: UUID) {
        snapshotJPEGDataByObjectID.removeValue(forKey: id)
    }

    func clearAllSnapshotJPEGData() {
        snapshotJPEGDataByObjectID.removeAll()
    }

    var statusHeadline: String {
        if activeObjectID != nil {
            return "Measuring object"
        }
        if !finalizedObjectIDs.isEmpty {
            return finalizedObjectIDs.count == 1
                ? "1 object measured"
                : "\(finalizedObjectIDs.count) objects measured"
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
        refreshFramingGuidance()
    }

    func updateObjectMaskDisplayBoundingBoxes(_ boundingBoxes: [UUID: CGRect]) {
        let activeBoundingBoxes = boundingBoxes.filter {
            !finalizedObjectIDs.contains($0.key)
        }
        if objectMaskDisplayBoundingBoxes != activeBoundingBoxes {
            objectMaskDisplayBoundingBoxes = activeBoundingBoxes
        }
        refreshFramingGuidance()
    }

    func updateActiveMeasurementDetail(
        id: UUID,
        stablePointCount: Int
    ) {
        guard activeObjectID == id else {
            return
        }
        let hasPublishedMeasurement = capturedObjectsByID[id] != nil
        let updated: MeasurementDetailStatus
        if hasPublishedMeasurement {
            updated = .sufficient
        } else if didEncounterInsufficientFit {
            updated = .needsCloser
        } else {
            updated = stablePointCount >= ObjectCapturePipeline.minimumClusterPoints
                ? .sufficient
                : .needsCloser
        }
        guard measurementDetailStatus != updated else {
            return
        }
        measurementDetailStatus = updated
        refreshFramingGuidance()
    }

    func reportActiveMeasurementNeedsMoreDetail(id: UUID) {
        guard activeObjectID == id,
              capturedObjectsByID[id] == nil else {
            return
        }
        didEncounterInsufficientFit = true
        if measurementDetailStatus != .needsCloser {
            measurementDetailStatus = .needsCloser
            refreshFramingGuidance()
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
                : activeMaskFeedback
        } else if lostCount > 0 {
            objectMaskFeedbackText = "\(finalizedObjectIDs.count) measured · \(lostCount) currently outside the view. Their results are retained."
        } else if finalizedObjectIDs.count >= 15 {
            objectMaskFeedbackText = "Maximum 15 objects reached."
        } else if !finalizedObjectIDs.isEmpty {
            objectMaskFeedbackText = "\(finalizedObjectIDs.count) object\(finalizedObjectIDs.count == 1 ? "" : "s") measured. Select another object to measure."
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
            objectMaskFeedbackText = "Finish the object being measured before selecting another."
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
        resetScanGuidance()
        automaticLockOfferedObjectIDs.remove(id)
        hasDefinitiveSupportPlaneForActiveObject = false
        measurementDetailStatus = .unknown
        didEncounterInsufficientFit = false
        activeObjectID = id
        refreshFramingGuidance()
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
        objectMaskFeedbackText = "This object is finished. Tap Edit to continue measuring it."
    }

    @discardableResult
    func lockActiveObject() -> UUID? {
        guard let id = activeObjectID else {
            objectMaskFeedbackText = "Select an object to measure before finishing it."
            return nil
        }
        guard capturedObjectsByID[id] != nil else {
            objectMaskFeedbackText = "Keep measuring until the object has a LiDAR box, then finish it."
            return nil
        }
        guard hasDefinitiveSupportPlaneForActiveObject else {
            objectMaskFeedbackText = "Scan the floor or table directly beneath this object before finishing it."
            return nil
        }

        let snapshotViewportBoundingBox = objectMaskDisplayBoundingBoxes[id]
        activeObjectID = nil
        hasDefinitiveSupportPlaneForActiveObject = false
        finalizedObjectIDs.insert(id)
        resetScanGuidance()
        hideObjectMask(id: id)
        clearTransientObjectMaskPreviews()
        focusedCaptureID = id
        isObjectSelectionPending = false
        objectWorkflowRequest = ObjectWorkflowRequest(
            id: id,
            kind: .finalize,
            snapshotViewportBoundingBox: snapshotViewportBoundingBox
        )
        objectWorkflowRequestRevision += 1
        statusText = "Measurement saved. Select the next object."
        objectMaskFeedbackText = statusText
        return id
    }

    /// Throws away the measurement in progress and deselects the object. It was never finalized, so
    /// nothing is kept — same teardown as removing a finished object.
    func cancelActiveMeasurement() {
        guard let id = activeObjectID else { return }

        activeObjectID = nil
        hasDefinitiveSupportPlaneForActiveObject = false
        isObjectSelectionPending = false
        measurementDetailStatus = .unknown
        didEncounterInsufficientFit = false

        capturedObjectsByID.removeValue(forKey: id)
        captureOrder.removeAll { $0 == id }
        objectNamesByID.removeValue(forKey: id)
        objectWeightsInKilogramsByID.removeValue(forKey: id)
        clearSnapshotJPEGData(for: id)
        objectColorsByID.removeValue(forKey: id)
        lockedMaskLayersByID.removeValue(forKey: id)
        lockedMaskLayerOrder.removeAll { $0 == id }
        objectMaskDisplayBoundingBoxes.removeValue(forKey: id)
        objectMaskMarkers.removeAll { $0.id == id }
        objectMaskMarkerMissCounts.removeValue(forKey: id)
        automaticLockOfferedObjectIDs.remove(id)

        resetScanGuidance()
        hideObjectMask(id: id)
        clearTransientObjectMaskPreviews()
        focusedCaptureID = measuredObjectIDs.last
        rebuildObjectMaskPreview(timestamp: latestObjectMaskPreviewTimestamp)

        objectWorkflowRequest = ObjectWorkflowRequest(id: id, kind: .remove)
        objectWorkflowRequestRevision += 1

        statusText = finalizedObjectIDs.isEmpty
            ? idleMeasurementPrompt
            : finalizedObjectIDs.count == 1
                ? "1 object measured."
                : "\(finalizedObjectIDs.count) objects measured."
        objectMaskFeedbackText = "Measurement cancelled. Tap an object to start again."
    }

    func updateName(id: UUID, name: String) {
        guard finalizedObjectIDs.contains(id) else {
            objectMaskFeedbackText = "Only a finished object can have its name updated."
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            objectMaskFeedbackText = "Enter a name for this object."
            return
        }
        objectNamesByID[id] = trimmedName
        objectMaskFeedbackText = "Object name updated."
    }

    func updatePackedWeight(id: UUID, weightInGrams: Double) {
        guard finalizedObjectIDs.contains(id) else {
            objectMaskFeedbackText = "Only a finished object can have its weight updated."
            return
        }
        guard weightInGrams.isFinite,
              weightInGrams > 0 else {
            objectMaskFeedbackText = "Enter a valid weight greater than zero."
            return
        }
        let kilograms = weightInGrams / 1_000
        guard kilograms.isFinite, kilograms > 0 else {
            objectMaskFeedbackText = "Enter a valid weight greater than zero."
            return
        }
        objectWeightsInKilogramsByID[id] = kilograms
        objectMaskFeedbackText = "Packed weight updated."
    }

    func updateDetails(
        id: UUID,
        name: String,
        weightInKilograms: Double
    ) {
        guard finalizedObjectIDs.contains(id) else {
            objectMaskFeedbackText = "Only a finished object can have its details updated."
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
            objectMaskFeedbackText = "Wait for the current object selection to finish before removing a measured object."
            return
        }
        finalizedObjectIDs.remove(id)
        capturedObjectsByID.removeValue(forKey: id)
        captureOrder.removeAll(where: { $0 == id })
        objectNamesByID.removeValue(forKey: id)
        objectWeightsInKilogramsByID.removeValue(forKey: id)
        clearSnapshotJPEGData(for: id)
        objectColorsByID.removeValue(forKey: id)
        lockedMaskLayersByID.removeValue(forKey: id)
        lockedMaskLayerOrder.removeAll(where: { $0 == id })
        objectMaskDisplayBoundingBoxes.removeValue(forKey: id)
        objectMaskMarkers.removeAll(where: { $0.id == id })
        objectMaskMarkerMissCounts.removeValue(forKey: id)
        automaticLockOfferedObjectIDs.remove(id)
        if focusedCaptureID == id {
            focusedCaptureID = activeObjectID ?? measuredObjectIDs.last
        }
        rebuildObjectMaskPreview(timestamp: latestObjectMaskPreviewTimestamp)
        objectWorkflowRequest = ObjectWorkflowRequest(id: id, kind: .remove)
        objectWorkflowRequestRevision += 1
        if activeObjectID != nil {
            statusText = "Measuring object."
            objectMaskFeedbackText = "Measured object removed. The active measurement was not changed."
        } else if finalizedObjectIDs.isEmpty {
            statusText = idleMeasurementPrompt
            objectMaskFeedbackText = "Measured object removed."
        } else {
            statusText = finalizedObjectIDs.count == 1
                ? "1 object measured."
                : "\(finalizedObjectIDs.count) objects measured."
            objectMaskFeedbackText = "Measured object removed."
        }
    }

    func reactivateFocusedObject() {
        guard activeObjectID == nil else {
            objectMaskFeedbackText = "Finish the object being measured before editing another."
            return
        }
        guard !isObjectSelectionPending else {
            objectMaskFeedbackText = "Wait for the current object selection to finish."
            return
        }
        guard let id = focusedCaptureID,
              finalizedObjectIDs.contains(id),
              capturedObjectsByID[id] != nil else {
            objectMaskFeedbackText = "Point at a finished object to edit it."
            return
        }
        finalizedObjectIDs.remove(id)
        clearSnapshotJPEGData(for: id)
        resetScanGuidance()
        automaticLockOfferedObjectIDs.remove(id)
        hasDefinitiveSupportPlaneForActiveObject = false
        activeObjectID = id
        isObjectSelectionPending = false
        objectWorkflowRequest = ObjectWorkflowRequest(id: id, kind: .reactivate)
        objectWorkflowRequestRevision += 1
        statusText = measurementMode == .top
            ? "Editing this object. Continue measuring it from above."
            : "Editing this object. Continue measuring it."
        objectMaskFeedbackText = activeMaskFeedback
    }

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
        refreshConvergence()
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
        guard activeObjectID == id else {
            return
        }
        if hasDefinitiveSupportPlaneForActiveObject != isAvailable {
            hasDefinitiveSupportPlaneForActiveObject = isAvailable
        }
        refreshConvergence()
    }

    func resetScanGuidance() {
        scanViewHint = .other
        footprintSatisfied = false
        heightSatisfied = false
        topMeasurementStable = false
        framingGuidance = nil
        measurementDetailStatus = .unknown
        didEncounterInsufficientFit = false
        resetConvergence()
    }

    func clearObjectMaskPreview() {
        objectMaskPreview = nil
        lockedMaskLayersByID.removeAll()
        lockedMaskLayerOrder.removeAll()
        liveMaskLayer = nil
        objectMaskDisplayBoundingBoxes.removeAll()
        framingGuidance = nil
        latestObjectMaskPreviewTimestamp = -.greatestFiniteMagnitude
    }

    func clearLiveObjectMaskPreview() {
        if let liveMaskLayer {
            objectMaskDisplayBoundingBoxes.removeValue(forKey: liveMaskLayer.id)
        }
        liveMaskLayer = nil
        rebuildObjectMaskPreview(timestamp: latestObjectMaskPreviewTimestamp)
        refreshFramingGuidance()
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
        refreshFramingGuidance()
    }

    func clearObjectMaskDisplayTracking(id: UUID) {
        objectMaskDisplayBoundingBoxes.removeValue(forKey: id)
        refreshFramingGuidance()
    }

    private func hideObjectMask(
        id: UUID,
        timestamp: TimeInterval? = nil
    ) {
        lockedMaskLayersByID.removeValue(forKey: id)
        lockedMaskLayerOrder.removeAll(where: { $0 == id })
        objectMaskDisplayBoundingBoxes.removeValue(forKey: id)
        refreshFramingGuidance()
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

    static func framingGuidance(
        forNormalizedViewportBoundingBox boundingBox: CGRect,
        hasSufficientMeasurementDetail: Bool = true
    ) -> ObjectFramingGuidance? {
        guard boundingBox.origin.x.isFinite,
              boundingBox.origin.y.isFinite,
              boundingBox.width.isFinite,
              boundingBox.height.isFinite,
              boundingBox.width > 0,
              boundingBox.height > 0 else {
            return nil
        }

        let viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard boundingBox.intersects(viewport) else {
            return nil
        }

        let edgeMargin: CGFloat = 0.03
        let isEdgeClipped = boundingBox.minX <= edgeMargin
            || boundingBox.minY <= edgeMargin
            || boundingBox.maxX >= 1 - edgeMargin
            || boundingBox.maxY >= 1 - edgeMargin
        let isTooLarge = boundingBox.width >= 0.85
            || boundingBox.height >= 0.85
        if isEdgeClipped || isTooLarge {
            return .moveFarther
        }

        if max(boundingBox.width, boundingBox.height) < 0.28
            || !hasSufficientMeasurementDetail {
            return .moveCloser
        }
        return .okay
    }

    private func refreshFramingGuidance() {
        let updatedGuidance = activeObjectID
            .flatMap { objectMaskDisplayBoundingBoxes[$0] }
            .flatMap {
                Self.framingGuidance(
                    forNormalizedViewportBoundingBox: $0,
                    hasSufficientMeasurementDetail:
                        measurementDetailStatus == .sufficient
                )
            }
        if framingGuidance != updatedGuidance {
            framingGuidance = updatedGuidance
        }
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
        measurementDetailStatus = .sufficient
        didEncounterInsufficientFit = false
        refreshFramingGuidance()
        focusedCaptureID = id
        statusText = measurementMode == .top
            ? "Overhead LiDAR fit ready. Hold steady or finish this object."
            : "LiDAR box ready. Continue scanning or finish this object."
    }

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
        hasDefinitiveSupportPlaneForActiveObject = false
        finalizedObjectIDs.removeAll()
        captureOrder.removeAll()
        objectColorsByID.removeAll()
        objectNamesByID.removeAll()
        objectWeightsInKilogramsByID.removeAll()
        clearAllSnapshotJPEGData()
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
        automaticLockOfferedObjectIDs.removeAll()
        resetScanGuidance()
        topViewDeviationDegrees = nil
        isTopViewAligned = false
        resetRevision += 1
    }
}
