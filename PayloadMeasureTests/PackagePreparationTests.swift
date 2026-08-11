import XCTest
import simd
@testable import PayloadMeasure

@MainActor
final class PackagePreparationTests: XCTestCase {
    func testPresetAcceptsEveryOrthogonalAxisPermutation() {
        let preset = PackingBoxPreset(
            id: "test",
            name: "Test",
            outerSizeMillimetres: SIMD3(130, 90, 70),
            usableInnerSizeMillimetres: SIMD3(120, 80, 60)
        )

        XCTAssertTrue(preset.fits(objectSizeMillimetres: SIMD3(119, 79, 59)))
        XCTAssertTrue(preset.fits(objectSizeMillimetres: SIMD3(119, 59, 79)))
        XCTAssertTrue(preset.fits(objectSizeMillimetres: SIMD3(79, 119, 59)))
        XCTAssertTrue(preset.fits(objectSizeMillimetres: SIMD3(59, 119, 79)))
        XCTAssertTrue(preset.fits(objectSizeMillimetres: SIMD3(79, 59, 119)))
        XCTAssertTrue(preset.fits(objectSizeMillimetres: SIMD3(59, 79, 119)))
    }

    func testPresetRejectsObjectThatExceedsEveryOrientation() {
        let preset = PackingBoxPreset(
            id: "test",
            name: "Test",
            outerSizeMillimetres: SIMD3(130, 90, 70),
            usableInnerSizeMillimetres: SIMD3(120, 80, 60)
        )

        XCTAssertFalse(preset.fits(objectSizeMillimetres: SIMD3(121, 80, 60)))
        XCTAssertFalse(preset.fits(objectSizeMillimetres: SIMD3(120, 81, 60)))
        XCTAssertFalse(preset.fits(objectSizeMillimetres: SIMD3(.nan, 20, 10)))
        XCTAssertFalse(preset.fits(objectSizeMillimetres: SIMD3(0, 20, 10)))
    }

    func testCatalogueRecommendsSmallestOuterBoxThatFits() {
        let smaller = PackingBoxPreset(
            id: "small",
            name: "Small",
            outerSizeMillimetres: SIMD3(100, 100, 100),
            usableInnerSizeMillimetres: SIMD3(90, 90, 90)
        )
        let larger = PackingBoxPreset(
            id: "large",
            name: "Large",
            outerSizeMillimetres: SIMD3(200, 200, 200),
            usableInnerSizeMillimetres: SIMD3(190, 190, 190)
        )
        let catalog = [larger, smaller]

        let fitting = PackingBoxCatalog.fittingPresets(
            for: SIMD3(80, 70, 60),
            in: catalog
        )

        XCTAssertEqual(fitting.map(\.id), ["small", "large"])
        XCTAssertEqual(
            PackingBoxCatalog.recommendedPreset(
                for: SIMD3(80, 70, 60),
                in: catalog
            )?.id,
            "small"
        )
    }

    func testPreparedPackageUsesOuterBoxDimensionsAndPackedGrams() {
        let (engine, objectID) = makeLockedObject(
            sizeMetres: SIMD3(0.05, 0.04, 0.03)
        )
        let store = PackingStore()

        XCTAssertNil(engine.name(for: objectID), "A lock must not invent an object name.")
        XCTAssertEqual(store.recommendedBoxPreset(for: objectID, in: engine)?.id, "120x90x40")
        XCTAssertTrue(
            store.selectBoxPreset(id: "120x90x40", for: objectID, in: engine)
        )
        engine.updateName(id: objectID, name: "  Camera  ")
        engine.updatePackedWeight(id: objectID, weightInGrams: 43.7)

        XCTAssertEqual(engine.name(for: objectID), "Camera")
        let grams = try! XCTUnwrap(engine.weightInGrams(for: objectID))
        XCTAssertEqual(grams, 43.7, accuracy: 1e-9)
        XCTAssertTrue(store.packagesMissingPreparation(from: engine).isEmpty)

        let package = try! XCTUnwrap(store.packages(from: engine).first)
        XCTAssertEqual(package.size, SIMD3(120, 90, 40))
        XCTAssertEqual(package.massKilograms, 0.0437, accuracy: 1e-12)

        let baldiItem = try! XCTUnwrap(store.baldiItems(from: engine).first)
        XCTAssertEqual(baldiItem.size, SIMD3(120, 90, 40))
        XCTAssertEqual(baldiItem.mass, 0.0437, accuracy: 1e-12)
    }

