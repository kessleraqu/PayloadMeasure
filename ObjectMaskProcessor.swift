//
//  ObjectMaskProcessor.swift
//  PayloadMeasure
//
//  Created by Codex on 14/07/2026.
//

import CoreImage
import CoreVideo
import Foundation
import ImageIO
import simd
import Vision

/// A display-ready RGB segmentation preview. The image is already oriented upright for the
/// interface orientation used when Vision processed the camera frame.
nonisolated struct ObjectMaskPreview: @unchecked Sendable {
    let image: CGImage
    let timestamp: TimeInterval
}

/// A tap in normalized viewport coordinates, with an upper-left origin like SwiftUI.
nonisolated struct ObjectMaskToggleRequest: @unchecked Sendable {
    let normalizedViewportPoint: CGPoint
    let proposedLockID: UUID?
    let worldTransform: simd_float4x4?
    let cameraDistance: Float?

    init(
        normalizedViewportPoint: CGPoint,
        proposedLockID: UUID? = nil,
        worldTransform: simd_float4x4? = nil,
        cameraDistance: Float? = nil
    ) {
        self.normalizedViewportPoint = normalizedViewportPoint
        self.proposedLockID = proposedLockID
        self.worldTransform = worldTransform
        self.cameraDistance = cameraDistance
    }
}

/// The current screen projection of a persistent AR anchor. Vision uses this as the authoritative
/// search location after a lock leaves the camera and later becomes visible again.
nonisolated struct ObjectMaskAnchorHint: @unchecked Sendable {
    let id: UUID
    let normalizedViewportPoint: CGPoint?
    let cameraDistance: Float
    let worldPosition: SIMD3<Float>
}

nonisolated struct ObjectMaskDisplayColor: Sendable, Hashable {
    let red: Double
    let green: Double
    let blue: Double
}

/// A lightweight world-anchored marker shown whenever an exact pixel mask is unavailable.
nonisolated struct ObjectMaskMarker: Identifiable, Equatable, @unchecked Sendable {
    let id: UUID
    let normalizedViewportPoint: CGPoint
    let color: ObjectMaskDisplayColor
    let isMaskVisible: Bool
}

nonisolated enum ObjectMaskLockChangeKind: Sendable {
    case added
    case removed
}

nonisolated struct ObjectMaskLockChange: @unchecked Sendable {
    let id: UUID
    let kind: ObjectMaskLockChangeKind
    let worldTransform: simd_float4x4?
}

/// Retains an AR camera pixel buffer while it crosses from the main actor to the Vision worker.
/// ARKit camera frames are immutable for the duration of this processing request.
nonisolated struct ObjectMaskFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
    let viewportSize: CGSize
    let toggleRequest: ObjectMaskToggleRequest?
    let anchorHints: [ObjectMaskAnchorHint]
    let timestamp: TimeInterval
    let trackingGeneration: Int
    let depthSnapshot: ObjectMaskDepthSnapshot?
}

/// The calibration and depth buffers captured with the RGB image passed to Vision. Keeping these
/// together is essential: sampling a newer depth frame with an older mask is a direct source of
/// table leakage when the phone moves.
nonisolated struct ObjectMaskDepthSnapshot: @unchecked Sendable {
    let depthMap: CVPixelBuffer
    let confidenceMap: CVPixelBuffer?
    let cameraTransform: simd_float4x4
    let cameraIntrinsics: simd_float3x3
    let cameraImageResolution: CGSize
    let imageToViewportTransform: CGAffineTransform
}

nonisolated struct ObjectMaskDepthPointCloud: @unchecked Sendable {
    let id: UUID
    let points: [SIMD3<Float>]
    let timestamp: TimeInterval
}

/// A compact segmentation correction consumed by the high-rate optical-flow worker. Each locked
/// object retains its own binary mask, so one object's update can never erase another's overlay.
nonisolated struct ObjectMaskMotionLayer: @unchecked Sendable {
    let id: UUID
    let color: ObjectMaskDisplayColor
    let mask: [UInt8]
}

nonisolated struct ObjectMaskMotionKeyframe: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
    let timestamp: TimeInterval
    let width: Int
    let height: Int
    let activeLockIDs: Set<UUID>
    let onScreenLockIDs: Set<UUID>
    let layers: [ObjectMaskMotionLayer]
}

/// Carries both the rendered overlay and tracker state back to the main actor. A nil preview is a
/// valid result when locked objects are temporarily outside the camera frame.
nonisolated struct ObjectMaskProcessingResult: @unchecked Sendable {
    let preview: ObjectMaskPreview?
    let lockedObjectCount: Int
    let visibleObjectCount: Int
    let markers: [ObjectMaskMarker]
    let didToggleLock: Bool
    let lockChange: ObjectMaskLockChange?
    let needsWorldSurface: Bool
    let motionKeyframe: ObjectMaskMotionKeyframe?
    let maskedPointClouds: [ObjectMaskDepthPointCloud]
}

