// Update ID: IMPORT-COMPLETION-REGISTRY-2026-10-14
import SwiftUI
import Foundation
import PhotosUI
import Photos
import UniformTypeIdentifiers
import UIKit
import Combine
import MapKit
import Vision
import UserNotifications
import ImageIO
import PencilKit
import CryptoKit
import CoreImage
import Security
import VisionKit
import AVFoundation

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

struct AircraftFeaturePicker: View {
    @EnvironmentObject var theme: AppTheme
    @Binding var equipment: AircraftEquipmentState
    @State private var expanded = false
    private func selection(_ feature: AircraftFeature) -> Binding<Bool> {
        Binding(get: { equipment.selected(feature) }, set: { equipment.choose(feature, enabled: $0) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(equipment.rows) { feature in
                Toggle(feature.title, isOn: selection(feature)).tint(theme.accent)
            }
            if !equipment.source.isEmpty {
                Text(equipment.source).font(.caption).foregroundStyle(theme.muted)
            }
            if let url = equipment.modelSourceURL {
                Link("View aircraft equipment source", destination: url).font(.caption).foregroundStyle(theme.cyan)
            }
            if equipment.horsepower != nil || equipment.engines != nil {
                HStack(spacing: 14) {
                    if let hp = equipment.horsepower { Text("\(Int(hp)) hp per engine") }
                    if let count = equipment.engines { Text("\(count) \(count == 1 ? "engine" : "engines")") }
                }.font(.caption).foregroundStyle(theme.muted)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { expanded.toggle() }
            } label: {
                HStack {
                    Text("Additional aircraft features").fontWeight(.semibold)
                    Spacer(); Image(systemName: "chevron.down").rotationEffect(.degrees(expanded ? 180 : 0))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(theme.accent)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                Text("Select a relevant feature that wasn't detected, or correct a listed feature. Your selections are remembered for this aircraft.")
                    .font(.caption).foregroundStyle(theme.muted)
                if !equipment.recordedFlight && !equipment.corrections.isEmpty {
                    Button("Use detected features") { equipment.useDetectedFeatures() }
                        .foregroundStyle(theme.cyan)
                    Text("Clears your saved feature corrections for this aircraft when you save.")
                        .font(.caption).foregroundStyle(theme.muted)
                }
                ForEach(AircraftFeature.pilotGroups, id: \.self) { group in
                    Text(group).font(.caption.weight(.semibold)).foregroundStyle(theme.cyan).padding(.top, 6)
                    ForEach(AircraftFeature.pilotFeatures.filter { $0.pilotGroup == group }) { feature in
                        Button { equipment.choose(feature, enabled: !equipment.selected(feature)) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: equipment.selected(feature) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(equipment.selected(feature) ? theme.accent : theme.muted)
                                Text(feature.title).foregroundStyle(theme.text).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }.padding(.vertical, 5).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityValue(equipment.selected(feature) ? "Selected" : "Not selected")
                    }
                }
                Text("Features describe the aircraft. Training and instructor endorsements are recorded separately. Select TAA only when its required displays, GPS moving map and integrated two-axis autopilot are installed.")
                    .font(.caption).foregroundStyle(theme.muted)
            }
        }.font(.subheadline).logbookCard()
    }
}

struct AircraftPhoto: View {
    @EnvironmentObject var photos: AircraftPhotos
    @EnvironmentObject var theme: AppTheme
    let registration: String
    var body: some View {
        let placeholderColor = theme.raised
        let loadingColor = theme.accent
        let captionColor = theme.muted
        return GeometryReader { geometry in
            ZStack {
                placeholderColor
                if let image = photos.images[AircraftNames.registration(registration)] {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else if photos.loading.contains(AircraftNames.registration(registration)) {
                    ProgressView().tint(loadingColor)
                } else {
                    VStack(spacing: 5) {
                        Image(systemName: "photo").font(.title3)
                        if geometry.size.width > 130 { Text("Add an aircraft photo").font(.caption) }
                    }.foregroundStyle(captionColor)
                }
            }
        }.clipped().task(id: registration) { await photos.load(registration) }
    }
}

struct AircraftGallery: View {
    @EnvironmentObject var photos: AircraftPhotos
    @EnvironmentObject var theme: AppTheme
    let registration: String
    var editable = true
    var height: CGFloat = 220
    @State private var selected: UUID?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var problem: String?
    private var reg: String { AircraftNames.registration(registration) }
    private var items: [AircraftGalleryItem] { photos.visibleItems(reg) }
    private var current: AircraftGalleryItem? { items.first { $0.id == selected } ?? items.first }
    var body: some View {
        let placeholderColor = theme.raised
        let captionColor = theme.muted
        return VStack(alignment: .leading, spacing: 10) {
            if items.isEmpty {
                AircraftPhoto(registration: reg).frame(height: height).clipShape(RoundedRectangle(cornerRadius: 22))
            } else {
                TabView(selection: $selected) {
                    ForEach(items) { item in
                        GeometryReader { geometry in
                            if let image = photos.image(item) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                            } else { placeholderColor.overlay(Text("Photo unavailable").foregroundStyle(captionColor)) }
                        }.tag(Optional(item.id))
                    }
                }.tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
                    .frame(height: height).clipShape(RoundedRectangle(cornerRadius: 22))
            }
            if let item = current {
                HStack(spacing: 8) {
                    if let link = item.link { Link(item.credit, destination: link).lineLimit(1) }
                    else { Text(item.credit).foregroundStyle(theme.muted) }
                    Spacer()
                    Text("\((items.firstIndex { $0.id == item.id } ?? 0) + 1) / \(items.count)").foregroundStyle(theme.muted)
                }.font(.caption)
                if !item.userAdded, item.quality?.acceptable != true {
                    Text("This older saved photo has not passed the new quality check. Retry lookup to check for a sharper original.")
                        .font(.caption2).foregroundStyle(theme.muted)
                }
            }
            if photos.loading.contains(reg) {
                HStack(spacing: 8) { ProgressView(); Text("Checking original photos…") }
                    .font(.caption).foregroundStyle(theme.muted)
            } else if let note = photos.lookupNotes[reg] {
                Text(note).font(.caption2).foregroundStyle(theme.muted)
            }
            if editable {
                controls
                if let item = current, item.userAdded {
                    Button("Delete this photo", role: .destructive) {
                        if !photos.delete(item.id, registration: reg) { problem = photos.errorMessage ?? "The photo could not be removed." }
                    }.font(.caption)
                }
            }
        }
        .task(id: reg) { selected = nil; await photos.load(reg) }
        .onChange(of: items.map(\.id), initial: true) { _, ids in
            if selected == nil || !ids.contains(selected!) { selected = ids.first }
        }
        .onChange(of: photoItems) { _, chosen in
            let targetRegistration = reg
            Task { @MainActor in
                importing = true
                defer { importing = false; photoItems = [] }
                for item in chosen {
                    guard let data = try? await item.loadTransferable(type: Data.self), let image = AircraftPhotos.decodedPhoto(data) else {
                        problem = "One of the selected photos could not be read."; continue
                    }
                    if !photos.add(image, registration: targetRegistration) { problem = photos.errorMessage ?? "The photo could not be saved." }
                }
                selected = photos.galleries[targetRegistration]?.first?.id
            }
        }
        .alert("Aircraft photos", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
    }
    private var controls: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $photoItems, maxSelectionCount: max(1, AircraftPhotos.maximumPhotos - items.filter(\.userAdded).count), matching: .images) {
                Label(importing ? "Saving…" : "Add photos", systemImage: "photo.badge.plus")
            }.disabled(importing || reg.isEmpty || items.filter(\.userAdded).count >= AircraftPhotos.maximumPhotos)
            Spacer()
            if let current, items.first?.id != current.id {
                Button("Use as cover") {
                    if !photos.makeCover(current.id, registration: reg) { problem = photos.errorMessage ?? "The cover could not be saved." }
                }
            }
            Menu {
                Button("Retry public photo lookup") { Task { await photos.load(reg, retry: true) } }
            } label: { Image(systemName: "ellipsis.circle") }
        }.font(.caption).foregroundStyle(theme.accent)
    }
}

// MARK: - App shell

struct SessionPhoto: View {
    @EnvironmentObject var theme: AppTheme
    let flight: Flight
    var body: some View {
        if flight.isDevice {
            ZStack {
                LinearGradient(colors: [theme.raised, theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "desktopcomputer").font(.system(size: 30, weight: .medium)).foregroundStyle(theme.cyan)
            }
        } else { AircraftPhoto(registration: flight.registration) }
    }
}

struct FlightRow: View {
    @EnvironmentObject var theme: AppTheme
    let flight: Flight
    var compact = false
    var body: some View {
        HStack(spacing: 12) {
            SessionPhoto(flight: flight).frame(width: 62, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text("\(flight.shortDate) \(flight.registration)\(compact || flight.aircraftModel.isEmpty ? "" : " (\(flight.aircraftModel))")")
                    .font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(flight.isDevice ? flight.category + " · " + flight.facts.text["representedClass", default: ""] : flight.airports.joined(separator: " "))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.muted)
                if compact || !flight.notes.isEmpty {
                    Text(compact ? "\(hours(flight.total)) hr\(flight.notes.isEmpty ? "" : " · \(flight.notes)")" : flight.notes)
                        .font(.system(size: 13)).foregroundStyle(theme.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 16, weight: .medium)).foregroundStyle(theme.muted)
        }.padding(.vertical, 14).contentShape(Rectangle())
    }
}

struct FlightListPopup: View {
    @EnvironmentObject var store: FlightStore
    var title = "All Flights"
    var ids: Set<UUID>? = nil
    @State private var selected: Flight?
    var flights: [Flight] { store.sorted.filter { ids?.contains($0.id) ?? true } }
    var body: some View {
        SheetFrame(title: title) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(flights.count) \(flights.count == 1 ? "flight" : "flights") logged").foregroundStyle(.secondary)
                ForEach(flights) { flight in
                    Button { selected = flight } label: { FlightRow(flight: flight, compact: true) }.buttonStyle(.plain)
                    Divider()
                }
                if flights.isEmpty { Text("No flights logged.").padding(.vertical, 30) }
            }
        }.sheet(item: $selected) { FlightDetail(flightID: $0.id) }
    }
}

struct LogbookScreen: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @State private var currency = false
    @State private var visibleCurrency = false
    @State private var pageOpacity = 1.0
    @State private var allFlights = false
    @State private var selected: Flight?
    @State private var heroIndex = 0
    @State private var confirmingFlightReset = false
    var recent: [Flight] { Array(store.sorted.prefix(10)) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                segment.padding(.horizontal, 20).padding(.top, 12)
                Group {
                    if visibleCurrency { CurrencyScreen() }
                    else { flightsPage }
                }.opacity(pageOpacity)
            }.padding(.horizontal, 16).padding(.bottom, 25)
        }
        .task(id: currency) {
            guard currency != visibleCurrency else {
                withAnimation(.easeIn(duration: 0.4)) { pageOpacity = 1 }
                return
            }
            withAnimation(.easeOut(duration: 0.25)) { pageOpacity = 0 }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            visibleCurrency = currency
            await Task.yield()
            withAnimation(.easeIn(duration: 0.4)) { pageOpacity = 1 }
        }
        .sheet(isPresented: $allFlights) { FlightListPopup() }
        .sheet(item: $selected) { FlightDetail(flightID: $0.id) }
        .confirmationDialog("Delete all \(store.flights.count) flights?", isPresented: $confirmingFlightReset, titleVisibility: .visible) {
            Button("Delete All Flights", role: .destructive) {
                if store.deleteAllFlightsForTesting() { heroIndex = 0; selected = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Testing only. This clears the entire logbook, not just the recent list. Deleted flights stay backed up until Undo, including earlier testing resets. Aircraft, schedules and photos are not removed.")
        }
    }
    private var segment: some View {
        let surfaceColor = theme.surface
        let selectionColor = theme.accent
        let captionColor = theme.muted
        let borderColor = theme.line
        return GeometryReader { geometry in
            let width = (geometry.size.width - 8) / 2
            ZStack(alignment: .leading) {
                Capsule().fill(surfaceColor)
                Capsule().fill(selectionColor).frame(width: width, height: 44)
                    .offset(x: currency ? width + 4 : 4)
                    .animation(.easeInOut(duration: 0.8), value: currency)
                HStack(spacing: 0) {
                    Button("Flights") { currency = false }
                        .foregroundStyle(currency ? captionColor : Color(hex: 0x15202A))
                    Button("Currency") { currency = true }
                        .foregroundStyle(currency ? Color(hex: 0x15202A) : captionColor)
                }.buttonStyle(SegmentButtonStyle())
            }.overlay(Capsule().stroke(borderColor, lineWidth: 1))
        }.frame(height: 52)
    }
    private var flightsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !recent.isEmpty {
                TabView(selection: $heroIndex) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, flight in
                        Button { selected = flight } label: {
                            SessionPhoto(flight: flight)
                                .overlay(LinearGradient(colors: [.clear, .black.opacity(0.76)], startPoint: .center, endPoint: .bottom))
                                .overlay(alignment: .bottomLeading) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(flight.aircraftModel.isEmpty ? flight.registration : flight.aircraftModel)
                                            .font(.system(size: 23, weight: .heavy, design: .rounded))
                                        Text("\(flight.registration) · \(flight.shortDate)").font(.system(size: 15))
                                        Text(flight.isDevice ? "Recent simulator session" : "Recent flight").font(.system(size: 13)).foregroundStyle(.white.opacity(0.75))
                                    }.foregroundStyle(.white).padding(18).padding(.bottom, 12)
                                }.overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "chevron.right").foregroundStyle(.white).font(.title2).padding(20).padding(.bottom, 18)
                                }
                        }.buttonStyle(.plain).tag(index)
                    }
                }.tabViewStyle(.page(indexDisplayMode: .never)).frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 4) {
                            ForEach(recent.indices, id: \.self) { index in
                                Capsule().fill(index == heroIndex ? theme.accent : .white.opacity(0.45))
                                    .frame(width: index == heroIndex ? 15 : 5, height: 5)
                            }
                        }.padding(17).allowsHitTesting(false)
                    }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "book").font(.largeTitle).foregroundStyle(theme.accent)
                    Text("Your logbook starts here").font(.headline)
                    Text("Tap + to log your first flight.").foregroundStyle(theme.muted)
                }.frame(maxWidth: .infinity).padding(.vertical, 40).logbookCard()
            }
            HStack {
                SectionHeading(title: "Recent Flights")
                Spacer()
                Button("See All") { allFlights = true }.font(.system(size: 17, weight: .bold)).foregroundStyle(theme.accent)
            }
            if PrototypeTesting.enablesFlightReset {
                HStack(spacing: 12) {
                    Text("Testing").font(.caption).foregroundStyle(theme.muted)
                    Spacer()
                    if store.canUndoFlightReset {
                        Button("Undo Delete All") { _ = store.undoFlightResetForTesting() }
                            .font(.caption.bold()).foregroundStyle(theme.cyan)
                    }
                    Button("Delete All Flights", role: .destructive) { confirmingFlightReset = true }
                        .font(.caption.bold()).disabled(store.flights.isEmpty)
                }
            }
            VStack(spacing: 0) {
                ForEach(recent) { flight in
                    Button { selected = flight } label: { FlightRow(flight: flight) }.buttonStyle(.plain)
                    Rectangle().fill(theme.line).frame(height: 1)
                }
            }
        }
    }
}

// MARK: - FAA medical validity

struct MedicalCurrencySection: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FAA medical").font(.headline)
                Spacer()
                Button(store.medical == nil ? "+ Add" : "Edit") { editing = true }.font(.subheadline.bold()).foregroundStyle(theme.accent)
            }
            if let medical = store.medical {
                Text(medical.medicalClass.title + " · Exam " + FlightDates.string(medical.examDate, format: "MMM d, yyyy"))
                    .font(.caption).foregroundStyle(theme.muted)
                TimelineView(.periodic(from: Date(), by: 60)) { clock in
                    VStack(spacing: 10) {
                        ForEach(MedicalPrivilege.allCases) { privilege in
                            MedicalPrivilegeRow(medical: medical, privilege: privilege, now: clock.date)
                        }
                    }
                }
                if !medical.limitations.isEmpty { Text("Printed limitations: " + medical.limitations).font(.caption).foregroundStyle(theme.muted) }
                Text("These dates track certificate validity. Follow its printed limits and §61.53 medical-fitness requirements. BasicMed and operations that do not require a medical are separate.")
                    .font(.caption2).foregroundStyle(theme.muted)
            } else {
                Button { editing = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "cross.case").font(.title2).foregroundStyle(theme.cyan)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Add your medical certificate").font(.subheadline.bold())
                            Text("See time remaining for each privilege level").font(.caption).foregroundStyle(theme.muted)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.muted)
                    }.foregroundStyle(theme.text).logbookCard(tone: .blue)
                }.buttonStyle(.plain)
            }
        }.padding(.vertical, 6).sheet(isPresented: $editing) { MedicalEditor(medical: store.medical) }
    }
}

struct MedicalPrivilegeRow: View {
    @EnvironmentObject var theme: AppTheme
    let medical: FAAMedical
    let privilege: MedicalPrivilege
    let now: Date
    private var end: Date? { MedicalValidity.endExclusive(medical, privilege: privilege) }
    private var current: Bool { end.map { now >= Calendar.current.startOfDay(for: medical.examDate) && now < $0 } ?? false }
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(privilege.title).font(.subheadline.bold())
                Text(privilege.detail).font(.caption2).foregroundStyle(theme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                if let end {
                    Text(MedicalValidity.remaining(end, now: now)).font(.subheadline.bold()).foregroundStyle(current ? Color.green : Color.red)
                    Text("Until " + FlightDates.string(MedicalValidity.lastDay(end), format: "M/d/yyyy"))
                        .font(.caption2).foregroundStyle(theme.muted)
                } else {
                    Text("Not covered").font(.subheadline.bold()).foregroundStyle(theme.muted)
                    Text("Needs a higher medical class").font(.caption2).foregroundStyle(theme.muted)
                }
            }
        }.logbookCard(15)
            .overlay(RoundedRectangle(cornerRadius: 22).stroke((current ? Color.green : theme.line).opacity(0.35)))
    }
}

struct MedicalEditor: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    @State private var draft: FAAMedical
    @State private var hasPrintedEnd: Bool
    @State private var printedEnd: Date
    @State private var problem: String?
    @State private var removing = false
    let existing: Bool
    init(medical: FAAMedical?) {
        let m = medical ?? FAAMedical()
        existing = medical != nil
        _draft = State(initialValue: m)
        _hasPrintedEnd = State(initialValue: m.notValidAfter != nil)
        _printedEnd = State(initialValue: m.notValidAfter ?? Date())
    }
    var body: some View {
        SheetFrame(title: existing ? "Medical certificate" : "Add FAA medical") {
            VStack(alignment: .leading, spacing: 18) {
                Picker("Medical issued", selection: $draft.medicalClass) {
                    ForEach(MedicalClass.allCases) { Text($0.title).tag($0) }
                }
                DatePicker("Date of examination", selection: $draft.examDate, in: ...Date(), displayedComponents: .date)
                Picker("Age at this examination", selection: $draft.age40OrOlderAtExam) {
                    Text("Under 40").tag(false)
                    Text("40 or older").tag(true)
                }.pickerStyle(.segmented)
                Text("Use age on the examination date. Turning 40 afterward does not shorten this certificate's standard third-class period.")
                    .font(.caption).foregroundStyle(theme.muted)
                DisclosureGroup("Printed expiry dates / special issuance") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Certificate has a 'not valid after' date", isOn: $hasPrintedEnd)
                        if hasPrintedEnd { DatePicker("Not valid after", selection: $printedEnd, displayedComponents: .date) }
                        ForEach(MedicalPrivilege.allCases) { privilege in
                            if MedicalValidity.months(draft, privilege: privilege) != nil {
                                Toggle("Earlier \(privilege.title.lowercased()) limit", isOn: limited(privilege))
                                if draft.privilegeLimits[privilege.rawValue] != nil {
                                    DatePicker("Printed last valid date", selection: limitDate(privilege), displayedComponents: .date)
                                }
                            }
                        }
                        LogField(title: "Other printed limitations (optional)", value: $draft.limitations, hint: "For example: corrective lenses")
                        Text("Enter dates from the medical certificate. Restrictions can shorten its validity; an authorization's renewal date is not automatically the certificate's expiry date.")
                            .font(.caption).foregroundStyle(theme.muted)
                    }.padding(.top, 12)
                }.font(.subheadline)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Validity preview").font(.headline)
                    ForEach(MedicalPrivilege.allCases) { privilege in
                        SummaryRow(title: privilege.title, value: MedicalValidity.endExclusive(preview, privilege: privilege).map {
                            FlightDates.string(MedicalValidity.lastDay($0), format: "MMM d, yyyy")
                        } ?? "Not covered")
                    }
                }.logbookCard(tone: .blue)
                AccentButton(title: "Save Medical") {
                    let value = preview
                    guard Calendar.current.startOfDay(for: value.examDate) <= Date() else { problem = "The examination date cannot be in the future."; return }
                    if store.saveMedical(value) { dismiss() } else { problem = store.errorMessage ?? "The medical could not be saved." }
                }
                if existing { Button("Remove medical information", role: .destructive) { removing = true }.frame(maxWidth: .infinity) }
                Link("FAA medical duration rules", destination: URL(string: "https://www.ecfr.gov/current/title-14/section-61.23")!)
                    .font(.caption).foregroundStyle(theme.cyan)
            }
        }.alert("Medical information", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
        .alert("Remove this medical?", isPresented: $removing) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { store.removeMedical(); dismiss() }
        } message: { Text("You can add the certificate again later.") }
    }
    private var preview: FAAMedical { var m = draft; m.notValidAfter = hasPrintedEnd ? printedEnd : nil; return m }
    private func limited(_ privilege: MedicalPrivilege) -> Binding<Bool> {
        Binding(get: { draft.privilegeLimits[privilege.rawValue] != nil }, set: { enabled in
            if enabled { draft.privilegeLimits[privilege.rawValue] = Date() }
            else { draft.privilegeLimits.removeValue(forKey: privilege.rawValue) }
        })
    }
    private func limitDate(_ privilege: MedicalPrivilege) -> Binding<Date> {
        Binding(get: { draft.privilegeLimits[privilege.rawValue] ?? Date() }, set: { draft.privilegeLimits[privilege.rawValue] = $0 })
    }
}

// MARK: - Currency estimates and both disclaimers

