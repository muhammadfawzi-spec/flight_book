// The central log-entry model: Flight (time splits, route, category flags,
// import/review state), its FlightFacts side data, and the small extension
// helpers used by the UI, stats and training screens.
import Foundation
import CryptoKit

struct FlightFacts: Codable {
    var flags: Set<String> = []
    var counts: [String: Int] = [:]
    var amounts: [String: Double] = [:]
    var text: [String: String] = [:]
    nonisolated func has(_ key: String) -> Bool { flags.contains(key) }
}

struct Flight: Identifiable, Codable {
    var id = UUID()
    var route = ""
    var date = ""
    var aircraft = ""
    var duration = "0.0"
    var dayLandings = 0
    var nightLandings = 0
    var pic = 0.0
    var night = 0.0
    var imc = 0.0
    var simulatedInstrument = 0.0
    var dual = 0.0
    var instructor = 0.0
    var crossCountry = 0.0
    var approaches = ""
    var approachCount = 0
    var holds = 0
    var tracking = false
    var notes = ""
    var category = "Unspecified"
    var progress: [String: Double] = [:]
    var complex = false
    var highPerformance = false
    var taa = false
    var facts = FlightFacts()
    var legacyPhotoKey: String?
    var signature: InstructorSignature?
    var confirmations: [String: MilestoneConfirmation] = [:]

    var landings: Int { dayLandings + nightLandings }
    var total: Double { number(duration) }
    var flightDate: Date? { FlightDates.parse(date) }
    var shortDate: String { flightDate.map { FlightDates.string($0, format: "M/d/yy") } ?? date }
    var registration: String { AircraftNames.registration(aircraft.components(separatedBy: "·").first ?? aircraft) }
    var aircraftModel: String {
        AircraftNames.display(aircraft.components(separatedBy: "·").dropFirst().joined(separator: "·"))
    }
    // A stable snapshot binds signatures and confirmations to the reviewed record.
    // Photos and confirmation receipts are not part of the signed flight entry.
    var recordSnapshot: Data {
        var copy = self
        copy.signature = nil; copy.confirmations = [:]; copy.legacyPhotoKey = nil
        copy.aircraft = registration + " · " + aircraftModel
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        // Sets do not have deterministic encoding order. Store their sorted form in a separate envelope.
        let flags = copy.facts.flags.sorted(); copy.facts.flags = []
        let payload = (try? encoder.encode(copy)) ?? Data()
        struct Envelope: Encodable { var schema: Int; var record: Data; var flags: [String] }
        return (try? encoder.encode(Envelope(schema: 1, record: payload, flags: flags))) ?? Data()
    }
    var recordDigest: String { SHA256.hash(data: recordSnapshot).map { String(format: "%02x", $0) }.joined() }
    var validSignature: InstructorSignature? { signature.flatMap { $0.matches(self) ? $0 : nil } }
    var airports: [String] { AirportRoute.codes(route) }
    var photoKey: String { id.uuidString }

