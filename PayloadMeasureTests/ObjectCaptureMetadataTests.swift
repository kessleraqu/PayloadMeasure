import CoreGraphics
import XCTest
import simd
@testable import PayloadMeasure

@MainActor
final class ObjectCaptureMetadataTests: XCTestCase {
    func testEveryStudyObjectReceivesADistinctSharedColour() throws {
        let engine = ObjectCaptureEngine()
        var colours: Set<ObjectMaskDisplayColor> = []
        for index in 0..<ObjectColourPalette.colours.count {
            let id = try XCTUnwrap(
                engine.addManualMeasurement(
                    sizeMillimetres: SIMD3(100 + Double(index), 50, 20)
                )
            )
            colours.insert(try XCTUnwrap(engine.objectColor(for: id)))
        }
        XCTAssertEqual(colours.count, ObjectColourPalette.colours.count)
    }

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
        // Clipped at an edge but not filling the frame: re-centre, don't back away.
        XCTAssertEqual(
            ObjectCaptureEngine.framingGuidance(
                forNormalizedViewportBoundingBox: CGRect(
                    x: 0.01,
                    y: 0.2,
                    width: 0.45,
                    height: 0.45
                )
            ),
            .centre
        )
        // Filling the frame: back away.
        XCTAssertEqual(
            ObjectCaptureEngine.framingGuidance(
                forNormalizedViewportBoundingBox: CGRect(
                    x: 0.05,
                    y: 0.05,
                    width: 0.9,
                    height: 0.9
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

        let engine = ObjectCaptureEngine()
        let id = beginMeasuredObject(in: engine)
        engine.updateObjectMaskDisplayBoundingBoxes([
            id: CGRect(x: 0.4, y: 0.4, width: 0.15, height: 0.15)
        ])
        XCTAssertEqual(engine.framingGuidance, .moveCloser)
        engine.updateObjectMaskDisplayBoundingBoxes([:])
        XCTAssertNil(engine.framingGuidance)
    }

    /// Framing advice only depends on framing, not on how much depth evidence the fit has. Thin
    /// evidence is shown on the progress ring instead.
    func testFramingAdviceIgnoresHowMuchEvidenceTheFitHas() {
        let engine = ObjectCaptureEngine()
        let id = UUID()
        engine.requestObjectMaskToggle(at: CGPoint(x: 0.5, y: 0.5))
        engine.beginObjectMeasurement(id: id)
        engine.updateObjectMaskDisplayBoundingBoxes([
            id: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5)
        ])
        XCTAssertEqual(
            engine.framingGuidance,
            .okay,
            "Well framed is well framed, however thin the evidence is so far."
        )

        engine.updateActiveMeasurementDetail(id: id, stablePointCount: 12)
        XCTAssertEqual(engine.framingGuidance, .okay)

        engine.reportActiveMeasurementNeedsMoreDetail(id: id)
        XCTAssertEqual(
            engine.framingGuidance,
            .okay,
            "Needing more detail is not a reason to send the operator anywhere."
        )

        // Edge clipping is still reported, but only after it repeats for several updates.
        for _ in 0..<6 {
            engine.updateObjectMaskDisplayBoundingBoxes([
                id: CGRect(x: 0.01, y: 0.2, width: 0.4, height: 0.4)
            ])
        }
        XCTAssertEqual(engine.framingGuidance, .centre)
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
    func testCancellingAMeasurementDiscardsItAndDeselectsTheObject() {
        let engine = ObjectCaptureEngine()
        let id = UUID()
        engine.requestObjectMaskToggle(at: CGPoint(x: 0.5, y: 0.5))
        engine.beginObjectMeasurement(id: id)
        engine.updateCapture(
            id: id,
            object: CapturedObject(
                dimensions: SIMD3(0.1, 0.08, 0.06),
                center: .zero,
                axes: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
                corners: [],
                volume: 0.00048,
                sampleCount: 100
            )
        )
        XCTAssertEqual(engine.activeObjectID, id)
        XCTAssertTrue(engine.hasCapture)

        engine.cancelActiveMeasurement()

        XCTAssertNil(engine.activeObjectID)
        XCTAssertFalse(engine.hasCapture)
        XCTAssertTrue(engine.measuredObjectIDs.isEmpty)
        XCTAssertFalse(engine.finalizedObjectIDs.contains(id))
        XCTAssertNil(engine.focusedObjectID)
        XCTAssertFalse(engine.isObjectSelectionPending)
    }

    func testCancellingLeavesAlreadyFinishedObjectsAlone() {
        let engine = ObjectCaptureEngine()
        let keptID = UUID()
        engine.requestObjectMaskToggle(at: CGPoint(x: 0.5, y: 0.5))
        engine.beginObjectMeasurement(id: keptID)
        engine.updateCapture(
            id: keptID,
            object: CapturedObject(
                dimensions: SIMD3(0.1, 0.08, 0.06),
                center: .zero,
                axes: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
                corners: [],
                volume: 0.00048,
                sampleCount: 100
            )
        )
        engine.updateActiveSupportPlaneAvailability(id: keptID, isAvailable: true)
        XCTAssertEqual(engine.lockActiveObject(), keptID)

        let discardedID = UUID()
        engine.requestObjectMaskToggle(at: CGPoint(x: 0.4, y: 0.4))
        engine.beginObjectMeasurement(id: discardedID)
        engine.cancelActiveMeasurement()

        XCTAssertEqual(engine.measuredObjectIDs, [keptID])
        XCTAssertNil(engine.activeObjectID)
        XCTAssertEqual(engine.focusedObjectID, keptID)
    }

    func testEditIsOfferedOnlyWhileTheFinishedObjectIsInView() {
        let engine = ObjectCaptureEngine()
        let id = UUID()
        engine.requestObjectMaskToggle(at: CGPoint(x: 0.5, y: 0.5))
        engine.beginObjectMeasurement(id: id)
        engine.updateCapture(
            id: id,
            object: CapturedObject(
                dimensions: SIMD3(0.1, 0.08, 0.06),
                center: .zero,
                axes: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
                corners: [],
                volume: 0.00048,
                sampleCount: 100
            )
        )
        engine.updateActiveSupportPlaneAvailability(id: id, isAvailable: true)
        XCTAssertEqual(engine.lockActiveObject(), id)

        // Finished and focused, but no marker visible, so nothing is being pointed at.
        XCTAssertTrue(engine.canReactivateFocusedObject)
        XCTAssertFalse(engine.canEditFocusedObject)
    }

}
