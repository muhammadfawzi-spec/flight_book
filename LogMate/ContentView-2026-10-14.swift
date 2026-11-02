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

struct ShareFile: Identifiable { let url: URL; var id: String { url.absoluteString } }

// CSV parsing is independent of layout: quoted commas, multiline cells, CRLF,
// tabs, semicolons and HH:MM durations are handled before field mapping.
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

struct CSVImportView: View {
    @EnvironmentObject var store: FlightStore
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    var onCompletionChanged: ((Bool) -> Void)? = nil
    @State private var choosing = false
    @State private var table: CSVTable?
    @State private var mapping: [String: Int] = [:]
    @State private var dayFirst = false
    @State private var drafts: [CSVFlightDraft] = []
    @State private var reviewing = false
    @State private var index = 0
    @State private var saved = 0
    @State private var skipped = 0
    @State private var duplicateCount = 0
    @State private var automaticSaved = 0
    @State private var completed = false
    @State private var reviewMode: CSVReviewMode = .all
    @State private var notAdded: [ImportFailure] = []
    @State private var confirmWithoutReview = false
    @State private var problem = ""
    @State private var preparingImport = false
    @State private var aircraftLookupCompleted = 0
    @State private var aircraftLookupTotal = 0
    @State private var importTask: Task<Void, Never>?
    private func column(_ field: CSVField) -> Binding<Int> {
        Binding(get: { mapping[field.id] ?? -1 }, set: { if $0 < 0 { mapping.removeValue(forKey: field.id) } else { mapping[field.id] = $0 } })
    }
    var body: some View {
        Group {
            if completed {
                ImportReviewCompletion(title: "All reviews complete",
                    saved: saved, skipped: skipped, duplicates: duplicateCount, automaticallySaved: automaticSaved,
                    savedWithoutReview: reviewMode == .withoutReview, destination: "logbook", notAdded: notAdded, onClose: { dismiss() })
            } else if reviewing, drafts.indices.contains(index) {
                let item = drafts[index]
                FlightEditor(flight: item.flight,
                    importReview: item.reviewContext(title: "CSV flight \(index + 1) of \(drafts.count)"),
                    importAircraft: item.resolvedAircraft,
                    onImportSaved: { saved += 1; advance() },
                    onImportSkipped: { skipped += 1; advance() }).id(item.id)
            } else { preparation }
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            do {
                let url = try result.get(); let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard data.count <= 10_000_000 else { throw CSVImportError.invalid("Choose a CSV smaller than 10 MB.") }
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) ?? String(data: data, encoding: .windowsCP1252) else {
                    throw CSVImportError.invalid("This file's text encoding could not be read.")
                }
                let parsed = try CSVTable.parse(text); table = parsed; mapping = parsed.automaticMapping
                completed = false; reviewing = false; saved = 0; skipped = 0; duplicateCount = 0; automaticSaved = 0
                notAdded = []
                onCompletionChanged?(false); problem = ""
            } catch { problem = error.localizedDescription }
        }
        .alert("Save without reviewing?", isPresented: $confirmWithoutReview) {
            Button("Go back", role: .cancel) {}
            Button("Continue") { beginImport(.withoutReview) }
        } message: {
            Text("We recommend reviewing at least the flagged flights before saving. Continue to save without checking them? Flights missing a valid date or registration will be listed on the completion screen and won't be added.")
        }
        .onDisappear { cancelImportPreparation() }
    }
    private var preparation: some View {
        SheetFrame(title: "Import CSV logbook") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose a logbook export, check the column mapping, then choose how to review your flights.")
                    .font(.subheadline).foregroundStyle(theme.muted)
                AccentButton(title: "Choose CSV file") { choosing = true }.disabled(preparingImport)
                if let table {
                    Text("\(table.rows.count) rows found").font(.headline)
                    Toggle("Dates use day / month / year", isOn: $dayFirst).disabled(preparingImport)
                    DisclosureGroup("Match columns") {
                        ForEach(CSVField.allCases) { field in
                            Picker(field.title, selection: column(field)) {
                                Text("Not included").tag(-1)
                                ForEach(table.headers.indices, id: \.self) { i in Text(table.headers[i]).tag(i) }
                            }.pickerStyle(.menu).font(.subheadline)
                        }
                    }.logbookCard().disabled(preparingImport)
                    Text("Original source values are kept separately from comments. Signatures and confirmation receipts are not transferred.")
                        .font(.caption).foregroundStyle(theme.muted)
                    if preparingImport {
                        ProgressView("Looking up aircraft…").tint(theme.cyan)
                        if aircraftLookupTotal > 0 {
                            Text("\(aircraftLookupCompleted) of \(aircraftLookupTotal) aircraft checked")
                                .font(.caption).foregroundStyle(theme.muted)
                        }
                        Button("Cancel") { cancelImportPreparation() }.foregroundStyle(theme.cyan)
                    } else {
                        AccentButton(title: "Review all flights") { beginImport(.all) }
                        secondaryAction("Review flagged flights only", symbol: "exclamationmark.circle") { beginImport(.flagged) }
                        secondaryAction("Save without reviewing", symbol: "square.and.arrow.down") { confirmWithoutReview = true }
                    }
                }
                if saved + skipped > 0 { Text("\(saved) saved · \(skipped) skipped").foregroundStyle(theme.cyan) }
                if duplicateCount > 0 { Text("\(duplicateCount) already imported \(duplicateCount == 1 ? "flight was" : "flights were") skipped.").font(.caption).foregroundStyle(theme.muted) }
                if !problem.isEmpty { Text(problem).font(.caption).foregroundStyle(theme.accent) }
            }
        }
    }
    private func secondaryAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.cyan).frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(theme.surface).clipShape(Capsule()).overlay(Capsule().stroke(theme.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func beginImport(_ mode: CSVReviewMode) {
        guard let table, !preparingImport else { return }
        let imported = CSVTable.newDrafts(table.drafts(mapping: mapping, dayFirst: dayFirst), existing: store.flights)
        preparingImport = true; aircraftLookupCompleted = 0; aircraftLookupTotal = 0; problem = ""
        importTask = Task { @MainActor in
            let resolved = await CSVImportAircraft.resolve(imported.drafts, saved: store.fleet, progress: { completed, total in
                guard !Task.isCancelled else { return }
                aircraftLookupCompleted = completed; aircraftLookupTotal = total
            })
            guard !Task.isCancelled else { return }
            preparingImport = false; importTask = nil
            savePreparedImport(resolved, mode: mode, duplicates: imported.duplicates)
        }
    }
    private func cancelImportPreparation() {
        importTask?.cancel(); importTask = nil; preparingImport = false
    }
    private func savePreparedImport(_ items: [CSVFlightDraft], mode: CSVReviewMode, duplicates: Int) {
        let checked = items.map { item -> CSVFlightDraft in
            var draft = item
            if store.flights.contains(where: { $0.date == item.flight.date && $0.registration == item.flight.registration && $0.route == item.flight.route && abs($0.total - item.flight.total) < 0.001 }) {
                draft.warnings.append("This may duplicate an existing flight. Use Skip if it is already logged.")
            }
            return draft
        }
        let plan = CSVImportReview.plan(checked, mode: mode)
        let automatic = plan.automatic.map { item -> Flight in
            var flight = item.flight
            flight.facts.text.removeValue(forKey: "importReviewedFields")
            flight.facts.text["importReviewStatus"] = mode == .withoutReview ? "Saved without review" : "No flagged fields; saved automatically"
            flight.facts.text["importUnreviewedFields"] = item.reviewContext(title: "CSV flight").fieldIssues.map(\.field).joined(separator: ", ")
            flight.facts.text["csvImportWarnings"] = item.warnings.joined(separator: "\n")
            return flight
        }
        guard store.saveImportedFlights(automatic, aircraft: plan.automatic.compactMap(\.resolvedAircraft)) else {
            problem = store.errorMessage ?? "The imported flights could not be saved."; return
        }
        drafts = plan.review; reviewMode = mode; duplicateCount = duplicates
        notAdded = plan.notAdded
        index = 0; saved = automatic.count; automaticSaved = automatic.count; skipped = 0; problem = ""
        reviewing = !drafts.isEmpty
        if drafts.isEmpty { finishReview() }
    }
    private func advance() { index += 1; if index >= drafts.count { finishReview() } }
    private func finishReview() { completed = true; reviewing = false; onCompletionChanged?(true) }
}

struct ImportReviewCompletion: View {
    @EnvironmentObject var theme: AppTheme
    var title = "All reviews complete"
    let saved: Int
    let skipped: Int
    var duplicates = 0
    var automaticallySaved = 0
    var savedWithoutReview = false
    var destination = "logbook"
    var notAdded: [ImportFailure] = []
    var nextPageTitle: String? = nil
    var onNextPage: (() -> Void)? = nil
    let onClose: () -> Void
    var body: some View {
        SheetFrame(title: "Import complete", onClose: onClose) {
            VStack(spacing: 26) {
                ZStack {
                    Circle().fill(theme.accent.opacity(0.06)).frame(width: 156, height: 156)
                    Circle().stroke(theme.accent.opacity(0.16), lineWidth: 1).frame(width: 134, height: 134)
                    Circle().fill(LinearGradient(colors: [theme.accent.opacity(0.22), theme.cyan.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 106, height: 106)
                    Image(systemName: "checkmark").font(.system(size: 43, weight: .semibold)).foregroundStyle(theme.accent)
                }.accessibilityHidden(true).padding(.top, 24)
                VStack(spacing: 12) {
                    Text(title).font(.system(size: 29, weight: .heavy, design: .rounded)).multilineTextAlignment(.center)
                    Text(completionMessage)
                        .font(.subheadline).foregroundStyle(theme.muted).multilineTextAlignment(.center)
                }
                HStack(alignment: .top, spacing: 12) {
                    statistic("Saved", count: saved, color: theme.accent)
                    statistic("Skipped", count: skipped, color: theme.muted)
                    if duplicates > 0 { statistic("Already imported", count: duplicates, color: theme.muted) }
                }.logbookCard()
                if automaticallySaved > 0 {
                    Text(automaticSaveSummary)
                        .font(.caption).foregroundStyle(theme.muted).multilineTextAlignment(.center)
                }
                if !notAdded.isEmpty { ImportFailureList(items: notAdded) }
                if let nextPageTitle, let onNextPage { AccentButton(title: nextPageTitle, action: onNextPage) }
                AccentButton(title: "Return to \(destination)", action: onClose)
            }.frame(maxWidth: .infinity).padding(.bottom, 24)
        }
    }
    private var completionMessage: String {
        let noun = destination == "calendar" ? "bookings" : "flights"
        if saved == 0 { return "No new \(noun) were added." }
        if !notAdded.isEmpty { return "Your import is complete. Check the flights below that couldn't be added." }
        return "Your \(destination == "calendar" ? "calendar" : "logbook") is up to date."
    }
    private var automaticSaveSummary: String {
        let noun = destination == "calendar" ? "booking" : "flight"
        let count = automaticallySaved == 1 ? noun + " was" : noun + "s were"
        if savedWithoutReview { return "\(automaticallySaved) \(count) saved without review." }
        return "\(automaticallySaved) unflagged \(count) saved automatically."
    }
    private func statistic(_ label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 6) {
            Text("\(count)").font(.system(size: 27, weight: .bold, design: .rounded)).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(theme.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
}

struct ImportFailureList: View {
    @EnvironmentObject var theme: AppTheme
    let items: [ImportFailure]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Following flights could not be added", systemImage: "exclamationmark.circle")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(ScanReviewColors.warning(theme.dark))
            Text("Tap a flight to see the missing or invalid fields.")
                .font(.caption).foregroundStyle(theme.muted)
            ForEach(items) { item in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(item.issues) { issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ScanReviewFields.title(issue.field)).font(.subheadline.bold())
                                Text(issue.message).font(.caption).foregroundStyle(theme.muted)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(theme.text)
                        Text(item.subtitle).font(.caption).foregroundStyle(theme.muted)
                    }
                }.tint(theme.cyan).logbookCard(16)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

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
@MainActor enum AIImportConfiguration {
    static let urlKey = "logmateAIImportServiceURL"
    private static var keychainService: String { (Bundle.main.bundleIdentifier ?? "LogMate") + ".photo-import" }
    static var endpoint: String { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    static var accessCode: String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: "access-code",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static var ready: Bool { (try? validate(endpoint: endpoint, accessCode: accessCode)) != nil }
    static func validate(endpoint: String, accessCode: String) throws -> URL {
        guard let components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              !host.lowercased().hasSuffix("openai.com"), let url = components.url else {
            throw AIImportFailure.message("Enter your HTTPS import-service address, for example https://your-service.workers.dev. This is the LogMate service, not the OpenAI API address.")
        }
        guard accessCode.range(of: "^lm_[A-Za-z0-9_-]{40,100}$", options: .regularExpression) != nil else {
            throw AIImportFailure.message("Enter the personal import access code supplied by your service. Do not enter an OpenAI API key here.")
        }
        return url
    }
    static func save(endpoint: String, accessCode: String) throws {
        _ = try validate(endpoint: endpoint, accessCode: accessCode)
        let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: "access-code"]
        let values: [String: Any] = [kSecValueData as String: Data(accessCode.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
        let final = status == errSecItemNotFound ? SecItemAdd(identity.merging(values) { _, new in new } as CFDictionary, nil) : status
        guard final == errSecSuccess else { throw AIImportFailure.message("The access code could not be saved securely on this device.") }
        UserDefaults.standard.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey)
    }
    static func disconnect() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: "access-code"] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: urlKey)
    }
}

enum AIImportFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Reject redirects rather than forwarding a private access code to a different service.
private final class AIImportSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

struct AIPhotoInput: Encodable, Sendable {
    var label: String
    var imageBase64: String
    var mimeType: String
}
struct AITextHint: Encodable, Sendable {
    var text: String
    var confidence: Double
    // Normalized coordinates on the prepared FULL page, origin at the top left.
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}
struct AIPhotoPrepared: Sendable {
    var preview: Data
    var inputs: [AIPhotoInput]
    var textHints: [AITextHint]
    var qualityWarnings: [String] = []
}
struct AIPhotoRequest: Encodable {
    var kind: String
    var defaultYear: Int
    var timezone: String
    var images: [AIPhotoInput]
    var ocrHints: [AITextHint] = []
}

// All pixel processing and local OCR run off the UI thread. No extra model call is made.
nonisolated enum PhotoDocumentPreparation {
    static func regions(width: Double, height: Double) -> [CGRect] {
        if width >= height {
            return [CGRect(x: 0, y: 0, width: 0.58, height: 1), CGRect(x: 0.42, y: 0, width: 0.58, height: 1)]
        }
        return [CGRect(x: 0, y: 0, width: 1, height: 0.58), CGRect(x: 0, y: 0.42, width: 1, height: 0.58)]
    }
    static func qualityWarnings(_ cg: CGImage, words: [VNRecognizedTextObservation]) -> [String] {
        var warnings: [String] = []
        if max(cg.width, cg.height) < 1200 || min(cg.width, cg.height) < 450 {
            warnings.append("Low-resolution photo. Move closer or use Scan document; keep every column in view.")
        }
        let side = 160
        var pixels = [UInt8](repeating: 0, count: side * side)
        let measured = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        if measured {
            let brightness = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
            if brightness < 55 { warnings.append("The page is dark. Use even lighting and avoid shadows over the writing.") }
            var sum = 0.0, square = 0.0, count = 0.0
            for y in 1..<(side - 1) {
                for x in 1..<(side - 1) {
                    let i = y * side + x
                    let laplacian = Double(pixels[i - 1]) + Double(pixels[i + 1]) + Double(pixels[i - side]) + Double(pixels[i + side]) - 4 * Double(pixels[i])
                    sum += laplacian; square += laplacian * laplacian; count += 1
                }
            }
            if square / count - pow(sum / count, 2) < 40 {
                warnings.append("Soft focus or little visible detail. Check that handwriting and landing columns are sharp before reading.")
            }
        }
        if words.count < 3 { warnings.append("Very little text was detected. Check focus, glare and whether the whole page is visible.") }
        return warnings
    }
    static func targetedRegions(_ words: [VNRecognizedTextObservation]) -> [(label: String, region: CGRect)] {
        var result: [(label: String, region: CGRect)] = []
        for (pattern, label) in [(#"\b(?:landings?|ldgs?)\b"#, "Landing-column detail; read its headings and every row."),
                                 (#"\b(?:remarks?|comments?|notes?)\b"#, "Remarks-column detail; keep notes attached to their row.")] {
            let boxes = words.filter { observation in
                let text = observation.topCandidates(1).first?.string ?? ""
                return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil && observation.boundingBox.midY > 0.45
            }.map(\.boundingBox)
            guard let first = boxes.first else { continue }
            let left = max(0, (boxes.map(\.minX).min() ?? first.minX) - 0.055)
            let right = min(1, (boxes.map(\.maxX).max() ?? first.maxX) + 0.075)
            let width = min(1 - left, max(label.hasPrefix("Remarks") ? 0.30 : 0.22, right - left))
            result.append((label, CGRect(x: left, y: 0, width: width, height: 1)))
        }
        return result
    }
    private static func recognized(_ cg: CGImage) throws -> [VNRecognizedTextObservation] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.003
        try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([request])
        return request.results ?? []
    }
    private static func image(_ input: CIImage, context: CIContext) throws -> CGImage {
        guard let cg = context.createCGImage(input, from: input.extent.integral) else { throw AIImportFailure.message("The photo could not be prepared.") }
        return cg
    }
    private static func jpeg(_ cg: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw AIImportFailure.message("The photo could not be prepared.") }
        CGImageDestinationAddImage(writer, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw AIImportFailure.message("The photo could not be prepared.") }
        return data as Data
    }
    private static func bounded(_ image: CIImage, longest: CGFloat) -> CIImage {
        let factor = min(1, longest / max(image.extent.width, image.extent.height))
        return image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
    }
    static func prepare(_ data: Data, schedule: Bool) throws -> AIPhotoPrepared {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw AIImportFailure.message("The selected image could not be opened.") }
        // ImageIO downsamples before decoding very large camera images and respects EXIF rotation.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw AIImportFailure.message("The selected image could not be opened.") }
        let context = CIContext(options: [.cacheIntermediates: false])
        var page = CIImage(cgImage: decoded)
        let initialText = (try? recognized(decoded)) ?? []
        if !schedule {
            let request = VNDetectRectanglesRequest()
            request.minimumAspectRatio = 0.15; request.maximumAspectRatio = 1
            request.minimumSize = 0.2; request.minimumConfidence = 0.75
            request.maximumObservations = 12; request.quadratureTolerance = 35
            try? VNImageRequestHandler(cgImage: decoded, orientation: .up).perform([request])
            // Open logbooks can occupy less than half of a camera photo's height.
            // Reject narrow single-page/table detections and crops that exclude recognized text.
            let useful = initialText.filter { ($0.topCandidates(1).first?.confidence ?? 0) >= 0.35 }
            let anchors = useful.filter { observation in
                let text = observation.topCandidates(1).first?.string ?? ""
                return text.range(of: #"\b\d{1,2}[/.-]\d{1,2}(?:[/.-]\d{2,4})?\b|\bN\d{1,5}[A-Z]{0,2}\b|\b(?:date|total|landings|remarks|dual|pilot)\b"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
            }
            let candidates = (request.results ?? []).filter { candidate in
                let rect = candidate.boundingBox
                guard rect.width >= 0.65, rect.height >= 0.22, rect.width * rect.height >= 0.20 else { return false }
                let expanded = rect.insetBy(dx: -0.025, dy: -0.025)
                guard anchors.allSatisfy({ expanded.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }) else { return false }
                return useful.isEmpty || Double(useful.filter { expanded.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }.count) / Double(useful.count) >= 0.95
            }
            if let rectangle = candidates.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                let center = CGPoint(x: rectangle.boundingBox.midX, y: rectangle.boundingBox.midY)
                func corner(_ p: CGPoint) -> CIVector {
                    // A small margin protects handwriting touching the page edges.
                    let x = min(1, max(0, center.x + (p.x - center.x) * 1.025))
                    let y = min(1, max(0, center.y + (p.y - center.y) * 1.025))
                    return CIVector(x: x * page.extent.width + page.extent.minX, y: y * page.extent.height + page.extent.minY)
                }
                let corrected = page.applyingFilter("CIPerspectiveCorrection", parameters: ["inputTopLeft": corner(rectangle.topLeft), "inputTopRight": corner(rectangle.topRight), "inputBottomLeft": corner(rectangle.bottomLeft), "inputBottomRight": corner(rectangle.bottomRight)])
                if corrected.extent.width >= 300, corrected.extent.height >= 120 { page = corrected }
            }
        }
        page = bounded(page, longest: 4096)
        var full = try image(page, context: context)
        var words = (try? recognized(full)) ?? []
        func legibility(_ words: [VNRecognizedTextObservation]) -> Double {
            words.reduce(0) { $0 + Double($1.topCandidates(1).first?.confidence ?? 0) * Double(min(50, $1.topCandidates(1).first?.string.count ?? 0)) }
        }
        // Recover sideways/upside-down photos only when OCR provides a clearly stronger orientation.
        if legibility(words) < 160 {
            var best = legibility(words)
            for orientation in [CGImagePropertyOrientation.right, .down, .left] {
                try Task.checkCancellation()
                let candidate = page.oriented(orientation)
                let cg = try image(candidate, context: context)
                let text = (try? recognized(cg)) ?? []
                let score = legibility(text)
                if score > best * 1.35 + 20 { best = score; full = cg; words = text }
            }
            page = CIImage(cgImage: full)
        }
        // Mild adjustments retain faint pen strokes; no aggressive thresholding or invented details.
        let enhanced = page.applyingFilter("CIColorControls", parameters: ["inputContrast": 1.08, "inputBrightness": 0.015, "inputSaturation": 0.95])
            .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.18]).cropped(to: page.extent)
        full = try image(enhanced, context: context)
        let regions = regions(width: Double(full.width), height: Double(full.height))
        let quality = qualityWarnings(full, words: words)
        var images = [full]
        var labels = ["Full prepared page; use this to count and order rows."]
        var hints: [AITextHint] = []
        func appendHints(_ observations: [VNRecognizedTextObservation], region: CGRect) {
            for observation in observations {
                guard let text = observation.topCandidates(1).first, text.confidence >= 0.3, !text.string.isEmpty else { continue }
                let box = observation.boundingBox
                let hint = AITextHint(text: String(text.string.prefix(180)), confidence: Double((text.confidence * 100).rounded()) / 100,
                    x: Double(region.minX + box.minX * region.width), y: Double(region.minY + (1 - box.maxY) * region.height),
                    width: Double(box.width * region.width), height: Double(box.height * region.height))
                if !hints.contains(where: { $0.text == hint.text && abs($0.x - hint.x) < 0.025 && abs($0.y - hint.y) < 0.025 }) { hints.append(hint) }
            }
        }
        appendHints(words, region: CGRect(x: 0, y: 0, width: 1, height: 1))
        let details = regions.enumerated().map { (label: "Overlapping detail \($0.offset + 1) of the SAME page, not another page.", region: $0.element) }
            + (schedule ? [] : targetedRegions(words))
        for detail in details {
            let region = detail.region
            try Task.checkCancellation()
            let rect = CGRect(x: region.minX * CGFloat(full.width), y: region.minY * CGFloat(full.height), width: region.width * CGFloat(full.width), height: region.height * CGFloat(full.height)).integral
            guard let crop = full.cropping(to: rect) else { continue }
            appendHints((try? recognized(crop)) ?? [], region: region)
            // Enlarge a small crop for legibility without exceeding the API's high-detail dimension.
            let factor = min(2, 2048 / CGFloat(max(crop.width, crop.height)))
            images.append(factor > 1 ? try image(CIImage(cgImage: crop).transformed(by: CGAffineTransform(scaleX: factor, y: factor)), context: context) : crop)
            labels.append(detail.label)
        }
        guard images.count >= 3, images.count <= 5 else { throw AIImportFailure.message("The detail crops could not be prepared. Choose another photo.") }
        var encoded: [Data] = []
        for quality in [0.92, 0.86, 0.78] {
            encoded = try images.map { try jpeg($0, quality: quality) }
            if encoded.reduce(0, { $0 + $1.count }) <= 7_500_000 { break }
        }
        guard encoded.reduce(0, { $0 + $1.count }) <= 7_500_000 else { throw AIImportFailure.message("This photo is too large. Choose one page or a smaller section.") }
        var textSize = 0
        hints = hints.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }.filter { hint in
            textSize += hint.text.utf8.count; return textSize <= 6000
        }
        return AIPhotoPrepared(preview: encoded[0], inputs: zip(labels, encoded).map { AIPhotoInput(label: $0, imageBase64: $1.base64EncodedString(), mimeType: "image/jpeg") }, textHints: Array(hints.prefix(80)), qualityWarnings: quality)
    }
}
struct AIImageBounds: Decodable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var rect: CGRect? {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1.001, y + height <= 1.001 else { return nil }
        return CGRect(x: x, y: y, width: min(width, 1 - x), height: min(height, 1 - y))
    }
}
struct AIPhotoEntry: Decodable {
    var rowNumber: Int
    var sourceText: String
    var warnings: [String]
    var inferredFields: [String]
    var uncertainFields: [String]
    var inheritedRegistration: Bool
    var inheritedModel: Bool
    var sourceBounds: AIImageBounds?
    var date: String?
    var endDate: String?
    var startTime: String?
    var endTime: String?
    var registration: String?
    var makeModel: String?
    var notes: String?
    var pilotName: String?
    var instructorName: String?
    var resource: String?
    var sourceId: String?
    var title: String?
    var approaches: String?
    var category: String?
    var activityType: String?
    var route: [String]?
    var totalHours: Double?
    var picHours: Double?
    var nightHours: Double?
    var actualInstrumentHours: Double?
    var simulatedInstrumentHours: Double?
    var dualReceivedHours: Double?
    var instructorHours: Double?
    var crossCountryHours: Double?
    var soloHours: Double?
    var dayHours: Double?
    var dayLandings: Int?
    var nightLandings: Int?
    var unclassifiedLandings: Int?
    var approachCount: Int?
    var holds: Int?
}
struct AIPageTotals: Decodable {
    var totalHours: Double?
    var dualReceivedHours: Double?
    var picHours: Double?
    var dayHours: Double?
    var landings: Int?
}
struct AIPhotoResult: Decodable {
    var schemaVersion: Int
    var kind: String
    var visibleEntryCount: Int?
    var pageWarnings: [String]
    var entries: [AIPhotoEntry]
    var pageTotals: AIPageTotals?
}

