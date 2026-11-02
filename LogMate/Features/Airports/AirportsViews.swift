// Airport and fleet views: the airport flip card, fleet range sheet, and
// the airport detail.
import SwiftUI
import Foundation
import MapKit

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
