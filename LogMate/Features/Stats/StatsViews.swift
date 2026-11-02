// Stats tab: the memory photo, the stats screen, and the stats dashboard.
import SwiftUI
import Foundation
import MapKit

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
