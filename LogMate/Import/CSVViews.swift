// The CSV import user interface: the import sheet, the review table,
// completion screen, and the import-failure list.
import SwiftUI
import Foundation

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