@MainActor enum AIPhotoImporter {
    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 210; config.timeoutIntervalForResource = 240
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: AIImportSessionDelegate(), delegateQueue: nil)
    }
    private static func call(_ request: URLRequest) async throws -> Data {
        let session = session(); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AIImportFailure.message("The import service returned an unreadable response.") }
        guard (200...299).contains(http.statusCode) else {
            struct ErrorReply: Decodable { var error: String }
            let message = (try? JSONDecoder().decode(ErrorReply.self, from: data).error)
            throw AIImportFailure.message(message ?? "The AI import service returned an error (\(http.statusCode)). Check its address and access code.")
        }
        guard data.count <= 4 * 1024 * 1024 else { throw AIImportFailure.message("Too much data was returned. Import a smaller section of the page.") }
        return data
    }
    static func connection(endpoint: String, accessCode: String) async throws {
        let base = try AIImportConfiguration.validate(endpoint: endpoint, accessCode: accessCode)
        var request = URLRequest(url: base.appendingPathComponent("v1/connection"))
        request.setValue("Bearer " + accessCode, forHTTPHeaderField: "Authorization")
        struct Connection: Decodable { var schemaVersion: Int; var ready: Bool }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let reply = try decoder.decode(Connection.self, from: await call(request))
        guard reply.schemaVersion == 1, reply.ready else { throw AIImportFailure.message("The service is not ready for image imports.") }
    }
    static func prepareImage(_ data: Data, schedule: Bool = false) async throws -> AIPhotoPrepared {
        let task = Task.detached(priority: .userInitiated) { try PhotoDocumentPreparation.prepare(data, schedule: schedule) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func read(_ inputs: [AIPhotoInput], schedule: Bool, year: Int, ocrHints: [AITextHint] = []) async throws -> AIPhotoResult {
        let code = AIImportConfiguration.accessCode
        let base = try AIImportConfiguration.validate(endpoint: AIImportConfiguration.endpoint, accessCode: code)
        var request = URLRequest(url: base.appendingPathComponent("v1/import")); request.httpMethod = "POST"
        request.setValue("Bearer " + code, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(AIPhotoRequest(kind: schedule ? "schedule" : "logbook", defaultYear: year, timezone: TimeZone.current.identifier, images: inputs, ocrHints: ocrHints))
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(AIPhotoResult.self, from: await call(request))
        guard result.schemaVersion == 1, result.kind == (schedule ? "schedule" : "logbook"), result.entries.count <= 100 else {
            throw AIImportFailure.message("The AI returned an incompatible result. Check the import service version.")
        }
        return result
    }
    // Map extracted values to editable drafts. Nothing is saved here.
    static func drafts(_ result: AIPhotoResult) -> [ScanFlightDraft] {
        result.entries.map { entry in
            var warnings = result.pageWarnings + entry.warnings
            var issues = entry.uncertainFields.compactMap { name -> ScanFieldIssue? in
                guard let field = ScanReviewFields.key(name) else { return nil }
                return ScanFieldIssue(field: field, message: "Check " + ScanReviewFields.title(field).lowercased() + " against the photo.")
            }
            if entry.inheritedRegistration { issues.append(ScanFieldIssue(field: "registration", message: "Check the repeated registration against this row.")) }
            if !entry.inferredFields.isEmpty {
                let names = entry.inferredFields.map { ScanReviewFields.key($0).map(ScanReviewFields.title) ?? $0.replacingOccurrences(of: "_", with: " ") }
                warnings.append("Read using headings, shorthand or repeated values: " + names.joined(separator: ", ") + ".")
            }
            let route = (entry.route ?? []).joined(separator: " → ")
            let registration = entry.registration ?? ""
            var unresolved: Set<String> = []
            if FlightDates.parse(entry.date ?? "") == nil { unresolved.insert("date"); warnings.append("Date was not read. Choose it from the source photo before saving.") }
            if result.kind == "schedule" {
                var item = ScheduledFlight()
                let parsedStart = localDate(entry.date, clock: entry.startTime)
                item.date = parsedStart ?? localDate(entry.date, clock: "00:00") ?? Date()
                if entry.startTime == nil || (entry.date != nil && parsedStart == nil) { unresolved.insert("start"); warnings.append("Start time was not read. Set it before saving; the displayed time is a placeholder.") }
                item.activityType = entry.activityType ?? "flight"
                if item.activityType == "ground" { item.registration = ""; item.resource = "GROUND"; item.route = "" }
                else { item.registration = registration; item.route = route; item.resource = entry.resource }
                item.title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if item.title.isEmpty { item.title = item.isGround ? "Ground lesson" : "Flight" }
                item.estimatedTime = entry.totalHours ?? 0
                if let end = localDate(entry.endDate ?? entry.date, clock: entry.endTime), end > item.date { item.endDate = end }
                else if entry.endTime != nil { warnings.append("End time could not be placed after the start. Check the date and time before including it.") }
                item.pilotName = entry.pilotName; item.instructorName = entry.instructorName
                item.notes = entry.notes; item.sourceScheduleID = entry.sourceId
                return ScanFlightDraft(schedule: item, sourceText: entry.sourceText, sourceBounds: entry.sourceBounds?.rect,
                    warnings: Array(Set(warnings)).sorted(), repeatsRegistration: entry.inheritedRegistration,
                    repeatsModel: entry.inheritedModel, unresolvedFields: unresolved, issues: ScanReviewFields.unique(issues))
            }
            var flight = Flight()
            flight.date = entry.date ?? ""; flight.aircraft = registration + " · " + (entry.makeModel ?? "")
            flight.route = route; flight.duration = entry.totalHours.map(editableHours) ?? "0.0"
            if entry.totalHours == nil { warnings.append("Total time was not read. You can leave it blank.") }
            flight.pic = entry.picHours ?? 0; flight.night = entry.nightHours ?? 0
            flight.imc = entry.actualInstrumentHours ?? 0; flight.simulatedInstrument = entry.simulatedInstrumentHours ?? 0
            flight.dual = entry.dualReceivedHours ?? 0; flight.instructor = entry.instructorHours ?? 0
            flight.crossCountry = entry.crossCountryHours ?? 0; flight.progress["solo"] = entry.soloHours ?? 0
            flight.dayLandings = entry.dayLandings ?? 0; flight.nightLandings = entry.nightLandings ?? 0
            flight.approachCount = entry.approachCount ?? 0; flight.holds = entry.holds ?? 0
            flight.approaches = entry.approaches ?? ""; flight.category = entry.category ?? "Unspecified"
            flight.notes = entry.notes ?? ""
            if let landings = entry.unclassifiedLandings, landings > 0 {
                issues.append(ScanFieldIssue(field: "landings", message: "Assign \(landings) landings to day / night."))
                flight.facts.counts["unclassifiedLandings"] = landings
                flight.facts.counts["importedLandingTotal"] = flight.landings + landings
            }
            if let day = entry.dayHours { flight.facts.amounts["importedDayHours"] = day }
            if let cfi = entry.instructorName, !cfi.isEmpty {
                flight.facts.text["importedInstructorName"] = cfi
            }
            // Preserve source interpretation with the saved flight for later auditing; never fabricate a signature/endorsement.
            flight.facts.text["photoImportSource"] = entry.sourceText
            flight.facts.text["photoImportMethod"] = "AI image interpretation"
            flight.facts.text["photoImportInferences"] = entry.inferredFields.joined(separator: ", ")
            flight.facts.text["photoImportUncertainty"] = entry.uncertainFields.joined(separator: ", ")
            flight.facts.text["photoImportWarnings"] = warnings.joined(separator: "\n")
            return ScanFlightDraft(flight: flight, sourceText: entry.sourceText, sourceBounds: entry.sourceBounds?.rect,
                warnings: Array(Set(warnings)).sorted(), repeatsRegistration: entry.inheritedRegistration,
                repeatsModel: entry.inheritedModel, unresolvedFields: unresolved, issues: ScanReviewFields.unique(issues))
        }
    }
    private static func localDate(_ date: String?, clock: String?) -> Date? {
        guard let date, let clock else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.isLenient = false
        let raw = date + " " + clock
        guard let result = formatter.date(from: raw), formatter.string(from: result) == raw else { return nil }
        return result
    }
}

@MainActor struct AIImportSettings: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    @State private var endpoint = AIImportConfiguration.endpoint
    @State private var accessCode = AIImportConfiguration.accessCode
    @State private var message = ""
    @State private var checking = false
    @State private var connectionTask: Task<Void, Never>?
    var body: some View {
        SheetFrame(title: "AI image imports") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connect LogMate to its image-reading service. It interprets schedules and logbook pages, then returns editable drafts for review.").foregroundStyle(theme.muted)
                LogField(title: "Import service address", value: $endpoint, hint: "https://your-service.workers.dev", keyboard: .URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Personal import access code").font(.subheadline).foregroundStyle(theme.muted)
                    SecureField("lm_…", text: $accessCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(theme.raised).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text("When you choose Read with AI, your photo is sent to LogMate's connected service and OpenAI to create editable drafts. Review them before saving.")
                    .font(.caption).foregroundStyle(theme.muted)
                if !message.isEmpty { Text(message).foregroundStyle(theme.accent) }
                AccentButton(title: checking ? "Checking connection…" : "Check connection and save") {
                    connectionTask?.cancel(); checking = true; message = ""
                    connectionTask = Task { @MainActor in
                        defer { checking = false }
                        do {
                            try await AIPhotoImporter.connection(endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), accessCode: accessCode.trimmingCharacters(in: .whitespacesAndNewlines))
                            try Task.checkCancellation()
                            try AIImportConfiguration.save(endpoint: endpoint, accessCode: accessCode.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        } catch is CancellationError { return }
                        catch { if !Task.isCancelled { message = error.localizedDescription } }
                    }
                }.disabled(checking)
                if AIImportConfiguration.ready {
                    Button("Disconnect", role: .destructive) { AIImportConfiguration.disconnect(); endpoint = ""; accessCode = ""; message = "Disconnected." }
                        .disabled(checking)
                }
            }
        }.onDisappear { connectionTask?.cancel() }
    }
}

// MARK: - Structured photo imports

struct ScanBox: Sendable {
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var confidence: Float
    var alternatives: [String] = []
    nonisolated var midX: Double { x + width / 2 }
    nonisolated var midY: Double { y + height / 2 }
}

struct ScanTable: Identifiable, Sendable {
    var id = UUID().uuidString
    var rows: [[String]]
    var rowBounds: [CGRect?] = []
}

struct ScanPage: Sendable {
    var tables: [ScanTable]
    var words: [ScanBox]
    var imagePNG: Data
    var transcript: String = ""
    var horizontalRules: [Double] = []
    var verticalRules: [Double] = []
}

enum ScanField: String, CaseIterable, Identifiable {
    case ignore, date, start, end, registration, model, route, departure, arrival
    case total, pic, night, imc, simulated, dual, instructor, crossCountry
    case dayLandings, nightLandings, landings, approaches, approachCount, holds, solo
    case notes, pilot, cfi, reference, resource, category
    case aselHours, asesHours, amelHours, amesHours, rotorHours, gliderHours
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ignore: return "Not a flight field"
        case .date: return "Date"
        case .start: return "Start date / time"
        case .end: return "End date / time"
        case .registration: return "Aircraft registration"
        case .model: return "Make / model"
        case .route: return "Route"
        case .departure: return "Departure airport"
        case .arrival: return "Arrival airport"
        case .total: return "Total hours / duration"
        case .pic: return "PIC hours"
        case .night: return "Night hours"
        case .imc: return "Actual instrument / IMC hours"
        case .simulated: return "Simulated instrument hours"
        case .dual: return "Dual received hours"
        case .instructor: return "Instructor hours"
        case .crossCountry: return "Cross-country hours"
        case .dayLandings: return "Day landings"
        case .nightLandings: return "Night landings"
        case .landings: return "Landings (day / night unspecified)"
        case .approaches: return "Approach details"
        case .approachCount: return "Approach count"
        case .holds: return "Hold count"
        case .solo: return "Solo hours"
        case .notes: return "Remarks / comments"
        case .pilot: return "Pilot name"
        case .cfi: return "Instructor name"
        case .reference: return "Schedule / entry number"
        case .resource: return "Resource / aircraft"
        case .category: return "Aircraft category / class"
        case .aselHours: return "Single-engine land hours"
        case .asesHours: return "Single-engine sea hours"
        case .amelHours: return "Multi-engine land hours"
        case .amesHours: return "Multi-engine sea hours"
        case .rotorHours: return "Rotorcraft hours"
        case .gliderHours: return "Glider hours"
        }
    }
}

