// Training tab: the path picker, goal progress, course/ground editor,
// duty approval, milestone flights, milestone evidence, and the flight
// review card.
import SwiftUI
import Foundation

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
