import CoreImage
import CoreVideo
import Foundation
import ImageIO
import simd
import Vision

// Runs Vision's foreground-instance segmentation and keeps masks matched to the same physical
// object across frames.
//
// In:  camera frames, plus anchor hints telling it where each tracked object was last seen.
// Out: mask layers to draw, per-object markers, and the depth samples belonging to each object.
//      Work happens off the main actor; results are timestamped so late frames can be discarded.

nonisolated enum ObjectMaskCandidatePolicy {
    /// Half-width of the window around the crosshair that counts as "what the phone is pointed at",
    /// in normalized image units. Nothing outside it may be masked or measured, however well Vision
    /// segmented it.
    static let aimWindowRadius: CGFloat = 0.12
    /// How far the crosshair may fall outside a mask's own bounds and still count as pointing at it.
    /// Some slack is needed because a small object's mask does not always sit under a hand-held
    /// crosshair; a whole screen-width of slack is what put masks on objects at the edge.
    static let aimBoundsSlack: CGFloat = 0.05
    /// The same rule for a mask that is *already* on screen, deliberately looser. One threshold for
    /// both makes the mask blink on and off while the crosshair sits on the boundary; letting go later
    /// than it takes hold is what stops that.
    static let heldAimBoundsSlack: CGFloat = 0.11
    /// How much of the smaller of the two masks the overlap must cover for a candidate to count as the
    /// same object from one segmentation to the next. Vision renumbers its instances every frame, so
    /// sameness can only be judged geometrically.
    static let continuationOverlap: CGFloat = 0.5
    /// After this long with no live mask, there is nothing left to continue: the phone has been pointed
    /// somewhere else and the next mask is a fresh decision.
    static let continuationTimeout: TimeInterval = 0.7

    /// Probes on the crosshair are the cheap, preferred path. When they miss — a small object can
    /// slip between them — widen only to the instances found inside the aim window. Widening to
    /// every instance in the frame, as this used to, is what let the nearest-centroid choice land on
    /// an object at the edge of the screen that nobody was pointing at.
    static func previewInstances(
        nearby: IndexSet,
        withinAim: @autoclosure () -> IndexSet,
        excluding excluded: Set<Int>
    ) -> [Int] {
        let eligibleNearby = nearby.filter { !excluded.contains($0) }
        if !eligibleNearby.isEmpty {
            return eligibleNearby
        }
        return withinAim().filter { !excluded.contains($0) }
    }

    /// True when the crosshair is inside the mask's bounds, or close enough outside them to be read
    /// as pointing at it.
    static func isAimedAt(
        boundingBox: CGRect,
        aim: CGPoint,
        slack: CGFloat = aimBoundsSlack
    ) -> Bool {
        guard !boundingBox.isNull,
              boundingBox.width > 0,
              boundingBox.height > 0 else {
            return false
        }
        return distance(from: aim, toBoundsOf: boundingBox) <= slack
    }

    /// Zero while the point is inside the rectangle, and how far outside it otherwise.
    static func distance(from point: CGPoint, toBoundsOf rect: CGRect) -> CGFloat {
        hypot(
            max(rect.minX - point.x, point.x - rect.maxX, 0),
            max(rect.minY - point.y, point.y - rect.maxY, 0)
        )
    }

    /// Which candidate is the mask already on screen, if any of them is.
    ///
    /// Without this the preview is a fresh decision every segmentation, and two candidates whose scores
    /// are all but identical — an object and the object plus its shadow, two touching objects — swap
    /// places several times a second. That is the flicker, and the jump from one object to the other.
    ///
    /// Sameness is judged by how much of the *smaller* of the two the overlap covers, not by
    /// intersection-over-union. Vision does not segment a complex object the same way twice: one frame it
    /// is one instance, the next it is split into the body and the handle. A part of what was on screen has
    /// a poor union score but sits almost entirely inside it, and it is plainly the same object — under a
    /// union rule it read as something new, and the preview swapped between the whole and the part. Of the
    /// candidates that qualify, the one sharing the most area wins, so a re-pick lands on the most complete
    /// piece rather than the first fragment.
    static func continuation(
        of previous: CGRect,
        among candidates: [(instance: Int, boundingBox: CGRect)],
        minimumOverlap: CGFloat = continuationOverlap
    ) -> Int? {
        guard previous.width > 0, previous.height > 0 else { return nil }
        var best: (instance: Int, sharedArea: CGFloat)?
        for candidate in candidates {
            guard overlapOfSmaller(previous, candidate.boundingBox) >= minimumOverlap else {
                continue
            }
            let shared = sharedArea(previous, candidate.boundingBox)
            if best == nil || shared > best!.sharedArea {
                best = (candidate.instance, shared)
            }
        }
        return best?.instance
    }

    /// The overlap as a fraction of the smaller rectangle: 1 when either is wholly inside the other.
    static func overlapOfSmaller(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let firstArea = first.width * first.height
        let secondArea = second.width * second.height
        guard firstArea > 0, secondArea > 0 else { return 0 }
        let shared = sharedArea(first, second)
        guard shared > 0 else { return 0 }
        return shared / min(firstArea, secondArea)
    }

    static func sharedArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.intersection(second)
        guard !intersection.isNull,
              intersection.width > 0,
              intersection.height > 0 else {
            return 0
        }
        return intersection.width * intersection.height
    }

    /// Whether to stay on the mask already on screen rather than take the best-scoring candidate.
    ///
    /// The held mask wins every close call — that is what stops the flicker — but not once the crosshair
    /// has moved right inside another object. Then the operator has plainly aimed somewhere else and a
    /// mask that clung on would be its own kind of wrong.
    static func keepsHeldMask(
        heldAimDistance: CGFloat,
        challengerAimDistance: CGFloat?
    ) -> Bool {
        guard heldAimDistance <= heldAimBoundsSlack else { return false }
        guard let challengerAimDistance else { return true }
        return !(challengerAimDistance <= 0 && heldAimDistance > 0)
    }

    static func intersectionOverUnion(_ first: CGRect, _ second: CGRect) -> CGFloat {
        guard first.width > 0, first.height > 0, second.width > 0, second.height > 0 else {
            return 0
        }
        let intersection = first.intersection(second)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = first.width * first.height
            + second.width * second.height
            - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}

/// Whether a freshly segmented live mask is worth swapping in for the one already on screen.
///
/// Vision re-segments every frame and its silhouette is never quite the same twice: a few pixels here,
/// a notch there. Redrawing the mask each time turns that into a visible shimmer even while the phone
/// and the object are both still. When the new mask is in the same place as the one on screen, the one
/// on screen is already the right answer and is left alone — the display tracker keeps it aligned in
/// the meantime. A hold is capped in time so a mask can never go stale.
nonisolated enum ObjectMaskPreviewHold {
    /// However steady the scene, the picture is refreshed at least this often.
    static let maximumHoldSeconds: TimeInterval = 1.2
    /// How far outside the mask on screen the new mask's centre may fall and still be the same object.
    static let sameObjectCentreSlack: CGFloat = 0.05
    /// A new mask bigger than this multiple of the one on screen is a better look at the object, and worth
    /// showing even mid-hold.
    static let materiallyLargerRatio: CGFloat = 1.15

    /// Whether the mask on screen should stay, rather than be replaced by the one just segmented.
    ///
    /// The policy is: show the most complete recent silhouette of whatever is at the aim point. A new mask
    /// centred on the same object is not automatically better than the one already up — Vision segments a
    /// complex object differently every time, so half of those are a *fragment* of what is on screen, and
    /// taking them is what makes the preview pulse between the whole object and a piece of it. So a mask
    /// that is smaller or the same is held; a mask that is materially bigger is taken, because more of the
    /// object has been found; a mask centred somewhere else is taken, because the aim has moved.
    ///
    /// Nothing is lost by holding: position and size are followed through the world every frame, so a
    /// silhouette up to `maximumHoldSeconds` old is still drawn in the right place at the right size. This
    /// is deliberately close to what a *selected* object does — one tracked instance, held while the phone
    /// moves — which is the case that is already rock steady on screen.
    static func holdsExistingLayer(
        existing: CGRect?,
        incoming: CGRect?,
        secondsHeld: TimeInterval
    ) -> Bool {
        guard let existing,
              let incoming,
              secondsHeld.isFinite,
              secondsHeld >= 0,
              secondsHeld < maximumHoldSeconds else {
            return false
        }
        let existingArea = existing.width * existing.height
        let incomingArea = incoming.width * incoming.height
        guard existingArea > 0, incomingArea > 0 else { return false }
        // Somewhere else: the aim has moved to another object.
        guard existing
            .insetBy(dx: -sameObjectCentreSlack, dy: -sameObjectCentreSlack)
            .contains(CGPoint(x: incoming.midX, y: incoming.midY)) else {
            return false
        }
        // A better look at the same object.
        return incomingArea <= existingArea * materiallyLargerRatio
    }
}

