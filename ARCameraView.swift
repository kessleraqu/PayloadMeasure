//
//  ARCameraView.swift
//  PayloadMeasure
//
//  Created by Alexandre on 29/06/2026.
//

import ARKit
import RealityKit
import SwiftUI
import UIKit

struct ARCameraView: UIViewRepresentable {
    let sessionManager: ARSessionManager
    let measurementEngine: MeasurementEngine
    let captureEngine: ObjectCaptureEngine

    func makeCoordinator() -> Coordinator {
        Coordinator(
            sessionManager: sessionManager,
            measurementEngine: measurementEngine,
            captureEngine: captureEngine
        )
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        sessionManager.configure(arView.session)
        context.coordinator.attach(to: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // The coordinator observes MeasurementEngine directly via `withObservationTracking`, so
        // there is no SwiftUI-driven update work to do here. This stays empty intentionally.
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.detach()
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject {
        private struct PlacedPoint {
            let id: UUID
            let marker: ModelEntity
            var anchorEntity: AnchorEntity?
            var arAnchor: ARAnchor?
            var latestTransform: simd_float4x4
            var trackedRaycast: ARTrackedRaycast?
        }

        // Bright UI-white for measurement visuals. `applyPostProcessToneMap: false` keeps the color
        // from being darkened by RealityKit's tone mapper, matching the on-screen SwiftUI aimer.
        fileprivate static let iceWhiteMaterial = UnlitMaterial(color: .white, applyPostProcessToneMap: false)
        // A distinct green for a captured object's box so it never reads as a manual measurement.
        fileprivate static let captureMaterial = UnlitMaterial(color: .systemGreen, applyPostProcessToneMap: false)
        // Cyan for the selected-cluster debug markers, so it is clearly separate from the box.
        fileprivate static let selectionMaterial = UnlitMaterial(color: .cyan, applyPostProcessToneMap: false)
        // One shared marker mesh reused by every selection point to avoid regenerating geometry.
        fileprivate static let selectionMarkerMesh = MeshResource.generateBox(size: 0.02)
        // A unit cube reused for every box edge (scaled per edge), since the box is rebuilt live.
        fileprivate static let unitCubeMesh = MeshResource.generateBox(size: 1.0)

        private let sessionManager: ARSessionManager
        private let measurementEngine: MeasurementEngine
        private let captureEngine: ObjectCaptureEngine
        private weak var arView: ARView?
        private var contentAnchor: AnchorEntity?
        private var placedPoints: [PlacedPoint] = []
        private var measurementEntities: [ModelEntity] = []
        private var previewMeasurementEntities: [ModelEntity] = []
        private var captureEntities: [ModelEntity] = []
        private var selectionEntities: [ModelEntity] = []
        private var lastSelectionPoints: [SIMD3<Float>] = []
        private var accumulator = PointAccumulator(voxelSize: ObjectCapturePipeline.voxelSize)
        private var liveResult: CaptureResult?
        private var accumulationAnchor: SIMD3<Float>?
        private var isScanFrozen = false
        private var scanTickCounter = 0
        private var previewTargetPosition: SIMD3<Float>?
        private var lastAimerRaycastTransform: simd_float4x4?
        private var aimerUpdateTimer: Timer?
        private var observedResetRevision = 0
        private var observedPlacementRequestRevision = 0
        private var observedMode: MeasurementMode = .line
        private var observedCaptureRequestRevision = 0
        private var observedCaptureResetRevision = 0
        private var observedMeshVisible = true
        private var observedShowsSelectedPoints = true

        init(
            sessionManager: ARSessionManager,
            measurementEngine: MeasurementEngine,
            captureEngine: ObjectCaptureEngine
        ) {
            self.sessionManager = sessionManager
            self.measurementEngine = measurementEngine
            self.captureEngine = captureEngine
        }

        func attach(to arView: ARView) {
            self.arView = arView
            observedMode = measurementEngine.mode
            observedMeshVisible = captureEngine.isMeshVisible
            observedShowsSelectedPoints = captureEngine.showsSelectedPoints
            createContentAnchorIfNeeded(in: arView)
            updateMeshVisibility()

            aimerUpdateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self, weak arView] _ in
                guard let self, let arView else {
                    return
                }

                Task { @MainActor in
                    self.updateAimerSurface(in: arView)
                    self.updatePlacedPointBillboards(in: arView)
                    self.updateScanLive(in: arView)
                }
            }

            observeEngineRevisions()
        }

        func detach() {
            aimerUpdateTimer?.invalidate()
            aimerUpdateTimer = nil
            clearMeasurementContent()
            clearCaptureContent()

            if let contentAnchor, let arView {
                arView.scene.removeAnchor(contentAnchor)
            }

            arView = nil
            contentAnchor = nil
        }

        // Direct observation of MeasurementEngine revision counters. Using
        // `withObservationTracking` removes the dependency on SwiftUI choosing to re-render the
        // hosting view (which it would only do if some property read by a view body changed).
        // `placementRequestRevision` and `resetRevision` are not read from any view body, so the
        // previous `updateUIView` path could silently miss button presses.
        private func observeEngineRevisions() {
            withObservationTracking {
                _ = measurementEngine.placementRequestRevision
                _ = measurementEngine.resetRevision
                _ = measurementEngine.mode
                _ = captureEngine.captureRequestRevision
                _ = captureEngine.resetRevision
                _ = captureEngine.isMeshVisible
                _ = captureEngine.showsSelectedPoints
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    self.observeEngineRevisions()
                    self.handleEngineRevisionChange()
                }
            }
        }

