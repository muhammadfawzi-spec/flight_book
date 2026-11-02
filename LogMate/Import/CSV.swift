// CSV import domain: the CSV field table, draft rows, validation and
// review plans, route/aircraft resolution during import, and the import
// review engine (what is flagged for human confirmation).
import Foundation
import CryptoKit

enum CSVImportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}
enum CSVField: String, CaseIterable, Identifiable {
    case date, registration, model, make, route, departure, destination, total, pic, sic, solo, night, imc, simulated, dual, instructor, xc
    case dayLandings, nightLandings, dayTakeoffs, nightTakeoffs, approaches, approachCount, holds, category, complex, hp, taa, turbine, tailwheel
    case notes, flightReview, checkride, passed, facts, legacyProgress, signatureAudit, confirmationAudit, ground, picDuties, supervisedPIC, numberFlights, aeroTows, groundLaunches, poweredLaunches, tracking, representedClass
    case xcDual, xcSolo, xcPIC, xcSIC, nightDual, nightPIC, nightSIC, nightTakeoffsPIC, nightLandingsPIC, nightTakeoffsSIC, nightLandingsSIC, totalLandings, totalTakeoffs
    case sourceID, fullStopDayLandings, fullStopNightLandings, touchAndGoDayLandings, touchAndGoNightLandings, simulator
    var id: String { rawValue }
    nonisolated var title: String {
        switch self {
        case .registration: return "Registration / aircraft ID"
        case .model: return "Make and model (or model column)"
        case .make: return "Make (separate column)"
        case .departure: return "From airport"
        case .destination: return "To airport"
        case .imc: return "Actual instrument"
        case .simulated: return "Simulated instrument"
        case .dual: return "Instruction received"
        case .xc: return "Cross-country"
        case .hp: return "High performance"
        case .passed: return "Passed qualifying test"
        case .facts: return "Flight facts JSON"
        case .sourceID: return "Source flight ID"
        case .fullStopDayLandings: return "Full-stop day landings (subset)"
        case .fullStopNightLandings: return "Full-stop night landings (subset)"
        case .simulator: return "Simulator / training-device time"
        default:
            return rawValue.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
        }
    }
    var aliases: [String] {
        switch self {
        case .date: return ["date", "flightdate", "dateofdeparture"]
        case .registration: return ["registration", "tailnumber", "displaytail", "aircraftident", "aircraftregistration", "nnumber", "aircraft", "aircraftid"]
        case .model: return ["makeandmodel", "aircraftmodel", "model", "aircrafttype", "type"]
        case .make: return ["make", "manufacturer"]
        case .route: return ["route", "routing", "flightpath"]
        case .departure: return ["from", "departure", "departureairport", "fromairport"]
        case .destination: return ["to", "arrival", "destination", "destinationairport", "toairport"]
        case .total: return ["total", "totaltime", "totalflighttime", "duration", "flighttime", "totalflighttimehhmm"]
        case .pic: return ["pic", "pilotincommand", "pilotincommandtime", "pichhmm"]
        case .sic: return ["sic", "secondincommand", "sictimehhmm"]
        case .solo: return ["solo", "solotime"]
        case .night: return ["night", "nighttime"]
        case .imc: return ["imc", "actualinstrument", "actualinstrumenttime", "actualinst"]
        case .simulated: return ["simulatedinstrument", "simulatedinstrumenttime", "simulatedinst", "hood"]
        case .dual: return ["dual", "dualreceived", "instructionreceived", "dualinstructionreceived"]
        case .instructor: return ["instructor", "dualgiven", "instructiongiven", "cfi", "instructortime", "cfitimehhmm"]
        case .xc: return ["crosscountry", "crosscountrytime", "xc", "xcountry"]
        case .dayLandings: return ["daylandings", "landingsday", "daylanding"]
        case .nightLandings: return ["nightlandings", "landingsnight", "nightlanding"]
        case .dayTakeoffs: return ["daytakeoffs", "takeoffsday", "daytakeoff", "takeoffday"]
        case .nightTakeoffs: return ["nighttakeoffs", "takeoffsnight", "nighttakeoff", "takeoffnight"]
        case .approaches: return ["approachnames", "approachname", "approachdetails", "instrumentapproaches", "approaches"]
        case .approachCount: return ["approachcount", "numberofapproaches", "approachescount"]
        case .holds: return ["holds", "hold", "holding", "holdcount"]
        case .category: return ["category", "categoryclass", "aircraftcategory", "aircraftclass"]
        case .complex: return ["complex", "complextime"]
        case .hp: return ["highperformance", "highperformancetime"]
        case .taa: return ["taa", "technicallyadvanced"]
        case .turbine: return ["turbine", "turbinepowered"]
        case .tailwheel: return ["tailwheel", "taildragger"]
        case .notes: return ["notes", "remarks", "comments", "comment"]
        case .flightReview: return ["flightreview", "bfr"]
        case .checkride: return ["checkride", "practicaltest", "checkridefaa"]
        case .passed: return ["passedqualifyingtest", "checkridepassed"]
        case .facts: return ["flightfactsjson"]
        case .legacyProgress: return ["legacyprogressjson"]
        case .signatureAudit: return ["instructorsignaturejson"]
        case .confirmationAudit: return ["milestoneconfirmationsjson"]
        case .ground: return ["ground", "groundinstruction", "groundtraining"]
        case .picDuties: return ["picduties", "picdutieswithinstructor", "supervisedsolo"]
        case .supervisedPIC: return ["supervisedpic", "supervisedpicdutiesassic"]
        case .numberFlights: return ["numberflights", "numberofflights", "flightcount"]
        case .aeroTows: return ["aerotows", "aerotow"]
        case .groundLaunches: return ["groundlaunches", "groundlaunch"]
        case .poweredLaunches: return ["poweredlaunches", "poweredlaunch"]
        case .tracking: return ["tracking", "instrumenttracking"]
        case .representedClass: return ["representedclass", "simulatorclass"]
        case .xcDual: return ["xcdual", "crosscountryinstructionreceived", "crosscountrydual", "crosscountrydualreceived"]
        case .xcSolo: return ["xcsolo", "crosscountrysolo"]
        case .xcPIC: return ["xcpic", "piccrosscountry", "crosscountrypic"]
        case .xcSIC: return ["xcsic", "siccrosscountry", "crosscountrysic"]
        case .nightDual: return ["nightdual", "nightinstructionreceived", "nightdualreceived"]
        case .nightPIC: return ["nightpic", "picnight"]
        case .nightSIC: return ["nightsic", "sicnight"]
        case .nightTakeoffsPIC: return ["nighttakeoffspic"]
        case .nightLandingsPIC: return ["nightlandingspic"]
        case .nightTakeoffsSIC: return ["nighttakeoffssic"]
        case .nightLandingsSIC: return ["nightlandingssic"]
        case .totalLandings: return ["landings", "alllandings", "totallandings"]
        case .totalTakeoffs: return ["takeoffs", "alltakeoffs", "totaltakeoffs"]
        case .sourceID: return ["flightid", "sourceflightid", "entryid", "recordid"]
        case .fullStopDayLandings: return ["fsdaylandings", "fullstopdaylandings", "dayfullstoplandings", "landingfullstopday", "daylandingsfullstop"]
        case .fullStopNightLandings: return ["fsnightlandings", "fullstopnightlandings", "nightfullstoplandings", "landingfullstopnight", "nightlandingsfullstop"]
        case .touchAndGoDayLandings: return ["landingtouchandgoday", "daylandingstouchandgo"]
        case .touchAndGoNightLandings: return ["landingtouchandgonight", "nightlandingstouchandgo"]
        case .simulator: return ["groundsimulator", "simulatortime", "groundsimtime", "devicetime"]
        }
    }
}
struct CSVFlightDraft: Identifiable {
    let id = UUID()
    var flight: Flight
    var source: String
    var warnings: [String]
    var missingDate: Bool
    var resolvedAircraft: SavedAircraft? = nil
    func reviewContext(title: String) -> ScanReviewContext {
        ScanReviewContext(title: title, sourceText: source, image: nil, warnings: warnings,
            unresolvedFields: missingDate ? ["date"] : [], issues: CSVImportReview.reviewIssues(flight))
    }
    var hasReviewFlags: Bool {
        let context = reviewContext(title: "CSV flight")
        return !context.fieldIssues.isEmpty || !context.otherNotes.isEmpty
    }
}

