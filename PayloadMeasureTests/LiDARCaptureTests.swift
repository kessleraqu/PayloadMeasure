import PDFKit
import UIKit
import XCTest
@testable import PayloadMeasure

final class LiDARCaptureTests: XCTestCase {
    func testDepthPaletteClampsAtBothEnds() {
        let range: ClosedRange<Float> = 1 ... 3

        XCTAssertEqual(LiDARDepthPalette.bucket(for: 0, range: range), 0)
        XCTAssertEqual(LiDARDepthPalette.bucket(for: 1, range: range), 0)
        XCTAssertEqual(
            LiDARDepthPalette.bucket(for: 3, range: range),
            UInt8(LiDARDepthPalette.bucketCount - 1)
        )
        XCTAssertEqual(
            LiDARDepthPalette.bucket(for: 8, range: range),
            UInt8(LiDARDepthPalette.bucketCount - 1)
        )
    }

    func testDisplayPaletteUsesFullSpectrumFromFifteenToSixtyCentimetres() {
        let lastBucket = UInt8(LiDARDepthPalette.bucketCount - 1)

        XCTAssertEqual(
            LiDARDepthPalette.bucket(for: 0.10, range: LiDARDepthPalette.displayRange),
            0
        )
        XCTAssertEqual(
            LiDARDepthPalette.bucket(for: 0.15, range: LiDARDepthPalette.displayRange),
            0
        )
        let middleBucket = LiDARDepthPalette.bucket(
            for: 0.375,
            range: LiDARDepthPalette.displayRange
        )
        XCTAssertGreaterThan(middleBucket, 0)
        XCTAssertLessThan(middleBucket, lastBucket)
        XCTAssertEqual(
            LiDARDepthPalette.bucket(for: 0.60, range: LiDARDepthPalette.displayRange),
            lastBucket
        )
        XCTAssertEqual(
            LiDARDepthPalette.bucket(for: 5.00, range: LiDARDepthPalette.displayRange),
            lastBucket
        )
    }

    func testPointScatterIsStableAndBoundedWithinItsSampleCell() {
        let first = LiDARPointScatter.offset(row: 17, column: 23, sampleStride: 2)
        let repeated = LiDARPointScatter.offset(row: 17, column: 23, sampleStride: 2)
        let neighbouring = LiDARPointScatter.offset(row: 17, column: 25, sampleStride: 2)
        let limit = Float(2) * LiDARPointScatter.maximumCellFraction

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, neighbouring)
        XCTAssertLessThanOrEqual(abs(first.x), limit)
        XCTAssertLessThanOrEqual(abs(first.y), limit)
    }

    @MainActor
    func testOneCaptureWritesThreeMatchingSinglePagePDFs() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidar-capture-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 160))
        }
        let images = LiDARSnapshotImages(rgb: image, lidar: image, combined: image)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(
            from: DateComponents(
                year: 2026,
                month: 9,
                day: 2,
                hour: 13,
                minute: 45,
                second: 12,
                nanosecond: 345_000_000
            )
        )!

        let first = try LiDARCaptureStorage.save(images, capturedAt: date, folder: folder)
        let second = try LiDARCaptureStorage.save(images, capturedAt: date, folder: folder)
        let expectedBaseName = LiDARCaptureStorage.baseName(for: date)

        XCTAssertEqual(
            LiDARCaptureStorage.baseName(for: date, calendar: calendar),
            "20260902-134512-345"
        )
        XCTAssertEqual(first.baseName, expectedBaseName)
        XCTAssertEqual(second.baseName, "\(expectedBaseName)-2")
        XCTAssertEqual(first.urls.map(\.lastPathComponent), [
            "\(expectedBaseName)-rgb.pdf",
            "\(expectedBaseName)-lidar.pdf",
            "\(expectedBaseName)-combined.pdf"
        ])
        let pages = try first.urls.map { url -> PDFPage in
            let document = try XCTUnwrap(PDFDocument(url: url))
            XCTAssertEqual(document.pageCount, 1)
            return try XCTUnwrap(document.page(at: 0))
        }
        let boxes = pages.map { $0.bounds(for: .mediaBox) }
        XCTAssertTrue(boxes.dropFirst().allSatisfy { $0 == boxes[0] })
        XCTAssertEqual(boxes[0].width, 540, accuracy: 0.01)
        XCTAssertEqual(boxes[0].height, 720, accuracy: 0.01)
    }
}