        private func handleEngineRevisionChange() {
            // A mode switch clears whatever the previous tool drew and refreshes the mesh overlay.
            if measurementEngine.mode != observedMode {
                let wasScanning = observedMode == .scan
                observedMode = measurementEngine.mode
                clearMeasurementContent()
                resetScanState()
                updateMeshVisibility()
                if wasScanning {
                    // Drop any stale captured/preview readout when leaving Scan.
                    captureEngine.reset()
                }
            }

            if measurementEngine.resetRevision != observedResetRevision {
                observedResetRevision = measurementEngine.resetRevision
                clearMeasurementContent()
            }

            if measurementEngine.placementRequestRevision != observedPlacementRequestRevision {
                observedPlacementRequestRevision = measurementEngine.placementRequestRevision
                if let arView {
                    placePointAtTarget(in: arView)
                }
            }

            if captureEngine.resetRevision != observedCaptureResetRevision {
                observedCaptureResetRevision = captureEngine.resetRevision
                resetScanState()
            }

            if captureEngine.captureRequestRevision != observedCaptureRequestRevision {
                observedCaptureRequestRevision = captureEngine.captureRequestRevision
                commitScanCapture()
            }

            if captureEngine.isMeshVisible != observedMeshVisible {
                observedMeshVisible = captureEngine.isMeshVisible
                updateMeshVisibility()
            }

            if captureEngine.showsSelectedPoints != observedShowsSelectedPoints {
                observedShowsSelectedPoints = captureEngine.showsSelectedPoints
                updateSelectionVisualization()
            }
        }

        private func updateMeshVisibility() {
            guard let arView else {
                return
            }

            // The reconstructed mesh overlay is only useful while scanning. RealityKit renders it
            // natively from the LiDAR scene-reconstruction data already enabled on the session.
            let shouldShow = measurementEngine.mode == .scan && captureEngine.isMeshVisible
            if shouldShow {
                arView.debugOptions.insert(.showSceneUnderstanding)
            } else {
                arView.debugOptions.remove(.showSceneUnderstanding)
            }
        }

