// Logbook totals domain: time ranges, groupings, the totals aggregation,
// the experience metric definitions, experience categories, the totals
// filter, and the experience selection entry.
import Foundation

enum TimeRange: String, CaseIterable {
    case all = "All time", days30 = "Past 30 days", week = "Past week"
    func includes(_ f: Flight) -> Bool {
        guard self != .all else { return true }
        guard let date = f.flightDate else { return false }
        let cutoff = Calendar.current.date(byAdding: .day, value: self == .week ? -7 : -30, to: Date())!
        return date >= cutoff && date <= Date()
    }
}

struct FlightGroup: Identifiable {
    var title: String
    var ids: Set<UUID>
    var id: String { title }
}

// Totals are built from the currently selected flights. A row exists only when
// its own time has been logged; equipment flags alone never create a zero row.
struct LogbookTotal: Identifiable {
    var id: String
    var title: String
    var amount: Double
    var isCount = false
    var detail = ""
    var flightIDs: Set<UUID>
    var displayValue: String { isCount ? String(Int(amount)) : LogbookTotals.format(amount) }
}

struct LogbookTotals {
    var categories: [LogbookTotal] = []
    var features: [LogbookTotal] = []
    var standard: [LogbookTotal] = []
    var overall: [LogbookTotal] = []
    var hasHours: Bool { !categories.isEmpty || !features.isEmpty || !standard.isEmpty }

    static func positive(_ value: Double) -> Double { value.isFinite && value > 0 ? value : 0 }
    static func sum(_ flights: [Flight], credit: (Flight) -> Double) -> Double {
        flights.reduce(0) { $0 + positive(credit($1)) }
    }
    static func format(_ value: Double) -> String {
        // Preserve a small real entry instead of rounding it into a visible 0.0.
        let rounded = hours(value)
        return value > 0 && rounded == "0.0" ? editableHours(value) : rounded
    }
    private static func row(_ id: String, _ title: String, flights: [Flight],
                            credit: (Flight) -> Double, detail: String = "") -> LogbookTotal? {
        let contributing = flights.filter { positive(credit($0)) > 0 }
        let amount = sum(contributing, credit: credit)
        guard amount > 0, amount.isFinite else { return nil }
        return LogbookTotal(id: id, title: title, amount: amount, detail: detail,
                            flightIDs: Set(contributing.map(\.id)))
    }
    private static func activity(_ flights: [Flight]) -> String {
        var parts: [String] = []
        let landings = flights.reduce(0) { $0 + max(0, $1.landings) }
        let night = flights.reduce(0) { $0 + max(0, $1.nightLandings) }
        let approaches = flights.reduce(0) { $0 + max(0, $1.approachCount) }
        if landings > 0 { parts.append("\(landings) landings" + (night > 0 ? " (\(night) night)" : "")) }
        if approaches > 0 { parts.append("\(approaches) approaches") }
        return parts.joined(separator: " · ")
    }
    init(flights: [Flight]) {
        let grouped = Dictionary(grouping: flights) { flight in
            let category = flight.category.trimmingCharacters(in: .whitespacesAndNewlines)
            return category.isEmpty ? "Unspecified" : category
        }
        categories = grouped.keys.sorted().compactMap { category in
            let list = (grouped[category] ?? []).filter { Self.positive($0.total) > 0 }
            return Self.row("category." + category, category, flights: list, credit: \.total,
                            detail: Self.activity(list))
        }
        for feature in AircraftFeature.pilotFeatures {
            let list = flights.filter { $0.hasAircraftFeature(feature) && Self.positive($0.total) > 0 }
            let pic = Self.sum(list, credit: \.pic)
            let title = feature == .taa ? "TAA (Technically Advanced Airplane)" : feature.title
            let detail = pic > 0 ? "PIC \(Self.format(pic))" : ""
            if let item = Self.row("feature." + feature.rawValue, title, flights: list, credit: \.total, detail: detail) {
                features.append(item)
            }
        }
        let times: [(id: String, title: String, credit: (Flight) -> Double)] = [
            ("xc", "Cross Country", \.crossCountry),
            ("night", "Night", \.night),
            ("instrument", "Instrument Time", { Self.positive($0.imc) + Self.positive($0.simulatedInstrument) }),
            ("imc", "IMC", \.imc),
            ("simulated", "Simulated Instrument", \.simulatedInstrument),
            ("dual", "Dual Received", \.dual),
            ("pic", "PIC", \.pic),
            ("sic", "SIC", \.sicTime),
            ("solo", "Solo", \.soloTime),
            ("instructor", "Instructor", \.instructor)
        ]
        standard = times.compactMap { time in
            var detail = ""
            if time.id == "instrument" {
                let actual = Self.sum(flights, credit: \.imc)
                let simulated = Self.sum(flights, credit: \.simulatedInstrument)
                var parts: [String] = []
                if actual > 0 { parts.append("\(Self.format(actual)) Actual") }
                if simulated > 0 { parts.append("\(Self.format(simulated)) Simulated") }
                detail = parts.joined(separator: " + ")
            }
            return Self.row("standard." + time.id, time.title, flights: flights, credit: time.credit, detail: detail)
        }
        let aircraftFlights = flights.filter { !$0.isDevice }
        let sessions = flights.filter(\.isDevice)
        if !aircraftFlights.isEmpty {
            overall.append(LogbookTotal(id: "overall.flights", title: "Flights", amount: Double(aircraftFlights.count),
                                        isCount: true, flightIDs: Set(aircraftFlights.map(\.id))))
        }
        if let item = Self.row("overall.time", "Total Time", flights: aircraftFlights, credit: \.total,
                               detail: Self.activity(aircraftFlights)) {
            overall.append(item)
        }
        if let item = Self.row("overall.deviceTime", "Simulator / Device Time", flights: sessions, credit: \.total,
                               detail: "\(sessions.count) \(sessions.count == 1 ? "session" : "sessions")") {
            overall.append(item)
        }
    }
}