    func testCannotAssignABoxThatDoesNotFitMeasuredObject() {
        let (engine, objectID) = makeLockedObject(
            sizeMetres: SIMD3(0.20, 0.10, 0.07)
        )
        let store = PackingStore()

        XCTAssertFalse(
            store.selectBoxPreset(id: "120x90x40", for: objectID, in: engine)
        )
        XCTAssertNil(store.selectedBoxPreset(for: objectID))
        XCTAssertTrue(
            store.packagesMissingPreparation(from: engine).contains(objectID)
        )
        XCTAssertTrue(store.packages(from: engine).isEmpty)
        XCTAssertTrue(store.baldiItems(from: engine).isEmpty)
    }

    func testNoFitObjectRequiresExplicitExclusionAndNeverBecomesRawSolverInput() {
        let (engine, objectID) = makeLockedObject(
            sizeMetres: SIMD3(0.40, 0.30, 0.20)
        )
        let store = PackingStore()

        XCTAssertTrue(store.fittingBoxPresets(for: objectID, in: engine).isEmpty)
        XCTAssertEqual(
            store.preparationState(for: objectID, in: engine),
            .noStockedBoxFits
        )
        XCTAssertTrue(store.packagesMissingPreparation(from: engine).contains(objectID))
        XCTAssertTrue(store.packages(from: engine).isEmpty)
        XCTAssertTrue(store.baldiItems(from: engine).isEmpty)
    }

    func testNoFitExclusionCompletesPreparationWithoutNameWeightOrBox() {
        let (engine, objectID) = makeLockedObject(
            sizeMetres: SIMD3(0.40, 0.30, 0.20)
        )
        let store = PackingStore()

        XCTAssertTrue(
            store.markExcludedBecauseNoStockedBoxFits(objectID, in: engine)
        )

        XCTAssertEqual(
            store.preparationState(for: objectID, in: engine),
            .excludedBecauseNoStockedBoxFits
        )
        XCTAssertNil(engine.name(for: objectID))
        XCTAssertNil(engine.weightInKilograms(for: objectID))
        XCTAssertNil(store.selectedBoxPreset(for: objectID))
        XCTAssertTrue(store.packagesMissingPreparation(from: engine).isEmpty)
        XCTAssertTrue(store.packagesMissingWeight(from: engine).isEmpty)
        XCTAssertEqual(
            store.objectIDsExcludedBecauseNoStockedBoxFits(in: engine),
            [objectID]
        )
        XCTAssertTrue(store.packages(from: engine).isEmpty)
        XCTAssertTrue(store.baldiItems(from: engine).isEmpty)
    }

    func testCannotExcludeObjectWhenAStockedBoxFits() {
        let (engine, objectID) = makeLockedObject(
            sizeMetres: SIMD3(0.05, 0.04, 0.03)
        )
        let store = PackingStore()

        XCTAssertFalse(
            store.markExcludedBecauseNoStockedBoxFits(objectID, in: engine)
        )
        XCTAssertFalse(
            store.isExcludedBecauseNoStockedBoxFits(objectID, in: engine)
        )
        XCTAssertEqual(
            store.preparationState(for: objectID, in: engine),
            .needsFittingBox
        )
    }