        /// Throttled live scanning: accumulate depth around the reticle across frames and keep a
        /// running cluster + box so the operator sees what will be captured before pressing Capture.
        private func updateScanLive(in arView: ARView) {
            guard measurementEngine.mode == .scan, !isScanFrozen else {
                return
            }

            // The aimer timer fires at 15 Hz; segment roughly every 5th tick (~3 Hz) to keep cost low.
            scanTickCounter &+= 1
            guard scanTickCounter % 5 == 0 else {
                return
            }

            guard sessionManager.isTrackingReady,
                  let frame = arView.session.currentFrame,
                  let aimerTransform = lastAimerRaycastTransform else {
                return
            }

            let seed = aimerTransform.translation

            // If the operator has aimed at a clearly different place (farther than the gather
            // radius), start a fresh accumulation. This keeps the buffer bounded and makes the tool
            // track the object currently being aimed at instead of piling up the whole scene.
            if let anchor = accumulationAnchor {
                let deltaX = seed.x - anchor.x
                let deltaZ = seed.z - anchor.z
                let jump = ObjectCapturePipeline.accumulationRadius
                if deltaX * deltaX + deltaZ * deltaZ > jump * jump {
                    resetScanState()
                }
            }
            if accumulationAnchor == nil {
                accumulationAnchor = seed
            }

            let points = DepthPointCloud.worldPoints(
                from: frame,
                near: seed,
                maxRadius: ObjectCapturePipeline.accumulationRadius
            )

            guard !points.isEmpty else {
                return
            }

            accumulator.add(points)

            // ARKit world Y is gravity-aligned (`.gravity` world alignment), so up is (0, 1, 0).
            guard case .success(let result) = ObjectCapturePipeline.capture(
                points: accumulator.points(),
                seed: seed,
                up: SIMD3<Float>(0, 1, 0)
            ) else {
                return
            }

            liveResult = result
            createContentAnchorIfNeeded(in: arView)
            addCapturedBox(result.object)
            lastSelectionPoints = result.selectionPoints
            updateSelectionVisualization()
            captureEngine.showPreview(result.object)
        }

        /// Locks in the latest live result as the committed capture and stops live updating.
        private func commitScanCapture() {
            guard sessionManager.isTrackingReady else {
                captureEngine.reportTrackingNotReady()
                return
            }

            guard let liveResult else {
                captureEngine.reportNotEnoughMesh()
                return
            }

            isScanFrozen = true
            captureEngine.applyCapture(liveResult.object)
            // The box and selection markers are already rendered from the last live tick.
        }

        private func resetScanState() {
            clearCaptureContent()
            accumulator.reset()
            liveResult = nil
            accumulationAnchor = nil
            isScanFrozen = false
            captureEngine.clearPreview()
        }

        private func placePointAtTarget(in arView: ARView) {
            guard sessionManager.isTrackingReady else {
                measurementEngine.reportTrackingNotReady()
                return
            }

            if !measurementEngine.canAcceptPoint {
                measurementEngine.reset()
                clearMeasurementContent()
                observedResetRevision = measurementEngine.resetRevision
            }

            let targetLocation = centerPoint(in: arView)

            // The visible aimer already represents a successful center raycast. Use its cached
            // transform as the primary source of truth so the marker always lands exactly where
            // the user sees the aimer, even if a fresh raycast transiently fails on this frame.
            // Fall back to a fresh raycast only when the aimer cache is absent.
            let initialTransform: simd_float4x4
            if let cached = lastAimerRaycastTransform {
                initialTransform = cached
            } else if let immediate = bestRaycastResult(from: targetLocation, in: arView) {
                initialTransform = immediate.worldTransform
            } else {
                measurementEngine.reportPlacementFailure()
                return
            }

            createContentAnchorIfNeeded(in: arView)

            let position = initialTransform.translation
            let pointID = measurementEngine.addPoint(at: position)
            let placedPoint = addMarker(id: pointID, transform: initialTransform)
            placedPoints.append(placedPoint)
            updateMeasurementVisual()
            startRefining(pointID: pointID, targetLocation: targetLocation, in: arView)
        }

        private func createContentAnchorIfNeeded(in arView: ARView) {
            guard contentAnchor == nil else {
                return
            }

            let anchor = AnchorEntity(world: .zero)
            arView.scene.addAnchor(anchor)
            contentAnchor = anchor
        }

        private func centerPoint(in arView: ARView) -> CGPoint {
            CGPoint(x: arView.bounds.midX, y: arView.bounds.midY)
        }