struct ScanSchema {
    var headers: [String]
    var fields: [ScanField]
    var firstDataRow: Int
}

struct ScanFlightDraft: Identifiable {
    var id = UUID()
    var flight: Flight? = nil
    var schedule: ScheduledFlight? = nil
    var sourceText: String
    var sourceBounds: CGRect?
    var warnings: [String]
    var repeatsRegistration = false
    var repeatsModel = false
    var unresolvedFields: Set<String> = []
    var issues: [ScanFieldIssue] = []
}

struct ScanScrollTarget: Equatable { var field: String; var token = UUID() }
nonisolated struct ScanFieldIssue: Identifiable, Equatable, Sendable {
    var field: String
    var message: String
    var id: String { field }
}
nonisolated enum ScanReviewFields {
    static let order = ["date", "start", "end", "registration", "model", "route", "departure", "arrival", "total", "pic", "sic", "solo", "landings", "day", "nightLandings", "night", "imc", "dual", "instructor", "xc", "sim", "approaches", "approachCount", "holds", "category", "notes", "title"]
    static func key(_ field: String) -> String? {
        let name = field.lowercased().filter { $0.isLetter || $0.isNumber }
        let aliases: [String: String] = ["date":"date", "start":"start", "starttime":"start", "enddate":"end", "endtime":"end",
            "registration":"registration", "aircraft":"registration", "aircraftregistration":"registration", "aircraftregistrationoptional":"registration", "nnumber":"registration", "makemodel":"model", "model":"model", "makeandmodel":"model",
            "route":"route", "departureairport":"departure", "arrivalairport":"arrival", "departure":"departure", "arrival":"arrival", "total":"total", "totalhours":"total", "totaltime":"total", "estimateddurationhours":"total", "pichours":"pic", "pictime":"pic", "pic":"pic", "sic":"sic", "sictime":"sic", "solo":"solo", "solohours":"solo",
            "daylandings":"day", "nightlandings":"nightLandings", "unclassifiedlandings":"landings", "landings":"landings",
            "nighthours":"night", "nighttime":"night", "night":"night", "actualinstrumenthours":"imc", "actualinstrument":"imc", "imctime":"imc", "imc":"imc",
            "simulatedinstrumenthours":"sim", "simulatedinstrument":"sim", "siminstrument":"sim", "dualreceivedhours":"dual", "dualreceived":"dual", "dual":"dual", "instructionreceived":"dual",
            "instructorhours":"instructor", "instructortime":"instructor", "instructor":"instructor", "crosscountryhours":"xc", "crosscountry":"xc", "xc":"xc",
            "approaches":"approaches", "approachcount":"approachCount", "holds":"holds", "category":"category", "categoryclass":"category", "notes":"notes", "remarks":"notes", "comments":"notes", "title":"title", "bookingtitle":"title"]
        return aliases[name]
    }
    static func title(_ key: String) -> String {
        ["date":"Date", "start":"Start time", "end":"End time", "registration":"Aircraft registration", "model":"Make and model", "route":"Route", "departure":"Departure airport", "arrival":"Arrival airport",
         "total":"Total time", "pic":"PIC time", "sic":"SIC time", "solo":"Solo", "day":"Day landings", "nightLandings":"Night landings", "landings":"Landings",
         "night":"Night time", "imc":"Actual instrument", "dual":"Dual received", "instructor":"Instructor time", "xc":"Cross-country", "sim":"Simulated instrument",
         "approaches":"Approaches", "approachCount":"Approach count", "holds":"Holds", "category":"Category / class", "notes":"Comments", "title":"Booking title"][key] ?? key
    }
    static func warningFields(_ warning: String) -> [String] {
        let lower = warning.lowercased()
        // Global capture/footer notes stay collapsed, rather than being repeated at every field.
        if lower.contains("page total") || lower.contains("full-page") || lower.contains("full page") || lower.contains("supplied year") || lower.contains("default_year") || lower.contains("source record") || lower.contains("simulator time is also") || lower.hasPrefix("read using") || lower.hasPrefix("other scanned columns") { return [] }
        if lower.contains("duplicate") || lower.contains("matching flight") || lower.contains("matching booking") { return ["date"] }
        if lower.contains("landing") { return ["landings"] }
        if lower.hasPrefix("check "), let colon = warning.firstIndex(of: ":"),
           let key = key(String(warning[warning.index(warning.startIndex, offsetBy: 6)..<colon])) { return [key] }
        let phrases: [(String, String)] = [("registration","registration"),("aircraft","registration"),("make and model","model"),("make_model","model"),("category","category"),("start time","start"),("end time","end"),("date","date"),("total time","total"),("pic","pic"),("sic","sic"),("cross-country","xc"),("cross country","xc"),("dual","dual"),("simulated","sim"),("instrument","imc"),("night time","night"),("approach count","approachCount"),("approach","approaches"),("hold","holds"),("remarks","notes"),("comments","notes"),("notes","notes"),("route","route")]
        return Array(Set(phrases.filter { lower.contains($0.0) }.map(\.1))).sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
    }
    static func unique(_ issues: [ScanFieldIssue]) -> [ScanFieldIssue] {
        // Day/night flags belong to the one shared landing card and confirmation snapshot.
        var grouped = issues
        if issues.contains(where: { ["day", "nightLandings"].contains($0.field) }) {
            let landingIssue = issues.first { $0.field == "landings" }
                ?? ScanFieldIssue(field: "landings", message: "Check day and night landings against the source.")
            grouped.removeAll { ["day", "nightLandings", "landings"].contains($0.field) }
            grouped.append(landingIssue)
        }
        var seen = Set<String>()
        return grouped.filter { seen.insert($0.field).inserted }.sorted { (order.firstIndex(of: $0.field) ?? 99) < (order.firstIndex(of: $1.field) ?? 99) }
    }
}
nonisolated enum ScanReviewLogic {
    static func valid(_ field: String, values: [String: String], requiredTotal: Bool = false) -> Bool {
        let raw = values[field, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if field == "date" { return FlightDates.parse(raw) != nil }
        if ["start", "end", "category", "model"].contains(field) { return true }
        if field == "registration" { return !AircraftNames.registration(raw).isEmpty }
        if ["departure", "arrival"].contains(field) { return raw.isEmpty || (!CSVRoute.containsCoordinates(raw) && AirportRoute.codes(raw).count == 1) }
        if field == "route" { return raw.isEmpty || raw == "optional" || !AirportRoute.codes(raw).isEmpty }
        if ["day", "nightLandings", "approachCount", "holds"].contains(field) { return count(raw) != nil }
        if field == "landings" { return count(values["day", default: ""]) != nil && count(values["nightLandings", default: ""]) != nil }
        if ["total", "pic", "sic", "night", "imc", "sim", "dual", "instructor", "xc"].contains(field) {
            guard let value = Double(raw.isEmpty && (field != "total" || !requiredTotal) ? "0" : raw.replacingOccurrences(of: ",", with: ".")), value.isFinite, value >= 0 else { return false }
            if field == "total" { return !requiredTotal || value > 0 }
            let total = Double(values["total", default: ""].replacingOccurrences(of: ",", with: ".")) ?? 0
            return total == 0 || value <= total + 0.001
        }
        return true
    }
    static func count(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(text.isEmpty ? "0" : text), (0..<100_000).contains(value) else { return nil }
        return value
    }
    static func confirmationValue(_ field: String, values: [String: String]) -> String {
        if field == "landings" { return values["day", default: ""] + "|" + values["nightLandings", default: ""] }
        return values[field, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func activeConfirmations(_ confirmed: Set<String>, snapshots: [String: String], values: [String: String]) -> Set<String> {
        Set(confirmed.filter { snapshots[$0] == confirmationValue($0, values: values) })
    }
    static func pending(_ issues: [ScanFieldIssue], values: [String: String], touched: Set<String>, confirmed: Set<String>, expectedLandings: Int?, requiredTotal: Bool = false) -> [ScanFieldIssue] {
        issues.filter { issue in
            guard valid(issue.field, values: values, requiredTotal: requiredTotal) else { return true }
            if confirmed.contains(issue.field) { return false }
            // Editing alone does not confirm an uncertain reading. Keep its Confirm action visible.
            return true
        }
    }
}
struct ScanReviewPresentation {
    var messages: [String: String] = [:]
    var canConfirm: Set<String> = []
    var confirm: ((String) -> Void)?
    var edited: ((String) -> Void)?
    var resolved: Set<String> = []
    var next: (() -> Void)?
    func isTracked(_ field: String?) -> Bool {
        guard let field else { return false }
        return messages[field] != nil || resolved.contains(field)
    }
    func needsReview(_ field: String?) -> Bool {
        guard let field else { return false }
        let group = ["day", "nightLandings"].contains(field) ? "landings" : field
        return messages[group] != nil
    }
}
enum ScanReviewColors {
    static func warning(_ dark: Bool) -> Color { Color(hex: dark ? 0xFFC044 : 0xA55F00) }
    static func success(_ dark: Bool) -> Color { Color(hex: dark ? 0x79E987 : 0x237A35) }
}
private struct ScanReviewPresentationKey: EnvironmentKey { static let defaultValue = ScanReviewPresentation() }
extension EnvironmentValues {
    var scanReviewPresentation: ScanReviewPresentation {
        get { self[ScanReviewPresentationKey.self] }
        set { self[ScanReviewPresentationKey.self] = newValue }
    }
}
struct ScanFieldMarker: ViewModifier {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.scanReviewPresentation) var review
    let field: String?
    var label: String? = nil
    func body(content: Content) -> some View {
        if let field, review.isTracked(field) {
            let pending = review.messages[field] != nil
            let stateColor = pending ? ScanReviewColors.warning(theme.dark) : ScanReviewColors.success(theme.dark)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let label { Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true) }
                    Text(pending ? "Review" : "Reviewed").font(.caption.bold()).foregroundStyle(stateColor)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(stateColor.opacity(0.08)).clipShape(Capsule())
                        .overlay(Capsule().stroke(stateColor, lineWidth: 1))
                    Spacer(minLength: 0)
                }
                content
                if let message = review.messages[field] {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            warning(message, color: stateColor).fixedSize(horizontal: true, vertical: true)
                            Spacer(minLength: 0)
                            confirmation
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            warning(message, color: stateColor).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            confirmation.frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                } else {
                    Label("Looks good", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(stateColor)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface).clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.line.opacity(0.75)))
                .id("scan-" + field)
        } else if let field { content.id("scan-" + field) }
        else { content }
    }
    private func warning(_ message: String, color: Color) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(color)
    }
    @ViewBuilder private var confirmation: some View {
        if let field, review.canConfirm.contains(field) {
            Button("Confirm") { review.confirm?(field) }.font(.caption.bold()).foregroundStyle(theme.cyan)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Confirm " + ScanReviewFields.title(field))
        }
    }
}
extension View {
    func scanField(_ field: String?, label: String? = nil) -> some View { modifier(ScanFieldMarker(field: field, label: label)) }
}

