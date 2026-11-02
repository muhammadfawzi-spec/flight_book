// Logbook export: the shared ShareFile wrapper, the PDF print layout,
// the CSV text exporter, and the LogbookExport entry point used by the
// More screen and stories.
import Foundation
import UIKit

struct ShareFile: Identifiable { let url: URL; var id: String { url.absoluteString } }

// CSV parsing is independent of layout: quoted commas, multiline cells, CRLF,
// tabs, semicolons and HH:MM durations are handled before field mapping.

struct LogbookPrintColumn {
    var title: String
    var width: CGFloat
}

@MainActor enum LogbookPDF {
    static let pageSize = CGSize(width: 792, height: 612)
    static let columns: [LogbookPrintColumn] = [
        .init(title: "Date\nEntry", width: 40), .init(title: "Make / model", width: 78),
        .init(title: "Reg.", width: 48), .init(title: "Route", width: 82),
        .init(title: "Total", width: 27), .init(title: "PIC", width: 27), .init(title: "SIC", width: 27),
        .init(title: "XC", width: 27), .init(title: "Night", width: 27),
        .init(title: "Act.\ninstr.", width: 27), .init(title: "Sim.\ninstr.", width: 27),
        .init(title: "Dual\nrecv.", width: 27), .init(title: "Inst.\ntime", width: 27),
        .init(title: "Day\nldg.", width: 22), .init(title: "Night\nldg.", width: 22),
        .init(title: "Appr.", width: 24), .init(title: "Remarks / instructor signature", width: 185)
    ]
    static func timeValues(_ f: Flight) -> [Double] { [f.total, f.pic, f.sicTime, f.crossCountry, f.night, f.imc, f.simulatedInstrument, f.dual, f.instructor] }
    static func countValues(_ f: Flight) -> [Int] { [f.dayLandings, f.nightLandings, f.approachCount] }
    static func lines(_ text: String, width: CGFloat, font: UIFont) -> [String] {
        var output: [String] = []
        func fits(_ line: String) -> Bool { (line as NSString).size(withAttributes: [.font: font]).width <= width }
        for paragraph in text.components(separatedBy: "\n") {
            var current = ""
            let words = paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if words.isEmpty { output.append(""); continue }
            for word in words {
                let candidate = current.isEmpty ? word : current + " " + word
                if fits(candidate) { current = candidate; continue }
                if !current.isEmpty { output.append(current); current = "" }
                for character in word {
                    let next = current + String(character)
                    if !current.isEmpty && !fits(next) { output.append(current); current = String(character) }
                    else { current = next }
                }
            }
            output.append(current)
        }
        return output.isEmpty ? [""] : output
    }
    static func text(_ value: String, x: CGFloat, y: CGFloat, width: CGFloat, font: UIFont = .systemFont(ofSize: 9),
                     maxLines: Int? = nil, centered: Bool = false) {
        let style = NSMutableParagraphStyle(); style.alignment = centered ? .center : .left
        let wrapped = lines(value, width: width, font: font)
        let used = Array(wrapped.prefix(maxLines ?? wrapped.count))
        for (offset, line) in used.enumerated() {
            (line as NSString).draw(in: CGRect(x: x, y: y + CGFloat(offset) * (font.lineHeight + 1), width: width, height: font.lineHeight + 2),
                withAttributes: [.font: font, .foregroundColor: UIColor.black, .paragraphStyle: style])
        }
    }
    static func rule(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, fill: Bool = false) {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        if fill { UIColor(white: 0.94, alpha: 1).setFill(); UIBezierPath(rect: rect).fill() }
        UIColor(white: 0.65, alpha: 1).setStroke()
        let path = UIBezierPath(rect: rect); path.lineWidth = 0.4; path.stroke()
    }
    static func entryDetail(_ f: Flight, entry: Int) -> String {
        var parts = ["ENTRY \(String(format: "%04d", entry))", "\(f.date) | \(f.registration) | \(f.aircraftModel) | \(f.category)",
            "Route: \(f.route)", "Total \(hours(f.total)) | PIC \(hours(f.pic)) | SIC \(hours(f.sicTime)) | XC \(hours(f.crossCountry)) | Night \(hours(f.night)) | Actual instrument \(hours(f.imc)) | Simulated instrument \(hours(f.simulatedInstrument)) | Dual \(hours(f.dual)) | Instructor \(hours(f.instructor)) hours",
            "Day / night landings \(f.dayLandings) / \(f.nightLandings) | Approaches \(f.approachCount) | Holds \(f.holds) | Instrument tracking \(f.tracking ? "Yes" : "No")",
            "Equipment: Complex \(f.complex ? "Yes" : "No") | High performance \(f.highPerformance ? "Yes" : "No") | TAA \(f.taa ? "Yes" : "No") | Turbine \(f.facts.has("turbine") ? "Yes" : "No")"]
        if !f.notes.isEmpty { parts.append("Pilot remarks:\n" + f.notes) }
        if !f.approaches.isEmpty { parts.append("Approaches:\n" + f.approaches) }
        if f.facts.has("flightReview") {
            parts.append("Flight review | Ground training \(hours(f.facts.amounts["reviewGround", default: 0])) h | Endorsement \(f.facts.has("reviewEndorsed") ? "recorded" : "not recorded") | Ground exception \(f.facts.has("reviewGroundException") ? "affirmed" : "not selected")")
        }
        if f.facts.has("checkride") { parts.append("Checkride | Passed qualifying practical test: \(f.facts.has("checkridePassed") ? "affirmed" : "not affirmed")") }
        if let signature = f.signature {
            let cfi = signature.instructor
            parts.append("Instructor: \(cfi.name) | Email: \(cfi.email) | Certificate #: \(cfi.certificate)")
            parts.append(cfi.noExpiration ? "Certificate: no expiration" : "Certificate expiration: " + (cfi.expiration.map { FlightDates.string($0) } ?? "Not recorded"))
            if let date = cfi.recentExperienceEnd { parts.append("Instructor recent-experience end date: " + FlightDates.string(date)) }
            parts.append("Instructor comments / training given:\n" + signature.comments)
            parts.append("Signed: " + FlightDates.string(signature.signedAt, format: "yyyy-MM-dd HH:mm:ss Z") + " | Agreement accepted: " + FlightDates.string(signature.agreedAt, format: "yyyy-MM-dd HH:mm:ss Z"))
            parts.append(signature.matches(f) ? "Signature attached to this recorded flight. Instructor identity and authority were affirmed, not verified by the app." : "SIGNATURE DOES NOT MATCH THIS ENTRY. It belongs to a previous version and is not an endorsement of this edited flight.")
            parts.append("Record reference: " + signature.flightDigest)
        }
        let receipts = f.confirmations.filter { $0.value.flightDigest == f.recordDigest && $0.value.accepted }.sorted { $0.key < $1.key }
        if !receipts.isEmpty {
            parts.append("Milestone confirmations (pilot affirmations, not instructor endorsements):")
            for (key, receipt) in receipts {
                parts.append(key + " | Credit " + hours(receipt.creditedValue) + " | Confirmed " + FlightDates.string(receipt.confirmedAt, format: "yyyy-MM-dd HH:mm Z") + "\n" + receipt.statement)
            }
        }
        return parts.joined(separator: "\n\n")
    }
    static func render(_ flights: [Flight], pilotName: String) -> Data {
        let entries = flights.enumerated().sorted {
            let a = $0.element.flightDate ?? .distantPast; let b = $1.element.flightDate ?? .distantPast
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        let rowCount = 8
        let tablePages = max(1, (entries.count + rowCount - 1) / rowCount)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        return renderer.pdfData { context in
            var pageNumber = 0
            var carriedTimes = Array(repeating: 0.0, count: 9)
            var carriedCounts = Array(repeating: 0, count: 3)
            @MainActor func header(_ subtitle: String) {
                pageNumber += 1; context.beginPage()
                text("PILOT LOGBOOK", x: 24, y: 22, width: 490, font: .boldSystemFont(ofSize: 19))
                text(pilotName.isEmpty ? "Personal flight record" : pilotName, x: 24, y: 47, width: 490, font: .systemFont(ofSize: 11))
                text("XC = cross-country | Act. / Sim. = actual / simulated instrument | Inst. = instructor time | Ldg. = landings", x: 24, y: 63, width: 744, font: .systemFont(ofSize: 7))
                text(subtitle, x: 524, y: 26, width: 244, font: .systemFont(ofSize: 9), centered: true)
                text("\(AppBrand.name) | Page \(pageNumber) | Hours in decimal form | Entries in date order", x: 24, y: 582, width: 744, font: .systemFont(ofSize: 8))
            }
            @MainActor func totals(_ title: String, _ times: [Double], _ counts: [Int], y: CGFloat) {
                rule(24, y, 248, 18, fill: true)
                text(title, x: 29, y: y + 3, width: 238, font: .boldSystemFont(ofSize: 8))
                var x: CGFloat = 272
                for index in 0..<12 {
                    let column = columns[index + 4]
                    rule(x, y, column.width, 18, fill: true)
                    let value = index < 9 ? hours(times[index]) : String(counts[index - 9])
                    text(value, x: x + 1, y: y + 3, width: column.width - 2, font: .boldSystemFont(ofSize: 7), centered: true)
                    x += column.width
                }
                rule(x, y, 185, 18, fill: true)
            }
            for page in 0..<tablePages {
                header("FLIGHT RECORD | Table \(page + 1) of \(tablePages)")
                var x: CGFloat = 24
                for column in columns {
                    rule(x, 76, column.width, 35, fill: true)
                    text(column.title, x: x + 2, y: 82, width: column.width - 4, font: .boldSystemFont(ofSize: 6.7), maxLines: 3, centered: true)
                    x += column.width
                }
                let start = page * rowCount; let end = min(entries.count, start + rowCount)
                let pageEntries = Array(entries[start..<end])
                var pageTimes = Array(repeating: 0.0, count: 9); var pageCounts = Array(repeating: 0, count: 3)
                for row in 0..<rowCount {
                    let y: CGFloat = 111 + CGFloat(row) * 49
                    x = 24
                    for column in columns { rule(x, y, column.width, 49); x += column.width }
                    guard row < pageEntries.count else { continue }
                    let f = pageEntries[row]; let entry = start + row + 1
                    let times = timeValues(f); let counts = countValues(f)
                    for i in times.indices { pageTimes[i] += times[i] }
                    for i in counts.indices { pageCounts[i] += counts[i] }
                    let identity = [f.shortDate + "\n#" + String(format: "%04d", entry), f.aircraftModel + "\n" + f.category, f.registration, f.route.replacingOccurrences(of: " → ", with: " ")]
                    x = 24
                    for i in 0..<4 {
                        text(identity[i], x: x + 3, y: y + 6, width: columns[i].width - 6, font: .systemFont(ofSize: 8), maxLines: 3)
                        x += columns[i].width
                    }
                    for i in 0..<12 {
                        text(i < 9 ? hours(times[i]) : String(counts[i - 9]), x: x + 1, y: y + 16,
                            width: columns[i + 4].width - 2, font: .systemFont(ofSize: 8), maxLines: 1, centered: true)
                        x += columns[i + 4].width
                    }
                    let remark = f.notes.isEmpty ? (f.facts.has("checkride") ? "Checkride" : f.facts.has("flightReview") ? "Flight review" : "") : f.notes
                    text(remark, x: x + 4, y: y + 3, width: 177, font: .systemFont(ofSize: 8), maxLines: 1)
                    if let signature = f.validSignature {
                        text(signature.instructor.name + " | CFI #" + signature.instructor.certificate,
                            x: x + 4, y: y + 17, width: 110, font: .systemFont(ofSize: 7), maxLines: 1)
                        if let ink = UIImage(data: signature.inkPNG) {
                            let width = min(64, 18 * ink.size.width / max(1, ink.size.height))
                            ink.draw(in: CGRect(x: x + 117, y: y + 15, width: width, height: 18))
                        }
                    } else if f.signature != nil {
                        text("Signature belongs to a previous version", x: x + 4, y: y + 17, width: 177, font: .systemFont(ofSize: 7), maxLines: 1)
                    }
                    text("Full remarks / details: appendix entry #" + String(format: "%04d", entry), x: x + 4, y: y + 35, width: 177, font: .systemFont(ofSize: 7), maxLines: 1)
                }
                totals("Brought forward", carriedTimes, carriedCounts, y: 511)
                totals("This page", pageTimes, pageCounts, y: 529)
                for i in carriedTimes.indices { carriedTimes[i] += pageTimes[i] }
                for i in carriedCounts.indices { carriedCounts[i] += pageCounts[i] }
                totals("Total to date", carriedTimes, carriedCounts, y: 547)
            }
            // Pack full remarks and signatures onto appendix pages; wrap and continue long entries.
            var appendixY: CGFloat = 600
            @MainActor func appendixPage(_ entry: Int, continued: Bool = false) {
                header("REMARKS / ENDORSEMENTS | Entry #" + String(format: "%04d", entry) + (continued ? " continued" : ""))
                appendixY = 82
            }
            for (index, flight) in entries.enumerated() {
                let font = UIFont.systemFont(ofSize: 9.5)
                let wrapped = lines(entryDetail(flight, entry: index + 1), width: 716, font: font)
                if appendixY > 475 { appendixPage(index + 1) }
                for line in wrapped {
                    if appendixY + font.lineHeight + 2 > 550 { appendixPage(index + 1, continued: true) }
                    text(line, x: 38, y: appendixY, width: 716, font: font, maxLines: 1)
                    appendixY += font.lineHeight + 2
                }
                if let signature = flight.signature {
                    if appendixY + 126 > 550 { appendixPage(index + 1, continued: true) }
                    text(signature.matches(flight) ? "Instructor signature for this entry" : "Previous signature - not valid for this edited entry",
                         x: 38, y: appendixY, width: 716, font: .boldSystemFont(ofSize: 9))
                    appendixY += 18
                    rule(38, appendixY, 716, 94)
                    if let ink = UIImage(data: signature.inkPNG) {
                        let scale = min(680 / max(1, ink.size.width), 74 / max(1, ink.size.height))
                        let size = CGSize(width: ink.size.width * scale, height: ink.size.height * scale)
                        ink.draw(in: CGRect(x: 52, y: appendixY + 10, width: size.width, height: size.height))
                    }
                    appendixY += 104
                }
                if appendixY + 20 <= 550 { rule(38, appendixY + 8, 716, 0.1) }
                appendixY += 26
            }
        }
    }
}

enum CSVExport {
    static func text(_ flights: [Flight]) throws -> String {
            let header = "Date,Registration,Make and model,Route,Total,PIC,SIC,Solo,Day takeoffs,Night takeoffs,Day landings,Night landings,Night time,IMC,Simulated instrument,Dual received,Instructor,Cross-country,Approach count,Approaches,Holds,Tracking,Category,Complex,High performance,TAA,Notes,Flight review,Checkride,Passed qualifying test,Flight facts JSON,Legacy progress JSON,Instructor signature JSON,Milestone confirmations JSON"
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let rows = try flights.map { f -> String in
                let facts = String(data: try encoder.encode(f.facts), encoding: .utf8) ?? "{}"
                let legacy = String(data: try encoder.encode(f.progress), encoding: .utf8) ?? "{}"
                let signature = String(data: try encoder.encode(f.signature), encoding: .utf8) ?? "null"
                let confirmations = String(data: try encoder.encode(f.confirmations), encoding: .utf8) ?? "{}"
                let fields: [String] = [f.date, f.registration, f.aircraftModel, f.route, editableHours(f.total), editableHours(f.pic), editableHours(f.sicTime), editableHours(f.soloTime), String(f.facts.counts["dayTakeoffs", default: 0]), String(f.facts.counts["nightTakeoffs", default: 0]),
                    String(f.dayLandings), String(f.nightLandings), editableHours(f.night), editableHours(f.imc), editableHours(f.simulatedInstrument),
                    editableHours(f.dual), editableHours(f.instructor), editableHours(f.crossCountry), String(f.approachCount), f.approaches,
                    String(f.holds), String(f.tracking), f.category, String(f.complex), String(f.highPerformance), String(f.taa), f.notes,
                    String(f.facts.has("flightReview")), String(f.facts.has("checkride")), String(f.facts.has("checkride") && f.facts.has("checkridePassed")), facts, legacy, signature, confirmations]
                return fields.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: ",")
            }
        return ([header] + rows).joined(separator: "\r\n")
    }
}

@MainActor enum LogbookExport {
    static func make(_ flights: [Flight], pdf: Bool, pilotName: String = "") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppBrand.name)-\(UUID().uuidString).\(pdf ? "pdf" : "csv")")
        if pdf { try LogbookPDF.render(flights, pilotName: pilotName).write(to: url, options: .atomic) }
        else {
            try CSVExport.text(flights).write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }
}
