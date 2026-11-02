// The Aircraft tab: the feature picker, photo card and gallery, the
// aircraft list, add-aircraft, and the aircraft profile.
import SwiftUI
import Foundation
import UIKit
import PhotosUI

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