/// Performs foreground-instance segmentation and stateful object tracking away from the main
/// actor. The center aimer previews an object; tapping any visible object toggles its lock.
actor ObjectMaskProcessor {
    private struct TrackedObject {
        let id: UUID
        let colorIndex: Int
        var request: TrackObjectRequest
        let referenceGeometry: MaskGeometry
        let anchorOffset: CGPoint
        let referenceCameraDistance: Float
        var appearance: AppearanceSignature?
        var lastGeometry: MaskGeometry
        var currentInstance: Int?
        var missedFrames: Int
        var lastAcceptedTimestamp: TimeInterval
    }

    private struct AppearanceSignature {
        var values: [Float]
    }

    private struct MaskGeometry {
        let boundingBox: NormalizedRect
        let area: CGFloat
        let centroid: CGPoint
    }

    private struct RenderSelection {
        let lockID: UUID?
        let instances: IndexSet
        let color: ObjectMaskDisplayColor
        let fillAlpha: CGFloat
    }

    private struct RenderedMask {
        let lockID: UUID?
        let color: ObjectMaskDisplayColor
        let fillAlpha: CGFloat
        let pixelBuffer: CVPixelBuffer
    }

    private struct CandidateMatch {
        let instance: Int
        let geometry: MaskGeometry
        let appearance: AppearanceSignature
        let score: CGFloat
    }

    private enum ToggleOutcome {
        case changed(ObjectMaskLockChange)
        case needsWorldSurface
        case unchanged
    }

    private static let previewColor = ObjectMaskDisplayColor(red: 0.08, green: 0.82, blue: 1.0)
    private static let lockedColors = [
        ObjectMaskDisplayColor(red: 1.00, green: 0.78, blue: 0.12),
        ObjectMaskDisplayColor(red: 1.00, green: 0.22, blue: 0.62),
        ObjectMaskDisplayColor(red: 0.20, green: 0.95, blue: 0.42),
        ObjectMaskDisplayColor(red: 1.00, green: 0.42, blue: 0.10),
        ObjectMaskDisplayColor(red: 0.64, green: 0.38, blue: 1.00),
        ObjectMaskDisplayColor(red: 0.20, green: 0.55, blue: 1.00),
        ObjectMaskDisplayColor(red: 1.00, green: 0.30, blue: 0.28),
        ObjectMaskDisplayColor(red: 0.16, green: 0.92, blue: 0.78)
    ]

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let segmentationRequest = GenerateForegroundInstanceMaskRequest()
    private static let motionLongEdge = 320
    private var trackedObjects: [TrackedObject] = []
    private var trackingGeneration: Int?

    func makePreview(from frame: ObjectMaskFrame) async -> ObjectMaskProcessingResult {
        if trackingGeneration != frame.trackingGeneration {
            trackedObjects.removeAll()
            trackingGeneration = frame.trackingGeneration
        }

        // Materialize the camera orientation in the CIImage coordinate space before handing it to
        // Vision. The request input and generated mask then share one upright coordinate system.
        let cameraImage = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(frame.orientation)
        let handler = ImageRequestHandler(cameraImage)

        do {
            guard let observation = try await handler.perform(segmentationRequest) else {
                ageUnmatchedTrackers()
                return result(preview: nil, frame: frame)
            }

            // Vision tracking is independent of ARKit's mapping-readiness label. In particular,
            // RGB-only devices must be able to retain a mask while world tracking is still limited.
            await updateTrackedObjects(
                using: observation,
                handler: handler,
                cameraImage: cameraImage,
                frame: frame
            )

            let toggleOutcome: ToggleOutcome
            if let toggleRequest = frame.toggleRequest,
               let imagePoint = imagePoint(
                   for: toggleRequest.normalizedViewportPoint,
                   imageSize: cameraImage.extent.size,
                   viewportSize: frame.viewportSize
               ) {
                toggleOutcome = try toggleLock(
                    at: imagePoint,
                    request: toggleRequest,
                    in: observation,
                    cameraImage: cameraImage,
                    frame: frame
                )
            } else {
                toggleOutcome = .unchanged
            }

            let selections = renderSelections(in: observation)
            let renderedMasks = try makeRenderedMasks(
                selections: selections,
                observation: observation,
                handler: handler
            )
            let preview = try makeDisplayImage(from: renderedMasks).map {
                ObjectMaskPreview(image: $0, timestamp: frame.timestamp)
            }
            let maskedPointClouds = makeMaskedPointClouds(
                from: renderedMasks,
                cameraImageSize: cameraImage.extent.size,
                frame: frame
            )

            switch toggleOutcome {
            case .changed(let change):
                return result(
                    preview: preview,
                    frame: frame,
                    lockChange: change,
                    maskedPointClouds: maskedPointClouds
                )
            case .needsWorldSurface:
                return result(
                    preview: preview,
                    frame: frame,
                    needsWorldSurface: true,
                    maskedPointClouds: maskedPointClouds
                )
            case .unchanged:
                return result(
                    preview: preview,
                    frame: frame,
                    maskedPointClouds: maskedPointClouds
                )
            }
        } catch {
            ageUnmatchedTrackers()
            return result(preview: nil, frame: frame)
        }
    }

    private func result(
        preview: ObjectMaskPreview?,
        frame: ObjectMaskFrame,
        lockChange: ObjectMaskLockChange? = nil,
        needsWorldSurface: Bool = false,
        motionKeyframe: ObjectMaskMotionKeyframe? = nil,
        maskedPointClouds: [ObjectMaskDepthPointCloud] = []
    ) -> ObjectMaskProcessingResult {
        let markers = makeMarkers(from: frame.anchorHints)
        return ObjectMaskProcessingResult(
            preview: preview,
            lockedObjectCount: trackedObjects.count,
            visibleObjectCount: trackedObjects.count(where: { $0.currentInstance != nil }),
            markers: markers,
            didToggleLock: lockChange != nil,
            lockChange: lockChange,
            needsWorldSurface: needsWorldSurface,
            motionKeyframe: motionKeyframe,
            maskedPointClouds: maskedPointClouds
        )
    }

    private func makeMarkers(from hints: [ObjectMaskAnchorHint]) -> [ObjectMaskMarker] {
        let hintsByID = Dictionary(uniqueKeysWithValues: hints.map { ($0.id, $0) })
        return trackedObjects.compactMap { trackedObject in
            guard let point = hintsByID[trackedObject.id]?.normalizedViewportPoint else {
                return nil
            }
            return ObjectMaskMarker(
                id: trackedObject.id,
                normalizedViewportPoint: point,
                color: Self.lockedColors[trackedObject.colorIndex],
                isMaskVisible: trackedObject.currentInstance != nil
            )
        }
    }

    /// Uses Vision's lightweight stateful tracker to predict each locked object's new rectangle,
    /// then associates that rectangle with the corresponding instance in the fresh segmentation.
    private func updateTrackedObjects(
        using observation: InstanceMaskObservation,
        handler: ImageRequestHandler,
        cameraImage: CIImage,
        frame: ObjectMaskFrame
    ) async {
        var geometryCache: [Int: MaskGeometry] = [:]
        var appearanceCache: [Int: AppearanceSignature] = [:]
        let hintsByID = Dictionary(uniqueKeysWithValues: frame.anchorHints.map { ($0.id, $0) })
        var candidateLists = [[CandidateMatch]](repeating: [], count: trackedObjects.count)

        for index in trackedObjects.indices {
            let anchorPoint: NormalizedPoint
            let cameraDistance: Float
            if let hint = hintsByID[trackedObjects[index].id] {
                guard let viewportPoint = hint.normalizedViewportPoint,
                      let projectedPoint = imagePoint(
                          for: viewportPoint,
                          imageSize: cameraImage.extent.size,
                          viewportSize: frame.viewportSize
                      ) else {
                    trackedObjects[index].currentInstance = nil
                    trackedObjects[index].missedFrames += 1
                    continue
                }
                anchorPoint = projectedPoint
                cameraDistance = hint.cameraDistance
            } else {
                // The AR anchor is installed on the main actor after this worker returns. Until its
                // first projection arrives, continue from the last visual location.
                anchorPoint = NormalizedPoint(
                    x: trackedObjects[index].lastGeometry.centroid.x,
                    y: trackedObjects[index].lastGeometry.centroid.y
                )
                cameraDistance = trackedObjects[index].referenceCameraDistance
            }

            let anchorSearchBox = projectedSearchBox(
                for: trackedObjects[index],
                anchorPoint: anchorPoint,
                cameraDistance: cameraDistance
            )
            let trackedObservation = try? await handler.perform(trackedObjects[index].request)
            let predictedBox = validatedPrediction(
                trackedObservation?.boundingBox,
                relativeTo: trackedObjects[index].lastGeometry.boundingBox
            )
            var candidateCounts = candidateInstanceCounts(
                in: observation,
                inside: anchorSearchBox
            )
            if trackedObjects[index].missedFrames <= 3 {
                mergeCandidateCounts(
                    candidateInstanceCounts(in: observation, inside: predictedBox),
                    into: &candidateCounts
                )
            }
            for instance in instances(near: anchorPoint, in: observation) {
                candidateCounts[instance, default: 0] += 16
            }
            for (instance, sampleCount) in candidateCounts {
                let geometry: MaskGeometry
                if let cachedGeometry = geometryCache[instance] {
                    geometry = cachedGeometry
                } else {
                    guard let mask = try? observation.generateMask(
                        for: IndexSet(integer: instance)
                    ), let measuredGeometry = maskGeometry(of: mask) else {
                        continue
                    }
                    geometryCache[instance] = measuredGeometry
                    geometry = measuredGeometry
                }

                let appearance: AppearanceSignature
                if let cachedAppearance = appearanceCache[instance] {
                    appearance = cachedAppearance
                } else {
                    guard let measuredAppearance = appearanceSignature(
                        of: cameraImage,
                        inside: geometry.boundingBox
                    ) else {
                        continue
                    }
                    appearanceCache[instance] = measuredAppearance
                    appearance = measuredAppearance
                }

                guard let score = matchScore(
                    candidate: geometry,
                    appearance: appearance,
                    trackedObject: trackedObjects[index],
                    anchorPoint: anchorPoint,
                    anchorSearchBox: anchorSearchBox,
                    visualPrediction: predictedBox,
                    cameraDistance: cameraDistance,
                    sampleCount: sampleCount,
                    timestamp: frame.timestamp
                ) else {
                    continue
                }

                candidateLists[index].append(
                    CandidateMatch(
                        instance: instance,
                        geometry: geometry,
                        appearance: appearance,
                        score: score
                    )
                )
            }

            // Four alternatives per lock are enough for a robust global decision while keeping the
            // tiny exhaustive assignment bounded even at the eight-lock UI limit.
            candidateLists[index] = Array(
                candidateLists[index].sorted { $0.score > $1.score }.prefix(4)
            )
        }

        // Solve all locks together. The previous greedy loop let the first tracker claim an
        // ambiguous instance and made a later, correct mask disappear.
        let assignments = globallyOptimalAssignments(candidateLists)
        for index in trackedObjects.indices {
            let bestMatch = assignments[index]
            if let bestMatch {
                // Correct the tracker back to the accepted segmentation bounds every frame. Without
                // this correction its rectangle can expand or drift onto the support surface.
                let correctedObservation = DetectedObjectObservation(
                    boundingBox: bestMatch.geometry.boundingBox
                )
                trackedObjects[index].request = TrackObjectRequest(
                    detectedObject: correctedObservation
                )
                trackedObjects[index].lastGeometry = bestMatch.geometry
                trackedObjects[index].currentInstance = bestMatch.instance
                trackedObjects[index].missedFrames = 0
                trackedObjects[index].lastAcceptedTimestamp = frame.timestamp
                trackedObjects[index].appearance = blendedAppearance(
                    previous: trackedObjects[index].appearance,
                    current: bestMatch.appearance
                )
            } else {
                trackedObjects[index].currentInstance = nil
                trackedObjects[index].missedFrames += 1
            }
        }
    }

    private func globallyOptimalAssignments(
        _ candidates: [[CandidateMatch]]
    ) -> [CandidateMatch?] {
        guard !candidates.isEmpty else {
            return []
        }

        var current = [CandidateMatch?](repeating: nil, count: candidates.count)
        var best = current
        var usedInstances = Set<Int>()
        var bestScore: CGFloat = -.greatestFiniteMagnitude

        func search(index: Int, score: CGFloat) {
            guard index < candidates.count else {
                if score > bestScore {
                    bestScore = score
                    best = current
                }
                return
            }

            // Missing a correction is safer than borrowing a different object's mask. Optical
            // flow and the world anchor keep the previous identity alive until segmentation
            // produces an unambiguous candidate again.
            current[index] = nil
            search(index: index + 1, score: score)

            for candidate in candidates[index] where !usedInstances.contains(candidate.instance) {
                usedInstances.insert(candidate.instance)
                current[index] = candidate
                search(index: index + 1, score: score + candidate.score)
                current[index] = nil
                usedInstances.remove(candidate.instance)
            }
        }

        search(index: 0, score: 0)
        return best
    }

    private func mergeCandidateCounts(_ source: [Int: Int], into destination: inout [Int: Int]) {
        for (instance, count) in source {
            destination[instance, default: 0] += count
        }
    }

    /// Predicts mask scale from camera-to-anchor distance. This permits legitimate close/far moves
    /// while preventing a small payload mask from suddenly expanding onto its supporting table.
    private func projectedSearchBox(
        for trackedObject: TrackedObject,
        anchorPoint: NormalizedPoint,
        cameraDistance: Float
    ) -> NormalizedRect {
        let safeDistance = max(cameraDistance, 0.05)
        let distanceScale = CGFloat(trackedObject.referenceCameraDistance / safeDistance)
        let scale = min(max(distanceScale, 0.25), 4.0)
        let reference = trackedObject.referenceGeometry.boundingBox
        let objectWidth = reference.width * scale
        let objectHeight = reference.height * scale
        let searchExpansion: CGFloat = trackedObject.missedFrames == 0 ? 1.45 : 1.85
        let width = min(max(objectWidth * searchExpansion, 0.08), 0.95)
        let height = min(max(objectHeight * searchExpansion, 0.08), 0.95)
        let anchorX = anchorPoint.x - trackedObject.anchorOffset.x * objectWidth
        let anchorY = anchorPoint.y - trackedObject.anchorOffset.y * objectHeight
        let x = min(max(anchorX - (width - objectWidth) / 2, 0), 1 - width)
        let y = min(max(anchorY - (height - objectHeight) / 2, 0), 1 - height)
        return NormalizedRect(x: x, y: y, width: width, height: height)
    }

    /// Vision tracking is only a search hint. A full-frame or abruptly displaced rectangle must not
    /// be allowed to search unrelated objects, even if one happens to have a similar mask area.
    private func validatedPrediction(
        _ prediction: NormalizedRect?,
        relativeTo previous: NormalizedRect
    ) -> NormalizedRect {
        guard let prediction,
              previous.width > 0,
              previous.height > 0 else {
            return previous
        }

        let widthScale = prediction.width / previous.width
        let heightScale = prediction.height / previous.height
        let previousCenter = CGPoint(
            x: previous.cgRect.midX,
            y: previous.cgRect.midY
        )
        let predictedCenter = CGPoint(
            x: prediction.cgRect.midX,
            y: prediction.cgRect.midY
        )
        let centerDistance = hypot(
            predictedCenter.x - previousCenter.x,
            predictedCenter.y - previousCenter.y
        )
        let maximumCenterDistance = max(previous.width, previous.height) * 2 + 0.08

        guard (0.5 ... 2.0).contains(widthScale),
              (0.5 ... 2.0).contains(heightScale),
              centerDistance <= maximumCenterDistance else {
            return previous
        }

        return prediction
    }

    private func ageUnmatchedTrackers() {
        for index in trackedObjects.indices {
            trackedObjects[index].currentInstance = nil
            trackedObjects[index].missedFrames += 1
        }
    }

    /// Tapping a currently tracked instance removes it. The AR layer supplies either a measured
    /// surface anchor or an RGB-only provisional ray anchor, so locking never depends on LiDAR.
    private func toggleLock(
        at point: NormalizedPoint,
        request: ObjectMaskToggleRequest,
        in observation: InstanceMaskObservation,
        cameraImage: CIImage,
        frame: ObjectMaskFrame
    ) throws -> ToggleOutcome {
        let tappedInstances = instances(near: point, in: observation)
        let hintsByID = Dictionary(uniqueKeysWithValues: frame.anchorHints.map { ($0.id, $0) })

        if let existingIndex = trackedObjects.firstIndex(where: { trackedObject in
            if let currentInstance = trackedObject.currentInstance,
               tappedInstances.contains(currentInstance) {
                return true
            }
            // Only use the rectangle fallback when segmentation missed the tap completely. If the
            // tap selected a different instance inside an overlapping rectangle, it is a new object.
            if tappedInstances.isEmpty,
               trackedObject.lastGeometry.boundingBox.cgRect.contains(point.cgPoint) {
                return true
            }
            guard let viewportPoint = hintsByID[trackedObject.id]?.normalizedViewportPoint,
                  let projectedPoint = imagePoint(
                      for: viewportPoint,
                      imageSize: cameraImage.extent.size,
                      viewportSize: frame.viewportSize
                  ) else {
                return false
            }
            return hypot(projectedPoint.x - point.x, projectedPoint.y - point.y) <= 0.065
        }) {
            let removed = trackedObjects.remove(at: existingIndex)
            return .changed(
                ObjectMaskLockChange(id: removed.id, kind: .removed, worldTransform: nil)
            )
        }

        guard trackedObjects.count < Self.lockedColors.count,
              let candidate = try lockCandidate(
                  near: point,
                  preferredInstances: tappedInstances,
                  in: observation
              ) else {
            return .unchanged
        }

        // The nearest-mask fallback is also used for removal. This keeps tap-again deletion working
        // when the low-resolution instance map misses the exact touch pixel.
        if let existingIndex = trackedObjects.firstIndex(where: {
            $0.currentInstance == candidate.instance
        }) {
            let removed = trackedObjects.remove(at: existingIndex)
            return .changed(
                ObjectMaskLockChange(id: removed.id, kind: .removed, worldTransform: nil)
            )
        }

        guard let proposedLockID = request.proposedLockID,
              let worldTransform = request.worldTransform,
              let cameraDistance = request.cameraDistance else {
            return .needsWorldSurface
        }

        let instance = candidate.instance
        let geometry = candidate.geometry

        let initialObservation = DetectedObjectObservation(boundingBox: geometry.boundingBox)
        let tracker = TrackObjectRequest(detectedObject: initialObservation)
        let colorIndex = firstAvailableColorIndex()
        let rect = geometry.boundingBox.cgRect
        let anchorOffset = CGPoint(
            x: min(max((point.x - rect.minX) / max(rect.width, 0.001), 0), 1),
            y: min(max((point.y - rect.minY) / max(rect.height, 0.001), 0), 1)
        )
        trackedObjects.append(
            TrackedObject(
                id: proposedLockID,
                colorIndex: colorIndex,
                request: tracker,
                referenceGeometry: geometry,
                anchorOffset: anchorOffset,
                referenceCameraDistance: max(cameraDistance, 0.05),
                appearance: appearanceSignature(of: cameraImage, inside: geometry.boundingBox),
                lastGeometry: geometry,
                currentInstance: instance,
                missedFrames: 0,
                lastAcceptedTimestamp: frame.timestamp
            )
        )
        return .changed(
            ObjectMaskLockChange(
                id: proposedLockID,
                kind: .added,
                worldTransform: worldTransform
            )
        )
    }

    /// Chooses the closest plausible foreground instance. Exact taps remain preferred, but a
    /// nearest-mask fallback makes selection tolerant of the low-resolution Vision mask boundary
    /// and small camera movement between the UI tap and the processed frame.
    private func lockCandidate(
        near point: NormalizedPoint,
        preferredInstances: IndexSet,
        in observation: InstanceMaskObservation
    ) throws -> (instance: Int, geometry: MaskGeometry)? {
        let preferred = Set(preferredInstances)
        var best: (instance: Int, geometry: MaskGeometry, score: CGFloat)?

        for instance in observation.allInstances {
            let mask = try observation.generateMask(for: IndexSet(integer: instance))
            guard let geometry = maskGeometry(of: mask),
                  geometry.area < 0.90,
                  !(geometry.boundingBox.width > 0.985 && geometry.boundingBox.height > 0.985) else {
                continue
            }

            let rect = geometry.boundingBox.cgRect
            let dx = max(rect.minX - point.x, point.x - rect.maxX, 0)
            let dy = max(rect.minY - point.y, point.y - rect.maxY, 0)
            let distanceToMaskBounds = hypot(dx, dy)
            let centroidDistance = hypot(
                geometry.centroid.x - point.x,
                geometry.centroid.y - point.y
            )
            let score = (preferred.contains(instance) ? -1 : 0)
                + distanceToMaskBounds * 5
                + centroidDistance * 0.15
                + geometry.area * 0.02
            if best == nil || score < best!.score {
                best = (instance, geometry, score)
            }
        }

        return best.map { ($0.instance, $0.geometry) }
    }

    private func firstAvailableColorIndex() -> Int {
        let usedColors = Set(trackedObjects.map(\.colorIndex))
        return Self.lockedColors.indices.first(where: { !usedColors.contains($0) }) ?? 0
    }

    /// Maps a SwiftUI tap through the centered aspect-fill crop used by the camera overlay and
    /// flips it into Vision's lower-left normalized coordinate system.
    private func imagePoint(
        for viewportPoint: CGPoint,
        imageSize: CGSize,
        viewportSize: CGSize
    ) -> NormalizedPoint? {
        guard imageSize.width > 0,
              imageSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return nil
        }

        let scale = max(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )
        let displayedSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        let cropX = (displayedSize.width - viewportSize.width) / 2
        let cropY = (displayedSize.height - viewportSize.height) / 2
        let viewportLocation = CGPoint(
            x: viewportPoint.x * viewportSize.width,
            y: viewportPoint.y * viewportSize.height
        )
        let imageX = (viewportLocation.x + cropX) / displayedSize.width
        let imageYFromTop = (viewportLocation.y + cropY) / displayedSize.height

        guard (0 ... 1).contains(imageX), (0 ... 1).contains(imageYFromTop) else {
            return nil
        }

        return NormalizedPoint(x: imageX, y: 1 - imageYFromTop)
    }

    /// Prefer the exact point, then search a small ring. This tolerates low-resolution instance
    /// masks missing the user's tap or the center aimer by a few pixels.
    private func instances(
        near point: NormalizedPoint,
        in observation: InstanceMaskObservation
    ) -> IndexSet {
        let centeredInstances = observation.instanceAtPoint(point)
        if !centeredInstances.isEmpty {
            return centeredInstances
        }

        let offsets: [CGFloat] = [0.0125, 0.025, 0.05]
        for offset in offsets {
            let candidates = [
                NormalizedPoint(x: point.x - offset, y: point.y),
                NormalizedPoint(x: point.x + offset, y: point.y),
                NormalizedPoint(x: point.x, y: point.y - offset),
                NormalizedPoint(x: point.x, y: point.y + offset),
                NormalizedPoint(x: point.x - offset, y: point.y - offset),
                NormalizedPoint(x: point.x + offset, y: point.y - offset),
                NormalizedPoint(x: point.x - offset, y: point.y + offset),
                NormalizedPoint(x: point.x + offset, y: point.y + offset)
            ]

            for candidate in candidates where (0 ... 1).contains(candidate.x) && (0 ... 1).contains(candidate.y) {
                let candidateInstances = observation.instanceAtPoint(candidate)
                if !candidateInstances.isEmpty {
                    return candidateInstances
                }
            }
        }

        return []
    }

    /// Collects every instance found inside the predicted rectangle. The caller validates their
    /// full mask geometry instead of blindly choosing the most common one (which may be the table).
    private func candidateInstanceCounts(
        in observation: InstanceMaskObservation,
        inside boundingBox: NormalizedRect
    ) -> [Int: Int] {
        let box = boundingBox.cgRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0, box.height > 0 else {
            return [:]
        }

        var counts: [Int: Int] = [:]
        let sampleCount = 7
        for row in 0 ..< sampleCount {
            for column in 0 ..< sampleCount {
                let x = box.minX + box.width * (CGFloat(column) + 0.5) / CGFloat(sampleCount)
                let y = box.minY + box.height * (CGFloat(row) + 0.5) / CGFloat(sampleCount)
                let instances = observation.instanceAtPoint(NormalizedPoint(x: x, y: y))
                for instance in instances {
                    counts[instance, default: 0] += 1
                }
            }
        }

        return counts
    }

    private func matchScore(
        candidate: MaskGeometry,
        appearance: AppearanceSignature,
        trackedObject: TrackedObject,
        anchorPoint: NormalizedPoint,
        anchorSearchBox: NormalizedRect,
        visualPrediction: NormalizedRect,
        cameraDistance: Float,
        sampleCount: Int,
        timestamp: TimeInterval
    ) -> CGFloat? {
        let reference = trackedObject.referenceGeometry
        guard reference.area > 0,
              reference.boundingBox.width > 0,
              reference.boundingBox.height > 0 else {
            return nil
        }

        // Consecutive-frame scale is more trustworthy than an RGB-only provisional anchor depth.
        // It naturally permits gradual close/far movement while rejecting a one-frame jump from an
        // object to the whole table. The 3D anchor remains a secondary reacquisition hint below.
        let previous = trackedObject.lastGeometry
        let expectedWidth = max(previous.boundingBox.width, 0.005)
        let expectedHeight = max(previous.boundingBox.height, 0.005)
        let expectedArea = max(previous.area, 0.00001)
        let elapsed = CGFloat(min(max(timestamp - trackedObject.lastAcceptedTimestamp, 0), 1.0))
        let scaleTolerance: CGFloat = trackedObject.missedFrames == 0
            ? min(1.75, 1.25 + elapsed * 1.0)
            : 2.2
        let widthRatio = candidate.boundingBox.width / expectedWidth
        let heightRatio = candidate.boundingBox.height / expectedHeight
        let areaRatio = candidate.area / expectedArea

        guard widthRatio >= 1 / scaleTolerance,
              widthRatio <= scaleTolerance,
              heightRatio >= 1 / scaleTolerance,
              heightRatio <= scaleTolerance,
              areaRatio >= 1 / (scaleTolerance * scaleTolerance),
              areaRatio <= scaleTolerance * scaleTolerance else {
            return nil
        }

        let predictedRect = anchorSearchBox.cgRect
        let candidateRect = candidate.boundingBox.cgRect
        let intersection = predictedRect.intersection(candidateRect)
        let intersectionArea = intersection.isNull ? 0 : intersection.width * intersection.height
        let unionArea = predictedRect.width * predictedRect.height
            + candidateRect.width * candidateRect.height
            - intersectionArea
        let intersectionOverUnion = unionArea > 0 ? intersectionArea / unionArea : 0
        let visualRect = visualPrediction.cgRect
        let visualIntersection = visualRect.intersection(candidateRect)
        let visualIntersectionArea = visualIntersection.isNull
            ? 0
            : visualIntersection.width * visualIntersection.height
        let visualUnionArea = visualRect.width * visualRect.height
            + candidateRect.width * candidateRect.height
            - visualIntersectionArea
        let visualIntersectionOverUnion = visualUnionArea > 0
            ? visualIntersectionArea / visualUnionArea
            : 0
        let dx = max(candidateRect.minX - anchorPoint.x, anchorPoint.x - candidateRect.maxX, 0)
        let dy = max(candidateRect.minY - anchorPoint.y, anchorPoint.y - candidateRect.maxY, 0)
        let anchorDistance = hypot(dx, dy)
        let allowedAnchorDistance = max(expectedWidth, expectedHeight) * 0.65 + 0.045

        guard visualIntersectionOverUnion >= 0.05
                || intersectionOverUnion >= 0.04
                || anchorDistance <= allowedAnchorDistance else {
            return nil
        }

        let visualDistance = appearanceDistance(appearance, trackedObject.appearance)
        if let visualDistance {
            let maximumVisualDistance: Float = trackedObject.missedFrames > 2 ? 0.52 : 0.68
            guard visualDistance <= maximumVisualDistance else {
                return nil
            }
        }

        let areaSimilarity = 1 - min(abs(log(areaRatio)), 1)
        let visualSimilarity = visualDistance.map { CGFloat(1 - min($0 / 0.7, 1)) } ?? 0
        return CGFloat(sampleCount)
            + intersectionOverUnion * 10
            + visualIntersectionOverUnion * 14
            + areaSimilarity * 5
            + visualSimilarity * 9
    }

    private func appearanceDistance(
        _ candidate: AppearanceSignature,
        _ reference: AppearanceSignature?
    ) -> Float? {
        guard let reference, candidate.values.count == reference.values.count,
              !candidate.values.isEmpty else {
            return nil
        }

        var squaredDistance: Float = 0
        for index in candidate.values.indices {
            let difference = candidate.values[index] - reference.values[index]
            squaredDistance += difference * difference
        }
        return sqrt(squaredDistance / Float(candidate.values.count))
    }

    private func blendedAppearance(
        previous: AppearanceSignature?,
        current: AppearanceSignature
    ) -> AppearanceSignature {
        guard let previous, previous.values.count == current.values.count else {
            return current
        }

        let values = zip(previous.values, current.values).map { old, new in
            old * 0.92 + new * 0.08
        }
        return AppearanceSignature(values: values)
    }

    /// A small chromaticity/luminance grid is inexpensive to compute and gives reacquisition an
    /// identity signal beyond rectangle size. Normalizing each sample makes it less sensitive to
    /// the exposure changes that occur while walking around an object.
    private func appearanceSignature(
        of image: CIImage,
        inside boundingBox: NormalizedRect
    ) -> AppearanceSignature? {
        let extent = image.extent
        let normalizedRect = boundingBox.cgRect
        let cropRect = CGRect(
            x: extent.minX + normalizedRect.minX * extent.width,
            y: extent.minY + normalizedRect.minY * extent.height,
            width: normalizedRect.width * extent.width,
            height: normalizedRect.height * extent.height
        ).intersection(extent)
        guard !cropRect.isNull, cropRect.width >= 2, cropRect.height >= 2 else {
            return nil
        }

        let sampleWidth = 6
        let sampleHeight = 6
        let translated = image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
        let sampled = translated.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(sampleWidth) / cropRect.width,
                y: CGFloat(sampleHeight) / cropRect.height
            )
        )
        var bytes = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        ciContext.render(
            sampled,
            toBitmap: &bytes,
            rowBytes: sampleWidth * 4,
            bounds: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight),
            format: .RGBA8,
            colorSpace: rgbColorSpace
        )

        var luminances = [Float]()
        luminances.reserveCapacity(sampleWidth * sampleHeight)
        for pixelIndex in 0 ..< sampleWidth * sampleHeight {
            let offset = pixelIndex * 4
            let red = Float(bytes[offset]) / 255
            let green = Float(bytes[offset + 1]) / 255
            let blue = Float(bytes[offset + 2]) / 255
            luminances.append(red * 0.2126 + green * 0.7152 + blue * 0.0722)
        }
        let meanLuminance = max(luminances.reduce(0, +) / Float(luminances.count), 0.04)

        var values = [Float]()
        values.reserveCapacity(sampleWidth * sampleHeight * 4)
        for pixelIndex in 0 ..< sampleWidth * sampleHeight {
            let offset = pixelIndex * 4
            let red = Float(bytes[offset]) / 255
            let green = Float(bytes[offset + 1]) / 255
            let blue = Float(bytes[offset + 2]) / 255
            let channelSum = max(red + green + blue, 0.05)
            values.append(red / channelSum)
            values.append(green / channelSum)
            values.append(blue / channelSum)
            values.append(min(luminances[pixelIndex] / meanLuminance, 2))
        }
        return AppearanceSignature(values: values)
    }

    private func maskGeometry(of pixelBuffer: CVPixelBuffer) -> MaskGeometry? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_OneComponent32Float,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let floatsPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<Float>.stride
        let pixels = baseAddress.assumingMemoryBound(to: Float.self)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var selectedPixelCount = 0
        var sumX: Double = 0
        var sumY: Double = 0

        for y in 0 ..< height {
            let row = pixels.advanced(by: y * floatsPerRow)
            for x in 0 ..< width where row[x] > 0.5 {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                selectedPixelCount += 1
                sumX += Double(x) + 0.5
                sumY += Double(y) + 0.5
            }
        }

        guard maxX >= minX, maxY >= minY, selectedPixelCount > 0 else {
            return nil
        }

        let padding: CGFloat = 0.015
        let x = max(CGFloat(minX) / CGFloat(width) - padding, 0)
        // Pixel-buffer rows have a top-left origin; Vision rectangles use a lower-left origin.
        let y = max(1 - CGFloat(maxY + 1) / CGFloat(height) - padding, 0)
        let rectWidth = min(CGFloat(maxX - minX + 1) / CGFloat(width) + padding * 2, 1 - x)
        let rectHeight = min(CGFloat(maxY - minY + 1) / CGFloat(height) + padding * 2, 1 - y)
        let boundingBox = NormalizedRect(x: x, y: y, width: rectWidth, height: rectHeight)
        let area = CGFloat(selectedPixelCount) / CGFloat(width * height)
        let centroid = CGPoint(
            x: CGFloat(sumX / Double(selectedPixelCount)) / CGFloat(width),
            y: 1 - CGFloat(sumY / Double(selectedPixelCount)) / CGFloat(height)
        )
        return MaskGeometry(boundingBox: boundingBox, area: area, centroid: centroid)
    }

    private func renderSelections(in observation: InstanceMaskObservation) -> [RenderSelection] {
        var selections: [RenderSelection] = []

        for trackedObject in trackedObjects {
            guard let instance = trackedObject.currentInstance else {
                continue
            }
            selections.append(
                RenderSelection(
                    lockID: trackedObject.id,
                    instances: IndexSet(integer: instance),
                    color: Self.lockedColors[trackedObject.colorIndex],
                    fillAlpha: 0.24
                )
            )
        }

        return selections
    }

    /// Converts the selected instance masks into colored translucent fills with stronger edges.
    private func makeRenderedMasks(
        selections: [RenderSelection],
        observation: InstanceMaskObservation,
        handler: ImageRequestHandler
    ) throws -> [RenderedMask] {
        try selections.map { selection in
            let pixelBuffer = try observation.generateScaledMask(
                for: selection.instances,
                scaledToImageFrom: handler
            )
            return RenderedMask(
                lockID: selection.lockID,
                color: selection.color,
                fillAlpha: selection.fillAlpha,
                pixelBuffer: pixelBuffer
            )
        }
    }

    private func makeDisplayImage(from renderedMasks: [RenderedMask]) throws -> CGImage? {
        var composite: CIImage?
        var imageExtent: CGRect?

        for renderedMask in renderedMasks {
            let mask = CIImage(cvPixelBuffer: renderedMask.pixelBuffer)
            let fill = tint(mask, color: renderedMask.color, alpha: renderedMask.fillAlpha)
            let edgeMask = mask.applyingFilter(
                "CIMorphologyGradient",
                parameters: [kCIInputRadiusKey: 4.0]
            )
            let edge = tint(edgeMask, color: renderedMask.color, alpha: 0.95)
            let layer = edge.composited(over: fill).cropped(to: mask.extent)
            composite = composite.map { layer.composited(over: $0) } ?? layer
            imageExtent = mask.extent
        }

        guard let composite, let imageExtent else {
            return nil
        }
        return ciContext.createCGImage(composite.cropped(to: imageExtent), from: imageExtent)
    }

    private func makeMotionKeyframe(
        from renderedMasks: [RenderedMask],
        cameraImageSize: CGSize,
        frame: ObjectMaskFrame
    ) -> ObjectMaskMotionKeyframe? {
        guard cameraImageSize.width > 0, cameraImageSize.height > 0 else {
            return nil
        }

        let longEdge = CGFloat(Self.motionLongEdge)
        let scale = longEdge / max(cameraImageSize.width, cameraImageSize.height)
        let width = max(Int((cameraImageSize.width * scale).rounded()), 1)
        let height = max(Int((cameraImageSize.height * scale).rounded()), 1)
        let layers = renderedMasks.compactMap { renderedMask -> ObjectMaskMotionLayer? in
            guard let lockID = renderedMask.lockID,
                  let mask = downsampleMask(
                      renderedMask.pixelBuffer,
                      width: width,
                      height: height
                  ) else {
                return nil
            }
            return ObjectMaskMotionLayer(id: lockID, color: renderedMask.color, mask: mask)
        }

        return ObjectMaskMotionKeyframe(
            pixelBuffer: frame.pixelBuffer,
            orientation: frame.orientation,
            timestamp: frame.timestamp,
            width: width,
            height: height,
            activeLockIDs: Set(trackedObjects.map(\.id)),
            onScreenLockIDs: Set(
                frame.anchorHints.compactMap { $0.normalizedViewportPoint == nil ? nil : $0.id }
            ),
            layers: layers
        )
    }

    private func downsampleMask(
        _ pixelBuffer: CVPixelBuffer,
        width targetWidth: Int,
        height targetHeight: Int
    ) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_OneComponent32Float,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              targetWidth > 0,
              targetHeight > 0 else {
            return nil
        }

        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<Float>.stride
        let source = baseAddress.assumingMemoryBound(to: Float.self)
        var result = [UInt8](repeating: 0, count: targetWidth * targetHeight)

        for y in 0 ..< targetHeight {
            let sourceY = min(Int((CGFloat(y) + 0.5) * CGFloat(sourceHeight) / CGFloat(targetHeight)), sourceHeight - 1)
            let row = source.advanced(by: sourceY * sourceStride)
            for x in 0 ..< targetWidth {
                let sourceX = min(Int((CGFloat(x) + 0.5) * CGFloat(sourceWidth) / CGFloat(targetWidth)), sourceWidth - 1)
                if row[sourceX] > 0.5 {
                    result[y * targetWidth + x] = 255
                }
            }
        }
        return result
    }

    /// Back-projects only depth pixels accepted by a locked object's mask. The mask and depth map
    /// are retained from the same ARFrame, avoiding the stale-mask/new-depth mismatch that used to
    /// turn a fast camera movement into a table-sized point cloud.
    private func makeMaskedPointClouds(
        from renderedMasks: [RenderedMask],
        cameraImageSize: CGSize,
        frame: ObjectMaskFrame
    ) -> [ObjectMaskDepthPointCloud] {
        guard let depth = frame.depthSnapshot,
              cameraImageSize.width > 0,
              cameraImageSize.height > 0 else {
            return []
        }

        let hintsByID = Dictionary(uniqueKeysWithValues: frame.anchorHints.map { ($0.id, $0) })
        return renderedMasks.compactMap { renderedMask in
            guard let lockID = renderedMask.lockID,
                  let hint = hintsByID[lockID] else {
                return nil
            }
            let points = maskedWorldPoints(
                mask: renderedMask.pixelBuffer,
                anchor: hint,
                cameraImageSize: cameraImageSize,
                viewportSize: frame.viewportSize,
                depth: depth
            )
            guard !points.isEmpty else {
                return nil
            }
            return ObjectMaskDepthPointCloud(id: lockID, points: points, timestamp: frame.timestamp)
        }
    }

    private func maskedWorldPoints(
        mask: CVPixelBuffer,
        anchor: ObjectMaskAnchorHint,
        cameraImageSize: CGSize,
        viewportSize: CGSize,
        depth: ObjectMaskDepthSnapshot
    ) -> [SIMD3<Float>] {
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return []
        }

        let depthMap = depth.depthMap
        let confidenceMap = depth.confidenceMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let maskWidth = CVPixelBufferGetWidth(mask)
        let maskHeight = CVPixelBufferGetHeight(mask)
        let imageResolution = depth.cameraImageResolution
        let scaleX = Float(depthWidth) / Float(imageResolution.width)
        let scaleY = Float(depthHeight) / Float(imageResolution.height)
        let fx = depth.cameraIntrinsics.columns.0.x * scaleX
        let fy = depth.cameraIntrinsics.columns.1.y * scaleY
        let cx = depth.cameraIntrinsics.columns.2.x * scaleX
        let cy = depth.cameraIntrinsics.columns.2.y * scaleY
        guard fx > 0, fy > 0 else {
            return []
        }

        CVPixelBufferLockBaseAddress(mask, .readOnly)
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        }
        defer {
            CVPixelBufferUnlockBaseAddress(mask, .readOnly)
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }

        guard let maskBase = CVPixelBufferGetBaseAddress(mask)?.assumingMemoryBound(to: Float.self),
              let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return []
        }
        let maskStride = CVPixelBufferGetBytesPerRow(mask) / MemoryLayout<Float>.stride
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let cameraToWorld = depth.cameraTransform
        let worldToCamera = cameraToWorld.inverse
        let anchorInCamera = worldToCamera * SIMD4<Float>(anchor.worldPosition, 1)
        let anchorDepth = max(-anchorInCamera.z, 0.05)
        let maximumDepthDifference = max(min(anchorDepth * 0.30, 0.45), 0.12)
        let maximumWorldDistanceSquared: Float = 0.55 * 0.55
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(depthWidth * depthHeight / 5)

        for row in 0 ..< depthHeight {
            let depthRow = depthBase
                .advanced(by: row * depthRowBytes)
                .assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase?
                .advanced(by: row * confidenceRowBytes)
                .assumingMemoryBound(to: UInt8.self)

            for column in 0 ..< depthWidth {
                let measuredDepth = depthRow[column]
                guard measuredDepth > 0.15,
                      measuredDepth < 3.5,
                      abs(measuredDepth - anchorDepth) <= maximumDepthDifference,
                      (confidenceRow?[column] ?? 2) >= 1 else {
                    continue
                }

                let nativeImagePoint = CGPoint(
                    x: (CGFloat(column) + 0.5) / CGFloat(depthWidth),
                    y: (CGFloat(row) + 0.5) / CGFloat(depthHeight)
                )
                let viewportPoint = nativeImagePoint.applying(depth.imageToViewportTransform)
                guard let visionPoint = imagePoint(
                    for: viewportPoint,
                    imageSize: cameraImageSize,
                    viewportSize: viewportSize
                ) else {
                    continue
                }
                let maskX = min(max(Int(visionPoint.x * CGFloat(maskWidth)), 0), maskWidth - 1)
                let maskY = min(max(Int((1 - visionPoint.y) * CGFloat(maskHeight)), 0), maskHeight - 1)
                guard maskBase[maskY * maskStride + maskX] > 0.5 else {
                    continue
                }

                let x = (Float(column) - cx) * measuredDepth / fx
                let y = (Float(row) - cy) * measuredDepth / fy
                let world = cameraToWorld * SIMD4<Float>(x, -y, -measuredDepth, 1)
                let worldPoint = SIMD3<Float>(world.x, world.y, world.z)
                let delta = worldPoint - anchor.worldPosition
                guard simd_length_squared(delta) <= maximumWorldDistanceSquared,
                      worldPoint.x.isFinite,
                      worldPoint.y.isFinite,
                      worldPoint.z.isFinite else {
                    continue
                }
                points.append(worldPoint)
            }
        }
        return points
    }

    private func tint(_ image: CIImage, color: ObjectMaskDisplayColor, alpha: CGFloat) -> CIImage {
        image.applyingFilter(
            "CIColorMatrix",
            parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(
                    x: CGFloat(color.red),
                    y: CGFloat(color.green),
                    z: CGFloat(color.blue),
                    w: 0
                )
            ]
        )
    }
}

