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
        let store = makeStore()

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
        let store = makeStore()

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
        let store = makeStore()

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
        let store = makeStore()

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
        let store = makeStore()

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
        let store = makeStore()

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
        let store = makeStore()

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
        let store = makeStore()
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
        let store = makeStore()
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
        let store = makeStore()

        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .needsFittingBox)
        store.assignBoxesAutomatically(in: engine)

        XCTAssertEqual(store.selectedBoxPreset(for: objectID)?.id, "120x90x40")
        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .needsName)
    }

    /// Each preset is one physical box, so it can only be assigned to one object.
    func testEachBoxPresetIsAssignedToAtMostOneObject() {
        let engine = ObjectCaptureEngine()
        let first = lockObject(in: engine, sizeMetres: SIMD3(0.05, 0.04, 0.03))
        let second = lockObject(in: engine, sizeMetres: SIMD3(0.05, 0.04, 0.03))
        let store = makeStore()

        store.assignBoxesAutomatically(in: engine)

        let firstPreset = try! XCTUnwrap(store.selectedBoxPreset(for: first)?.id)
        let secondPreset = try! XCTUnwrap(store.selectedBoxPreset(for: second)?.id)
        XCTAssertEqual(firstPreset, "120x90x40", "The smallest fitting box, same as the single-object case.")
        XCTAssertNotEqual(
            secondPreset, firstPreset,
            "The second object of the same size must be given a different box, not share the first's."
        )

        // Picking the taken box by hand must fail too.
        XCTAssertFalse(store.selectBoxPreset(id: firstPreset, for: second, in: engine))
        XCTAssertEqual(store.selectedBoxPreset(for: second)?.id, secondPreset, "Left unchanged by the refusal.")

        // Skipping the first object frees its box.
        store.setSkipped(true, for: first, in: engine)
        XCTAssertTrue(store.selectBoxPreset(id: firstPreset, for: second, in: engine))
        XCTAssertEqual(store.selectedBoxPreset(for: second)?.id, firstPreset)
    }

    func testObjectMarkedAsItsOwnBoxPacksAtItsMeasuredSize() {
        let (engine, objectID) = makeLockedObject(sizeMetres: SIMD3(0.40, 0.30, 0.20))
        let store = makeStore()

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
        let store = makeStore()

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
        let store = makeStore()

        store.assignBoxesAutomatically(in: engine)
        XCTAssertNil(store.selectedBoxPreset(for: objectID))

        let added = store.addBox(outerSizeMillimetres: SIMD3(420, 320, 220))
        XCTAssertNotNil(added)
        XCTAssertEqual(added?.name, "420 × 320 × 220 mm")
        XCTAssertEqual(added?.id, "420x320x220")
        XCTAssertEqual(added?.usableInnerSizeMillimetres, SIMD3(420, 320, 220))
        XCTAssertNil(store.addBox(outerSizeMillimetres: SIMD3(420, 320, 220)))

        store.assignBoxesAutomatically(in: engine)
        XCTAssertEqual(store.selectedBoxPreset(for: objectID)?.id, added?.id)

        store.removeBox(id: added!.id)
        XCTAssertNil(store.selectedBoxPreset(for: objectID))
        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .noStockedBoxFits)
    }

    func testEveryBoxCanBeDeletedAndAddedBack() {
        let store = makeStore()
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

    func testBoxIsNamedAfterItsSizeAndTakesThatSizeAsItsCapacity() {
        let box = PackingBoxPreset.sized(outerSizeMillimetres: SIMD3(120, 80, 60))
        XCTAssertEqual(box?.name, "120 × 80 × 60 mm")
        XCTAssertEqual(box?.usableInnerSizeMillimetres, SIMD3(120, 80, 60))

        XCTAssertNil(PackingBoxPreset.sized(outerSizeMillimetres: SIMD3(0, 40, 40)))
    }

    /// A box can hold a different size than its outside suggests. The name shows the interior; the
    /// outer size is what gets packed.
    func testInteriorSizeIsShownAndUsedForTheFitWhileOuterSizeIsPacked() {
        let box = try! XCTUnwrap(
            PackingBoxPreset.sized(
                outerSizeMillimetres: SIMD3(120, 90, 40),
                usableInnerSizeMillimetres: SIMD3(120, 90, 30)
            )
        )

        XCTAssertEqual(box.name, "120 × 90 × 30 mm")
        XCTAssertEqual(box.id, "120x90x40")
        XCTAssertEqual(box.outerSizeMillimetres, SIMD3(120, 90, 40))
        // 35 mm fits a box of that nominal size, but not this one.
        XCTAssertFalse(box.fits(objectSizeMillimetres: SIMD3(100, 80, 35)))
        XCTAssertTrue(box.fits(objectSizeMillimetres: SIMD3(100, 80, 30)))

        // The deep box holds more than its size says.
        let deep = try! XCTUnwrap(
            PackingBoxPreset.sized(
                outerSizeMillimetres: SIMD3(75, 75, 230),
                usableInnerSizeMillimetres: SIMD3(75, 75, 235)
            )
        )
        XCTAssertEqual(deep.name, "75 × 75 × 235 mm")
        XCTAssertTrue(deep.fits(objectSizeMillimetres: SIMD3(70, 70, 234)))
    }

    /// The catalogue follows the payload in progress, including in test runs.
    func testTheBoxCatalogueFollowsThePayloadInProgress() {
        let store = StudyStore()
        store.startRun(
            participantName: "boxes",
            studyDate: Date(),
            flow: .batch,
            firstBox: .big
        )
        store.beginParticipantSession()
        XCTAssertEqual(store.catalogueOwner, .big)
        store.advanceToNextBox()
        XCTAssertEqual(store.catalogueOwner, .small)

        let test = StudyStore()
        test.startTestRun(box: .small, inputMode: .augmentedReality)
        XCTAssertEqual(test.catalogueOwner, .small, "A test run uses the boxes of the payload it picked.")
    }

    func testStandardCentreOfMassDomainMatchesThePaper() {
        let store = makeStore()
        let knapsack = store.knapsack()

        XCTAssertTrue(store.usesStandardDomain)
        XCTAssertEqual(knapsack.size, SIMD3(600, 200, 100))
        XCTAssertEqual(knapsack.domainLower, SIMD3(150, 50, 0))
        XCTAssertEqual(knapsack.domainUpper, SIMD3(450, 150, 50))
    }

    func testEnforcedSizeOverridesTheMeasurementAndNeedsNoBox() {
        let (engine, objectID) = makeLockedObject(sizeMetres: SIMD3(0.40, 0.30, 0.20))
        let store = makeStore()

        // Nothing fits, so it can't be planned without an override.
        store.assignBoxesAutomatically(in: engine)
        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .noStockedBoxFits)

        store.setForcedSize(SIMD3(150, 90, 60), for: objectID, in: engine)
        engine.updateName(id: objectID, name: "Odd shape")
        engine.updatePackedWeight(id: objectID, weightInGrams: 500)

        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .readyAsItsOwnBox)
        XCTAssertTrue(store.packagesMissingPreparation(from: engine).isEmpty)
        XCTAssertEqual(
            store.packagedSizeMillimetres(for: objectID, in: engine),
            SIMD3(150, 90, 60)
        )
        XCTAssertEqual(store.baldiItems(from: engine).first?.size, SIMD3(150, 90, 60))
    }

    func testEnforcedSizeWinsOverAnAssignedBoxAndCanBeCleared() {
        let (engine, objectID) = makeLockedObject(sizeMetres: SIMD3(0.05, 0.04, 0.03))
        let store = makeStore()
        store.assignBoxesAutomatically(in: engine)
        XCTAssertNotNil(store.selectedBoxPreset(for: objectID))

        store.setForcedSize(SIMD3(200, 180, 160), for: objectID, in: engine)
        XCTAssertNil(store.selectedBoxPreset(for: objectID))
        XCTAssertEqual(
            store.packagedSizeMillimetres(for: objectID, in: engine),
            SIMD3(200, 180, 160)
        )

        store.setForcedSize(nil, for: objectID, in: engine)
        store.assignBoxesAutomatically(in: engine)
        XCTAssertNil(store.forcedSize(for: objectID, in: engine))
        XCTAssertNotNil(store.selectedBoxPreset(for: objectID))
    }

    func testDuplicateNamesAreRejected() {
        let engine = ObjectCaptureEngine()
        let first = lockObject(in: engine, sizeMetres: SIMD3(0.05, 0.04, 0.03))
        let second = lockObject(in: engine, sizeMetres: SIMD3(0.06, 0.05, 0.04))
        engine.updateName(id: first, name: "Camera")

        XCTAssertFalse(engine.isNameAvailable("Camera", excluding: second))
        XCTAssertFalse(engine.isNameAvailable("  camera ", excluding: second))
        XCTAssertTrue(engine.isNameAvailable("Camera", excluding: first))
        XCTAssertTrue(engine.isNameAvailable("Lens", excluding: second))
        XCTAssertFalse(engine.isNameAvailable("   ", excluding: second))
    }

    func testOwnBoxObjectThatFitsNothingCanStillBeCompleted() {
        // An object marked as its own box that no catalogue box fits must still be completable.
        let (engine, objectID) = makeLockedObject(sizeMetres: SIMD3(0.40, 0.30, 0.20))
        let store = makeStore()
        store.assignBoxesAutomatically(in: engine)
        XCTAssertTrue(store.fittingBoxPresets(for: objectID, in: engine).isEmpty)

        store.setIsItsOwnBox(true, for: objectID, in: engine)
        engine.updateName(id: objectID, name: "Crate")
        engine.updatePackedWeight(id: objectID, weightInGrams: 900)

        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .readyAsItsOwnBox)
        XCTAssertTrue(
            store.packagesMissingPreparation(from: engine).isEmpty,
            "Nothing may still be outstanding, or the plan screen is unreachable."
        )
        XCTAssertEqual(store.baldiItems(from: engine).count, 1)
    }

    func testEnforcedSizeObjectThatFitsNothingCanStillBeCompleted() {
        let (engine, objectID) = makeLockedObject(sizeMetres: SIMD3(0.50, 0.40, 0.30))
        let store = makeStore()
        store.assignBoxesAutomatically(in: engine)
        XCTAssertTrue(store.fittingBoxPresets(for: objectID, in: engine).isEmpty)

        store.setForcedSize(SIMD3(180, 120, 90), for: objectID, in: engine)
        engine.updateName(id: objectID, name: "Odd shape")
        engine.updatePackedWeight(id: objectID, weightInGrams: 250)

        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .readyAsItsOwnBox)
        XCTAssertTrue(store.packagesMissingPreparation(from: engine).isEmpty)
        XCTAssertEqual(store.baldiItems(from: engine).first?.size, SIMD3(180, 120, 90))
    }

    func testAMixOfBoxedOwnBoxAndExcludedObjectsAllReachCompletion() {
        let engine = ObjectCaptureEngine()
        let boxed = lockObject(in: engine, sizeMetres: SIMD3(0.05, 0.04, 0.03))
        let ownBox = lockObject(in: engine, sizeMetres: SIMD3(0.40, 0.30, 0.20))
        let excluded = lockObject(in: engine, sizeMetres: SIMD3(0.60, 0.50, 0.40))
        let store = makeStore()
        store.assignBoxesAutomatically(in: engine)

        engine.updateName(id: boxed, name: "Camera")
        engine.updatePackedWeight(id: boxed, weightInGrams: 250)

        store.setIsItsOwnBox(true, for: ownBox, in: engine)
        engine.updateName(id: ownBox, name: "Crate")
        engine.updatePackedWeight(id: ownBox, weightInGrams: 900)

        XCTAssertTrue(store.markExcludedBecauseNoStockedBoxFits(excluded, in: engine))

        XCTAssertTrue(store.packagesMissingPreparation(from: engine).isEmpty)
        XCTAssertEqual(Set(store.baldiItems(from: engine).map(\.id)), [boxed, ownBox])
    }

    // MARK: - Skipping an object

    /// A skipped object is complete without a box, name or weight.
    func testSkippingCompletesPreparationWithoutBoxNameOrWeight() {
        let (engine, objectID) = makeLockedObject(sizeMetres: SIMD3(0.05, 0.04, 0.03))
        let store = makeStore()
        store.assignBoxesAutomatically(in: engine)
        XCTAssertNotNil(
            store.selectedBoxPreset(for: objectID),
            "A box fits it, so this is a skip by choice rather than for want of a box."
        )

        store.setSkipped(true, for: objectID, in: engine)

        XCTAssertTrue(store.isSkipped(objectID, in: engine))
        XCTAssertEqual(store.preparationState(for: objectID, in: engine), .skipped)
        XCTAssertTrue(store.packagesMissingPreparation(from: engine).isEmpty)
        XCTAssertTrue(store.packagesMissingWeight(from: engine).isEmpty)
        XCTAssertEqual(store.objectIDsSkipped(in: engine), [objectID])
        // And it isn't passed to either solver.
        XCTAssertTrue(store.packages(from: engine).isEmpty)
        XCTAssertTrue(store.baldiItems(from: engine).isEmpty)
        // Its box is cleared too.
        XCTAssertNil(store.selectedBoxPreset(for: objectID))
    }

    func testPuttingASkippedObjectBackRestoresItsAssignment() {
        let (engine, objectID) = makeLockedObject(sizeMetres: SIMD3(0.05, 0.04, 0.03))
        let store = makeStore()
        store.setSkipped(true, for: objectID, in: engine)
        store.setSkipped(false, for: objectID, in: engine)
        store.assignBoxesAutomatically(in: engine)

        XCTAssertFalse(store.isSkipped(objectID, in: engine))
        XCTAssertNotNil(store.selectedBoxPreset(for: objectID))
        XCTAssertTrue(store.objectIDsSkipped(in: engine).isEmpty)
        // Unskipped again, so it needs a name and weight.
        XCTAssertTrue(store.packagesMissingPreparation(from: engine).contains(objectID))
    }

    /// A skipped object doesn't block the rest of the payload.
    func testASkippedObjectDoesNotBlockTheOthers() {
        let engine = ObjectCaptureEngine()
        let keptID = lockObject(in: engine, sizeMetres: SIMD3(0.05, 0.04, 0.03))
        let skippedID = lockObject(in: engine, sizeMetres: SIMD3(0.06, 0.05, 0.04))
        let store = makeStore()
        store.assignBoxesAutomatically(in: engine)
        engine.updateName(id: keptID, name: "Kept")
        engine.updatePackedWeight(id: keptID, weightInGrams: 120)

        store.setSkipped(true, for: skippedID, in: engine)

        XCTAssertTrue(store.packagesMissingPreparation(from: engine).isEmpty)
        XCTAssertEqual(store.packages(from: engine).map(\.id), [keptID])
        XCTAssertEqual(store.baldiItems(from: engine).map(\.id), [keptID])
    }

    /// Removing an object also clears its skipped flag.
    func testASkipIsForgottenWithTheObject() {
        let (engine, objectID) = makeLockedObject(sizeMetres: SIMD3(0.05, 0.04, 0.03))
        let store = makeStore()
        store.setSkipped(true, for: objectID, in: engine)
        engine.removeFinalizedObject(id: objectID)
        store.reconcilePreparationState(with: engine)

        XCTAssertTrue(store.skippedObjectIDs.isEmpty)
    }

    /// A store with a fixed box list, so results don't depend on what the app or an earlier test
    /// saved.
    private func makeStore() -> PackingStore {
        let store = PackingStore()
        for preset in store.boxPresets {
            store.removeBox(id: preset.id)
        }
        store.boxes.add(outerSizeMillimetres: SIMD3(100, 75, 90))
        store.boxes.add(
            outerSizeMillimetres: SIMD3(120, 90, 40),
            usableInnerSizeMillimetres: SIMD3(120, 90, 30)
        )
        store.boxes.add(outerSizeMillimetres: SIMD3(130, 100, 105))
        return store
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