        private func updateAimerSurface(in arView: ARView) {
            guard let result = bestRaycastResult(from: centerPoint(in: arView), in: arView) else {
                previewTargetPosition = nil
                lastAimerRaycastTransform = nil
                clearPreviewMeasurementEntities()
                measurementEngine.updateAimerSurface(
                    scaleY: 1,
                    rotationDegrees: 0,
                    distanceScale: 1,
                    isDetected: false
                )
                return
            }

            previewTargetPosition = result.worldTransform.translation
            lastAimerRaycastTransform = result.worldTransform
            let surfaceNormal = SIMD3<Float>(
                result.worldTransform.columns.1.x,
                result.worldTransform.columns.1.y,
                result.worldTransform.columns.1.z
            )
            let normalizedNormal = simd_length(surfaceNormal) > 0 ? simd_normalize(surfaceNormal) : SIMD3<Float>(0, 1, 0)
            let cameraDirection = simd_normalize(arView.cameraTransform.translation - result.worldTransform.translation)
            let facingAmount = abs(simd_dot(normalizedNormal, cameraDirection))
            let scaleY = Double(min(max(0.34 + facingAmount * 0.66, 0.34), 1.0))
            let distance = simd_distance(arView.cameraTransform.translation, result.worldTransform.translation)
            // Inverse-distance scaling so the aimer behaves like a fixed-world-size disc projected
            // onto the screen: closer surfaces enlarge the aimer, farther surfaces shrink it.
            let referenceDistance: Float = 0.7
            let safeDistance = max(distance, 0.15)
            let distanceScale = Double(min(max(referenceDistance / safeDistance, 0.55), 1.8))
            // The aimer's squish axis should follow the surface's tilt as seen in the camera image,
            // not the world-space yaw of the normal. Transform the world normal into camera space,
            // project it onto the camera image plane (SwiftUI Y is inverted relative to camera Y),
            // and rotate so the squish direction aligns with the projected tilt.
            let inverseCamera = arView.cameraTransform.matrix.inverse
            let normalInCamera4 = inverseCamera * SIMD4<Float>(normalizedNormal, 0)
            let normalInCamera = SIMD3<Float>(normalInCamera4.x, normalInCamera4.y, normalInCamera4.z)
            let projectedLength = hypot(normalInCamera.x, normalInCamera.y)
            let rotation: Double = projectedLength > 0.05
                ? Double(atan2(normalInCamera.x, -normalInCamera.y) * 180 / .pi)
                : 0

            measurementEngine.updateAimerSurface(
                scaleY: scaleY,
                rotationDegrees: rotation,
                distanceScale: distanceScale,
                isDetected: true
            )
            updatePreviewMeasurementVisual()
        }

        private func bestRaycastResult(from point: CGPoint, in arView: ARView) -> ARRaycastResult? {
            if let meshOrEstimatedSurface = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first {
                return meshOrEstimatedSurface
            }

            return arView.raycast(from: point, allowing: .existingPlaneGeometry, alignment: .any).first
        }

