// Checkride and training-path domain: progress metrics, goals, time
// credits, route geometry, milestone evidence, training paths and rules,
// duty/approval credits, ground-course records, simulator credit, the
// credit engine, and flight-review rules.
import Foundation

enum ProgressMetric {
    static let fields: [(key: String, title: String)] = [
        ("solo", "Solo"), ("xcPIC", "Qualifying cross-country PIC"), ("xcDual", "Cross-country training received"),
        ("nightDual", "Night training received"), ("instrumentDual", "Instrument training received"),
        ("cfii", "Instrument training with a CFII"), ("prep", "Practical-test preparation with instructor")
    ]
}

enum CheckrideGoal: String, CaseIterable, Identifiable {
    case sport = "Sport Pilot", recreational = "Recreational Pilot", privatePilot = "Private Pilot", instrument = "Instrument Rating", commercial = "Commercial Pilot", atp = "ATP"
    var id: String { rawValue }
    var subtitle: String { "Choose category, class and training path" }
    var regulation: String {
        switch self {
        case .sport: return "61.313"
        case .recreational: return "61.99"
        case .privatePilot: return "61.109"
        case .instrument: return "61.65"
        case .commercial: return "61.129"
        case .atp: return "61.159"
        }
    }
}

// MARK: - Shared logbook calculations

struct TimeCredit {
    var value: Double
    var estimated = false
}

extension Flight {
    var isAirplane: Bool { ["ASEL", "ASES", "AMEL", "AMES"].contains(category) }
    var isSingleEngine: Bool { category == "ASEL" || category == "ASES" }
    var instrumentTime: Double { min(total, max(0, imc + simulatedInstrument)) }
    var soloTime: Double {
        if facts.has("soloPIC") { return min(max(0, total), max(0, pic)) }
        let logged = facts.has("solo") ? total : min(total, max(0, facts.amounts["solo"] ?? progress["solo", default: 0]))
        if logged > 0 { return logged }
        if let receipt = confirmations["time-v1|solo"], receipt.accepted, receipt.matches(self, statement: "Confirm solo credit.") {
            return min(total, max(0, receipt.creditedValue))
        }
        return 0
    }
    func overlap(_ values: [Double]) -> TimeCredit {
        let times = values.map { max(0, min(total, $0)) }
        let upper = times.min() ?? 0
        let lower = max(0, times.reduce(0, +) - Double(max(0, times.count - 1)) * total)
        return TimeCredit(value: upper, estimated: upper - lower > 0.001 && !facts.has("overlapsConfirmed"))
    }
    func union(_ values: [Double]) -> TimeCredit {
        let times = values.map { max(0, min(total, $0)) }
        let upper = min(total, times.reduce(0, +)), lower = times.max() ?? 0
        return TimeCredit(value: upper, estimated: upper - lower > 0.001)
    }
    var picCrossCountry: TimeCredit { overlap([pic, crossCountry]) }
    var dualCrossCountry: TimeCredit { overlap([dual, crossCountry]) }
    var dualNight: TimeCredit { overlap([dual, night]) }
    var dualInstrument: TimeCredit { overlap([dual, instrumentTime]) }
    var cfiiInstrument: TimeCredit {
        if facts.has("cfii") { return dualInstrument }
        return TimeCredit(value: min(dualInstrument.value, max(0, progress["cfii", default: 0])))
    }
}

enum RouteGeometry {
    static func distance(_ a: AirportInfo, _ b: AirportInfo) -> Double {
        let rad = Double.pi / 180
        let lat = (b.latitude - a.latitude) * rad
        let lon = (b.longitude - a.longitude) * rad
        let h = pow(sin(lat / 2), 2) + cos(a.latitude * rad) * cos(b.latitude * rad) * pow(sin(lon / 2), 2)
        return 3440.065 * 2 * asin(sqrt(min(1, max(0, h))))
    }
    static func legs(_ flight: Flight, airports: [String: AirportInfo]) -> [Double]? {
        let codes = flight.airports
        guard codes.count >= 2, codes.allSatisfy({ airports[$0] != nil }) else { return nil }
        return zip(codes, codes.dropFirst()).map { distance(airports[$0.0]!, airports[$0.1]!) }
    }
    static func farthest(_ flight: Flight, airports: [String: AirportInfo], codes: [String]? = nil) -> Double? {
        guard let first = flight.airports.first, let origin = airports[first] else { return nil }
        let points = codes ?? Array(flight.airports.dropFirst())
        guard !points.isEmpty, points.allSatisfy({ airports[$0] != nil }) else { return nil }
        return points.map { distance(origin, airports[$0]!) }.max()
    }
}