    func testMixedPreparedAndNoFitExcludedObjectsSubmitOnlyPreparedPackage() {
        let engine = ObjectCaptureEngine()
        let preparedID = lockObject(
            in: engine,
            sizeMetres: SIMD3(0.05, 0.04, 0.03)
        )
        let excludedID = lockObject(
            in: engine,
            sizeMetres: SIMD3(0.40, 0.30, 0.20)
        )
        let store = PackingStore()

        XCTAssertTrue(store.selectBoxPreset(id: "120x90x40", for: preparedID, in: engine))
        engine.updateName(id: preparedID, name: "Camera")
        engine.updatePackedWeight(id: preparedID, weightInGrams: 250)
        XCTAssertTrue(
            store.markExcludedBecauseNoStockedBoxFits(excludedID, in: engine)
        )

        XCTAssertTrue(store.packagesMissingPreparation(from: engine).isEmpty)
        XCTAssertTrue(store.packagesMissingWeight(from: engine).isEmpty)
        let packages = store.packages(from: engine)
        let baldiItems = store.baldiItems(from: engine)
        XCTAssertEqual(packages.map(\.id), [preparedID])
        XCTAssertEqual(packages.first?.size, SIMD3(120, 90, 40))
        XCTAssertEqual(packages.first?.massKilograms ?? 0, 0.25, accuracy: 1e-12)
        XCTAssertEqual(baldiItems.map(\.id), [preparedID])
        XCTAssertEqual(baldiItems.first?.size, SIMD3(120, 90, 40))
        XCTAssertEqual(baldiItems.first?.mass ?? 0, 0.25, accuracy: 1e-12)
    }

    func testAllNoFitExcludedObjectsCompletePreparationWithNoSolverInput() {
        let engine = ObjectCaptureEngine()
        let firstID = lockObject(
            in: engine,
            sizeMetres: SIMD3(0.40, 0.30, 0.20)
        )
        let secondID = lockObject(
            in: engine,
            sizeMetres: SIMD3(0.50, 0.25, 0.20)
        )
        let store = PackingStore()

        XCTAssertTrue(store.markExcludedBecauseNoStockedBoxFits(firstID, in: engine))
        XCTAssertTrue(store.markExcludedBecauseNoStockedBoxFits(secondID, in: engine))

        XCTAssertTrue(store.packagesMissingPreparation(from: engine).isEmpty)
        XCTAssertTrue(store.packagesMissingWeight(from: engine).isEmpty)
        XCTAssertEqual(
            store.objectIDsExcludedBecauseNoStockedBoxFits(in: engine),
            [firstID, secondID]
        )
        XCTAssertTrue(store.packages(from: engine).isEmpty)
        XCTAssertTrue(store.baldiItems(from: engine).isEmpty)
        XCTAssertTrue(store.baldiProblem(from: engine).items.isEmpty)
    }

