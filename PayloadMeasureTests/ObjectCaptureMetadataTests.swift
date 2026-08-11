import CoreGraphics
import XCTest
import simd
@testable import PayloadMeasure

@MainActor
final class ObjectCaptureMetadataTests: XCTestCase {
    func testLockDoesNotInventNameAndCarriesLastViewportBox() {
        let engine = ObjectCaptureEngine()
        let id = beginMeasuredObject(in: engine)
        let viewportBox = CGRect(x: 0.2, y: 0.25, width: 0.5, height: 0.4)
        engine.updateObjectMaskDisplayBoundingBoxes([id: viewportBox])

        XCTAssertEqual(engine.framingGuidance, .okay)
        XCTAssertEqual(engine.lockActiveObject(), id)

        XCTAssertNil(engine.name(for: id))
        XCTAssertEqual(engine.statusText, "Measurement saved. Select the next object.")
        XCTAssertEqual(
            engine.objectWorkflowRequest?.snapshotViewportBoundingBox,
            viewportBox
        )
        XCTAssertNil(engine.framingGuidance)
    }

    func testStagedNameAndGramWeightUpdatesValidateAndPreserveCompatibility() {
        let engine = ObjectCaptureEngine()
        let id = beginMeasuredObject(in: engine)
        XCTAssertEqual(engine.lockActiveObject(), id)

        engine.updateName(id: id, name: "  Medical kit  ")
        engine.updatePackedWeight(id: id, weightInGrams: 1_250)
        XCTAssertEqual(engine.name(for: id), "Medical kit")
        XCTAssertEqual(engine.weightInKilograms(for: id), 1.25)
        XCTAssertEqual(engine.weightInGrams(for: id), 1_250)

        engine.updateName(id: id, name: " \n ")
        engine.updatePackedWeight(id: id, weightInGrams: .nan)
        XCTAssertEqual(engine.name(for: id), "Medical kit")
        XCTAssertEqual(engine.weightInGrams(for: id), 1_250)

        engine.updateDetails(
            id: id,
            name: "Legacy update",
            weightInKilograms: 2.5
        )
        XCTAssertEqual(engine.name(for: id), "Legacy update")
        XCTAssertEqual(engine.weightInGrams(for: id), 2_500)
    }

    func testSnapshotDataIsSessionOnlyAndClearsWithObjectLifecycle() {
        let engine = ObjectCaptureEngine()
        let firstID = beginMeasuredObject(in: engine)
        XCTAssertEqual(engine.lockActiveObject(), firstID)
        let firstJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9])
        engine.setSnapshotJPEGData(firstJPEG, for: firstID)
        XCTAssertEqual(engine.snapshotJPEGData(for: firstID), firstJPEG)

        engine.removeFinalizedObject(id: firstID)
        XCTAssertNil(engine.snapshotJPEGData(for: firstID))

        let secondID = beginMeasuredObject(in: engine)
        XCTAssertEqual(engine.lockActiveObject(), secondID)
        engine.setSnapshotJPEGData(firstJPEG, for: secondID)
        engine.reset()
        XCTAssertNil(engine.snapshotJPEGData(for: secondID))
    }

    func testFramingGuidanceClassifiesAndClearsStaleBoxes() {
        XCTAssertEqual(
            ObjectCaptureEngine.framingGuidance(
                forNormalizedViewportBoundingBox: CGRect(
                    x: 0.4,
                    y: 0.4,
                    width: 0.15,
                    height: 0.15
                )
            ),
            .moveCloser
        )
        XCTAssertEqual(
            ObjectCaptureEngine.framingGuidance(
                forNormalizedViewportBoundingBox: CGRect(
                    x: 0.01,
                    y: 0.2,
                    width: 0.45,
                    height: 0.45
                )
            ),
            .moveFarther
        )
        XCTAssertEqual(
            ObjectCaptureEngine.framingGuidance(
                forNormalizedViewportBoundingBox: CGRect(
                    x: 0.2,
                    y: 0.2,
                    width: 0.5,
                    height: 0.5
                )
            ),
            .okay
        )
        XCTAssertEqual(
            ObjectCaptureEngine.framingGuidance(
                forNormalizedViewportBoundingBox: CGRect(
                    x: 0.2,
                    y: 0.2,
                    width: 0.5,
                    height: 0.5
                ),
                hasSufficientMeasurementDetail: false
            ),
            .moveCloser,
            "A visually large small object still needs a closer view when LiDAR evidence is insufficient."
        )

        let engine = ObjectCaptureEngine()
        let id = beginMeasuredObject(in: engine)
        engine.updateObjectMaskDisplayBoundingBoxes([
            id: CGRect(x: 0.4, y: 0.4, width: 0.15, height: 0.15)
        ])
        XCTAssertEqual(engine.framingGuidance, .moveCloser)
        engine.updateObjectMaskDisplayBoundingBoxes([:])
        XCTAssertNil(engine.framingGuidance)
    }

    func testFramingWaitsForEnoughStableDepthEvidence() {
        let engine = ObjectCaptureEngine()
        let id = UUID()
        engine.requestObjectMaskToggle(at: CGPoint(x: 0.5, y: 0.5))
        engine.beginObjectMeasurement(id: id)
        engine.updateObjectMaskDisplayBoundingBoxes([
            id: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        ])
        XCTAssertEqual(
            engine.framingGuidance,
            .moveCloser,
            "A large screen box is not enough before stable depth evidence arrives."
        )

        engine.updateActiveMeasurementDetail(id: id, stablePointCount: 12)
        XCTAssertEqual(engine.framingGuidance, .moveCloser)

        engine.updateActiveMeasurementDetail(
            id: id,
            stablePointCount: ObjectCapturePipeline.minimumClusterPoints
        )
        XCTAssertEqual(engine.framingGuidance, .okay)

        engine.reportActiveMeasurementNeedsMoreDetail(id: id)
        XCTAssertEqual(engine.framingGuidance, .moveCloser)

        engine.updateActiveMeasurementDetail(
            id: id,
            stablePointCount: ObjectCapturePipeline.minimumClusterPoints + 100
        )
        XCTAssertEqual(engine.framingGuidance, .moveCloser)

        engine.updateCapture(
            id: id,
            object: CapturedObject(
                dimensions: SIMD3<Float>(0.02, 0.03, 0.04),
                center: SIMD3<Float>(0, 0.02, 0),
                axes: (
                    width: SIMD3<Float>(1, 0, 0),
                    depth: SIMD3<Float>(0, 0, 1),
                    height: SIMD3<Float>(0, 1, 0)
                ),
                corners: [],
                volume: 0.000024,
                sampleCount: ObjectCapturePipeline.minimumClusterPoints + 100
            )
        )
        XCTAssertEqual(engine.framingGuidance, .okay)
    }

    private func beginMeasuredObject(in engine: ObjectCaptureEngine) -> UUID {
        let id = UUID()
        engine.requestObjectMaskToggle(
            at: CGPoint(x: 0.5, y: 0.5)
        )
        engine.beginObjectMeasurement(id: id)
        engine.updateCapture(
            id: id,
            object: CapturedObject(
                dimensions: SIMD3<Float>(0.2, 0.3, 0.4),
                center: SIMD3<Float>(0, 0.2, 0),
                axes: (
                    width: SIMD3<Float>(1, 0, 0),
                    depth: SIMD3<Float>(0, 0, 1),
                    height: SIMD3<Float>(0, 1, 0)
                ),
                corners: [],
                volume: 0.024,
                sampleCount: 100
            )
        )
        engine.updateActiveSupportPlaneAvailability(id: id, isAvailable: true)
        return id
    }
}