struct CurrencyScreen: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @State private var disclaimer = false
    private var recent: [Flight] {
        let today = Calendar.current.startOfDay(for: Date())
        let cutoff = Calendar.current.date(byAdding: .day, value: -90, to: today)!
        return store.sorted.filter {
            guard let date = $0.flightDate else { return false }
            return $0.category == "ASEL" && date >= cutoff && date <= Date()
        }
    }
    private func expiry(night: Bool) -> Date? {
        var count = 0
        for f in recent {
            count += night ? f.nightLandings : f.landings
            if count >= 3, let date = f.flightDate {
                return Calendar.current.date(byAdding: .day, value: 90, to: date)
            }
        }
        return nil
    }
    private var instrument: [Flight] {
        let c = Calendar.current
        let month = c.date(from: c.dateComponents([.year, .month], from: Date()))!
        let cutoff = c.date(byAdding: .month, value: -6, to: month)!
        return store.flights.filter {
            guard let date = $0.flightDate else { return false }
            let airplane = ["ASEL", "AMEL", "ASES", "AMES"].contains($0.category)
            let device = $0.isDevice && $0.facts.has("deviceApproved") && $0.instrumentTime > 0 &&
                ["ASEL", "AMEL", "ASES", "AMES"].contains($0.facts.text["representedClass", default: ""])
            return (airplane || device) && date >= cutoff && date <= Date()
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    SectionHeading(title: "Currency")
                    Text("Based on your logged flight activity").font(.subheadline).foregroundStyle(theme.muted)
                }
                Spacer()
                Text("61.57").font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.cyan).padding(10)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.cyan.opacity(0.5)))
            }.padding(.bottom, 8)
            MedicalCurrencySection()
            FlightReviewCard()
            currencyCard("ASEL – Passengers", expiration: expiry(night: false),
                         detail: "\(recent.reduce(0) { $0 + $1.landings }) of 3 landings logged")
            currencyCard("ASEL – Night", expiration: expiry(night: true),
                         detail: "\(recent.reduce(0) { $0 + $1.nightLandings }) of 3 night landings logged")
            let approaches = instrument.reduce(0) { $0 + $1.approachCount }
            let holds = instrument.reduce(0) { $0 + $1.holds }
            let tracked = instrument.contains { $0.tracking }
            HStack(alignment: .center, spacing: 12) {
                Text("IFR – Airplane").frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text(approaches >= 6 && holds > 0 && tracked ? "Review required" : "Incomplete records")
                        .font(.system(size: 18, weight: .bold)).foregroundStyle(theme.accent)
                    Text("\(approaches) approaches · \(holds) holds\nTracking: \(tracked ? "logged" : "not logged")")
                        .font(.caption).foregroundStyle(theme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.logbookCard()
            VStack(alignment: .leading, spacing: 7) {
                Text("Landing data only").font(.headline).foregroundStyle(theme.accent)
                Text("This view uses logged landings to estimate currency. Make sure the required takeoffs have also been completed.")
                    .font(.subheadline).foregroundStyle(theme.muted)
            }.logbookCard().padding(.top, 4)
            Button { disclaimer = true } label: {
                HStack {
                    Text("Currency disclaimer")
                    Spacer()
                    Image(systemName: "chevron.right")
                }.foregroundStyle(.white).padding(20)
                    .background(LinearGradient(colors: [Color(hex: 0x9C3542), Color(hex: 0x36151D)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hex: 0xEE7385), lineWidth: 1))
            }.buttonStyle(.plain)
        }.sheet(isPresented: $disclaimer) {
            SheetFrame(title: "Currency disclaimer") {
                VStack(alignment: .leading, spacing: 18) {
                    Text("This is a logbook aid, not a legal determination of whether you may act as pilot in command.").font(.headline)
                    Text("Check every date, unit, category, class, aircraft type, landing, approach, and holding entry for accuracy.")
                    Text("Landing estimates do not verify takeoffs, sole manipulation of controls, night time boundaries, full-stop requirements, or type-specific requirements. Only enter qualifying night landings in the night landing field.")
                    Text("IFR counts are a checklist, not an automatic currency determination. Conditions, category, holding, tracking, and any required proficiency checks must also be verified.")
                    Text("An estimate does not mean you are legal, qualified, or safe to fly. Review the applicable rules with your instructor.")
                    Link("Read 14 CFR 61.57", destination: URL(string: "https://www.ecfr.gov/current/title-14/section-61.57")!)
                }
            }
        }
    }
    private func currencyCard(_ title: String, expiration: Date?, detail: String) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(expiration.map { "Estimate until:\n" + FlightDates.string($0, format: "M/d/yyyy") } ?? "Not enough landings")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(expiration == nil ? Color.red : Color.green)
                Text(detail).font(.caption).foregroundStyle(theme.muted)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.logbookCard().overlay(RoundedRectangle(cornerRadius: 22).stroke((expiration == nil ? Color.red : Color.green).opacity(0.35)))
    }
}

// MARK: - Add and edit flights

// MARK: - Instructor signing

struct SignatureCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    @MainActor final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: SignatureCanvas
        var isApplyingDrawing = false

        init(_ parent: SignatureCanvas) {
            self.parent = parent
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingDrawing else { return }

            let newDrawing = canvasView.drawing
            guard newDrawing.dataRepresentation() != parent.drawing.dataRepresentation() else {
                return
            }

            parent.drawing = newDrawing
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.backgroundColor = .white
        canvas.isOpaque = true
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.accessibilityLabel = "Instructor signature. Draw with a finger or Apple Pencil."

        // Set the initial drawing before enabling drawing callbacks.
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        guard canvas.drawing.dataRepresentation() != drawing.dataRepresentation() else {
            return
        }

        // A SwiftUI update must not write back into the SwiftUI binding.
        coordinator.isApplyingDrawing = true
        defer { coordinator.isApplyingDrawing = false }
        canvas.drawing = drawing
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        canvas.delegate = nil
    }
}

struct InstructorSigningView: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    let flight: Flight
    let onSigned: (InstructorSignature) -> Void
    @State private var agreed = false
    @State private var agreedAt: Date?
    @State private var next = false
    @State private var profile = InstructorProfile()
    @State private var expiration = Date()
    @State private var hasExpiration = false
    @State private var recentEnd = Date()
    @State private var hasRecentEnd = false
    @State private var comments = ""
    @State private var drawing = PKDrawing()
    @State private var instructorAffirmed = false
    @State private var problem: String?
    var body: some View {
        SheetFrame(title: next ? "Instructor signature" : "Before signing") {
            VStack(alignment: .leading, spacing: 18) {
                if !next {
                    Text(InstructorSignature.agreement).foregroundStyle(theme.text).logbookCard()
                    Toggle("I agree and affirm the instructor will sign personally", isOn: $agreed)
                    AccentButton(title: "Next") { agreedAt = Date(); next = true }.disabled(!agreed)
                } else {
                    Text("Hand the device to your instructor to review this entry and sign.")
                        .font(.subheadline).foregroundStyle(theme.muted)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(flight.shortDate + " · " + flight.registration + " · " + flight.aircraftModel).font(.headline)
                        Text(flight.route)
                        let hoursSummary = "Total " + hours(flight.total) + " h · Dual " + hours(flight.dual) + " h · PIC " + hours(flight.pic) + " h"
                        Text(hoursSummary)
                        DisclosureGroup("Review all recorded times and comments") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Cross-country \(hours(flight.crossCountry)) · Night \(hours(flight.night)) · IMC \(hours(flight.imc)) · Simulated instrument \(hours(flight.simulatedInstrument)) · Instructor \(hours(flight.instructor)) h")
                                Text("Day / night landings \(flight.dayLandings) / \(flight.nightLandings) · Approaches \(flight.approachCount) · Holds \(flight.holds)")
                                Text("Class: \(flight.category) · Complex: \(flight.complex ? "Yes" : "No") · HP: \(flight.highPerformance ? "Yes" : "No") · TAA: \(flight.taa ? "Yes" : "No")")
                                if flight.facts.has("flightReview") { Text("Flight review · Ground \(hours(flight.facts.amounts["reviewGround", default: 0])) h · Endorsement \(flight.facts.has("reviewEndorsed") ? "recorded" : "not recorded")") }
                                if flight.facts.has("checkride") { Text("Checkride · \(flight.facts.has("checkridePassed") ? "Passed qualifying practical test" : "Passing result not confirmed")") }
                                if !flight.approaches.isEmpty { Text(flight.approaches) }
                                if !flight.notes.isEmpty { Text(flight.notes) }
                            }.font(.caption).padding(.top, 10)
                        }.font(.subheadline)
                    }.logbookCard()
                    if !store.instructors.isEmpty {
                        Menu("Choose a previous CFI") {
                            ForEach(store.instructors) { instructor in
                                Button(instructor.name + " · " + instructor.certificate) { select(instructor) }
                            }
                        }.foregroundStyle(theme.accent)
                    }
                    LogField(title: "Instructor name", value: $profile.name, hint: "Full name")
                    LogField(title: "Instructor email", value: $profile.email, hint: "name@example.com", keyboard: .emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    LogField(title: "Certificate #", value: $profile.certificate, hint: "Instructor certificate number")
                    Toggle("No expiration", isOn: $profile.noExpiration)
                        .onChange(of: profile.noExpiration) { _, value in if value { hasExpiration = false; profile.expiration = nil } }
                    if !profile.noExpiration {
                        Toggle("Enter expiration date", isOn: $hasExpiration)
                        if hasExpiration { DatePicker("Expiration", selection: $expiration, displayedComponents: .date) }
                    } else {
                        Toggle("Include recent-experience end date", isOn: $hasRecentEnd)
                        if hasRecentEnd { DatePicker("Recent experience ends", selection: $recentEnd, displayedComponents: .date) }
                        Text("A certificate without an expiration date does not by itself establish current instructor privileges.")
                            .font(.caption).foregroundStyle(theme.muted)
                    }
                    Text("Instructor comments / training given").font(.subheadline).foregroundStyle(theme.muted)
                    TextEditor(text: $comments).frame(minHeight: 105).padding(10).scrollContentBackground(.hidden)
                        .background(theme.raised).clipShape(RoundedRectangle(cornerRadius: 14))
                    HStack { Text("Draw signature").font(.headline); Spacer(); Button("Clear") { drawing = PKDrawing(); instructorAffirmed = false } }
                    SignatureCanvas(drawing: $drawing).frame(height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line))
                    Toggle("I am the named instructor. I reviewed this flight and training description, and am authorized to sign this entry.", isOn: $instructorAffirmed)
                        .font(.subheadline)
                    AccentButton(title: "Attach signature to this flight", action: attach)
                    Text("Comments and the signature are entered fresh for every flight.")
                        .font(.caption).foregroundStyle(theme.muted)
                }
            }
        }.alert("Check signature", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
    }
    private func select(_ instructor: InstructorProfile) {
        profile = instructor
        hasExpiration = instructor.expiration != nil && !instructor.noExpiration
        expiration = instructor.expiration ?? Date()
        hasRecentEnd = instructor.recentExperienceEnd != nil
        recentEnd = instructor.recentExperienceEnd ?? Date()
        comments = ""; drawing = PKDrawing(); instructorAffirmed = false
    }
    private func attach() {
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.email = profile.email.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.certificate = profile.certificate.trimmingCharacters(in: .whitespacesAndNewlines)
        let emailParts = profile.email.split(separator: "@", omittingEmptySubsequences: false)
        guard !profile.name.isEmpty, !profile.certificate.isEmpty, emailParts.count == 2,
              !emailParts[0].isEmpty, emailParts[1].contains("."), !profile.email.contains(where: { $0.isWhitespace }) else {
            problem = "Enter the instructor's name, email, and certificate number."; return
        }
        guard profile.noExpiration || hasExpiration else { problem = "Enter an expiration date or select No expiration."; return }
        guard !comments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = "The instructor must describe the training or endorsement in the comments."; return
        }
        guard agreed, let agreedAt, instructorAffirmed, !drawing.strokes.isEmpty,
              drawing.bounds.width > 2, drawing.bounds.height > 2 else {
            problem = "The instructor must draw a signature and affirm the entry."; return
        }
        profile.expiration = profile.noExpiration ? nil : expiration
        profile.recentExperienceEnd = profile.noExpiration && hasRecentEnd ? recentEnd : nil
        let rect = drawing.bounds.insetBy(dx: -10, dy: -10)
        let ink = drawing.image(from: rect, scale: 2)
        let image = UIGraphicsImageRenderer(size: rect.size).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: rect.size))
            ink.draw(in: CGRect(origin: .zero, size: rect.size))
        }
        guard let png = image.pngData() else { problem = "The signature image could not be saved. Please try again."; return }
        onSigned(InstructorSignature(instructor: profile, comments: comments, inkPNG: png, signedAt: Date(),
            agreedAt: agreedAt, flightDigest: flight.recordDigest, flightSnapshot: flight.recordSnapshot))
        dismiss()
    }
}

struct InstructorSignatureCard: View {
    @EnvironmentObject var theme: AppTheme
    let signature: InstructorSignature
    var valid = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Instructor signature").font(.headline)
            Text(signature.instructor.name + " · Certificate " + signature.instructor.certificate).font(.subheadline.bold())
            Text(signature.instructor.email).font(.caption).foregroundStyle(theme.muted)
            Text(signature.instructor.noExpiration ? "No certificate expiration" : "Expiration: " + (signature.instructor.expiration.map { FlightDates.string($0) } ?? "Not recorded"))
                .font(.caption).foregroundStyle(theme.muted)
            if let end = signature.instructor.recentExperienceEnd { Text("Recent experience ends: " + FlightDates.string(end)).font(.caption) }
            Text(signature.comments).font(.subheadline)
            if let image = UIImage(data: signature.inkPNG) {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 100)
                    .padding(12).frame(maxWidth: .infinity).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Text("Signed " + FlightDates.string(signature.signedAt, format: "MMM d, yyyy h:mm a") + " · Identity not verified by the app")
                .font(.caption2).foregroundStyle(theme.muted)
            if !valid { Text("The flight changed after signing. Re-sign the entry before using this signature.").font(.caption).foregroundStyle(.red) }
        }.logbookCard()
    }
}

struct ApproachPickerView: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var catalog = ApproachCatalog.shared
    let airports: [String]
    let add: (String) -> Void
    @State private var airport = ""
    @State private var selected = ""
    @State private var type = "RNAV (GPS)"
    @State private var runway = "01"
    @State private var variant = ""
    @State private var manual = false
    @State private var manualText = ""
    private let types = ["RNAV (GPS)", "RNAV (RNP)", "ILS", "LOC", "VOR", "VOR/DME", "NDB", "LDA", "SDF", "Visual"]
    private var choices: [LoggedProcedure] { catalog.choices(airport) }
    var body: some View {
        SheetFrame(title: "Log an approach") {
            VStack(alignment: .leading, spacing: 16) {
                if !airports.isEmpty {
                    Picker("Airport", selection: Binding(get: { airports.contains(AirportRoute.canonical(airport)) ? AirportRoute.canonical(airport) : "" }, set: { airport = $0 })) { ForEach(Array(Set(airports)).sorted(), id: \.self) { Text($0).tag($0) }; Text("Other airport").tag("") }
                }
                LogField(title: "Airport code", value: $airport, hint: "KRHV").textInputAutocapitalization(.characters)
                if !choices.isEmpty {
                    Picker("Approach", selection: Binding(get: { selected == "other" ? "other" : choices.first { $0.name == selected }?.family ?? "" }, set: { family in
                        selected = family == "other" ? "other" : choices.first { $0.family == family }?.name ?? ""
                    })) {
                        Text("Choose a procedure").tag("")
                        ForEach(Array(Set(choices.map(\.family))).sorted(), id: \.self) { Text($0).tag($0) }
                        Text("Other / historical procedure").tag("other")
                    }.pickerStyle(.menu)
                }
                if choices.isEmpty || selected == "other" {
                    Text("Select the procedure you flew. Available FAA procedures appear automatically when found.")
                        .font(.caption).foregroundStyle(theme.muted)
                    Picker("Approach type", selection: $type) { ForEach(types, id: \.self) { Text($0).tag($0) } }
                    Picker("Variant (optional)", selection: $variant) { Text("None").tag(""); ForEach(["X", "Y", "Z", "A", "B", "C"], id: \.self) { Text($0).tag($0) } }
                }
                let procedure = choices.first { $0.name == selected }
                if let procedure {
                    Picker("Runway", selection: Binding(get: { choices.first { $0.name == selected }?.runway ?? "" }, set: { runway in
                        if let match = choices.first(where: { $0.family == procedure.family && $0.runway == runway }) { selected = match.name }
                    })) {
                        ForEach(Array(Set(choices.filter { $0.family == procedure.family }.map(\.runway))).sorted(), id: \.self) { Text($0.isEmpty ? "Circling / no runway" : $0).tag($0) }
                    }.pickerStyle(.menu)
                } else {
                    Picker("Runway", selection: $runway) {
                        Text("Circling / no runway").tag("")
                        ForEach((1...36).flatMap { number in ["", "L", "C", "R"].map { String(format: "%02d", number) + $0 } }, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.menu)
                }
                Button("Don’t see your approach?") { withAnimation(.easeInOut(duration: 0.2)) { manual.toggle() } }
                    .foregroundStyle(theme.cyan)
                if manual {
                    LogField(title: "Approach flown", value: $manualText, hint: "RNAV-Z 31R")
                    Text("Use the airport above and enter the procedure and runway.").font(.caption).foregroundStyle(theme.muted)
                }
                if !catalog.message.isEmpty { Text(catalog.message).font(.caption).foregroundStyle(theme.muted) }
                AccentButton(title: "Add approach") {
                    let code = AirportRoute.canonical(airport)
                    let name = manual ? manualText.trimmingCharacters(in: .whitespacesAndNewlines) : procedure?.name ?? type + (variant.isEmpty ? "" : " " + variant) + (runway.isEmpty ? "" : " RWY " + runway)
                    add(code + " · " + name); dismiss()
                }.disabled(AirportRoute.codes(airport).count != 1 || (manual ? manualText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : (!choices.isEmpty && selected.isEmpty)))
            }
        }.onAppear { if airport.isEmpty { airport = airports.first ?? "" } }
            .onChange(of: airport) { _, _ in selected = "" }
            .task { await catalog.refresh() }
    }
}

struct WINGSEditor: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    @ObservedObject var store: WINGSStore
    @State private var date = Date()
    @State private var item: PhotosPickerItem?
    @State private var image: UIImage?
    var body: some View {
        SheetFrame(title: "WINGS completion") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Record completion of a WINGS phase. Individual activities do not replace a flight review.").font(.caption).foregroundStyle(theme.muted)
                DatePicker("Phase completed", selection: $date, in: ...Date(), displayedComponents: .date)
                PhotosPicker(selection: $item, matching: .images) { Label("Add completion certificate (optional)", systemImage: "photo.badge.plus") }.foregroundStyle(theme.cyan)
                if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 14)) }
                if !store.error.isEmpty { Text(store.error).font(.caption).foregroundStyle(theme.accent) }
                AccentButton(title: "Save completion") { if store.save(date: date, image: image) { dismiss() } }
            }
        }.onChange(of: item) { _, item in
            Task { if let data = try? await item?.loadTransferable(type: Data.self) { image = AircraftPhotos.decodedPhoto(data) } }
        }
    }
}

struct ShareImage: Identifiable { let id = UUID(); let image: UIImage }
@MainActor enum StoryPhotoSaver {
    static func save(_ image: UIImage) async throws {
        guard let purpose = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String, !purpose.isEmpty else {
            throw CSVImportError.invalid("Enable photo saving in Xcode: Target → Info → Privacy - Photo Library Additions Usage Description. Use: Save flight stories to your photo library.")
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CSVImportError.invalid("Allow LogMate to add photos in iPhone Settings, then try again.") }
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
    }
}

