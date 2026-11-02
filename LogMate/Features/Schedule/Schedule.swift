// Schedule tab: the calendar, schedule review mode/plan/import review,
// the schedule editor, the reminder manager, and the notification
// settings.
import SwiftUI
import Foundation
import UserNotifications

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