struct ScanReviewContext {
    var title: String
    var sourceText: String
    var image: UIImage?
    var warnings: [String]
    var unresolvedFields: Set<String> = []
    var issues: [ScanFieldIssue] = []
    var rowImage: UIImage? = nil
    var fieldIssues: [ScanFieldIssue] {
        let missing = unresolvedFields.map { ScanFieldIssue(field: $0, message: "Choose " + ScanReviewFields.title($0).lowercased() + ".") }
        let fallback = warnings.flatMap { warning in
            ScanReviewFields.warningFields(warning).map { ScanFieldIssue(field: $0, message: "Check " + ScanReviewFields.title($0).lowercased() + " against the source.") }
        }
        return ScanReviewFields.unique(issues + missing + fallback)
    }
    var otherNotes: [String] { Array(Set(warnings.filter { ScanReviewFields.warningFields($0).isEmpty })).sorted() }
}

struct ScanEntryEvidence: View {
    @EnvironmentObject var theme: AppTheme
    @State private var expanded = false
    let context: ScanReviewContext
    var pendingIssues: [ScanFieldIssue] = []
    var reviewNext: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review this entry before saving").font(.headline)
            if let image = context.rowImage ?? context.image {
                Button { expanded = true } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityLabel("Enlarge source schedule or logbook photo")
                Button("Enlarge source photo") { expanded = true }.font(.caption).foregroundStyle(theme.cyan)
            }
            if !pendingIssues.isEmpty {
                Button { reviewNext?() } label: {
                    HStack {
                        Text("\(pendingIssues.count) \(pendingIssues.count == 1 ? "field needs" : "fields need") review").foregroundStyle(theme.text)
                        Spacer(); Text("Next").foregroundStyle(theme.cyan)
                    }.font(.subheadline.bold()).padding(.vertical, 10)
                }.buttonStyle(.plain)
            } else if !context.fieldIssues.isEmpty {
                Label("Review items checked", systemImage: "checkmark.circle").font(.caption).foregroundStyle(theme.cyan)
            }
            if !context.otherNotes.isEmpty {
                DisclosureGroup("Other scan notes") {
                    ForEach(Array(context.otherNotes.enumerated()), id: \.offset) { _, note in
                        Text(note).font(.caption).foregroundStyle(theme.muted).padding(.top, 6)
                    }
                }.font(.subheadline)
            }
            DisclosureGroup("Text from this entry") {
                Text(context.sourceText).font(.caption).textSelection(.enabled).padding(.top, 8)
            }
        }.logbookCard()
            .sheet(isPresented: $expanded) {
                if let image = context.image {
                    SheetFrame(title: "Source photo", subtitle: "Pinch to zoom and drag to check the printed details.") {
                        ScanPhotoZoom(image: image).frame(height: 480).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
    }
}

struct ScanPhotoZoom: UIViewRepresentable {
    let image: UIImage
    final class PhotoScrollView: UIScrollView {
        let photo = UIImageView()
        private var fittedSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0, bounds.height > 0, let image = photo.image, image.size.width > 0, image.size.height > 0 else { return }
            if fittedSize != bounds.size {
                fittedSize = bounds.size
                setZoomScale(1, animated: false)
                photo.frame = CGRect(origin: .zero, size: image.size)
                contentSize = image.size
                let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
                minimumZoomScale = fit; maximumZoomScale = max(fit * 8, 1)
                setZoomScale(fit, animated: false)
            }
            photo.center = CGPoint(x: max(contentSize.width, bounds.width) / 2, y: max(contentSize.height, bounds.height) / 2)
        }
    }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? PhotoScrollView)?.photo }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> PhotoScrollView {
        let view = PhotoScrollView()
        view.photo.image = image; view.photo.contentMode = .scaleAspectFit
        view.addSubview(view.photo); view.delegate = context.coordinator
        view.bouncesZoom = true
        return view
    }
    func updateUIView(_ uiView: PhotoScrollView, context: Context) {}
    static func dismantleUIView(_ uiView: PhotoScrollView, coordinator: Coordinator) { uiView.delegate = nil }
}