nonisolated struct ObjectMaskPreviewLayer: @unchecked Sendable {
    let id: UUID
    let image: CGImage
    let trackedObjectID: UUID?
    let referenceAnchorPoint: CGPoint?
    let referenceCameraDistance: Float?
    let referenceViewportBoundingBox: CGRect?
    let trackingBoundingBox: NormalizedRect?
    let trackingOrientation: CGImagePropertyOrientation
}

/// Where a mask's own point in the room is on screen right now, and how far away it is.
///
/// The pair is everything needed to keep a mask picture on its object between segmentations: the point
/// gives the position, and the change in distance gives the apparent size. It comes from ARKit's world
/// tracking, so it holds at any distance and at any apparent size — which is the whole reason it exists.
nonisolated struct ObjectMaskWorldTracking: Equatable, Sendable {
    let normalizedViewportPoint: CGPoint
    let cameraDistance: Float
}

nonisolated struct ObjectMaskPreview: @unchecked Sendable {
    let layers: [ObjectMaskPreviewLayer]
    let timestamp: TimeInterval

    init(layers: [ObjectMaskPreviewLayer], timestamp: TimeInterval) {
        self.layers = layers
        self.timestamp = timestamp
    }
}

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

nonisolated struct ObjectMaskMarker: Identifiable, Equatable, @unchecked Sendable {
    let id: UUID
    let normalizedViewportPoint: CGPoint
    let cameraDistance: Float
    let color: ObjectMaskDisplayColor
    let isMaskVisible: Bool
}

nonisolated enum ObjectMaskLockChangeKind: Sendable {
    case added
    case focused
}

nonisolated struct ObjectMaskLockChange: @unchecked Sendable {
    let id: UUID
    let kind: ObjectMaskLockChangeKind
    let worldTransform: simd_float4x4?
}

nonisolated struct ObjectMaskFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
    let viewportSize: CGSize
    let imageToViewportTransform: CGAffineTransform
    let toggleRequest: ObjectMaskToggleRequest?
    let anchorHints: [ObjectMaskAnchorHint]
    let activeObjectID: UUID?
    let finalizedObjectIDs: Set<UUID>
    let timestamp: TimeInterval
    let trackingGeneration: Int
    let requiresDepthWarmup: Bool
    let depthSnapshot: ObjectMaskDepthSnapshot?
}

nonisolated struct ObjectMaskDepthSnapshot: @unchecked Sendable {
    let depthMap: CVPixelBuffer
    let confidenceMap: CVPixelBuffer?
    let cameraTransform: simd_float4x4
    let cameraIntrinsics: simd_float3x3
    let cameraImageResolution: CGSize
}

nonisolated struct ObjectMaskDepthPointCloud: @unchecked Sendable {
    let id: UUID
    let points: [SIMD3<Float>]
    let timestamp: TimeInterval
    /// Negative evidence from the same frame the points came from: see `ObjectMaskSilhouette`.
    let silhouette: ObjectMaskSilhouette?
}

/// One frame's answer to "which directions is this object *not* in", in the form a world point can be
/// tested against exactly.
///
/// Points are only ever *added* to an object's accumulator, so a frame on which the mask jumped to the
/// wrong segment leaves foreign points behind permanently, and the box — which is the literal extent of
/// the points — grows to contain them. Removing them again is the classic silhouette/space-carving
/// argument (Laurentini's visual hull; Kutulakos & Seitz, *A Theory of Shape by Space Carving*): a point
/// that is inside the camera frustum, is not occluded by anything nearer, and still falls *outside* the
/// object's silhouette cannot belong to the object, and can be carved away.
///
/// Everything needed for that test is bundled here from a single frame — the silhouette itself, the pose
/// it was observed from, the intrinsics to project with, and the depth map to settle occlusion — so the
/// test is an exact projection. It deliberately replaces warping screen coordinates by an approximate
/// scale-and-offset to compensate for a mask that has gone stale, which is only ever an estimate of
/// where a point would have landed.
nonisolated struct ObjectMaskSilhouette: @unchecked Sendable {
    let width: Int
    let height: Int
    /// Mask membership per depth pixel, independent of the admission filters used to build the point
    /// cloud: a retained point has to be testable even where no new point would have been accepted.
    let isObject: [Bool]
    /// Measured depth per depth pixel, 0 where the sensor gave nothing usable. Used only to tell
    /// "outside the silhouette" apart from "hidden behind something nearer".
    let depths: [Float]
    let cameraTransform: simd_float4x4
    let focalX: Float
    let focalY: Float
    let principalX: Float
    let principalY: Float

    /// True only if this pixel *and* its four neighbours are all outside the object.
    ///
    /// That is the silhouette dilated by one pixel, and it is what makes carving safe at a mask's own
    /// boundary. A segmentation edge wobbles by a pixel between frames — especially on a translucent
    /// or specular surface — and a point sitting exactly on the true edge would otherwise be carved by
    /// the wobble alone. Requiring the neighbourhood to agree costs no threshold: one pixel is the
    /// finest distinction the mask is capable of making.
    func isClearlyOutside(column: Int, row: Int) -> Bool {
        for (dx, dy) in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)] {
            let x = column + dx
            let y = row + dy
            guard x >= 0, x < width, y >= 0, y < height else {
                continue
            }
            if isObject[y * width + x] {
                return false
            }
        }
        return true
    }

    /// Where a world point lands on this frame's depth grid, or nil if it is behind the camera or
    /// outside the frame.
    func pixel(for worldPoint: SIMD3<Float>) -> (column: Int, row: Int, depth: Float)? {
        let camera = cameraTransform.inverse * SIMD4<Float>(worldPoint, 1)
        let depth = -camera.z
        guard depth > 0.01, focalX > 0, focalY > 0 else {
            return nil
        }
        let column = Int((camera.x / depth) * focalX + principalX)
        let row = Int((-camera.y / depth) * focalY + principalY)
        guard column >= 0, column < width, row >= 0, row < height else {
            return nil
        }
        return (column, row, depth)
    }
}

nonisolated struct ObjectMaskDisplaySeed: @unchecked Sendable {
    let id: UUID
    let boundingBox: NormalizedRect
    let orientation: CGImagePropertyOrientation
    let preservesState: Bool
    let timestamp: TimeInterval
}

nonisolated struct ObjectMaskDisplayFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
    let imageToViewportTransform: CGAffineTransform
    let timestamp: TimeInterval
    let trackingGeneration: Int
}

nonisolated enum ObjectMaskProcessingStatus: Sendable {
    case succeeded
    case cancelled
    case failed(String)
}

nonisolated struct ObjectMaskProcessingResult: @unchecked Sendable {
    let preview: ObjectMaskPreview?
    let lockedObjectCount: Int
    let visibleObjectCount: Int
    let markers: [ObjectMaskMarker]
    let didToggleLock: Bool
    let lockChange: ObjectMaskLockChange?
    let needsWorldSurface: Bool
    let maskedPointClouds: [ObjectMaskDepthPointCloud]
    let status: ObjectMaskProcessingStatus
    let isSelectionPipelineWarmed: Bool
}

