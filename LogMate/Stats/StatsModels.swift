// Stats value types: snapshot inputs/outputs, flight/leg summaries, airport
// activity, coordinate helpers, and the pure-geometry math used by the
// stats worker.
import Foundation
import UIKit

nonisolated struct StatsInput: Sendable {
    let id: UUID
    let order: Int
    let date: String
    let route: String
    let registration: String
    let model: String
    let total: Double
    let photoKey: String
    let legacyPhotoKey: String
}
nonisolated struct StatsFlight: Identifiable, Sendable {
    let input: StatsInput
    let parsedDate: Date
    let shortDate: String
    let airports: [String]
    var id: UUID { input.id }
    var total: Double { input.total }
    var route: String { airports.joined(separator: " → ") }
}
nonisolated struct StatsLeg: Identifiable, Hashable, Sendable {
    let from: String
    let to: String
    var id: String { from + "|" + to }
    init(_ a: String, _ b: String) { from = min(a, b); to = max(a, b) }
}
nonisolated struct StatsAirportActivity: Sendable {
    var arrivals = 0
    var total = 0.0
    var flightIDs: [UUID] = []
    var lastVisit = "—"
    var recentRoutes: [String] = []
    mutating func record(_ flight: StatsFlight) {
        if flightIDs.isEmpty { lastVisit = flight.shortDate }
        flightIDs.append(flight.id); total += flight.total
        if recentRoutes.count < 2 { recentRoutes.append(flight.route) }
    }
}
nonisolated struct StatsSnapshot: Sendable {
    var key = ""
    var flights: [StatsFlight] = []
    var byID: [UUID: StatsFlight] = [:]
    var codes: [String] = []
    var airports: [String: StatsAirportActivity] = [:]
    var total = 0.0
    var registrationCounts: [String: Int] = [:]
    var mostFlown: String?
    var mostFlownModel = ""
    var modelCount = 0
    var variantCount = 0
    var recentLegs: [StatsLeg] = []
    var otherLegs: [StatsLeg] = []
}
nonisolated struct StatsCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}
nonisolated struct StatsDistance: Identifiable, Sendable {
    let flightID: UUID
    let route: String
    let distance: Double
    var id: UUID { flightID }
}
nonisolated enum StatsMath {
    static func baseModel(_ name: String) -> String {
        AircraftNames.baseModel(name)
    }
    static func distances(_ snapshot: StatsSnapshot, coordinates: [String: StatsCoordinate]) -> [StatsDistance] {
        // Repeated legs share one geodesic calculation, but every logged leg still
        // contributes to that flight's distance (including return legs).
        var legs: [StatsLeg: Double] = [:]
        var result: [StatsDistance] = []
        for flight in snapshot.flights {
            guard flight.airports.count > 1, flight.airports.allSatisfy({ coordinates[$0] != nil }) else { continue }
            var distance = 0.0
            for (from, to) in zip(flight.airports, flight.airports.dropFirst()) {
                let leg = StatsLeg(from, to)
                if legs[leg] == nil, let a = coordinates[from], let b = coordinates[to] {
                    let radians = Double.pi / 180
                    let lat = (b.latitude - a.latitude) * radians, lon = (b.longitude - a.longitude) * radians
                    let h = pow(sin(lat / 2), 2) + cos(a.latitude * radians) * cos(b.latitude * radians) * pow(sin(lon / 2), 2)
                    legs[leg] = 3440.065 * 2 * atan2(sqrt(max(0, min(1, h))), sqrt(max(0, 1 - min(1, h))))
                }
                distance += legs[leg] ?? 0
            }
            guard distance > 0 else { continue }
            result.append(StatsDistance(flightID: flight.id, route: flight.route, distance: distance))
            // Keep just the top three. Equal distances retain newest-first order.
            result.sort { $0.distance > $1.distance }
            if result.count > 3 { result.removeLast() }
        }
        return result
    }
}
