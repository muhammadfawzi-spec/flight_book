// Date parsing and formatting used when reading and writing log entries
// (US and ISO layouts, two-digit years, fixed locale).
import Foundation

nonisolated enum FlightDates {
    static func formats(for text: String) -> [String] {
        // A two-digit year must be parsed as yy, not AD 26 through yyyy.
        if text.range(of: #"^\s*[0-9]{1,2}/[0-9]{1,2}/[0-9]{2}\s*$"#, options: .regularExpression) != nil { return ["M/d/yy"] }
        if text.range(of: #"^\s*[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}\s*$"#, options: .regularExpression) != nil { return ["M/d/yyyy"] }
        if text.range(of: #"^\s*[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}\s*$"#, options: .regularExpression) != nil { return ["yyyy-MM-dd"] }
        return ["MMM d, yyyy", "MMMM d, yyyy"]
    }
    static func parse(_ text: String) -> Date? {
        for format in formats(for: text) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = format
            f.isLenient = false
            if let date = f.date(from: text) { return date }
        }
        return nil
    }
    static func string(_ date: Date, format: String = "yyyy-MM-dd") -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f.string(from: date)
    }
}
