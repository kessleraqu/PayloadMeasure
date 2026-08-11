import Foundation
import XCTest
@testable import PayloadMeasure

final class PositiveDecimalTextTests: XCTestCase {
    func testRequestedCommaAndDotExamplesParseEqually() {
        assertParses("43.7", as: 43.7)
        assertParses("43,7", as: 43.7)
        assertParses("0.5", as: 0.5)
        assertParses("0,5", as: 0.5)
    }

    func testSurroundingWhitespaceIsIgnored() {
        assertParses("  \n\t43,7\u{00A0} ", as: 43.7)
    }

    func testPositiveIntegersAndLocalizedDigitsParse() {
        assertParses("250", as: 250)
        assertParses("٤٣,٧", as: 43.7)
    }

    func testEmptyNonfiniteNonpositiveAndSignedValuesAreRejected() {
        for text in [
            "", "   ", "0", "0.0", "0,0", "-1", "+1", "NaN", "inf", "∞",
            String(repeating: "9", count: 400),
        ] {
            XCTAssertNil(PositiveDecimalText.parse(text), text)
        }
    }

    func testMalformedGroupingExponentUnitsAndWhitespaceAreRejected() {
        for text in [
            ".5", ",5", "5.", "5,", "1..2", "1,,2", "1.2.3", "1,2,3",
            "1,234.5", "1.234,5", "1 234,5", "1\t234", "1e3", "$43.7", "43.7 g",
        ] {
            XCTAssertNil(PositiveDecimalText.parse(text), text)
        }
    }

    func testFormatterUsesLocaleDecimalWithoutGrouping() {
        XCTAssertEqual(
            PositiveDecimalText.format(1_234.5, locale: Locale(identifier: "en_US")),
            "1234.5"
        )
        XCTAssertEqual(
            PositiveDecimalText.format(1_234.5, locale: Locale(identifier: "de_DE")),
            "1234,5"
        )
    }

    func testFormatterRoundsAndRoundTrips() {
        let locale = Locale(identifier: "de_DE")
        let text = PositiveDecimalText.format(
            43.6786,
            locale: locale,
            maximumFractionDigits: 3
        )
        XCTAssertEqual(text, "43,679")
        assertParses(text ?? "", as: 43.679)
    }

    func testFormatterRejectsInvalidOrRoundedToZeroValues() {
        XCTAssertNil(PositiveDecimalText.format(0))
        XCTAssertNil(PositiveDecimalText.format(-1))
        XCTAssertNil(PositiveDecimalText.format(.nan))
        XCTAssertNil(PositiveDecimalText.format(.infinity))
        XCTAssertNil(PositiveDecimalText.format(1, maximumFractionDigits: -1))
        XCTAssertNil(PositiveDecimalText.format(0.0001, maximumFractionDigits: 3))
        XCTAssertEqual(
            PositiveDecimalText.format(
                0.0001,
                locale: Locale(identifier: "en_US"),
                maximumFractionDigits: 4
            ),
            "0.0001"
        )
    }

    private func assertParses(
        _ text: String,
        as expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual = PositiveDecimalText.parse(text) else {
            XCTFail("Expected to parse ‘\(text)’.", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, accuracy: 1e-9, file: file, line: line)
    }
}
