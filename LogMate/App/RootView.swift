// App root: the tab definitions, the hand-drawn tab icons, and the
// top-level ContentView (header, tab bar, shared environment objects).
import SwiftUI

enum MainTab: Int, CaseIterable {
    case logbook, aircraft, totals, stats, calendar
    var title: String { ["Logbook", "Aircraft", "Totals", "Stats", "Calendar"][rawValue] }
    var icon: String { ["book", "airplane", "list.bullet", "chart.bar", "calendar"][rawValue] }
}

struct PrototypeTabIcon: Shape {
    let tab: MainTab
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 24 * rect.width, y: rect.minY + y / 24 * rect.height)
        }
        func line(_ points: [(CGFloat, CGFloat)], closed: Bool = false) {
            guard let first = points.first else { return }
            p.move(to: point(first.0, first.1))
            for item in points.dropFirst() { p.addLine(to: point(item.0, item.1)) }
            if closed { p.closeSubpath() }
        }
        switch tab {
        case .logbook:
            p.move(to: point(12, 5)); p.addQuadCurve(to: point(2, 3), control: point(6, 1))
            line([(2, 3), (2, 20)])
            p.addQuadCurve(to: point(12, 22), control: point(7, 18))
            p.addQuadCurve(to: point(22, 20), control: point(17, 18))
            p.addLine(to: point(22, 3)); p.addQuadCurve(to: point(12, 5), control: point(18, 1))
            line([(12, 5), (12, 22)])
        case .aircraft:
            // Top view, nose upward, as in the prototype.
            line([(12, 1), (12, 23)])
            line([(9.5, 4), (12, 1), (14.5, 4)])
            line([(12, 8), (3, 11), (3, 14), (12, 11), (21, 14), (21, 11)], closed: true)
            line([(12, 18.5), (7, 23), (17, 23)], closed: true)
        case .totals:
            for y in [CGFloat(5), 12, 19] {
                p.addEllipse(in: CGRect(x: point(2, y - 1.4).x, y: point(2, y - 1.4).y,
                                       width: rect.width * 2.8 / 24, height: rect.height * 2.8 / 24))
                line([(9, y), (22, y)])
            }
        case .stats:
            line([(2, 2), (2, 22), (23, 22)])
            line([(7, 18), (7, 14)]); line([(13, 18), (13, 8)])
            line([(19, 18), (19, 3)])
        case .calendar:
            p.addRoundedRect(in: CGRect(x: point(2, 5).x, y: point(2, 5).y,
                width: rect.width * 20 / 24, height: rect.height * 17 / 24), cornerSize: CGSize(width: 3, height: 3))
            line([(2, 10), (22, 10)]); line([(7, 2), (7, 7)]); line([(17, 2), (17, 7)])
            for y in [CGFloat(14), 18] { for x in [CGFloat(7), 12, 17] {
                p.addEllipse(in: CGRect(x: point(x - 0.6, y - 0.6).x, y: point(x - 0.6, y - 0.6).y,
                    width: rect.width * 1.2 / 24, height: rect.height * 1.2 / 24))
            } }
        }
        return p
    }
}

struct ContentView: View {
    @StateObject private var store = FlightStore()
    @StateObject private var theme = AppTheme()
    @StateObject private var photos = AircraftPhotos()
    @StateObject private var airports = AirportCatalog()
    @State private var tab: MainTab = .logbook
    @State private var more = false
    @State private var adding = false
    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if more { MoreScreen(onImportFinished: { more = false; tab = .logbook }) }
                else {
                    switch tab {
                    case .logbook: LogbookScreen()
                    case .aircraft: AircraftScreen()
                    case .totals: TotalsScreen()
                    case .stats: StatsScreen()
                    case .calendar: CalendarScreen()
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            tabBar
        }.background(theme.background.ignoresSafeArea()).foregroundStyle(theme.text)
            .environmentObject(store).environmentObject(theme).environmentObject(photos).environmentObject(airports)
            .preferredColorScheme(theme.dark ? .dark : .light).tint(theme.accent)
            .sheet(isPresented: $adding) {
                FlightEditor()
                    .environmentObject(store)
                    .environmentObject(theme)
                    .environmentObject(photos)
                    .environmentObject(airports)
            }
            .alert(AppBrand.name, isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK", role: .cancel) { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
    }
    private var header: some View {
        HStack {
            Button { more.toggle() } label: {
                Image(systemName: more ? "xmark" : "line.3.horizontal")
                    .font(.system(size: 21, weight: .semibold)).frame(width: 44, height: 44)
                    .background(theme.surface).clipShape(Circle())
                    .overlay(Circle().stroke(theme.line, lineWidth: 1))
            }.accessibilityLabel(more ? "Close More" : "Open More")
            Spacer()
            Text(more ? "More" : tab.title).font(.system(size: 25, weight: .heavy, design: .rounded))
            Spacer()
            Button { adding = true } label: {
                Image(systemName: "plus").font(.system(size: 29, weight: .regular))
                    .foregroundStyle(Color(hex: 0x15202A)).frame(width: 46, height: 46)
                    .background(theme.accent).clipShape(Circle())
            }.accessibilityLabel("Add flight")
        }.buttonStyle(.plain).padding(.horizontal, 18).padding(.vertical, 16)
            .background(theme.background).overlay(alignment: .bottom) { Rectangle().fill(theme.line).frame(height: 1) }
    }
    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(MainTab.allCases, id: \.rawValue) { item in
                Button { more = false; tab = item } label: {
                    VStack(spacing: 7) {
                        PrototypeTabIcon(tab: item).stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                            .frame(width: 25, height: 25).accessibilityHidden(true)
                        Text(item.title).font(.system(size: 11, weight: .medium))
                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                        .foregroundStyle(!more && tab == item ? theme.accent : theme.muted)
                        .background(!more && tab == item ? theme.accent.opacity(0.13) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 21))
                }
            }
        }.buttonStyle(.plain).padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
            .background(theme.surface.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(theme.line).frame(height: 1) }
    }
}
