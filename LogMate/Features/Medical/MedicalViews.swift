// Medical currency tab: the currency section, privilege rows, the medical
// editor, and the WINGS editor.
import SwiftUI
import Foundation
import PhotosUI

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