    enum CodingKeys: String, CodingKey {
        case id, route, date, aircraft, duration, landings, dayLandings, nightLandings
        case pic, night, imc, simulatedInstrument, dual, instructor, crossCountry
        case approaches, approachCount, holds, tracking, notes, category
        case complex, highPerformance, taa, legacyPhotoKey, progress, facts, signature, confirmations
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        route = try c.decode(String.self, forKey: .route)
        date = try c.decode(String.self, forKey: .date)
        aircraft = try c.decode(String.self, forKey: .aircraft)
        duration = try c.decode(String.self, forKey: .duration)
        nightLandings = try c.decodeIfPresent(Int.self, forKey: .nightLandings) ?? 0
        dayLandings = try c.decodeIfPresent(Int.self, forKey: .dayLandings)
            ?? max(0, (try c.decodeIfPresent(Int.self, forKey: .landings) ?? 0) - nightLandings)
        pic = try c.decodeIfPresent(Double.self, forKey: .pic) ?? 0
        night = try c.decodeIfPresent(Double.self, forKey: .night) ?? 0
        imc = try c.decodeIfPresent(Double.self, forKey: .imc) ?? 0
        simulatedInstrument = try c.decodeIfPresent(Double.self, forKey: .simulatedInstrument) ?? 0
        dual = try c.decodeIfPresent(Double.self, forKey: .dual) ?? 0
        instructor = try c.decodeIfPresent(Double.self, forKey: .instructor) ?? 0
        crossCountry = try c.decodeIfPresent(Double.self, forKey: .crossCountry) ?? 0
        approaches = try c.decodeIfPresent(String.self, forKey: .approaches) ?? ""
        approachCount = try c.decodeIfPresent(Int.self, forKey: .approachCount) ?? 0
        holds = try c.decodeIfPresent(Int.self, forKey: .holds) ?? 0
        tracking = try c.decodeIfPresent(Bool.self, forKey: .tracking) ?? false
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "ASEL"
        progress = try c.decodeIfPresent([String: Double].self, forKey: .progress) ?? [:]
        complex = try c.decodeIfPresent(Bool.self, forKey: .complex) ?? false
        highPerformance = try c.decodeIfPresent(Bool.self, forKey: .highPerformance) ?? false
        taa = try c.decodeIfPresent(Bool.self, forKey: .taa) ?? false
        facts = try c.decodeIfPresent(FlightFacts.self, forKey: .facts) ?? FlightFacts()
        signature = try c.decodeIfPresent(InstructorSignature.self, forKey: .signature)
        confirmations = try c.decodeIfPresent([String: MilestoneConfirmation].self, forKey: .confirmations) ?? [:]
        legacyPhotoKey = try c.decodeIfPresent(String.self, forKey: .legacyPhotoKey)
            ?? "\(route)-\(date)-\(aircraft)"
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(route, forKey: .route)
        try c.encode(date, forKey: .date)
        try c.encode(aircraft, forKey: .aircraft)
        try c.encode(duration, forKey: .duration)
        try c.encode(landings, forKey: .landings)
        try c.encode(dayLandings, forKey: .dayLandings)
        try c.encode(nightLandings, forKey: .nightLandings)
        try c.encode(pic, forKey: .pic)
        try c.encode(night, forKey: .night)
        try c.encode(imc, forKey: .imc)
        try c.encode(simulatedInstrument, forKey: .simulatedInstrument)
        try c.encode(dual, forKey: .dual)
        try c.encode(instructor, forKey: .instructor)
        try c.encode(crossCountry, forKey: .crossCountry)
        try c.encode(approaches, forKey: .approaches)
        try c.encode(approachCount, forKey: .approachCount)
        try c.encode(holds, forKey: .holds)
        try c.encode(tracking, forKey: .tracking)
        try c.encode(notes, forKey: .notes)
        try c.encode(category, forKey: .category)
        try c.encode(progress, forKey: .progress)
        try c.encode(complex, forKey: .complex)
        try c.encode(highPerformance, forKey: .highPerformance)
        try c.encode(taa, forKey: .taa)
        try c.encode(facts, forKey: .facts)
        try c.encodeIfPresent(legacyPhotoKey, forKey: .legacyPhotoKey)
        try c.encodeIfPresent(signature, forKey: .signature)
        try c.encode(confirmations, forKey: .confirmations)
    }
}

extension Flight {
    func hasAircraftFeature(_ feature: AircraftFeature) -> Bool {
        guard !isDevice else { return false }
        switch feature {
        case .complex: return complex
        case .highPerformance: return highPerformance
        case .taa: return taa
        case .turbine: return facts.has("turbine") || facts.has("aircraftFeature.turbine")
        case .tailwheel: return facts.has("aircraftFeature.tailwheel") || facts.has("tailwheel")
        default: return facts.has("aircraftFeature." + feature.rawValue)
        }
    }
}

extension Flight {
    var sicTime: Double { min(max(0, total), max(0, facts.amounts["sic", default: 0])) }
    var isDevice: Bool { ["FFS", "FTD", "ATD"].contains(category) }
    var isPowered: Bool { !isDevice && !["Glider", "Balloon", "Airship", "Unspecified"].contains(category) }
}