    func testRemeasurementInvalidatesNoFitExclusionAndRequiresPreparation() {
        let (engine, objectID) = makeLockedObject(
            sizeMetres: SIMD3(0.40, 0.30, 0.20)
        )
        let store = PackingStore()
        XCTAssertTrue(store.markExcludedBecauseNoStockedBoxFits(objectID, in: engine))

        engine.focusFinalizedObject(id: objectID)
        engine.reactivateFocusedObject()
        XCTAssertEqual(engine.activeObjectID, objectID)
        updateCapture(
            in: engine,
            id: objectID,
            sizeMetres: SIMD3(0.05, 0.04, 0.03)
        )
        XCTAssertEqual(engine.lockActiveObject(), objectID)

        XCTAssertFalse(
            store.isExcludedBecauseNoStockedBoxFits(objectID, in: engine)
        )
        XCTAssertEqual(
            store.preparationState(for: objectID, in: engine),
            .needsFittingBox
        )
        XCTAssertTrue(store.packagesMissingPreparation(from: engine).contains(objectID))
        store.reconcilePreparationState(with: engine)
        XCTAssertTrue(store.selectBoxPreset(id: "120x90x40", for: objectID, in: engine))
        engine.updateName(id: objectID, name: "Remeasured object")
        engine.updatePackedWeight(id: objectID, weightInGrams: 100)
        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .ready)
    }

    func testClearPreparationAndStoreClearRemoveNoFitExclusions() {
        let (engine, objectID) = makeLockedObject(
            sizeMetres: SIMD3(0.40, 0.30, 0.20)
        )
        let store = PackingStore()
        XCTAssertTrue(store.markExcludedBecauseNoStockedBoxFits(objectID, in: engine))

        store.clearNoStockedBoxFitExclusion(for: objectID)
        XCTAssertFalse(store.isExcludedBecauseNoStockedBoxFits(objectID, in: engine))
        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .noStockedBoxFits)

        XCTAssertTrue(store.markExcludedBecauseNoStockedBoxFits(objectID, in: engine))
        store.clearPreparation(for: objectID)
        XCTAssertFalse(store.isExcludedBecauseNoStockedBoxFits(objectID, in: engine))
        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .noStockedBoxFits)

        XCTAssertTrue(store.markExcludedBecauseNoStockedBoxFits(objectID, in: engine))
        store.clear()
        XCTAssertFalse(store.isExcludedBecauseNoStockedBoxFits(objectID, in: engine))
        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .noStockedBoxFits)
    }

    // MARK: - Automatic assignment, own boxes and the catalogue

    func testAssignmentPicksTheSmallestFittingBoxWithoutTheOperatorChoosing() {
        let (engine, objectID) = makeLockedObject(sizeMetres: SIMD3(0.05, 0.04, 0.03))
        let store = PackingStore()

        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .needsFittingBox)
        store.assignBoxesAutomatically(in: engine)

        XCTAssertEqual(store.selectedBoxPreset(for: objectID)?.id, "120x90x40")
        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .needsName)
    }

    func testObjectMarkedAsItsOwnBoxPacksAtItsMeasuredSize() {
        let (engine, objectID) = makeLockedObject(sizeMetres: SIMD3(0.40, 0.30, 0.20))
        let store = PackingStore()

        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .noStockedBoxFits)
        store.setIsItsOwnBox(true, for: objectID, in: engine)
        engine.updateName(id: objectID, name: "Crate")
        engine.updatePackedWeight(id: objectID, weightInGrams: 1200)

        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .readyAsItsOwnBox)
        XCTAssertTrue(store.packagesMissingPreparation(from: engine).isEmpty)
        XCTAssertNil(store.selectedBoxPreset(for: objectID))

        let items = store.baldiItems(from: engine)
        XCTAssertEqual(items.map(\.id), [objectID])
        XCTAssertEqual(items.first?.size, SIMD3(400, 300, 200))
        XCTAssertEqual(items.first?.mass ?? 0, 1.2, accuracy: 1e-12)
    }

    func testClearingOwnBoxRestoresAutomaticAssignment() {
        let (engine, objectID) = makeLockedObject(sizeMetres: SIMD3(0.05, 0.04, 0.03))
        let store = PackingStore()

        store.setIsItsOwnBox(true, for: objectID, in: engine)
        XCTAssertNil(store.selectedBoxPreset(for: objectID))
        XCTAssertEqual(store.packagedSizeMillimetres(for: objectID, in: engine), SIMD3(50, 40, 30))

        store.setIsItsOwnBox(false, for: objectID, in: engine)
        store.assignBoxesAutomatically(in: engine)
        XCTAssertEqual(store.selectedBoxPreset(for: objectID)?.id, "120x90x40")
        XCTAssertEqual(store.packagedSizeMillimetres(for: objectID, in: engine), SIMD3(120, 90, 40))
    }

    func testAddedBoxBecomesAvailableToAssignmentAndRemovingItReleasesTheObject() {
        let (engine, objectID) = makeLockedObject(sizeMetres: SIMD3(0.40, 0.30, 0.20))
        let store = PackingStore()

        store.assignBoxesAutomatically(in: engine)
        XCTAssertNil(store.selectedBoxPreset(for: objectID))

        let added = store.addBox(outerSizeMillimetres: SIMD3(420, 320, 220))
        XCTAssertNotNil(added)
        XCTAssertEqual(added?.name, "420 × 320 × 220 mm")
        XCTAssertEqual(added?.id, "420x320x220")
        XCTAssertEqual(added?.usableInnerSizeMillimetres, SIMD3(418, 318, 218))
        XCTAssertNil(store.addBox(outerSizeMillimetres: SIMD3(420, 320, 220)))

        store.assignBoxesAutomatically(in: engine)
        XCTAssertEqual(store.selectedBoxPreset(for: objectID)?.id, added?.id)

        store.removeBox(id: added!.id)
        XCTAssertNil(store.selectedBoxPreset(for: objectID))
        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .noStockedBoxFits)
    }

    func testEveryBoxCanBeDeletedIncludingTheOnesTheListStartsWith() {
        let store = PackingStore()
        let starting = store.boxPresets
        XCTAssertFalse(starting.isEmpty)

        for preset in starting {
            store.removeBox(id: preset.id)
        }
        XCTAssertTrue(store.boxPresets.isEmpty)

        for preset in starting {
            store.addBox(outerSizeMillimetres: preset.outerSizeMillimetres)
        }
        XCTAssertEqual(store.boxPresets.map(\.id), starting.map(\.id))
    }

    func testBoxIsNamedAfterItsSizeAndNeedsRoomForItsWalls() {
        let box = PackingBoxPreset.sized(outerSizeMillimetres: SIMD3(120, 80, 60))
        XCTAssertEqual(box?.name, "120 × 80 × 60 mm")
        XCTAssertEqual(box?.usableInnerSizeMillimetres, SIMD3(118, 78, 58))

        XCTAssertNil(PackingBoxPreset.sized(outerSizeMillimetres: SIMD3(2, 40, 40)))
        XCTAssertNil(PackingBoxPreset.sized(outerSizeMillimetres: SIMD3(0, 40, 40)))

        XCTAssertEqual(PackingBoxPreset.defaultCatalog.count, 12)
        XCTAssertEqual(PackingBoxPreset.defaultCatalog.first?.name, "130 × 100 × 105 mm")
        XCTAssertEqual(PackingBoxPreset.defaultCatalog.first?.id, "130x100x105")
        XCTAssertEqual(
            Set(PackingBoxPreset.defaultCatalog.map(\.id)).count,
            PackingBoxPreset.defaultCatalog.count
        )
    }

    func testStandardCentreOfMassDomainMatchesThePaper() {
        let store = PackingStore()
        let knapsack = store.knapsack()

        XCTAssertTrue(store.usesStandardDomain)
        XCTAssertEqual(knapsack.size, SIMD3(600, 200, 100))
        XCTAssertEqual(knapsack.domainLower, SIMD3(150, 50, 0))
        XCTAssertEqual(knapsack.domainUpper, SIMD3(450, 150, 50))
    }

    private func makeLockedObject(
        sizeMetres: SIMD3<Float>
    ) -> (ObjectCaptureEngine, UUID) {
        let engine = ObjectCaptureEngine()
        return (engine, lockObject(in: engine, sizeMetres: sizeMetres))
    }

    @discardableResult
    private func lockObject(
        in engine: ObjectCaptureEngine,
        sizeMetres: SIMD3<Float>,
        id: UUID = UUID()
    ) -> UUID {
        engine.requestObjectMaskToggle(at: CGPoint(x: 0.5, y: 0.5))
        engine.beginObjectMeasurement(id: id)
        updateCapture(in: engine, id: id, sizeMetres: sizeMetres)
        XCTAssertEqual(engine.lockActiveObject(), id)
        return id
    }

    private func updateCapture(
        in engine: ObjectCaptureEngine,
        id: UUID,
        sizeMetres: SIMD3<Float>
    ) {
        engine.updateCapture(
            id: id,
            object: CapturedObject(
                dimensions: sizeMetres,
                center: SIMD3(0, sizeMetres.z / 2, 0),
                axes: (
                    width: SIMD3(1, 0, 0),
                    depth: SIMD3(0, 1, 0),
                    height: SIMD3(0, 0, 1)
                ),
                corners: [],
                volume: sizeMetres.x * sizeMetres.y * sizeMetres.z,
                sampleCount: 100
            )
        )
        engine.updateActiveSupportPlaneAvailability(id: id, isAvailable: true)
    }
}