struct MilestoneEvidence: Identifiable {
    var flight: Flight
    var credit: TimeCredit
    var reason: String
    var potential: Double
    var confirmationKey: String
    var statement: String
    var confirmed = false
    var excluded = false
    var needsConfirmation: Bool { !statement.isEmpty }
    var id: UUID { flight.id }
}

struct CheckrideMilestone: Identifiable {
    var title: String
    var citation: String
    var requirement: String
    var target: Double
    var unit: String
    var evidence: [MilestoneEvidence]
    var groundCredit = 0.0
    var id: String { citation + title }
    var value: Double { unit == "flight" ? min(1, sum) : sum }
    private var sum: Double { groundCredit + evidence.reduce(0) { $0 + $1.credit.value } }
    var verified: Double { unit == "flight" ? min(1, verifiedSum) : verifiedSum }
    private var verifiedSum: Double { groundCredit + evidence.filter { !$0.credit.estimated }.reduce(0) { $0 + $1.credit.value } }
    var met: Bool { verified + 0.0001 >= target }
    var hasEstimate: Bool { evidence.contains { $0.credit.estimated && $0.credit.value > 0 } }
    var progressText: String { unit == "hr" ? "\(hours(value)) / \(hours(target)) hr" : "\(Int(value)) / \(Int(target)) \(unit)" }
}

