// Flight entry authoring: the simulator editor, the full flight editor,
// the flight detail view, and the summary row.
import SwiftUI
import Foundation
import UIKit
import PhotosUI

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
