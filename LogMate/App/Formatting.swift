// Display formatting helpers shared across the app.
// Hours render with one decimal; empty optional fields save as zero.
// (Moved file-`private` to `internal` so callers can live in other files.)
import Foundation

func hours(_ value: Double) -> String { String(format: "%.1f", value) }
func editableHours(_ value: Double) -> String {
    abs(value * 10 - (value * 10).rounded()) < 0.0000001 ? hours(value) : String(value)
}
// Empty controls show their placeholder; optional empty fields save as zero.
func entryHours(_ value: Double) -> String { value == 0 ? "" : editableHours(value) }
func entryCount(_ value: Int) -> String { value == 0 ? "" : String(value) }

func number(_ text: String) -> Double {
    Double(text.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ",", with: ".").split(separator: " ").first.map(String.init) ?? "") ?? 0
}