enum FlightMetric: String, CaseIterable, Identifiable {
    case total, dual, solo, pic, sic, ground, picDuties, supervisedPIC, xc, xcDual, xcSolo, xcPIC, xcSIC
    case instrument, actual, simulated, night, nightDual, nightPIC, nightSIC, instructor
    case dayTakeoffs, nightTakeoffs, dayLandings, nightLandings
    case nightTakeoffsPIC, nightLandingsPIC, nightTakeoffsSIC, nightLandingsSIC
    case approaches, holds, flights, picFlights, dualFlights, aeroTows, groundLaunches, poweredLaunches
    var id: String { rawValue }
    var title: String {
        switch self {
        case .total: return "Total time"
        case .dual: return "Instruction received"
        case .solo: return "Solo"
        case .pic: return "PIC"
        case .sic: return "SIC"
        case .ground: return "Ground instruction"
        case .picDuties: return "PIC duties with instructor"
        case .supervisedPIC: return "Supervised PIC duties as SIC"
        case .xc: return "Cross-country"
        case .xcDual: return "Cross-country instruction received"
        case .xcSolo: return "Cross-country solo"
        case .xcPIC: return "PIC cross-country"
        case .xcSIC: return "SIC cross-country"
        case .instrument: return "Instrument"
        case .actual: return "Actual instrument"
        case .simulated: return "Simulated instrument"
        case .night: return "Night"
        case .nightDual: return "Night instruction received"
        case .nightPIC: return "Night PIC"
        case .nightSIC: return "Night SIC"
        case .instructor: return "Instructor"
        case .dayTakeoffs: return "Day takeoffs"
        case .nightTakeoffs: return "Night takeoffs"
        case .dayLandings: return "Day landings"
        case .nightLandings: return "Night landings"
        case .nightTakeoffsPIC: return "Night takeoffs PIC"
        case .nightLandingsPIC: return "Night landings PIC"
        case .nightTakeoffsSIC: return "Night takeoffs SIC"
        case .nightLandingsSIC: return "Night landings SIC"
        case .approaches: return "Instrument approaches"
        case .holds: return "Holds"
        case .flights: return "Number of flights"
        case .picFlights: return "PIC flights"
        case .dualFlights: return "Instructional flights"
        case .aeroTows: return "Aero-tows"
        case .groundLaunches: return "Ground launches"
        case .poweredLaunches: return "Powered launches"
        }
    }
    var iacraTitle: String {
        switch self {
        case .nightLandings: return "Night takeoffs and landings"
        case .nightLandingsPIC: return "Night takeoffs and landings PIC"
        case .nightLandingsSIC: return "Night takeoffs and landings SIC"
        default: return title
        }
    }
    var isCount: Bool {
        switch self {
        case .dayTakeoffs, .nightTakeoffs, .dayLandings, .nightLandings,
             .nightTakeoffsPIC, .nightLandingsPIC, .nightTakeoffsSIC, .nightLandingsSIC,
             .approaches, .holds, .flights, .picFlights, .dualFlights, .aeroTows, .groundLaunches, .poweredLaunches: return true
        default: return false
        }
    }
    static let optionalHours = ["sic", "solo", "ground", "picDuties", "supervisedPIC"]
    static let optionalCounts = ["dayTakeoffs", "nightTakeoffs", "numberFlights", "aeroTows", "groundLaunches", "poweredLaunches"]
    static let overlapMetrics: Set<String> = ["xcDual", "xcSolo", "xcPIC", "xcSIC", "nightDual", "nightPIC", "nightSIC", "nightTakeoffsPIC", "nightLandingsPIC", "nightTakeoffsSIC", "nightLandingsSIC"]
    func rawCredit(_ f: Flight) -> TimeCredit {
        if Self.overlapMetrics.contains(rawValue), let value = f.facts.amounts["credit_" + rawValue], value.isFinite, value >= 0 {
            let role: Double = rawValue.hasSuffix("SIC") ? f.sicTime : rawValue.hasSuffix("PIC") ? f.pic : self == .xcSolo ? f.soloTime : f.dual
            let cap: Double = isCount ? Double(f.nightLandings) : min(role, rawValue.hasPrefix("xc") ? f.crossCountry : f.night)
            let floor: Double = isCount ? (role + 0.001 >= f.total ? cap : 0) : max(0, role + (rawValue.hasPrefix("xc") ? f.crossCountry : f.night) - f.total)
            return TimeCredit(value: min(cap, value), estimated: value > cap + 0.001 || value + 0.001 < floor)
        }
        func event(_ count: Int, during time: Double) -> TimeCredit {
            guard time > 0, count > 0 else { return TimeCredit(value: 0) }
            return TimeCredit(value: Double(count), estimated: time + 0.001 < f.total)
        }
        func nightEvent(_ count: Int, role: FlightMetric, time: Double) -> TimeCredit {
            if time + 0.001 >= f.total { return event(count, during: time) }
            let night = role.rawCredit(f)
            if f.night > 0 && !night.estimated && night.value + 0.001 >= f.night { return TimeCredit(value: Double(max(0, count))) }
            return event(count, during: time)
        }
        let count = max(1, f.facts.counts["numberFlights", default: 1])
        switch self {
        case .total: return TimeCredit(value: f.total)
        case .dual: return TimeCredit(value: f.dual)
        case .solo: return TimeCredit(value: f.soloTime)
        case .pic: return TimeCredit(value: f.pic)
        case .sic: return TimeCredit(value: f.sicTime)
        case .ground: return TimeCredit(value: max(0, f.facts.amounts[rawValue, default: 0]))
        case .picDuties: return TimeCredit(value: DutyCredit.hours(f, supervised: false))
        case .supervisedPIC: return TimeCredit(value: DutyCredit.hours(f, supervised: true))
        case .xc: return TimeCredit(value: f.crossCountry)
        case .xcDual: return f.dualCrossCountry
        case .xcSolo: return f.overlap([f.crossCountry, f.soloTime])
        case .xcPIC: return f.picCrossCountry
        case .xcSIC: return f.overlap([f.crossCountry, f.sicTime])
        case .instrument: return TimeCredit(value: f.instrumentTime)
        case .actual: return TimeCredit(value: f.imc)
        case .simulated: return TimeCredit(value: f.simulatedInstrument)
        case .night: return TimeCredit(value: f.night)
        case .nightDual: return f.dualNight
        case .nightPIC: return f.overlap([f.night, f.pic])
        case .nightSIC: return f.overlap([f.night, f.sicTime])
        case .instructor: return TimeCredit(value: f.instructor)
        case .dayTakeoffs: return TimeCredit(value: Double(f.dayLandings))
        case .nightTakeoffs: return TimeCredit(value: Double(f.nightLandings))
        case .dayLandings: return TimeCredit(value: Double(f.dayLandings))
        case .nightLandings: return TimeCredit(value: Double(f.nightLandings))
        case .nightTakeoffsPIC: return nightEvent(f.nightLandings, role: .nightPIC, time: f.pic)
        case .nightLandingsPIC: return nightEvent(f.nightLandings, role: .nightPIC, time: f.pic)
        case .nightTakeoffsSIC: return nightEvent(f.nightLandings, role: .nightSIC, time: f.sicTime)
        case .nightLandingsSIC: return nightEvent(f.nightLandings, role: .nightSIC, time: f.sicTime)
        case .approaches: return TimeCredit(value: Double(f.approachCount))
        case .holds: return TimeCredit(value: Double(f.holds))
        case .flights: return TimeCredit(value: Double(count))
        case .picFlights: return event(count, during: f.pic)
        case .dualFlights: return event(count, during: f.dual)
        case .aeroTows, .groundLaunches, .poweredLaunches:
            return TimeCredit(value: Double(f.facts.counts[rawValue, default: 0]))
        }
    }
    func evidence(_ f: Flight) -> MilestoneEvidence? {
        let candidate = rawCredit(f)
        guard candidate.value.isFinite, candidate.value > 0 else { return nil }
        let statement = candidate.estimated ? "Partial overlap. Confirm \(title) credit." : ""
        let key = "time-v1|" + rawValue
        var credit = candidate
        var confirmed = false, excluded = false
        if candidate.estimated, let receipt = f.confirmations[key], receipt.matches(f, statement: statement) {
            confirmed = receipt.accepted; excluded = !receipt.accepted
            credit = TimeCredit(value: confirmed ? min(candidate.value, max(0, receipt.creditedValue)) : 0)
        }
        return MilestoneEvidence(flight: f, credit: credit, reason: "", potential: candidate.value,
            confirmationKey: key, statement: statement, confirmed: confirmed, excluded: excluded)
    }
    func credit(_ f: Flight) -> Double { evidence(f)?.credit.value ?? 0 }
}