struct TrainingPath: Codable, Identifiable, Hashable {
    var id: String
    var goal: String
    var part: String
    var category: String
    var title: String
    var qualification: String = ""
    var rules: [TrainingRule]
    static func == (lhs: TrainingPath, rhs: TrainingPath) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
struct TrainingRule: Codable, Identifiable {
    var id: String
    var title: String
    var citation: String
    var target: Double
    var unit: String
    var metric: String
    var scope: String
    var condition: String = ""
    var recentDays: Int = 0
    var recentMonths: Bool = false
    var minimum: Double = 0
    var night: String = ""
    var landings: Int = 0
    var distance: Double = 0
    var farthest: Double = 0
    var longest: Double = 0
    var points: Int = 0
    var approaches: Int = 0
    var alternateMetric: String = ""
    var alternateTarget: Double = 0
}

enum DutyCredit {
    static func key(_ supervised: Bool) -> String { supervised ? "duties-v1|supervisedPIC" : "duties-v1|picDuties" }
    static func statement(_ supervised: Bool) -> String {
        supervised ? "Confirm supervised PIC duties while serving as SIC." : "Confirm PIC duties with an authorized instructor."
    }
    static func limit(_ f: Flight, supervised: Bool) -> Double { supervised ? min(f.total, f.sicTime) : f.total }
    static func receipt(_ f: Flight, supervised: Bool) -> MilestoneConfirmation? {
        f.confirmations[key(supervised)].flatMap { $0.matches(f, statement: statement(supervised)) ? $0 : nil }
    }
    static func hours(_ f: Flight, supervised: Bool) -> Double {
        if let receipt = receipt(f, supervised: supervised) {
            return receipt.accepted ? min(limit(f, supervised: supervised), max(0, receipt.creditedValue)) : 0
        }
        // Retain qualifying amounts from earlier versions and CSV imports.
        return min(f.total, max(0, f.facts.amounts[supervised ? "supervisedPIC" : "picDuties", default: 0]))
    }
}

struct CourseGroundRecord: Identifiable, Codable {
    var id = UUID()
    var pathID: String
    var date: Date
    var hours: Double
    var notes: String
}
@MainActor final class CourseGroundStore: ObservableObject {
    static let shared = CourseGroundStore()
    @Published private(set) var records: [CourseGroundRecord] = []
    @Published private(set) var error = ""
    private var readable = true
    private let key = "course-ground-records-v1"
    init() {
        if let data = UserDefaults.standard.data(forKey: key) {
            do { records = try JSONDecoder().decode([CourseGroundRecord].self, from: data) }
            catch { readable = false; self.error = "Saved ground instruction could not be read. It has been retained." }
        }
    }
    func save(_ record: CourseGroundRecord) -> Bool {
        guard readable, record.hours.isFinite, record.hours > 0, record.date <= Date(), !record.pathID.isEmpty else { return false }
        return persist((records.filter { $0.id != record.id } + [record]).sorted { $0.date > $1.date })
    }
    func delete(_ record: CourseGroundRecord) { if readable { _ = persist(records.filter { $0.id != record.id }) } }
    private func persist(_ next: [CourseGroundRecord]) -> Bool {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(next), forKey: key)
            records = next; error = ""; return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

// Device entries stay separate from aircraft flight time. Only approved,
// instructor-provided training is considered for certificate hour credit.
// Reference: §§61.65(h)-(j), 61.109(k), 61.129(i), 61.159(a), Part 141 appendices.
enum SimulatorCredit {
    struct Allowance {
        var combined: Double
        var ffs: Double
        var ftd: Double
        var atd: Double
        var basicATD: Double
        var nonFFS: Double? = nil
    }
    static func matches(_ f: Flight, path: TrainingPath, rule: TrainingRule) -> Bool {
        let represented = f.facts.text["representedClass", default: ""]
        if path.category == "Airplanes" { return ["ASEL", "ASES", "AMEL", "AMES"].contains(represented) }
        if path.goal == "ATP", !rule.citation.contains("141"), ["ASEL", "ASES", "AMEL", "AMES"].contains(path.category),
           rule.scope == "all" || rule.metric == "instrument" {
            return ["ASEL", "ASES", "AMEL", "AMES"].contains(represented)
        }
        return represented == path.category
    }
    static func allowance(_ rule: TrainingRule, path: TrainingPath) -> Allowance? {
        // No device credit for aircraft-only operations, solo/PIC, XC, night,
        // landings, recent flight-test preparation, or single-flight milestones.
        guard rule.unit == "hr", !rule.recentMonths, rule.recentDays == 0,
              ["total", "dual", "instrument", "dualInstrument", "hoodDual"].contains(rule.metric) else { return nil }
        if rule.title.localizedCaseInsensitiveContains("in flight") || rule.title.localizedCaseInsensitiveContains("in-flight") { return nil }
        // These subrequirements explicitly call for time in the aircraft.
        if rule.metric == "hoodDual", rule.scope == "class", ["ASEL", "ASES", "AMEL", "AMES", "Powered lift"].contains(path.category) { return nil }
        if path.goal == "Private Pilot", rule.metric == "dualInstrument", !rule.citation.contains("Appendix M") { return nil }
        if path.goal == "Commercial Pilot", rule.metric == "hoodDual", ["Helicopter", "Gyroplane"].contains(path.category) {
            let cap = path.category == "Helicopter" ? 5.0 : 2.5
            return Allowance(combined: cap, ffs: cap, ftd: cap, atd: cap, basicATD: cap)
        }
        if path.part == "Part 141", rule.citation.contains("141") {
            let basis = path.rules.first { $0.metric == "total" && $0.scope == "class" }?.target ??
                path.rules.first { $0.metric == (path.goal == "Instrument Rating" && !rule.citation.contains("Appendix M") ? "dualInstrument" : "dual") && $0.scope == "class" }?.target ?? 0
            guard basis > 0 else { return nil }
            if rule.citation.contains("Appendix I") {
                return Allowance(combined: basis * 0.10, ffs: basis * 0.10, ftd: basis * 0.05, atd: 0, basicATD: 0)
            }
            if rule.citation.contains("Appendix M") {
                return Allowance(combined: basis * 0.35, ffs: basis * 0.35, ftd: basis * 0.25,
                                 atd: basis * 0.25, basicATD: basis * 0.25, nonFFS: basis * 0.25)
            }
            if path.goal == "Commercial Pilot", rule.metric == "hoodDual", rule.scope == "all" {
                return Allowance(combined: 5, ffs: 5, ftd: 5, atd: 0, basicATD: 0)
            }
            switch path.goal {
            case "Private Pilot": return Allowance(combined: basis * 0.20, ffs: basis * 0.20, ftd: basis * 0.15, atd: 0, basicATD: 0)
            case "Instrument Rating": return Allowance(combined: basis * 0.50, ffs: basis * 0.50, ftd: basis * 0.40,
                                                        atd: basis * 0.40, basicATD: basis * 0.25, nonFFS: basis * 0.40)
            case "Commercial Pilot": return Allowance(combined: basis * 0.30, ffs: basis * 0.30, ftd: basis * 0.20, atd: 0, basicATD: 0)
            case "ATP": return Allowance(combined: basis * 0.50, ffs: basis * 0.50, ftd: basis * 0.25, atd: 0, basicATD: 0)
            default: return nil
            }
        }
        switch path.goal {
        case "Private Pilot":
            guard rule.metric == "total" else { return nil }
            return Allowance(combined: 2.5, ffs: 2.5, ftd: 2.5, atd: 0, basicATD: 0)
        case "Instrument Rating":
            guard ["instrument", "dualInstrument"].contains(rule.metric) else { return nil }
            return Allowance(combined: 20, ffs: 20, ftd: 20, atd: 20, basicATD: 10)
        case "Commercial Pilot":
            if rule.metric == "hoodDual", rule.scope == "all" {
                return Allowance(combined: 5, ffs: 5, ftd: 5, atd: 0, basicATD: 0)
            }
            guard rule.metric == "total", rule.scope == "all", ["ASEL", "ASES", "AMEL", "AMES", "Powered lift", "Helicopter"].contains(path.category) else { return nil }
            let limit = path.category == "Helicopter" ? 25.0 : 50.0
            return Allowance(combined: limit, ffs: limit, ftd: limit, atd: 0, basicATD: 0)
        case "ATP":
            if ["Helicopter", "Powered lift"].contains(path.category), rule.metric == "instrument" {
                return Allowance(combined: 25, ffs: 25, ftd: 25, atd: 0, basicATD: 0)
            }
            if path.category == "Powered lift", rule.metric == "total", rule.scope == "all" {
                return Allowance(combined: 100, ffs: 100, ftd: 100, atd: 0, basicATD: 0)
            }
            guard ["ASEL", "ASES", "AMEL", "AMES"].contains(path.category) else { return nil }
            if rule.metric == "total", rule.scope == "class" { return Allowance(combined: 25, ffs: 25, ftd: 0, atd: 0, basicATD: 0) }
            if rule.metric == "total", rule.scope == "all" { return Allowance(combined: 100, ffs: 100, ftd: 100, atd: 0, basicATD: 0) }
            if rule.metric == "instrument" { return Allowance(combined: 25, ffs: 25, ftd: 25, atd: 0, basicATD: 0) }
            return nil
        default: return nil
        }
    }
    static func evidence(rule: TrainingRule, path: TrainingPath, flights: [Flight]) -> [MilestoneEvidence] {
        guard var limits = allowance(rule, path: path) else { return [] }
        let permitted = flights.filter { f in
            guard f.isDevice, f.facts.has("deviceApproved"), f.dual > 0, matches(f, path: path, rule: rule) else { return false }
            let program = f.facts.text["deviceProgram", default: "Part 61"]
            if path.part == "Part 141", rule.citation.contains("141") { return program == "Part 141" }
            if path.goal == "ATP", rule.metric == "total" {
                return path.category == "Powered lift" ? program == "Part 142" : ["Part 121", "Part 135", "Part 141", "Part 142"].contains(program)
            }
            return true
        }
        if !rule.citation.contains("141"), !permitted.isEmpty, permitted.allSatisfy({ $0.facts.text["deviceProgram"] == "Part 142" }) {
            switch path.goal {
            case "Private Pilot": limits = Allowance(combined: 5, ffs: 5, ftd: 5, atd: 0, basicATD: 0)
            case "Instrument Rating": limits = Allowance(combined: 30, ffs: 30, ftd: 30, atd: 20, basicATD: 10)
            case "Commercial Pilot" where rule.metric == "total":
                let cap = path.category == "Helicopter" ? 50.0 : 100.0
                limits = Allowance(combined: cap, ffs: cap, ftd: cap, atd: 0, basicATD: 0)
            case "ATP": if rule.metric == "instrument" { limits = Allowance(combined: 50, ffs: 50, ftd: 50, atd: 0, basicATD: 0) }
            default: break
            }
        }
        var used = 0.0, byKind: [String: Double] = [:], basicUsed = 0.0, nonFFSUsed = 0.0
        return permitted.compactMap { f in
            let cap = f.category == "FFS" ? limits.ffs : f.category == "FTD" ? limits.ftd : limits.atd
            var available = min(limits.combined - used, cap - byKind[f.category, default: 0])
            if f.category != "FFS", let nonFFS = limits.nonFFS { available = min(available, nonFFS - nonFFSUsed) }
            if f.category == "ATD", f.facts.text["atdType"] != "AATD" { available = min(available, limits.basicATD - basicUsed) }
            let candidate = ["instrument", "dualInstrument", "hoodDual"].contains(rule.metric) ? f.dualInstrument : TimeCredit(value: f.dual)
            let potential = min(max(0, available), candidate.value)
            guard potential > 0 else { return nil }
            let condition = rule.condition.contains("CFII") && f.facts.has("cfii") ? "" : rule.condition
            let text = !condition.isEmpty ? condition : candidate.estimated ? "Partial overlap. Confirm simulator instruction credit." : ""
            let key = "device-v1|" + path.id + "|" + rule.id
            var credit = TimeCredit(value: potential, estimated: !text.isEmpty), confirmed = false, excluded = false
            if !text.isEmpty, let receipt = f.confirmations[key], receipt.matches(f, statement: text) {
                confirmed = receipt.accepted; excluded = !receipt.accepted
                credit = TimeCredit(value: confirmed ? min(potential, max(0, receipt.creditedValue)) : 0)
            }
            used += credit.value; byKind[f.category, default: 0] += credit.value
            if f.category != "FFS" { nonFFSUsed += credit.value }
            if f.category == "ATD", f.facts.text["atdType"] != "AATD" { basicUsed += credit.value }
            return MilestoneEvidence(flight: f, credit: credit, reason: "Approved device training · within device limit", potential: potential,
                                     confirmationKey: key, statement: text, confirmed: confirmed, excluded: excluded)
        }
    }
}

enum TrainingEngine {
    static func categoryMatches(_ flight: Flight, _ category: String) -> Bool {
        if category == "Airplanes" { return flight.isAirplane }
        if category.hasPrefix("Balloon") { return flight.category == "Balloon" }
        return flight.category == category
    }
    static func milestones(path: TrainingPath, flights: [Flight], airports: [String: AirportInfo],
                           commercialPath: String = "Solo", now: Date = Date(), ground: [CourseGroundRecord] = []) -> [CheckrideMilestone] {
        let logged = flights.filter { ($0.flightDate ?? .distantFuture) <= now }
        let currentClass = logged.filter { categoryMatches($0, path.category) }
        func scoped(_ rule: TrainingRule) -> [Flight] {
            var list: [Flight]
            switch rule.scope {
            case "all": list = logged.filter { !$0.isDevice }
            case "powered": list = logged.filter(\.isPowered)
            case "airplane": list = logged.filter(\.isAirplane)
            case "heavier": list = logged.filter { !$0.isDevice && !["Balloon", "Airship"].contains($0.category) }
            default: list = currentClass
            }
            if rule.recentDays > 0 {
                let cutoff = Calendar.current.date(byAdding: .day, value: -rule.recentDays, to: now) ?? now
                list = list.filter { ($0.flightDate ?? .distantPast) >= cutoff }
            } else if rule.recentMonths {
                let month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: now)) ?? now
                let cutoff = Calendar.current.date(byAdding: .month, value: -2, to: month) ?? now
                list = list.filter { ($0.flightDate ?? .distantPast) >= cutoff }
            }
            return list
        }
        func candidate(_ rule: TrainingRule, _ f: Flight) -> TimeCredit {
            let duties = DutyCredit.hours(f, supervised: false)
            let commandCredit = f.union([f.pic, DutyCredit.hours(f, supervised: true)])
                        let dutiesCredit = f.union([f.pic, duties])
            func intersection(_ credit: TimeCredit, _ hours: Double) -> TimeCredit {
                let overlap = f.overlap([credit.value, hours])
                return TimeCredit(value: overlap.value, estimated: overlap.estimated || (credit.estimated && overlap.value > 0))
            }
            let solo = f.soloTime > 0 ? TimeCredit(value: f.soloTime) :
                TimeCredit(value: f.dual <= 0 && f.sicTime <= 0 ? max(0, f.total) : 0, estimated: true)
            let dutiesPath = path.category == "Airship" || (path.goal == "Commercial Pilot" && commercialPath == "Instructor")
            let pathHours = dutiesPath ? duties : solo.value
            switch rule.metric {
            case "ground": return TimeCredit(value: max(0, f.facts.amounts["ground", default: 0]))
            case "dualInstrument": return f.dualInstrument
            case "commandInstrument": return intersection(commandCredit, f.instrumentTime)
            case "solo": return solo
            case "xcSolo":
                let credit = f.overlap([solo.value, f.crossCountry])
                return TimeCredit(value: credit.value, estimated: solo.estimated || credit.estimated)
            case "hoodDual": return f.overlap([f.dual, f.simulatedInstrument])
            case "command": return commandCredit
            case "commandXC": return intersection(commandCredit, f.crossCountry)
            case "commandNight": return intersection(commandCredit, f.night)
            case "duties": return TimeCredit(value: duties)
            case "dutiesXC": return f.overlap([duties, f.crossCountry])
            case "dutiesNight": return f.overlap([duties, f.night])
            case "picOrDuties": return dutiesCredit
            case "picOrDutiesXC": return intersection(dutiesCredit, f.crossCountry)
            case "picOrDutiesNight": return intersection(dutiesCredit, f.night)
            case "path": return TimeCredit(value: pathHours, estimated: !dutiesPath && solo.estimated)
            case "pathNight":
                let credit = f.overlap([pathHours, f.night])
                return TimeCredit(value: credit.value, estimated: credit.estimated || (!dutiesPath && solo.estimated))
            case "complexTurbineDual": return TimeCredit(value: f.hasAircraftFeature(.complex) || f.hasAircraftFeature(.turbine) ? f.dual : 0)
            case "advancedDual":
                let isMulti = ["AMEL", "AMES"].contains(path.category)
                return TimeCredit(value: f.hasAircraftFeature(.complex) || f.hasAircraftFeature(.turbine) || (!isMulti && f.hasAircraftFeature(.taa)) ? f.dual : 0)
            case "soloFlights":
                guard solo.value > 0 else { return TimeCredit(value: 0) }
                return TimeCredit(value: FlightMetric.flights.rawCredit(f).value, estimated: solo.estimated || solo.value + 0.001 < f.total)
            case "pathTakeoffs", "pathLandings":
                if pathHours <= 0 || (rule.night == "night" && f.night <= 0) { return TimeCredit(value: 0) }
                let count = rule.night == "night" ? f.nightLandings : f.landings
                return TimeCredit(value: Double(count))
            case "takeoffs", "landings", "dutiesTakeoffs", "dutiesLandings", "dualTakeoffs", "dualLandings":
                let needsDual = rule.metric.hasPrefix("dual"), needsDuties = rule.metric.hasPrefix("duties")
                guard (!needsDual || f.dual > 0), (!needsDuties || duties > 0), rule.night != "night" || f.night > 0 else { return TimeCredit(value: 0) }
                let count = rule.night == "night" ? f.nightLandings : f.landings
                return TimeCredit(value: Double(count))
            case "special":
                guard f.total + 0.001 >= rule.minimum, f.landings >= rule.landings, f.approachCount >= rule.approaches else { return TimeCredit(value: 0) }
                if rule.night == "night" && f.night + 0.001 < rule.minimum { return TimeCredit(value: 0) }
                if rule.night == "day" && f.total - f.night + 0.001 < rule.minimum { return TimeCredit(value: 0) }
                let context = rule.scope
                let requiredTime = context == "solo" ? solo.value : context == "path" ? pathHours : context == "duties" ? duties : context == "dual" ? f.dual : f.total
                if requiredTime <= 0 || requiredTime + 0.001 < rule.minimum { return TimeCredit(value: 0) }
                if rule.night == "night" && f.overlap([requiredTime, f.night]).value + 0.001 < rule.minimum { return TimeCredit(value: 0) }
                if rule.night == "day" && f.overlap([requiredTime, f.total - f.night]).value + 0.001 < rule.minimum { return TimeCredit(value: 0) }
                if rule.points > 0 && Set(f.airports).count < rule.points { return TimeCredit(value: 0) }
                if rule.farthest > 0, let far = RouteGeometry.farthest(f, airports: airports), far + 0.001 < rule.farthest { return TimeCredit(value: 0) }
                if rule.longest > 0, let legs = RouteGeometry.legs(f, airports: airports), (legs.max() ?? 0) + 0.001 < rule.longest { return TimeCredit(value: 0) }
                return TimeCredit(value: Double(max(1, f.facts.counts["numberFlights", default: 1])))
            default:
                if path.goal == "Commercial Pilot", commercialPath == "Instructor" {
                    if rule.metric == "pic" { return dutiesCredit }
                    if rule.metric == "xcPIC" { return intersection(dutiesCredit, f.crossCountry) }
                }
                return FlightMetric(rawValue: rule.metric)?.rawCredit(f) ?? TimeCredit(value: 0)
            }
        }
        return path.rules.map { configured in
            var rule = configured
            // Alternatives are evaluated independently; never add fractions from
            // an hours option to fractions from a flight-count option.
            if !rule.alternateMetric.isEmpty, rule.alternateTarget > 0 {
                var alternate = rule; alternate.metric = rule.alternateMetric; alternate.target = rule.alternateTarget; alternate.unit = "flights"
                let ordinaryFraction = scoped(rule).reduce(0) { $0 + candidate(rule, $1).value } / max(0.001, rule.target)
                let alternateFraction = scoped(alternate).reduce(0) { $0 + candidate(alternate, $1).value } / alternate.target
                if alternateFraction > ordinaryFraction { rule = alternate }
            }
            var entries = scoped(rule).compactMap { f -> MilestoneEvidence? in
                let potential = candidate(rule, f)
                guard potential.value.isFinite, potential.value > 0 else { return nil }
                let condition = rule.condition.contains("CFII") && f.facts.has("cfii") ? "" : rule.condition
                let statement = !condition.isEmpty ? condition :
                    potential.estimated ? ((["solo", "soloFlights", "xcSolo", "path", "pathNight"].contains(rule.metric) && f.soloTime == 0) ? "Confirm solo credit." : "Partial overlap. Confirm \(rule.title) credit.") : ""
                let dutiesAllowance = path.goal == "Commercial Pilot" && commercialPath == "Instructor" && ["pic", "xcPIC"].contains(rule.metric)
                let sharedMetric = dutiesAllowance ? nil : FlightMetric(rawValue: rule.metric)
                let key = condition.isEmpty && sharedMetric != nil ?
                    "time-v1|" + rule.metric : "training-v2|" + path.id + "|" + rule.id + "|" + commercialPath
                let confirmationText = condition.isEmpty && potential.estimated && sharedMetric != nil && statement != "Confirm solo credit." ?
                    "Partial overlap. Confirm \(sharedMetric!.title) credit." : statement
                var credit = TimeCredit(value: potential.value, estimated: !confirmationText.isEmpty)
                var confirmed = false, excluded = false
                if !confirmationText.isEmpty, let receipt = f.confirmations[key], receipt.matches(f, statement: confirmationText) {
                    confirmed = receipt.accepted; excluded = !receipt.accepted
                    credit = TimeCredit(value: confirmed ? min(potential.value, max(0, receipt.creditedValue)) : 0)
                }
                let reason = rule.metric == "special" ? rule.title : ""
                return MilestoneEvidence(flight: f, credit: credit, reason: reason, potential: potential.value,
                    confirmationKey: key, statement: confirmationText, confirmed: confirmed, excluded: excluded)
            }
            entries += SimulatorCredit.evidence(rule: rule, path: path, flights: logged)
            let groundHours = rule.metric == "ground" ? ground.filter { $0.pathID == path.id && $0.date <= now }.reduce(0) { $0 + max(0, $1.hours) } : 0
            return CheckrideMilestone(title: rule.title, citation: rule.citation,
                requirement: "\(rule.target == rule.target.rounded() ? String(Int(rule.target)) : hours(rule.target)) \(rule.unit)" +
                    (rule.condition.isEmpty ? "" : " · " + rule.condition),
                target: rule.target, unit: rule.unit, evidence: entries, groundCredit: groundHours)
        }
    }
}

nonisolated enum FlightReviewRules {
    static func endExclusive(_ date: Date, calendar: Calendar = .current) -> Date? {
        guard let month = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else { return nil }
        return calendar.date(byAdding: .month, value: 25, to: month)
    }
    static func qualifies(_ flight: Flight) -> Bool {
        if flight.facts.has("checkride") && flight.facts.has("checkridePassed") { return true }
        return flight.facts.has("flightReview")
    }
}
