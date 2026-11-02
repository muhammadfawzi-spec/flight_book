// Approach/procedure support: the logged-procedure model and the aeronav
// XML parser used to build the local procedure set.
import Foundation

struct LoggedProcedure: Codable, Identifiable, Sendable {
    var airport: String
    var name: String
    var id: String { airport + "|" + name }
    var family: String { name.replacingOccurrences(of: #"\s+(?:RWY|RW)\s+\d{1,2}[LRC]?"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
    var runway: String {
        let pattern = #"(?:RWY|RW)\s+(\d{1,2}[LRC]?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let range = Range(match.range(at: 1), in: name) else { return "" }
        return String(name[range])
    }
}

final class ProcedureXML: NSObject, XMLParserDelegate {
    static func read(_ data: Data) -> ProcedureXML? {
        guard let xml = String(data: data, encoding: .utf8),
              let rootRegex = try? NSRegularExpression(pattern: #"<digital_tpp\b[^>]*>"#),
              let root = rootRegex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let rootRange = Range(root.range, in: xml),
              let airportRegex = try? NSRegularExpression(pattern: #"<airport_name\b[^>]*>[\s\S]*?</airport_name>"#) else { return nil }
        let delegate = ProcedureXML()
        let header = XMLParser(data: Data((String(xml[rootRange]) + "</digital_tpp>").utf8))
        header.delegate = delegate
        guard header.parse() else { return nil }
        for match in airportRegex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            guard let range = Range(match.range, in: xml) else { continue }
            let parser = XMLParser(data: Data(xml[range].utf8)); parser.delegate = delegate
            guard parser.parse() else { return nil }
        }
        return delegate.procedures.isEmpty ? nil : delegate
    }
    var procedures: [LoggedProcedure] = []
    var expires: Date?
    var effective: Date?
    private var airport = "", code = "", name = "", element = "", text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = elementName; text = ""
        if elementName == "digital_tpp" {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "'0901Z'  MM/dd/yy"
            effective = attributes["from_edate"].flatMap(formatter.date(from:))
            expires = attributes["to_edate"].flatMap(formatter.date(from:))
        }
        if elementName == "airport_name" { airport = AirportRoute.canonical(attributes["icao_ident"].flatMap { $0.isEmpty ? nil : $0 } ?? attributes["apt_ident"] ?? "") }
        if elementName == "record" { code = ""; name = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "chart_code" { code = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "chart_name" { name = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if elementName == "record", code == "IAP", !airport.isEmpty, !name.isEmpty { procedures.append(LoggedProcedure(airport: airport, name: name)) }
    }
}
