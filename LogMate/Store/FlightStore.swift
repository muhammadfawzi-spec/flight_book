// The app's single shared state object: loads, validates, saves and deletes
// flights, aircraft, schedules, instructors and the medical record; owns the
// stats model, the save/backup logic, and the prototype testing-reset.
import Foundation
import Combine
import UIKit

// App history notes from the original single-file build (kept verbatim):
// Update ID: IMPORT-COMPLETION-REGISTRY-2026-10-14
// Replace ContentView.swift only. Keep your existing @main app file.
// iOS 17 or later. Existing savedFlights and FlightPhotos are retained.
// October 14 build: registry aircraft resolution, preserved import features, completion reports and date/registration-only required fields.
// Add Privacy - Camera Usage Description (NSCameraUsageDescription) to the Xcode target's Info settings.
// Aircraft controls show the five retained experience features; totals show accumulated hours only.
// Configure AI image imports in More. The AI provider key must remain on the server.
// Existing galleries, medical tracking, stories, signatures, milestones and exports are retained.

@MainActor final class FlightStore: ObservableObject {
    @Published private(set) var flights: [Flight] = [] {
        didSet { sortedCache = nil; statsInputCache = nil; flightIndexCache = nil; flightRevision &+= 1 }
    }
    @Published private(set) var flightRevision = 0
    let stats = StatsModel()
    private var sortedCache: [Flight]?
    private var statsInputCache: [StatsInput]?
    private var flightIndexCache: [UUID: Flight]?
    @Published private(set) var aircraft: [SavedAircraft] = []
    @Published private(set) var schedules: [ScheduledFlight] = []
    @Published private(set) var instructors: [InstructorProfile] = []
    @Published private(set) var medical: FAAMedical?
    @Published var errorMessage: String?
    @Published var photoRevision = 0
    @Published private(set) var canUndoFlightReset = UserDefaults.standard.data(forKey: "savedFlights_beforeTestingReset") != nil
    private var loadFailed = false
    init() {
        if let data = UserDefaults.standard.data(forKey: "savedFlights") {
            do { flights = try JSONDecoder().decode([Flight].self, from: data) }
            catch {
                loadFailed = true
                errorMessage = "The saved logbook could not be read. It has not been overwritten."
            }
        }
        aircraft = Self.read("logbookAircraft", as: [SavedAircraft].self) ?? []
        schedules = Self.read("logbookSchedules", as: [ScheduledFlight].self) ?? []
        instructors = Self.read("logbookInstructors", as: [InstructorProfile].self) ?? []
        medical = Self.read("logbookMedical", as: FAAMedical.self)
        if !loadFailed {
            var updated = flights
            if AircraftFeatureSync.applySavedFeatures(aircraft, to: &updated) {
                do {
                    let data = try JSONEncoder().encode(updated)
                    backup()
                    UserDefaults.standard.set(data, forKey: "savedFlights")
                    flights = updated
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }
    private static func read<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    var sorted: [Flight] {
        if let sortedCache { return sortedCache }
        typealias SortEntry = (offset: Int, flight: Flight, date: Date)
        var entries: [SortEntry] = []
        entries.reserveCapacity(flights.count)
        for (offset, flight) in flights.enumerated() {
            let date: Date = flight.flightDate ?? Date.distantPast
            entries.append((offset: offset, flight: flight, date: date))
        }
        entries.sort { first, second in
            if first.date == second.date { return first.offset > second.offset }
            return first.date > second.date
        }
        var result: [Flight] = []
        result.reserveCapacity(entries.count)
        for entry in entries { result.append(entry.flight) }
        sortedCache = result
        return result
    }
    var statsInput: [StatsInput] {
        if let statsInputCache { return statsInputCache }
        var identities: [String: (registration: String, model: String)] = [:]
        let input = flights.enumerated().filter { !$0.element.isDevice }.map { entry in
            let f = entry.element
            let identity = identities[f.aircraft] ?? (registration: f.registration, model: f.aircraftModel)
            identities[f.aircraft] = identity
            return StatsInput(id: f.id, order: entry.offset, date: f.date, route: f.route,
                registration: identity.registration, model: identity.model, total: f.total,
                photoKey: f.photoKey, legacyPhotoKey: f.legacyPhotoKey ?? "\(f.route)-\(f.date)-\(f.aircraft)")
        }
        statsInputCache = input
        return input
    }
    func flight(_ id: UUID) -> Flight? {
        if flightIndexCache == nil { flightIndexCache = Dictionary(flights.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }) }
        return flightIndexCache?[id]
    }
    var fleet: [SavedAircraft] {
        var result = Dictionary(aircraft.map { item -> (String, SavedAircraft) in
            var normalized = item
            normalized.registration = AircraftNames.registration(item.registration)
            normalized.model = AircraftNames.display(item.model)
            return (normalized.registration, normalized)
        }, uniquingKeysWith: { _, new in new })
        for f in sorted.reversed() where !f.isDevice {
            if !aircraft.contains(where: { AircraftNames.registration($0.registration) == f.registration }) {
                result[f.registration] = SavedAircraft(registration: f.registration, model: f.aircraftModel, category: f.category,
                    complex: f.complex ? true : nil, highPerformance: f.highPerformance ? true : nil,
                    taa: f.taa ? true : nil, turbine: f.facts.has("turbine") ? true : nil,
                    detectedFeatures: Dictionary(uniqueKeysWithValues: AircraftFeature.allCases.filter { f.hasAircraftFeature($0) }.map { ($0.rawValue, true) }))
            }
        }
        return result.values.filter { !["FFS", "FTD", "ATD"].contains($0.category ?? "") }.sorted { a, b in
            let ah = flights.filter { $0.registration == a.registration }.reduce(0) { $0 + $1.total }
            let bh = flights.filter { $0.registration == b.registration }.reduce(0) { $0 + $1.total }
            return ah == bh ? a.registration < b.registration : ah > bh
        }
    }
    @discardableResult func save(_ flight: Flight, photos: [UIImage], aircraft input: SavedAircraft? = nil,
                                featureChanges: [String: Bool] = [:]) -> Bool {
        guard !loadFailed else { errorMessage = "Restore the unreadable logbook before saving."; return false }
        let issues = FlightEntryValidation.savingIssues(flight)
        guard issues.isEmpty else { errorMessage = issues.map(\.message).joined(separator: "\n"); return false }
        var updated = flights
        if let index = updated.firstIndex(where: { $0.id == flight.id }) { updated[index] = flight }
        else { updated.append(flight) }
        var updatedAircraft = aircraft
        if var item = input {
            item.registration = AircraftNames.registration(item.registration)
            item.model = AircraftNames.display(item.model)
            updatedAircraft.removeAll { AircraftNames.registration($0.registration) == item.registration }
            updatedAircraft.append(item)
            let features = item.resolvedEquipmentFeatures.merging(featureChanges, uniquingKeysWith: { _, edit in edit })
            AircraftFeatureSync.apply(features, registration: item.registration, to: &updated)
        }
        do {
            let encoded = try JSONEncoder().encode(updated)
            let encodedAircraft = input == nil ? nil : try JSONEncoder().encode(updatedAircraft)
            try PhotoStore.save(photos, key: flight.photoKey)
            backup()
            UserDefaults.standard.set(encoded, forKey: "savedFlights")
            if let encodedAircraft { UserDefaults.standard.set(encodedAircraft, forKey: "logbookAircraft") }
            flights = updated
            if input != nil { aircraft = updatedAircraft }
            photoRevision += 1
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    // CSV automatic saves commit once, so a failed batch never leaves a partially imported logbook.
    @discardableResult func saveImportedFlights(_ imported: [Flight], aircraft incomingAircraft: [SavedAircraft] = []) -> Bool {
        guard !loadFailed else { errorMessage = "Restore the unreadable logbook before saving."; return false }
        guard imported.allSatisfy({ CSVImportReview.validationIssues($0).isEmpty }) else {
            errorMessage = "Some imported flights need required details before they can be saved."; return false
        }
        guard !imported.isEmpty else { return true }
        var ids = Set(flights.map(\.id))
        let additions = imported.filter { ids.insert($0.id).inserted }
        guard !additions.isEmpty else { return true }
        var updatedAircraft = aircraft
        for item in incomingAircraft where additions.contains(where: { $0.registration == AircraftNames.registration(item.registration) }) {
            updatedAircraft.removeAll { AircraftNames.registration($0.registration) == AircraftNames.registration(item.registration) }
            updatedAircraft.append(item)
        }
        do {
            var updated = flights + additions
            AircraftFeatureSync.applySavedFeatures(updatedAircraft, to: &updated)
            let encoded = try JSONEncoder().encode(updated)
            let encodedAircraft = incomingAircraft.isEmpty ? nil : try JSONEncoder().encode(updatedAircraft)
            backup()
            UserDefaults.standard.set(encoded, forKey: "savedFlights")
            if let encodedAircraft { UserDefaults.standard.set(encodedAircraft, forKey: "logbookAircraft") }
            flights = updated
            if !incomingAircraft.isEmpty { aircraft = updatedAircraft }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func delete(_ flight: Flight) {
        guard !loadFailed else { return }
        let updated = flights.filter { $0.id != flight.id }
        do {
            let encoded = try JSONEncoder().encode(updated)
            backup()
            UserDefaults.standard.set(encoded, forKey: "savedFlights")
            flights = updated
            // Keep photo files recoverable; removing a flight does not erase them.
        } catch { errorMessage = error.localizedDescription }
    }
    private func backup() {
        let defaults = UserDefaults.standard
        if defaults.data(forKey: "savedFlights_beforePrototypeUI") == nil,
           let original = defaults.data(forKey: "savedFlights") {
            defaults.set(original, forKey: "savedFlights_beforePrototypeUI")
        }
    }
    @discardableResult func deleteAllFlightsForTesting() -> Bool {
        guard PrototypeTesting.enablesFlightReset, !loadFailed, !flights.isEmpty else { return false }
        do {
            let defaults = UserDefaults.standard
            var previouslyDeleted: [Flight] = []
            if let data = defaults.data(forKey: "savedFlights_beforeTestingReset") {
                // Preserve earlier resets too; an unreadable backup aborts without clearing anything.
                previouslyDeleted = try JSONDecoder().decode([Flight].self, from: data)
            }
            var ids = Set(flights.map(\.id))
            let recoverable = flights + previouslyDeleted.filter { ids.insert($0.id).inserted }
            let snapshot = try JSONEncoder().encode(recoverable)
            let empty = try JSONEncoder().encode([Flight]())
            backup()
            defaults.set(snapshot, forKey: "savedFlights_beforeTestingReset")
            defaults.set(empty, forKey: "savedFlights")
            flights = []; canUndoFlightReset = true
            // Aircraft, schedules, instructor records and all photo files are retained.
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    @discardableResult func undoFlightResetForTesting() -> Bool {
        guard PrototypeTesting.enablesFlightReset, !loadFailed,
              let data = UserDefaults.standard.data(forKey: "savedFlights_beforeTestingReset") else { return false }
        do {
            let saved = try JSONDecoder().decode([Flight].self, from: data)
            var ids = Set(flights.map(\.id))
            var restored = flights + saved.filter { ids.insert($0.id).inserted }
            AircraftFeatureSync.applySavedFeatures(aircraft, to: &restored)
            let encoded = try JSONEncoder().encode(restored)
            UserDefaults.standard.set(encoded, forKey: "savedFlights"); flights = restored
            UserDefaults.standard.removeObject(forKey: "savedFlights_beforeTestingReset")
            canUndoFlightReset = false
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    @discardableResult func addAircraft(_ input: SavedAircraft, featureChanges: [String: Bool] = [:]) -> Bool {
        guard !loadFailed else { errorMessage = "Restore the unreadable logbook before changing aircraft equipment."; return false }
        var item = input
        item.registration = AircraftNames.registration(input.registration); item.model = AircraftNames.display(input.model)
        var list = aircraft.filter { AircraftNames.registration($0.registration) != item.registration }
        list.append(item)
        var updated = flights
        let features = item.resolvedEquipmentFeatures.merging(featureChanges, uniquingKeysWith: { _, edit in edit })
        let changed = AircraftFeatureSync.apply(features, registration: item.registration, to: &updated)
        do {
            let data = try JSONEncoder().encode(list)
            let flightData = changed ? try JSONEncoder().encode(updated) : nil
            if let flightData {
                backup()
                UserDefaults.standard.set(flightData, forKey: "savedFlights")
            }
            UserDefaults.standard.set(data, forKey: "logbookAircraft")
            aircraft = list
            if changed { flights = updated }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    @discardableResult func confirm(_ flightID: UUID, key: String, statement: String, value: Double, accepted: Bool) -> Bool {
        guard !loadFailed, value.isFinite, value >= 0,
              let index = flights.firstIndex(where: { $0.id == flightID }) else { return false }
        var updated = flights
        updated[index].confirmations[key] = MilestoneConfirmation(flightDigest: updated[index].recordDigest,
            confirmedAt: Date(), accepted: accepted, creditedValue: value, statement: statement)
        do {
            let data = try JSONEncoder().encode(updated); backup()
            UserDefaults.standard.set(data, forKey: "savedFlights"); flights = updated
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func clearConfirmation(_ flightID: UUID, key: String) {
        guard !loadFailed, let index = flights.firstIndex(where: { $0.id == flightID }) else { return }
        var updated = flights; updated[index].confirmations.removeValue(forKey: key)
        do {
            let data = try JSONEncoder().encode(updated); backup()
            UserDefaults.standard.set(data, forKey: "savedFlights"); flights = updated
        } catch { errorMessage = error.localizedDescription }
    }
    @discardableResult func rememberInstructor(_ instructor: InstructorProfile) -> Bool {
        var list = instructors.filter { $0.id != instructor.id }; list.append(instructor)
        do {
            let data = try JSONEncoder().encode(list)
            UserDefaults.standard.set(data, forKey: "logbookInstructors"); instructors = list
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    @discardableResult func saveMedical(_ value: FAAMedical) -> Bool {
        do {
            let data = try JSONEncoder().encode(value)
            UserDefaults.standard.set(data, forKey: "logbookMedical"); medical = value
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func removeMedical() { UserDefaults.standard.removeObject(forKey: "logbookMedical"); medical = nil }
    @discardableResult func saveSchedule(_ item: ScheduledFlight) -> Bool {
        let issues = ScheduleImportReview.validationIssues(item)
        guard issues.isEmpty else { errorMessage = issues.map(\.message).joined(separator: "\n"); return false }
        var list = schedules.filter { $0.id != item.id }
        list.append(item)
        do {
            let data = try JSONEncoder().encode(list)
            UserDefaults.standard.set(data, forKey: "logbookSchedules"); schedules = list
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    @discardableResult func saveImportedSchedules(_ imported: [ScheduledFlight]) -> Bool {
        guard imported.allSatisfy({ ScheduleImportReview.validationIssues($0).isEmpty }) else {
            errorMessage = "Some scheduled flights need a valid date or time before saving."; return false
        }
        var ids = Set(schedules.map(\.id))
        var sources = Set(schedules.compactMap { $0.sourceScheduleID?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let additions = imported.filter { item in
            guard ids.insert(item.id).inserted else { return false }
            let source = item.sourceScheduleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return source.isEmpty || sources.insert(source).inserted
        }
        guard !additions.isEmpty else { return true }
        do {
            let updated = schedules + additions
            let data = try JSONEncoder().encode(updated)
            UserDefaults.standard.set(data, forKey: "logbookSchedules"); schedules = updated
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func deleteSchedule(_ item: ScheduledFlight) {
        let list = schedules.filter { $0.id != item.id }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: "logbookSchedules"); schedules = list
            Task { await ReminderManager.rebuild(list) }
        }
    }
}