enum CSVReviewMode { case all, flagged, withoutReview }
struct CSVReviewPlan {
    var automatic: [CSVFlightDraft] = []
    var review: [CSVFlightDraft] = []
    var notAdded: [ImportFailure] = []
}
struct ImportFailure: Identifiable {
    let id: UUID
    var title: String
    var subtitle: String
    var issues: [ScanFieldIssue]
    static func flight(_ flight: Flight, number: Int, issues: [ScanFieldIssue]) -> ImportFailure {
        ImportFailure(id: flight.id, title: "Flight \(number)",
            subtitle: [flight.date.isEmpty ? "Date missing" : flight.shortDate,
                       flight.registration.isEmpty ? "Registration missing" : flight.registration].joined(separator: " · "),
            issues: ScanReviewFields.unique(issues))
    }
    static func schedule(_ item: ScheduledFlight, number: Int, issues: [ScanFieldIssue]) -> ImportFailure {
        let date = issues.contains { $0.field == "date" } ? "Date missing" : FlightDates.string(item.date, format: "M/d/yy")
        let aircraft = item.isGround ? "Ground lesson" : (item.registration.isEmpty ? "Registration missing" : item.registration)
        return ImportFailure(id: item.id, title: item.title.isEmpty ? "Scheduled flight \(number)" : item.title,
            subtitle: date + " · " + aircraft, issues: ScanReviewFields.unique(issues))
    }
}
enum FlightEntryValidation {
    static func requiredIssues(_ flight: Flight, missingDate: Bool = false) -> [ScanFieldIssue] {
        var issues: [ScanFieldIssue] = []
        if missingDate || FlightDates.parse(flight.date) == nil {
            issues.append(ScanFieldIssue(field: "date", message: "Choose a valid flight date."))
        }
        if flight.registration.isEmpty {
            issues.append(ScanFieldIssue(field: "registration", message: "Enter this flight's aircraft registration."))
        }
        return issues
    }
    static func savingIssues(_ flight: Flight, missingDate: Bool = false) -> [ScanFieldIssue] {
        var issues = requiredIssues(flight, missingDate: missingDate)
        func issue(_ field: String, _ message: String) { issues.append(ScanFieldIssue(field: field, message: message)) }
        if !flight.total.isFinite || flight.total < 0 { issue("total", "Enter a valid, nonnegative total time, or leave it blank.") }
        for (field, value) in [("pic", flight.pic), ("night", flight.night), ("imc", flight.imc),
                               ("sim", flight.simulatedInstrument), ("dual", flight.dual),
                               ("instructor", flight.instructor), ("xc", flight.crossCountry), ("sic", flight.facts.amounts["sic", default: 0])] {
            if !value.isFinite || value < 0 || (flight.total > 0 && value > flight.total + 0.001) {
                issue(field, "Enter a valid time; when total time is supplied, each time must fit within it.")
            }
        }
        if flight.total > 0 && flight.imc + flight.simulatedInstrument > flight.total + 0.001 {
            issue("imc", "Actual and simulated instrument time together exceed total time.")
            issue("sim", "Actual and simulated instrument time together exceed total time.")
        }
        for (field, value) in [("landings", flight.dayLandings), ("landings", flight.nightLandings),
                               ("approachCount", flight.approachCount), ("holds", flight.holds)] {
            if value < 0 || value >= 100_000 { issue(field, "Enter a nonnegative whole-number count.") }
        }
        return ScanReviewFields.unique(issues)
    }
}
enum CSVImportReview {
    static func plan(_ drafts: [CSVFlightDraft], mode: CSVReviewMode) -> CSVReviewPlan {
        var result = CSVReviewPlan()
        for (index, draft) in drafts.enumerated() {
            let issues = FlightEntryValidation.requiredIssues(draft.flight, missingDate: draft.missingDate)
            switch mode {
            case .all: result.review.append(draft)
            case .flagged:
                if !issues.isEmpty || draft.hasReviewFlags { result.review.append(draft) }
                else { result.automatic.append(draft) }
            case .withoutReview:
                if issues.isEmpty { result.automatic.append(draft) }
                else {
                    let number = Int(draft.flight.facts.text["csvSourceRow", default: ""]) ?? index + 1
                    result.notAdded.append(.flight(draft.flight, number: number, issues: issues))
                }
            }
        }
        return result
    }
    static func validationIssues(_ flight: Flight) -> [ScanFieldIssue] { FlightEntryValidation.requiredIssues(flight) }
    static func reviewIssues(_ flight: Flight) -> [ScanFieldIssue] {
        var issues = FlightEntryValidation.savingIssues(flight)
        func issue(_ field: String, _ message: String) { issues.append(ScanFieldIssue(field: field, message: message)) }
        if flight.isDevice ? flight.aircraftModel.isEmpty : !AircraftNames.hasMake(flight.aircraftModel) {
            issue("model", "Make and model could not be filled from the aircraft lookup. You can leave them blank.")
        }
        if !flight.isDevice {
            if flight.facts.text["csvRouteEndpoints"] == "1" {
                for (field, key) in [("departure", "csvDeparture"), ("arrival", "csvArrival")] {
                    if AirportRoute.codes(flight.facts.text[key, default: ""]).count != 1 {
                        issue(field, "The source gives coordinates for this airport. Leave it blank or enter an airport.")
                    }
                }
            } else if AirportRoute.codes(flight.route).isEmpty { issue("route", "Route is not supplied. You can leave it blank.") }
        }
        if flight.total == 0 { issue("total", "Total time is not supplied. You can leave it blank.") }
        return ScanReviewFields.unique(issues)
    }
}
nonisolated enum CSVRoute {
    static func containsCoordinates(_ text: String) -> Bool {
        let pattern = #"(?i)(°|\bcoordinates?\b|\b(?:lat(?:itude)?|lon(?:gitude)?)\s*[:=]?\s*[+-]?\d|\d+(?:\.\d+)?\s*[NS]\s*[/, ]+\s*\d+(?:\.\d+)?\s*[EW]|(?<![A-Za-z0-9])[+-]?\d{1,2}(?:\.\d+)?\s*[,/ ]\s*[+-]?\d{1,3}(?:\.\d+)?(?![A-Za-z0-9]))"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    static func airport(_ text: String) -> String {
        containsCoordinates(text) ? "" : AirportRoute.codes(text).first ?? ""
    }
    static func endpoints(route: String, departure: String, arrival: String) -> (departure: String, arrival: String)? {
        guard containsCoordinates(departure) || containsCoordinates(arrival) || containsCoordinates(route) else { return nil }
        if !departure.isEmpty || !arrival.isEmpty {
            return (airport(departure), airport(arrival))
        }
        let arrows = route.components(separatedBy: "→")
        if arrows.count > 1 { return (airport(arrows.first ?? ""), airport(arrows.last ?? "")) }
        let tokens = route.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return (airport(tokens.first ?? ""), airport(tokens.last ?? ""))
    }
}