        private func startRefining(pointID: UUID, targetLocation: CGPoint, in arView: ARView) {
            guard let trackedRaycast = arView.trackedRaycast(
                from: targetLocation,
                allowing: .estimatedPlane,
                alignment: .any,
                updateHandler: { [weak self] results in
                    Task { @MainActor in
                        self?.applyRefinedResult(results.first, to: pointID)
                    }
                }
            ) else {
                measurementEngine.finishRefiningPoint(id: pointID)
                return
            }

            updateTrackedRaycast(trackedRaycast, for: pointID)

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                stopRefining(pointID: pointID)
            }
        }

        private func applyRefinedResult(_ result: ARRaycastResult?, to pointID: UUID) {
            guard let result,
                  let index = placedPoints.firstIndex(where: { $0.id == pointID }) else {
                return
            }

            let position = result.worldTransform.translation
            placedPoints[index].latestTransform = result.worldTransform
            placedPoints[index].marker.position = position
            if let arView {
                orientBillboard(placedPoints[index].marker, at: position, in: arView)
            }
            measurementEngine.updatePoint(id: pointID, position: position)
            updateMeasurementVisual()
        }

        private func stopRefining(pointID: UUID) {
            guard let index = placedPoints.firstIndex(where: { $0.id == pointID }) else {
                return
            }

            placedPoints[index].trackedRaycast?.stopTracking()
            placedPoints[index].trackedRaycast = nil
            lockPointToARAnchor(at: index)
            measurementEngine.finishRefiningPoint(id: pointID)
        }

        private func updateTrackedRaycast(_ trackedRaycast: ARTrackedRaycast, for pointID: UUID) {
            guard let index = placedPoints.firstIndex(where: { $0.id == pointID }) else {
                trackedRaycast.stopTracking()
                return
            }

            placedPoints[index].trackedRaycast = trackedRaycast
        }

        private func addMarker(id: UUID, transform: simd_float4x4) -> PlacedPoint {
            let marker = ModelEntity(
                mesh: .generatePlane(width: 0.014, depth: 0.014, cornerRadius: 0.007),
                materials: [Coordinator.iceWhiteMaterial]
            )
            marker.position = transform.translation
            if let arView {
                orientBillboard(marker, at: transform.translation, in: arView)
            }
            contentAnchor?.addChild(marker)
            return PlacedPoint(
                id: id,
                marker: marker,
                anchorEntity: nil,
                arAnchor: nil,
                latestTransform: transform,
                trackedRaycast: nil
            )
        }

        private func lockPointToARAnchor(at index: Int) {
            guard let arView,
                  placedPoints[index].anchorEntity == nil else {
                return
            }

            let pointID = placedPoints[index].id
            let marker = placedPoints[index].marker
            let latestTransform = placedPoints[index].latestTransform
            let arAnchor = ARAnchor(
                name: "MeasurementPoint-\(pointID.uuidString)",
                transform: latestTransform
            )
            let anchorEntity = AnchorEntity(anchor: arAnchor)

            arView.session.add(anchor: arAnchor)
            arView.scene.addAnchor(anchorEntity)

            marker.removeFromParent()
            marker.position = .zero
            anchorEntity.addChild(marker)
            orientBillboard(marker, at: latestTransform.translation, in: arView)

            placedPoints[index].arAnchor = arAnchor
            placedPoints[index].anchorEntity = anchorEntity
            measurementEngine.updatePoint(id: pointID, position: latestTransform.translation)
            updateMeasurementVisual()
        }

        private func updateMeasurementVisual() {
            clearMeasurementEntities()
            clearPreviewMeasurementEntities()

            guard measurementEngine.points.count == 2 else {
                updatePreviewMeasurementVisual()
                return
            }

            switch measurementEngine.mode {
            case .line:
                addDashedLine(from: measurementEngine.points[0].position, to: measurementEngine.points[1].position)
            case .boundingBox:
                addBoundingBox(from: measurementEngine.points[0].position, to: measurementEngine.points[1].position)
            case .scan:
                // Scan mode draws its captured box separately; nothing to do for tapped points.
                break
            }
        }

        private func updatePreviewMeasurementVisual() {
            clearPreviewMeasurementEntities()

            guard measurementEngine.points.count == 1,
                  let previewTargetPosition else {
                return
            }

            addDashedLine(
                from: measurementEngine.points[0].position,
                to: previewTargetPosition,
                into: &previewMeasurementEntities
            )
        }

        private func addBoundingBox(from firstCorner: SIMD3<Float>, to secondCorner: SIMD3<Float>) {
            let minCorner = simd_min(firstCorner, secondCorner)
            let maxCorner = simd_max(firstCorner, secondCorner)

            let corners: [SIMD3<Float>] = [
                SIMD3<Float>(minCorner.x, minCorner.y, minCorner.z),
                SIMD3<Float>(maxCorner.x, minCorner.y, minCorner.z),
                SIMD3<Float>(maxCorner.x, minCorner.y, maxCorner.z),
                SIMD3<Float>(minCorner.x, minCorner.y, maxCorner.z),
                SIMD3<Float>(minCorner.x, maxCorner.y, minCorner.z),
                SIMD3<Float>(maxCorner.x, maxCorner.y, minCorner.z),
                SIMD3<Float>(maxCorner.x, maxCorner.y, maxCorner.z),
                SIMD3<Float>(minCorner.x, maxCorner.y, maxCorner.z)
            ]

            let edges = [
                (0, 1), (1, 2), (2, 3), (3, 0),
                (4, 5), (5, 6), (6, 7), (7, 4),
                (0, 4), (1, 5), (2, 6), (3, 7)
            ]

            for edge in edges {
                addDashedLine(from: corners[edge.0], to: corners[edge.1], radius: 0.0012)
            }
        }

        private func addDashedLine(
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            radius: Float = 0.0015,
            into targetEntities: inout [ModelEntity]
        ) {
            let delta = end - start
            let length = simd_length(delta)

            guard length > 0.001 else {
                return
            }

            let direction = simd_normalize(delta)
            let width = max(radius * 2.0, 0.002)
            let dashLength: Float = 0.035
            let gapLength: Float = 0.02
            let stepLength = dashLength + gapLength
            var distance: Float = 0

            while distance < length {
                let segmentLength = min(dashLength, length - distance)
                let segmentCenter = start + direction * (distance + segmentLength / 2)
                let dash = ModelEntity(
                    mesh: .generatePlane(width: segmentLength, depth: width, cornerRadius: width / 2),
                    materials: [Coordinator.iceWhiteMaterial]
                )
                dash.position = segmentCenter
                dash.orientation = lineOrientation(at: segmentCenter, direction: direction)

                contentAnchor?.addChild(dash)
                targetEntities.append(dash)
                distance += stepLength
            }
        }

        private func addDashedLine(
            from start: SIMD3<Float>,
            to end: SIMD3<Float>,
            radius: Float = 0.0015
        ) {
            addDashedLine(from: start, to: end, radius: radius, into: &measurementEntities)
        }

        private func updatePlacedPointBillboards(in arView: ARView) {
            for placedPoint in placedPoints {
                let worldPosition = placedPoint.marker.transformMatrix(relativeTo: nil).translation
                orientBillboard(placedPoint.marker, at: worldPosition, in: arView)
                syncAnchoredPositionIfNeeded(for: placedPoint, worldPosition: worldPosition)
            }
        }

        private func syncAnchoredPositionIfNeeded(for placedPoint: PlacedPoint, worldPosition: SIMD3<Float>) {
            guard placedPoint.anchorEntity != nil,
                  let storedPosition = measurementEngine.points.first(where: { $0.id == placedPoint.id })?.position,
                  simd_distance(storedPosition, worldPosition) > 0.001 else {
                return
            }

            measurementEngine.updatePoint(id: placedPoint.id, position: worldPosition)
            updateMeasurementVisual()
        }

        private func orientBillboard(_ entity: Entity, at position: SIMD3<Float>, in arView: ARView) {
            let cameraDirection = arView.cameraTransform.translation - position
            guard simd_length(cameraDirection) > 0 else {
                return
            }

            let orientation = simd_quatf(
                from: SIMD3<Float>(0, 1, 0),
                to: simd_normalize(cameraDirection)
            )
            entity.setOrientation(orientation, relativeTo: nil)
        }

        private func lineOrientation(at position: SIMD3<Float>, direction: SIMD3<Float>) -> simd_quatf {
            guard let arView else {
                return simd_quatf(from: SIMD3<Float>(1, 0, 0), to: direction)
            }

            let cameraDirection = simd_normalize(arView.cameraTransform.translation - position)
            let projectedNormal = cameraDirection - direction * simd_dot(cameraDirection, direction)
            let fallbackNormal = SIMD3<Float>(0, 1, 0)
            let yAxis = simd_length(projectedNormal) > 0.001 ? simd_normalize(projectedNormal) : fallbackNormal
            let zAxis = simd_normalize(simd_cross(direction, yAxis))
            let correctedYAxis = simd_normalize(simd_cross(zAxis, direction))

            let matrix = simd_float3x3(columns: (
                direction,
                correctedYAxis,
                zAxis
            ))

            return simd_quatf(matrix)
        }

        private func clearMeasurementContent() {
            stopTrackedRaycasts()

            for placedPoint in placedPoints {
                if let arAnchor = placedPoint.arAnchor {
                    arView?.session.remove(anchor: arAnchor)
                }

                placedPoint.anchorEntity?.removeFromParent()
                placedPoint.marker.removeFromParent()
            }

            clearMeasurementEntities()
            clearPreviewMeasurementEntities()
            placedPoints.removeAll()
        }

        private func clearMeasurementEntities() {
            for entity in measurementEntities {
                entity.removeFromParent()
            }

            measurementEntities.removeAll()
        }

        private func clearPreviewMeasurementEntities() {
            for entity in previewMeasurementEntities {
                entity.removeFromParent()
            }

            previewMeasurementEntities.removeAll()
        }

        private func addCapturedBox(_ object: CapturedObject) {
            clearCaptureContent()

            guard object.corners.count == 8 else {
                return
            }

            // Edges for the `i + 2*j + 4*k` corner layout: base face, top face, vertical edges.
            let edges = [
                (0, 1), (1, 3), (2, 3), (0, 2),
                (4, 5), (5, 7), (6, 7), (4, 6),
                (0, 4), (1, 5), (2, 6), (3, 7)
            ]

            for edge in edges {
                addCapturedBoxEdge(from: object.corners[edge.0], to: object.corners[edge.1])
            }
        }

        private func addCapturedBoxEdge(from start: SIMD3<Float>, to end: SIMD3<Float>) {
            let delta = end - start
            let length = simd_length(delta)

            guard length > 0.001 else {
                return
            }

            // A thin 3D bar (rather than a flat strip) so the box reads correctly from any angle as
            // the operator walks around the captured object. Reuses a shared unit cube, scaled to
            // length, because the box is rebuilt on every live tick.
            let thickness: Float = 0.006
            let bar = ModelEntity(
                mesh: Coordinator.unitCubeMesh,
                materials: [Coordinator.captureMaterial]
            )
            bar.scale = SIMD3<Float>(length, thickness, thickness)
            bar.position = start + delta / 2
            bar.orientation = orientation(alongX: delta)

            contentAnchor?.addChild(bar)
            captureEntities.append(bar)
        }

        /// A rotation that maps a box's local +X axis onto `direction`, built from a stable
        /// orthonormal basis. Unlike `simd_quatf(from:to:)` this stays well-defined when the
        /// direction points opposite the reference axis (e.g. a box edge along world -X).
        private func orientation(alongX direction: SIMD3<Float>) -> simd_quatf {
            let xAxis = simd_normalize(direction)
            var reference = SIMD3<Float>(0, 1, 0)
            if abs(simd_dot(xAxis, reference)) > 0.99 {
                reference = SIMD3<Float>(1, 0, 0)
            }
            let zAxis = simd_normalize(simd_cross(xAxis, reference))
            let yAxis = simd_cross(zAxis, xAxis)
            return simd_quatf(simd_float3x3(columns: (xAxis, yAxis, zAxis)))
        }

        private func clearCaptureContent() {
            for entity in captureEntities {
                entity.removeFromParent()
            }

            captureEntities.removeAll()
            clearSelectionEntities()
            lastSelectionPoints = []
        }

        /// Redraws (or hides) the cyan markers showing which voxel cluster the last capture selected.
        private func updateSelectionVisualization() {
            clearSelectionEntities()

            guard captureEngine.showsSelectedPoints, !lastSelectionPoints.isEmpty,
                  let contentAnchor else {
                return
            }

            // Keep the marker count bounded so a dense cluster never floods the scene (it is
            // rebuilt on every live tick); stride through the voxel centers when over the cap.
            let maxMarkers = 500
            let step = max(1, lastSelectionPoints.count / maxMarkers)
            var index = 0
            while index < lastSelectionPoints.count {
                let marker = ModelEntity(
                    mesh: Coordinator.selectionMarkerMesh,
                    materials: [Coordinator.selectionMaterial]
                )
                marker.position = lastSelectionPoints[index]
                contentAnchor.addChild(marker)
                selectionEntities.append(marker)
                index += step
            }
        }

        private func clearSelectionEntities() {
            for entity in selectionEntities {
                entity.removeFromParent()
            }

            selectionEntities.removeAll()
        }

        private func stopTrackedRaycasts() {
            for index in placedPoints.indices {
                placedPoints[index].trackedRaycast?.stopTracking()
                placedPoints[index].trackedRaycast = nil
            }
        }
    }
}

private extension simd_float4x4 {
    var translation: SIMD3<Float> {
        SIMD3<Float>(columns.3.x, columns.3.y, columns.3.z)
    }
}

private extension Transform {
    var translation: SIMD3<Float> {
        matrix.translation
    }
}