struct SimulatorEditor: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    let original: Flight?
    var onSaved: (() -> Void)?
    @State private var date: Date
    @State private var kind: String
    @State private var name: String
    @State private var identifier: String
    @State private var represented: String
    @State private var total: String
    @State private var dual: String
    @State private var instrument: String
    @State private var approachCount: String
    @State private var holds: String
    @State private var approaches: String
    @State private var tracking: Bool
    @State private var approved: Bool
    @State private var cfii: Bool
    @State private var program: String
    @State private var atdType: String
    @State private var notes: String
    @State private var choosingApproach = false
    @State private var problem: String?
    init(flight: Flight? = nil, onSaved: (() -> Void)? = nil) {
        original = flight; self.onSaved = onSaved
        _date = State(initialValue: flight?.flightDate ?? Date())
        _kind = State(initialValue: flight?.category ?? "ATD")
        _name = State(initialValue: flight?.aircraftModel ?? "")
        _identifier = State(initialValue: flight?.registration ?? "")
        _represented = State(initialValue: flight?.facts.text["representedClass"] ?? "ASEL")
        _total = State(initialValue: flight.map { entryHours($0.total) } ?? "")
        _dual = State(initialValue: entryHours(flight?.dual ?? 0))
        _instrument = State(initialValue: entryHours(flight?.simulatedInstrument ?? 0))
        _approachCount = State(initialValue: entryCount(flight?.approachCount ?? 0))
        _holds = State(initialValue: entryCount(flight?.holds ?? 0))
        _approaches = State(initialValue: flight?.approaches ?? "")
        _tracking = State(initialValue: flight?.tracking ?? false)
        _approved = State(initialValue: flight?.facts.has("deviceApproved") ?? false)
        _cfii = State(initialValue: flight?.facts.has("cfii") ?? false)
        _program = State(initialValue: flight?.facts.text["deviceProgram"] ?? "Part 61")
        _atdType = State(initialValue: flight?.facts.text["atdType"] ?? "AATD")
        _notes = State(initialValue: flight?.notes ?? "")
    }
    var body: some View {
        SheetFrame(title: original == nil ? "Log simulator time" : "Edit simulator time") {
            VStack(alignment: .leading, spacing: 18) {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Picker("Device", selection: $kind) {
                    Text("Full flight simulator (FFS)").tag("FFS")
                    Text("Flight training device (FTD)").tag("FTD")
                    Text("Aviation training device (ATD)").tag("ATD")
                }.pickerStyle(.menu)
                if kind == "ATD" {
                    Picker("ATD type", selection: $atdType) { Text("Basic (BATD)").tag("BATD"); Text("Advanced (AATD)").tag("AATD") }
                }
                LogField(title: "Simulator name / model", value: $name, hint: "Redbird FMX")
                LogField(title: "Device identifier (optional)", value: $identifier, hint: "Serial number or school ID")
                Picker("Represented category / class", selection: $represented) {
                    ForEach(AircraftLookup.categories.filter { !["Unspecified", "FFS", "FTD", "ATD", "Rotorcraft"].contains($0) }, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                LogField(title: "Session time", value: $total, hint: "0.0", keyboard: .decimalPad)
                HStack(spacing: 12) {
                    LogField(title: "Instruction received", value: $dual, hint: "0.0", keyboard: .decimalPad)
                    LogField(title: "Simulated instrument", value: $instrument, hint: "0.0", keyboard: .decimalPad)
                }
                Toggle("FAA-approved device and training tasks", isOn: $approved).tint(theme.accent)
                if number(dual) > 0 { Toggle("Instrument instruction with a CFII", isOn: $cfii).tint(theme.accent) }
                Picker("Training program", selection: $program) {
                    ForEach(["Part 61", "Part 141", "Part 142", "Part 121", "Part 135"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
                HStack { Text("Approaches").font(.headline); Spacer(); Button("+ Add approach") { choosingApproach = true }.foregroundStyle(theme.accent) }
                if !approaches.isEmpty { Text(approaches).font(.caption).foregroundStyle(theme.muted) }
                HStack(spacing: 12) {
                    LogField(title: "Approach count", value: $approachCount, hint: "0", keyboard: .numberPad)
                    LogField(title: "Holds", value: $holds, hint: "0", keyboard: .numberPad)
                }
                Toggle("Instrument intercepting / tracking logged", isOn: $tracking)
                LogField(title: "Comments", value: $notes, hint: "Training completed")
                Text("Device time is recorded separately from aircraft flight time. Checkride credit uses applicable device limits; your device authorization or course may allow less.")
                    .font(.caption).foregroundStyle(theme.muted)
                AccentButton(title: "Save simulator time", action: save)
            }
        }.sheet(isPresented: $choosingApproach) {
            ApproachPickerView(airports: []) { value in
                approaches += (approaches.isEmpty ? "" : "\n") + value
                approachCount = String((Int(approachCount) ?? 0) + 1)
            }
        }.alert("Check simulator entry", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
    }
    private func save() {
        let values = [number(total), number(dual), number(instrument)]
        let raw = [total, dual, instrument].map { $0.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".") }
        guard raw.allSatisfy({ text in
                  Double(text.isEmpty ? "0" : text).map { $0.isFinite && $0 >= 0 && (values[0] == 0 || $0 <= values[0] + 0.001) } == true
              }), date.timeIntervalSinceReferenceDate.isFinite, date <= Date() else {
            problem = "Enter a valid date and nonnegative times. Times may be left blank."; return
        }
        guard let count = Int(approachCount.isEmpty ? "0" : approachCount), let holdCount = Int(holds.isEmpty ? "0" : holds),
              count >= 0, holdCount >= 0, count < 100_000, holdCount < 100_000 else { problem = "Use nonnegative whole numbers for approaches and holds."; return }
        var f = original ?? Flight()
        let id = AircraftNames.registration(identifier)
        let stableID = id.isEmpty ? (original?.registration ?? "SIM" + String(f.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(10))) : id
        f.category = kind; f.aircraft = stableID + " · " + name.trimmingCharacters(in: .whitespacesAndNewlines)
        f.date = FlightDates.string(date); f.duration = editableHours(values[0]); f.dual = values[1]; f.simulatedInstrument = values[2]
        f.approaches = approaches; f.approachCount = count; f.holds = holdCount; f.tracking = tracking; f.notes = notes
        f.facts.text["representedClass"] = represented; f.facts.text["deviceProgram"] = program; f.facts.text["atdType"] = atdType
        for (flag, enabled) in [("deviceApproved", approved), ("cfii", cfii && values[1] > 0)] {
            if enabled { f.facts.flags.insert(flag) } else { f.facts.flags.remove(flag) }
        }
        if let signature = f.signature, !signature.matches(f) { problem = "This signed session changed. Remove its signature before editing."; return }
        if store.save(f, photos: original.map { PhotoStore.load($0) } ?? []) { dismiss(); onSaved?() }
        else { problem = store.errorMessage ?? "The session could not be saved." }
    }
}

struct FlightEditor: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    @State private var draft: Flight
    @State private var date: Date
    @State private var registration: String
    @State private var model: String
    @State private var departureAirport: String
    @State private var arrivalAirport: String
    @State private var values: [String: String]
    @State private var photos: [UIImage]
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var validation: String?
    @State private var lookupMessage = ""
    @State private var autoModel = ""
    @State private var categoryOverride = ""
    @State private var lookupRetry = 0
    @State private var equipment = AircraftEquipmentState()
    @State private var importFeatureBaseline: [String: Bool] = [:]
    @State private var aircraftInfo: AircraftInfo?
    @State private var detailValues: [String: String] = [:]
    @State private var appliedRegistration = ""
    @State private var selectingApproach = false
    @State private var loggingSimulator = false
    @State private var soloSelected = false
    @State private var soloChanged = false
    @State private var signatureFlight: Flight?
    @State private var signedChange = false
    let editing: Bool
    let csvCoordinateRoute: Bool
    let scheduleID: UUID?
    let originalRegistration: String
    let originalFlight: Flight?
    let importReview: ScanReviewContext?
    let importAircraft: SavedAircraft?
    let onImportSaved: (() -> Void)?
    let onImportSkipped: (() -> Void)?
    @State private var missingDateResolved = false
    @State private var reviewTouched: Set<String> = []
    @State private var reviewConfirmed: Set<String> = []
    @State private var reviewConfirmedValues: [String: String] = [:]
    @State private var reviewTarget: ScanScrollTarget?
    @MainActor init(flight: Flight? = nil, scheduled: ScheduledFlight? = nil, suggestedNotes: String = "",
                    importReview: ScanReviewContext? = nil, importAircraft: SavedAircraft? = nil, onImportSaved: (() -> Void)? = nil,
                    onImportSkipped: (() -> Void)? = nil) {
        var f = flight ?? Flight()
        if let scheduled {
            f.route = scheduled.route; f.aircraft = scheduled.registration; f.notes = scheduled.title
        } else if flight == nil { f.notes = suggestedNotes }
        self.importReview = importReview
        self.importAircraft = importAircraft
        self.onImportSaved = onImportSaved
        self.onImportSkipped = onImportSkipped
        editing = flight != nil && importReview == nil; scheduleID = scheduled?.id
        csvCoordinateRoute = importReview != nil && f.facts.text["csvRouteEndpoints"] == "1"
        originalRegistration = f.registration
        originalFlight = editing ? flight : nil
        _appliedRegistration = State(initialValue: f.registration)
        _draft = State(initialValue: f)
        _soloSelected = State(initialValue: f.soloTime > 0)
        _date = State(initialValue: scheduled?.date ?? f.flightDate ?? Date())
        _registration = State(initialValue: f.registration)
        _model = State(initialValue: f.aircraftModel)
        _departureAirport = State(initialValue: f.facts.text["csvDeparture", default: ""])
        _arrivalAirport = State(initialValue: f.facts.text["csvArrival", default: ""])
        _autoModel = State(initialValue: importReview == nil || f.facts.text["csvSource"] != nil ? f.aircraftModel : "")
        let initialEquipment: AircraftEquipmentState = flight == nil ? AircraftEquipmentState() :
            (importReview != nil && f.facts.text["csvSource"] != nil ? .imported(f, model: f.aircraftModel, category: f.category,
                info: importAircraft?.equipmentInfo, saved: importAircraft) : .recorded(f))
        _equipment = State(initialValue: initialEquipment)
        _importFeatureBaseline = State(initialValue: initialEquipment.corrections)
        _aircraftInfo = State(initialValue: importAircraft?.equipmentInfo)
        _detailValues = State(initialValue: f.facts.amounts.mapValues { entryHours($0) }
            .merging(f.facts.counts.mapValues { entryCount($0) }, uniquingKeysWith: { _, new in new }))
        _values = State(initialValue: [
            "total": flight == nil ? "" : entryHours(f.total), "pic": entryHours(f.pic), "day": entryCount(f.dayLandings),
            "nightLandings": entryCount(f.nightLandings), "night": entryHours(f.night), "imc": entryHours(f.imc),
            "sim": entryHours(f.simulatedInstrument), "dual": entryHours(f.dual), "instructor": entryHours(f.instructor),
            "xc": entryHours(f.crossCountry), "approachCount": entryCount(f.approachCount), "holds": entryCount(f.holds)
        ])
        if let flight, importReview == nil {
            _photos = State(initialValue: PhotoStore.load(flight))
        } else {
            _photos = State(initialValue: [])
        }
    }
    private func field(_ key: String) -> Binding<String> {
        Binding(get: { values[key] ?? "" }, set: { values[key] = $0 })
    }
    private func fact(_ key: String) -> Binding<Bool> {
        Binding(get: { draft.facts.has(key) }, set: { value in
            if value { draft.facts.flags.insert(key) } else { draft.facts.flags.remove(key) }
        })
    }
    private func detail(_ key: String) -> Binding<String> {
        Binding(get: { detailValues[key] ?? "" }, set: { detailValues[key] = $0 })
    }
    private func factText(_ key: String) -> Binding<String> {
        Binding(get: { draft.facts.text[key, default: ""] }, set: { draft.facts.text[key] = $0 })
    }
    private func applyFeatures(_ previous: SavedAircraft? = nil) {
        equipment.category = draft.category
        guard !editing || AircraftLookup.clean(registration) != originalRegistration else { return }
        let remembered = previous ?? (importAircraft?.registration == AircraftLookup.clean(registration) ? importAircraft : nil)
        if importReview != nil, equipment.recordedFlight {
            if draft.facts.text["csvSource"] != nil {
                let edits = equipment.corrections.filter { importFeatureBaseline[$0.key] != $0.value }
                equipment = .imported(draft, model: model, category: draft.category,
                    info: aircraftInfo ?? remembered?.equipmentInfo, saved: remembered)
                importFeatureBaseline = equipment.corrections
                equipment.corrections = equipment.corrections.merging(edits, uniquingKeysWith: { _, edit in edit })
            } else if let remembered {
                equipment.detected = equipment.detected.merging(remembered.resolvedEquipmentFeatures, uniquingKeysWith: { _, saved in saved })
            }
        }
        equipment.update(model: model, category: draft.category, info: aircraftInfo ?? remembered?.equipmentInfo, saved: remembered)
        equipment.apply(to: &draft)
    }
    var body: some View {
        SheetFrame(title: importReview?.title ?? (editing ? "Edit Flight" : "New Flight"), scrollTarget: reviewTarget) {
            VStack(alignment: .leading, spacing: 20) {
                if let importReview { ScanEntryEvidence(context: importReview, pendingIssues: pendingReview, reviewNext: nextReview) }
                VStack(alignment: .leading, spacing: 8) {
                    if !reviewPresentation.isTracked("date") { Text("Date").foregroundStyle(theme.muted).font(.subheadline) }
                    DatePicker("Date", selection: $date, displayedComponents: .date).labelsHidden()
                        .onChange(of: date) { _, _ in missingDateResolved = true; reviewTouched.insert("date") }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(theme.raised).clipShape(RoundedRectangle(cornerRadius: 14))
                }.scanField("date", label: "Date")
                if !store.fleet.isEmpty {
                    Menu("Choose a previous aircraft") {
                        ForEach(store.fleet) { item in
                            Button(item.registration + " · " + item.model) {
                                registration = item.registration; model = item.model; autoModel = item.model
                                draft.category = item.category ?? "Unspecified"
                                reviewTouched.formUnion(["registration", "model", "category"])
                            }
                        }
                    }.foregroundStyle(theme.accent)
                }
                if !editing && importReview == nil {
                    Button { loggingSimulator = true } label: {
                        Label("Log simulator time", systemImage: "desktopcomputer")
                    }.foregroundStyle(theme.cyan)
                }
                let aircraftLayout = importReview == nil ? AnyLayout(HStackLayout(alignment: .top, spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                aircraftLayout {
                    LogField(title: "N-number", value: $registration, hint: "N12345").textInputAutocapitalization(.characters)
                    LogField(title: "Make and model", value: $model, hint: "Cessna 172P")
                }
                Text("Only the date and registration are required. Other fields can be left blank.")
                    .font(.caption).foregroundStyle(theme.muted)
                if !lookupMessage.isEmpty { Text(lookupMessage).font(.caption).foregroundStyle(theme.muted) }
                Button("Retry aircraft lookup") { lookupRetry += 1 }.font(.caption).foregroundStyle(theme.cyan)
                if AircraftNames.registration(registration).count >= 3 {
                    DisclosureGroup("Aircraft photos") {
                        AircraftGallery(registration: registration, height: 180).padding(.top, 10)
                    }.foregroundStyle(theme.accent)
                }
                if csvCoordinateRoute {
                    LogField(title: "Departure airport", value: $departureAirport, hint: "Airport code").textInputAutocapitalization(.characters)
                    LogField(title: "Arrival airport", value: $arrivalAirport, hint: "Airport code").textInputAutocapitalization(.characters)
                } else {
                    LogField(title: "Route", value: $draft.route, hint: "KRHV KAPC KSJC").textInputAutocapitalization(.characters)
                    Text("Type airport codes separated by spaces. Landing counts stay manual.").font(.caption).foregroundStyle(theme.muted)
                }
                pair("Total time", "total", "PIC time", "pic")
                if number(values["pic", default: ""]) > 0 || pendingReview.contains(where: { $0.field == "solo" }) {
                    Toggle("Solo", isOn: Binding(get: { soloSelected }, set: { soloSelected = $0; soloChanged = true; reviewTouched.insert("solo") }))
                        .tint(theme.accent).transition(.opacity.combined(with: .move(edge: .top)))
                        .scanField("solo")
                    if soloSelected {
                        Text("PIC time is also recorded as solo.").font(.caption).foregroundStyle(theme.muted)
                    }
                }
                LogField(title: "SIC time", value: detail("sic"), hint: "0.0", keyboard: .decimalPad)
                HStack(alignment: .top, spacing: 12) {
                    LogField(title: "Day landings", value: field("day"), hint: "0", keyboard: .numberPad)
                    LogField(title: "Night landings", value: field("nightLandings"), hint: "0", keyboard: .numberPad)
                }.scanField("landings")
                pair("Night time", "night", "IMC time", "imc")
                pair("Dual received", "dual", "Instructor time", "instructor")
                pair("Cross-country", "xc", "Sim. instrument", "sim")
                HStack {
                    Text("Approaches").font(.subheadline.bold()); Spacer()
                    Button("+ Add approach") { selectingApproach = true }.foregroundStyle(theme.accent)
                }.scanField("approaches")
                if !draft.approaches.isEmpty {
                    Text(draft.approaches).font(.caption).foregroundStyle(theme.muted)
                    Button("Clear approach details") { draft.approaches = ""; reviewTouched.insert("approaches") }.font(.caption).foregroundStyle(theme.cyan)
                }
                let approachLayout = importReview != nil && (reviewPresentation.isTracked("approachCount") || reviewPresentation.isTracked("holds"))
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                approachLayout {
                    LogField(title: "Approach count", value: field("approachCount"), hint: "0", keyboard: .numberPad)
                    LogField(title: "Holds", value: field("holds"), hint: "0", keyboard: .numberPad)
                }
                Toggle("Instrument intercepting / tracking logged", isOn: $draft.tracking).font(.subheadline)
                Picker("Category / class", selection: Binding(get: { draft.category }, set: {
                    draft.category = $0; categoryOverride = AircraftLookup.clean(registration); reviewTouched.insert("category")
                })) {
                    ForEach(AircraftLookup.categories, id: \.self) { Text($0).tag($0) }
                }.scanField("category")
                Text("Registry-based class is a suggestion. Confirm land/sea configuration and aircraft features for this flight.")
                    .font(.caption).foregroundStyle(theme.muted)
                AircraftFeaturePicker(equipment: $equipment)
                flightFacts
                if ["Glider", "Balloon", "Airship"].contains(draft.category) {
                    LogField(title: "Number of flights", value: detail("numberFlights"), hint: "1", keyboard: .numberPad)
                }
                if draft.category == "Glider" {
                    DisclosureGroup("Glider launches") {
                        VStack(spacing: 12) {
                            LogField(title: "Aero-tows", value: detail("aeroTows"), hint: "0", keyboard: .numberPad)
                            LogField(title: "Ground launches", value: detail("groundLaunches"), hint: "0", keyboard: .numberPad)
                            LogField(title: "Powered launches", value: detail("poweredLaunches"), hint: "0", keyboard: .numberPad)
                        }.padding(.top, 10)
                    }.logbookCard()
                }
                LogField(title: "Comments", value: $draft.notes, hint: "Notes about the flight")
                PhotosPicker(selection: $photoItems, maxSelectionCount: 12, matching: .images) {
                    Label("Add flight photos", systemImage: "photo.on.rectangle")
                }.foregroundStyle(theme.accent)
                photoGrid
                if let signature = draft.signature {
                    InstructorSignatureCard(signature: signature, valid: signature.matches(draft))
                    Button("Remove signature", role: .destructive) { draft.signature = nil }
                }
                Button { if prepareDraft() { signatureFlight = draft } } label: {
                    Label(draft.signature == nil ? "Add CFI signature" : "Have instructor sign again", systemImage: "signature")
                        .frame(maxWidth: .infinity).padding(14)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.line))
                }.foregroundStyle(theme.accent)
                AccentButton(title: importReview != nil ? "Confirm and save flight" : editing ? "Save Changes" : "Save Flight", action: save)
                Button(importReview == nil ? "Discard" : "Skip this entry", role: .cancel) {
                    if let onImportSkipped { onImportSkipped() } else { dismiss() }
                }.frame(maxWidth: .infinity).foregroundStyle(theme.muted)
            }.environment(\.scanReviewPresentation, reviewPresentation)
        }
        .task(id: "\(registration)-\(lookupRetry)") {
            let cleaned = AircraftLookup.clean(registration)
            if appliedRegistration != cleaned {
                appliedRegistration = cleaned; categoryOverride = ""; aircraftInfo = nil
                let original = cleaned == originalRegistration ? originalFlight : nil
                let previous = store.fleet.first { $0.registration == cleaned }
                if original == nil, model == autoModel { model = previous?.model ?? ""; autoModel = model }
                draft.category = original?.category ?? previous?.category ?? "Unspecified"
                equipment = original.map { .recorded($0) } ?? AircraftEquipmentState()
                equipment.apply(to: &draft)
            }
            guard cleaned.count >= 3 else { return }
            if lookupRetry == 0, let previous = store.fleet.first(where: { $0.registration == cleaned }) {
                if (!editing || cleaned != originalRegistration), draft.facts.text["aircraftModelSource"] != "Registry",
                   model.isEmpty || model == autoModel { model = previous.model; autoModel = previous.model }
                if (!editing || cleaned != originalRegistration), categoryOverride != cleaned, let category = previous.category { draft.category = category }
                applyFeatures(previous)
                lookupMessage = "Filled from your saved aircraft."
            }
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            lookupMessage = "Looking up aircraft…"
            let info = await AircraftLookup.info(cleaned, refresh: lookupRetry > 0)
            guard !Task.isCancelled, AircraftLookup.clean(registration) == cleaned else { return }
            if let info {
                aircraftInfo = info
                if (!editing || cleaned != originalRegistration), model.isEmpty || model == autoModel { model = info.model; autoModel = info.model }
                if (!editing || cleaned != originalRegistration), categoryOverride != cleaned {
                    draft.category = store.fleet.first { $0.registration == cleaned }?.category ?? info.suggestedCategory ?? "Unspecified"
                }
                applyFeatures(store.fleet.first { $0.registration == cleaned })
                lookupMessage = "\(info.source ?? "Registry"): \(info.aircraftType ?? "Aircraft") · Verify the class below."
            } else {
                applyFeatures(store.fleet.first { $0.registration == cleaned })
                lookupMessage = "Lookup unavailable. Saved aircraft details remain available; retry or enter missing details manually."
            }
        }
        .onChange(of: model) { _, _ in
            applyFeatures(store.fleet.first { $0.registration == AircraftLookup.clean(registration) })
            // A CSV missing-value flag is resolved by a successful aircraft lookup.
            // Scanner uncertainty still requires the pilot's confirmation.
            if draft.facts.text["csvSource"] != nil, model == autoModel, AircraftNames.hasMake(model),
               importReview?.issues.contains(where: { $0.field == "model" && $0.message.contains("could not be filled") }) == true {
                reviewConfirmed.insert("model")
                reviewConfirmedValues["model"] = ScanReviewLogic.confirmationValue("model", values: reviewValues)
            }
        }
        .onChange(of: departureAirport) { _, _ in updateCSVRoute() }
        .onChange(of: arrivalAirport) { _, _ in updateCSVRoute() }
        .onChange(of: draft.category) { _, _ in
            applyFeatures(store.fleet.first { $0.registration == AircraftLookup.clean(registration) })
        }
        .onChange(of: equipment.corrections) { _, _ in equipment.apply(to: &draft) }
        .onChange(of: photoItems) { _, items in
            Task { @MainActor in
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { photos.append(image) }
                }
                photoItems = []
            }
        }
        .animation(.easeInOut(duration: 0.3), value: number(values["pic", default: ""]) > 0)
        .sheet(isPresented: $loggingSimulator) {
            SimulatorEditor(onSaved: { dismiss() })
        }
        .sheet(isPresented: $selectingApproach) {
            ApproachPickerView(airports: draft.airports) { text in
                draft.approaches += (draft.approaches.isEmpty ? "" : "\n") + text
                values["approachCount"] = String((Int(values["approachCount", default: ""]) ?? 0) + 1)
                reviewTouched.formUnion(["approaches", "approachCount"])
            }
        }
        .sheet(item: $signatureFlight) { entry in
            InstructorSigningView(flight: entry) { draft.signature = $0 }
        }
        .alert("Signed entry changed", isPresented: $signedChange) {
            Button("Re-sign") { signatureFlight = draft }
            Button("Remove signature and save", role: .destructive) { draft.signature = nil; commitSave() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The signature belongs to the previously reviewed entry. Have the instructor review and sign the updated entry, or save it without that signature.") }
        .alert("Check flight", isPresented: Binding(get: { validation != nil }, set: { if !$0 { validation = nil } })) {
            Button("OK", role: .cancel) { validation = nil }
        } message: { Text(validation ?? "") }
    }
    private var flightFacts: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                Toggle("Flight review", isOn: fact("flightReview"))
                Toggle("Checkride", isOn: fact("checkride"))
            }.font(.subheadline.bold())
            if draft.facts.has("checkride") {
                Toggle("Passed a qualifying practical test", isOn: fact("checkridePassed"))
                Text("A passed pilot or flight-instructor practical test under §61.56(d) satisfies Flight Review. A failed or incomplete test does not.")
                    .font(.caption).foregroundStyle(theme.muted)
            }
            if draft.facts.has("flightReview") && !(draft.facts.has("checkride") && draft.facts.has("checkridePassed")) {
                Text("Ensure the required ground training is complete and your instructor's endorsement is in your paper or digital logbook.")
                    .font(.caption).foregroundStyle(theme.muted)
            }
        }.font(.subheadline).logbookCard()
    }
    private func pair(_ left: String, _ a: String, _ right: String, _ b: String) -> some View {
        let layout = importReview == nil ? AnyLayout(HStackLayout(spacing: 12)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
        return layout {
            LogField(title: left, value: field(a), hint: "0.0", keyboard: .decimalPad)
            LogField(title: right, value: field(b), hint: "0.0", keyboard: .decimalPad)
        }
    }
    private var photoGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(photos.indices, id: \.self) { index in
                Image(uiImage: photos[index]).resizable().scaledToFill().frame(height: 85).clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contextMenu { Button("Remove photo", role: .destructive) { photos.remove(at: index) } }
            }
        }
    }
    private func save() {
        guard prepareDraft() else { return }
        if let signature = draft.signature, !signature.matches(draft) { signedChange = true; return }
        commitSave()
    }
    private var reviewValues: [String: String] {
        var result = values
        result["date"] = FlightDates.string(date); result["registration"] = registration; result["model"] = model
        result["route"] = draft.route; result["category"] = draft.category; result["notes"] = draft.notes
        result["sic"] = detailValues["sic", default: ""]; result["approaches"] = draft.approaches
        if csvCoordinateRoute { result["departure"] = departureAirport; result["arrival"] = arrivalAirport }
        return result
    }
    private func updateCSVRoute() {
        guard csvCoordinateRoute else { return }
        draft.route = AirportRoute.formatted(departureAirport + " " + arrivalAirport)
    }
    private var expectedLandingTotal: Int? {
        if let total = draft.facts.counts["importedLandingTotal"] { return total }
        let unknown = draft.facts.counts["unclassifiedLandings", default: 0]
        return unknown > 0 ? draft.dayLandings + draft.nightLandings + unknown : nil
    }
    private var pendingReview: [ScanFieldIssue] {
        ScanReviewLogic.pending(importReview?.fieldIssues ?? [], values: reviewValues, touched: reviewTouched,
            confirmed: ScanReviewLogic.activeConfirmations(reviewConfirmed, snapshots: reviewConfirmedValues, values: reviewValues), expectedLandings: expectedLandingTotal)
    }
    private func nextReview() {
        guard let next = pendingReview.first else { return }
        reviewTarget = ScanScrollTarget(field: next.field)
    }
    private func confirmReview(_ field: String) {
        guard ScanReviewLogic.valid(field, values: reviewValues) else { return }
        if field == "date" { missingDateResolved = true }
        reviewConfirmed.insert(field)
        reviewConfirmedValues[field] = ScanReviewLogic.confirmationValue(field, values: reviewValues)
        nextReview()
    }
    private var reviewPresentation: ScanReviewPresentation {
        let all = Set((importReview?.fieldIssues ?? []).map(\.field))
        return ScanReviewPresentation(messages: Dictionary(uniqueKeysWithValues: pendingReview.map { ($0.field, $0.message) }),
            canConfirm: Set(pendingReview.filter { ScanReviewLogic.valid($0.field, values: reviewValues) }.map(\.field)),
            confirm: confirmReview, edited: { field in
                reviewTouched.insert(field)
                if ["day", "nightLandings"].contains(field) { reviewTouched.insert("landings") }
            }, resolved: all.subtracting(pendingReview.map(\.field)), next: nextReview)
    }
    private func prepareDraft() -> Bool {
        let originalLandingTotal = expectedLandingTotal
        if importReview != nil, let originalLandingTotal, draft.facts.counts["importedLandingTotal"] == nil {
            draft.facts.counts["importedLandingTotal"] = originalLandingTotal
        }
        if importReview?.unresolvedFields.contains("date") == true, !missingDateResolved {
            validation = "Set the missing flight date before saving."; return false
        }
        if importReview != nil, !pendingReview.isEmpty {
            validation = "Check the remaining review items before saving."; nextReview(); return false
        }
        if csvCoordinateRoute {
            updateCSVRoute()
        }
        let reg = AircraftLookup.clean(registration)
        guard !reg.isEmpty, date.timeIntervalSinceReferenceDate.isFinite else {
            validation = "Enter a valid date and aircraft registration."; return false
        }
        var decimals: [String: Double] = [:]
        for key in ["total", "pic", "night", "imc", "sim", "dual", "instructor", "xc"] {
            let text = values[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            guard let value = Double(text.isEmpty ? "0" : text), value.isFinite, value >= 0 else {
                validation = "Enter valid, nonnegative flight times."; return false
            }
            decimals[key] = value
        }
        let total = decimals["total", default: 0]
        guard total == 0 || (decimals.filter({ $0.key != "total" }).allSatisfy({ $0.value <= total + 0.001 }) &&
              decimals["imc", default: 0] + decimals["sim", default: 0] <= total + 0.001) else {
            validation = "When total time is supplied, each logged time must fit within it."; return false
        }
        var counts: [String: Int] = [:]
        for key in ["day", "nightLandings", "approachCount", "holds"] {
            let text = values[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Int(text.isEmpty ? "0" : text), value >= 0, value < 100_000 else {
                validation = "Landing, approach, and hold counts must be nonnegative whole numbers."; return false
            }
            counts[key] = value
        }
        draft.aircraft = reg + " · " + AircraftNames.display(model)
        draft.route = AirportRoute.formatted(draft.route); draft.date = FlightDates.string(date)
        draft.duration = editableHours(total); draft.pic = decimals["pic", default: 0]
        draft.night = decimals["night", default: 0]; draft.imc = decimals["imc", default: 0]
        draft.simulatedInstrument = decimals["sim", default: 0]; draft.dual = decimals["dual", default: 0]
        draft.instructor = decimals["instructor", default: 0]; draft.crossCountry = decimals["xc", default: 0]
        draft.dayLandings = counts["day", default: 0]; draft.nightLandings = counts["nightLandings", default: 0]
        draft.approachCount = counts["approachCount", default: 0]; draft.holds = counts["holds", default: 0]
        if importReview != nil {
            let imported = draft.facts.counts["unclassifiedLandings", default: 0]
            if imported > 0, let expected = originalLandingTotal, draft.landings != expected, !reviewConfirmed.contains("landings") {
                validation = "Assign the remaining landings or confirm the corrected counts."; return false
            }
        }
        equipment.category = draft.category
        equipment.apply(to: &draft)
        // Hidden legacy fields remain intact; new training confirmations live in milestones.
        for key in ["sic"] {
            let raw = detailValues[key, default: ""].replacingOccurrences(of: ",", with: ".")
            guard let value = Double(raw.isEmpty ? "0" : raw), value.isFinite, value >= 0,
                  total == 0 || key == "ground" || value <= total + 0.001 else {
                validation = "Check the additional experience times."; return false
            }
            draft.facts.amounts[key] = value
        }
        let originalPIC = originalFlight?.pic ?? draft.pic
        let keepLegacySolo = !soloChanged && !draft.facts.has("soloPIC") &&
            abs(originalPIC - decimals["pic", default: 0]) < 0.001 && draft.soloTime > 0
        if !keepLegacySolo {
            draft.facts.flags.remove("solo")
            draft.progress.removeValue(forKey: "solo")
            draft.confirmations.removeValue(forKey: "time-v1|solo")
            draft.facts.amounts["solo"] = soloSelected ? draft.pic : 0
            if soloSelected && draft.pic > 0 { draft.facts.flags.insert("soloPIC") }
            else { draft.facts.flags.remove("soloPIC") }
        }
        for key in ["numberFlights", "aeroTows", "groundLaunches", "poweredLaunches"] {
            let raw = detailValues[key, default: ""]
            guard let value = Int(raw.isEmpty ? "0" : raw), value >= 0, value < 100_000 else {
                validation = "Enter nonnegative whole numbers for takeoffs and launches."; return false
            }
            draft.facts.counts[key] = value
        }
        if importReview != nil {
            draft.facts.counts.removeValue(forKey: "unclassifiedLandings")
            draft.facts.text["importReviewStatus"] = "Reviewed before saving"
            draft.facts.text["importReviewedFields"] = Set((importReview?.fieldIssues ?? []).map(\.field)).subtracting(pendingReview.map(\.field)).sorted().joined(separator: ", ")
            for key in ["csvRouteEndpoints", "csvDeparture", "csvArrival"] { draft.facts.text.removeValue(forKey: key) }
        }
        return true
    }
    private func commitSave() {
        let reg = draft.registration
        // Preserve the legacy progress dictionary for compatibility, but never require new subset entries.
        let previous = store.fleet.first { $0.registration == reg } ?? (importAircraft?.registration == reg ? importAircraft : nil)
        let savedAircraft = equipment.aircraft(registration: reg, model: model, category: draft.category,
                                               previous: previous, info: aircraftInfo)
        if store.save(draft, photos: photos, aircraft: savedAircraft, featureChanges: equipment.synchronizedFeatures) {
            if let signature = draft.validSignature { store.rememberInstructor(signature.instructor) }
            if let scheduleID, let item = store.schedules.first(where: { $0.id == scheduleID }) { store.deleteSchedule(item) }
            if let onImportSaved { onImportSaved() } else { dismiss() }
        } else { validation = store.errorMessage ?? "The flight could not be saved." }
    }
}

struct FlightDetail: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    let flightID: UUID
    @State private var editing = false
    @State private var deleting = false
    @State private var sharingFlight = false
    @State private var images: [UIImage] = []
    var flight: Flight? { store.flights.first { $0.id == flightID } }
    var body: some View {
        SheetFrame(title: "Flight details") {
            if let f = flight {
                VStack(alignment: .leading, spacing: 20) {
                    if !f.isDevice { AircraftGallery(registration: f.registration, height: 210) }
                    else { Label("Simulator session · " + f.category, systemImage: "desktopcomputer").foregroundStyle(theme.cyan).logbookCard() }
                    Text(f.route).font(.system(size: 25, weight: .heavy, design: .rounded))
                    Text("\(f.shortDate) · \(f.registration) · \(f.aircraftModel)").foregroundStyle(theme.muted)
                    if !f.isDevice { Button { sharingFlight = true } label: {
                        Label("Share Flight", systemImage: "square.and.arrow.up").font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(theme.accent).padding(.horizontal, 18).padding(.vertical, 12)
                            .background(theme.raised).clipShape(Capsule())
                    }.buttonStyle(.plain) }
                    VStack(spacing: 13) {
                        SummaryRow(title: "Total time", value: hours(f.total) + " hours")
                        SummaryRow(title: "PIC time", value: hours(f.pic) + " hours")
                        SummaryRow(title: "SIC time", value: hours(f.sicTime) + " hours")
                        SummaryRow(title: "Solo time", value: hours(f.soloTime) + " hours")
                        SummaryRow(title: "Day / night landings", value: "\(f.dayLandings) / \(f.nightLandings)")
                        SummaryRow(title: "Night / IMC", value: "\(hours(f.night)) / \(hours(f.imc)) hours")
                        SummaryRow(title: "Dual received", value: hours(f.dual) + " hours")
                        SummaryRow(title: "Instructor time", value: hours(f.instructor) + " hours")
                        SummaryRow(title: "Cross-country", value: hours(f.crossCountry) + " hours")
                        SummaryRow(title: "Approaches / holds", value: "\(f.approachCount) / \(f.holds)")
                    }.logbookCard()
                    if !f.approaches.isEmpty { Text(f.approaches).logbookCard() }
                    if !f.notes.isEmpty { Text(f.notes).logbookCard() }
                    if let signature = f.signature { InstructorSignatureCard(signature: signature, valid: signature.matches(f)) }
                    SectionHeading(title: "Flight photos")
                    if images.isEmpty { Text("Tap Edit to add photos from this flight.").foregroundStyle(theme.muted) }
                    ForEach(images.indices, id: \.self) { index in
                        Image(uiImage: images[index]).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 18))
                    }
                    AccentButton(title: "Edit Flight") { editing = true }
                    Button("Delete Flight", role: .destructive) { deleting = true }.frame(maxWidth: .infinity)
                }
            } else { Text("This flight is no longer in the logbook.") }
        }
        .task(id: store.photoRevision) { if let flight { images = PhotoStore.load(flight) } }
        .sheet(isPresented: $editing) {
            if let flight {
                if flight.isDevice { SimulatorEditor(flight: flight) }
                else { FlightEditor(flight: flight) }
            }
        }
        .sheet(isPresented: $sharingFlight) { if let flight { FlightStoryView(flight: flight) } }
        .alert("Delete this flight?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { if let flight { store.delete(flight) }; dismiss() }
        } message: { Text("The flight will be removed from your logbook. Its photo files are retained.") }
    }
}