actor ObjectMaskDisplayTracker {
    private struct Tracker {
        var request: TrackObjectRequest
        var lastBoundingBox: NormalizedRect
        var displayBoundingBox: NormalizedRect
        var authoritativeBoundingBox: NormalizedRect
        var orientation: CGImagePropertyOrientation
        var seedTimestamp: TimeInterval
        var lastFrameTimestamp: TimeInterval
        var missedFrames: Int
        var history: [(timestamp: TimeInterval, boundingBox: NormalizedRect)]
    }

    private var trackers: [UUID: Tracker] = [:]
    private var trackingGeneration: Int?

    func boundingBoxes(
        for frame: ObjectMaskDisplayFrame,
        seeds: [ObjectMaskDisplaySeed]
    ) async -> [UUID: CGRect] {
        synchronize(with: seeds, trackingGeneration: frame.trackingGeneration)
        guard !trackers.isEmpty else {
            return [:]
        }

        let eligible = trackers.filter {
            $0.value.orientation == frame.orientation
                && $0.value.missedFrames <= 2
                && frame.timestamp > $0.value.lastFrameTimestamp
        }
        guard !eligible.isEmpty else {
            return currentBoundingBoxes(for: frame)
        }

        let handler = ImageRequestHandler(
            frame.pixelBuffer,
            orientation: frame.orientation
        )
        var idsByRequest: [ObjectIdentifier: UUID] = [:]
        let requests: [any VisionRequest] = eligible.map { id, tracker in
            idsByRequest[ObjectIdentifier(tracker.request)] = id
            return tracker.request
        }
        let submittedRequests = Dictionary(
            uniqueKeysWithValues: eligible.map {
                ($0.key, ObjectIdentifier($0.value.request))
            }
        )
        let submittedGeneration = trackingGeneration
        var observations: [UUID: DetectedObjectObservation] = [:]

        for await result in handler.performAll(requests) {
            guard case .trackObject(let request, let observation) = result,
                  let id = idsByRequest[ObjectIdentifier(request)],
                  let observation else {
                continue
            }
            observations[id] = observation
        }

        guard trackingGeneration == submittedGeneration,
              trackingGeneration == frame.trackingGeneration else {
            return [:]
        }

        for id in eligible.keys {
            guard var tracker = trackers[id],
                  let submittedRequest = submittedRequests[id],
                  ObjectIdentifier(tracker.request) == submittedRequest else {
                continue
            }
            tracker.lastFrameTimestamp = frame.timestamp
            if let observation = observations[id],
               let accepted = acceptedBoundingBox(
                   observation,
                   relativeTo: tracker.lastBoundingBox,
                   authoritative: tracker.authoritativeBoundingBox
               ) {
                tracker.lastBoundingBox = accepted
                tracker.displayBoundingBox = smoothedBoundingBox(
                    from: tracker.displayBoundingBox,
                    to: accepted
                )
                tracker.missedFrames = 0
                tracker.history.append((frame.timestamp, accepted))
                if tracker.history.count > 60 {
                    tracker.history.removeFirst(tracker.history.count - 60)
                }
            } else {
                tracker.missedFrames += 1
            }
            trackers[id] = tracker
        }

        return currentBoundingBoxes(for: frame)
    }

    func reset(trackingGeneration: Int) {
        trackers.removeAll()
        self.trackingGeneration = trackingGeneration
    }

    private func synchronize(
        with seeds: [ObjectMaskDisplaySeed],
        trackingGeneration: Int
    ) {
        if self.trackingGeneration != trackingGeneration {
            trackers.removeAll()
            self.trackingGeneration = trackingGeneration
        }

        let seedIDs = Set(seeds.map(\.id))
        trackers = trackers.filter {
            seedIDs.contains($0.key)
        }

        for seed in seeds {
            guard (trackers[seed.id]?.seedTimestamp ?? -.greatestFiniteMagnitude)
                < seed.timestamp else {
                continue
            }
            if var tracker = trackers[seed.id],
               tracker.orientation == seed.orientation,
               tracker.missedFrames <= 2,
               seed.timestamp <= tracker.lastFrameTimestamp {
                let historicalBoundingBox = tracker.history.min {
                    abs($0.timestamp - seed.timestamp)
                        < abs($1.timestamp - seed.timestamp)
                }.flatMap {
                    abs($0.timestamp - seed.timestamp) <= 0.12
                        ? $0.boundingBox
                        : nil
                }
                let identityReference = historicalBoundingBox
                    ?? tracker.lastBoundingBox
                if seed.preservesState
                    || isConsistentDelayedSeed(
                        seed.boundingBox,
                        relativeTo: identityReference
                    ) {
                    if let historicalBoundingBox {
                        let rebased = rebasedBoundingBox(
                            tracker.lastBoundingBox,
                            predictedAtSeed: historicalBoundingBox,
                            authoritativeAtSeed: seed.boundingBox
                        )
                        tracker.request = TrackObjectRequest(
                            detectedObject: DetectedObjectObservation(
                                boundingBox: rebased
                            )
                        )
                        tracker.lastBoundingBox = rebased
                        tracker.authoritativeBoundingBox = rebased
                        tracker.displayBoundingBox = smoothedBoundingBox(
                            from: tracker.displayBoundingBox,
                            to: rebased
                        )
                        tracker.history = [
                            (tracker.lastFrameTimestamp, rebased)
                        ]
                    }
                    tracker.seedTimestamp = seed.timestamp
                    trackers[seed.id] = tracker
                    continue
                }
            }
            let observation = DetectedObjectObservation(
                boundingBox: seed.boundingBox
            )
            trackers[seed.id] = Tracker(
                request: TrackObjectRequest(detectedObject: observation),
                lastBoundingBox: seed.boundingBox,
                displayBoundingBox: seed.boundingBox,
                authoritativeBoundingBox: seed.boundingBox,
                orientation: seed.orientation,
                seedTimestamp: seed.timestamp,
                lastFrameTimestamp: seed.timestamp,
                missedFrames: 0,
                history: [(seed.timestamp, seed.boundingBox)]
            )
        }
    }

    private func acceptedBoundingBox(
        _ observation: DetectedObjectObservation,
        relativeTo previous: NormalizedRect,
        authoritative: NormalizedRect
    ) -> NormalizedRect? {
        guard observation.confidence >= 0.5 else {
            return nil
        }

        let candidate = observation.boundingBox.cgRect
        let old = previous.cgRect
        guard candidate.width >= 0.005,
              candidate.height >= 0.005,
              candidate.width <= 1,
              candidate.height <= 1,
              candidate.minX.isFinite,
              candidate.minY.isFinite,
              candidate.maxX.isFinite,
              candidate.maxY.isFinite else {
            return nil
        }

        let widthRatio = candidate.width / max(old.width, 0.005)
        let heightRatio = candidate.height / max(old.height, 0.005)
        let authoritativeRect = authoritative.cgRect
        let authoritativeWidthRatio = candidate.width
            / max(authoritativeRect.width, 0.005)
        let authoritativeHeightRatio = candidate.height
            / max(authoritativeRect.height, 0.005)
        let centerDistance = hypot(
            candidate.midX - old.midX,
            candidate.midY - old.midY
        )
        let maximumCenterDistance = max(hypot(old.width, old.height) * 0.65, 0.08)
        guard (0.65 ... 1.55).contains(widthRatio),
              (0.65 ... 1.55).contains(heightRatio),
              (0.72 ... 1.4).contains(authoritativeWidthRatio),
              (0.72 ... 1.4).contains(authoritativeHeightRatio),
              centerDistance <= maximumCenterDistance else {
            return nil
        }
        return observation.boundingBox
    }

    private func isConsistentDelayedSeed(
        _ seed: NormalizedRect,
        relativeTo prediction: NormalizedRect
    ) -> Bool {
        let candidate = seed.cgRect
        let previous = prediction.cgRect
        let widthRatio = candidate.width / max(previous.width, 0.005)
        let heightRatio = candidate.height / max(previous.height, 0.005)
        let centerDistance = hypot(
            candidate.midX - previous.midX,
            candidate.midY - previous.midY
        )
        return (0.55 ... 1.8).contains(widthRatio)
            && (0.55 ... 1.8).contains(heightRatio)
            && centerDistance <= max(
                hypot(previous.width, previous.height) * 0.8,
                0.12
            )
    }

    private func rebasedBoundingBox(
        _ current: NormalizedRect,
        predictedAtSeed: NormalizedRect,
        authoritativeAtSeed: NormalizedRect
    ) -> NormalizedRect {
        let currentRect = current.cgRect
        let predicted = predictedAtSeed.cgRect
        let authoritative = authoritativeAtSeed.cgRect
        let widthScale = min(
            max(authoritative.width / max(predicted.width, 0.005), 0.75),
            1.33
        )
        let heightScale = min(
            max(authoritative.height / max(predicted.height, 0.005), 0.75),
            1.33
        )
        let maximumCorrection = max(
            hypot(predicted.width, predicted.height) * 0.35,
            0.04
        )
        let xCorrection = min(
            max(authoritative.midX - predicted.midX, -maximumCorrection),
            maximumCorrection
        )
        let yCorrection = min(
            max(authoritative.midY - predicted.midY, -maximumCorrection),
            maximumCorrection
        )
        let width = min(max(currentRect.width * widthScale, 0.005), 1)
        let height = min(max(currentRect.height * heightScale, 0.005), 1)
        let centerX = min(
            max(currentRect.midX + xCorrection, width / 2),
            1 - width / 2
        )
        let centerY = min(
            max(currentRect.midY + yCorrection, height / 2),
            1 - height / 2
        )
        return NormalizedRect(
            x: centerX - width / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
    }

    private func smoothedBoundingBox(
        from previous: NormalizedRect,
        to current: NormalizedRect
    ) -> NormalizedRect {
        let old = previous.cgRect
        let new = current.cgRect
        let alpha: CGFloat = 0.85
        return NormalizedRect(
            x: old.minX + (new.minX - old.minX) * alpha,
            y: old.minY + (new.minY - old.minY) * alpha,
            width: old.width + (new.width - old.width) * alpha,
            height: old.height + (new.height - old.height) * alpha
        )
    }

    private func currentBoundingBoxes(
        for frame: ObjectMaskDisplayFrame
    ) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        for (id, tracker) in trackers
        where tracker.orientation == frame.orientation
            && tracker.missedFrames <= 2 {
            if let boundingBox = objectMaskViewportBoundingBox(
                tracker.displayBoundingBox,
                orientation: frame.orientation,
                imageToViewportTransform: frame.imageToViewportTransform
            ) {
                result[id] = boundingBox
            }
        }
        return result
    }
}