@MainActor enum CSVImportAircraft {
    static func resolve(_ drafts: [CSVFlightDraft], saved: [SavedAircraft],
                        lookup: @MainActor (String) async -> AircraftInfo? = { await AircraftLookup.info($0) },
                        progress: (Int, Int) -> Void = { _, _ in }) async -> [CSVFlightDraft] {
        var result = drafts
        let registrations = Array(Set(drafts.filter {
            !$0.flight.isDevice && !$0.flight.registration.isEmpty
        }.map { $0.flight.registration })).sorted()
        progress(0, registrations.count)
        for (index, registration) in registrations.enumerated() {
            guard !Task.isCancelled else { return result }
            let previous = saved.first { AircraftLookup.clean($0.registration) == registration }
            let info = await lookup(registration)
            guard !Task.isCancelled else { return result }
            let registryModel = info.map { AircraftNames.display($0.model) } ?? ""
            let savedModel = previous.map { AircraftNames.display($0.model) } ?? ""
            // CSV model text is source evidence only. Resolve every registration.
            let model = AircraftNames.hasMake(registryModel) ? registryModel : (AircraftNames.hasMake(savedModel) ? savedModel : "")
            let savedCategory = previous?.category ?? "Unspecified"
            let sourceCategory = result.first { $0.flight.registration == registration && $0.flight.category != "Unspecified" }?.flight.category
            let category = savedCategory != "Unspecified" ? savedCategory : info?.suggestedCategory ?? sourceCategory ?? "Unspecified"
            let detection = AircraftFeatures.detect(model, category: category, info: info ?? previous?.equipmentInfo)
            var resolvedAircraft = previous ?? SavedAircraft(registration: registration, model: model)
            resolvedAircraft.model = model; resolvedAircraft.category = category
            resolvedAircraft.equipmentInfo = info ?? previous?.equipmentInfo
            resolvedAircraft.detectedFeatures = detection.values
            var corrections = previous?.featureCorrections ?? previous?.equipmentCorrections.filter { $0.value } ?? [:]
            for feature in AircraftFeature.allCases where corrections[feature.rawValue] == nil && detection.values[feature.rawValue] == nil {
                if result.contains(where: { $0.flight.registration == registration && $0.flight.hasAircraftFeature(feature) }) {
                    corrections[feature.rawValue] = true
                }
            }
            resolvedAircraft.featureCorrections = corrections
            let features = resolvedAircraft.resolvedEquipmentFeatures
            resolvedAircraft.complex = features["complex"]; resolvedAircraft.highPerformance = features["hp"]
            resolvedAircraft.taa = features["taa"]; resolvedAircraft.turbine = features["turbine"]
            for i in result.indices where result[i].flight.registration == registration && !result[i].flight.isDevice {
                result[i].flight.aircraft = registration + " · " + model
                if result[i].flight.category == "Unspecified" { result[i].flight.category = category }
                let equipment = AircraftEquipmentState.imported(result[i].flight, model: model,
                    category: result[i].flight.category, info: info, saved: resolvedAircraft)
                equipment.apply(to: &result[i].flight)
                result[i].resolvedAircraft = resolvedAircraft
                result[i].flight.facts.text["aircraftModelSource"] = AircraftNames.hasMake(registryModel) ? "Registry" : (model.isEmpty ? "Unavailable" : "Saved aircraft")
            }
            progress(index + 1, registrations.count)
        }
        return result
    }
}