struct SummaryRow: View {
    @EnvironmentObject var theme: AppTheme
    var title: String
    var value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(theme.muted)
            Spacer()
            Text(value).fontWeight(.semibold).multilineTextAlignment(.trailing)
        }.font(.system(size: 15))
    }
}

// MARK: - Aircraft and totals

struct AircraftScreen: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @State private var selected: SavedAircraft?
    @State private var adding = false
    private var loggedAircraft: [SavedAircraft] {
        let registrations = Set(store.flights.filter { !$0.isDevice }.map { AircraftLookup.clean($0.registration) })
        return store.fleet.filter { registrations.contains(AircraftLookup.clean($0.registration)) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeading(title: "My Aircraft")
                ForEach(loggedAircraft) { aircraft in
                    let total = store.flights.filter { $0.registration == aircraft.registration }.reduce(0) { $0 + $1.total }
                    Button { selected = aircraft } label: {
                        HStack(spacing: 14) {
                            AircraftPhoto(registration: aircraft.registration).frame(width: 75, height: 67).clipShape(RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 6) {
                                Text(aircraft.registration).font(.system(size: 18, weight: .heavy, design: .rounded))
                                Text(aircraft.model).foregroundStyle(theme.muted).font(.subheadline)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(hours(total) + " h").font(.system(size: 21, weight: .bold, design: .rounded)).foregroundStyle(theme.accent)
                                Text("logged").foregroundStyle(theme.muted).font(.caption)
                            }
                        }.logbookCard(14)
                    }.buttonStyle(.plain)
                }
                if loggedAircraft.isEmpty { Text("Log a flight to see your aircraft and their logged hours here.").foregroundStyle(theme.muted).logbookCard() }
            }.padding(18)
        }.sheet(item: $selected) { AircraftProfile(aircraft: $0) }

    }
}

struct AddAircraftScreen: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    @State private var registration = ""
    @State private var model = ""
    @State private var autoModel = ""
    @State private var category = "Unspecified"
    @State private var categoryOverride = ""
    @State private var status = ""
    @State private var retry = 0
    @State private var equipment = AircraftEquipmentState()
    @State private var aircraftInfo: AircraftInfo?
    @State private var appliedRegistration = ""
    let existing: SavedAircraft?
    init(existing: SavedAircraft? = nil) {
        self.existing = existing
        _appliedRegistration = State(initialValue: existing?.registration ?? "")
        _registration = State(initialValue: existing?.registration ?? "")
        _model = State(initialValue: existing?.model ?? "")
        _autoModel = State(initialValue: existing?.model ?? "")
        _category = State(initialValue: existing?.category ?? "Unspecified")
        _aircraftInfo = State(initialValue: existing?.equipmentInfo)
        var selection = AircraftEquipmentState()
        if let existing { selection.update(model: existing.model, category: existing.category ?? "Unspecified", info: existing.equipmentInfo, saved: existing) }
        _equipment = State(initialValue: selection)
    }
    private func applyFeatures() {
        let saved = store.fleet.first { $0.registration == AircraftLookup.clean(registration) }
        equipment.update(model: model, category: category, info: aircraftInfo ?? saved?.equipmentInfo, saved: saved)
    }
    var body: some View {
        SheetFrame(title: existing == nil ? "Add Aircraft" : "Aircraft Equipment") {
            VStack(spacing: 18) {
                LogField(title: "Registration", value: $registration, hint: "N12345").textInputAutocapitalization(.characters)
                LogField(title: "Make and model", value: $model, hint: "Cessna 172S")
                Picker("Category / class", selection: Binding(get: { category }, set: {
                    category = $0; categoryOverride = AircraftLookup.clean(registration)
                })) {
                    ForEach(AircraftLookup.categories, id: \.self) { Text($0).tag($0) }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(theme.muted) }
                AircraftFeaturePicker(equipment: $equipment)
                Button("Retry lookup") { retry += 1 }.foregroundStyle(theme.cyan)
                AccentButton(title: "Save Aircraft") {
                    let reg = AircraftLookup.clean(registration)
                    let saved = store.fleet.first { $0.registration == reg }
                    let updated = equipment.aircraft(registration: reg, model: model, category: category, previous: saved, info: aircraftInfo)
                    let features = equipment.values.merging(equipment.synchronizedFeatures, uniquingKeysWith: { _, new in new })
                    if store.addAircraft(updated, featureChanges: features) { dismiss() }
                    else { status = store.errorMessage ?? "The aircraft could not be saved." }
                }.disabled(AircraftNames.registration(registration).isEmpty || !AircraftNames.hasMake(model))
            }
        }.task(id: "\(registration)-\(retry)") {
            let reg = AircraftLookup.clean(registration)
            let previous = store.fleet.first { $0.registration == reg }
            if appliedRegistration != reg {
                appliedRegistration = reg; categoryOverride = ""; equipment = AircraftEquipmentState()
                aircraftInfo = previous?.equipmentInfo
                if model == autoModel { model = previous?.model ?? ""; autoModel = model }
                category = previous?.category ?? "Unspecified"
            }
            guard reg.count >= 3 else { return }
            if let previous {
                if model.isEmpty || model == autoModel { model = previous.model; autoModel = model }
                if categoryOverride != reg { category = previous.category ?? category }
                status = "Filled from your saved aircraft."
            }
            applyFeatures()
            do { try await Task.sleep(nanoseconds: 700_000_000) } catch { return }
            status = "Looking up aircraft…"
            let info = await AircraftLookup.info(reg, refresh: retry > 0)
            guard !Task.isCancelled, AircraftLookup.clean(registration) == reg else { return }
            if let info {
                aircraftInfo = info
                if model.isEmpty || model == autoModel { model = info.model; autoModel = info.model }
                if categoryOverride != reg { category = previous?.category ?? info.suggestedCategory ?? "Unspecified" }
                applyFeatures()
                status = "Model, engine and available equipment detected. Saved corrections take priority."
            } else {
                applyFeatures()
                status = "Lookup unavailable. Saved details remain available; retry or enter missing details manually."
            }
        }.onChange(of: model) { _, _ in applyFeatures() }
            .onChange(of: category) { _, _ in applyFeatures() }
    }
}

struct AircraftProfile: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var photos: AircraftPhotos
    let aircraft: SavedAircraft
    @State private var selected: Flight?
    @State private var equipment = false
    var flights: [Flight] { store.sorted.filter { $0.registration == aircraft.registration } }
    var body: some View {
        SheetFrame(title: aircraft.registration) {
            VStack(alignment: .leading, spacing: 18) {
                AircraftGallery(registration: aircraft.registration)
                Text(aircraft.model).font(.title2.bold())
                Button("Review aircraft equipment") { equipment = true }.font(.subheadline)
                VStack(spacing: 14) {
                    SummaryRow(title: "Total time", value: hours(flights.reduce(0) { $0 + $1.total }) + " hours")
                    SummaryRow(title: "PIC time", value: hours(flights.reduce(0) { $0 + $1.pic }) + " hours")
                    SummaryRow(title: "Landings", value: String(flights.reduce(0) { $0 + $1.landings }))
                    SummaryRow(title: "Flights", value: String(flights.count))
                }.logbookCard()
                SectionHeading(title: "Related flights")
                ForEach(flights) { f in
                    Button { selected = f } label: { FlightRow(flight: f, compact: true) }.buttonStyle(.plain)
                    Divider()
                }
            }
        }.sheet(item: $selected) { FlightDetail(flightID: $0.id) }
            .sheet(isPresented: $equipment) { AddAircraftScreen(existing: store.fleet.first { $0.registration == aircraft.registration } ?? aircraft) }

    }
}

struct TotalsScreen: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @State private var filter = TotalsFilter()
    @State private var filtering = false
    @State private var group: FlightGroup?
    @State private var iacra = false
    @State private var checkride = false
    var flights: [Flight] { store.sorted.filter(filter.includes) }
    var body: some View {
        let totals = LogbookTotals(flights: flights)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    SectionHeading(title: "Flying Totals"); Spacer()
                    Button("Filter") { filtering = true }.fontWeight(.bold)
                        .foregroundStyle(theme.text).padding(.horizontal, 15).padding(.vertical, 8)
                        .overlay(Capsule().stroke(theme.line))
                }
                if filter.active { Text("Filtered · \(flights.count) flights").font(.caption).foregroundStyle(theme.cyan) }
                if !totals.hasHours {
                    Text(filter.active ? "No logged hours match these filters." : "Log a flight to see your accumulated hours here.")
                        .font(.subheadline).foregroundStyle(theme.muted).frame(maxWidth: .infinity, alignment: .leading).logbookCard()
                }
                totalsSection("Overall", rows: totals.overall)
                totalsSection("Logbook Times", rows: totals.standard)
                totalsSection("Category/Class", rows: totals.categories)
                totalsSection("Aircraft Features", rows: totals.features)
                actionCard("Checkride progress", "Track the time you still need for a certificate or rating.", tone: .blue) { checkride = true }
                actionCard("IACRA Assistant", "8710-1 aeronautical experience, calculated from your flights.", tone: .green) { iacra = true }
            }.padding(18)
        }.sheet(item: $group) { FlightListPopup(title: $0.title, ids: $0.ids) }
            .sheet(isPresented: $filtering) { TotalsFilterSheet(value: $filter) }
            .sheet(isPresented: $iacra) { IACRAView() }
            .sheet(isPresented: $checkride) { CheckrideView() }
    }
    @ViewBuilder private func totalsSection(_ title: String, rows: [LogbookTotal]) -> some View {
        if !rows.isEmpty {
            Text(title).font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(theme.muted).padding(.top, 12)
            ForEach(rows) { totalRow($0) }
        }
    }
    private func totalRow(_ row: LogbookTotal) -> some View {
        Button { group = FlightGroup(title: row.title, ids: row.flightIDs) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.title).font(.system(size: 17, weight: .semibold))
                    if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(theme.muted) }
                }
                Spacer()
                Text(row.displayValue).font(.system(size: 24, weight: .heavy, design: .rounded))
                Image(systemName: "chevron.right").foregroundStyle(theme.muted)
            }.logbookCard()
        }.buttonStyle(.plain)
    }
    private func actionCard(_ title: String, _ subtitle: String, tone: CardTone, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(.system(size: 19, weight: .heavy, design: .rounded))
                    Text(subtitle).font(.subheadline).foregroundStyle(theme.muted)
                }
                Spacer(); Image(systemName: "chevron.right").foregroundStyle(theme.muted).font(.caption)
            }.logbookCard(18, tone: tone)
        }.buttonStyle(.plain).padding(.top, 5)
    }
}

// Shared logged-time metrics. A known overlap is credited directly; only an
// uncertain intersection produces a review receipt, bound to the flight snapshot.
struct TotalsFilterSheet: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    @Binding var value: TotalsFilter
    @State private var draft: TotalsFilter
    init(value: Binding<TotalsFilter>) { _value = value; _draft = State(initialValue: value.wrappedValue) }
    private var features: [AircraftFeature] {
        [.complex, .highPerformance, .taa, .turbine, .tailwheel]
    }
    var body: some View {
        SheetFrame(title: "Filter totals") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Select any number of options. Match any selection in a group, and every selected group. Each flight is counted once.")
                    .font(.caption).foregroundStyle(theme.muted)
                choices("Dates for flights", $draft.dates, ["Last 30 days", "Last 90 days", "This year"].map { ($0, $0) })
                choices("Airports", $draft.airports, Array(Set(store.flights.flatMap(\.airports))).sorted().map { ($0, $0) })
                choices("Flight aircraft", $draft.aircraft, Array(Set(store.flights.filter { !$0.isDevice }.map(\.registration))).sorted().map { ($0, $0) })
                choices("Aircraft make / model", $draft.models, Array(Set(store.flights.filter { !$0.isDevice }.map(\.aircraftModel))).filter { !$0.isEmpty }.sorted().map { ($0, $0) })
                choices("Category / class", $draft.categories, AircraftLookup.categories.map { ($0, $0) })
                choices("Aircraft features", $draft.aircraftFeatures, features.map {
                    ($0.rawValue, $0 == .taa ? "TAA" : $0 == .turbine ? "Turbine" : $0 == .highPerformance ? "High Performance" : $0.title)
                })
                if draft.aircraftFeatures.count > 1 { Toggle("Require all selected aircraft features", isOn: $draft.requireAllAircraftFeatures).font(.caption) }
                choices("Flight features", $draft.flightFeatures, FlightMetric.allCases.map { ($0.rawValue, $0.title) } +
                    [("flightReview", "Flight review"), ("checkride", "Checkride"), ("tracking", "Instrument tracking")])
                if draft.flightFeatures.count > 1 { Toggle("Require all selected flight features", isOn: $draft.requireAllFlightFeatures).font(.caption) }
                HStack {
                    Button("Reset") { draft = TotalsFilter() }.foregroundStyle(theme.cyan)
                    AccentButton(title: "Apply filters") { value = draft; dismiss() }
                }
            }
        }
    }
    private func choices(_ title: String, _ selection: Binding<Set<String>>, _ options: [(String, String)]) -> some View {
        DisclosureGroup {
            if options.isEmpty { Text("No logged choices yet.").font(.caption).foregroundStyle(theme.muted) }
            ForEach(options, id: \.0) { option in
                HStack(spacing: 12) {
                    Text(option.1).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    Toggle(option.1, isOn: Binding(get: { selection.wrappedValue.contains(option.0) }, set: { on in
                        if on { selection.wrappedValue.insert(option.0) } else { selection.wrappedValue.remove(option.0) }
                    })).labelsHidden().toggleStyle(.switch).fixedSize().tint(theme.accent)
                        .padding(.trailing, 8)
                }.padding(.vertical, 5)
            }
        } label: {
            HStack { Text(title).fontWeight(.semibold); Spacer(); Text(selection.wrappedValue.isEmpty ? "All" : "\(selection.wrappedValue.count) selected").font(.caption).foregroundStyle(theme.muted) }
        }.logbookCard(18)
    }
}

struct IACRAView: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @State private var category = ExperienceCategory.airplane
    @State private var selected: ExperienceSelection?
    private var flights: [Flight] { store.sorted.filter(category.includes) }
    var body: some View {
        SheetFrame(title: "IACRA Assistant") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Experience category", selection: $category) {
                    ForEach(ExperienceCategory.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).logbookCard(tone: .green)
                Text("FAA 8710-1 · Record of pilot time").font(.caption).foregroundStyle(theme.cyan)
                ForEach(category.metrics) { metric in
                    let evidence = flights.compactMap { metric.evidence($0) }
                    Button { selected = ExperienceSelection(metric: metric) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(metric.iacraTitle)
                                if evidence.contains(where: { $0.credit.estimated }) { Text("Confirmation needed").font(.caption).foregroundStyle(theme.cyan) }
                            }
                            Spacer()
                            let total = evidence.reduce(0) { $0 + $1.credit.value }
                            Text(metric.isCount ? String(Int(total)) : hours(total)).fontWeight(.bold).foregroundStyle(theme.accent)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.muted)
                        }.logbookCard(13)
                    }.buttonStyle(.plain)
                }
                classHours
                Text("Suggested overlap credit is included. Review marked entries before submitting IACRA. Device hours are separate from aircraft hours; approved training credit remains subject to FAA limits.")
                    .font(.caption).foregroundStyle(theme.muted)
            }
        }.sheet(item: $selected) { selection in
            ExperienceFlightsView(metric: selection.metric, category: category, className: selection.className)
        }
    }
    @ViewBuilder private var classHours: some View {
        let classes: [String] = category == .airplane ? ["ASEL", "AMEL", "ASES", "AMES"] :
            category == .rotorcraft ? ["Helicopter", "Gyroplane"] : category == .lighter ? ["Balloon", "Airship"] :
            [.ffs, .ftd, .atd].contains(category) ? ["Airplane single-engine", "Airplane multiengine", "Helicopter"] : []
        if !classes.isEmpty { Text("Class totals").font(.headline).padding(.top, 6) }
        ForEach(classes, id: \.self) { name in
            let list = flights.filter { ExperienceCategory.matchesClass($0, name) }
            VStack(alignment: .leading, spacing: 8) {
                Text(name).font(.subheadline.bold())
                ForEach(category == .airplane ? [FlightMetric.pic, .sic, .dual] : [.total]) { metric in
                    Button { selected = ExperienceSelection(metric: metric, className: name) } label: {
                        HStack { Text(metric.iacraTitle); Spacer(); Text(hours(list.reduce(0) { $0 + metric.credit($1) })).foregroundStyle(theme.accent); Image(systemName: "chevron.right").font(.caption2) }
                    }.buttonStyle(.plain).font(.caption)
                }
            }.logbookCard(13)
        }
    }
}
struct ExperienceFlightsView: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    let metric: FlightMetric
    let category: ExperienceCategory
    var className: String? = nil
    @State private var selected: Flight?
    var body: some View {
        SheetFrame(title: metric.iacraTitle) {
            VStack(alignment: .leading, spacing: 14) {
                let entries = store.sorted.filter(category.includes).filter { f in className.map { ExperienceCategory.matchesClass(f, $0) } ?? true }.compactMap { metric.evidence($0) }
                if entries.isEmpty { Text("No contributing flights yet.").foregroundStyle(theme.muted).logbookCard() }
                ForEach(entries) { entry in
                    MilestoneEvidenceCard(entry: entry, unit: metric.isCount ? "events" : "hr") { selected = entry.flight }
                }
            }
        }.sheet(item: $selected) { FlightDetail(flightID: $0.id) }
    }
}