nonisolated private func objectMaskViewportBoundingBox(
    _ boundingBox: NormalizedRect,
    orientation: CGImagePropertyOrientation,
    imageToViewportTransform: CGAffineTransform
) -> CGRect? {
    let rect = boundingBox.cgRect
    let uprightPoints = [
        CGPoint(x: rect.minX, y: 1 - rect.minY),
        CGPoint(x: rect.maxX, y: 1 - rect.minY),
        CGPoint(x: rect.minX, y: 1 - rect.maxY),
        CGPoint(x: rect.maxX, y: 1 - rect.maxY)
    ]
    let viewportPoints = uprightPoints.map {
        objectMaskRawTopLeftPoint(
            fromUprightTopLeft: $0,
            orientation: orientation
        ).applying(imageToViewportTransform)
    }
    guard viewportPoints.allSatisfy({
        $0.x.isFinite && $0.y.isFinite
    }),
    let first = viewportPoints.first else {
        return nil
    }
    let minX = viewportPoints.dropFirst().reduce(first.x) { min($0, $1.x) }
    let maxX = viewportPoints.dropFirst().reduce(first.x) { max($0, $1.x) }
    let minY = viewportPoints.dropFirst().reduce(first.y) { min($0, $1.y) }
    let maxY = viewportPoints.dropFirst().reduce(first.y) { max($0, $1.y) }
    guard maxX - minX >= 0.001, maxY - minY >= 0.001 else {
        return nil
    }
    return CGRect(
        x: minX,
        y: minY,
        width: maxX - minX,
        height: maxY - minY
    )
}

