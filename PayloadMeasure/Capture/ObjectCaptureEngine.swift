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
    /// The object runs off the edge of the frame. A distance instruction is the wrong advice here —
    /// backing away from something that is off to one side does not bring it into view, which is why
    /// "move further" used to be given and then appear to do nothing.
    case centre
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
    /// Bounds of the AR viewport that produced the normalized boxes. Accuracy calibration needs the
    /// real renderer size, not the safe-area size of a SwiftUI overlay.
    private(set) var objectMaskViewportSize: CGSize = .zero
    private(set) var objectMaskFeedbackText: String?
    private(set) var objectMaskToggleRequest: ObjectMaskToggleRequest?
    private(set) var objectWorkflowRequest: ObjectWorkflowRequest?
    private(set) var isObjectSelectionPending = false
    private(set) var statusText = defaultPrompt
    private(set) var isMeshVisible = false
    private(set) var showsSelectedPoints = true
    // The mask is shown from the start. It is the clearest sign that the app has found the object and
    // is working on the right thing, so hiding it by default left the operator guessing.
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
    /// True when the crosshair is on an object that has already been measured. Set from the AR side
    /// out of the stored boxes; no tracking is involved.
    private(set) var isPointingAtFinishedObject = false
    private(set) var framingGuidance: ObjectFramingGuidance?
    private var candidateFramingGuidance: ObjectFramingGuidance?
    private var candidateFramingGuidanceCount = 0
    private var lastPublishedDetailStatus: MeasurementDetailStatus = .unknown
    private var measurementDetailStatus: MeasurementDetailStatus = .unknown
    private var didEncounterInsufficientFit = false

    // MARK: - Automatic lock

    private(set) var convergence: MeasurementConvergence = .idle
    private(set) var isAutomaticLockEnabled = true
    private(set) var automaticLockRequest: UUID?
    private(set) var automaticLockRequestRevision = 0
    private var convergenceMonitor = MeasurementConvergenceMonitor()
    /// When each object was last offered for an automatic finish.
    private var automaticLockOfferTimestamps: [UUID: TimeInterval] = [:]
    /// How long to wait before offering the same object again. There is no manual Finish on the
    /// camera screen, so an offer the overlay could not act on must not be the only one it gets.
    private static let automaticLockRetryInterval: TimeInterval = 1

    var isAutomaticLockDisarmedForActiveObject: Bool {
        guard isAutomaticLockEnabled, let activeObjectID else {
            return false
        }
        return automaticLockOfferTimestamps[activeObjectID] != nil
    }

    func setAutomaticLockEnabled(_ isEnabled: Bool) {
        guard isAutomaticLockEnabled != isEnabled else {
            return
        }
        isAutomaticLockEnabled = isEnabled
        if isEnabled, let activeObjectID {
            automaticLockOfferTimestamps.removeValue(forKey: activeObjectID)
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
              let id = activeObjectID else {
            return
        }
        // The offer used to be made exactly once per object. Anything that stopped the overlay acting
        // on it — standing too close, a sheet in the way, tracking dropping for a frame — stranded
        // the measurement at "converged" with no way to finish it. So keep offering, slowly. A
        // successful finish clears the active object, which ends this by itself.
        let now = ProcessInfo.processInfo.systemUptime
        if let offered = automaticLockOfferTimestamps[id],
           now - offered < Self.automaticLockRetryInterval {
            return
        }
        automaticLockOfferTimestamps[id] = now
        automaticLockRequest = id
        automaticLockRequestRevision += 1
    }

    private static let defaultPrompt = "Aim at a highlighted object and follow the distance guide."

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

    /// Restores the live measurement presentation used by the framing test: segmentation mask,
    /// cyan admitted points, detected-object marker, and the fitted 3D box.
    func showMeasurementVisuals() {
        showsLiveMaskPreview = true
        showsSelectedObjectMaskPreview = true
        showsBoundingBoxes = true
        showsSelectedPoints = true
        showsObjectMaskMarkers = true
        isMeshVisible = false
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

    func showObjectMaskPreview(
        _ preview: ObjectMaskPreview,
        viewportSize: CGSize? = nil
    ) {
        guard preview.timestamp >= latestObjectMaskPreviewTimestamp else {
            return
        }
        if let viewportSize,
           viewportSize.width > 0,
           viewportSize.height > 0 {
            objectMaskViewportSize = viewportSize
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

    func updateObjectMaskDisplayBoundingBoxes(
        _ boundingBoxes: [UUID: CGRect],
        viewportSize: CGSize? = nil
    ) {
        if let viewportSize,
           viewportSize.width > 0,
           viewportSize.height > 0 {
            objectMaskViewportSize = viewportSize
        }
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
        objectMaskFeedbackText = "No stable surface was found. Move slowly around the object and hold it in view."
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
        objectMaskFeedbackText = "Object recognition had a temporary problem. Keep the object visible and hold steady."
    }

    func markObjectRecognitionWarmupCompleted() {
        hasCompletedObjectRecognitionWarmup = true
    }

    func reportObjectLockNotFound() {
        isObjectSelectionPending = false
        objectMaskFeedbackText = "No separate object mask was found. Keep one object fully visible near the centre."
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
        objectMaskFeedbackText = "Object selection was interrupted. Keep the object visible to try again."
    }

    func beginObjectMeasurement(id: UUID) {
        guard isObjectSelectionPending,
              !finalizedObjectIDs.contains(id),
              activeObjectID == nil || activeObjectID == id else {
            return
        }
        resetScanGuidance()
        automaticLockOfferTimestamps.removeValue(forKey: id)
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
        automaticLockOfferTimestamps.removeValue(forKey: id)

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
        objectMaskFeedbackText = "Measurement cancelled. Aim at an object to start again."
    }

    /// Two packages with the same name are indistinguishable in a loading plan.
    func isNameAvailable(_ name: String, excluding id: UUID?) -> Bool {
        let candidate = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return false }
        return !objectNamesByID.contains { existingID, existingName in
            existingID != id
                && existingName.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == candidate
        }
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

    // MARK: - Manual study input

    /// Creates the same finalized measurement record that AR capture would create, but from ruler or
    /// calliper dimensions. Packing consumes `CapturedObject` dimensions only, so keeping one shared
    /// representation makes every later screen and optimizer identical across study conditions.
    @discardableResult
    func addManualMeasurement(
        name: String,
        sizeMillimetres: SIMD3<Double>
    ) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isNameAvailable(trimmed, excluding: nil),
              let object = Self.manualCapturedObject(sizeMillimetres: sizeMillimetres) else {
            return nil
        }
        let id = UUID()
        captureOrder.append(id)
        capturedObjectsByID[id] = object
        finalizedObjectIDs.insert(id)
        objectNamesByID[id] = trimmed
        objectColorsByID[id] = Self.manualPalette[(captureOrder.count - 1) % Self.manualPalette.count]
        focusedCaptureID = id
        statusText = finalizedObjectIDs.count == 1
            ? "1 object entered manually."
            : "\(finalizedObjectIDs.count) objects entered manually."
        objectMaskFeedbackText = statusText
        return id
    }

    /// Measurement and preparation are deliberately separate study phases. Manual entry therefore
    /// creates an unnamed object; the participant names it beside the box and weight controls, just
    /// as they do after AR measurement.
    @discardableResult
    func addManualMeasurement(sizeMillimetres: SIMD3<Double>) -> UUID? {
        guard let object = Self.manualCapturedObject(sizeMillimetres: sizeMillimetres) else {
            return nil
        }
        let id = UUID()
        captureOrder.append(id)
        capturedObjectsByID[id] = object
        finalizedObjectIDs.insert(id)
        objectColorsByID[id] = ObjectColourPalette.colour(at: captureOrder.count - 1)
        focusedCaptureID = id
        statusText = finalizedObjectIDs.count == 1
            ? "1 object entered manually."
            : "\(finalizedObjectIDs.count) objects entered manually."
        objectMaskFeedbackText = statusText
        return id
    }

    @discardableResult
    func updateManualMeasurement(
        id: UUID,
        name: String,
        sizeMillimetres: SIMD3<Double>
    ) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard finalizedObjectIDs.contains(id),
              capturedObjectsByID[id] != nil,
              isNameAvailable(trimmed, excluding: id),
              let object = Self.manualCapturedObject(sizeMillimetres: sizeMillimetres) else {
            return false
        }
        capturedObjectsByID[id] = object
        objectNamesByID[id] = trimmed
        focusedCaptureID = id
        statusText = "Manual dimensions updated."
        objectMaskFeedbackText = statusText
        return true
    }

    @discardableResult
    func updateManualMeasurement(
        id: UUID,
        sizeMillimetres: SIMD3<Double>
    ) -> Bool {
        guard finalizedObjectIDs.contains(id),
              capturedObjectsByID[id] != nil,
              let object = Self.manualCapturedObject(sizeMillimetres: sizeMillimetres) else {
            return false
        }
        capturedObjectsByID[id] = object
        focusedCaptureID = id
        statusText = "Manual dimensions updated."
        objectMaskFeedbackText = statusText
        return true
    }

    private static func manualCapturedObject(
        sizeMillimetres: SIMD3<Double>
    ) -> CapturedObject? {
        guard sizeMillimetres.x.isFinite,
              sizeMillimetres.y.isFinite,
              sizeMillimetres.z.isFinite,
              sizeMillimetres.x > 0,
              sizeMillimetres.y > 0,
              sizeMillimetres.z > 0 else {
            return nil
        }
        let dimensions = SIMD3<Float>(
            Float(sizeMillimetres.x / 1_000),
            Float(sizeMillimetres.y / 1_000),
            Float(sizeMillimetres.z / 1_000)
        )
        guard dimensions.x.isFinite,
              dimensions.y.isFinite,
              dimensions.z.isFinite,
              dimensions.x > 0,
              dimensions.y > 0,
              dimensions.z > 0 else {
            return nil
        }
        let half = dimensions / 2
        let corners = [-half.x, half.x].flatMap { x in
            [-half.y, half.y].flatMap { y in
                [-half.z, half.z].map { z in SIMD3<Float>(x, y, z) }
            }
        }
        return CapturedObject(
            dimensions: dimensions,
            center: .zero,
            axes: (
                width: SIMD3<Float>(1, 0, 0),
                depth: SIMD3<Float>(0, 1, 0),
                height: SIMD3<Float>(0, 0, 1)
            ),
            corners: corners,
            volume: dimensions.x * dimensions.y * dimensions.z,
            sampleCount: 0
        )
    }

    private static let manualPalette = ObjectColourPalette.colours

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
        automaticLockOfferTimestamps.removeValue(forKey: id)
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
        automaticLockOfferTimestamps.removeValue(forKey: id)
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

    func setPointingAtFinishedObject(_ isPointing: Bool) {
        guard isPointingAtFinishedObject != isPointing else { return }
        isPointingAtFinishedObject = isPointing
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
        objectMaskViewportSize = .zero
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
        forNormalizedViewportBoundingBox boundingBox: CGRect
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

        // Genuinely filling the frame: backing away is the only thing that helps.
        if boundingBox.width >= 0.85 || boundingBox.height >= 0.85 {
            return .moveFarther
        }

        // Running off an edge without filling the frame is an aiming problem, not a distance one.
        let edgeMargin: CGFloat = 0.03
        if boundingBox.minX <= edgeMargin
            || boundingBox.minY <= edgeMargin
            || boundingBox.maxX >= 1 - edgeMargin
            || boundingBox.maxY >= 1 - edgeMargin {
            return .centre
        }

        // Small in the frame, so closer really does help. Note what is *not* here: whether the fit has
        // enough detail yet. That used to return "move closer" too, which meant a dark or glancing
        // surface asked the operator to close in on something already close enough, and then the size
        // threshold asked them to back off again — the pair of them chasing each other. Thin evidence
        // is reported by the progress bar, not as a distance instruction.
        if max(boundingBox.width, boundingBox.height) < 0.28 {
            return .moveCloser
        }
        return .okay
    }

    /// The apparent size of an object sits near a threshold for much of a scan, and recomputing the
    /// advice every mask update made it alternate between "move closer" and "move further" frame by
    /// frame — unusable, and it makes the operator chase it. A new instruction has to agree with
    /// itself for several consecutive updates before it is published; going quiet is immediate,
    /// because stale advice is worse than none.
    private static let framingGuidanceHoldCount = 4

    private func refreshFramingGuidance() {
        let updatedGuidance = activeObjectID
            .flatMap { objectMaskDisplayBoundingBoxes[$0] }
            .flatMap {
                Self.framingGuidance(forNormalizedViewportBoundingBox: $0)
            }

        guard updatedGuidance != framingGuidance else {
            candidateFramingGuidance = nil
            candidateFramingGuidanceCount = 0
            lastPublishedDetailStatus = measurementDetailStatus
            return
        }

        guard let updatedGuidance else {
            candidateFramingGuidance = nil
            candidateFramingGuidanceCount = 0
            framingGuidance = nil
            return
        }

        // Publish at once when there is no advice yet, when the advice is "you are framed", or when
        // the fit itself has just reported a change in how much detail it has. Only advice that
        // changed because the object's apparent size re-crossed a threshold has to prove itself —
        // that is the one that oscillates, because the size sits near a boundary for most of a scan.
        let detailChanged = measurementDetailStatus != lastPublishedDetailStatus
        if framingGuidance == nil || updatedGuidance == .okay || detailChanged {
            candidateFramingGuidance = nil
            candidateFramingGuidanceCount = 0
            lastPublishedDetailStatus = measurementDetailStatus
            framingGuidance = updatedGuidance
            return
        }

        if candidateFramingGuidance == updatedGuidance {
            candidateFramingGuidanceCount += 1
        } else {
            candidateFramingGuidance = updatedGuidance
            candidateFramingGuidanceCount = 1
        }

        if candidateFramingGuidanceCount >= Self.framingGuidanceHoldCount {
            framingGuidance = updatedGuidance
            candidateFramingGuidance = nil
            candidateFramingGuidanceCount = 0
            lastPublishedDetailStatus = measurementDetailStatus
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
        objectMaskViewportSize = .zero
        latestObjectMaskPreviewTimestamp = -.greatestFiniteMagnitude
        lockedObjectMaskCount = 0
        visibleObjectMaskCount = 0
        objectMaskMarkers = []
        objectMaskMarkerMissCounts.removeAll()
        objectMaskFeedbackText = nil
        objectMaskToggleRequest = nil
        statusText = idleMeasurementPrompt
        hasCompletedObjectRecognitionWarmup = false
        automaticLockOfferTimestamps.removeAll()
        resetScanGuidance()
        topViewDeviationDegrees = nil
        isTopViewAligned = false
        resetRevision += 1
    }
}