struct CheckrideView: View {
    @EnvironmentObject var theme: AppTheme
    @State private var goal: CheckrideGoal?
    var body: some View {
        SheetFrame(title: "Choose a goal") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Select the certificate or rating you want to track.").foregroundStyle(theme.muted)
                ForEach(CheckrideGoal.allCases) { item in
                    Button { goal = item } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) { Text(item.rawValue).font(.headline); Text(item.subtitle).font(.caption).foregroundStyle(theme.muted) }
                            Spacer(); Image(systemName: "chevron.right").foregroundStyle(theme.muted)
                        }.logbookCard()
                    }.buttonStyle(.plain)
                }
            }
        }.sheet(item: $goal) { GoalProgressView(goal: $0) }
    }
}

struct TrainingPathPicker: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    let goal: CheckrideGoal
    @Binding var selectedID: String
    var body: some View {
        SheetFrame(title: "Training path") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(["Part 61", "Part 141"], id: \.self) { part in
                    let paths = TrainingCatalog.paths(goal).filter { $0.part == part }
                    if !paths.isEmpty {
                        Text(part).font(.headline).foregroundStyle(theme.cyan)
                        ForEach(paths) { path in
                            Button { selectedID = path.id; dismiss() } label: {
                                HStack {
                                    Text(path.title).font(.subheadline); Spacer()
                                    Image(systemName: selectedID == path.id ? "checkmark.circle.fill" : "circle").foregroundStyle(theme.accent)
                                }.logbookCard(14)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

struct GoalProgressView: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var airports: AirportCatalog
    @ObservedObject private var ground = CourseGroundStore.shared
    let goal: CheckrideGoal
    @State private var pathID = ""
    @State private var commercialPath = "Solo"
    @State private var selectingPath = false
    @State private var selected: CheckrideMilestone?
    @State private var qualificationComplete = false
    private var path: TrainingPath? { TrainingCatalog.paths(goal).first { $0.id == pathID } ?? TrainingCatalog.paths(goal).first }
    private var rows: [CheckrideMilestone] {
        path.map { TrainingEngine.milestones(path: $0, flights: store.sorted, airports: airports.airports, commercialPath: commercialPath, ground: ground.records) } ?? []
    }
    var body: some View {
        SheetFrame(title: goal.rawValue) {
            VStack(alignment: .leading, spacing: 14) {
                if let path {
                    Button { selectingPath = true } label: {
                        HStack { Text(path.part + " · " + path.title).font(.subheadline.bold()); Spacer(); Image(systemName: "chevron.down").font(.caption) }
                            .foregroundStyle(theme.text).logbookCard(16, tone: .blue)
                    }.buttonStyle(.plain)
                    if path.part == "Part 141" {
                        Text("Confirm hours were completed as part of your Part 141 course.")
                            .font(.caption).foregroundStyle(theme.muted).logbookCard(14)
                    }
                    Text("\(rows.filter(\.met).count + (qualificationComplete && !path.qualification.isEmpty ? 1 : 0)) of \(rows.count + (path.qualification.isEmpty ? 0 : 1)) milestones completed")
                        .font(.headline).foregroundStyle(theme.cyan).logbookCard(tone: .blue)
                    Text("Tap a milestone to see contributing flights. Recent training uses today's date.")
                        .font(.caption).foregroundStyle(theme.muted)
                    ForEach(rows) { row in
                        Button { selected = row } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .top) {
                                    Text(row.title).font(.subheadline.bold()); Spacer()
                                    Text(row.progressText).font(.subheadline.bold()).foregroundStyle(theme.accent)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.muted)
                                }
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(theme.line)
                                        Capsule().fill(LinearGradient(colors: [theme.accent, theme.cyan], startPoint: .leading, endPoint: .trailing))
                                            .frame(width: geometry.size.width * min(1, max(0, row.value / row.target)))
                                    }
                                }.frame(height: 8)
                                Text(row.met ? "Completed" : row.hasEstimate ? "Confirmation needed" : "More qualifying records needed")
                                    .font(.caption).foregroundStyle(row.met ? Color.green : theme.muted)
                                Text(row.citation).font(.caption2).foregroundStyle(theme.muted)
                            }.foregroundStyle(theme.text).logbookCard(15)
                        }.buttonStyle(.plain)
                    }
                    if !path.qualification.isEmpty {
                        Toggle(isOn: $qualificationComplete) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Additional course / eligibility requirements").font(.subheadline.bold())
                                Text(path.qualification).font(.caption).foregroundStyle(theme.muted)
                            }
                        }.tint(theme.accent).logbookCard()
                            .onChange(of: qualificationComplete) { _, complete in UserDefaults.standard.set(complete, forKey: "trainingChecklist-v1|" + path.id) }
                    }
                    Text("Device credits, prior-course transfers and special regulatory exceptions require instructor review. This progress view tracks logged experience; it does not certify eligibility.")
                        .font(.caption).foregroundStyle(theme.muted)
                    Link("Review FAA requirements", destination: URL(string: path.part == "Part 141" ?
                        "https://www.ecfr.gov/current/title-14/chapter-I/subchapter-H/part-141" : "https://www.ecfr.gov/current/title-14/section-" + goal.regulation)!)
                        .foregroundStyle(theme.cyan)
                }
            }
        }.onAppear {
            pathID = UserDefaults.standard.string(forKey: "trainingPath-v2|" + goal.id) ?? ""
            commercialPath = UserDefaults.standard.string(forKey: "commercialPath") ?? "Solo"
            loadChecklist()
        }.onChange(of: pathID) { _, id in
            UserDefaults.standard.set(id, forKey: "trainingPath-v2|" + goal.id); loadChecklist()
        }.onChange(of: commercialPath) { _, value in UserDefaults.standard.set(value, forKey: "commercialPath") }
            .task(id: store.sorted.map { $0.route }.joined()) { await airports.load(store.flights.flatMap(\.airports)) }
            .sheet(isPresented: $selectingPath) { TrainingPathPicker(goal: goal, selectedID: $pathID) }
            .sheet(item: $selected) { item in
                if let path { MilestoneFlightsView(milestoneID: item.id, path: path, commercialPath: $commercialPath) }
            }
    }
    private func loadChecklist() { if let path { qualificationComplete = UserDefaults.standard.bool(forKey: "trainingChecklist-v1|" + path.id) } }
}

struct CourseGroundEditor: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var ground = CourseGroundStore.shared
    let pathID: String
    let original: CourseGroundRecord?
    @State private var date: Date
    @State private var amount: String
    @State private var notes: String
    @State private var problem: String?
    init(pathID: String, record: CourseGroundRecord? = nil) {
        self.pathID = pathID; original = record
        _date = State(initialValue: record?.date ?? Date())
        _amount = State(initialValue: record.map { entryHours($0.hours) } ?? "")
        _notes = State(initialValue: record?.notes ?? "")
    }
    var body: some View {
        SheetFrame(title: "Course ground instruction") {
            VStack(alignment: .leading, spacing: 18) {
                DatePicker("Instruction date", selection: $date, in: ...Date(), displayedComponents: .date)
                LogField(title: "Hours completed", value: $amount, hint: "0.0", keyboard: .decimalPad)
                LogField(title: "Notes (optional)", value: $notes, hint: "Instructor or topics covered")
                Text("Recorded for this training course. Ground instruction does not increase flight hours.")
                    .font(.caption).foregroundStyle(theme.muted)
                AccentButton(title: "Save ground instruction") {
                    guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 else { problem = "Enter hours above zero."; return }
                    var entry = original ?? CourseGroundRecord(pathID: pathID, date: date, hours: value, notes: notes)
                    entry.date = date; entry.hours = value; entry.notes = notes
                    if ground.save(entry) { dismiss() } else { problem = ground.error.isEmpty ? "Ground instruction could not be saved." : ground.error }
                }
            }
        }.alert("Ground instruction", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
    }
}

struct DutyApprovalCard: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    let flight: Flight
    let supervised: Bool
    let openFlight: () -> Void
    @State private var amount = ""
    @State private var problem: String?
    private var accepted: Bool { DutyCredit.hours(flight, supervised: supervised) > 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: openFlight) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(flight.shortDate + " · " + flight.registration).font(.subheadline.bold())
                        Text(flight.route).font(.caption).foregroundStyle(theme.muted)
                    }
                    Spacer(); Image(systemName: "chevron.right").font(.caption)
                }
            }.buttonStyle(.plain)
            Toggle(supervised ? "Supervised PIC duties as SIC" : "PIC duties with an instructor", isOn: Binding(get: { accepted }, set: { enabled in save(enabled) }))
                .font(.subheadline).tint(theme.accent)
            if accepted {
                HStack(spacing: 12) {
                    LogField(title: "Qualifying hours", value: $amount, hint: "0.0", keyboard: .decimalPad)
                    Button("Update") { save(true) }.foregroundStyle(theme.cyan)
                }
            }
            Text(supervised ? "Confirm you performed PIC duties under the PIC’s supervision while serving as SIC, with the required record." : "Confirm the selected hours were spent performing PIC duties with an authorized instructor and the required record.")
                .font(.caption).foregroundStyle(theme.muted)
        }.logbookCard(16)
            .onAppear { amount = editableHours(accepted ? DutyCredit.hours(flight, supervised: supervised) : DutyCredit.limit(flight, supervised: supervised)) }
            .onChange(of: flight.recordDigest) { _, _ in amount = editableHours(accepted ? DutyCredit.hours(flight, supervised: supervised) : DutyCredit.limit(flight, supervised: supervised)) }
            .alert("Check qualifying hours", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) { problem = nil }
            } message: { Text(problem ?? "") }
    }
    private func save(_ enabled: Bool) {
        let value = number(amount)
        guard !enabled || (value.isFinite && value > 0 && value <= DutyCredit.limit(flight, supervised: supervised) + 0.001) else {
            problem = supervised ? "Qualifying hours must fit within logged SIC time." : "Qualifying hours must fit within this flight’s total time."; return
        }
        if !store.confirm(flight.id, key: DutyCredit.key(supervised), statement: DutyCredit.statement(supervised), value: enabled ? value : 0, accepted: enabled) {
            problem = store.errorMessage ?? "The confirmation could not be saved."
        }
    }
}

struct MilestoneFlightsView: View {
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var airports: AirportCatalog
    @ObservedObject private var ground = CourseGroundStore.shared
    let milestoneID: String
    let path: TrainingPath
    @Binding var commercialPath: String
    @State private var selected: Flight?
    @State private var enteringGround = false
    @State private var editingGround: CourseGroundRecord?
    private var rule: TrainingRule? { path.rules.first { $0.citation + $0.title == milestoneID } }
    private var milestone: CheckrideMilestone? {
        TrainingEngine.milestones(path: path, flights: store.sorted, airports: airports.airports,
                                  commercialPath: commercialPath, ground: ground.records).first { $0.id == milestoneID }
    }
    private var selectablePath: Bool {
        guard let rule else { return false }
        return path.goal == "Commercial Pilot" && path.category != "Airship" &&
            (["path", "pathNight", "pathTakeoffs", "pathLandings", "pic", "xcPIC"].contains(rule.metric) || rule.scope == "path")
    }
    private var dutiesMode: Bool {
        guard let rule else { return false }
        return rule.metric.hasPrefix("duties") || rule.metric.hasPrefix("picOrDuties") || rule.scope == "duties" ||
            (selectablePath && commercialPath == "Instructor")
    }
    private var supervisedMode: Bool { rule?.metric.hasPrefix("command") == true }
    private var dutyFlights: [Flight] {
        guard let rule, dutiesMode || supervisedMode else { return [] }
        return store.sorted.filter { f in
            guard !f.isDevice, (f.flightDate ?? .distantFuture) <= Date() else { return false }
            let matches: Bool
            switch rule.scope {
            case "all": matches = true
            case "airplane": matches = f.isAirplane
            case "powered": matches = f.isPowered
            default: matches = TrainingEngine.categoryMatches(f, path.category)
            }
            return matches && (supervisedMode ? f.sicTime > 0 : f.soloTime <= 0 || DutyCredit.hours(f, supervised: false) > 0)
        }
    }
    private var groundRecords: [CourseGroundRecord] {
        rule?.metric == "ground" ? ground.records.filter { $0.pathID == path.id && $0.date <= Date() } : []
    }
    var body: some View {
        SheetFrame(title: milestone?.title ?? "Milestone") {
            if let milestone {
                VStack(alignment: .leading, spacing: 16) {
                    Text(milestone.requirement).font(.subheadline).foregroundStyle(theme.muted)
                    HStack { Text(milestone.citation); Spacer(); Text(milestone.progressText).fontWeight(.bold).foregroundStyle(theme.accent) }.logbookCard(tone: .blue)
                    if selectablePath { experienceChoice }
                    if rule?.metric == "ground" {
                        Button { editingGround = nil; enteringGround = true } label: { Label("Log course ground instruction", systemImage: "plus.circle") }.foregroundStyle(theme.accent)
                        ForEach(groundRecords) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(FlightDates.string(entry.date, format: "M/d/yy")); Spacer(); Text(hours(entry.hours) + " hr").foregroundStyle(theme.accent) }
                                if !entry.notes.isEmpty { Text(entry.notes).font(.caption).foregroundStyle(theme.muted) }
                                HStack {
                                    Button("Edit") { editingGround = entry; enteringGround = true }.foregroundStyle(theme.cyan)
                                    Spacer(); Button("Delete", role: .destructive) { ground.delete(entry) }
                                }.font(.caption)
                            }.logbookCard(14)
                        }
                        if !ground.error.isEmpty { Text(ground.error).font(.caption).foregroundStyle(theme.accent) }
                    }
                    if dutiesMode || supervisedMode {
                        Text(supervisedMode ? "Approve supervised PIC duties" : "Approve PIC duties with an instructor").font(.headline)
                        ForEach(dutyFlights) { f in DutyApprovalCard(flight: f, supervised: supervisedMode) { selected = f } }
                    }
                    if milestone.hasEstimate { Text("Confirm marked entries to complete this milestone.").font(.caption).foregroundStyle(theme.accent) }
                    if milestone.evidence.isEmpty && groundRecords.isEmpty {
                        Text(rule?.metric == "ground" ? "No ground instruction recorded yet." : "No contributing flights yet.").foregroundStyle(theme.muted).logbookCard()
                    }
                    ForEach(milestone.evidence) { entry in MilestoneEvidenceCard(entry: entry, unit: milestone.unit) { selected = entry.flight } }
                }
            }
        }.sheet(item: $selected) { FlightDetail(flightID: $0.id) }
            .sheet(isPresented: $enteringGround) { CourseGroundEditor(pathID: path.id, record: editingGround) }
    }
    private var experienceChoice: some View {
        HStack(spacing: 8) {
            ForEach(["Solo", "Instructor"], id: \.self) { choice in
                Button { withAnimation(.easeInOut(duration: 0.25)) { commercialPath = choice } } label: {
                    Text(choice == "Solo" ? "Solo" : "PIC duties with an instructor")
                        .font(.subheadline.bold()).multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 52)
                        .padding(.horizontal, 8).foregroundStyle(commercialPath == choice ? Color.black : theme.muted)
                        .background(commercialPath == choice ? theme.accent : theme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                }.buttonStyle(.plain)
            }
        }
    }
}

struct MilestoneEvidenceCard: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    let entry: MilestoneEvidence
    let unit: String
    let openFlight: () -> Void
    @State private var adjust = false
    @State private var creditText = ""
    @State private var problem: String?
    private var displayedCredit: String { unit == "hr" ? hours(entry.credit.value) + " hr" : "\(Int(entry.credit.value)) \(unit)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: openFlight) { FlightRow(flight: entry.flight, compact: true) }.buttonStyle(.plain)
            HStack {
                Text(entry.excluded ? "Excluded" : entry.confirmed ? "Confirmed contribution" : entry.needsConfirmation ? "Suggested contribution" : "Logged contribution")
                Spacer(); Text(displayedCredit).fontWeight(.bold)
            }.font(.caption).foregroundStyle(entry.confirmed ? theme.cyan : theme.accent)
            Text(entry.reason).font(.caption).foregroundStyle(theme.muted)
            if entry.needsConfirmation {
                Toggle(isOn: Binding(get: { entry.confirmed }, set: { accepted in confirm(accepted) })) {
                    Text(entry.statement).font(.subheadline)
                }.tint(theme.accent)
                if unit != "flight" {
                    Button(adjust ? "Use suggested credit" : "Only some of this flight qualifies") {
                        adjust.toggle()
                        creditText = unit == "hr" ? hours(entry.confirmed ? entry.credit.value : entry.potential) : String(Int(entry.confirmed ? entry.credit.value : entry.potential))
                    }.font(.caption).foregroundStyle(theme.cyan)
                    if adjust {
                        HStack {
                            LogField(title: unit == "hr" ? "Qualifying hours" : "Qualifying events", value: $creditText,
                                hint: unit == "hr" ? hours(entry.potential) : String(Int(entry.potential)), keyboard: unit == "hr" ? .decimalPad : .numberPad)
                            Button("Confirm") { confirm(true) }.foregroundStyle(theme.accent)
                        }
                        Text("Up to \(unit == "hr" ? hours(entry.potential) : String(Int(entry.potential))) from this flight's logged record.").font(.caption).foregroundStyle(theme.muted)
                    }
                }
                if !entry.confirmed {
                    Button(entry.excluded ? "Restore as a candidate" : "This flight does not apply") {
                        // A withdrawn confirmation is represented as zero accepted credit; restoring uses no receipt.
                        if entry.excluded { store.clearConfirmation(entry.flight.id, key: entry.confirmationKey) }
                        else { store.confirm(entry.flight.id, key: entry.confirmationKey, statement: entry.statement, value: 0, accepted: false) }
                    }.font(.caption).foregroundStyle(theme.muted)
                }
            }
        }.logbookCard()
            .alert("Check contribution", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) { problem = nil }
            } message: { Text(problem ?? "") }
    }
    private func confirm(_ accepted: Bool) {
        let raw = creditText.replacingOccurrences(of: ",", with: ".")
        let value = adjust && accepted ? Double(raw) : entry.potential
        guard let value, value.isFinite, value > 0, value <= entry.potential + 0.0001,
              unit == "hr" || value.rounded(.down) == value else {
            problem = "Enter qualifying credit above zero and no greater than the flight's suggested contribution."; return
        }
        if !store.confirm(entry.flight.id, key: entry.confirmationKey, statement: entry.statement, value: value, accepted: accepted) {
            problem = store.errorMessage ?? "The confirmation could not be saved."
        }
    }
}

struct FlightReviewCard: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @StateObject private var wings = WINGSStore()
    @State private var showRecords = false
    @State private var addingWINGS = false
    @State private var selected: Flight?
    private var reviews: [Flight] { store.sorted.filter { ($0.facts.has("flightReview") || $0.facts.has("checkride")) && ($0.flightDate ?? .distantFuture) <= Date() } }
    private var completed: Flight? { reviews.first(where: FlightReviewRules.qualifies) }
    private var wing: WINGSCompletion? { wings.records.first { $0.date <= Date() } }
    private var latestDate: Date? {
        [completed?.flightDate, wing?.date].compactMap { $0 }.max()
    }
    private var end: Date? { latestDate.flatMap { FlightReviewRules.endExclusive($0) } }
    private var current: Bool { end.map { Date() < $0 } ?? false }
    private var status: String {
        guard let end else { return "No review recorded" }
        let lastDay = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
        return (current ? "Current until:\n" : "Last review expired:\n") + FlightDates.string(lastDay, format: "M/d/yyyy")
    }
    private var description: String {
        if let wing, wing.date >= (completed?.flightDate ?? .distantPast) { return "WINGS phase · " + FlightDates.string(wing.date, format: "M/d/yy") }
        return completed.map { ($0.facts.has("checkridePassed") ? "Passed checkride · " : "Flight review · ") + $0.shortDate } ?? "Tap to add or review records"
    }
    var body: some View {
        Button { showRecords = true } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) { Text("Flight Review").font(.subheadline.bold()); Text("§61.56").font(.caption).foregroundStyle(theme.muted) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text(status).font(.system(size: 18, weight: .bold)).foregroundStyle(current ? Color.green : theme.accent)
                    Text(description).font(.caption).foregroundStyle(theme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(theme.muted)
            }.foregroundStyle(theme.text).logbookCard()
                .overlay(RoundedRectangle(cornerRadius: 22).stroke((current ? Color.green : theme.accent).opacity(0.35)))
        }.buttonStyle(.plain).sheet(isPresented: $showRecords) {
            SheetFrame(title: "Flight Review") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(status).font(.title3.bold()).foregroundStyle(current ? Color.green : theme.accent)
                    Text("Ensure the required ground training is complete and your instructor's endorsement is in your paper or digital logbook.")
                        .font(.caption).foregroundStyle(theme.muted)
                    AccentButton(title: "Completed the WINGS program") { addingWINGS = true }
                    ForEach(wings.records) { record in
                        VStack(alignment: .leading, spacing: 10) {
                            Text("WINGS phase completed · " + FlightDates.string(record.date, format: "M/d/yy")).font(.headline)
                            if let image = wings.image(record) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 230).clipShape(RoundedRectangle(cornerRadius: 12)) }
                            Button("Remove record", role: .destructive) { wings.delete(record) }.font(.caption)
                        }.logbookCard(tone: .blue)
                    }
                    ForEach(reviews) { f in
                        Button { selected = f } label: {
                            VStack(alignment: .leading, spacing: 9) {
                                FlightRow(flight: f, compact: true)
                                Text(FlightReviewRules.qualifies(f) ? "Qualifying review or passed practical test" : "Practical test not marked passed")
                                    .font(.caption).foregroundStyle(theme.muted)
                            }.logbookCard()
                        }.buttonStyle(.plain)
                    }
                    if reviews.isEmpty && wings.records.isEmpty { Text("Mark Flight review or a passed Checkride when logging a flight, or add your completed WINGS phase here.").font(.subheadline).foregroundStyle(theme.muted).logbookCard() }
                    if !wings.error.isEmpty { Text(wings.error).foregroundStyle(theme.accent).font(.caption) }
                    Link("Read 14 CFR 61.56", destination: URL(string: "https://www.ecfr.gov/current/title-14/section-61.56")!)
                }
            }.sheet(isPresented: $addingWINGS) { WINGSEditor(store: wings) }
                .sheet(item: $selected) { FlightDetail(flightID: $0.id) }
        }
    }
}