nonisolated private func objectMaskRawTopLeftPoint(
    fromUprightTopLeft point: CGPoint,
    orientation: CGImagePropertyOrientation
) -> CGPoint {
    switch orientation {
    case .up: point
    case .upMirrored: CGPoint(x: 1 - point.x, y: point.y)
    case .down: CGPoint(x: 1 - point.x, y: 1 - point.y)
    case .downMirrored: CGPoint(x: point.x, y: 1 - point.y)
    case .left: CGPoint(x: 1 - point.y, y: point.x)
    case .leftMirrored: CGPoint(x: point.y, y: point.x)
    case .right: CGPoint(x: point.y, y: 1 - point.x)
    case .rightMirrored: CGPoint(x: 1 - point.y, y: 1 - point.x)
    }
}

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
        let boundingBox: NormalizedRect
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

    private static let lockedColors = ObjectColourPalette.colours

    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
    private let segmentationRequest = GenerateForegroundInstanceMaskRequest()
    private let livePreviewID = UUID()
    private var trackedObjects: [TrackedObject] = []
    /// Finished masks are intentionally no longer tracked, but their colour remains reserved so the
    /// next object cannot silently reuse it.
    private var reservedColorIndexesByID: [UUID: Int] = [:]
    private var trackingGeneration: Int?
    /// Where the live mask was last drawn, so the next segmentation can recognise the same object
    /// instead of choosing one all over again. Vision's instance numbers cannot be used for this: they
    /// are per-frame.
    private var lastLivePreview: (boundingBox: CGRect, timestamp: TimeInterval)?
    private var hasWarmedAppearanceSignature = false
    private var hasWarmedScaledMask = false
    private var hasWarmedLockCandidate = false

    func makePreview(from frame: ObjectMaskFrame) async -> ObjectMaskProcessingResult {
        if trackingGeneration != frame.trackingGeneration {
            trackedObjects.removeAll()
            lastLivePreview = nil
            trackingGeneration = frame.trackingGeneration
        }
        var colourOwners = frame.finalizedObjectIDs
        if let activeObjectID = frame.activeObjectID {
            colourOwners.insert(activeObjectID)
        }
        if let proposedLockID = frame.toggleRequest?.proposedLockID {
            colourOwners.insert(proposedLockID)
        }
        reservedColorIndexesByID = reservedColorIndexesByID.filter {
            colourOwners.contains($0.key)
        }
        // Only the object being measured is tracked. Every finished one used to be kept here for the
        // rest of the session, and Vision re-tracked all of them on every pass, so each object saved
        // made the next measurement slower — which is exactly how it felt after one or two.
        //
        // They can go because nothing needs them any more: their markers are not drawn, there is no
        // remeasure, and "already measured" is decided from the stored boxes rather than from tracking.
        // What is given up is tapping a finished object in the camera to select it; the saved-objects
        // list does that instead.
        var retainedObjectIDs: Set<UUID> = []
        if let activeObjectID = frame.activeObjectID {
            retainedObjectIDs.insert(activeObjectID)
        }
        trackedObjects.removeAll {
            !retainedObjectIDs.contains($0.id)
        }

        return await makeNativeVisionPreview(from: frame)
    }

    private func makeNativeVisionPreview(
        from frame: ObjectMaskFrame
    ) async -> ObjectMaskProcessingResult {
        let cameraImage = CIImage(cvPixelBuffer: frame.pixelBuffer).oriented(frame.orientation)
        let handler = ImageRequestHandler(cameraImage)
        var addedTrackerID: UUID?

        do {
            guard let observation = try await handler.perform(segmentationRequest) else {
                ageUnmatchedTracker(activeObjectID: frame.activeObjectID)
                return result(
                    preview: nil,
                    frame: frame,
                    status: .failed("Vision returned no foreground observation.")
                )
            }
            guard !Task.isCancelled else {
                return result(preview: nil, frame: frame, status: .cancelled)
            }

            await updateTrackedObjects(
                using: observation,
                handler: handler,
                cameraImage: cameraImage,
                frame: frame
            )
            guard !Task.isCancelled else {
                return result(preview: nil, frame: frame, status: .cancelled)
            }

            let toggleOutcome: ToggleOutcome
            if let toggleRequest = frame.toggleRequest,
               let imagePoint = imagePoint(
                   for: toggleRequest.normalizedViewportPoint,
                   frame: frame
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
            if case .changed(let change) = toggleOutcome,
               case .added = change.kind {
                addedTrackerID = change.id
            }

            let effectiveActiveObjectID: UUID?
            if let activeObjectID = frame.activeObjectID {
                effectiveActiveObjectID = activeObjectID
            } else if case .changed(let change) = toggleOutcome,
                      case .added = change.kind {
                effectiveActiveObjectID = change.id
            } else {
                effectiveActiveObjectID = nil
            }
            let selections = try renderSelections(
                in: observation,
                frame: frame,
                activeObjectID: effectiveActiveObjectID
            )
            if let liveSelection = selections.first(where: { $0.lockID == nil }) {
                if !hasWarmedAppearanceSignature,
                   appearanceSignature(
                       of: cameraImage,
                       inside: liveSelection.boundingBox
                   ) != nil {
                    hasWarmedAppearanceSignature = true
                }
                if frame.requiresDepthWarmup,
                   !hasWarmedScaledMask,
                   frame.depthSnapshot != nil {
                    _ = try observation.generateScaledMask(
                        for: liveSelection.instances,
                        scaledToImageFrom: handler
                    )
                    hasWarmedScaledMask = true
                }
                if !hasWarmedLockCandidate {
                    let boundingBox = liveSelection.boundingBox.cgRect
                    _ = try lockCandidate(
                        near: NormalizedPoint(
                            x: boundingBox.midX,
                            y: boundingBox.midY
                        ),
                        preferredInstances: liveSelection.instances,
                        in: observation,
                        // Warmup only: the result is discarded, and there is no mask held on screen to
                        // continue from during recognition warmup. Explicitly nil so this path keeps
                        // behaving exactly as it did before `continuing:` existed.
                        continuing: nil
                    )
                    hasWarmedLockCandidate = true
                }
            }
            if Task.isCancelled {
                if let addedTrackerID {
                    trackedObjects.removeAll {
                        $0.id == addedTrackerID
                    }
                }
                return result(preview: nil, frame: frame, status: .cancelled)
            }
            var previewLayers: [ObjectMaskPreviewLayer] = []
            var maskedPointClouds: [ObjectMaskDepthPointCloud] = []
            previewLayers.reserveCapacity(selections.count)
            maskedPointClouds.reserveCapacity(selections.count)

            for selection in selections {
                if Task.isCancelled {
                    if let addedTrackerID {
                        trackedObjects.removeAll {
                            $0.id == addedTrackerID
                        }
                    }
                    return result(preview: nil, frame: frame, status: .cancelled)
                }
                // A finished object's overlay is never drawn, and building one costs a full mask
                // plus a full-frame CGImage every cycle. That is the whole reason the scan used to
                // slow down as objects piled up.
                let isDrawn = selection.lockID.map { !frame.finalizedObjectIDs.contains($0) } ?? true
                let needsPointCloud = selection.lockID == effectiveActiveObjectID
                    && addedTrackerID == nil
                    && frame.depthSnapshot != nil
                guard isDrawn || needsPointCloud else { continue }

                let processed = try autoreleasepool {
                    let layer: ObjectMaskPreviewLayer? = !isDrawn ? nil : try {
                    let pixelBuffer = try observation.generateMask(
                        for: selection.instances
                    )
                    let renderedMask = RenderedMask(
                        lockID: selection.lockID,
                        color: selection.color,
                        fillAlpha: selection.fillAlpha,
                        pixelBuffer: pixelBuffer
                    )
                    return makeDisplayImage(from: [renderedMask], frame: frame).map { image in
                        let trackingReference = renderedMask.lockID.flatMap {
                            displayTrackingReference(
                                for: $0,
                                toggleOutcome: toggleOutcome,
                                frame: frame
                            )
                        }
                        return ObjectMaskPreviewLayer(
                            id: renderedMask.lockID ?? livePreviewID,
                            image: image,
                            trackedObjectID: renderedMask.lockID,
                            referenceAnchorPoint: trackingReference?.point,
                            referenceCameraDistance: trackingReference?.cameraDistance,
                            referenceViewportBoundingBox: objectMaskViewportBoundingBox(
                                selection.boundingBox,
                                orientation: frame.orientation,
                                imageToViewportTransform: frame.imageToViewportTransform
                            ),
                            trackingBoundingBox: selection.boundingBox,
                            trackingOrientation: frame.orientation
                        )
                    }
                    }()
                    let cloud: ObjectMaskDepthPointCloud?
                    if needsPointCloud {
                        let sourceAlignedBuffer = try observation
                            .generateScaledMask(
                                for: selection.instances,
                                scaledToImageFrom: handler
                            )
                        let sourceAlignedMask = RenderedMask(
                            lockID: selection.lockID,
                            color: selection.color,
                            fillAlpha: selection.fillAlpha,
                            pixelBuffer: sourceAlignedBuffer
                        )
                        cloud = makeMaskedPointClouds(
                            from: [sourceAlignedMask],
                            frame: frame,
                            activeObjectID: effectiveActiveObjectID
                        ).first
                    } else {
                        cloud = nil
                    }
                    return (layer, cloud)
                }
                if let layer = processed.0 {
                    previewLayers.append(layer)
                }
                if let cloud = processed.1 {
                    maskedPointClouds.append(cloud)
                }
            }
            let preview = previewLayers.isEmpty
                ? nil
                : ObjectMaskPreview(layers: previewLayers, timestamp: frame.timestamp)

            if Task.isCancelled {
                if let addedTrackerID {
                    trackedObjects.removeAll {
                        $0.id == addedTrackerID
                    }
                }
                return result(preview: nil, frame: frame, status: .cancelled)
            }

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
            if let addedTrackerID {
                trackedObjects.removeAll {
                    $0.id == addedTrackerID
                }
            }
            if Task.isCancelled {
                return result(preview: nil, frame: frame, status: .cancelled)
            }
            ageUnmatchedTracker(activeObjectID: frame.activeObjectID)
            return result(
                preview: nil,
                frame: frame,
                status: .failed(error.localizedDescription)
            )
        }
    }

    private func result(
        preview: ObjectMaskPreview?,
        frame: ObjectMaskFrame,
        lockChange: ObjectMaskLockChange? = nil,
        needsWorldSurface: Bool = false,
        maskedPointClouds: [ObjectMaskDepthPointCloud] = [],
        status: ObjectMaskProcessingStatus = .succeeded
    ) -> ObjectMaskProcessingResult {
        var markers = makeMarkers(from: frame.anchorHints)
        if let lockChange,
           case .added = lockChange.kind,
           !markers.contains(where: { $0.id == lockChange.id }),
           let request = frame.toggleRequest,
           let cameraDistance = request.cameraDistance,
           let trackedObject = trackedObjects.first(where: { $0.id == lockChange.id }) {
            markers.append(
                ObjectMaskMarker(
                    id: lockChange.id,
                    normalizedViewportPoint: request.normalizedViewportPoint,
                    cameraDistance: cameraDistance,
                    color: Self.lockedColors[trackedObject.colorIndex],
                    isMaskVisible: trackedObject.currentInstance != nil
                        || trackedObject.missedFrames <= 2
                )
            )
        }
        return ObjectMaskProcessingResult(
            preview: preview,
            lockedObjectCount: trackedObjects.count,
            visibleObjectCount: trackedObjects.count(where: { $0.currentInstance != nil }),
            markers: markers,
            didToggleLock: lockChange != nil,
            lockChange: lockChange,
            needsWorldSurface: needsWorldSurface,
            maskedPointClouds: maskedPointClouds,
            status: status,
            isSelectionPipelineWarmed: hasWarmedAppearanceSignature
                && (!frame.requiresDepthWarmup || hasWarmedScaledMask)
                && hasWarmedLockCandidate
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
                cameraDistance: hintsByID[trackedObject.id]?.cameraDistance
                    ?? trackedObject.referenceCameraDistance,
                color: Self.lockedColors[trackedObject.colorIndex],
                isMaskVisible: trackedObject.currentInstance != nil
                    || trackedObject.missedFrames <= 2
            )
        }
    }

    private func displayTrackingReference(
        for lockID: UUID,
        toggleOutcome: ToggleOutcome,
        frame: ObjectMaskFrame
    ) -> (point: CGPoint, cameraDistance: Float)? {
        if case .changed(let change) = toggleOutcome,
           case .added = change.kind,
           change.id == lockID,
           let toggleRequest = frame.toggleRequest,
           let cameraDistance = toggleRequest.cameraDistance {
            return (toggleRequest.normalizedViewportPoint, cameraDistance)
        }

        guard let hint = frame.anchorHints.first(where: { $0.id == lockID }),
              let point = hint.normalizedViewportPoint else {
            return nil
        }
        return (point, hint.cameraDistance)
    }

    private func updateTrackedObjects(
        using observation: InstanceMaskObservation,
        handler: ImageRequestHandler,
        cameraImage: CIImage,
        frame: ObjectMaskFrame
    ) async {
        guard let activeObjectID = frame.activeObjectID,
              var index = trackedObjects.firstIndex(where: {
                  $0.id == activeObjectID
              }) else {
            return
        }
        var geometryCache: [Int: MaskGeometry] = [:]
        var appearanceCache: [Int: AppearanceSignature] = [:]
        let hintsByID = Dictionary(uniqueKeysWithValues: frame.anchorHints.map { ($0.id, $0) })
        let anchorPoint: NormalizedPoint
        let cameraDistance: Float
        if let hint = hintsByID[activeObjectID] {
            guard let viewportPoint = hint.normalizedViewportPoint,
                  let projectedPoint = imagePoint(for: viewportPoint, frame: frame) else {
                trackedObjects[index].currentInstance = nil
                trackedObjects[index].missedFrames += 1
                return
            }
            anchorPoint = projectedPoint
            cameraDistance = hint.cameraDistance
        } else {
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
        guard !Task.isCancelled else {
            return
        }
        // This actor is reentrant: a cancelled pass stays suspended here while the next one enters
        // and can drop tracked objects, so the index from before the await may no longer be valid,
        // or may now point at a different object. Find it again, or give up.
        guard let currentIndex = trackedObjects.firstIndex(where: { $0.id == activeObjectID }) else {
            return
        }
        index = currentIndex
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
        var candidates: [CandidateMatch] = []
        for (instance, sampleCount) in candidateCounts {
            let geometry: MaskGeometry
            if let cachedGeometry = geometryCache[instance] {
                geometry = cachedGeometry
            } else {
                // Pooled: each of these is a full-resolution buffer, and this runs on every frame of
                // every measurement.
                guard let measuredGeometry = autoreleasepool(invoking: {
                    (try? observation.generateMask(
                        for: IndexSet(integer: instance)
                    )).flatMap { maskGeometry(of: $0) }
                }) else {
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

            candidates.append(
                CandidateMatch(
                    instance: instance,
                    geometry: geometry,
                    appearance: appearance,
                    score: score
                )
            )
        }

        if let bestMatch = candidates.max(by: { $0.score < $1.score }) {
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

    private func mergeCandidateCounts(_ source: [Int: Int], into destination: inout [Int: Int]) {
        for (instance, count) in source {
            destination[instance, default: 0] += count
        }
    }

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

    private func validatedPrediction(
        _ prediction: NormalizedRect?,
        relativeTo previous: NormalizedRect
    ) -> NormalizedRect {
        validTrackingPrediction(prediction, relativeTo: previous) ?? previous
    }

    private func validTrackingPrediction(
        _ prediction: NormalizedRect?,
        relativeTo previous: NormalizedRect
    ) -> NormalizedRect? {
        guard let prediction,
              previous.width > 0,
              previous.height > 0 else {
            return nil
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
            return nil
        }

        return prediction
    }

    private func ageUnmatchedTracker(activeObjectID: UUID?) {
        guard let activeObjectID,
              let index = trackedObjects.firstIndex(where: {
                  $0.id == activeObjectID
              }) else {
            return
        }
        trackedObjects[index].currentInstance = nil
        trackedObjects[index].missedFrames += 1
    }

    private func toggleLock(
        at point: NormalizedPoint,
        request: ObjectMaskToggleRequest,
        in observation: InstanceMaskObservation,
        cameraImage: CIImage,
        frame: ObjectMaskFrame
    ) throws -> ToggleOutcome {
        guard frame.activeObjectID == nil else {
            return .unchanged
        }
        let hintsByID = Dictionary(uniqueKeysWithValues: frame.anchorHints.map { ($0.id, $0) })
        let tappedInstances = instances(near: point, in: observation)
        let tappedBoundingBoxes = tappedInstances.compactMap { instance -> CGRect? in
            autoreleasepool {
                guard let mask = try? observation.generateMask(
                    for: IndexSet(integer: instance)
                ) else {
                    return nil
                }
                return maskGeometry(of: mask)?.boundingBox.cgRect
            }
        }
        if let existing = trackedObjects.first(where: { trackedObject in
            guard frame.finalizedObjectIDs.contains(trackedObject.id),
                  let viewportPoint = hintsByID[trackedObject.id]?.normalizedViewportPoint,
                  let projectedPoint = imagePoint(for: viewportPoint, frame: frame) else {
                return false
            }
            return hypot(projectedPoint.x - point.x, projectedPoint.y - point.y) <= 0.065
                || tappedBoundingBoxes.contains {
                    $0.insetBy(dx: -0.02, dy: -0.02)
                        .contains(projectedPoint.cgPoint)
                }
        }) {
            return .changed(
                ObjectMaskLockChange(id: existing.id, kind: .focused, worldTransform: nil)
            )
        }

        guard reservedColorIndexesByID.count < Self.lockedColors.count,
              let candidate = try lockCandidate(
                  near: point,
                  preferredInstances: tappedInstances,
                  in: observation,
                  // The mask on screen at the moment of the tap, for the same reason the preview uses
                  // it: without it the lock re-decides which instance the crosshair is on from scratch,
                  // so a frame whose segmentation momentarily differs from the one the user is looking
                  // at either locks a different object or finds none and silently does nothing —
                  // pressing the button and having no measurement start. The preview is sticky and the
                  // selection was not, which is precisely how they came to disagree.
                  continuing: livePreviewBoundingBox(at: frame.timestamp)
              ) else {
            return .unchanged
        }

        guard let proposedLockID = request.proposedLockID,
              let worldTransform = request.worldTransform,
              let cameraDistance = request.cameraDistance else {
            return .needsWorldSurface
        }

        let instance = candidate.instance
        let geometry = candidate.geometry
        let colorIndex = colorIndex(for: proposedLockID)

        let initialObservation = DetectedObjectObservation(boundingBox: geometry.boundingBox)
        let tracker = TrackObjectRequest(detectedObject: initialObservation)
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

    private func lockCandidate(
        near point: NormalizedPoint,
        preferredInstances: IndexSet,
        in observation: InstanceMaskObservation,
        continuing previous: CGRect?
    ) throws -> (instance: Int, geometry: MaskGeometry)? {
        try aimedCandidate(
            at: point,
            candidates: ObjectMaskCandidatePolicy.previewInstances(
                nearby: preferredInstances,
                withinAim: instances(inAimWindowAround: point, in: observation),
                excluding: []
            ),
            preferred: preferredInstances,
            in: observation,
            continuing: previous
        )
    }

    /// The one instance the crosshair is on, or nothing. Distance from the aim to the mask's own
    /// bounds dominates the score, so a mask the crosshair sits inside always beats a larger one that
    /// merely has its centroid nearby, and anything the crosshair is not pointing at is rejected
    /// outright rather than won by default.
    ///
    /// Preview and selection both go through here, which is what makes them agree: the object that
    /// lights up is the object that gets measured. `continuing` is the mask that is on screen now, and
    /// it wins any argument it is still eligible for — a mask that keeps being re-chosen from scratch
    /// several times a second does not look like a mask on an object, it looks like a fault.
    private func aimedCandidate(
        at point: NormalizedPoint,
        candidates: [Int],
        preferred: IndexSet,
        in observation: InstanceMaskObservation,
        continuing previous: CGRect? = nil
    ) throws -> (instance: Int, geometry: MaskGeometry)? {
        let aim = point.cgPoint
        let preferredInstances = Set(preferred)
        var best: (instance: Int, geometry: MaskGeometry, score: CGFloat)?
        var geometriesByInstance: [Int: MaskGeometry] = [:]

        for instance in candidates {
            // Vision hands back a full-resolution mask buffer per instance, so without a pool of its
            // own this loop is the peak-memory moment of the frame.
            let geometry: MaskGeometry? = try autoreleasepool {
                let mask = try observation.generateMask(for: IndexSet(integer: instance))
                return maskGeometry(of: mask)
            }
            guard let geometry,
                  geometry.area < 0.90,
                  !(geometry.boundingBox.width > 0.985 && geometry.boundingBox.height > 0.985) else {
                continue
            }
            geometriesByInstance[instance] = geometry

            let rect = geometry.boundingBox.cgRect
            guard ObjectMaskCandidatePolicy.isAimedAt(boundingBox: rect, aim: aim) else {
                continue
            }
            let centroidDistance = hypot(
                geometry.centroid.x - aim.x,
                geometry.centroid.y - aim.y
            )
            let score = (preferredInstances.contains(instance) ? -1 : 0)
                + ObjectMaskCandidatePolicy.distance(from: aim, toBoundsOf: rect) * 5
                + centroidDistance * 0.15
                + geometry.area * 0.02
            if best == nil || score < best!.score {
                best = (instance, geometry, score)
            }
        }

        // Stay on the object already masked while the crosshair is still on it, judged with the looser
        // held threshold so sitting on the boundary does not flick the mask on and off.
        if let previous,
           let heldInstance = ObjectMaskCandidatePolicy.continuation(
               of: previous,
               among: geometriesByInstance.map { ($0.key, $0.value.boundingBox.cgRect) }
           ),
           let heldGeometry = geometriesByInstance[heldInstance],
           ObjectMaskCandidatePolicy.keepsHeldMask(
               heldAimDistance: ObjectMaskCandidatePolicy.distance(
                   from: aim,
                   toBoundsOf: heldGeometry.boundingBox.cgRect
               ),
               challengerAimDistance: best.map {
                   ObjectMaskCandidatePolicy.distance(
                       from: aim,
                       toBoundsOf: $0.geometry.boundingBox.cgRect
                   )
               }
           ) {
            return (heldInstance, heldGeometry)
        }

        return best.map { ($0.instance, $0.geometry) }
    }

    /// Every instance that appears anywhere in the square around the crosshair. Point probes are
    /// cheap — the tracker already samples a 7 × 7 grid per candidate — so this is a far better
    /// fallback than generating a mask for every instance in the frame.
    private func instances(
        inAimWindowAround point: NormalizedPoint,
        in observation: InstanceMaskObservation
    ) -> IndexSet {
        let radius = ObjectMaskCandidatePolicy.aimWindowRadius
        let steps = 8
        var found = IndexSet()
        for row in 0 ... steps {
            for column in 0 ... steps {
                let x = point.x - radius + 2 * radius * CGFloat(column) / CGFloat(steps)
                let y = point.y - radius + 2 * radius * CGFloat(row) / CGFloat(steps)
                guard (0 ... 1).contains(x), (0 ... 1).contains(y) else {
                    continue
                }
                found.formUnion(
                    observation.instanceAtPoint(NormalizedPoint(x: x, y: y))
                )
            }
        }
        // Probes report whatever is under them, including the background; only segmented instances
        // are candidates for a mask.
        return found.intersection(observation.allInstances)
    }

    private func firstAvailableColorIndex() -> Int {
        let usedColors = Set(reservedColorIndexesByID.values)
            .union(trackedObjects.map(\.colorIndex))
        return Self.lockedColors.indices.first(where: { !usedColors.contains($0) }) ?? 0
    }

    private func colorIndex(for id: UUID) -> Int {
        if let existing = reservedColorIndexesByID[id] { return existing }
        let index = firstAvailableColorIndex()
        reservedColorIndexesByID[id] = index
        return index
    }

    private func imagePoint(
        for viewportPoint: CGPoint,
        frame: ObjectMaskFrame
    ) -> NormalizedPoint? {
        guard frame.viewportSize.width > 0,
              frame.viewportSize.height > 0,
              abs(
                  frame.imageToViewportTransform.a * frame.imageToViewportTransform.d
                      - frame.imageToViewportTransform.b * frame.imageToViewportTransform.c
              ) > 0.000001 else {
            return nil
        }
        let rawPoint = viewportPoint.applying(frame.imageToViewportTransform.inverted())
        guard (-0.001 ... 1.001).contains(rawPoint.x),
              (-0.001 ... 1.001).contains(rawPoint.y) else {
            return nil
        }
        let upright = uprightTopLeftPoint(fromRawTopLeft: rawPoint, orientation: frame.orientation)
        return NormalizedPoint(
            x: min(max(upright.x, 0), 1),
            y: min(max(1 - upright.y, 0), 1)
        )
    }

    private func uprightTopLeftPoint(
        fromRawTopLeft point: CGPoint,
        orientation: CGImagePropertyOrientation
    ) -> CGPoint {
        switch orientation {
        case .up: point
        case .upMirrored: CGPoint(x: 1 - point.x, y: point.y)
        case .down: CGPoint(x: 1 - point.x, y: 1 - point.y)
        case .downMirrored: CGPoint(x: point.x, y: 1 - point.y)
        case .left: CGPoint(x: point.y, y: 1 - point.x)
        case .leftMirrored: CGPoint(x: point.y, y: point.x)
        case .right: CGPoint(x: 1 - point.y, y: point.x)
        case .rightMirrored: CGPoint(x: 1 - point.y, y: 1 - point.x)
        }
    }

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
        if let visualDistance,
           trackedObject.missedFrames == 0,
           visualDistance > 0.68 {
            return nil
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

    private func renderSelections(
        in observation: InstanceMaskObservation,
        frame: ObjectMaskFrame,
        activeObjectID: UUID?
    ) throws -> [RenderSelection] {
        var selections: [RenderSelection] = []

        if let activeObjectID,
           let trackedObject = trackedObjects.first(where: {
               $0.id == activeObjectID
           }),
           let instance = trackedObject.currentInstance {
            selections.append(
                RenderSelection(
                    lockID: trackedObject.id,
                    instances: IndexSet(integer: instance),
                    color: Self.lockedColors[trackedObject.colorIndex],
                    fillAlpha: 0.24,
                    boundingBox: trackedObject.lastGeometry.boundingBox
                )
            )
        }

        if activeObjectID == nil,
           trackedObjects.count < Self.lockedColors.count,
           !frame.anchorHints.contains(where: { hint in
               guard let point = hint.normalizedViewportPoint else { return false }
               return hypot(point.x - 0.5, point.y - 0.5) < 0.075
           }),
           let centerPoint = imagePoint(for: CGPoint(x: 0.5, y: 0.5), frame: frame) {
            let finalizedInstances = Set(
                frame.anchorHints
                    .filter { frame.finalizedObjectIDs.contains($0.id) }
                    .compactMap { hint -> IndexSet? in
                        guard let viewportPoint = hint.normalizedViewportPoint,
                              let projectedPoint = imagePoint(
                                  for: viewportPoint,
                                  frame: frame
                              ) else {
                            return nil
                        }
                        return observation.instanceAtPoint(projectedPoint)
                    }
                    .flatMap { $0 }
            )
            let nearbyInstances = instances(near: centerPoint, in: observation)
            // A distant or physically small object can occupy fewer pixels than the centre probes.
            // Vision may still segment it perfectly, so widen the search to the aim window rather
            // than dropping it — but only to the aim window, so the preview cannot walk off to an
            // object at the edge of the frame.
            let candidateInstances = ObjectMaskCandidatePolicy.previewInstances(
                nearby: nearbyInstances,
                withinAim: instances(inAimWindowAround: centerPoint, in: observation),
                excluding: finalizedInstances
            )
            let bestPreview = try aimedCandidate(
                at: centerPoint,
                candidates: candidateInstances,
                preferred: nearbyInstances,
                in: observation,
                continuing: livePreviewBoundingBox(at: frame.timestamp)
            )

            if let bestPreview {
                lastLivePreview = (
                    boundingBox: bestPreview.geometry.boundingBox.cgRect,
                    timestamp: frame.timestamp
                )
                selections.append(
                    RenderSelection(
                        lockID: nil,
                        instances: IndexSet(integer: bestPreview.instance),
                        color: Self.lockedColors[firstAvailableColorIndex()],
                        fillAlpha: 0.16,
                        boundingBox: bestPreview.geometry.boundingBox
                    )
                )
            }
        }

        return selections
    }

    /// The mask on screen, as long as it is recent enough to still be on screen. A stale one would pull
    /// the preview back onto an object the phone is no longer pointed at.
    private func livePreviewBoundingBox(at timestamp: TimeInterval) -> CGRect? {
        guard let lastLivePreview,
              timestamp - lastLivePreview.timestamp
                  <= ObjectMaskCandidatePolicy.continuationTimeout else {
            return nil
        }
        return lastLivePreview.boundingBox
    }

    private func makeDisplayImage(
        from renderedMasks: [RenderedMask],
        frame: ObjectMaskFrame
    ) -> CGImage? {
        let dimensions = viewportDimensions(for: frame.viewportSize, longEdge: 320)
        guard dimensions.width > 0, dimensions.height > 0 else {
            return nil
        }

        var rgba = [UInt8](repeating: 0, count: dimensions.width * dimensions.height * 4)
        var renderedLayer = false
        for renderedMask in renderedMasks {
            guard let mask = viewportMask(
                renderedMask.pixelBuffer,
                width: dimensions.width,
                height: dimensions.height,
                frame: frame
            ) else {
                continue
            }
            renderedLayer = true
            let red = CGFloat(renderedMask.color.red)
            let green = CGFloat(renderedMask.color.green)
            let blue = CGFloat(renderedMask.color.blue)
            for y in 0 ..< dimensions.height {
                for x in 0 ..< dimensions.width where mask[y * dimensions.width + x] != 0 {
                    let edgeRadius = 2
                    let isEdge = x < edgeRadius
                        || x >= dimensions.width - edgeRadius
                        || y < edgeRadius
                        || y >= dimensions.height - edgeRadius
                        || mask[y * dimensions.width + max(x - edgeRadius, 0)] == 0
                        || mask[y * dimensions.width + min(x + edgeRadius, dimensions.width - 1)] == 0
                        || mask[max(y - edgeRadius, 0) * dimensions.width + x] == 0
                        || mask[min(y + edgeRadius, dimensions.height - 1) * dimensions.width + x] == 0
                    let sourceAlpha = isEdge ? CGFloat(0.95) : renderedMask.fillAlpha
                    let offset = (y * dimensions.width + x) * 4
                    let retained = 1 - sourceAlpha
                    rgba[offset] = UInt8(min(
                        red * sourceAlpha * 255 + CGFloat(rgba[offset]) * retained,
                        255
                    ).rounded())
                    rgba[offset + 1] = UInt8(min(
                        green * sourceAlpha * 255 + CGFloat(rgba[offset + 1]) * retained,
                        255
                    ).rounded())
                    rgba[offset + 2] = UInt8(min(
                        blue * sourceAlpha * 255 + CGFloat(rgba[offset + 2]) * retained,
                        255
                    ).rounded())
                    rgba[offset + 3] = UInt8(min(
                        sourceAlpha * 255 + CGFloat(rgba[offset + 3]) * retained,
                        255
                    ).rounded())
                }
            }
        }

        guard renderedLayer,
              let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(
            width: dimensions.width,
            height: dimensions.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: dimensions.width * 4,
            space: rgbColorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private func viewportDimensions(for viewportSize: CGSize, longEdge: Int) -> (width: Int, height: Int) {
        guard viewportSize.width > 0, viewportSize.height > 0, longEdge > 0 else {
            return (0, 0)
        }
        let scale = CGFloat(longEdge) / max(viewportSize.width, viewportSize.height)
        return (
            max(Int((viewportSize.width * scale).rounded()), 1),
            max(Int((viewportSize.height * scale).rounded()), 1)
        )
    }

    private func viewportMask(
        _ pixelBuffer: CVPixelBuffer,
        width targetWidth: Int,
        height targetHeight: Int,
        frame: ObjectMaskFrame
    ) -> [UInt8]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_OneComponent32Float,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              targetWidth > 0,
              targetHeight > 0,
              abs(
                  frame.imageToViewportTransform.a * frame.imageToViewportTransform.d
                      - frame.imageToViewportTransform.b * frame.imageToViewportTransform.c
              ) > 0.000001 else {
            return nil
        }

        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<Float>.stride
        let source = baseAddress.assumingMemoryBound(to: Float.self)
        let viewportToRaw = frame.imageToViewportTransform.inverted()
        var result = [UInt8](repeating: 0, count: targetWidth * targetHeight)

        for y in 0 ..< targetHeight {
            for x in 0 ..< targetWidth {
                let viewportPoint = CGPoint(
                    x: (CGFloat(x) + 0.5) / CGFloat(targetWidth),
                    y: (CGFloat(y) + 0.5) / CGFloat(targetHeight)
                )
                let rawPoint = viewportPoint.applying(viewportToRaw)
                guard (0 ... 1).contains(rawPoint.x), (0 ... 1).contains(rawPoint.y) else {
                    continue
                }
                let uprightPoint = uprightTopLeftPoint(
                    fromRawTopLeft: rawPoint,
                    orientation: frame.orientation
                )
                guard (0 ... 1).contains(uprightPoint.x), (0 ... 1).contains(uprightPoint.y) else {
                    continue
                }
                let sourceX = min(
                    Int(uprightPoint.x * CGFloat(sourceWidth)),
                    sourceWidth - 1
                )
                let sourceY = min(
                    Int(uprightPoint.y * CGFloat(sourceHeight)),
                    sourceHeight - 1
                )
                let row = source.advanced(by: sourceY * sourceStride)
                if row[sourceX] > 0.5 {
                    result[y * targetWidth + x] = 255
                }
            }
        }
        return result
    }

    private func makeMaskedPointClouds(
        from renderedMasks: [RenderedMask],
        frame: ObjectMaskFrame,
        activeObjectID: UUID?
    ) -> [ObjectMaskDepthPointCloud] {
        guard let activeObjectID,
              let depth = frame.depthSnapshot else {
            return []
        }

        let hintsByID = Dictionary(uniqueKeysWithValues: frame.anchorHints.map { ($0.id, $0) })
        return renderedMasks.compactMap { renderedMask in
            guard let lockID = renderedMask.lockID,
                  lockID == activeObjectID,
                  let hint = hintsByID[lockID] else {
                return nil
            }
            let surface = maskedWorldSurface(
                mask: renderedMask.pixelBuffer,
                anchor: hint,
                frame: frame,
                depth: depth
            )
            // The silhouette is returned even when this frame contributed no new points: a frame that
            // adds nothing can still be the frame that proves an earlier point does not belong.
            guard !surface.points.isEmpty || surface.silhouette != nil else {
                return nil
            }
            return ObjectMaskDepthPointCloud(
                id: lockID,
                points: surface.points,
                timestamp: frame.timestamp,
                silhouette: surface.silhouette
            )
        }
    }

    private func maskedWorldSurface(
        mask: CVPixelBuffer,
        anchor: ObjectMaskAnchorHint,
        frame: ObjectMaskFrame,
        depth: ObjectMaskDepthSnapshot
    ) -> (points: [SIMD3<Float>], silhouette: ObjectMaskSilhouette?) {
        let empty: (points: [SIMD3<Float>], silhouette: ObjectMaskSilhouette?) = ([], nil)
        guard CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent32Float else {
            return empty
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
            return empty
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
            return empty
        }
        let maskStride = CVPixelBufferGetBytesPerRow(mask) / MemoryLayout<Float>.stride
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0
        let cameraToWorld = depth.cameraTransform
        let worldToCamera = cameraToWorld.inverse
        let anchorInCamera = worldToCamera * SIMD4<Float>(anchor.worldPosition, 1)
        let anchorDepth = max(-anchorInCamera.z, 0.05)
        let maximumDepthDifference = max(min(anchorDepth * 0.22, 0.32), 0.10)
        let maximumWorldDistanceSquared: Float = 0.42 * 0.42

        var admitted = [Bool](repeating: false, count: depthWidth * depthHeight)
        var worldPoints = [SIMD3<Float>](
            repeating: .zero,
            count: depthWidth * depthHeight
        )
        var sampleDepths = [Float](repeating: 0, count: depthWidth * depthHeight)
        // The silhouette records mask membership and raw depth for *every* pixel, not only the ones a
        // new point may be taken from: an already-retained point has to be testable at a pixel where
        // nothing new would be accepted, which is precisely where a foreign point tends to sit.
        var isObject = [Bool](repeating: false, count: depthWidth * depthHeight)
        var silhouetteDepths = [Float](repeating: 0, count: depthWidth * depthHeight)
        var admittedCount = 0

        for row in 0 ..< depthHeight {
            let depthRow = depthBase
                .advanced(by: row * depthRowBytes)
                .assumingMemoryBound(to: Float32.self)
            let confidenceRow = confidenceBase?
                .advanced(by: row * confidenceRowBytes)
                .assumingMemoryBound(to: UInt8.self)

            for column in 0 ..< depthWidth {
                let measuredDepth = depthRow[column]
                let index = row * depthWidth + column

                let nativeImagePoint = CGPoint(
                    x: (CGFloat(column) + 0.5) / CGFloat(depthWidth),
                    y: (CGFloat(row) + 0.5) / CGFloat(depthHeight)
                )
                let uprightPoint = uprightTopLeftPoint(
                    fromRawTopLeft: nativeImagePoint,
                    orientation: frame.orientation
                )
                let maskX = min(max(Int(uprightPoint.x * CGFloat(maskWidth)), 0), maskWidth - 1)
                let maskY = min(max(Int(uprightPoint.y * CGFloat(maskHeight)), 0), maskHeight - 1)
                let isInsideMask = maskBase[maskY * maskStride + maskX] > 0.5
                isObject[index] = isInsideMask
                if measuredDepth > 0.15,
                   measuredDepth < 3.5,
                   (confidenceRow?[column] ?? 2) >= 1 {
                    silhouetteDepths[index] = measuredDepth
                }

                guard measuredDepth > 0.15,
                      measuredDepth < 3.5,
                      abs(measuredDepth - anchorDepth) <= maximumDepthDifference,
                      (confidenceRow?[column] ?? 2) >= 1,
                      isInsideMask else {
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
                admitted[index] = true
                worldPoints[index] = worldPoint
                sampleDepths[index] = measuredDepth
                admittedCount += 1
            }
        }

        let silhouette = ObjectMaskSilhouette(
            width: depthWidth,
            height: depthHeight,
            isObject: isObject,
            depths: silhouetteDepths,
            cameraTransform: cameraToWorld,
            focalX: fx,
            focalY: fy,
            principalX: cx,
            principalY: cy
        )

        guard admittedCount > 0 else {
            return ([], silhouette)
        }

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(admittedCount)

        let maximumNeighbourDepthDelta = max(anchorDepth * 0.03, 0.02)
        for row in 1 ..< max(depthHeight - 1, 1) {
            for column in 1 ..< max(depthWidth - 1, 1) {
                let index = row * depthWidth + column
                guard admitted[index] else {
                    continue
                }
                let depthHere = sampleDepths[index]
                var admittedNeighbours = 0
                var hasDepthEdge = false
                for neighbour in [index - 1, index + 1, index - depthWidth, index + depthWidth]
                where admitted[neighbour] {
                    admittedNeighbours += 1
                    if abs(depthHere - sampleDepths[neighbour]) > maximumNeighbourDepthDelta {
                        hasDepthEdge = true
                    }
                }
                guard admittedNeighbours >= 3, !hasDepthEdge else {
                    continue
                }
                points.append(worldPoints[index])
            }
        }
        return (points, silhouette)
    }
}