struct CSVTable {
    var headers: [String]
    var rows: [[String]]
    var isForeFlight: Bool {
        let names = Set(headers.map(Self.normalized))
        return names.isSuperset(of: ["aircraftid", "from", "to"]) &&
            !names.isDisjoint(with: ["landingfullstopday", "landingfullstopnight", "daylandingsfullstop", "nightlandingsfullstop"])
    }
    nonisolated static func normalized(_ text: String) -> String {
        let value = text.lowercased().filter { $0.isLetter || $0.isNumber }
        return value.hasPrefix("flt") ? String(value.dropFirst(3)) : value
    }
    static func cells(_ text: String, delimiter: Character) throws -> [[String]] {
        let chars = Array(text.replacingOccurrences(of: "\u{FEFF}", with: "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false, i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { cell.append("\""); i += 1 }
                else if quoted || cell.isEmpty { quoted.toggle() }
                else { cell.append(c) }
            } else if c == delimiter && !quoted { row.append(cell); cell = "" }
            else if (c == "\r" || c == "\n") && !quoted {
                row.append(cell); rows.append(row); row = []; cell = ""
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
            } else { cell.append(c) }
            i += 1
        }
        guard !quoted else { throw CSVImportError.invalid("An unmatched quote was found. Re-export the CSV or repair the quoted cell.") }
        if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
        return rows.filter { $0.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    }
    static func parse(_ text: String) throws -> CSVTable {
        let fields = Set(CSVField.allCases.flatMap(\.aliases))
        func score(_ row: [String]) -> Int { row.map(normalized).filter { fields.contains($0) }.count }
        // Choose the delimiter from the header before parsing the complete file.
        // A broken quoted comma cell must not silently turn into a one-column semicolon import.
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(30)
        let candidates = [Character(","), ";", "\t"].map { delimiter in
            let rows = lines.compactMap { try? cells($0, delimiter: delimiter) }.flatMap { $0 }
            return (delimiter: delimiter, score: rows.map(score).max() ?? 0, width: rows.first?.count ?? 0)
        }
        guard let selected = candidates.max(by: { $0.score == $1.score ? $0.width < $1.width : $0.score < $1.score }) else {
            throw CSVImportError.invalid("No CSV header and flight rows were found.")
        }
        let best = try cells(text, delimiter: selected.delimiter)
        guard let headerIndex = best.indices.max(by: { score(best[$0]) < score(best[$1]) }),
              score(best[headerIndex]) >= 2 else {
            // Still allow an unfamiliar header to be mapped manually.
            guard best.count >= 2 else {
                throw CSVImportError.invalid("No CSV header and flight rows were found.")
            }
            return CSVTable(headers: best[0], rows: Array(best.dropFirst()))
        }
        let headers = best[headerIndex]
        let rows = best.dropFirst(headerIndex + 1).filter { $0.count > 1 && normalized($0.first ?? "") != "total" }
        return CSVTable(headers: headers, rows: Array(rows))
    }
    var automaticMapping: [String: Int] {
        var result: [String: Int] = [:]
        let clean = headers.map(Self.normalized)
        for field in CSVField.allCases {
            // Prefer explicit registrations and detailed approach names over earlier generic columns.
            if let index = field.aliases.compactMap({ clean.firstIndex(of: $0) }).first { result[field.rawValue] = index }
        }
        if result[CSVField.approachCount.rawValue] == nil, let i = clean.firstIndex(of: "approaches"), fieldIsNumeric(i) { result[CSVField.approachCount.rawValue] = i }
        return result
    }
    private func fieldIsNumeric(_ index: Int) -> Bool {
        let populated = rows.compactMap { $0.indices.contains(index) ? $0[index].trimmingCharacters(in: .whitespacesAndNewlines) : nil }.filter { !$0.isEmpty }
        return !populated.isEmpty && populated.allSatisfy { Int($0).map { $0 >= 0 } ?? false }
    }
    nonisolated static func time(_ text: String) -> Double? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return 0 }
        if value.contains(":") {
            let pieces = value.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count == 2, let h = Double(pieces[0]), let m = Double(pieces[1]), h.isFinite, m.isFinite, h >= 0, (0..<60).contains(m) else { return nil }
            return h + m / 60
        }
        return Double(value.replacingOccurrences(of: ",", with: ".")).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    func drafts(mapping: [String: Int], dayFirst: Bool) -> [CSVFlightDraft] {
        let defaultMapping = automaticMapping
        let cleanHeaders = headers.map(Self.normalized)
        let foreFlight = isForeFlight
        return rows.enumerated().map { rowIndex, row in
            func text(_ field: CSVField) -> String {
                guard let i = mapping[field.rawValue], row.indices.contains(i) else { return "" }
                let value = row[i].trimmingCharacters(in: .whitespacesAndNewlines)
                // ForeFlight has modern and deprecated count columns in the same file.
                // A populated value (including zero) wins. Only blank automatic mappings fall back.
                if !value.isEmpty { return value }
                if foreFlight, mapping[field.rawValue] == defaultMapping[field.rawValue],
                   [.fullStopDayLandings, .fullStopNightLandings, .dayTakeoffs, .nightTakeoffs].contains(field) {
                    for alias in field.aliases {
                        if let j = cleanHeaders.firstIndex(of: alias), row.indices.contains(j) {
                            let alternate = row[j].trimmingCharacters(in: .whitespacesAndNewlines)
                            if !alternate.isEmpty { return alternate }
                        }
                    }
                }
                return value
            }
            var f = Flight(), warnings: [String] = []
            func time(_ field: CSVField) -> Double {
                if let value = Self.time(text(field)) { return value }
                warnings.append("Check \(field.title): \(text(field))."); return 0
            }
            func optionalCount(_ field: CSVField) -> Int? {
                let raw = text(field); if raw.isEmpty { return nil }
                guard let value = Double(raw), value.isFinite, value >= 0, value.rounded() == value, value < 100_000 else {
                    warnings.append("Check \(field.title): \(raw)."); return nil
                }
                return Int(value)
            }
            func count(_ field: CSVField) -> Int { optionalCount(field) ?? 0 }
            func flag(_ field: CSVField) -> Bool {
                let raw = text(field).lowercased()
                return ["true", "yes", "y", "1", "checked"].contains(raw) || (Self.time(raw) ?? 0) > 0
            }
            let rawDate = text(.date)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.isLenient = false
            var date: Date?
            let dateText = rawDate.range(of: #"^\d{4}-\d{2}-\d{2}[T ]"#, options: .regularExpression) != nil ? String(rawDate.prefix(10)) : rawDate
            for format in dayFirst ? ["yyyy-MM-dd", "yyyy/MM/dd", "d/M/yyyy", "d/M/yy", "d-M-yyyy", "d.M.yyyy", "dd MMM yyyy"] : ["yyyy-MM-dd", "yyyy/MM/dd", "M/d/yyyy", "M/d/yy", "MMM d, yyyy", "dd MMM yyyy"] {
                formatter.dateFormat = format
                if let found = formatter.date(from: dateText) { date = found; break }
            }
            f.date = date.map { FlightDates.string($0) } ?? ""
            if date == nil { warnings.append("Choose the missing or unreadable flight date: \(rawDate).") }
            let reg = AircraftNames.registration(text(.registration))
            let model = AircraftNames.display([text(.make), text(.model)].filter { !$0.isEmpty }.joined(separator: " "))
            f.aircraft = reg + " · " + model
            let route = text(.route).isEmpty ? [text(.departure), text(.destination)].filter { !$0.isEmpty }.joined(separator: " ") : text(.route)
            let coordinateEndpoints = CSVRoute.endpoints(route: route, departure: text(.departure), arrival: text(.destination))
            f.route = AirportRoute.formatted(coordinateEndpoints.map { $0.departure + " " + $0.arrival } ?? route)
            f.duration = editableHours(time(.total)); f.pic = time(.pic); f.night = time(.night); f.imc = time(.imc)
            f.simulatedInstrument = time(.simulated); f.dual = time(.dual); f.instructor = time(.instructor); f.crossCountry = time(.xc)
            // Missing cells are not zero: an explicit 0 must survive the remainder calculation.
            var explicitDayLandings = optionalCount(.dayLandings)
            var explicitNightLandings = optionalCount(.nightLandings)
            var dayLandingMissing = text(.dayLandings).isEmpty
            var nightLandingMissing = text(.nightLandings).isEmpty
            let fullStopDayLandings = optionalCount(.fullStopDayLandings)
            let fullStopNightLandings = optionalCount(.fullStopNightLandings)
            let touchAndGoDayLandings = optionalCount(.touchAndGoDayLandings)
            let touchAndGoNightLandings = optionalCount(.touchAndGoNightLandings)
            let sourceLandingTotal = optionalCount(.totalLandings)
            if foreFlight {
                if dayLandingMissing, !text(.fullStopDayLandings).isEmpty || !text(.touchAndGoDayLandings).isEmpty {
                    dayLandingMissing = false
                    if (text(.fullStopDayLandings).isEmpty || fullStopDayLandings != nil) &&
                        (text(.touchAndGoDayLandings).isEmpty || touchAndGoDayLandings != nil) {
                        explicitDayLandings = (fullStopDayLandings ?? 0) + (touchAndGoDayLandings ?? 0)
                    }
                }
                if nightLandingMissing, !text(.fullStopNightLandings).isEmpty || !text(.touchAndGoNightLandings).isEmpty {
                    nightLandingMissing = false
                    if (text(.fullStopNightLandings).isEmpty || fullStopNightLandings != nil) &&
                        (text(.touchAndGoNightLandings).isEmpty || touchAndGoNightLandings != nil) {
                        explicitNightLandings = (fullStopNightLandings ?? 0) + (touchAndGoNightLandings ?? 0)
                    }
                }
                // Older rows can omit touch-and-go detail while retaining the total.
                // A full-stop day count is a subset; it must not erase those other day landings.
                if text(.dayLandings).isEmpty, text(.touchAndGoDayLandings).isEmpty,
                   text(.fullStopDayLandings).isEmpty || fullStopDayLandings != nil,
                   let total = sourceLandingTotal, let night = explicitNightLandings, night <= total,
                   (fullStopDayLandings ?? 0) <= total - night {
                    explicitDayLandings = total - night
                    dayLandingMissing = false
                }
            }
            f.dayLandings = explicitDayLandings ?? (dayLandingMissing ? fullStopDayLandings ?? 0 : 0)
            f.nightLandings = explicitNightLandings ?? (nightLandingMissing ? fullStopNightLandings ?? 0 : 0)
            f.approaches = Self.approachDetails(text(.approaches)); f.approachCount = count(.approachCount); f.holds = count(.holds)
            f.notes = text(.notes)
            let categoryAliases = ["sel": "ASEL", "ses": "ASES", "mel": "AMEL", "mes": "AMES", "airplanesingleengineland": "ASEL", "airplanesingleenginesea": "ASES", "airplanemultiengineland": "AMEL", "airplanemultienginesea": "AMES", "rotorcrafthelicopter": "Helicopter", "rotorcraftgyroplane": "Gyroplane", "poweredlift": "Powered lift"]
            f.category = categoryAliases[Self.normalized(text(.category))] ?? AircraftLookup.categories.first { $0.caseInsensitiveCompare(text(.category)) == .orderedSame } ?? "Unspecified"
            if let data = text(.facts).data(using: .utf8), let facts = try? JSONDecoder().decode(FlightFacts.self, from: data) { f.facts = facts }
            if let data = text(.legacyProgress).data(using: .utf8), let progress = try? JSONDecoder().decode([String: Double].self, from: data) { f.progress = progress }
            if let coordinateEndpoints {
                f.facts.text["csvRouteEndpoints"] = "1"
                f.facts.text["csvDeparture"] = coordinateEndpoints.departure
                f.facts.text["csvArrival"] = coordinateEndpoints.arrival
            }
            if mapping[CSVField.sic.rawValue] != nil { f.facts.amounts["sic"] = time(.sic) }
            if mapping[CSVField.solo.rawValue] != nil { f.facts.amounts["solo"] = time(.solo) }
            for key in FlightMetric.optionalHours where mapping[key] != nil {
                if let field = CSVField(rawValue: key) { f.facts.amounts[key] = time(field) }
            }
            for key in FlightMetric.optionalCounts where mapping[key] != nil {
                if let field = CSVField(rawValue: key) { f.facts.counts[key] = count(field) }
            }
            for key in FlightMetric.overlapMetrics where mapping[key] != nil {
                if let field = CSVField(rawValue: key), let metric = FlightMetric(rawValue: key) {
                    f.facts.amounts["credit_" + key] = metric.isCount ? Double(count(field)) : time(field)
                    if metric.rawCredit(f).estimated { warnings.append("Check conflicting \(metric.title) credit.") }
                }
            }
            for (field, value) in [(CSVField.fullStopDayLandings, fullStopDayLandings), (.fullStopNightLandings, fullStopNightLandings),
                                   (.touchAndGoDayLandings, touchAndGoDayLandings), (.touchAndGoNightLandings, touchAndGoNightLandings)] where mapping[field.rawValue] != nil {
                f.facts.counts[field.rawValue] = value ?? 0
            }
            let foreFlightLandingTotal: Int? = foreFlight && text(.totalLandings).isEmpty &&
                (explicitDayLandings != nil || explicitNightLandings != nil)
                ? (explicitDayLandings ?? 0) + (explicitNightLandings ?? 0) : nil
            if let total = sourceLandingTotal ?? foreFlightLandingTotal {
                f.facts.text.removeValue(forKey: "csvLandingSplit")
                if let night = explicitNightLandings, dayLandingMissing, night <= total {
                    f.dayLandings = total - night
                    f.facts.text["csvLandingSplit"] = "Day landings calculated automatically: total minus explicit night landings."
                } else if let day = explicitDayLandings, nightLandingMissing, day <= total {
                    f.nightLandings = total - day
                    f.facts.text["csvLandingSplit"] = "Night landings calculated automatically: total minus explicit day landings."
                } else if dayLandingMissing && nightLandingMissing {
                    // Source-specific full-stop fields are fallbacks, never overrides of explicit day/night counts.
                    // Their arithmetic split is automatic; retain the source subset and one review warning.
                    if let night = fullStopNightLandings {
                        f.nightLandings = night
                        if night <= total {
                            f.dayLandings = total - night
                            if night > 0 || f.night > 0 {
                                warnings.append("Check landings: day calculated as total minus the source's full-stop night count.")
                            }
                            f.facts.text["csvLandingSplit"] = "Automatic source fallback: night = full-stop night; day = total minus night."
                        }
                    } else if text(.fullStopNightLandings).isEmpty, let day = fullStopDayLandings {
                        f.dayLandings = day
                        if day <= total {
                            f.nightLandings = total - day
                            warnings.append("Check landings: night calculated as total minus the source's full-stop day count.")
                            f.facts.text["csvLandingSplit"] = "Automatic source fallback: day = full-stop day; night = total minus day."
                        }
                    } else if text(.fullStopDayLandings).isEmpty && text(.fullStopNightLandings).isEmpty && f.night == 0 {
                        f.dayLandings = total; f.nightLandings = 0
                    }
                }
                // Full-stop counts are known landings even when the total is wrong.
                // Preserve them as minimums for a missing day/night count. Explicit
                // day/night values (including zero) still take priority over subsets.
                if dayLandingMissing, let day = fullStopDayLandings { f.dayLandings = max(f.dayLandings, day) }
                if nightLandingMissing, let night = fullStopNightLandings { f.nightLandings = max(f.nightLandings, night) }
                if let day = fullStopDayLandings, day > f.dayLandings {
                    warnings.append("Check landings: full-stop day count exceeds the day landing count.")
                }
                if let night = fullStopNightLandings, night > f.nightLandings {
                    warnings.append("Check landings: full-stop night count exceeds the night landing count.")
                }
                f.facts.counts.removeValue(forKey: "unclassifiedLandings")
                let remainder = max(0, total - f.dayLandings - f.nightLandings)
                if remainder > 0 {
                    warnings.append("Assign \(remainder) remaining landings to day / night.")
                    f.facts.counts["unclassifiedLandings"] = remainder
                }
                if f.dayLandings + f.nightLandings > total {
                    warnings.append("Check landings: counts exceed the source total. Supplied counts were kept (\(f.dayLandings) day, \(f.nightLandings) night; source total \(total)).")
                }
                f.facts.counts["importedLandingTotal"] = total
            }
            if mapping[CSVField.totalTakeoffs.rawValue] != nil && mapping[CSVField.dayTakeoffs.rawValue] == nil {
                let total = count(.totalTakeoffs)
                if mapping[CSVField.nightTakeoffs.rawValue] != nil || f.night == 0 { f.facts.counts["dayTakeoffs"] = max(0, total - f.facts.counts["nightTakeoffs", default: 0]) }
                else { warnings.append("Assign \(total) takeoffs to day / night."); f.facts.counts["unclassifiedTakeoffs"] = total }
            }
            if mapping[CSVField.representedClass.rawValue] != nil { f.facts.text["representedClass"] = text(.representedClass) }
            if mapping[CSVField.tracking.rawValue] != nil { f.tracking = flag(.tracking) }
            if let value = Int(f.approaches.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 {
                if mapping[CSVField.approachCount.rawValue] == nil { f.approachCount = value }
                f.approaches = ""
            }
            if mapping[CSVField.simulator.rawValue] != nil, time(.simulator) > 0 {
                let deviceTime = time(.simulator)
                f.facts.amounts["importedSimulatorHours"] = deviceTime
                if f.total == 0 {
                    f.category = "ATD"; f.duration = editableHours(deviceTime)
                    f.aircraft = (reg.isEmpty ? "ATD" : reg) + " · " + (model.isEmpty ? "Training device" : model)
                    warnings.append("Check category / class: confirm the training device type.")
                } else { warnings.append("Simulator time is also recorded on this source row. Review it separately from aircraft flight time.") }
            }
            f.complex = flag(.complex); f.highPerformance = flag(.hp); f.taa = flag(.taa)
            for field in [CSVField.turbine, .tailwheel, .flightReview, .checkride] where mapping[field.rawValue] != nil {
                let key = field == .tailwheel ? "aircraftFeature.tailwheel" : field.rawValue
                f.facts.flags.remove(key)
                if field == .tailwheel { f.facts.flags.remove("tailwheel") }
                if field == .turbine { f.facts.flags.remove("aircraftFeature.turbine") }
                if flag(field) { f.facts.flags.insert(key) }
            }
            if flag(.passed) { f.facts.flags.insert("checkridePassed") }
            if f.total <= 0 { warnings.append("Total time is not supplied. You can leave it blank.") }
            if reg.isEmpty { warnings.append("Choose this flight's aircraft.") }
            // Preserve original metadata for audits without polluting the pilot's comments.
            for field in [CSVField.signatureAudit, .confirmationAudit] {
                let record = text(field)
                if !record.isEmpty && !["null", "{}", "[]"].contains(record) {
                    f.facts.text["csvSource_" + field.rawValue] = record
                }
            }
            let source = zip(headers, row).map { "\($0): \($1)" }.joined(separator: "\n")
            f.facts.text["csvSource"] = source
            f.facts.text["csvSourceRow"] = String(rowIndex + 1)
            let sourceID = text(.sourceID)
            if !sourceID.isEmpty {
                let schemaHash = SHA256.hash(data: Data(headers.map(Self.normalized).joined(separator: "|").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                let provider = headers.map(Self.normalized).contains("flightproperties") && headers.map(Self.normalized).contains("displaytail") ? "myflightbook" : "csv-" + schemaHash
                f.facts.text["csvSourceID"] = provider + ":" + sourceID
            }
            return CSVFlightDraft(flight: f, source: zip(headers, row).map { "\($0): \($1)" }.joined(separator: "\n"),
                warnings: warnings, missingDate: date == nil)
        }
    }
    nonisolated static func approachDetails(_ value: String) -> String {
        guard value.contains("@") else { return value }
        // MyFlightbook: 1-RNAV/GPS-Z-RWY31R@KRHV. Preserve the count and any unfamiliar text.
        return value.components(separatedBy: ";").map { part in
            let pieces = part.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "@")
            guard pieces.count == 2, let regex = try? NSRegularExpression(pattern: #"^(\d+)-(.+?)-RWY(.+)$"#),
                  let match = regex.firstMatch(in: pieces[0], range: NSRange(pieces[0].startIndex..., in: pieces[0])),
                  let countRange = Range(match.range(at: 1), in: pieces[0]),
                  let typeRange = Range(match.range(at: 2), in: pieces[0]),
                  let runwayRange = Range(match.range(at: 3), in: pieces[0]) else { return part }
            let count = String(pieces[0][countRange])
            return pieces[1] + " " + String(pieces[0][typeRange]) + " " + String(pieces[0][runwayRange]) + (count == "1" ? "" : " (\(count))")
        }.joined(separator: "\n")
    }
    static func newDrafts(_ drafts: [CSVFlightDraft], existing: [Flight]) -> (drafts: [CSVFlightDraft], duplicates: Int) {
        var seen = Set(existing.compactMap { $0.facts.text["csvSourceID"] }.filter { !$0.isEmpty })
        var duplicates = 0
        let remaining = drafts.filter { item in
            guard let source = item.flight.facts.text["csvSourceID"], !source.isEmpty else { return true }
            if !seen.insert(source).inserted { duplicates += 1; return false }
            return true
        }
        return (remaining, duplicates)
    }
}
