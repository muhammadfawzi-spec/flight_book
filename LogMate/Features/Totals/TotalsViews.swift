// Totals tab: the totals screen, filter sheet, IACRA view, experience
// flights, and the checkride screen.
import SwiftUI
import Foundation

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
