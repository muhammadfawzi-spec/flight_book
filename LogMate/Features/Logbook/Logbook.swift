// The Logbook tab: flight row, logbook screen, the session photo card,
// and the flight list popup.
import SwiftUI
import Foundation

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