enum ExperienceCategory: String, CaseIterable, Identifiable {
    case airplane = "Airplanes", rotorcraft = "Rotorcraft", poweredLift = "Powered lift", glider = "Gliders"
    case lighter = "Lighter than air", ffs = "FFS", ftd = "FTD", atd = "ATD"
    var id: String { rawValue }
    func includes(_ f: Flight) -> Bool {
        switch self {
        case .airplane: return f.isAirplane
        case .rotorcraft: return ["Rotorcraft", "Helicopter", "Gyroplane"].contains(f.category)
        case .poweredLift: return f.category == "Powered lift"
        case .glider: return f.category == "Glider"
        case .lighter: return ["Balloon", "Airship"].contains(f.category)
        case .ffs, .ftd, .atd: return f.category == rawValue
        }
    }
    static func matchesClass(_ f: Flight, _ name: String) -> Bool {
        let category = f.isDevice ? f.facts.text["representedClass", default: ""] : f.category
        if name == "Airplane single-engine" { return ["ASEL", "ASES"].contains(category) }
        if name == "Airplane multiengine" { return ["AMEL", "AMES"].contains(category) }
        return category == name
    }
    var metrics: [FlightMetric] {
        if [.ffs, .ftd, .atd].contains(self) { return [.total, .dual, .instrument] }
        var result: [FlightMetric] = [.total, .dual, .solo, .pic, .sic]
        if self != .glider { result += [.xcDual, .xcSolo, .xcPIC, .xcSIC] }
        if self != .glider { result += [.instrument] }
        if self != .glider { result += [.nightDual, .nightLandings, .nightPIC, .nightSIC, .nightLandingsPIC, .nightLandingsSIC] }
        if self == .glider || self == .lighter { result += [.picFlights, .dualFlights] }
        if self == .glider { result += [.aeroTows, .groundLaunches, .poweredLaunches] }
        return result
    }
}