struct AirportFlipCard: View {
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var catalog: AirportCatalog
    let code: String
    let flights: [Flight]
    var activity: StatsAirportActivity? = nil
    @State private var flipped = false
    @State private var degrees = 0.0
    @State private var turning = false
    @State private var commenting = false
    @State private var readingComment = false
    @State private var notes = ""
    @State private var rating = 0
    private var info: AirportInfo? { catalog.airports[code] }
    private var arrivals: Int { activity?.arrivals ?? flights.reduce(0) { $0 + $1.airports.dropFirst().filter { $0 == code }.count } }
    var body: some View {
        Group {
            if flipped { back } else { front }
        }.frame(maxWidth: .infinity, alignment: .leading).frame(height: 280, alignment: .topLeading)
            .logbookCard(18, tone: .airport)
            .rotation3DEffect(.degrees(degrees), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
            .zIndex(turning ? 1 : 0)
            .contentShape(RoundedRectangle(cornerRadius: 22))
            .onTapGesture { flip() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(code) airport card. Tap to flip.")
            .onAppear {
                let saved = AirportPreferences.read(code); notes = saved.comment; rating = saved.rating
            }
            .sheet(isPresented: $commenting) {
                SheetFrame(title: "\(code) comment") {
                    VStack(alignment: .leading, spacing: 14) {
                        TextEditor(text: $notes).frame(minHeight: 170).padding(10).background(theme.raised).clipShape(RoundedRectangle(cornerRadius: 14))
                        Text("Saved on this device").font(.caption).foregroundStyle(theme.muted)
                    }.onChange(of: notes) { _, value in UserDefaults.standard.set(value, forKey: "airportNotes-" + code) }
                }
            }
            .sheet(isPresented: $readingComment) {
                SheetFrame(title: "\(code) comment") {
                    Text(notes).font(.body).foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
            }
    }
    private var front: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(code).font(.system(size: 28, weight: .black, design: .rounded)).foregroundStyle(theme.accent)
                Spacer()
                Text("Last visit \(activity?.lastVisit ?? flights.first?.shortDate ?? "—")").font(.caption).foregroundStyle(theme.muted)
            }
            Text(info?.name ?? code).font(.system(size: 18, weight: .heavy, design: .rounded)).lineLimit(2)
            HStack(alignment: .top, spacing: 7) {
                metric(String(arrivals), "times flown to")
                Rectangle().fill(theme.line).frame(width: 1, height: 45)
                metric(String(activity?.flightIDs.count ?? flights.count), "flights")
                Rectangle().fill(theme.line).frame(width: 1, height: 45)
                metric(hours(activity?.total ?? flights.reduce(0) { $0 + $1.total }), "hours connected")
            }
            Rectangle().fill(theme.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 7) {
                Text("RECENT ROUTES").font(.system(size: 11)).tracking(1.3).foregroundStyle(theme.accent)
                Text((activity?.recentRoutes ?? Array(flights.prefix(2)).map { AirportRoute.formatted($0.route) }).joined(separator: "\n")).font(.subheadline).lineLimit(3)
            }
            Spacer(minLength: 0)
            Text("Tap for airport details").font(.system(size: 10)).foregroundStyle(theme.muted).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.system(size: 21, weight: .black, design: .rounded)).foregroundStyle(theme.cyan).minimumScaleFactor(0.6).lineLimit(1)
            Text(label).font(.system(size: 10)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
    private var back: some View {
        VStack(alignment: .leading, spacing: notes.isEmpty ? 6 : 5) {
            Text("AIRPORT DETAILS").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(theme.cyan)
            Text(info?.name ?? code).font(.system(size: 18, weight: .heavy, design: .rounded)).lineLimit(2)
            let unavailable = catalog.loading.contains(code) ? "Loading…" : "Not available"
            detail("City", info?.location.isEmpty == false ? info!.location : unavailable)
            let tower = info?.towered.map { $0 ? "Towered" : "Non-towered" }
            let airportType = [info?.use, tower].compactMap { $0 }.joined(separator: " · ")
            detail("Type", airportType.isEmpty ? unavailable : airportType)
            detail("Field elevation", info?.elevation.map { "\(Int($0.rounded())) ft MSL" } ?? unavailable)
            HStack(spacing: 8) {
                Text("YOUR RATING").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(theme.muted)
                Spacer(minLength: 0)
                ForEach(1...5, id: \.self) { star in
                    Button {
                        rating = star == rating ? 0 : star
                        UserDefaults.standard.set(rating, forKey: "airportRating-" + code)
                    } label: { Image(systemName: "star.fill").font(.system(size: 22)).foregroundStyle(star <= rating ? theme.accent : theme.muted) }
                        .buttonStyle(.plain).accessibilityLabel("\(star) stars")
                }
            }
            HStack {
                Button(notes.isEmpty ? "Add comment" : "Edit comment") { commenting = true }
                    .font(.caption).foregroundStyle(theme.cyan).padding(9).overlay(Capsule().stroke(theme.cyan.opacity(0.5)))
                Spacer()
                if catalog.loading.contains(code) {
                    ProgressView().controlSize(.small).tint(theme.cyan).accessibilityLabel("Loading airport details")
                } else if catalog.failed.contains(code) || info?.elevation == nil || info?.use == nil {
                    Button("Retry data") { Task { await catalog.load([code], refresh: true) } }.font(.caption).foregroundStyle(theme.cyan)
                }
            }.buttonStyle(.plain)
            if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { readingComment = true } label: {
                    Text(notes).font(.system(size: 12)).foregroundStyle(theme.text)
                        .lineLimit(2).truncationMode(.tail).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 16, maxHeight: 32, alignment: .topLeading)
                }.buttonStyle(.plain).layoutPriority(-1)
                    .accessibilityLabel("Read airport comment").accessibilityHint("Opens the full comment")
            }
            Spacer(minLength: 0)
            Text((info?.source ?? (catalog.loading.contains(code) ? "Loading…" : "Data unavailable")) + (info?.effectiveDate.map { " · " + $0 } ?? "") + " · Not for navigation")
                .font(.system(size: 9)).foregroundStyle(theme.muted).lineLimit(2)
            Text("Tap the card to return").font(.system(size: 10)).foregroundStyle(theme.muted).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(spacing: 6) {
            HStack { Text(title).foregroundStyle(theme.muted); Spacer(); Text(value).fontWeight(.bold).multilineTextAlignment(.trailing).lineLimit(2) }.font(.system(size: 13))
            Rectangle().fill(theme.line).frame(height: 1)
        }
    }
    private func flip() {
        guard !turning, !commenting, !readingComment else { return }
        turning = true
        Task { @MainActor in
            withAnimation(.easeIn(duration: 0.25)) { degrees = 90 }
            try? await Task.sleep(nanoseconds: 250_000_000)
            flipped.toggle()
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { degrees = -90 }
            await Task.yield()
            withAnimation(.easeOut(duration: 0.3)) { degrees = 0 }
            try? await Task.sleep(nanoseconds: 300_000_000)
            turning = false
        }
    }
}

struct FleetRangeSheet: View {
    @EnvironmentObject var theme: AppTheme
    let flights: [Flight]
    let rangeTitle: String
    @Binding var groupingRawValue: String
    @State private var selected: FlightGroup?
    @State private var detent: PresentationDetent = .medium
    private var grouping: FleetGrouping? { FleetGrouping(rawValue: groupingRawValue) }
    private var groups: [FleetRangeGroup] {
        guard let grouping else { return [] }
        return FleetRange.groups(flights, by: grouping)
    }
    private var subtitle: String {
        guard let grouping else { return "Choose how to display your fleet" }
        return "\(groups.count) \(grouping.countLabel(groups.count))"
    }
    var body: some View {
        SheetFrame(title: "Fleet Range", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    groupingButton(.variants)
                    groupingButton(.models)
                }
                Text(rangeTitle).font(.caption).foregroundStyle(theme.muted)
                if let grouping {
                    VStack(spacing: 14) {
                        ForEach(groups) { item in
                            Button { selected = FlightGroup(title: item.title, ids: Set(item.flights.map(\.id))) } label: {
                                VStack(alignment: .leading, spacing: 9) {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(item.title).font(.system(size: 22, weight: .heavy, design: .rounded))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 8)
                                        Text(hours(item.total) + " hr").font(.system(size: 21, weight: .bold, design: .rounded))
                                            .lineLimit(1).minimumScaleFactor(0.8)
                                    }
                                    if grouping == .models {
                                        Text(item.variants.joined(separator: " · ")).font(.subheadline).foregroundStyle(theme.muted)
                                    }
                                    Text("\(item.flights.count) \(item.flights.count == 1 ? "flight" : "flights")")
                                        .font(.subheadline).foregroundStyle(theme.muted)
                                }.foregroundStyle(theme.text).logbookCard(18)
                            }.buttonStyle(.plain)
                        }
                        if groups.isEmpty {
                            Text("No flights with an aircraft model in this date range.")
                                .foregroundStyle(theme.muted).frame(maxWidth: .infinity, alignment: .leading).logbookCard()
                        }
                    }.id(grouping).transition(.opacity)
                } else {
                    Text("Aircraft models group versions such as Cessna 172N and 172P under Cessna 172. Model variants show each version separately.")
                        .font(.subheadline).foregroundStyle(theme.muted).logbookCard()
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .sheet(item: $selected) { FlightListPopup(title: $0.title, ids: $0.ids) }
    }
    private func groupingButton(_ option: FleetGrouping) -> some View {
        let active = grouping == option
        return Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                groupingRawValue = option.rawValue
                detent = FleetRange.groups(flights, by: option).count > 2 ? .large : .medium
            }
        } label: {
            Text(option.rawValue).font(.system(size: 16, weight: active ? .bold : .medium, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.75).frame(maxWidth: .infinity).padding(.vertical, 16)
                .foregroundStyle(active ? Color(hex: 0x15202A) : theme.muted)
                .background(LinearGradient(colors: active ? [theme.accent, theme.accent.opacity(0.9)] : [theme.raised, theme.surface], startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(active ? theme.accent : theme.line))
        }.buttonStyle(.plain).accessibilityAddTraits(active ? .isSelected : [])
    }
}

// Primitive, Sendable snapshots keep logbook parsing and aggregation off the UI actor.
struct StatsMemoryPhoto: View {
    @EnvironmentObject var theme: AppTheme
    let reference: FlightMemoryReference
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                theme.raised
                if let image { Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped() }
                else if failed { Image(systemName: "photo").font(.title2).foregroundStyle(theme.muted).accessibilityLabel("Photo unavailable") }
                else { ProgressView().tint(theme.cyan) }
            }
        }.task(id: reference.id) {
            image = nil; failed = false
            let data = try? await FlightMemoryLoader.shared.thumbnail(reference, folder: PhotoStore.folder)
            guard !Task.isCancelled else { return }
            image = data.flatMap { UIImage(data: $0) }
            failed = image == nil
        }
    }
}

struct StatsScreen: View {
    @EnvironmentObject var store: FlightStore
    var body: some View { StatsDashboard(model: store.stats) }
}
struct StatsDashboard: View {
    @ObservedObject var model: StatsModel
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var catalog: AirportCatalog
    @State private var range: TimeRange = .all
    @State private var airport: AirportInfo?
    @State private var selected: Flight?
    @State private var group: FlightGroup?
    @State private var selectedAircraft: SavedAircraft?
    @State private var showingFleetRange = false
    @AppStorage("fleetRangeGrouping") private var fleetGroupingRawValue = ""
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var preparingMap = true
    @State private var framedRouteKey = ""
    @State private var memoryPosition: String?
    private var fleetGrouping: FleetGrouping { FleetGrouping(rawValue: fleetGroupingRawValue) ?? .models }
    private var fleetCount: Int { fleetGrouping == .models ? summary.modelCount : summary.variantCount }
    private var summary: StatsSnapshot { model.snapshot }
    private var routeRequestKey: String { summary.key }
    private var missingMapCodes: [String] {
        codes.filter { code in
            guard let info = catalog.airports[code] else { return true }
            return !info.latitude.isFinite || !info.longitude.isFinite || !CLLocationCoordinate2DIsValid(info.coordinate)
        }.sorted()
    }
    private var codes: [String] { summary.codes }
    private func arrivals(_ code: String) -> Int { summary.airports[code]?.arrivals ?? 0 }
    private var mostFlown: String? { summary.mostFlown }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                HStack {
                    SectionHeading(title: "Flight map"); Spacer()
                    Menu(range.rawValue) { Picker("Date range", selection: $range) { ForEach(TimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) } } }
                        .foregroundStyle(theme.text).padding(10).overlay(Capsule().stroke(theme.line))
                }
                routeMap
                HStack(spacing: 20) {
                    Label("Recent route", systemImage: "circle.fill").foregroundStyle(theme.accent)
                    Label("Other flights", systemImage: "circle.fill").foregroundStyle(theme.cyan)
                }.font(.caption).frame(maxWidth: .infinity)
                SectionHeading(title: "Flight memories")
                if model.memories.isEmpty {
                    HStack(spacing: 15) {
                        Image(systemName: "sparkle").font(.title2).foregroundStyle(theme.cyan).frame(width: 46, height: 46)
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.cyan.opacity(0.5)))
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Upload photos to your flights").font(.system(size: 18, weight: .heavy, design: .rounded))
                            Text("to see your past memories here.").foregroundStyle(theme.muted).font(.subheadline)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 108, alignment: .center).logbookCard(22, tone: .blue)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 0) {
                            ForEach(model.memories) { memory in
                                Button { selected = store.flight(memory.flightID) } label: {
                                    StatsMemoryPhoto(reference: memory).frame(height: 210)
                                        .overlay(alignment: .bottomLeading) {
                                            if let f = summary.byID[memory.flightID] {
                                                Text("\(f.shortDate) · \(f.route)")
                                                    .font(.subheadline.bold()).foregroundStyle(.white).padding(14).background(.black.opacity(0.5))
                                            }
                                        }
                                }.buttonStyle(.plain).containerRelativeFrame(.horizontal).id(memory.id)
                            }
                        }
                        .scrollTargetLayout()
                    }.scrollTargetBehavior(.paging).scrollPosition(id: $memoryPosition)
                        .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 22))
                }
                HStack { SectionHeading(title: "Airports visited"); Spacer(); Text("\(codes.count) airports").font(.caption).foregroundStyle(theme.muted) }
                if codes.isEmpty {
                    Text("No airport activity yet.").font(.subheadline).foregroundStyle(theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).logbookCard(20, tone: .airport)
                } else {
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 14) {
                            ForEach(codes, id: \.self) { code in
                                AirportFlipCard(code: code, flights: [], activity: summary.airports[code])
                                    .frame(width: max(250, geometry.size.width * 0.84))
                            }
                        }
                        .padding(.top, 6).padding(.bottom, 16)
                    }.scrollClipDisabled()
                }.frame(height: 340)
                }
                overview
                longestCard
                insights
            }.padding(18)
        }.task(id: "\(store.flightRevision)|\(range.rawValue)") {
                await model.update(store.statsInput, revision: store.flightRevision, range: range.rawValue)
            }
            .task(id: routeRequestKey) { if !routeRequestKey.isEmpty { await prepareMap() } }
            .task(id: routeRequestKey + "|photos:\(store.photoRevision)") {
                await model.updateMemories(revision: store.photoRevision, folder: PhotoStore.folder)
            }
            .task(id: routeRequestKey + "|coords:\(catalog.coordinateRevision)") {
                // Coalesce streamed airport updates instead of recalculating for each one.
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                guard !routeRequestKey.isEmpty else { return }
                fitMapIfNeeded()
                let coordinates = Dictionary(uniqueKeysWithValues: codes.compactMap { code -> (String, StatsCoordinate)? in
                    guard let info = catalog.airports[code], CLLocationCoordinate2DIsValid(info.coordinate) else { return nil }
                    return (code, StatsCoordinate(latitude: info.latitude, longitude: info.longitude))
                })
                await model.updateDistances(coordinates)
            }
            .sheet(item: $airport) { AirportDetail(airport: $0) }
            .sheet(item: $selected) { FlightDetail(flightID: $0.id) }
            .sheet(item: $group) { FlightListPopup(title: $0.title, ids: $0.ids) }
            .sheet(item: $selectedAircraft) { AircraftProfile(aircraft: $0) }
            .sheet(isPresented: $showingFleetRange) {
                FleetRangeSheet(flights: summary.flights.compactMap { store.flight($0.id) }, rangeTitle: range.rawValue, groupingRawValue: $fleetGroupingRawValue)
            }
    }
    private var overview: some View {
        let total = summary.total
        return HStack(spacing: 12) {
            overviewTile("LOGBOOK OVERVIEW", String(summary.flights.count), "FLIGHTS LOGGED", String(codes.count), "airports visited", theme.accent)
            overviewTile("TIME IN THE AIR", hours(total) + " h", "TOTAL FLIGHT TIME", hours(summary.flights.isEmpty ? 0 : total / Double(summary.flights.count)) + " h", "average flight", theme.cyan)
        }
    }
    private func overviewTile(_ kicker: String, _ value: String, _ label: String, _ detail: String, _ detailLabel: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(kicker).font(.system(size: 10)).tracking(1.3).foregroundStyle(theme.cyan).lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(.system(size: 35, weight: .black, design: .rounded)).foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.5)
            Text(label).font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(1).lineLimit(2)
            VStack(alignment: .leading, spacing: 3) {
                Text(detail).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(theme.cyan)
                Text(detailLabel).font(.caption).foregroundStyle(theme.muted)
            }
        }.frame(maxWidth: .infinity, minHeight: 170, alignment: .leading).logbookCard(16)
    }
    private var longestCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("LONGEST FLIGHTS").font(.system(size: 11)).tracking(1.3).foregroundStyle(theme.cyan)
            if model.longest.isEmpty { Text("No route activity yet.").font(.subheadline).foregroundStyle(theme.muted) }
            ForEach(Array(model.longest.enumerated()), id: \.element.id) { index, item in
                Button { selected = store.flight(item.flightID) } label: {
                    HStack(spacing: 10) {
                        Text(String(index + 1)).font(.system(size: 14, weight: .black)).foregroundStyle(Color(hex: 0x26343E))
                            .frame(width: 25, height: 25).background(index == 0 ? theme.accent : index == 1 ? Color(hex: 0xC4CBD2) : Color(hex: 0xC68554)).clipShape(Circle())
                        Text("\(Int(item.distance.rounded())) NM").font(.system(size: index == 0 ? 32 : 22, weight: .black, design: .rounded))
                            .foregroundStyle(index == 0 ? theme.accent : theme.text).lineLimit(1).minimumScaleFactor(0.6)
                        Text(item.route).font(.system(size: index == 0 ? 13 : 12)).foregroundStyle(index == 0 ? theme.text : theme.muted).lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }.buttonStyle(.plain)
                if index == 0 { Rectangle().fill(theme.line).frame(height: 1) }
            }
            Text("Direct airport-to-airport distance estimates, not actual flown tracks.").font(.system(size: 10)).foregroundStyle(theme.muted)
        }.logbookCard()
    }
    private var insights: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button { showingFleetRange = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "airplane").font(.title2).foregroundStyle(theme.accent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("FLEET RANGE").font(.system(size: 10)).tracking(1).foregroundStyle(theme.muted)
                            Text(String(fleetCount)).font(.system(size: 25, weight: .heavy, design: .rounded))
                            Text(fleetGrouping.countLabel(fleetCount)).font(.caption).foregroundStyle(theme.muted)
                        }
                    }.foregroundStyle(theme.text).frame(maxWidth: .infinity, minHeight: 95, alignment: .leading).logbookCard(15)
                }.buttonStyle(.plain).accessibilityLabel("Fleet Range").accessibilityHint("Choose aircraft models or model variants")
                Button {
                    if let reg = mostFlown { selectedAircraft = store.fleet.first { $0.registration == reg } }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("MOST FLOWN").font(.system(size: 10)).tracking(1).foregroundStyle(theme.muted)
                        Text(mostFlown ?? "—").font(.system(size: 21, weight: .heavy, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                        if let reg = mostFlown {
                            Text("\(summary.mostFlownModel) · \(summary.registrationCounts[reg, default: 0]) flights")
                                .font(.caption).foregroundStyle(theme.muted).lineLimit(2)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 95, alignment: .leading).logbookCard(15)
                }.buttonStyle(.plain)
            }
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "scope").foregroundStyle(theme.cyan).font(.title2)
                VStack(alignment: .leading, spacing: 12) {
                    Text("TOP AIRPORTS BY FLIGHT ACTIVITY").font(.system(size: 10)).tracking(1).foregroundStyle(theme.muted)
                    ForEach(Array(codes.prefix(3).enumerated()), id: \.element) { index, code in
                        Button { group = FlightGroup(title: code, ids: Set(summary.airports[code]?.flightIDs ?? [])) } label: {
                            HStack { Text("\(index + 1).  \(code)"); Spacer(); Text("\(arrivals(code)) visits").fontWeight(.bold).foregroundStyle(theme.cyan) }.font(.subheadline)
                        }.buttonStyle(.plain)
                    }
                    if codes.isEmpty { Text("No airport activity yet.").font(.caption).foregroundStyle(theme.muted) }
                }
            }.logbookCard()
        }
    }
    private var routeMap: some View {
        let routeColor = theme.accent
        let otherRouteColor = theme.cyan
        return Map(position: $mapPosition, interactionModes: [.pan, .zoom]) {
            ForEach(codes, id: \.self) { code in
                if let info = catalog.airports[code] {
                    Annotation(code, coordinate: info.coordinate) {
                        Circle().fill(routeColor).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
            ForEach(summary.otherLegs) { leg in
                if let a = catalog.airports[leg.from], let b = catalog.airports[leg.to] {
                    MapPolyline(coordinates: [a.coordinate, b.coordinate]).stroke(otherRouteColor, lineWidth: 2)
                }
            }
            ForEach(summary.recentLegs) { leg in
                if let a = catalog.airports[leg.from], let b = catalog.airports[leg.to] {
                    MapPolyline(coordinates: [a.coordinate, b.coordinate]).stroke(routeColor, lineWidth: 4)
                }
            }
        }.mapStyle(.standard(elevation: .flat)).frame(height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 24)).overlay(RoundedRectangle(cornerRadius: 24).stroke(theme.line))
            .overlay {
                if summary.key.isEmpty || model.calculating && codes.isEmpty {
                    ProgressView("Preparing flight map…").tint(theme.cyan).frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.surface)
                } else if codes.isEmpty {
                    Text("Log a route to see your flights on the map.").padding().background(theme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                } else if preparingMap && !missingMapCodes.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView().tint(theme.cyan)
                        Text("Loading flight map…").font(.subheadline.bold())
                        Text("\(codes.count - missingMapCodes.count) of \(codes.count) airports ready")
                            .font(.caption).foregroundStyle(theme.muted)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                } else if !missingMapCodes.isEmpty {
                    VStack(spacing: 8) {
                        Text("Airport coordinates unavailable: " + missingMapCodes.joined(separator: ", "))
                            .font(.caption).multilineTextAlignment(.center)
                        Button("Retry map") { Task { await prepareMap(refresh: true) } }
                            .font(.subheadline.bold()).foregroundStyle(theme.cyan)
                    }.padding(12).background(theme.surface).clipShape(RoundedRectangle(cornerRadius: 12)).padding(12)
                }
            }
    }
    private func prepareMap(refresh: Bool = false) async {
        let requestKey = routeRequestKey
        let requestedCodes = codes
        preparingMap = !missingMapCodes.isEmpty
        if !preparingMap { fitMapIfNeeded() }
        await catalog.load(requestedCodes, refresh: refresh)
        guard !Task.isCancelled, requestKey == routeRequestKey else { return }
        fitMapIfNeeded()
        preparingMap = false
    }
    private func fitMapIfNeeded() {
        let resolved = codes.compactMap { catalog.airports[$0] }
        let frameKey = routeRequestKey + "|" + resolved.map { "\($0.code):\($0.latitude),\($0.longitude)" }.joined(separator: "|")
        guard frameKey != framedRouteKey else { return }
        let coordinates = resolved.map(\.coordinate)
        guard let bounds = AirportMapGeometry.mapRect(coordinates) else { return }
        mapPosition = .rect(bounds)
        framedRouteKey = frameKey
    }
}

