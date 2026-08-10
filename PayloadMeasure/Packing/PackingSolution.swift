import Foundation
import simd

/// One package as the optimiser placed it, in the module frame.
///
/// Positions are reported exactly as the solver produced them. Nothing is nudged, snapped or
/// re-packed here or anywhere later in the pipeline; the only post-processing is the LP polish
/// step, which is the same model re-solved with the integers pinned.
nonisolated struct PlacedPackage: Sendable, Identifiable {
    var id: UUID
    var name: String
    var itemIndex: Int
    var orientation: OrthogonalOrientation
    /// Footprint on the module floor, recomputed exactly from the chosen integer orientation.
    var footprint: SIMD2<Double>
    var height: Double
    /// Geometric centre. `z` is always `height / 2` — packages rest on the floor.
    var centre: SIMD3<Double>
    /// Centre of mass after orientation, i.e. the geometric centre plus the rotated offset.
    var massCentre: SIMD3<Double>
    var massKilograms: Double
    var wallClearance: Double
    var neighbourClearance: Double

    var minimumX: Double { centre.x - footprint.x / 2 }
    var maximumX: Double { centre.x + footprint.x / 2 }
    var minimumY: Double { centre.y - footprint.y / 2 }
    var maximumY: Double { centre.y + footprint.y / 2 }
    var floorArea: Double { footprint.x * footprint.y }
}

nonisolated struct PackingBoundingBox: Sendable {
    var minimumX: Double
    var maximumX: Double
    var minimumY: Double
    var maximumY: Double

    var length: Double { maximumX - minimumX }
    var width: Double { maximumY - minimumY }
    /// The hierarchical second objective: the perimeter-like extent of the occupied rectangle.
    var compactness: Double { length + width }
}

nonisolated struct PackingSolution: Sendable {
    var module: PayloadModule
    var packages: [PlacedPackage]
    /// Centre of mass of the complete connected system, as reported by the model.
    var centreOfMass: SIMD3<Double>
    var deviation: SIMD3<Double>
    /// `w_x e_x + w_y e_y + w_z e_z`.
    var weightedDeviation: Double
    var boundingBox: PackingBoundingBox?
    var totalPayloadMass: Double
    var totalSystemMass: Double

    var occupiedFloorArea: Double { packages.reduce(0) { $0 + $1.floorArea } }
    var floorUtilisation: Double {
        module.floorArea > 0 ? occupiedFloorArea / module.floorArea : 0
    }
    var tallestPackageHeight: Double { packages.map(\.height).max() ?? 0 }

    /// Independent recomputation of the system centre of mass from the reported placement.
    var recomputedCentreOfMass: SIMD3<Double> {
        var moment = module.fixedMassMoment
        for package in packages {
            moment += package.massKilograms * package.massCentre
        }
        return totalSystemMass > 0 ? moment / totalSystemMass : .zero
    }
}

nonisolated enum PackingSolutionReader {
    /// Turns a raw solver point into an explicit arrangement.
    ///
    /// The one-hot orientation binaries are rounded to the nearest integer and the footprint is
    /// then recomputed exactly from that integer orientation, so a reported size is never a
    /// floating-point approximation of a dimension the operator measured.
    static func read(_ model: PackingModel, values: [Double]) -> PackingSolution {
        let problem = model.problem
        var packages: [PlacedPackage] = []

        for (index, prepared) in problem.items.enumerated() {
            let variables = model.orientationVariables[index]
            var chosen = 0
            if !variables.isEmpty {
                var best = -Double.infinity
                for (position, variable) in variables.enumerated() where values[variable] > best {
                    best = values[variable]
                    chosen = position
                }
            }
            let orientation = prepared.orientations[chosen]
            let centre = SIMD3(
                values[model.xVariables[index]],
                values[model.yVariables[index]],
                orientation.halfExtents.z
            )
            packages.append(
                PlacedPackage(
                    id: prepared.item.id,
                    name: prepared.item.name,
                    itemIndex: index,
                    orientation: orientation.orientation,
                    footprint: SIMD2(orientation.footprintX, orientation.footprintY),
                    height: orientation.height,
                    centre: centre,
                    massCentre: centre + orientation.comOffset,
                    massKilograms: prepared.item.massKilograms,
                    wallClearance: prepared.wallClearance,
                    neighbourClearance: prepared.item.horizontalClearance
                )
            )
        }

        let centreOfMass = SIMD3(
            values[model.centreOfMassVariables[0]],
            values[model.centreOfMassVariables[1]],
            values[model.centreOfMassVariables[2]]
        )
        let deviation = centreOfMass - problem.module.targetCentreOfMass
        var weighted = 0.0
        for axis in 0..<3 {
            weighted += max(0, problem.module.axisWeights[axis]) * abs(deviation[axis])
        }

        var boundingBox: PackingBoundingBox?
        if !packages.isEmpty {
            boundingBox = PackingBoundingBox(
                minimumX: packages.map(\.minimumX).min() ?? 0,
                maximumX: packages.map(\.maximumX).max() ?? 0,
                minimumY: packages.map(\.minimumY).min() ?? 0,
                maximumY: packages.map(\.maximumY).max() ?? 0
            )
        }

        return PackingSolution(
            module: problem.module,
            packages: packages,
            centreOfMass: centreOfMass,
            deviation: deviation,
            weightedDeviation: weighted,
            boundingBox: boundingBox,
            totalPayloadMass: problem.totalItemMass,
            totalSystemMass: problem.totalSystemMass
        )
    }
}

// MARK: - Independent verification

