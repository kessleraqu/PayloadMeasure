import Foundation

// Parsing and formatting for the positive decimal fields the operator types into, accepting either
// a comma or a dot regardless of locale.
//
// In:  text.
// Out: a positive Double, or nil when the text is not one.

nonisolated enum PositiveDecimalText {
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var normalized = ""
        var hasDecimalMark = false
        var hasDigitAfterDecimalMark = false

        for character in trimmed {
            if let digit = decimalDigit(character) {
                normalized.append(String(digit))
                if hasDecimalMark {
                    hasDigitAfterDecimalMark = true
                }
            } else if character == "." || character == "," {
                guard !hasDecimalMark, !normalized.isEmpty else { return nil }
                hasDecimalMark = true
                normalized.append(".")
            } else {
                return nil
            }
        }

        guard !hasDecimalMark || hasDigitAfterDecimalMark,
              let value = Double(normalized),
              value.isFinite,
              value > 0 else {
            return nil
        }
        return value
    }

    static func format(
        _ value: Double,
        locale: Locale = .current,
        maximumFractionDigits: Int = 3
    ) -> String? {
        guard value.isFinite, value > 0, maximumFractionDigits >= 0 else {
            return nil
        }

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.roundingMode = .halfUp

        guard let text = formatter.string(from: NSNumber(value: value)),
              parse(text) != nil else {
            return nil
        }
        return text
    }

    private static func decimalDigit(_ character: Character) -> Int? {
        guard character.unicodeScalars.allSatisfy({
            CharacterSet.decimalDigits.contains($0)
        }) else {
            return nil
        }
        return character.wholeNumberValue
    }
}