struct AirportDetail: View {
    @EnvironmentObject var store: FlightStore
    let airport: AirportInfo
    @State private var notes = ""
    @State private var rating = 0
    var body: some View {
        SheetFrame(title: airport.code) {
            VStack(alignment: .leading, spacing: 20) {
                Text(airport.name).font(.title2.bold())
                Text(airport.location).foregroundStyle(.secondary)
                HStack {
                    ForEach(1...5, id: \.self) { star in
                        Button { rating = star; UserDefaults.standard.set(star, forKey: "airportRating-" + airport.code) } label: {
                            Image(systemName: star <= rating ? "star.fill" : "star").font(.title2)
                        }
                    }
                }
                LogField(title: "Your airport notes", value: $notes, hint: "Add comments about this airport")
                Text("Saved on this device").font(.caption).foregroundStyle(.secondary)
                SectionHeading(title: "Related flights")
                ForEach(store.sorted.filter { $0.airports.contains(airport.code) }) { FlightRow(flight: $0, compact: true) }
            }
        }.onAppear {
            let saved = AirportPreferences.read(airport.code); notes = saved.comment; rating = saved.rating
        }.onChange(of: notes) { _, value in UserDefaults.standard.set(value, forKey: "airportNotes-" + airport.code) }
    }
}

// MARK: - Calendar and local reminders

struct CalendarScreen: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @State private var month = Date()
    @State private var chosenDay: Date?
    @State private var editing: ScheduledFlight?
    @State private var scanning = false
    private var calendar: Calendar { Calendar.current }
    private var start: Date { calendar.date(from: calendar.dateComponents([.year, .month], from: month))! }
    private var monthFlights: [ScheduledFlight] {
        store.schedules.filter { calendar.isDate($0.date, equalTo: month, toGranularity: .month) }.sorted { $0.date < $1.date }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionHeading(title: "Schedule flights")
                        Text("Plan upcoming flights before they become logbook entries.").font(.subheadline).foregroundStyle(theme.muted)
                    }
                    Spacer()
                    Button("+ Add") { newSchedule() }.foregroundStyle(theme.accent).fontWeight(.bold)
                }
                HStack {
                    monthButton(-1, "chevron.left")
                    Spacer()
                    Text(FlightDates.string(month, format: "MMMM yyyy")).font(.system(size: 19, weight: .heavy, design: .rounded))
                    Spacer()
                    monthButton(1, "chevron.right")
                }.logbookCard()
                monthGrid.logbookCard(16)
                HStack {
                    Text("Upcoming flights").font(.system(size: 20, weight: .bold, design: .rounded))
                    Spacer()
                    Button("Upload schedule photo") { scanning = true }.font(.system(size: 11)).foregroundStyle(theme.text)
                        .padding(.horizontal, 10).padding(.vertical, 9).overlay(Capsule().stroke(theme.line))
                }
                if monthFlights.isEmpty {
                    Text("No flights scheduled this month. Add one manually or upload a schedule photo to start planning.")
                        .foregroundStyle(theme.muted).multilineTextAlignment(.center).padding(.vertical, 16).logbookCard()
                }
                ForEach(monthFlights) { item in
                    Button { editing = item } label: {
                        HStack(spacing: 14) {
                            VStack(spacing: 1) {
                                Text(FlightDates.string(item.date, format: "d")).font(.system(size: 27, weight: .black, design: .rounded)).foregroundStyle(theme.accent)
                                Text(FlightDates.string(item.date, format: "EEE").uppercased()).font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(theme.muted)
                            }.frame(width: 44)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title.isEmpty ? "Flight" : item.title).font(.system(size: 17, weight: .heavy, design: .rounded))
                                Text(bookingTimes(item))
                                    .font(.system(size: 12)).foregroundStyle(theme.muted)
                                if !item.registration.isEmpty || !item.route.isEmpty {
                                    Text([item.registration, AirportRoute.formatted(item.route)].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(.system(size: 12)).foregroundStyle(theme.muted)
                                }
                                if let name = item.instructorName, !name.isEmpty {
                                    Text("CFI: " + name).font(.system(size: 11)).foregroundStyle(theme.muted)
                                }
                            }
                            Spacer(minLength: 0)
                            Text(item.isGround ? "GROUND" : "SCHEDULED").font(.system(size: 10)).foregroundStyle(theme.cyan)
                        }.logbookCard(16)
                    }.buttonStyle(.plain)
                }
                FlightNotificationSettings()
            }.padding(18)
        }.sheet(item: $editing) { ScheduleEditor(item: $0) }
            .sheet(isPresented: $scanning) { ScanReview(schedule: true) }
    }
    private var monthGrid: some View {
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: month)!.count
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 10) {
            ForEach(0..<7, id: \.self) { index in
                Text(calendar.shortWeekdaySymbols[(calendar.firstWeekday - 1 + index) % 7]).font(.caption).foregroundStyle(theme.muted)
            }
            ForEach(0..<(offset + count), id: \.self) { cell in
                if cell < offset { Color.clear.frame(height: 40) }
                else {
                    let day = calendar.date(byAdding: .day, value: cell - offset, to: start)!
                    let hasFlight = monthFlights.contains { calendar.isDate($0.date, inSameDayAs: day) }
                    let selected = chosenDay.map { calendar.isDate($0, inSameDayAs: day) } ?? false
                    Button { chosenDay = day } label: {
                        VStack(spacing: 3) {
                            Text(String(cell - offset + 1)).font(.system(size: 18, weight: calendar.isDateInToday(day) ? .bold : .regular))
                                .foregroundStyle(calendar.isDateInToday(day) ? theme.cyan : theme.text)
                            Circle().fill(hasFlight ? theme.accent : Color.clear).frame(width: 4, height: 4)
                        }.frame(maxWidth: .infinity).frame(height: 40)
                            .background(hasFlight ? theme.accent.opacity(0.16) : selected ? theme.cyan.opacity(0.08) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(calendar.isDateInToday(day) || selected ? theme.cyan : Color.clear, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private func changeMonth(_ value: Int) { month = calendar.date(byAdding: .month, value: value, to: month)!; chosenDay = nil }
    private func bookingTimes(_ item: ScheduledFlight) -> String {
        let begin = FlightDates.string(item.date, format: "h:mm a")
        guard let end = item.endDate else { return item.estimatedTime > 0 ? "\(begin) · \(hours(item.estimatedTime)) hr" : "\(begin) · End time not set" }
        let format = calendar.isDate(item.date, inSameDayAs: end) ? "h:mm a" : "MMM d, h:mm a"
        return begin + " – " + FlightDates.string(end, format: format)
    }
    private func monthButton(_ value: Int, _ icon: String) -> some View {
        Button { changeMonth(value) } label: {
            Image(systemName: icon).font(.system(size: 17)).frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.line))
        }.buttonStyle(.plain)
    }
    private func newSchedule() {
        var item = ScheduledFlight()
        item.date = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: chosenDay ?? month) ?? Date()
        editing = item
    }
}

enum ScheduleReviewMode { case all, flagged, withoutReview }
struct ScheduleReviewPlan {
    var automatic: [ScheduledFlight] = []
    var review: [ScanFlightDraft] = []
    var duplicates = 0
    var notAdded: [ImportFailure] = []
}
@MainActor enum ScheduleImportReview {
    static func validationIssues(_ item: ScheduledFlight) -> [ScanFieldIssue] {
        var issues: [ScanFieldIssue] = []
        if !item.date.timeIntervalSinceReferenceDate.isFinite {
            issues.append(ScanFieldIssue(field: "date", message: "Choose a valid start date and time."))
        }
        if !item.isGround, AircraftLookup.clean(item.registration).isEmpty {
            issues.append(ScanFieldIssue(field: "registration", message: "Enter this flight's aircraft registration."))
        }
        if let end = item.endDate {
            if !end.timeIntervalSinceReferenceDate.isFinite || end <= item.date || !(end.timeIntervalSince(item.date) / 3600).isFinite {
                issues.append(ScanFieldIssue(field: "end", message: "Set the end date and time after the start."))
            }
        } else if !item.estimatedTime.isFinite || item.estimatedTime < 0 {
            issues.append(ScanFieldIssue(field: "total", message: "Enter a valid, nonnegative duration."))
        }
        return issues
    }
    static func normalized(_ item: ScheduledFlight) -> ScheduledFlight {
        var result = item
        if let end = result.endDate { result.estimatedTime = end.timeIntervalSince(result.date) / 3600 }
        result.activityType = result.isGround ? "ground" : "flight"
        result.registration = result.isGround ? "" : AircraftLookup.clean(result.registration)
        result.route = result.isGround ? "" : AirportRoute.formatted(result.route)
        if result.isGround { result.resource = "GROUND" }
        if result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.title = result.isGround ? "Ground lesson" : "Flight" }
        return result
    }
    static func plan(_ drafts: [ScanFlightDraft], existing: [ScheduledFlight], mode: ScheduleReviewMode,
                     context: (ScanFlightDraft) -> ScanReviewContext) -> ScheduleReviewPlan {
        var result = ScheduleReviewPlan()
        var ids = Set(existing.map(\.id))
        var sources = Set(existing.compactMap { $0.sourceScheduleID?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        for (index, draft) in drafts.enumerated() {
            guard let item = draft.schedule else {
                if mode == .withoutReview {
                    result.notAdded.append(ImportFailure(id: draft.id, title: "Scheduled flight \(index + 1)",
                        subtitle: "Missing booking details", issues: [ScanFieldIssue(field: "date", message: "The booking could not be read. Enter its date and registration.")]))
                } else { result.review.append(draft) }
                continue
            }
            let source = item.sourceScheduleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard ids.insert(item.id).inserted, source.isEmpty || sources.insert(source).inserted else { result.duplicates += 1; continue }
            let evidence = context(draft)
            var issues = validationIssues(item)
            if draft.unresolvedFields.contains("date") {
                issues.append(ScanFieldIssue(field: "date", message: "Choose the missing or unreadable booking date."))
            }
            let requiresDetails = !issues.isEmpty
            let flagged = !evidence.fieldIssues.isEmpty || !evidence.otherNotes.isEmpty
            let needsReview: Bool
            switch mode {
            case .all: needsReview = true
            case .flagged: needsReview = requiresDetails || flagged
            case .withoutReview:
                if requiresDetails {
                    result.notAdded.append(.schedule(item, number: index + 1, issues: issues))
                    continue
                }
                needsReview = false
            }
            if needsReview { result.review.append(draft) }
            else {
                var savedItem = normalized(item)
                savedItem.importReviewStatus = mode == .withoutReview ? "Saved without review" : "No flagged fields; saved automatically"
                savedItem.importUnreviewedFields = evidence.fieldIssues.map(\.field)
                savedItem.importWarnings = evidence.warnings
                result.automatic.append(savedItem)
            }
        }
        return result
    }
}

struct ScheduleEditor: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    @State private var item: ScheduledFlight
    @State private var time: String
    @State private var end: Date
    @State private var hasEnd: Bool
    @State private var ground: Bool
    @State private var validation = ""
    @State private var deleting = false
    @State private var logging = false
    @State private var resolvedMissingFields: Set<String> = []
    @State private var reviewTouched: Set<String> = []
    @State private var reviewConfirmed: Set<String> = []
    @State private var reviewConfirmedValues: [String: String] = [:]
    @State private var reviewTarget: ScanScrollTarget?
    let importReview: ScanReviewContext?
    let onImportSaved: (() -> Void)?
    let onImportSkipped: (() -> Void)?
    @MainActor init(item: ScheduledFlight, importReview: ScanReviewContext? = nil,
         onImportSaved: (() -> Void)? = nil, onImportSkipped: (() -> Void)? = nil) {
        _item = State(initialValue: item)
        _time = State(initialValue: item.estimatedTime == 0 ? "" : editableHours(item.estimatedTime))
        _end = State(initialValue: item.endDate ?? item.date.addingTimeInterval(max(1, item.estimatedTime) * 3600))
        _hasEnd = State(initialValue: item.endDate != nil)
        _ground = State(initialValue: item.isGround)
        self.importReview = importReview
        self.onImportSaved = onImportSaved
        self.onImportSkipped = onImportSkipped
    }
    private func optional(_ path: WritableKeyPath<ScheduledFlight, String?>) -> Binding<String> {
        Binding(get: { item[keyPath: path] ?? "" }, set: { item[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
    private var reviewValues: [String: String] {
        ["date": FlightDates.string(item.date), "start": FlightDates.string(item.date, format: "yyyy-MM-dd HH:mm"), "end": hasEnd ? (end > item.date ? FlightDates.string(end, format: "yyyy-MM-dd HH:mm") : "") : "not included",
         "registration": ground ? "GROUND" : item.registration, "route": item.route.isEmpty ? "optional" : item.route,
         "title": item.title, "notes": item.notes ?? "", "total": hasEnd ? String(max(0, end.timeIntervalSince(item.date) / 3600)) : time]
    }
    private var pendingReview: [ScanFieldIssue] {
        var supported: Set<String> = ["date", "start", "end", "registration", "route", "title", "notes", "total"]
        if ground { supported.subtract(["registration", "route"]) }
        return ScanReviewLogic.pending((importReview?.fieldIssues ?? []).filter { supported.contains($0.field) }, values: reviewValues,
            touched: reviewTouched, confirmed: ScanReviewLogic.activeConfirmations(reviewConfirmed, snapshots: reviewConfirmedValues, values: reviewValues), expectedLandings: nil, requiredTotal: false)
    }
    private func nextReview() {
        guard let next = pendingReview.first else { return }
        reviewTarget = ScanScrollTarget(field: next.field)
    }
    private func confirmReview(_ field: String) {
        guard ScanReviewLogic.valid(field, values: reviewValues, requiredTotal: false) else { return }
        reviewConfirmed.insert(field); reviewConfirmedValues[field] = ScanReviewLogic.confirmationValue(field, values: reviewValues)
        resolvedMissingFields.insert(field); nextReview()
    }
    private var reviewPresentation: ScanReviewPresentation {
        let all = Set((importReview?.fieldIssues ?? []).map(\.field))
        return ScanReviewPresentation(messages: Dictionary(uniqueKeysWithValues: pendingReview.map { ($0.field, $0.message) }),
            canConfirm: Set(pendingReview.filter { ScanReviewLogic.valid($0.field, values: reviewValues, requiredTotal: false) }.map(\.field)),
            confirm: confirmReview, edited: { field in reviewTouched.insert(field) },
            resolved: all.subtracting(pendingReview.map(\.field)), next: nextReview)
    }
    var body: some View {
        SheetFrame(title: importReview?.title ?? (ground ? "Schedule a ground lesson" : "Schedule a flight"), scrollTarget: reviewTarget) {
            VStack(alignment: .leading, spacing: 18) {
                if let importReview { ScanEntryEvidence(context: importReview, pendingIssues: pendingReview, reviewNext: nextReview) }
                Picker("Booking type", selection: $ground) {
                    Text("Flight").tag(false)
                    Text("Ground lesson").tag(true)
                }.pickerStyle(.segmented)
                DatePicker("Starts", selection: $item.date).datePickerStyle(.compact)
                    .onChange(of: item.date) { old, new in
                        let calendar = Calendar.current
                        if !calendar.isDate(old, inSameDayAs: new) { resolvedMissingFields.insert("date"); reviewTouched.insert("date") }
                        if calendar.component(.hour, from: old) != calendar.component(.hour, from: new) || calendar.component(.minute, from: old) != calendar.component(.minute, from: new) { resolvedMissingFields.insert("start"); reviewTouched.insert("start") }
                    }
                    .scanField("start").scanField("date")
                Toggle("Include end date and time", isOn: $hasEnd)
                    .onChange(of: hasEnd) { _, _ in
                        if !hasEnd { reviewConfirmed.insert("end"); reviewConfirmedValues["end"] = "not included" }
                        else { reviewTouched.insert("end") }
                    }
                    .scanField(hasEnd ? nil : "end")
                if hasEnd {
                    DatePicker("Ends", selection: $end).datePickerStyle(.compact)
                        .onChange(of: end) { _, _ in reviewTouched.insert("end") }.scanField("end")
                    if end > item.date { Text("Duration: \(hours(end.timeIntervalSince(item.date) / 3600)) hours").font(.caption).foregroundStyle(theme.muted).scanField("total") }
                } else {
                    LogField(title: "Estimated duration (hours)", value: $time, hint: "2.0", keyboard: .decimalPad)
                }
                LogField(title: "Booking title", value: $item.title, hint: ground ? "Ground lesson" : "Napa breakfast flight")
                if !ground {
                    LogField(title: "Aircraft registration (optional)", value: $item.registration, hint: "N5130E").textInputAutocapitalization(.characters)
                    LogField(title: "Route", value: $item.route, hint: "KRHV KAPC KRHV").textInputAutocapitalization(.characters)
                }
                LogField(title: "Pilot / student", value: optional(\.pilotName), hint: "Pilot name")
                LogField(title: "CFI", value: optional(\.instructorName), hint: "Instructor name")
                LogField(title: "Resource shown on schedule", value: optional(\.resource), hint: ground ? "GROUND" : "5130E")
                LogField(title: "Comments", value: optional(\.notes), hint: "Booking notes")
                if let reference = item.sourceScheduleID, !reference.isEmpty {
                    Text("Schedule reference: " + reference).font(.caption).foregroundStyle(theme.muted)
                }
                if !validation.isEmpty { Text(validation).font(.subheadline).foregroundStyle(theme.accent) }
                AccentButton(title: importReview == nil ? "Save to Calendar" : "Save booking", action: save)
                if importReview != nil {
                    Button("Skip this entry") { onImportSkipped?() }.frame(maxWidth: .infinity).foregroundStyle(theme.muted)
                } else if store.schedules.contains(where: { $0.id == item.id }) {
                    if !ground { Button("Log this flight") { logging = true } }
                    Button("Delete scheduled booking", role: .destructive) { deleting = true }
                }
            }.environment(\.scanReviewPresentation, reviewPresentation)
        }
        .sheet(isPresented: $logging, onDismiss: {
            if !store.schedules.contains(where: { $0.id == item.id }) { dismiss() }
        }) { FlightEditor(scheduled: item) }
        .alert("Delete scheduled booking?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { store.deleteSchedule(item); dismiss() }
        }
    }
    private func save() {
        if let review = importReview, review.unresolvedFields.contains("date"), !resolvedMissingFields.contains("date") {
            validation = "Set the missing date before saving this booking."; return
        }
        if !pendingReview.isEmpty {
            validation = "Check the remaining review items before saving."; nextReview(); return
        }
        var savedItem = item
        if hasEnd {
            guard end > item.date else { validation = "End date and time must be after the start."; return }
            savedItem.endDate = end
            savedItem.estimatedTime = end.timeIntervalSince(item.date) / 3600
        } else {
            let raw = time.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            guard let duration = Double(raw.isEmpty ? "0" : raw), duration.isFinite, duration >= 0 else {
                validation = "Enter a valid, nonnegative duration."; return
            }
            savedItem.endDate = nil; savedItem.estimatedTime = duration
        }
        savedItem.activityType = ground ? "ground" : "flight"
        savedItem.registration = ground ? "" : AircraftLookup.clean(item.registration)
        savedItem.route = ground ? "" : AirportRoute.formatted(item.route)
        if ground { savedItem.resource = "GROUND" }
        if savedItem.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            savedItem.title = ground ? "Ground lesson" : "Flight"
        }
        if let importReview {
            savedItem.importReviewStatus = "Reviewed before saving"
            savedItem.importUnreviewedFields = []
            savedItem.importWarnings = importReview.warnings
        }
        guard store.saveSchedule(savedItem) else { validation = store.errorMessage ?? "The booking could not be saved."; return }
        Task { await ReminderManager.rebuild(store.schedules) }
        if let onImportSaved { onImportSaved() } else { dismiss() }
    }
}

@MainActor enum ReminderManager {
    private static var worker: Task<Void, Never>?
    static var leads: [Double] {
        let d = UserDefaults.standard
        let raw = d.string(forKey: "flightReminderSelections")
        var values = (raw ?? "").split(separator: ",").compactMap { Double($0) }
        if raw == nil, d.bool(forKey: "flightReminderEnabled") { values.append(Double(max(1, d.integer(forKey: "flightReminderHours")))) }
        if d.bool(forKey: "flightReminderCustomEnabled"), let custom = Double(d.string(forKey: "flightReminderCustomHours") ?? ""), custom > 0, custom <= 720 { values.append(custom) }
        return Array(Set(values)).filter { $0 > 0 && $0 <= 720 }.sorted()
    }
    static func rebuild(_ schedules: [ScheduledFlight]) async {
        let previous = worker
        let task = Task { @MainActor in
            if let previous { await previous.value }
            await performRebuild(schedules)
        }
        worker = task
        await task.value
    }
    private static func performRebuild(_ schedules: [ScheduledFlight]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("logbook-") }.map(\.identifier))
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let notifications = schedules.flatMap { item in leads.map { lead in (item: item, lead: lead, date: item.date.addingTimeInterval(-lead * 3600)) } }
            .filter { $0.date > Date() }.sorted { $0.date < $1.date }
        for event in notifications.prefix(60) {
            let item = event.item
            let content = UNMutableNotificationContent()
            content.title = item.title.isEmpty ? "Upcoming flight" : item.title
            content.body = "\(item.registration) · \(item.route) · \(FlightDates.string(item.date, format: "MMM d, h:mm a"))"
            content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: event.date)
            let request = UNNotificationRequest(identifier: "logbook-" + item.id.uuidString + "-\(event.lead)", content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try? await center.add(request)
        }
    }
}

struct FlightNotificationSettings: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @AppStorage("flightReminderSelections") private var selections = ""
    @AppStorage("flightReminderCustomEnabled") private var custom = false
    @AppStorage("flightReminderCustomHours") private var customHours = ""
    @State private var status = "Saved"
    private var signature: String { "\(selections)|\(custom)|\(customHours)" }
    private var selected: Set<String> { Set(selections.split(separator: ",").map(String.init)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack { Text("Flight notifications").font(.system(size: 21, weight: .heavy, design: .rounded)); Spacer(); Text(status == "Saved" ? "Saved" : "Review").font(.caption).foregroundStyle(theme.cyan) }
            Text("Choose when you want reminders before a scheduled flight.").font(.subheadline).foregroundStyle(theme.muted)
            ForEach([24, 12, 6, 1], id: \.self) { lead in
                Button {
                    var values = selected
                    if values.contains(String(lead)) { values.remove(String(lead)) } else { values.insert(String(lead)) }
                    selections = values.sorted().joined(separator: ",")
                } label: { HStack(spacing: 13) { checkbox(selected.contains(String(lead))); Text("\(lead) \(lead == 1 ? "hour" : "hours") before"); Spacer() } }
                    .buttonStyle(.plain).accessibilityLabel("\(lead) hours before").accessibilityValue(selected.contains(String(lead)) ? "On" : "Off")
            }
            HStack(spacing: 13) {
                Button { custom.toggle() } label: { HStack(spacing: 13) { checkbox(custom); Text("Custom") } }.buttonStyle(.plain)
                Spacer()
                TextField("Hours", text: $customHours).keyboardType(.decimalPad).disabled(!custom)
                    .font(.subheadline).padding(12).frame(width: 88).background(theme.raised.opacity(custom ? 1 : 0.4)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if custom, Double(customHours) == nil || (Double(customHours) ?? 0) <= 0 || (Double(customHours) ?? 0) > 720 {
                Text("Enter custom hours above 0 and up to 720.").font(.caption).foregroundStyle(theme.muted)
            }
            if status != "Saved" { Text(status).font(.caption).foregroundStyle(theme.muted) }
        }.logbookCard(20, tone: .blue)
            .onAppear {
                let defaults = UserDefaults.standard
                if defaults.object(forKey: "flightReminderSelections") == nil {
                    if defaults.bool(forKey: "flightReminderEnabled") {
                        let oldHours = max(1, defaults.integer(forKey: "flightReminderHours"))
                        if [24, 12, 6, 1].contains(oldHours) { selections = String(oldHours) }
                        else { selections = ""; custom = true; customHours = String(oldHours) }
                    } else { selections = "" }
                }
            }
            .task(id: signature) {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                let center = UNUserNotificationCenter.current()
                if !ReminderManager.leads.isEmpty {
                    let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                    status = granted ? "Saved" : "Allow \(AppBrand.name) notifications in Settings to receive reminders."
                } else { status = "Saved" }
                await ReminderManager.rebuild(store.schedules)
            }
    }
    private func checkbox(_ checked: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8).fill(LinearGradient(colors: checked ? [Color(hex: 0x63EDFF), Color(hex: 0x16C9E5), Color(hex: 0x078AA9)] : [theme.background, theme.background], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 27, height: 27)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(checked ? Color(hex: 0x5CECFF) : theme.muted, lineWidth: 1.5))
            .shadow(color: checked ? theme.cyan.opacity(0.3) : .clear, radius: 7, y: 3)
    }
}

// MARK: - Flight story sharing

enum FlightStoryStyle: String, CaseIterable, Identifiable {
    case midnight, light, photo
    var id: String { rawValue }
    var title: String { switch self { case .midnight: return "Midnight"; case .light: return "Light"; case .photo: return "Photo" } }
}

private extension UIColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

@MainActor final class FlightStoryBuilder: ObservableObject {
    @Published private(set) var stories: [FlightStoryStyle: UIImage] = [:]
    @Published private(set) var working = false
    @Published private(set) var message: String?
    @Published private(set) var hasPhoto = false
    private var background: UIImage?
    private var darkMap: UIImage?
    private var lightMap: UIImage?
    private var snapshotter: MKMapSnapshotter?
    private var timeout: Task<Void, Never>?
    private var requestID = UUID()
    private var flight: Flight?
    private var distance = 0.0

    func setPhoto(_ photo: UIImage?) {
        background = photo; hasPhoto = photo != nil
        compose()
    }
    func prepare(_ flight: Flight, catalog: AirportCatalog) async {
        cancel()
        let request = requestID
        self.flight = flight; working = true; message = nil
        stories = [:]; darkMap = nil; lightMap = nil
        let codes = flight.airports
        guard !codes.isEmpty else { fail("This flight needs an airport in its route before a map can be shared.", request: request); return }
        await catalog.load(codes)
        guard request == requestID, !Task.isCancelled else { return }
        let missing = Array(Set(codes.filter { code in
            guard let info = catalog.airports[code] else { return true }
            return !CLLocationCoordinate2DIsValid(info.coordinate)
        })).sorted()
        guard missing.isEmpty else {
            fail("Airport coordinates could not be loaded for \(missing.joined(separator: ", ")). Check the route and try again.", request: request)
            return
        }
        let route = codes.compactMap { catalog.airports[$0] }
        distance = zip(route, route.dropFirst()).reduce(0) { $0 + RouteGeometry.distance($1.0, $1.1) }
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(35)) } catch { return }
            guard let self, request == self.requestID, self.working else { return }
            self.fail("The map request timed out. Check your connection and try again.", request: request)
        }
        capture(route, light: false, request: request)
    }
    func cancel() {
        requestID = UUID(); timeout?.cancel(); timeout = nil
        snapshotter?.cancel(); snapshotter = nil; working = false
    }
    private func fail(_ text: String, request: UUID) {
        guard request == requestID else { return }
        requestID = UUID(); timeout?.cancel(); timeout = nil
        snapshotter?.cancel(); snapshotter = nil; message = text; working = false
    }
    private func capture(_ route: [AirportInfo], light: Bool, request: UUID) {
        let options = MKMapSnapshotter.Options()
        options.size = CGSize(width: 848, height: 806)
        options.scale = 1
        options.mapRect = FlightStoryArt.mapRect(route)
        options.mapType = .mutedStandard
        options.traitCollection = UITraitCollection(userInterfaceStyle: light ? .light : .dark)
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false
        let renderer = MKMapSnapshotter(options: options)
        snapshotter = renderer
        renderer.start(with: DispatchQueue.main) { [weak self] snapshot, error in
            // MapKit explicitly delivers this callback on the main queue.
            MainActor.assumeIsolated {
                guard let self, self.requestID == request else { return }
                guard let snapshot else {
                    self.fail(error?.localizedDescription ?? "The map could not be rendered. Please try again.", request: request)
                    return
                }
                let map = FlightStoryArt.routeMap(snapshot, route: route, light: light)
                if light {
                    self.lightMap = map; self.snapshotter = nil
                    self.timeout?.cancel(); self.timeout = nil
                    self.compose(); self.working = false
                } else {
                    self.darkMap = map
                    self.capture(route, light: true, request: request)
                }
            }
        }
    }
    private func compose() {
        guard let flight, let darkMap, let lightMap else { return }
        var results: [FlightStoryStyle: UIImage] = [
            .midnight: FlightStoryArt.render(flight, map: darkMap, distance: distance, style: .midnight, photo: nil),
            .light: FlightStoryArt.render(flight, map: lightMap, distance: distance, style: .light, photo: nil)
        ]
        if let background { results[.photo] = FlightStoryArt.render(flight, map: darkMap, distance: distance, style: .photo, photo: background) }
        stories = results
    }
}