/// Propagates every locked binary mask through the RGB video between segmentation corrections.
/// This worker is deliberately separate from `ObjectMaskProcessor`: the expensive foreground
/// segmentation request can be busy without blocking the much faster temporal update stream.
actor ObjectMaskMotionProcessor {
    private struct LayerState {
        let id: UUID
        let color: ObjectMaskDisplayColor
        var mask: [UInt8]
    }

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private var opticalFlowRequest: VNTrackOpticalFlowRequest?
    private var layers: [UUID: LayerState] = [:]
    private var activeLockIDs = Set<UUID>()
    private var width = 0
    private var height = 0
    private var lastTimestamp: TimeInterval = -.greatestFiniteMagnitude

    func install(_ keyframe: ObjectMaskMotionKeyframe) -> ObjectMaskPreview? {
        let correctedLayers = Dictionary(
            uniqueKeysWithValues: keyframe.layers.map {
                ($0.id, LayerState(id: $0.id, color: $0.color, mask: $0.mask))
            }
        )

        if keyframe.activeLockIDs.isEmpty {
            reset()
            return nil
        }

        // A partial segmentation correction must not erase masks that optical flow is still
        // tracking. This is especially important when several objects are selected and Vision
        // temporarily omits one at a different viewing distance.
        let retainedIDs = Set(layers.keys).intersection(keyframe.activeLockIDs)
        let missingOnScreenIDs = retainedIDs
            .intersection(keyframe.onScreenLockIDs)
            .subtracting(correctedLayers.keys)
        if keyframe.activeLockIDs == activeLockIDs,
           !missingOnScreenIDs.isEmpty {
            return makePreview(timestamp: lastTimestamp)
        }

        guard let camera = makeWorkingCamera(
            keyframe.pixelBuffer,
            orientation: keyframe.orientation,
            width: keyframe.width,
            height: keyframe.height
        ) else {
            return makePreview(timestamp: lastTimestamp)
        }

        let request = VNTrackOpticalFlowRequest()
        request.computationAccuracy = .high
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cvPixelBuffer: camera, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return makePreview(timestamp: lastTimestamp)
        }

        opticalFlowRequest = request
        layers = correctedLayers
        activeLockIDs = keyframe.activeLockIDs
        width = keyframe.width
        height = keyframe.height
        lastTimestamp = keyframe.timestamp
        return makePreview(timestamp: keyframe.timestamp)
    }

    func propagate(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) -> ObjectMaskPreview? {
        guard timestamp > lastTimestamp,
              width > 0,
              height > 0,
              !layers.isEmpty,
              let request = opticalFlowRequest,
              let camera = makeWorkingCamera(
                  pixelBuffer,
                  orientation: orientation,
                  width: width,
                  height: height
              ) else {
            return makePreview(timestamp: lastTimestamp)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: camera, orientation: .up, options: [:])
        do {
            try handler.perform([request])
            guard let flow = request.results?.first?.pixelBuffer else {
                return makePreview(timestamp: lastTimestamp)
            }
            for id in Array(layers.keys) {
                guard var layer = layers[id] else {
                    continue
                }
                layer.mask = warp(layer.mask, with: flow)
                layers[id] = layer
            }
            lastTimestamp = timestamp
            return makePreview(timestamp: timestamp)
        } catch {
            // Retain the last good mask rather than flashing it off for one failed flow request.
            return makePreview(timestamp: lastTimestamp)
        }
    }

    func reset() {
        opticalFlowRequest = nil
        layers.removeAll()
        activeLockIDs.removeAll()
        width = 0
        height = 0
        lastTimestamp = -.greatestFiniteMagnitude
    }

    private func makeWorkingCamera(
        _ pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &output
        ) == kCVReturnSuccess, let output else {
            return nil
        }

        let oriented = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let extent = oriented.extent
        guard extent.width > 0, extent.height > 0 else {
            return nil
        }
        let normalized = oriented.transformed(
            by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        )
        let scaled = normalized.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(width) / extent.width,
                y: CGFloat(height) / extent.height
            )
        )
        ciContext.render(
            scaled,
            to: output,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace
        )
        return output
    }

    private func warp(_ source: [UInt8], with flow: CVPixelBuffer) -> [UInt8] {
        guard source.count == width * height,
              CVPixelBufferGetPixelFormatType(flow) == kCVPixelFormatType_TwoComponent32Float else {
            return source
        }

        CVPixelBufferLockBaseAddress(flow, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flow, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(flow) else {
            return source
        }
        let flowWidth = CVPixelBufferGetWidth(flow)
        let flowHeight = CVPixelBufferGetHeight(flow)
        guard flowWidth == width, flowHeight == height else {
            return source
        }
        let vectorsPerRow = CVPixelBufferGetBytesPerRow(flow) / MemoryLayout<SIMD2<Float>>.stride
        let vectors = base.assumingMemoryBound(to: SIMD2<Float>.self)

        var xSamples: [Float] = []
        var ySamples: [Float] = []
        xSamples.reserveCapacity(source.count / 18)
        ySamples.reserveCapacity(source.count / 18)
        for y in stride(from: 0, to: height, by: 3) {
            let flowRow = vectors.advanced(by: y * vectorsPerRow)
            for x in stride(from: 0, to: width, by: 3) where source[y * width + x] != 0 {
                let vector = flowRow[x]
                if vector.x.isFinite, vector.y.isFinite {
                    xSamples.append(vector.x)
                    ySamples.append(vector.y)
                }
            }
        }
        guard !xSamples.isEmpty else {
            return source
        }
        let medianX = median(&xSamples)
        let medianY = median(&ySamples)
        let maximumFrameMotion = Float(max(width, height)) * 0.45
        guard abs(medianX) <= maximumFrameMotion, abs(medianY) <= maximumFrameMotion else {
            return source
        }

        var destination = [UInt8](repeating: 0, count: source.count)
        let maximumLocalDeviation = max(Float(max(width, height)) * 0.10, 10)
        for y in 0 ..< height {
            let flowRow = vectors.advanced(by: y * vectorsPerRow)
            for x in 0 ..< width where source[y * width + x] != 0 {
                var vector = flowRow[x]
                if !vector.x.isFinite || !vector.y.isFinite
                    || abs(vector.x - medianX) > maximumLocalDeviation
                    || abs(vector.y - medianY) > maximumLocalDeviation {
                    vector = SIMD2<Float>(medianX, medianY)
                }
                let targetX = Int((Float(x) + vector.x).rounded())
                let targetY = Int((Float(y) + vector.y).rounded())
                if targetX >= 0, targetX < width, targetY >= 0, targetY < height {
                    destination[targetY * width + targetX] = 255
                }
            }
        }

        destination = close(destination)
        let oldArea = source.count(where: { $0 != 0 })
        let newArea = destination.count(where: { $0 != 0 })
        guard oldArea > 0,
              newArea >= Int(Double(oldArea) * 0.72),
              newArea <= Int(Double(oldArea) * 1.28) else {
            return translated(source, x: medianX, y: medianY)
        }
        return destination
    }

    private func translated(_ source: [UInt8], x offsetX: Float, y offsetY: Float) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: source.count)
        let dx = Int(offsetX.rounded())
        let dy = Int(offsetY.rounded())
        for y in 0 ..< height {
            for x in 0 ..< width where source[y * width + x] != 0 {
                let targetX = x + dx
                let targetY = y + dy
                if targetX >= 0, targetX < width, targetY >= 0, targetY < height {
                    result[targetY * width + targetX] = 255
                }
            }
        }
        return result
    }

    private func close(_ source: [UInt8]) -> [UInt8] {
        var dilated = [UInt8](repeating: 0, count: source.count)
        for y in 0 ..< height {
            for x in 0 ..< width {
                var isSet = false
                for neighborY in max(y - 1, 0) ... min(y + 1, height - 1) {
                    for neighborX in max(x - 1, 0) ... min(x + 1, width - 1)
                    where source[neighborY * width + neighborX] != 0 {
                        isSet = true
                        break
                    }
                    if isSet { break }
                }
                if isSet { dilated[y * width + x] = 255 }
            }
        }

        var eroded = [UInt8](repeating: 0, count: source.count)
        guard width > 2, height > 2 else {
            return dilated
        }
        for y in 1 ..< height - 1 {
            for x in 1 ..< width - 1 {
                var allSet = true
                for neighborY in y - 1 ... y + 1 {
                    for neighborX in x - 1 ... x + 1
                    where dilated[neighborY * width + neighborX] == 0 {
                        allSet = false
                        break
                    }
                    if !allSet { break }
                }
                if allSet { eroded[y * width + x] = 255 }
            }
        }
        return eroded
    }

    private func median(_ values: inout [Float]) -> Float {
        values.sort()
        return values[values.count / 2]
    }

    private func makePreview(timestamp: TimeInterval) -> ObjectMaskPreview? {
        guard width > 0, height > 0, !layers.isEmpty else {
            return nil
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        for layer in layers.values {
            guard layer.mask.count == width * height else {
                continue
            }
            for y in 0 ..< height {
                for x in 0 ..< width where layer.mask[y * width + x] != 0 {
                    let isEdge = x == 0 || x == width - 1 || y == 0 || y == height - 1
                        || layer.mask[y * width + max(x - 1, 0)] == 0
                        || layer.mask[y * width + min(x + 1, width - 1)] == 0
                        || layer.mask[max(y - 1, 0) * width + x] == 0
                        || layer.mask[min(y + 1, height - 1) * width + x] == 0
                    let sourceAlpha = isEdge ? 0.95 : 0.24
                    let offset = (y * width + x) * 4
                    let destinationAlpha = Double(rgba[offset + 3]) / 255
                    let outputAlpha = sourceAlpha + destinationAlpha * (1 - sourceAlpha)
                    guard outputAlpha > 0 else { continue }
                    let destinationRed = Double(rgba[offset]) / 255
                    let destinationGreen = Double(rgba[offset + 1]) / 255
                    let destinationBlue = Double(rgba[offset + 2]) / 255
                    let red = (layer.color.red * sourceAlpha + destinationRed * destinationAlpha * (1 - sourceAlpha)) / outputAlpha
                    let green = (layer.color.green * sourceAlpha + destinationGreen * destinationAlpha * (1 - sourceAlpha)) / outputAlpha
                    let blue = (layer.color.blue * sourceAlpha + destinationBlue * destinationAlpha * (1 - sourceAlpha)) / outputAlpha
                    rgba[offset] = UInt8(min(max(red * 255, 0), 255))
                    rgba[offset + 1] = UInt8(min(max(green * 255, 0), 255))
                    rgba[offset + 2] = UInt8(min(max(blue * 255, 0), 255))
                    rgba[offset + 3] = UInt8(min(max(outputAlpha * 255, 0), 255))
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        return ObjectMaskPreview(image: image, timestamp: timestamp)
    }
}
