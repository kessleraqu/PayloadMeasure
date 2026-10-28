import XCTest
import simd
@testable import PayloadMeasure

// The box is the smallest box containing all given points. Thin parts like prongs or handles
// must not be dropped as outliers here; artifact filtering happens earlier in image space
// (`ObjectMaskProcessor.maskedWorldSurface`).
final class ThinFeatureExtentTests: XCTestCase {
    private let up = SIMD3<Float>(0, 1, 0)

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// A box surface with jitter, like a real scan.
    private func jitteredBoxSurface(
        halfWidth: Float,
        halfDepth: Float,
        base: Float,
        top: Float,
        step: Float = 0.005,
        jitter: Float = 0.0004,
        seed: UInt64
    ) -> [SIMD3<Float>] {
        var generator = SeededGenerator(state: seed)
        func noise() -> Float {
            Float(Double.random(in: -Double(jitter) ... Double(jitter), using: &generator))
        }
        func grid(from lower: Float, to upper: Float) -> [Float] {
            var values: [Float] = []
            var value = lower
            while value <= upper {
                values.append(value)
                value += step
            }
            return values
        }
        let widthSteps = grid(from: -halfWidth, to: halfWidth)
        let depthSteps = grid(from: -halfDepth, to: halfDepth)
        let heightSteps = grid(from: base, to: top)

        var points: [SIMD3<Float>] = []
        for x in widthSteps {
            for z in depthSteps {
                points.append(SIMD3(x + noise(), base + noise(), z + noise()))
                points.append(SIMD3(x + noise(), top + noise(), z + noise()))
            }
        }
        for y in heightSteps {
            for z in depthSteps {
                points.append(SIMD3(halfWidth + noise(), y + noise(), z + noise()))
                points.append(SIMD3(-halfWidth + noise(), y + noise(), z + noise()))
            }
        }
        for y in heightSteps {
            for x in widthSteps {
                points.append(SIMD3(x + noise(), y + noise(), halfDepth + noise()))
                points.append(SIMD3(x + noise(), y + noise(), -halfDepth + noise()))
            }
        }
        return points
    }

    /// A thin part sticking out of one side has to be inside the box.
    func testAThinProtrusionIsInsideTheMeasuredBox() throws {
        let halfWidth: Float = 0.15
        let halfDepth: Float = 0.10
        let base: Float = 0
        let top: Float = 0.12
        var points = jitteredBoxSurface(
            halfWidth: halfWidth, halfDepth: halfDepth, base: base, top: top, seed: 11
        )

        // A sparse prong reaching 30 mm past the +x wall.
        let prongTip = halfWidth + 0.030
        var prong: [SIMD3<Float>] = []
        var x = halfWidth
        while x <= prongTip {
            prong.append(SIMD3(x, top / 2, 0))
            prong.append(SIMD3(x, top / 2 + 0.004, 0.004))
            x += 0.004
        }
        points.append(contentsOf: prong)

        let object = try XCTUnwrap(
            OrientedBoundingBox.make(
                from: points, enclosing: [], up: up, groundHeight: base, minimumEdgeDistance: 0.005
            )
        )
        let measuredWidth = max(object.dimensions.x, object.dimensions.y)
        XCTAssertEqual(
            measuredWidth, halfWidth + prongTip, accuracy: 0.004,
            "The box must reach the tip of the thin protrusion, not stop at the main body."
        )

        // Every drawn point is inside the drawn box.
        for point in points {
            XCTAssertTrue(
                object.contains(point, tolerance: 0.002),
                "A point that is drawn must be inside the box that is drawn."
            )
        }
    }

    func testTheBoxIsExactlyTheExtremesOfTheCloudItWasGiven() throws {
        let halfWidth: Float = 0.15
        let halfDepth: Float = 0.10
        let base: Float = 0
        let top: Float = 0.12
        let points = jitteredBoxSurface(
            halfWidth: halfWidth, halfDepth: halfDepth, base: base, top: top, seed: 12
        )

        let object = try XCTUnwrap(
            OrientedBoundingBox.make(
                from: points, enclosing: [], up: up, groundHeight: base, minimumEdgeDistance: 0.005
            )
        )
        XCTAssertEqual(max(object.dimensions.x, object.dimensions.y), halfWidth * 2, accuracy: 0.003)
        XCTAssertEqual(min(object.dimensions.x, object.dimensions.y), halfDepth * 2, accuracy: 0.003)
        XCTAssertEqual(object.dimensions.z, top - base, accuracy: 0.003)
        for point in points {
            XCTAssertTrue(object.contains(point, tolerance: 0.002))
        }
    }

    /// `ObjectBoundingBox.enclosing` must contain everything it's given and never shrink the box.
    func testEnclosingContainsEveryRetainedPointAndNeverShrinks() {
        let dimensions = SIMD3<Float>(0.30, 0.20, 0.12)
        let previous = CapturedObject(
            dimensions: dimensions,
            center: SIMD3<Float>(0, 0.06, 0),
            axes: (SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
            corners: [],
            volume: dimensions.x * dimensions.y * dimensions.z,
            sampleCount: 0
        )
        let retained: [SIMD3<Float>] = [
            SIMD3(0.18, 0.06, 0),      // 30 mm past the +x wall
            SIMD3(0, 0.06, 0.05),
            SIMD3(-0.05, 0.02, -0.05)
        ]

        let result = ObjectBoundingBox.enclosing(retained, around: previous)
        for point in retained {
            XCTAssertTrue(
                result.contains(point, tolerance: 0.001),
                "Every retained point must be inside the enclosing box."
            )
        }
        XCTAssertGreaterThanOrEqual(result.dimensions.x, dimensions.x)
        XCTAssertGreaterThanOrEqual(result.dimensions.y, dimensions.y)
        XCTAssertGreaterThanOrEqual(result.dimensions.z, dimensions.z)
    }
}