nonisolated struct PackingVerification: Sendable {
    var isValid: Bool
    var tolerance: Double
    var maximumViolation: Double
    var violations: [String]
    var recomputedCentreOfMass: SIMD3<Double>
    var centreOfMassError: Double
}

nonisolated enum PackingGeometryCheck {
    /// Millimetre tolerance for the verification.
    ///
    /// The dense-tableau simplex carries the geometry through big-M rows, so a coordinate near
    /// 400 mm can arrive a few nanometres off. One micrometre absorbs that while staying four
    /// orders of magnitude below anything physically meaningful for a payload module. The actual
    /// residual is always reported rather than hidden.
    static let defaultTolerance = 1e-3

    /// Re-derives every property from the reported placement alone, so this is a genuine check on
    /// the model and the solver rather than a restatement of them.
    static func verify(
        _ solution: PackingSolution,
        against problem: PreparedProblem,
        tolerance: Double = defaultTolerance
    ) -> PackingVerification {
        var violations: [String] = []
        var maximumViolation = 0.0
        let module = solution.module

        func fail(_ message: String, amount: Double) {
            violations.append(message)
            maximumViolation = max(maximumViolation, amount)
        }

        // Every requested package appears exactly once.
        let requested = Set(problem.items.map(\.item.id))
        let reported = Set(solution.packages.map(\.id))
        if requested != reported || solution.packages.count != problem.items.count {
            fail(
                "The arrangement contains \(solution.packages.count) packages but \(problem.items.count) were requested.",
                amount: Double(abs(solution.packages.count - problem.items.count))
            )
        }

        let halfLength = module.lengthMillimetres / 2
        let halfWidth = module.widthMillimetres / 2

        for package in solution.packages {
            let clearance = package.wallClearance
            let checks: [(String, Double)] = [
                ("the rear wall", package.minimumX - clearance + halfLength),
                ("the front wall", halfLength - clearance - package.maximumX),
                ("the left wall", package.minimumY - clearance + halfWidth),
                ("the right wall", halfWidth - clearance - package.maximumY),
            ]
            for (side, slack) in checks where slack < -tolerance {
                fail(
                    String(format: "“%@” crosses %@ by %.4f mm.", package.name, side, -slack),
                    amount: -slack
                )
            }

            let item = problem.items[package.itemIndex].item
            let heightSlack = module.heightMillimetres - package.height - 2 * item.verticalClearance
            if heightSlack < -tolerance {
                fail(
                    String(
                        format: "“%@” stands %.1f mm tall, which exceeds the %.0f mm module height.",
                        package.name,
                        package.height,
                        module.heightMillimetres
                    ),
                    amount: -heightSlack
                )
            }

            // The oriented footprint must be a permutation of the measured dimensions.
            let measured = [item.size.x, item.size.y, item.size.z].map { ($0 * 1e6).rounded() }.sorted()
            let placed = [package.footprint.x, package.footprint.y, package.height]
                .map { ($0 * 1e6).rounded() }
                .sorted()
            if measured != placed {
                fail("“\(package.name)” reports a footprint that is not a rotation of its measured size.", amount: 1)
            }
            if item.keepsUpright, !package.orientation.keepsPackageUpright {
                fail("“\(package.name)” must stay upright but was placed \(package.orientation.restingDescription).", amount: 1)
            }
        }

        // Pairwise separation: two packages must be clear on at least one horizontal axis.
        for first in 0..<solution.packages.count {
            for second in (first + 1)..<solution.packages.count {
                let a = solution.packages[first]
                let b = solution.packages[second]
                let required = max(a.neighbourClearance, b.neighbourClearance)
                let gapX = abs(a.centre.x - b.centre.x) - (a.footprint.x + b.footprint.x) / 2
                let gapY = abs(a.centre.y - b.centre.y) - (a.footprint.y + b.footprint.y) / 2
                let best = max(gapX, gapY)
                if best < required - tolerance {
                    if best < -tolerance {
                        fail(
                            String(format: "“%@” and “%@” overlap by %.4f mm.", a.name, b.name, -best),
                            amount: -best
                        )
                    } else {
                        fail(
                            String(
                                format: "“%@” and “%@” are only %.4f mm apart but require %.1f mm.",
                                a.name, b.name, best, required
                            ),
                            amount: required - best
                        )
                    }
                }
            }
        }

        if let limit = module.maximumPayloadMassKilograms, solution.totalPayloadMass > limit + 1e-6 {
            fail(
                String(
                    format: "The load weighs %.2f kg, above the %.2f kg module limit.",
                    solution.totalPayloadMass,
                    limit
                ),
                amount: solution.totalPayloadMass - limit
            )
        }

        let recomputed = solution.recomputedCentreOfMass
        let error = (0..<3).map { abs(recomputed[$0] - solution.centreOfMass[$0]) }.max() ?? 0
        let centreTolerance = max(tolerance, 1e-3)
        if error > centreTolerance {
            fail(
                String(
                    format: "The reported centre of mass differs from an independent recomputation by %.6f mm.",
                    error
                ),
                amount: error
            )
        }
        if !module.centreOfMassEnvelope.isUnbounded,
           !module.centreOfMassEnvelope.contains(recomputed, tolerance: centreTolerance) {
            fail("The resulting centre of mass lies outside the requested envelope.", amount: 1)
        }

        return PackingVerification(
            isValid: violations.isEmpty,
            tolerance: tolerance,
            maximumViolation: maximumViolation,
            violations: violations,
            recomputedCentreOfMass: recomputed,
            centreOfMassError: error
        )
    }
}