struct TotalsFilter: Equatable {
    var dates: Set<String> = []
    var airports: Set<String> = []
    var aircraft: Set<String> = []
    var models: Set<String> = []
    var categories: Set<String> = []
    var aircraftFeatures: Set<String> = []
    var flightFeatures: Set<String> = []
    var requireAllAircraftFeatures = false
    var requireAllFlightFeatures = false
    var active: Bool { !dates.isEmpty || !airports.isEmpty || !aircraft.isEmpty || !models.isEmpty || !categories.isEmpty || !aircraftFeatures.isEmpty || !flightFeatures.isEmpty }
    func includes(_ f: Flight) -> Bool {
        if !dates.isEmpty {
            guard let day = f.flightDate, day <= Date() else { return false }
            let matches = dates.contains { period in
                if period == "This year" { return Calendar.current.isDate(day, equalTo: Date(), toGranularity: .year) }
                let cutoff = Calendar.current.date(byAdding: .day, value: period == "Last 30 days" ? -30 : -90, to: Date()) ?? Date()
                return day >= cutoff
            }
            if !matches { return false }
        }
        if !airports.isEmpty && Set(f.airports).isDisjoint(with: airports) { return false }
        if !aircraft.isEmpty && !aircraft.contains(f.registration) { return false }
        if !models.isEmpty && !models.contains(f.aircraftModel) { return false }
        if !categories.isEmpty && !categories.contains(f.category) { return false }
        let equipment = aircraftFeatures.compactMap(AircraftFeature.init(rawValue:))
        if !equipment.isEmpty {
            let matches = equipment.map { f.hasAircraftFeature($0) }
            if requireAllAircraftFeatures ? matches.contains(false) : !matches.contains(true) { return false }
        }
        if !flightFeatures.isEmpty {
            let matches = flightFeatures.map { key -> Bool in
                if key == "tracking" { return f.tracking }
                if ["flightReview", "checkride"].contains(key) { return f.facts.has(key) }
                return FlightMetric(rawValue: key).map { $0.credit(f) > 0 } ?? false
            }
            if requireAllFlightFeatures ? matches.contains(false) : !matches.contains(true) { return false }
        }
        return true
    }
}

struct ExperienceSelection: Identifiable { let metric: FlightMetric; var className: String? = nil; var id: String { metric.id + "|" + (className ?? "") } }