@MainActor enum FlightStoryArt {
    static let canvas = CGSize(width: 1080, height: 1920)
    private static func format() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        return format
    }
    static func mapRect(_ route: [AirportInfo]) -> MKMapRect {
        AirportMapGeometry.mapRect(route.map(\.coordinate), aspectRatio: 848.0 / 806.0) ?? .world
    }
    static func routeMap(_ snapshot: MKMapSnapshotter.Snapshot, route: [AirportInfo], light: Bool) -> UIImage {
        let size = snapshot.image.size
        return UIGraphicsImageRenderer(size: size, format: format()).image { context in
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            let accent = UIColor(hex: light ? "DA9200" : "FFC548")
            let text = UIColor(hex: light ? "142A36" : "F5F7F8")
            let points = route.map { snapshot.point(for: $0.coordinate) }
            let path = UIBezierPath()
            for (index, point) in points.enumerated() {
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            cg.saveGState(); cg.setShadow(offset: .zero, blur: 9, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            UIColor(hex: light ? "FFF8DC" : "10212A").setStroke(); path.lineWidth = 13; path.stroke()
            accent.setStroke(); path.lineWidth = 7; path.stroke(); cg.restoreGState()
            var seen: Set<String> = []
            let unique = route.filter { seen.insert($0.code).inserted }
            // Limit labels on complex routes while keeping every route leg and airport marker.
            let labeled = Set(unique.count <= 6 ? unique.map(\.code) : Array(unique.prefix(3).map(\.code)) + Array(unique.suffix(3).map(\.code)))
            for airport in unique {
                let point = snapshot.point(for: airport.coordinate)
                let dot = UIBezierPath(ovalIn: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20))
                cg.saveGState(); cg.setShadow(offset: .zero, blur: 7, color: UIColor.black.withAlphaComponent(0.35).cgColor)
                (airport.code == route.first?.code ? UIColor(hex: "19D7EE") : accent).setFill(); dot.fill()
                UIColor.white.setStroke(); dot.lineWidth = 3; dot.stroke(); cg.restoreGState()
                guard labeled.contains(airport.code) else { continue }
                let font = UIFont.systemFont(ofSize: 23, weight: .heavy)
                let measured = (airport.code as NSString).size(withAttributes: [.font: font])
                var x = point.x + 18
                if x + measured.width + 20 > size.width - 18 { x = point.x - measured.width - 32 }
                x = max(18, min(size.width - measured.width - 22, x))
                // Leave the original MapKit logo and legal attribution visible at the bottom.
                let y = max(18, min(size.height - 75, point.y - 17))
                let label = CGRect(x: x, y: y, width: measured.width + 16, height: 36)
                UIColor(hex: light ? "FFFFFF" : "14232D").withAlphaComponent(0.90).setFill()
                UIBezierPath(roundedRect: label, cornerRadius: 8).fill()
                draw(airport.code, in: label.insetBy(dx: 8, dy: 3), size: 23, color: text, weight: .heavy)
            }
        }
    }
    static func render(_ flight: Flight, map: UIImage, distance: Double, style: FlightStoryStyle, photo: UIImage?) -> UIImage {
        UIGraphicsImageRenderer(size: canvas, format: format()).image { context in
            let cg = context.cgContext
            let light = style == .light
            let text = UIColor(hex: light ? "102431" : "F5F7F8")
            let muted = UIColor(hex: light ? "687986" : "96AAB4")
            let accent = UIColor(hex: light ? "CA8300" : "FFC548")
            gradient(cg, rect: CGRect(origin: .zero, size: canvas), colors: light ? ["EDF2F4", "FFFFFF", "DDE9ED"] : ["080B0E", "172933", "091217"])
            if style == .photo, let photo {
                aspectFill(blur(photo), in: CGRect(origin: .zero, size: canvas))
                gradient(cg, rect: CGRect(origin: .zero, size: canvas), colors: ["080B0E", "0A151C"], alphas: [0.57, 0.88])
            }
            cg.saveGState()
            cg.addPath(LogMateLogo().path(in: CGRect(x: 90, y: 170, width: 43, height: 43)).cgPath)
            cg.setStrokeColor(accent.cgColor); cg.setLineWidth(2.6)
            cg.setLineCap(.round); cg.setLineJoin(.round); cg.strokePath(); cg.restoreGState()
            draw(AppBrand.name, in: CGRect(x: 144, y: 176, width: 720, height: 40), size: 30, color: text, weight: .heavy)
            draw("FLIGHT RECAP", in: CGRect(x: 92, y: 233, width: 896, height: 30), size: 19, color: muted, weight: .semibold)

            let card = CGRect(x: 84, y: 314, width: 912, height: 1294)
            let shape = UIBezierPath(roundedRect: card, cornerRadius: 46)
            cg.saveGState(); cg.setShadow(offset: CGSize(width: 0, height: 25), blur: 45, color: UIColor.black.withAlphaComponent(light ? 0.13 : 0.45).cgColor)
            UIColor(hex: light ? "FFFFFF" : "121D25").setFill(); shape.fill(); cg.restoreGState()
            cg.saveGState(); shape.addClip()
            gradient(cg, rect: card, colors: light ? ["FFFFFF", "F6F9FA"] : ["1C2C36", "101A21"])
            cg.restoreGState()
            UIColor(hex: light ? "DAE4E9" : "344550").withAlphaComponent(0.8).setStroke(); shape.lineWidth = 2; shape.stroke()
            let mapFrame = CGRect(x: 116, y: 346, width: 848, height: 806)
            cg.saveGState(); UIBezierPath(roundedRect: mapFrame, cornerRadius: 26).addClip()
            // Draw the complete map, including its attribution. Never aspect-fill or crop it.
            UIColor(hex: light ? "E3ECEF" : "182A34").setFill(); UIRectFill(mapFrame)
            // This inset keeps all four image corners inside the rounded frame.
            map.draw(in: mapFrame.insetBy(dx: 8, dy: 8)); cg.restoreGState()
            let codes = flight.airports
            let route = codes.count <= 4 ? codes.joined(separator: " → ") : "\(codes.first ?? "") → \(codes.last ?? "")"
            draw(route, in: CGRect(x: 128, y: 1193, width: 824, height: 122), size: 57, minimumSize: 38, color: text, weight: .heavy, lines: 2)
            if codes.count > 4 {
                draw("via " + codes.dropFirst().dropLast().joined(separator: " · "), in: CGRect(x: 128, y: 1303, width: 824, height: 29), size: 21, minimumSize: 14, color: muted)
            }
            draw("\(flight.aircraftModel) · \(flight.registration)", in: CGRect(x: 128, y: 1347, width: 824, height: 45), size: 30, minimumSize: 18, color: muted, weight: .medium)
            let date = flight.flightDate.map { FlightDates.string($0, format: "MMM d, yyyy") } ?? flight.date
            draw(date, in: CGRect(x: 128, y: 1398, width: 824, height: 33), size: 24, color: muted)
            cg.setStrokeColor(UIColor(hex: light ? "DCE5E9" : "354550").cgColor); cg.setLineWidth(2)
            cg.move(to: CGPoint(x: 128, y: 1450)); cg.addLine(to: CGPoint(x: 952, y: 1450)); cg.strokePath()
            draw(hours(max(0, flight.total)), in: CGRect(x: 128, y: 1471, width: 376, height: 85), size: 64, minimumSize: 40, color: accent, weight: .heavy)
            draw(String(format: "%.0f", distance), in: CGRect(x: 560, y: 1471, width: 392, height: 85), size: 64, minimumSize: 40, color: text, weight: .heavy)
            draw("TOTAL HOURS", in: CGRect(x: 128, y: 1561, width: 376, height: 27), size: 18, color: muted, weight: .semibold)
            draw("ROUTE NM", in: CGRect(x: 560, y: 1561, width: 392, height: 27), size: 18, color: muted, weight: .semibold)
            draw("Straight-line legs between logged airports.", in: CGRect(x: 92, y: 1680, width: 896, height: 32), size: 21, color: muted)
        }
    }
    private static func draw(_ text: String, in rect: CGRect, size: CGFloat, minimumSize: CGFloat? = nil, color: UIColor, weight: UIFont.Weight = .regular, lines: Int = 1) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        paragraph.lineSpacing = 5
        var fontSize = size
        var attributes: [NSAttributedString.Key: Any] = [:]
        repeat {
            let base = UIFont.systemFont(ofSize: fontSize, weight: weight)
            let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: fontSize) } ?? base
            attributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            let bounds = (text as NSString).boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
            if bounds.height <= rect.height, (lines > 1 || (text as NSString).size(withAttributes: attributes).width <= rect.width) { break }
            fontSize -= 1
        } while fontSize >= (minimumSize ?? size)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
    }
    private static func gradient(_ cg: CGContext, rect: CGRect, colors: [String], alphas: [CGFloat]? = nil) {
        let values = colors.enumerated().map { index, value in UIColor(hex: value).withAlphaComponent(alphas?[index] ?? 1).cgColor }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: values as CFArray, locations: nil) else { return }
        cg.saveGState(); cg.clip(to: rect)
        cg.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()
    }
    private static func aspectFill(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        let target = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        let cg = UIGraphicsGetCurrentContext(); cg?.saveGState(); cg?.clip(to: rect)
        image.draw(in: target); cg?.restoreGState()
    }
    private static func blur(_ image: UIImage) -> UIImage {
        guard let input = CIImage(image: image) else { return image }
        let output = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12]).cropped(to: input.extent)
        guard let cg = CIContext().createCGImage(output, from: input.extent) else { return image }
        return UIImage(cgImage: cg)
    }
}

struct FlightStoryView: View {
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var catalog: AirportCatalog
    @EnvironmentObject var photos: AircraftPhotos
    let flight: Flight
    @StateObject private var builder = FlightStoryBuilder()
    @State private var style = FlightStoryStyle.midnight
    @State private var chosenPhoto: UUID?
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var copied = false
    @State private var share: ShareImage?
    @State private var savingPhoto = false
    @State private var problem: String?
    private var ownedPhotos: [AircraftGalleryItem] { (photos.galleries[flight.registration] ?? []).filter(\.userAdded) }
    private var styles: [FlightStoryStyle] { builder.hasPhoto ? FlightStoryStyle.allCases : [.midnight, .light] }
    var body: some View {
        let photoPickerBackground = theme.raised
        let photoPickerTitle = importing ? "Saving…" : "Add photo"
        return SheetFrame(title: "Share flight") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Make a story from your flight.").font(.subheadline).foregroundStyle(theme.muted)
                preview
                HStack(spacing: 24) {
                    ForEach(styles) { option in
                        Button { withAnimation(.easeInOut(duration: 0.3)) { style = option }; copied = false } label: {
                            VStack(spacing: 7) {
                                Circle().fill(option == .light ? Color(hex: 0xEEF3F5) : option == .photo ? theme.cyan : Color(hex: 0x152B37))
                                    .frame(width: 42, height: 42)
                                    .overlay(Circle().stroke(style == option ? theme.accent : theme.line, lineWidth: style == option ? 3 : 1))
                                Text(option.title).font(.caption).foregroundStyle(style == option ? theme.accent : theme.muted)
                            }
                        }.buttonStyle(.plain).accessibilityLabel(option.title + " story style")
                    }
                    Spacer()
                    PhotosPicker(selection: $photo, matching: .images) {
                        VStack(spacing: 7) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 20)).frame(width: 42, height: 42).background(photoPickerBackground).clipShape(Circle())
                            Text(photoPickerTitle).font(.caption)
                        }
                    }.disabled(importing)
                }
                if ownedPhotos.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(ownedPhotos) { item in
                                if let image = photos.image(item) {
                                    Button {
                                        chosenPhoto = item.id; builder.setPhoto(image); style = .photo; copied = false
                                    } label: {
                                        Image(uiImage: image).resizable().scaledToFill().frame(width: 62, height: 62).clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(chosenPhoto == item.id ? theme.accent : theme.line, lineWidth: chosenPhoto == item.id ? 3 : 1))
                                    }.buttonStyle(.plain).accessibilityLabel("Use aircraft photo as story background")
                                }
                            }
                        }.padding(3)
                    }
                }
                Text("1080 × 1920 · Distance is the sum of straight-line route legs, not a recorded GPS track.").font(.caption).foregroundStyle(theme.muted)
                Button {
                    guard let image = builder.stories[style] else { return }
                    Task { @MainActor in
                        savingPhoto = true; defer { savingPhoto = false }
                        do { try await StoryPhotoSaver.save(image); problem = "Saved to Photos." }
                        catch { problem = error.localizedDescription }
                    }
                } label: { Label(savingPhoto ? "Saving…" : "Save to Photos", systemImage: "square.and.arrow.down").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(14).background(theme.raised).clipShape(Capsule()) }
                    .disabled(savingPhoto || builder.working || builder.stories[style] == nil)
                HStack(spacing: 12) {
                    Button { export() } label: {
                        Label("Share image", systemImage: "square.and.arrow.up").font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity).padding(.vertical, 15).foregroundStyle(Color.black).background(theme.accent).clipShape(Capsule())
                    }.buttonStyle(.plain)
                    Button {
                        if let image = builder.stories[style] { UIPasteboard.general.image = image; copied = true }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 15, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 15)
                            .background(theme.raised).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }.disabled(builder.working || builder.stories[style] == nil)
            }
        }
        .task {
            photos.loadSaved(flight.registration); selectBackground()
            await builder.prepare(flight, catalog: catalog)
        }
        .onDisappear { builder.cancel() }
        .onChange(of: ownedPhotos.map(\.id)) { _, _ in selectBackground() }
        .onChange(of: style) { _, _ in copied = false }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { @MainActor in
                importing = true; defer { importing = false; photo = nil }
                guard let data = try? await item.loadTransferable(type: Data.self), let image = AircraftPhotos.decodedPhoto(data) else {
                    problem = "The selected photo could not be read."; return
                }
                guard photos.add(image, registration: flight.registration) else { problem = photos.errorMessage ?? "The photo could not be saved."; return }
                chosenPhoto = photos.galleries[flight.registration]?.first?.id
                builder.setPhoto(image); style = .photo; copied = false
            }
        }
        .sheet(item: $share) { ShareSheet(items: [$0.image]) }
        .alert("Share flight", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
    }
    @ViewBuilder private var preview: some View {
        if builder.working {
            VStack(spacing: 14) { ProgressView().tint(theme.accent); Text("Preparing your route map…").foregroundStyle(theme.muted) }
                .frame(maxWidth: .infinity).frame(height: 480).background(theme.raised).clipShape(RoundedRectangle(cornerRadius: 24))
        } else if let message = builder.message {
            VStack(spacing: 15) {
                Image(systemName: "map").font(.system(size: 38)).foregroundStyle(theme.accent)
                Text(message).multilineTextAlignment(.center).foregroundStyle(theme.muted)
                Button("Try again") { Task { await builder.prepare(flight, catalog: catalog) } }.foregroundStyle(theme.accent).fontWeight(.bold)
            }.padding(24).frame(maxWidth: .infinity).frame(height: 360).background(theme.raised).clipShape(RoundedRectangle(cornerRadius: 24))
        } else {
            TabView(selection: $style) {
                ForEach(styles) { option in
                    if let image = builder.stories[option] {
                        Image(uiImage: image).resizable().scaledToFit().padding(.bottom, 32).tag(option)
                            .accessibilityLabel("\(option.title) flight story preview")
                    }
                }
            }.tabViewStyle(.page(indexDisplayMode: .always)).frame(height: 480)
        }
    }
    private func selectBackground() {
        let item = ownedPhotos.first { $0.id == chosenPhoto } ?? ownedPhotos.first
        chosenPhoto = item?.id
        builder.setPhoto(item.flatMap { photos.image($0) } ?? PhotoStore.load(flight).first)
        if !builder.hasPhoto, style == .photo { style = .midnight }
    }
    private func export() {
        guard let image = builder.stories[style] else { problem = "The story image could not be created."; return }
        share = ShareImage(image: image)
    }
}

// MARK: - More, OCR review, CSV and PDF exports

struct MoreScreen: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @AppStorage("logbookPilotName") private var pilotName = ""
    @State private var csvImport = false
    @State private var scanning = false
    @State private var importSettings = false
    @State private var share: ShareFile?
    @State private var message: String?
    @State private var completedImport = false
    var onImportFinished: () -> Void = {}
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // The header already says More. Do not repeat the heading here.
                HStack(spacing: 14) {
                    settingsTitle("Appearance", "Choose how \(AppBrand.name) looks")
                    Spacer()
                    Button { theme.toggle() } label: {
                        Text(theme.dark ? "Dark" : "Light").font(.system(size: 18, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color(hex: 0x15202A)).padding(.horizontal, 20).padding(.vertical, 12)
                            .background(theme.accent).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }.logbookCard()
                HStack(spacing: 14) {
                    settingsTitle("Import paper logbook", "Scan pages and review draft flights")
                    Spacer()
                    Button("Scan") { completedImport = false; scanning = true }.padding(12).overlay(Capsule().stroke(theme.line))
                }.logbookCard()
                HStack(spacing: 14) {
                    settingsTitle("Import CSV logbook", "Bring flights from another logbook")
                    Spacer()
                    Button("Import") { completedImport = false; csvImport = true }.padding(12).overlay(Capsule().stroke(theme.line))
                }.logbookCard()
                HStack(spacing: 14) {
                    settingsTitle("AI image imports", "Read schedules and handwritten logbooks")
                    Spacer()
                    Button("Connect") { importSettings = true }.padding(12).overlay(Capsule().stroke(theme.line))
                }.logbookCard()
                VStack(alignment: .leading, spacing: 16) {
                    settingsTitle("Export data", "Download a backup or printable logbook")
                    LogField(title: "Pilot name (optional)", value: $pilotName, hint: "Name on printed logbook")
                    HStack(spacing: 14) {
                        Button("CSV") { export(pdf: false) }.padding(12).overlay(Capsule().stroke(theme.line))
                        Button("PDF") { export(pdf: true) }.padding(12).overlay(Capsule().stroke(theme.line))
                    }
                }.logbookCard()
            }.padding(20).padding(.top, 12)
        }.sheet(isPresented: $scanning, onDismiss: finishDismissedImport) {
                ScanReview(schedule: false, onCompletionChanged: { completedImport = $0 })
            }
            .sheet(isPresented: $csvImport, onDismiss: finishDismissedImport) {
                CSVImportView(onCompletionChanged: { completedImport = $0 })
            }
            .sheet(isPresented: $importSettings) { AIImportSettings() }
            .sheet(item: $share) { ShareSheet(items: [$0.url]) }
            .alert("Export", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
    }
    private func settingsTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 19, weight: .heavy, design: .rounded))
            Text(subtitle).font(.subheadline).foregroundStyle(theme.muted)
        }
    }
    private func finishDismissedImport() {
        if completedImport { completedImport = false; onImportFinished() }
    }
    private func export(pdf: Bool) {
        do { share = ShareFile(url: try LogbookExport.make(store.sorted, pdf: pdf, pilotName: pilotName)) }
        catch { message = error.localizedDescription }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // Saving to Photos requires a purpose string in the app target. Other share destinations remain available.
        let canSavePhotos = ["NSPhotoLibraryAddUsageDescription", "NSPhotoLibraryUsageDescription"].contains { key in
            guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return false }
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !canSavePhotos { controller.excludedActivityTypes = [.saveToCameraRoll] }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Whole-image AI imports
// Only this private import-service access code is stored on the device. The OpenAI key stays on the server.