// Foundation-only field parsing is separated from Vision and the review UI.
enum ScanParsing {
    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
    nonisolated static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    static func field(_ header: String, schedule: Bool) -> ScanField {
        if let exact = ScanField.allCases.first(where: { $0.title == header }) { return exact }
        let h = normalized(header)
        if h.isEmpty { return .ignore }
        // Short schedule headings can merge letters in a small screenshot.
        if schedule {
            if h == "stot" { return .start }
            if h == "ent" { return .end }
            if h == "plot" { return .pilot }
            if ["cfl", "cf1", "cr"].contains(h) { return .cfi }
        }
        if h.contains("schedule") || h == "entrynumber" || h == "reference" || h == "bookingid" { return .reference }
        if h.contains("resource") { return .resource }
        if h == "cfi" || h.contains("instructorname") || (schedule && h == "instructor") { return .cfi }
        if h == "pilot" || h.contains("pilotname") || h == "student" || h == "studentname" { return .pilot }
        if !schedule {
            if h.contains("singleengineland") || h == "asel" || h == "sel" { return .aselHours }
            if h.contains("singleenginesea") || h == "ases" || h == "ses" { return .asesHours }
            if h.contains("multiengineland") || h == "amel" || h == "mel" { return .amelHours }
            if h.contains("multienginesea") || h == "ames" || h == "mes" { return .amesHours }
            if h == "rotorcraft" || h == "helicopter" || h == "rotorcrafttime" { return .rotorHours }
            if h == "glider" || h == "glidertime" { return .gliderHours }
        }
        if h.contains("registration") || h.contains("tailnumber") || h == "nnumber" || h == "ident" || h == "aircraftident" || h == "aircraftidentification" { return .registration }
        if h.contains("model") || h.contains("aircrafttype") || h.contains("typeofaircraft") || h == "make" || h == "type" || h == "maketype" { return .model }
        if h == "aircraft" || h == "airplane" { return schedule ? .resource : .model }
        if h.contains("category") || h == "class" { return .category }
        if h.contains("start") || h == "begin" || h == "out" || h == "departuretime" { return .start }
        if h == "end" || h.contains("endtime") || h.contains("enddate") || h == "finish" || h == "in" || h == "arrivaltime" { return .end }
        if h.contains("date") || h == "dayofmonth" { return .date }
        if h.contains("route") { return .route }
        if h == "from" || h.hasPrefix("departureairport") || h == "departure" || h == "origin" || h == "placeofdeparture" { return .departure }
        if h == "to" || h.hasPrefix("arrivalairport") || h == "arrival" || h == "destination" || h == "placeofarrival" { return .arrival }
        if h.contains("landing") || h.contains("ldg") || h == "day" {
            if h.contains("night") { return .nightLandings }
            if h.contains("day") { return .dayLandings }
            return .landings
        }
        if h.contains("crosscountry") || h == "xc" || h == "xctotal" || h == "xccountry" { return .crossCountry }
        if h.contains("pic") || h.contains("pilotincommand") { return .pic }
        if h.contains("simulated") || h == "hood" || h == "siminstr" || h == "siminst" || h == "siminstrument" { return .simulated }
        if h.contains("actual") || h.contains("imc") || h == "actinstr" || h == "actinst" { return .imc }
        if h.contains("dual") || h.contains("trainingreceived") || h == "instructionreceived" { return .dual }
        if h.contains("instructor") || h.contains("instructiongiven") || h.contains("dualgiven") { return .instructor }
        if h.contains("solo") { return .solo }
        if h.contains("approach") || h == "appr" || h == "app" || h == "nrinstapp" || h == "nrapp" {
            return h.contains("count") || h.contains("number") || h == "appr" || h == "app" || h.hasPrefix("nrinst") || h.hasPrefix("nrapp") ? .approachCount : .approaches
        }
        if h.contains("hold") { return .holds }
        if h.contains("night") { return .night }
        if h.contains("total") || h.contains("duration") || h == "time" || h == "hours" || h.contains("flighttime") { return .total }
        if h.contains("remark") || h.contains("comment") || h.contains("note") || h == "description" { return .notes }
        return .ignore
    }
    static func schema(_ table: ScanTable, schedule: Bool) -> ScanSchema {
        let width = table.rows.map(\.count).max() ?? 0
        var bestIndex = -1
        var bestScore = 0
        for (index, row) in table.rows.prefix(12).enumerated() {
            let tags = row.map { field($0, schedule: schedule) }
            let score = tags.filter { $0 != .ignore }.count
            if score > bestScore, !row.contains(where: { date($0, year: 2000) != nil }) {
                bestIndex = index; bestScore = score
            }
        }
        guard bestIndex >= 0 else {
            return ScanSchema(headers: (0..<width).map { "Column \($0 + 1)" }, fields: Array(repeating: .ignore, count: width), firstDataRow: 0)
        }
        var lastHeader = bestIndex
        // A second line of subheaders (such as day/night under Landings) belongs to the header.
        while lastHeader + 1 < min(table.rows.count, bestIndex + 3) {
            let row = table.rows[lastHeader + 1]
            let recognized = row.filter { field($0, schedule: schedule) != .ignore }.count
            if recognized >= 2 && !row.contains(where: { date($0, year: 2000) != nil }) { lastHeader += 1 }
            else { break }
        }
        var headers = [String]()
        var fields = [ScanField]()
        for column in 0..<width {
            let parts = (max(0, bestIndex - 2)...lastHeader).compactMap { index -> String? in
                guard column < table.rows[index].count else { return nil }
                let value = table.rows[index][column].trimmingCharacters(in: .whitespacesAndNewlines)
                // Page titles and account information must not become column labels.
                return field(value, schedule: schedule) != .ignore ? value : nil
            }
            let header = parts.joined(separator: " ")
            headers.append(header.isEmpty ? "Column \(column + 1)" : header)
            fields.append(field(header, schedule: schedule))
        }
        return ScanSchema(headers: headers, fields: fields, firstDataRow: lastHeader + 1)
    }
    static func date(_ text: String, year: Int) -> Date? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = matches(#"\b(?:\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[/\-]\d{1,2}(?:[/\-]\d{2,4})?)\b"#, in: raw).first
        if let numeric {
            let pieces = numeric.split(whereSeparator: { $0 == "/" || $0 == "-" }).compactMap { Int($0) }
            guard pieces.count >= 2 else { return nil }
            let iso = numeric.prefix(4).allSatisfy(\.isNumber) && numeric.count > 4 && (numeric[numeric.index(numeric.startIndex, offsetBy: 4)] == "-" || numeric[numeric.index(numeric.startIndex, offsetBy: 4)] == "/")
            let month = iso ? pieces[1] : pieces[0]
            let day = iso ? pieces[2] : pieces[1]
            var resolvedYear = iso ? pieces[0] : pieces.count == 3 ? pieces[2] : year
            if resolvedYear < 100 { resolvedYear += (year / 100) * 100 }
            guard (1900...2199).contains(resolvedYear), (1...12).contains(month), (1...31).contains(day) else { return nil }
            let calendar = Calendar(identifier: .gregorian)
            guard let result = calendar.date(from: DateComponents(year: resolvedYear, month: month, day: day)),
                  calendar.component(.month, from: result) == month, calendar.component(.day, from: result) == day else { return nil }
            return result
        }
        let months = #"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"#
        let patterns = ["\\b" + months + #"\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?\b"#,
                        #"\b\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?"# + months + #"\.?(?:,?\s+\d{4})?\b"#]
        for pattern in patterns {
            guard var match = matches(pattern, in: raw).first else { continue }
            match = match.replacingOccurrences(of: #"(?<=\d)(st|nd|rd|th)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"\s+of\s+"#, with: " ", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "")
            if matches(#"\b\d{4}\b"#, in: match).isEmpty { match += " \(year)" }
            for format in ["MMM d yyyy", "MMMM d yyyy", "d MMM yyyy", "d MMMM yyyy"] {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.isLenient = false; f.dateFormat = format
                if let result = f.date(from: match) { return result }
            }
        }
        return nil
    }
    static func clock(_ text: String) -> (hour: Int, minute: Int, explicitPeriod: Bool)? {
        let cleaned = text.uppercased().replacingOccurrences(of: "A.M.", with: "AM").replacingOccurrences(of: "P.M.", with: "PM")
        let patterns = [#"\b(\d{1,2}):(\d{2})(?::\d{2})?\s*(AM|PM)?\b"#,
                        #"\b(\d{1,2})()\s*(AM|PM)\b"#,
                        #"(?:\bAT\s+|@\s*)(\d{1,2})()\s*(AM|PM)?\b"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
                  let hr = Range(match.range(at: 1), in: cleaned), var hour = Int(cleaned[hr]) else { continue }
            let minute = Range(match.range(at: 2), in: cleaned).flatMap { Int(cleaned[$0]) } ?? 0
            let period = Range(match.range(at: 3), in: cleaned).map { String(cleaned[$0]) }
            guard minute < 60 else { return nil }
            let unambiguous24Hour = hour == 0 || hour > 12
            if let period {
                guard (1...12).contains(hour) else { return nil }
                hour %= 12
                if period == "PM" { hour += 12 }
            } else if hour > 23 { return nil }
            return (hour, minute, period != nil || unambiguous24Hour)
        }
        return nil
    }
    static func dateTime(_ text: String, fallback: Date?, year: Int) -> Date? {
        guard let day = date(text, year: year) ?? fallback, let time = clock(text) else { return nil }
        return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
    }
    static func hoursValue(_ text: String) -> Double? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "hours", with: "").replacingOccurrences(of: "hrs", with: "").replacingOccurrences(of: "hr", with: "").replacingOccurrences(of: " h", with: "").trimmingCharacters(in: .whitespaces)
        if raw.range(of: #"^\d{1,3}:\d{2}$"#, options: .regularExpression) != nil {
            let parts = raw.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts[1] < 60 else { return nil }
            return parts[0] + parts[1] / 60
        }
        // Do not silently turn a handwritten '05' with a missing decimal into five hours.
        if raw.range(of: #"^0\d+$"#, options: .regularExpression) != nil { return nil }
        // Handwritten decimals are sometimes recognized as two separated digits.
        if raw.range(of: #"^\d{1,2}\s+\d$"#, options: .regularExpression) != nil {
            return Double(raw.split(whereSeparator: \.isWhitespace).joined(separator: "."))
        }
        guard raw.range(of: #"^(?:\d{1,3}(?:\.\d{1,2})?|\.\d{1,2})$"#, options: .regularExpression) != nil,
              let value = Double(raw), value.isFinite else { return nil }
        return value
    }
    static func registration(_ text: String, bareAllowed: Bool = true) -> String {
        let raw = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = matches(#"\bN[1-9][0-9]{0,4}[A-HJ-NP-Z]{0,2}\b"#, in: raw).first, match.count <= 6 { return match }
        let firstToken = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? raw
        let compact = firstToken.filter { $0.isLetter || $0.isNumber }
        guard !firstToken.contains(where: { ".:/".contains($0) }) else { return "" }
        if bareAllowed, compact.range(of: #"^[1-9][0-9]{0,4}[A-HJ-NP-Z]{0,2}$"#, options: .regularExpression) != nil,
           compact.count <= 5 { return "N" + compact }
        return ""
    }
    nonisolated static func isBlank(_ text: String) -> Bool {
        ["", "-", "—", "–", ".", "n/a"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    static func isDitto(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["ditto", "same", "do", "do.", "〃", "\"", "''", "“", "”"].contains(raw)
            || (!raw.isEmpty && raw.allSatisfy { "\"'〃“”".contains($0) || $0.isWhitespace })
    }
    static func parsedDrafts(_ tables: [ScanTable], schedule: Bool, year: Int, overrides: [String: [ScanField]]) -> [ScanFlightDraft] {
        var output = [ScanFlightDraft]()
        for table in tables {
            var schema = schema(table, schedule: schedule)
            if let selected = overrides[table.id], selected.count == schema.fields.count { schema.fields = selected }
            var previousDate: Date?
            var previousRegistration = ""
            var previousModel = ""
            for rowIndex in schema.firstDataRow..<table.rows.count {
                let row = table.rows[rowIndex]
                let fullText = row.joined(separator: " | ")
                let clean = normalized(fullText)
                if row.allSatisfy(isBlank) || ["totals", "subtotal", "carriedforward", "broughtforward", "pagetotal", "amountforward"].contains(where: { clean.hasPrefix($0) }) { continue }
                var values = [ScanField: String]()
                var extras = [String]()
                for (column, value) in row.enumerated() where !isBlank(value) {
                    let tag = column < schema.fields.count ? schema.fields[column] : .ignore
                    if tag == .ignore {
                        if !["download", "edit", "delete", "|"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                            extras.append("\(column < schema.headers.count ? schema.headers[column] : "Column \(column + 1)"): \(value)")
                        }
                    } else if values[tag] != value { values[tag] = [values[tag], value].compactMap { $0 }.joined(separator: " ") }
                }
                let dateText = [values[.date], values[.start]].compactMap { $0 }.joined(separator: " ")
                let resource = values[.resource] ?? values[.registration] ?? ""
                var reg = registration(resource)
                let grounded = normalized(resource).contains("ground")
                let classFields: [(ScanField, String)] = [(.aselHours, "ASEL"), (.asesHours, "ASES"), (.amelHours, "AMEL"), (.amesHours, "AMES"), (.rotorHours, "Rotorcraft"), (.gliderHours, "Glider")]
                let classTimes = classFields.compactMap { field, category -> (String, Double)? in
                    guard let raw = values[field], let value = hoursValue(raw) else { return nil }
                    return (category, value)
                }
                var total = hoursValue(values[.total] ?? "")
                if total == nil, !classTimes.isEmpty { total = classTimes.reduce(0) { $0 + $1.1 } }
                let repeatedRegistration = !schedule && isDitto(resource) && !previousRegistration.isEmpty
                if repeatedRegistration { reg = previousRegistration }
                let explicitDate = date(dateText, year: year)
                let aggregate = row.contains { value in
                    let label = normalized(value)
                    return label == "total" || ["totals", "totalthispage", "pagetotal", "subtotal", "carriedforward", "broughtforward", "amountforward", "amtforward", "totalstodate"].contains { label.hasPrefix($0) }
                }
                if aggregate, explicitDate == nil, reg.isEmpty { continue }
                let rowIdentity = [values[.model], values[.route], values[.departure], values[.arrival]].compactMap { $0 }.contains { !isBlank($0) }
                let hasEvidence = explicitDate != nil || !reg.isEmpty || (schedule && grounded) || (!schedule && total != nil && rowIdentity)
                let inheritedEvidence = !schedule && previousDate != nil && (total != nil || !reg.isEmpty)
                guard hasEvidence || inheritedEvidence,
                      schedule ? (explicitDate != nil || !resource.isEmpty) : (total != nil || !reg.isEmpty || !isBlank(values[.route] ?? "")) else { continue }
                var warnings = [String]()
                if repeatedRegistration { warnings.append("Aircraft registration carried from a ditto mark in the preceding row. Verify it.") }
                if !reg.isEmpty { previousRegistration = reg }
                if values[.total] == nil, !classTimes.isEmpty { warnings.append("Total time was calculated from the aircraft category/class time columns. Verify it against the full logbook page.") }
                for (field, raw) in values where raw.range(of: #"^\d{1,2}\s+\d$"#, options: .regularExpression) != nil {
                    if field.title.contains("hours") { warnings.append("\(field.title): read \(raw) as a decimal. Check the handwritten value.") }
                }
                var day = explicitDate
                if day == nil, !schedule, let previousDate,
                   isBlank(dateText) || isDitto(dateText) {
                    day = previousDate; warnings.append("Date carried from the preceding row. Verify it against the photo.")
                }
                if let day { previousDate = day }
                if day == nil { warnings.append("Date was not readable. Set the correct date before confirming.") }
                if explicitDate != nil, !dateText.contains(String(year)), matches(#"\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}|\d{4}[-/]"#, in: dateText).isEmpty {
                    warnings.append("Year \(year) was supplied for this date. Verify the year.")
                }
                let notes = values[.notes] ?? ""
                if !extras.isEmpty { warnings.append("Other scanned columns: " + extras.joined(separator: "; ")) }
                let routeText = values[.route] ?? [values[.departure], values[.arrival]].compactMap { $0 }.joined(separator: " ")
                let bounds = rowIndex < table.rowBounds.count ? table.rowBounds[rowIndex] : nil
                if schedule {
                    var item = ScheduledFlight()
                    let start = dateTime(dateText, fallback: day, year: year)
                    if let start { item.date = start }
                    else {
                        item.date = day ?? Date()
                        warnings.append("Start time was not readable. Enter the correct time.")
                    }
                    if let endText = values[.end], let start {
                        var end = dateTime(endText, fallback: start, year: year)
                        if let candidate = end, candidate <= start, date(endText, year: year) == nil {
                            end = Calendar.current.date(byAdding: .day, value: 1, to: candidate)
                            warnings.append("End time appears to be on the following day. Verify the dates.")
                        }
                        if let end, end > start { item.endDate = end; item.estimatedTime = end.timeIntervalSince(start) / 3600 }
                        else { warnings.append("End time was not readable or precedes the start. Check the end time.") }
                        if let period = clock(endText), !period.explicitPeriod { warnings.append("End time has no AM/PM marker. Verify it.") }
                    } else { warnings.append("End time was not found. You may add an end time or estimated duration; both can be left unspecified.") }
                    if let period = clock(dateText), !period.explicitPeriod { warnings.append("Start time has no AM/PM marker. Verify it.") }
                    if item.endDate == nil, let total { item.estimatedTime = total }
                    item.registration = grounded ? "" : reg
                    item.resource = resource
                    item.activityType = grounded ? "ground" : "flight"
                    item.title = grounded ? "Ground lesson" : "Flight"
                    item.route = AirportRoute.formatted(routeText)
                    item.pilotName = values[.pilot]; item.instructorName = values[.cfi]
                    item.sourceScheduleID = values[.reference]; item.notes = notes.isEmpty ? nil : notes
                    if !grounded && reg.isEmpty { warnings.append("Aircraft registration was not readable. Check the resource / aircraft field.") }
                    output.append(ScanFlightDraft(schedule: item, sourceText: fullText, sourceBounds: bounds, warnings: warnings))
                } else {
                    var flight = Flight()
                    if let day { flight.date = FlightDates.string(day) }
                    let rawModel = values[.model] ?? ""
                    let carriedModel = isDitto(rawModel) && !previousModel.isEmpty
                    let model = AircraftNames.display(carriedModel ? previousModel : rawModel)
                    if carriedModel { warnings.append("Make/model carried from a ditto mark in the preceding row. Verify it.") }
                    if !model.isEmpty { previousModel = model }
                    flight.aircraft = reg + " · " + model
                    flight.route = AirportRoute.formatted(routeText)
                    flight.notes = notes
                    if !extras.isEmpty { flight.facts.text["photoImportOtherColumns"] = extras.joined(separator: "; ") }
                    flight.duration = total.map { String($0) } ?? "0.0"
                    let times: [(ScanField, WritableKeyPath<Flight, Double>)] = [(.pic, \.pic), (.night, \.night), (.imc, \.imc), (.simulated, \.simulatedInstrument), (.dual, \.dual), (.instructor, \.instructor), (.crossCountry, \.crossCountry)]
                    for (field, path) in times {
                        if let raw = values[field], !isBlank(raw) {
                            if let value = hoursValue(raw) { flight[keyPath: path] = value }
                            else { warnings.append("\(field.title) was not readable: \(raw). Enter it manually.") }
                        }
                    }
                    let counts: [(ScanField, WritableKeyPath<Flight, Int>)] = [(.dayLandings, \.dayLandings), (.nightLandings, \.nightLandings), (.approachCount, \.approachCount), (.holds, \.holds)]
                    for (field, path) in counts {
                        if let raw = values[field], !isBlank(raw) {
                            if let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 { flight[keyPath: path] = value }
                            else { warnings.append("\(field.title) was not readable: \(raw). Enter it manually.") }
                        }
                    }
                    if let raw = values[.landings], !isBlank(raw) {
                        if let total = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), total >= flight.landings, total < 100_000 {
                            flight.facts.counts["importedLandingTotal"] = total
                            flight.facts.counts["unclassifiedLandings"] = total - flight.landings
                        } else { flight.facts.text["photoImportLandingReading"] = raw }
                        warnings.append("Landing count has no day/night label. Assign it to the correct landing field.")
                    }
                    if let raw = values[.approaches] {
                        if let count = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), count >= 0 { flight.approachCount = count }
                        else { flight.approaches = raw }
                    }
                    if let raw = values[.solo], let solo = hoursValue(raw) { flight.progress["solo"] = solo }
                    let categoriesWithTime = classTimes.filter { $0.1 > 0 }.map { $0.0 }
                    if categoriesWithTime.count == 1 { flight.category = categoriesWithTime[0] }
                    if let category = values[.category], let matched = AircraftLookup.categories.first(where: { normalized($0) == normalized(category) }) { flight.category = matched }
                    if let instructor = values[.cfi] { flight.facts.text["importedInstructorName"] = instructor }
                    if total == nil { warnings.append("Total hours were not readable. Enter the flight's total time.") }
                    if reg.isEmpty { warnings.append("Registration was not readable. Enter the correct aircraft.") }
                    if flight.route.isEmpty { warnings.append("Route was not readable. You can leave it blank or enter airports.") }
                    if !AircraftNames.hasMake(model) { warnings.append("Full make/model was not found. Aircraft lookup can fill it after the registration is confirmed.") }
                    var draft = ScanFlightDraft(flight: flight, sourceText: fullText, sourceBounds: bounds, warnings: warnings)
                    draft.repeatsRegistration = isDitto(resource); draft.repeatsModel = isDitto(rawModel)
                    if draft.repeatsRegistration && reg.isEmpty { draft.warnings.append("Aircraft ditto mark refers to an unreadable preceding aircraft. Correct that entry first.") }
                    output.append(draft)
                }
            }
        }
        return output
    }
}

// Read lists, notes and labelled booking cards without assuming a table layout.
enum ScanTextEntries {
    static func captured(_ pattern: String, _ text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              group < result.numberOfRanges, let range = Range(result.range(at: group), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func timeStrings(_ text: String) -> [String] {
        let raw = text.replacingOccurrences(of: "a.m.", with: "AM", options: .caseInsensitive)
            .replacingOccurrences(of: "p.m.", with: "PM", options: .caseInsensitive)
        let pattern = #"\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)?\b|\b\d{1,2}\s*(?:AM|PM)\b|(?:\bat\s+|@\s*)\d{1,2}(?![\d/:])\s*(?:AM|PM)?\b"#
        var found = ScanParsing.matches(pattern, in: raw)
        // '2–4pm' carries the period to the first time only when written as a range.
        if found.count < 2, let range = captured(#"\b(\d{1,2}(?::\d{2})?\s*(?:AM|PM)?\s*(?:-|–|—|to)\s*\d{1,2}(?::\d{2})?\s*(?:AM|PM))\b"#, raw) {
            guard let separator = try? NSRegularExpression(pattern: #"\s*(?:-|–|—|to)\s*"#, options: [.caseInsensitive]) else { return found }
            let parts = range.components(separatedBy: separator)
            if parts.count == 2 {
                let period = ScanParsing.matches(#"AM|PM"#, in: parts[1]).last ?? ""
                found = [ScanParsing.matches(#"AM|PM"#, in: parts[0]).isEmpty ? parts[0] + " " + period : parts[0], parts[1]]
            }
        }
        return found
    }
    static func grounded(_ text: String) -> Bool {
        text.range(of: #"\bground(?:\s+(?:lesson|training|school|instruction))?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func blocks(_ text: String, schedule: Bool, year: Int) -> [(text: String, day: Date?)] {
        var output = [(text: String, day: Date?)]()
        var pending = [String]()
        var sharedDay: Date?
        var pendingDay: Date?
        func finish() {
            let raw = pending.joined(separator: "\n")
            let hasAircraft = !ScanParsing.registration(raw, bareAllowed: false).isEmpty
            let hasDate = ScanParsing.date(raw, year: year) != nil
            let hasTime = !timeStrings(raw).isEmpty
            if (schedule && (hasAircraft || grounded(raw) || (hasDate && hasTime))) || (!schedule && (hasAircraft || hasDate)) {
                output.append((raw, pendingDay))
            }
            pending = []; pendingDay = nil
        }
        let source = text.replacingOccurrences(of: ";", with: "\n")
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let compact = ScanParsing.normalized(line)
            if ["totals", "subtotal", "totalthispage", "totalstodate", "amtforward", "amountforward", "carriedforward", "broughtforward"].contains(where: { compact.hasPrefix($0) }) { finish(); continue }
            let date = ScanParsing.date(line, year: year)
            let reg = ScanParsing.registration(line, bareAllowed: false)
            let isGround = grounded(line)
            let hasTime = !timeStrings(line).isEmpty
            let pendingText = pending.joined(separator: " ")
            let priorReg = ScanParsing.registration(pendingText, bareAllowed: false)
            let priorTime = !timeStrings(pendingText).isEmpty
            let priorDate = ScanParsing.date(pendingText, year: year)
            let hasPriorEntry = !priorReg.isEmpty || grounded(pendingText) || (priorDate != nil && priorTime)
            let newDate = date != nil && (priorDate != nil || (hasPriorEntry && priorTime))
            let newAircraft = (!reg.isEmpty || isGround) && hasPriorEntry && (priorTime || !schedule)
            let newTime = schedule && hasTime && priorTime && (!reg.isEmpty || isGround)
            if !pending.isEmpty && (newDate || newAircraft || newTime) { finish() }
            if let date { sharedDay = date }
            if pending.isEmpty { pendingDay = date ?? sharedDay }
            // A standalone date is a heading shared by the bookings that follow.
            if date != nil && reg.isEmpty && !isGround && !hasTime && schedule {
                if pending.isEmpty { pendingDay = date }
                pending.append(line); continue
            }
            if pending.isEmpty && date == nil && reg.isEmpty && !isGround && !hasTime { continue }
            pending.append(line)
        }
        finish()
        return output
    }
    static func labelledValues(_ text: String, schedule: Bool) -> [ScanField: String] {
        var values = [ScanField: String]()
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = String(line[..<colon]); let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let field = ScanParsing.field(label, schedule: schedule)
            if field != .ignore && !value.isEmpty { values[field] = value }
        }
        // Inline time/count labels are accepted as well as one label per line.
        let labels: [(ScanField, String)] = [(.total, "(?:total(?:\\s+time)?|duration)"), (.pic, "PIC"), (.night, "night(?:\\s+time)?"),
            (.imc, "(?:IMC|actual(?:\\s+instrument)?)"), (.simulated, "(?:hood|simulated(?:\\s+instrument)?)"), (.dual, "dual(?:\\s+received)?"),
            (.instructor, "instructor(?:\\s+time)?"), (.crossCountry, "(?:XC|cross[ -]?country)"), (.dayLandings, "day\\s+landings"),
            (.nightLandings, "night\\s+landings"), (.landings, "landings"), (.approachCount, "approach(?:es|\\s+count)"), (.holds, "holds?")]
        for (field, label) in labels where values[field] == nil {
            if let value = captured("\\b" + label + #"\s*[:=]?\s*(\d+(?:[.,:]\d+)?)\b"#, text) { values[field] = value }
        }
        for (field, label) in [(ScanField.pilot, "(?:pilot|student)"), (.cfi, "(?:CFI|instructor)"), (.route, "route"), (.model, "(?:model|make/model|aircraft type)")] where values[field] == nil {
            values[field] = captured("\\b" + label + #"\s*[:=]\s*([^\n;]+)"#, text)
        }
        return values
    }
    static func delimitedTable(_ text: String, schedule: Bool) -> ScanTable? {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { return nil }
        let delimiter: Character = header.contains("\t") ? "\t" : header.contains("|") ? "|" : ","
        func cells(_ line: String) -> [String] {
            var result = [String](); var current = ""; var quoted = false
            for c in line {
                if c == "\"", delimiter == "," { quoted.toggle() }
                else if c == delimiter && !quoted { result.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
                else { current.append(c) }
            }
            result.append(current.trimmingCharacters(in: .whitespaces)); return result
        }
        let headers = cells(header)
        guard headers.count >= 3, headers.filter({ ScanParsing.field($0, schedule: schedule) != .ignore }).count >= 2 else { return nil }
        return ScanTable(rows: lines.map(cells))
    }
    static func drafts(_ text: String, schedule: Bool, year: Int) -> [ScanFlightDraft] {
        if let table = delimitedTable(text, schedule: schedule) {
            return ScanParsing.parsedDrafts([table], schedule: schedule, year: year, overrides: [:])
        }
        var result = [ScanFlightDraft]()
        for block in blocks(text, schedule: schedule, year: year) {
            let raw = block.text
            let labelled = labelledValues(raw, schedule: schedule)
            let explicit = ScanParsing.date(raw, year: year)
            let day = explicit ?? block.day
            let reg = ScanParsing.registration(labelled[.registration] ?? labelled[.resource] ?? raw, bareAllowed: labelled[.registration] != nil || labelled[.resource] != nil)
            var warnings = [String]()
            if explicit == nil { warnings.append(day == nil ? "Date was not readable. Set the correct date." : "Date taken from the preceding heading. Check it.") }
            else if ScanParsing.matches(#"\b\d{4}\b|\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}"#, in: raw).isEmpty { warnings.append("Year \(year) was supplied. Check the year.") }
            if schedule {
                let ground = grounded(raw)
                let clocks = timeStrings(raw)
                var item = ScheduledFlight()
                item.date = ScanParsing.dateTime(labelled[.start] ?? clocks.first ?? "", fallback: day, year: year) ?? day ?? Date()
                if clocks.isEmpty && labelled[.start] == nil { warnings.append("Start time was not readable. Set the correct time.") }
                let startText = labelled[.start] ?? clocks.first ?? ""
                if let clock = ScanParsing.clock(startText), !clock.explicitPeriod { warnings.append("Start time does not specify AM or PM. The displayed time is provisional; choose the correct period.") }
                if let endText = labelled[.end] ?? (clocks.count > 1 ? clocks[1] : nil), var end = ScanParsing.dateTime(endText, fallback: item.date, year: year) {
                    if end <= item.date, ScanParsing.date(endText, year: year) == nil {
                        end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end
                        warnings.append("End time was placed on the next day. Check the dates.")
                    }
                    if end > item.date { item.endDate = end; item.estimatedTime = end.timeIntervalSince(item.date) / 3600 }
                    if ScanParsing.clock(endText)?.explicitPeriod == false { warnings.append("End time has no AM/PM marker. Check it.") }
                } else {
                    item.estimatedTime = ScanParsing.hoursValue(labelled[.total] ?? "") ?? 0
                    warnings.append("End time and duration can be left unspecified or added before saving.")
                }
                item.registration = ground ? "" : reg; item.activityType = ground ? "ground" : "flight"
                item.resource = ground ? "GROUND" : reg
                item.title = ground ? "Ground lesson" : "Flight"
                item.route = AirportRoute.formatted(labelled[.route] ?? "")
                item.pilotName = labelled[.pilot]; item.instructorName = labelled[.cfi]
                item.sourceScheduleID = labelled[.reference]; item.notes = raw
                if !ground && reg.isEmpty { warnings.append("Aircraft registration was not readable. Enter it.") }
                result.append(ScanFlightDraft(schedule: item, sourceText: raw, sourceBounds: nil, warnings: warnings))
            } else {
                var fields = labelled
                fields[.date] = day.map { FlightDates.string($0) } ?? ""
                fields[.registration] = reg
                fields[.notes] = raw
                if fields[.route] == nil {
                    let codes = ScanParsing.matches(#"\b[A-Z][A-Z0-9]{3}\b"#, in: raw).filter { $0.uppercased().hasPrefix("K") }
                    if !codes.isEmpty { fields[.route] = codes.joined(separator: " ") }
                }
                let order = ScanField.allCases.filter { fields[$0] != nil }
                let table = ScanTable(rows: [order.map(\.title), order.map { fields[$0] ?? "" }])
                let extracted = ScanParsing.parsedDrafts([table], schedule: false, year: year, overrides: [:])
                for var draft in extracted { draft.sourceText = raw; draft.warnings += warnings; result.append(draft) }
            }
        }
        return result
    }
}

// A small helper keeps range splitting independent of locale and whitespace.
private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        var output = [String](); var cursor = startIndex
        for match in regex.matches(in: self, range: NSRange(startIndex..., in: self)) {
            guard let range = Range(match.range, in: self) else { continue }
            output.append(String(self[cursor..<range.lowerBound])); cursor = range.upperBound
        }
        output.append(String(self[cursor...])); return output
    }
}

// Reconstruct rows from coordinates if the OS cannot return a structured table.
enum ScanLayout {
    static func lines(_ words: [ScanBox]) -> [[ScanBox]] {
        var rows = [[ScanBox]]()
        for word in words.sorted(by: { $0.midY < $1.midY }) {
            if let index = rows.indices.last, let first = rows[index].first,
               abs(word.midY - first.midY) <= max(0.0025, min(word.height, first.height) * 0.6) { rows[index].append(word) }
            else { rows.append([word]) }
        }
        return rows.map { $0.sorted { $0.x < $1.x } }
    }
    static func fallbackTable(_ words: [ScanBox], schedule: Bool) -> ScanTable? {
        let lineGroups = lines(words)
        var header = [ScanBox]()
        var columns = [ScanField]()
        var best = 0
        for sourceLine in lineGroups {
            let line = sourceLine.filter { $0.text != "|" }
            let score = line.filter { ScanParsing.field($0.text, schedule: schedule) != .ignore }.count
            if score > best, !line.contains(where: { ScanParsing.date($0.text, year: 2000) != nil }) {
                best = score; header = line; columns = line.map { ScanParsing.field($0.text, schedule: schedule) }
            }
        }
        let allDates = words.filter { ScanParsing.date($0.text, year: 2000) != nil }
        guard !allDates.isEmpty else { return nil }
        let leftDateX = allDates.map(\.midX).min() ?? 0
        let dateColumn = header.firstIndex { ScanParsing.field($0.text, schedule: schedule) == .start || ScanParsing.field($0.text, schedule: schedule) == .date }
        var dateCenter = leftDateX
        if let dateColumn { dateCenter = header[dateColumn].midX }
        let dateCandidates = allDates.filter { abs($0.midX - dateCenter) < 0.06 }
        var anchors = [ScanBox]()
        for box in dateCandidates.sorted(by: { $0.y < $1.y }) {
            if let previous = anchors.last, abs(box.midY - previous.midY) < max(box.height, previous.height) * 0.7 { continue }
            anchors.append(box)
        }
        guard !anchors.isEmpty else { return nil }
        if best < 2 && schedule { return nil }
        if best < 2 {
            // Infer column positions from the first entry, but leave unlabelled numbers unassigned.
            let top = anchors[0].y - anchors[0].height * 0.3
            let bottom = anchors.count > 1 ? anchors[1].y - anchors[1].height * 0.3 : top + 0.12
            header = words.filter {
                $0.midY >= top && $0.midY < bottom && $0.text != "|"
                    && ScanParsing.clock($0.text) == nil && !["AM", "PM"].contains($0.text.uppercased())
            }.sorted { $0.x < $1.x }
            var inferred = [ScanBox]()
            for box in header {
                if let last = inferred.last, abs(last.midX - box.midX) < 0.035 { continue }
                inferred.append(box)
            }
            header = inferred
            var inferredDates = 0
            columns = header.map {
                if ScanParsing.date($0.text, year: 2000) != nil {
                    inferredDates += 1
                    return schedule ? (inferredDates == 1 ? .start : .end) : .date
                }
                if ScanParsing.normalized($0.text).contains("ground") { return .resource }
                if !ScanParsing.registration($0.text, bareAllowed: false).isEmpty { return .registration }
                if schedule, $0.text.count >= 3, !$0.text.contains(where: { ".:/".contains($0) }),
                   !ScanParsing.registration($0.text).isEmpty { return .resource }
                return .ignore
            }
        }
        let order = header.indices.sorted { header[$0].midX < header[$1].midX }
        header = order.map { header[$0] }; columns = order.map { columns[$0] }
        guard !header.isEmpty else { return nil }
        let firstY = anchors[0].y
        // Read neighbouring header lines to retain grouped labels such as Night Landings.
        for index in header.indices {
            let neighbours = words.filter { $0.y < firstY && $0.midY < header[index].midY && header[index].midY - $0.midY < 0.04 && $0.x < header[index].midX && $0.x + $0.width > header[index].midX }
            let parent = neighbours.map(\.text).joined(separator: " ")
            let combined = parent + " " + header[index].text
            if combined.lowercased().contains("landing") { columns[index] = ScanParsing.field(combined, schedule: schedule) }
        }
        var rows = [columns.enumerated().map { index, field in field == .ignore ? "Unassigned column \(index + 1)" : field.title }]
        var bounds: [CGRect?] = [nil]
        let medianHeight = anchors.map(\.height).sorted()[anchors.count / 2]
        for (index, anchor) in anchors.enumerated() {
            let top = max(0, anchor.y - medianHeight * 0.4)
            let bottom = index + 1 < anchors.count ? anchors[index + 1].y - medianHeight * 0.4 : min(1, anchor.y + (index > 0 ? max(medianHeight * 2.5, anchor.y - anchors[index - 1].y) : 0.1))
            let rowWords = words.filter { $0.midY >= top && $0.midY < bottom && $0.text != "|" }
            var cells = Array(repeating: [ScanBox](), count: header.count)
            for word in rowWords {
                let closest = header.indices.min { abs(header[$0].midX - word.midX) < abs(header[$1].midX - word.midX) } ?? 0
                cells[closest].append(word)
            }
            rows.append(cells.map { lines($0).map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n") })
            bounds.append(CGRect(x: 0, y: top, width: 1, height: max(0.01, bottom - top)))
        }
        return ScanTable(rows: rows, rowBounds: bounds)
    }
    static func ruledTable(_ page: ScanPage, schedule: Bool) -> ScanTable? {
        let ys = page.horizontalRules.sorted(), xs = page.verticalRules.sorted()
        guard ys.count >= 4, xs.count >= 4 else { return nil }
        var rows = [[String]](); var bounds = [CGRect?]()
        for r in 0..<(ys.count - 1) where ys[r + 1] - ys[r] > 0.005 {
            var cells = [String]()
            for c in 0..<(xs.count - 1) {
                let words = page.words.filter { $0.midY >= ys[r] && $0.midY < ys[r + 1] && $0.midX >= xs[c] && $0.midX < xs[c + 1] }
                cells.append(lines(words).map { $0.map(\.text).joined(separator: " ") }.joined(separator: " "))
            }
            rows.append(cells)
            bounds.append(CGRect(x: max(0, xs[0] - 0.01), y: max(0, ys[r] - 0.005),
                width: min(1 - xs[0], xs[xs.count - 1] - xs[0] + 0.02), height: ys[r + 1] - ys[r] + 0.01))
        }
        let table = ScanTable(rows: rows, rowBounds: bounds)
        let schema = ScanParsing.schema(table, schedule: schedule)
        guard schema.fields.filter({ $0 != .ignore }).count >= 3 else { return nil }
        return table
    }
    static func score(_ tables: [ScanTable], schedule: Bool, year: Int) -> Int {
        let drafts = ScanParsing.parsedDrafts(tables, schedule: schedule, year: year, overrides: [:])
        return drafts.reduce(0) { total, draft in
            if let flight = draft.flight {
                let hasHours = (Double(flight.duration) ?? 0) > 0
                return total + 2 + (hasHours ? 3 : 0) + (ScanParsing.registration(flight.aircraft, bareAllowed: false).isEmpty ? 0 : 3)
            }
            if let item = draft.schedule { return total + 2 + (item.isGround || !item.registration.isEmpty ? 3 : 0) + (item.endDate != nil ? 1 : 0) }
            return total
        }
    }
    static func chooseTables(_ page: ScanPage, schedule: Bool, year: Int) -> [ScanTable] {
        let native = page.tables.filter {
            let schema = ScanParsing.schema($0, schedule: schedule)
            return schema.fields.filter { $0 != .ignore }.count >= 2
        }
        var candidates = [[ScanTable]]()
        if !native.isEmpty { candidates.append(native) }
        if let grid = ruledTable(page, schedule: schedule) { candidates.append([grid]) }
        if let fallback = fallbackTable(page.words, schedule: schedule) { candidates.append([fallback]) }
        return candidates.max { score($0, schedule: schedule, year: year) < score($1, schedule: schedule, year: year) } ?? page.tables
    }

}

// Printed row/column rules provide structure even when dates and ditto marks are faint.
enum ScanGrid {
    nonisolated static func rules(_ image: CGImage) -> (horizontal: [Double], vertical: [Double]) {
        let scale = min(1, 1200 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return ([], []) }
        var horizontal = [Int](repeating: 0, count: height), vertical = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] < 115 {
                horizontal[y] += 1; vertical[x] += 1
            }
        }
        func centers(_ counts: [Int], threshold: Int) -> [Double] {
            var ranges = [(Int, Int)](); var start: Int?
            for i in counts.indices {
                if counts[i] >= threshold { if start == nil { start = i } }
                else if let first = start { ranges.append((first, i - 1)); start = nil }
            }
            if let first = start { ranges.append((first, counts.count - 1)) }
            return ranges.filter { $0.1 - $0.0 < max(4, counts.count / 35) }.map { Double($0.0 + $0.1) / (2 * Double(counts.count)) }
        }
        let h = centers(horizontal, threshold: max(8, Int(Double(width) * 0.48)))
        let v = centers(vertical, threshold: max(8, Int(Double(height) * 0.40)))
        return (h.count >= 4 ? h : [], v.count >= 4 ? v : [])
    }
}

enum TextScan {
    nonisolated static func read(_ data: Data, schedule: Bool) async throws -> ScanPage {
        let worker = Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw URLError(.cannotDecodeContentData) }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = CGImagePropertyOrientation(rawValue: (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1) ?? .up
            var input = CIImage(cgImage: cg).oriented(orientation)
            let context = CIContext()
            if !schedule, let upright = context.createCGImage(input, from: input.extent) {
                // Rectify photographed paper before OCR; keep the corrected page as review evidence.
                let rectangleRequest = VNDetectRectanglesRequest()
                rectangleRequest.minimumAspectRatio = 0.2; rectangleRequest.maximumAspectRatio = 1
                rectangleRequest.minimumSize = 0.4; rectangleRequest.minimumConfidence = 0.75
                rectangleRequest.maximumObservations = 6
                try? VNImageRequestHandler(cgImage: upright, orientation: .up).perform([rectangleRequest])
                let candidates = (rectangleRequest.results ?? []).filter { $0.boundingBox.width > 0.65 && $0.boundingBox.height > 0.45 }
                if let rectangle = candidates.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                    func point(_ p: CGPoint) -> CIVector {
                        CIVector(x: input.extent.minX + p.x * input.extent.width, y: input.extent.minY + p.y * input.extent.height)
                    }
                    input = input.applyingFilter("CIPerspectiveCorrection", parameters: [
                        "inputTopLeft": point(rectangle.topLeft), "inputTopRight": point(rectangle.topRight),
                        "inputBottomLeft": point(rectangle.bottomLeft), "inputBottomRight": point(rectangle.bottomRight)])
                }
            }
            guard let image = context.createCGImage(input, from: input.extent) else { throw URLError(.cannotDecodeContentData) }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { throw URLError(.cannotDecodeContentData) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotDecodeContentData) }
            var tables = [ScanTable]()
            var transcript = ""
            if #available(iOS 26.0, *) {
                // Document recognition retains empty cells, rows, and column relationships.
                do {
                    let observations = try await RecognizeDocumentsRequest().perform(on: png as Data)
                    if let document = observations.first?.document {
                        transcript = document.text.transcript
                        tables = document.tables.map { table in
                            ScanTable(rows: table.rows.map { row in row.map { $0.content.text.transcript } })
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { /* Coordinate-based recognition below remains available. */ }
            }
            let enhanced = CIImage(cgImage: image).applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": 1.4])
            let enhancedImage = context.createCGImage(enhanced, from: enhanced.extent)
            if !schedule, tables.isEmpty, #available(iOS 26.0, *), let enhancedImage {
                do {
                    let observations = try await RecognizeDocumentsRequest().perform(on: enhancedImage)
                    if let document = observations.first?.document {
                        if transcript.isEmpty { transcript = document.text.transcript }
                        tables = document.tables.map { table in ScanTable(rows: table.rows.map { row in row.map { $0.content.text.transcript } }) }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { /* OCR and printed-rule reconstruction still run. */ }
            }
            var words = [ScanBox]()
            let width = Double(image.width), height = Double(image.height)
            // Overlapping crops retain small table text that can be missed in a full-page OCR pass.
            let regions: [CGRect] = [CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 0, y: 0, width: 0.55, height: 0.56), CGRect(x: 0.45, y: 0, width: 0.55, height: 0.56), CGRect(x: 0, y: 0.44, width: 0.55, height: 0.56), CGRect(x: 0.45, y: 0.44, width: 0.55, height: 0.56)]
            let passes: [(CGImage, CGRect)] = regions.map { (image, $0) } + (!schedule ? enhancedImage.map { [($0, CGRect(x: 0, y: 0, width: 1, height: 1))] } ?? [] : [])
            for (passImage, region) in passes {
                try Task.checkCancellation()
                let pixels = CGRect(x: region.minX * width, y: region.minY * height, width: region.width * width, height: region.height * height).integral
                guard let crop = passImage.cropping(to: pixels) else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.002
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
                for observation in request.results ?? [] {
                    guard let candidate = observation.topCandidates(1).first,
                          let regex = try? NSRegularExpression(pattern: #"\S+"#) else { continue }
                    let text = candidate.string
                    let tokens = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    for token in tokens {
                        guard let range = Range(token.range, in: text) else { continue }
                        let rectangle = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                        var word = ScanBox(text: String(text[range]), x: (pixels.minX + rectangle.minX * pixels.width) / width,
                            y: (pixels.minY + (1 - rectangle.maxY) * pixels.height) / height,
                            width: rectangle.width * pixels.width / width, height: rectangle.height * pixels.height / height,
                            confidence: candidate.confidence)
                        if let index = words.firstIndex(where: { existing in
                            let sameText = ScanParsing.normalized(existing.text) == ScanParsing.normalized(word.text)
                            let nearby = abs(existing.midX - word.midX) < max(0.004, min(existing.width, word.width) * 0.4)
                                && abs(existing.midY - word.midY) < max(0.002, min(existing.height, word.height) * 0.6)
                            let oldBounds = CGRect(x: existing.x, y: existing.y, width: existing.width, height: existing.height)
                            let newBounds = CGRect(x: word.x, y: word.y, width: word.width, height: word.height)
                            let overlap = oldBounds.intersection(newBounds)
                            let oldArea = existing.width * existing.height, newArea = word.width * word.height
                            let areaRatio = min(oldArea, newArea) / max(0.000001, max(oldArea, newArea))
                            let sharedArea = overlap.isNull ? 0 : Double(overlap.width * overlap.height)
                            return (sameText && nearby) || (areaRatio > 0.55 && sharedArea > min(oldArea, newArea) * 0.75)
                        }) {
                            let existing = words[index]
                            let different = ScanParsing.normalized(existing.text) != ScanParsing.normalized(word.text)
                            let alternatives = Array(Set(existing.alternatives + (different ? [existing.text, word.text] : []))).sorted()
                            if word.confidence > existing.confidence { word.alternatives = alternatives; words[index] = word }
                            else { words[index].alternatives = alternatives }
                        } else { words.append(word) }
                    }
                }
            }
            let rules = schedule ? (horizontal: [Double](), vertical: [Double]()) : ScanGrid.rules(image)
            return ScanPage(tables: tables, words: words, imagePNG: png as Data, transcript: transcript,
                horizontalRules: rules.horizontal, verticalRules: rules.vertical)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}

struct ScanMappingEditor: View {
    @Environment(\.dismiss) var dismiss
    @State var fields: [ScanField]
    let headers: [String]
    let onSave: ([ScanField]) -> Void
    var body: some View {
        SheetFrame(title: "Match the columns") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose what each photo column contains. Unassigned columns stay in the entry's comments.").font(.subheadline)
                ForEach(fields.indices, id: \.self) { index in
                    Picker(index < headers.count ? headers[index] : "Column \(index + 1)", selection: $fields[index]) {
                        ForEach(ScanField.allCases) { field in Text(field.title).tag(field) }
                    }.pickerStyle(.menu)
                }
                AccentButton(title: "Apply column mapping") { onSave(fields); dismiss() }
            }
        }
    }
}

// Apple's guided document camera supplies edge detection, perspective correction and recapture controls.
struct GuidedDocumentCamera: UIViewControllerRepresentable {
    let finished: ([Data]) -> Void
    let cancelled: () -> Void
    let failed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let owner: GuidedDocumentCamera
        init(_ owner: GuidedDocumentCamera) { self.owner = owner }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0, scan.pageCount <= 10 else { owner.failed("Scan between 1 and 10 pages at a time."); return }
            var pages: [Data] = []
            for index in 0..<scan.pageCount {
                guard let data = scan.imageOfPage(at: index).jpegData(compressionQuality: 0.94) else {
                    owner.failed("A scanned page could not be opened. Please recapture it."); return
                }
                pages.append(data)
            }
            owner.finished(pages)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { owner.cancelled() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { owner.failed(error.localizedDescription) }
    }
}

@MainActor struct ScanReview: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var store: FlightStore
    var schedule: Bool
    var onCompletionChanged: ((Bool) -> Void)? = nil
    @State private var photo: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var preparationRun = 0
    @State private var showDocumentCamera = false
    @State private var cameraPages: [Data] = []
    @State private var cameraPageIndex = 0
    @State private var qualityWarnings: [String] = []
    @State private var cameraPermissionTask: Task<Void, Never>?
    @State private var originalPhoto: Data?
    @State private var inputs: [AIPhotoInput] = []
    @State private var ocrHints: [AITextHint] = []
    @State private var page: ScanPage?
    @State private var tables: [ScanTable] = []
    @State private var overrides: [String: [ScanField]] = [:]
    @State private var drafts: [ScanFlightDraft] = []
    @State private var working = false
    @State private var problem = ""
    @State private var reviewing = false
    @State private var index = 0
    @State private var saved = 0
    @State private var skipped = 0
    @State private var previousSaved = 0
    @State private var previousSkipped = 0
    @State private var automaticallySaved = 0
    @State private var previousAutomaticallySaved = 0
    @State private var duplicateCount = 0
    @State private var previousDuplicateCount = 0
    @State private var bypassedScheduleReview = false
    @State private var notAdded: [ImportFailure] = []
    @State private var previousNotAdded: [ImportFailure] = []
    @State private var confirmWithoutReview = false
    @State private var year = String(Calendar.current.component(.year, from: Date()))
    @State private var mapping: ScanTable?
    @State private var rawText = ""
    @State private var correctedText = false
    @State private var showSource = false
    @State private var showSettings = false
    @State private var configured = AIImportConfiguration.ready
    @State private var scanRun = 0
    @State private var requestedBasic = false
    @State private var basicResult = false
    @State private var pageWarnings: [String] = []
    private var resolvedYear: Int { Int(year).flatMap { (1900...2199).contains($0) ? $0 : nil } ?? Calendar.current.component(.year, from: Date()) }
    var body: some View {
        reviewContent
        .task(id: photo) {
            guard let photo else { return }
            working = true
            defer { working = false }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw URLError(.cannotDecodeContentData) }
                try Task.checkCancellation()
                cameraPages = []; cameraPageIndex = 0; resetImportSummary(); stageImage(data)
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
        .task(id: preparationRun) {
            guard preparationRun > 0, let data = selectedImageData else { return }
            working = true; resetReading(); originalPhoto = nil; inputs = []; ocrHints = []; page = nil; qualityWarnings = []
            defer { working = false }
            do {
                let prepared = try await AIPhotoImporter.prepareImage(data, schedule: schedule)
                try Task.checkCancellation()
                originalPhoto = data; inputs = prepared.inputs; ocrHints = prepared.textHints
                qualityWarnings = prepared.qualityWarnings
                page = ScanPage(tables: [], words: [], imagePNG: prepared.preview)
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
        .task(id: scanRun) {
            guard scanRun > 0, let data = originalPhoto else { return }
            working = true; resetReading()
            defer { working = false }
            do {
                if requestedBasic { try await readBasic(data) }
                else {
                    let result = try await AIPhotoImporter.read(inputs, schedule: schedule, year: resolvedYear, ocrHints: ocrHints)
                    try Task.checkCancellation()
                    drafts = AIPhotoImporter.drafts(result); pageWarnings = qualityWarnings + result.pageWarnings; basicResult = false
                    rawText = result.entries.map { "Entry \($0.rowNumber): " + $0.sourceText }.joined(separator: "\n\n")
                    if drafts.isEmpty { problem = "No flight entries were found. Check that the complete page is readable, then try another photo or a smaller section." }
                }
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { problem = error.localizedDescription + " No entries were saved. You can retry or choose basic text reading." } }
        }
        .sheet(isPresented: $showSettings, onDismiss: { configured = AIImportConfiguration.ready }) { AIImportSettings() }
        .fullScreenCover(isPresented: $showDocumentCamera) {
            GuidedDocumentCamera(finished: { pages in
                showDocumentCamera = false; cameraPages = pages; cameraPageIndex = 0
                resetImportSummary()
                if let first = pages.first { stageImage(first) }
            }, cancelled: { showDocumentCamera = false }, failed: { message in
                showDocumentCamera = false; problem = message
            }).ignoresSafeArea()
        }
        .sheet(isPresented: $showSource) {
            if let image = page.flatMap({ UIImage(data: $0.imagePNG) }) {
                SheetFrame(title: "Source photo") { ScanPhotoZoom(image: image).frame(height: 540) }
            }
        }
        .sheet(item: $mapping) { table in
            let schema = ScanParsing.schema(table, schedule: schedule)
            ScanMappingEditor(fields: overrides[table.id] ?? schema.fields, headers: schema.headers) { fields in
                overrides[table.id] = fields; rebuildDrafts()
            }
        }
        .alert("Save without reviewing?", isPresented: $confirmWithoutReview) {
            Button("Go back", role: .cancel) {}
            Button("Continue") {
                if schedule { beginScheduleImport(.withoutReview) }
                else { beginPhotoImport(.withoutReview) }
            }
        } message: {
            Text("We recommend reviewing at least the flagged flights before saving. Continue to save without checking them? Entries missing required details will be listed on the completion screen and won't be added.")
        }
    }
    @ViewBuilder private var reviewContent: some View {
        if reviewing, drafts.indices.contains(index) {
            reviewEditor(drafts[index])
        } else if reviewing {
            reviewCompletion
        } else {
            preparation
        }
    }
    @ViewBuilder private func reviewEditor(_ current: ScanFlightDraft) -> some View {
        if let item = current.schedule {
            ScheduleEditor(item: item, importReview: scheduledReviewContext(current),
                           onImportSaved: { advance(saved: true) },
                           onImportSkipped: { advance(saved: false) }).id(current.id)
        } else if let flight = current.flight {
            FlightEditor(flight: flight, importReview: reviewContext(current),
                         onImportSaved: { advance(saved: true) },
                         onImportSkipped: { advance(saved: false) }).id(current.id)
        }
    }
    private var reviewCompletion: ImportReviewCompletion {
        let destination = schedule ? "calendar" : "logbook"
        let savedCount = previousSaved + saved
        let skippedCount = previousSkipped + skipped
        let automaticCount = previousAutomaticallySaved + automaticallySaved
        let duplicates = previousDuplicateCount + duplicateCount
        let failures = previousNotAdded + notAdded
        if cameraPageIndex + 1 < cameraPages.count {
            return ImportReviewCompletion(title: bypassedScheduleReview ? "Page saved" : "Page reviews complete", saved: savedCount, skipped: skippedCount,
                duplicates: duplicates, automaticallySaved: automaticCount, savedWithoutReview: bypassedScheduleReview, destination: destination,
                notAdded: failures,
                nextPageTitle: "Continue to scanned page \(cameraPageIndex + 2) of \(cameraPages.count)",
                onNextPage: { continueScannedPage() }, onClose: { dismiss() })
        }
        return ImportReviewCompletion(title: "All reviews complete", saved: savedCount, skipped: skippedCount,
            duplicates: duplicates, automaticallySaved: automaticCount, savedWithoutReview: bypassedScheduleReview, destination: destination,
            notAdded: failures, onClose: { dismiss() })
    }
    private var preparation: some View {
        SheetFrame(title: schedule ? "Import schedule photo" : "Import logbook photo") {
            VStack(alignment: .leading, spacing: 18) {
                Text(schedule ? "AI reads each booking's date, time, aircraft and details from the image. Choose how to review the scheduled flights and ground lessons before adding them to your calendar." : "AI reads the handwriting, headings and rows together. Review each flight's extracted details before adding it to your logbook.")
                    .font(.subheadline).foregroundStyle(theme.muted)
                AccentButton(title: "Scan document") { openDocumentCamera() }.disabled(working)
                PhotosPicker(selection: $photo, matching: .images) {
                    AccentButtonLabel(title: "Choose photo")
                }.buttonStyle(.plain).disabled(working)
                if !cameraPages.isEmpty { Text("Scanned page \(cameraPageIndex + 1) of \(cameraPages.count)").font(.caption).foregroundStyle(theme.muted) }
                Text("Capture the whole page, including headings, landing columns and remarks. Keep it flat and evenly lit.")
                    .font(.caption).foregroundStyle(theme.muted)
                if let image = page.flatMap({ UIImage(data: $0.imagePNG) }) {
                    Button { showSource = true } label: {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                    Text("Tap the photo to zoom in.").font(.caption).foregroundStyle(theme.muted)
                }
                if originalPhoto != nil, !reviewing {
                    if !qualityWarnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Check photo quality", systemImage: "exclamationmark.circle.fill").font(.subheadline.bold())
                            ForEach(qualityWarnings, id: \.self) { Text($0).font(.caption) }
                            Text("You can recapture the page or continue and check every draft.").font(.caption)
                        }.foregroundStyle(ScanReviewColors.warning(theme.dark)).logbookCard()
                    }
                    LogField(title: "Year if the photo does not show one", value: $year, hint: "2026", keyboard: .numberPad).disabled(working)
                    if configured {
                        Text("Your photo is sent securely for AI reading. Review the editable drafts before saving.")
                            .font(.caption).foregroundStyle(theme.muted)
                        AccentButton(title: "Read with AI") { requestedBasic = false; scanRun += 1 }.disabled(working)
                    } else {
                        Text("AI image reading needs a connected import service. Basic text reading remains available, with more limited handwriting and layout recognition.")
                            .font(.subheadline).foregroundStyle(theme.muted)
                        Button("Connect AI image imports") { showSettings = true }.foregroundStyle(theme.cyan).disabled(working)
                    }
                    Button("Use basic text reading") { requestedBasic = true; scanRun += 1 }.font(.subheadline).foregroundStyle(theme.muted).disabled(working)
                }
                if working { ProgressView(inputs.isEmpty ? "Preparing photo and checking quality…" : requestedBasic ? "Reading text and columns…" : "Reading handwriting and separating entries…") }
                if !problem.isEmpty { Text(problem).foregroundStyle(theme.accent) }
                if !working, !reviewing, page != nil {
                    if !pageWarnings.isEmpty {
                        DisclosureGroup("Other scan notes") {
                            ForEach(Array(pageWarnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.subheadline).foregroundStyle(theme.accent) }
                        }.logbookCard()
                    }
                    if !drafts.isEmpty {
                        Text("\(drafts.count) \(drafts.count == 1 ? "entry" : "entries") ready to review").font(.headline)
                        Text(basicResult ? "Read with basic text recognition" : "Read with AI image interpretation").font(.caption).foregroundStyle(theme.muted)
                        if schedule { scheduleReviewChoices }
                        else { photoReviewChoices }
                    }
                    if basicResult {
                        ForEach(Array(tables.enumerated()), id: \.element.id) { tableIndex, table in
                            Button("Check column mapping\(tables.count > 1 ? " · table \(tableIndex + 1)" : "")") { mapping = table }.foregroundStyle(theme.cyan)
                        }
                        DisclosureGroup("Recognized text / correct a reading") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Correct missed characters or separate entries onto new lines. For a table, keep | separators and empty cells.").font(.caption).foregroundStyle(theme.muted)
                                TextEditor(text: $rawText).font(.system(size: 13, design: .monospaced)).frame(minHeight: 200)
                                    .scrollContentBackground(.hidden).padding(10).background(theme.raised).clipShape(RoundedRectangle(cornerRadius: 12))
                                Button("Use corrected text") { correctedText = true; rebuildDrafts() }.foregroundStyle(theme.cyan)
                            }.padding(.top, 10)
                        }
                    } else if !rawText.isEmpty {
                        DisclosureGroup("AI source readings") { Text(rawText).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).padding(.top, 10) }
                    }
                    if drafts.isEmpty, !problem.isEmpty { Button("Enter a draft with this photo") { startUncertainDraft() }.foregroundStyle(theme.cyan) }
                }
            }
        }
    }
    @ViewBuilder private var scheduleReviewChoices: some View {
        AccentButton(title: "Review all scheduled flights") { beginScheduleImport(.all) }
        scheduleSecondaryAction("Review flagged flights only", symbol: "exclamationmark.circle") { beginScheduleImport(.flagged) }
        scheduleSecondaryAction("Save without reviewing", symbol: "square.and.arrow.down") { confirmWithoutReview = true }
    }
    @ViewBuilder private var photoReviewChoices: some View {
        AccentButton(title: "Review all flights") { beginPhotoImport(.all) }
        scheduleSecondaryAction("Review flagged flights only", symbol: "exclamationmark.circle") { beginPhotoImport(.flagged) }
        scheduleSecondaryAction("Save without reviewing", symbol: "square.and.arrow.down") { confirmWithoutReview = true }
    }
    private func beginPhotoImport(_ mode: CSVReviewMode) {
        guard !schedule else { return }
        var automatic: [Flight] = []
        var review: [ScanFlightDraft] = []
        var failures: [ImportFailure] = []
        for (number, draft) in drafts.enumerated() {
            guard var flight = draft.flight else {
                if mode == .withoutReview {
                    failures.append(ImportFailure(id: draft.id, title: "Flight \(number + 1)", subtitle: "Missing flight details",
                        issues: [ScanFieldIssue(field: "date", message: "The flight could not be read. Enter its date and registration.")]))
                } else { review.append(draft) }
                continue
            }
            let issues = FlightEntryValidation.requiredIssues(flight, missingDate: draft.unresolvedFields.contains("date"))
            let evidence = reviewContext(draft)
            if mode == .all || (mode == .flagged && (!issues.isEmpty || !evidence.fieldIssues.isEmpty || !evidence.otherNotes.isEmpty)) {
                review.append(draft)
            } else if !issues.isEmpty {
                failures.append(.flight(flight, number: number + 1, issues: issues))
            } else {
                flight.facts.text["importReviewStatus"] = mode == .withoutReview ? "Saved without review" : "No flagged fields; saved automatically"
                flight.facts.text["importUnreviewedFields"] = evidence.fieldIssues.map(\.field).joined(separator: ", ")
                flight.facts.text["scanImportWarnings"] = evidence.warnings.joined(separator: "\n")
                flight.facts.text["scanSource"] = draft.sourceText
                automatic.append(flight)
            }
        }
        guard store.saveImportedFlights(automatic) else {
            problem = store.errorMessage ?? "The imported flights could not be saved."; return
        }
        drafts = review; index = 0; saved = automatic.count; skipped = 0
        automaticallySaved = automatic.count; duplicateCount = 0; notAdded = failures
        if mode == .withoutReview { bypassedScheduleReview = true }
        problem = ""; reviewing = true; onCompletionChanged?(drafts.isEmpty)
    }
    private func scheduleSecondaryAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.cyan).frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(theme.surface).clipShape(Capsule()).overlay(Capsule().stroke(theme.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func beginScheduleImport(_ mode: ScheduleReviewMode) {
        guard schedule else { return }
        let plan = ScheduleImportReview.plan(drafts, existing: store.schedules, mode: mode, context: { scheduledReviewContext($0) })
        guard store.saveImportedSchedules(plan.automatic) else {
            problem = store.errorMessage ?? "The scheduled flights could not be saved."; return
        }
        if !plan.automatic.isEmpty { Task { await ReminderManager.rebuild(store.schedules) } }
        drafts = plan.review; index = 0; saved = plan.automatic.count; skipped = 0
        automaticallySaved = plan.automatic.count; duplicateCount = plan.duplicates
        notAdded = plan.notAdded
        if mode == .withoutReview { bypassedScheduleReview = true }
        problem = ""; reviewing = true; onCompletionChanged?(drafts.isEmpty)
    }
    private func scheduledReviewContext(_ draft: ScanFlightDraft) -> ScanReviewContext {
        var context = reviewContext(draft)
        let additionalWarnings = pageWarnings.filter { !context.warnings.contains($0) }
        context.warnings += additionalWarnings
        if let item = draft.schedule { context.issues += ScheduleImportReview.validationIssues(item) }
        return context
    }
    private func resetImportSummary() {
        previousSaved = 0; previousSkipped = 0; previousAutomaticallySaved = 0; previousDuplicateCount = 0
        bypassedScheduleReview = false
        notAdded = []; previousNotAdded = []
    }
    private func resetReading() {
        problem = ""; reviewing = false; rawText = ""; drafts = []; tables = []; overrides = [:]
        correctedText = false; basicResult = false; pageWarnings = []
        automaticallySaved = 0; duplicateCount = 0
        notAdded = []
        onCompletionChanged?(false)
    }
    private func stageImage(_ data: Data) {
        reviewing = false; onCompletionChanged?(false)
        selectedImageData = data; preparationRun += 1
    }
    private func continueScannedPage() {
        guard cameraPageIndex + 1 < cameraPages.count else { return }
        previousSaved += saved; previousSkipped += skipped
        previousAutomaticallySaved += automaticallySaved; previousDuplicateCount += duplicateCount
        previousNotAdded += notAdded
        cameraPageIndex += 1; stageImage(cameraPages[cameraPageIndex])
    }
    private func openDocumentCamera() {
        guard VNDocumentCameraViewController.isSupported else { problem = "Document scanning is not supported on this device. Choose a photo instead."; return }
        guard let description = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = "Add Privacy - Camera Usage Description (NSCameraUsageDescription) to the Xcode target's Info settings to enable document scanning."
            return
        }
        cameraPermissionTask?.cancel()
        cameraPermissionTask = Task { @MainActor in
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            let allowed: Bool
            if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
            else { allowed = status == .authorized }
            guard !Task.isCancelled else { return }
            if allowed { showDocumentCamera = true; problem = "" }
            else { problem = "Camera access is off. Enable it in iOS Settings for LogMate, or choose a photo." }
        }
    }
    private func readBasic(_ data: Data) async throws {
        let result = try await TextScan.read(data, schedule: schedule)
        try Task.checkCancellation()
        page = result; basicResult = true; pageWarnings = qualityWarnings
        tables = ScanLayout.chooseTables(result, schedule: schedule, year: resolvedYear)
        let lines = ScanLayout.lines(result.words).map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
        let geometric = ScanTextEntries.drafts(lines, schedule: schedule, year: resolvedYear)
        let document = ScanTextEntries.drafts(result.transcript, schedule: schedule, year: resolvedYear)
        rawText = document.count > geometric.count ? result.transcript : lines
        rebuildDrafts()
        if !tables.isEmpty, ScanLayout.score(tables, schedule: schedule, year: resolvedYear) >= draftScore(ScanTextEntries.drafts(rawText, schedule: schedule, year: resolvedYear)),
           let table = tables.first, tables.count == 1 {
            let schema = ScanParsing.schema(table, schedule: schedule)
            let rows = [schema.headers] + Array(table.rows.dropFirst(schema.firstDataRow))
            rawText = rows.map { $0.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") }.joined(separator: "\n")
        }
    }
    private func draftScore(_ items: [ScanFlightDraft]) -> Int {
        items.reduce(0) { total, draft in
            if let flight = draft.flight { return total + 2 + (flight.total > 0 ? 3 : 0) + (!flight.registration.isEmpty ? 3 : 0) }
            if let item = draft.schedule { return total + 2 + (item.isGround || !item.registration.isEmpty ? 3 : 0) + (item.endDate != nil ? 1 : 0) }
            return total
        }
    }
    private func rebuildDrafts() {
        let textDrafts = ScanTextEntries.drafts(rawText, schedule: schedule, year: resolvedYear)
        if correctedText { drafts = textDrafts }
        else {
            let rowDrafts = ScanParsing.parsedDrafts(tables, schedule: schedule, year: resolvedYear, overrides: overrides)
            drafts = draftScore(rowDrafts) >= draftScore(textDrafts) ? rowDrafts : textDrafts
        }
        problem = drafts.isEmpty ? "Basic text reading could not separate entries. Try AI reading, correct the recognized text, or enter a draft from the photo." : ""
    }
    private func startUncertainDraft() {
        let warnings = ["Enter the date and registration from the source before saving. Other fields can be left blank."]
        drafts = schedule
            ? [ScanFlightDraft(schedule: ScheduledFlight(), sourceText: rawText, sourceBounds: nil, warnings: warnings, unresolvedFields: ["date", "start"])]
            : [ScanFlightDraft(flight: Flight(), sourceText: rawText, sourceBounds: nil, warnings: warnings, unresolvedFields: ["date"])]
        index = 0; saved = 0; skipped = 0; reviewing = true
    }
    private func advance(saved accepted: Bool) {
        if accepted {
            saved += 1
            // Carry a corrected aircraft through following ditto rows, keeping every row editable.
            if let scanned = drafts[index].flight, let confirmed = store.flights.first(where: { $0.id == scanned.id }), index + 1 < drafts.count {
                for next in (index + 1)..<drafts.count {
                    guard drafts[next].repeatsRegistration, var flight = drafts[next].flight else { break }
                    let makeModel = drafts[next].repeatsModel ? confirmed.aircraftModel : flight.aircraftModel
                    flight.aircraft = confirmed.registration + " · " + makeModel
                    drafts[next].flight = flight
                    drafts[next].warnings.append("Aircraft updated from the preceding saved entry's ditto mark. Check it against this row.")
                }
            }
        } else { skipped += 1 }
        index += 1
        if index >= drafts.count { onCompletionChanged?(true) }
    }
    private func reviewContext(_ draft: ScanFlightDraft) -> ScanReviewContext {
        var warnings = draft.warnings + qualityWarnings
        if let bounds = draft.sourceBounds, let page,
           page.words.contains(where: { bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) && $0.confidence < 0.5 }) {
            warnings.append("Some writing in this row has low recognition confidence. Compare the draft with the photo.")
        }
        if let bounds = draft.sourceBounds, let page,
           page.words.contains(where: { bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) && !$0.alternatives.isEmpty }) {
            warnings.append("Recognition passes disagreed on some characters in this row. Check numbers and aircraft registration against the photo.")
        }
        if let item = draft.schedule, store.schedules.contains(where: { existing in
            if let source = item.sourceScheduleID, !source.isEmpty, source == existing.sourceScheduleID { return true }
            return abs(existing.date.timeIntervalSince(item.date)) < 60 && existing.registration == item.registration && existing.isGround == item.isGround
        }) { warnings.append("A matching booking is already in your calendar. Skip this entry to avoid a duplicate.") }
        if let flight = draft.flight, store.flights.contains(where: { $0.date == flight.date && $0.registration == flight.registration && $0.route == flight.route && abs($0.total - flight.total) < 0.001 }) {
            warnings.append("A matching flight is already in your logbook. Skip it unless this is a separate flight.")
        }
        let image = page.flatMap { UIImage(data: $0.imagePNG) }
        var rowImage: UIImage?
        if let cg = image?.cgImage, let rect = draft.sourceBounds {
            let pixels = CGRect(x: rect.minX * Double(cg.width), y: rect.minY * Double(cg.height), width: rect.width * Double(cg.width), height: rect.height * Double(cg.height)).integral
            if let crop = cg.cropping(to: pixels) { rowImage = UIImage(cgImage: crop) }
        }
        return ScanReviewContext(title: "Review \(schedule ? "booking" : "flight") \(index + 1) of \(drafts.count)", sourceText: draft.sourceText, image: image, warnings: warnings, unresolvedFields: draft.unresolvedFields, issues: draft.issues, rowImage: rowImage)
    }
}

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
