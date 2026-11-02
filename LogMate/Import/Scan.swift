// The on-device scan pipeline: the scanned-page model and fields, the
// review presentation/fields/logic, coordinate + text parsing, layout and
// grid resolution, the guided camera, the mapping editor, and the full
// scan-review UI. (Kept as one unit: it contains file-private helpers that
// cross-cut these types.)
import Foundation
import SwiftUI
import UIKit
import Vision
import VisionKit
import PhotosUI

struct ScanBox: Sendable {
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var confidence: Float
    var alternatives: [String] = []
    nonisolated var midX: Double { x + width / 2 }
    nonisolated var midY: Double { y + height / 2 }
}

struct ScanTable: Identifiable, Sendable {
    var id = UUID().uuidString
    var rows: [[String]]
    var rowBounds: [CGRect?] = []
}

struct ScanPage: Sendable {
    var tables: [ScanTable]
    var words: [ScanBox]
    var imagePNG: Data
    var transcript: String = ""
    var horizontalRules: [Double] = []
    var verticalRules: [Double] = []
}

enum ScanField: String, CaseIterable, Identifiable {
    case ignore, date, start, end, registration, model, route, departure, arrival
    case total, pic, night, imc, simulated, dual, instructor, crossCountry
    case dayLandings, nightLandings, landings, approaches, approachCount, holds, solo
    case notes, pilot, cfi, reference, resource, category
    case aselHours, asesHours, amelHours, amesHours, rotorHours, gliderHours
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ignore: return "Not a flight field"
        case .date: return "Date"
        case .start: return "Start date / time"
        case .end: return "End date / time"
        case .registration: return "Aircraft registration"
        case .model: return "Make / model"
        case .route: return "Route"
        case .departure: return "Departure airport"
        case .arrival: return "Arrival airport"
        case .total: return "Total hours / duration"
        case .pic: return "PIC hours"
        case .night: return "Night hours"
        case .imc: return "Actual instrument / IMC hours"
        case .simulated: return "Simulated instrument hours"
        case .dual: return "Dual received hours"
        case .instructor: return "Instructor hours"
        case .crossCountry: return "Cross-country hours"
        case .dayLandings: return "Day landings"
        case .nightLandings: return "Night landings"
        case .landings: return "Landings (day / night unspecified)"
        case .approaches: return "Approach details"
        case .approachCount: return "Approach count"
        case .holds: return "Hold count"
        case .solo: return "Solo hours"
        case .notes: return "Remarks / comments"
        case .pilot: return "Pilot name"
        case .cfi: return "Instructor name"
        case .reference: return "Schedule / entry number"
        case .resource: return "Resource / aircraft"
        case .category: return "Aircraft category / class"
        case .aselHours: return "Single-engine land hours"
        case .asesHours: return "Single-engine sea hours"
        case .amelHours: return "Multi-engine land hours"
        case .amesHours: return "Multi-engine sea hours"
        case .rotorHours: return "Rotorcraft hours"
        case .gliderHours: return "Glider hours"
        }
    }
}

struct ScanSchema {
    var headers: [String]
    var fields: [ScanField]
    var firstDataRow: Int
}

struct ScanFlightDraft: Identifiable {
    var id = UUID()
    var flight: Flight? = nil
    var schedule: ScheduledFlight? = nil
    var sourceText: String
    var sourceBounds: CGRect?
    var warnings: [String]
    var repeatsRegistration = false
    var repeatsModel = false
    var unresolvedFields: Set<String> = []
    var issues: [ScanFieldIssue] = []
}

struct ScanScrollTarget: Equatable { var field: String; var token = UUID() }
nonisolated struct ScanFieldIssue: Identifiable, Equatable, Sendable {
    var field: String
    var message: String
    var id: String { field }
}
nonisolated enum ScanReviewFields {
    static let order = ["date", "start", "end", "registration", "model", "route", "departure", "arrival", "total", "pic", "sic", "solo", "landings", "day", "nightLandings", "night", "imc", "dual", "instructor", "xc", "sim", "approaches", "approachCount", "holds", "category", "notes", "title"]
    static func key(_ field: String) -> String? {
        let name = field.lowercased().filter { $0.isLetter || $0.isNumber }
        let aliases: [String: String] = ["date":"date", "start":"start", "starttime":"start", "enddate":"end", "endtime":"end",
            "registration":"registration", "aircraft":"registration", "aircraftregistration":"registration", "aircraftregistrationoptional":"registration", "nnumber":"registration", "makemodel":"model", "model":"model", "makeandmodel":"model",
            "route":"route", "departureairport":"departure", "arrivalairport":"arrival", "departure":"departure", "arrival":"arrival", "total":"total", "totalhours":"total", "totaltime":"total", "estimateddurationhours":"total", "pichours":"pic", "pictime":"pic", "pic":"pic", "sic":"sic", "sictime":"sic", "solo":"solo", "solohours":"solo",
            "daylandings":"day", "nightlandings":"nightLandings", "unclassifiedlandings":"landings", "landings":"landings",
            "nighthours":"night", "nighttime":"night", "night":"night", "actualinstrumenthours":"imc", "actualinstrument":"imc", "imctime":"imc", "imc":"imc",
            "simulatedinstrumenthours":"sim", "simulatedinstrument":"sim", "siminstrument":"sim", "dualreceivedhours":"dual", "dualreceived":"dual", "dual":"dual", "instructionreceived":"dual",
            "instructorhours":"instructor", "instructortime":"instructor", "instructor":"instructor", "crosscountryhours":"xc", "crosscountry":"xc", "xc":"xc",
            "approaches":"approaches", "approachcount":"approachCount", "holds":"holds", "category":"category", "categoryclass":"category", "notes":"notes", "remarks":"notes", "comments":"notes", "title":"title", "bookingtitle":"title"]
        return aliases[name]
    }
    static func title(_ key: String) -> String {
        ["date":"Date", "start":"Start time", "end":"End time", "registration":"Aircraft registration", "model":"Make and model", "route":"Route", "departure":"Departure airport", "arrival":"Arrival airport",
         "total":"Total time", "pic":"PIC time", "sic":"SIC time", "solo":"Solo", "day":"Day landings", "nightLandings":"Night landings", "landings":"Landings",
         "night":"Night time", "imc":"Actual instrument", "dual":"Dual received", "instructor":"Instructor time", "xc":"Cross-country", "sim":"Simulated instrument",
         "approaches":"Approaches", "approachCount":"Approach count", "holds":"Holds", "category":"Category / class", "notes":"Comments", "title":"Booking title"][key] ?? key
    }
    static func warningFields(_ warning: String) -> [String] {
        let lower = warning.lowercased()
        // Global capture/footer notes stay collapsed, rather than being repeated at every field.
        if lower.contains("page total") || lower.contains("full-page") || lower.contains("full page") || lower.contains("supplied year") || lower.contains("default_year") || lower.contains("source record") || lower.contains("simulator time is also") || lower.hasPrefix("read using") || lower.hasPrefix("other scanned columns") { return [] }
        if lower.contains("duplicate") || lower.contains("matching flight") || lower.contains("matching booking") { return ["date"] }
        if lower.contains("landing") { return ["landings"] }
        if lower.hasPrefix("check "), let colon = warning.firstIndex(of: ":"),
           let key = key(String(warning[warning.index(warning.startIndex, offsetBy: 6)..<colon])) { return [key] }
        let phrases: [(String, String)] = [("registration","registration"),("aircraft","registration"),("make and model","model"),("make_model","model"),("category","category"),("start time","start"),("end time","end"),("date","date"),("total time","total"),("pic","pic"),("sic","sic"),("cross-country","xc"),("cross country","xc"),("dual","dual"),("simulated","sim"),("instrument","imc"),("night time","night"),("approach count","approachCount"),("approach","approaches"),("hold","holds"),("remarks","notes"),("comments","notes"),("notes","notes"),("route","route")]
        return Array(Set(phrases.filter { lower.contains($0.0) }.map(\.1))).sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
    }
    static func unique(_ issues: [ScanFieldIssue]) -> [ScanFieldIssue] {
        // Day/night flags belong to the one shared landing card and confirmation snapshot.
        var grouped = issues
        if issues.contains(where: { ["day", "nightLandings"].contains($0.field) }) {
            let landingIssue = issues.first { $0.field == "landings" }
                ?? ScanFieldIssue(field: "landings", message: "Check day and night landings against the source.")
            grouped.removeAll { ["day", "nightLandings", "landings"].contains($0.field) }
            grouped.append(landingIssue)
        }
        var seen = Set<String>()
        return grouped.filter { seen.insert($0.field).inserted }.sorted { (order.firstIndex(of: $0.field) ?? 99) < (order.firstIndex(of: $1.field) ?? 99) }
    }
}
nonisolated enum ScanReviewLogic {
    static func valid(_ field: String, values: [String: String], requiredTotal: Bool = false) -> Bool {
        let raw = values[field, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if field == "date" { return FlightDates.parse(raw) != nil }
        if ["start", "end", "category", "model"].contains(field) { return true }
        if field == "registration" { return !AircraftNames.registration(raw).isEmpty }
        if ["departure", "arrival"].contains(field) { return raw.isEmpty || (!CSVRoute.containsCoordinates(raw) && AirportRoute.codes(raw).count == 1) }
        if field == "route" { return raw.isEmpty || raw == "optional" || !AirportRoute.codes(raw).isEmpty }
        if ["day", "nightLandings", "approachCount", "holds"].contains(field) { return count(raw) != nil }
        if field == "landings" { return count(values["day", default: ""]) != nil && count(values["nightLandings", default: ""]) != nil }
        if ["total", "pic", "sic", "night", "imc", "sim", "dual", "instructor", "xc"].contains(field) {
            guard let value = Double(raw.isEmpty && (field != "total" || !requiredTotal) ? "0" : raw.replacingOccurrences(of: ",", with: ".")), value.isFinite, value >= 0 else { return false }
            if field == "total" { return !requiredTotal || value > 0 }
            let total = Double(values["total", default: ""].replacingOccurrences(of: ",", with: ".")) ?? 0
            return total == 0 || value <= total + 0.001
        }
        return true
    }
    static func count(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(text.isEmpty ? "0" : text), (0..<100_000).contains(value) else { return nil }
        return value
    }
    static func confirmationValue(_ field: String, values: [String: String]) -> String {
        if field == "landings" { return values["day", default: ""] + "|" + values["nightLandings", default: ""] }
        return values[field, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func activeConfirmations(_ confirmed: Set<String>, snapshots: [String: String], values: [String: String]) -> Set<String> {
        Set(confirmed.filter { snapshots[$0] == confirmationValue($0, values: values) })
    }
    static func pending(_ issues: [ScanFieldIssue], values: [String: String], touched: Set<String>, confirmed: Set<String>, expectedLandings: Int?, requiredTotal: Bool = false) -> [ScanFieldIssue] {
        issues.filter { issue in
            guard valid(issue.field, values: values, requiredTotal: requiredTotal) else { return true }
            if confirmed.contains(issue.field) { return false }
            // Editing alone does not confirm an uncertain reading. Keep its Confirm action visible.
            return true
        }
    }
}
struct ScanReviewPresentation {
    var messages: [String: String] = [:]
    var canConfirm: Set<String> = []
    var confirm: ((String) -> Void)?
    var edited: ((String) -> Void)?
    var resolved: Set<String> = []
    var next: (() -> Void)?
    func isTracked(_ field: String?) -> Bool {
        guard let field else { return false }
        return messages[field] != nil || resolved.contains(field)
    }
    func needsReview(_ field: String?) -> Bool {
        guard let field else { return false }
        let group = ["day", "nightLandings"].contains(field) ? "landings" : field
        return messages[group] != nil
    }
}
enum ScanReviewColors {
    static func warning(_ dark: Bool) -> Color { Color(hex: dark ? 0xFFC044 : 0xA55F00) }
    static func success(_ dark: Bool) -> Color { Color(hex: dark ? 0x79E987 : 0x237A35) }
}
private struct ScanReviewPresentationKey: EnvironmentKey { static let defaultValue = ScanReviewPresentation() }
extension EnvironmentValues {
    var scanReviewPresentation: ScanReviewPresentation {
        get { self[ScanReviewPresentationKey.self] }
        set { self[ScanReviewPresentationKey.self] = newValue }
    }
}
struct ScanFieldMarker: ViewModifier {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.scanReviewPresentation) var review
    let field: String?
    var label: String? = nil
    func body(content: Content) -> some View {
        if let field, review.isTracked(field) {
            let pending = review.messages[field] != nil
            let stateColor = pending ? ScanReviewColors.warning(theme.dark) : ScanReviewColors.success(theme.dark)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let label { Text(label).font(.subheadline.weight(.semibold)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true) }
                    Text(pending ? "Review" : "Reviewed").font(.caption.bold()).foregroundStyle(stateColor)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(stateColor.opacity(0.08)).clipShape(Capsule())
                        .overlay(Capsule().stroke(stateColor, lineWidth: 1))
                    Spacer(minLength: 0)
                }
                content
                if let message = review.messages[field] {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            warning(message, color: stateColor).fixedSize(horizontal: true, vertical: true)
                            Spacer(minLength: 0)
                            confirmation
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            warning(message, color: stateColor).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            confirmation.frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                } else {
                    Label("Looks good", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(stateColor)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface).clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(theme.line.opacity(0.75)))
                .id("scan-" + field)
        } else if let field { content.id("scan-" + field) }
        else { content }
    }
    private func warning(_ message: String, color: Color) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(color)
    }
    @ViewBuilder private var confirmation: some View {
        if let field, review.canConfirm.contains(field) {
            Button("Confirm") { review.confirm?(field) }.font(.caption.bold()).foregroundStyle(theme.cyan)
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Confirm " + ScanReviewFields.title(field))
        }
    }
}
extension View {
    func scanField(_ field: String?, label: String? = nil) -> some View { modifier(ScanFieldMarker(field: field, label: label)) }
}

struct ScanReviewContext {
    var title: String
    var sourceText: String
    var image: UIImage?
    var warnings: [String]
    var unresolvedFields: Set<String> = []
    var issues: [ScanFieldIssue] = []
    var rowImage: UIImage? = nil
    var fieldIssues: [ScanFieldIssue] {
        let missing = unresolvedFields.map { ScanFieldIssue(field: $0, message: "Choose " + ScanReviewFields.title($0).lowercased() + ".") }
        let fallback = warnings.flatMap { warning in
            ScanReviewFields.warningFields(warning).map { ScanFieldIssue(field: $0, message: "Check " + ScanReviewFields.title($0).lowercased() + " against the source.") }
        }
        return ScanReviewFields.unique(issues + missing + fallback)
    }
    var otherNotes: [String] { Array(Set(warnings.filter { ScanReviewFields.warningFields($0).isEmpty })).sorted() }
}

struct ScanEntryEvidence: View {
    @EnvironmentObject var theme: AppTheme
    @State private var expanded = false
    let context: ScanReviewContext
    var pendingIssues: [ScanFieldIssue] = []
    var reviewNext: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review this entry before saving").font(.headline)
            if let image = context.rowImage ?? context.image {
                Button { expanded = true } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).accessibilityLabel("Enlarge source schedule or logbook photo")
                Button("Enlarge source photo") { expanded = true }.font(.caption).foregroundStyle(theme.cyan)
            }
            if !pendingIssues.isEmpty {
                Button { reviewNext?() } label: {
                    HStack {
                        Text("\(pendingIssues.count) \(pendingIssues.count == 1 ? "field needs" : "fields need") review").foregroundStyle(theme.text)
                        Spacer(); Text("Next").foregroundStyle(theme.cyan)
                    }.font(.subheadline.bold()).padding(.vertical, 10)
                }.buttonStyle(.plain)
            } else if !context.fieldIssues.isEmpty {
                Label("Review items checked", systemImage: "checkmark.circle").font(.caption).foregroundStyle(theme.cyan)
            }
            if !context.otherNotes.isEmpty {
                DisclosureGroup("Other scan notes") {
                    ForEach(Array(context.otherNotes.enumerated()), id: \.offset) { _, note in
                        Text(note).font(.caption).foregroundStyle(theme.muted).padding(.top, 6)
                    }
                }.font(.subheadline)
            }
            DisclosureGroup("Text from this entry") {
                Text(context.sourceText).font(.caption).textSelection(.enabled).padding(.top, 8)
            }
        }.logbookCard()
            .sheet(isPresented: $expanded) {
                if let image = context.image {
                    SheetFrame(title: "Source photo", subtitle: "Pinch to zoom and drag to check the printed details.") {
                        ScanPhotoZoom(image: image).frame(height: 480).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
    }
}

struct ScanPhotoZoom: UIViewRepresentable {
    let image: UIImage
    final class PhotoScrollView: UIScrollView {
        let photo = UIImageView()
        private var fittedSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0, bounds.height > 0, let image = photo.image, image.size.width > 0, image.size.height > 0 else { return }
            if fittedSize != bounds.size {
                fittedSize = bounds.size
                setZoomScale(1, animated: false)
                photo.frame = CGRect(origin: .zero, size: image.size)
                contentSize = image.size
                let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
                minimumZoomScale = fit; maximumZoomScale = max(fit * 8, 1)
                setZoomScale(fit, animated: false)
            }
            photo.center = CGPoint(x: max(contentSize.width, bounds.width) / 2, y: max(contentSize.height, bounds.height) / 2)
        }
    }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? PhotoScrollView)?.photo }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> PhotoScrollView {
        let view = PhotoScrollView()
        view.photo.image = image; view.photo.contentMode = .scaleAspectFit
        view.addSubview(view.photo); view.delegate = context.coordinator
        view.bouncesZoom = true
        return view
    }
    func updateUIView(_ uiView: PhotoScrollView, context: Context) {}
    static func dismantleUIView(_ uiView: PhotoScrollView, coordinator: Coordinator) { uiView.delegate = nil }
}

// Foundation-only field parsing is separated from Vision and the review UI.
enum ScanParsing {
    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
    nonisolated static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    static func field(_ header: String, schedule: Bool) -> ScanField {
        if let exact = ScanField.allCases.first(where: { $0.title == header }) { return exact }
        let h = normalized(header)
        if h.isEmpty { return .ignore }
        // Short schedule headings can merge letters in a small screenshot.
        if schedule {
            if h == "stot" { return .start }
            if h == "ent" { return .end }
            if h == "plot" { return .pilot }
            if ["cfl", "cf1", "cr"].contains(h) { return .cfi }
        }
        if h.contains("schedule") || h == "entrynumber" || h == "reference" || h == "bookingid" { return .reference }
        if h.contains("resource") { return .resource }
        if h == "cfi" || h.contains("instructorname") || (schedule && h == "instructor") { return .cfi }
        if h == "pilot" || h.contains("pilotname") || h == "student" || h == "studentname" { return .pilot }
        if !schedule {
            if h.contains("singleengineland") || h == "asel" || h == "sel" { return .aselHours }
            if h.contains("singleenginesea") || h == "ases" || h == "ses" { return .asesHours }
            if h.contains("multiengineland") || h == "amel" || h == "mel" { return .amelHours }
            if h.contains("multienginesea") || h == "ames" || h == "mes" { return .amesHours }
            if h == "rotorcraft" || h == "helicopter" || h == "rotorcrafttime" { return .rotorHours }
            if h == "glider" || h == "glidertime" { return .gliderHours }
        }
        if h.contains("registration") || h.contains("tailnumber") || h == "nnumber" || h == "ident" || h == "aircraftident" || h == "aircraftidentification" { return .registration }
        if h.contains("model") || h.contains("aircrafttype") || h.contains("typeofaircraft") || h == "make" || h == "type" || h == "maketype" { return .model }
        if h == "aircraft" || h == "airplane" { return schedule ? .resource : .model }
        if h.contains("category") || h == "class" { return .category }
        if h.contains("start") || h == "begin" || h == "out" || h == "departuretime" { return .start }
        if h == "end" || h.contains("endtime") || h.contains("enddate") || h == "finish" || h == "in" || h == "arrivaltime" { return .end }
        if h.contains("date") || h == "dayofmonth" { return .date }
        if h.contains("route") { return .route }
        if h == "from" || h.hasPrefix("departureairport") || h == "departure" || h == "origin" || h == "placeofdeparture" { return .departure }
        if h == "to" || h.hasPrefix("arrivalairport") || h == "arrival" || h == "destination" || h == "placeofarrival" { return .arrival }
        if h.contains("landing") || h.contains("ldg") || h == "day" {
            if h.contains("night") { return .nightLandings }
            if h.contains("day") { return .dayLandings }
            return .landings
        }
        if h.contains("crosscountry") || h == "xc" || h == "xctotal" || h == "xccountry" { return .crossCountry }
        if h.contains("pic") || h.contains("pilotincommand") { return .pic }
        if h.contains("simulated") || h == "hood" || h == "siminstr" || h == "siminst" || h == "siminstrument" { return .simulated }
        if h.contains("actual") || h.contains("imc") || h == "actinstr" || h == "actinst" { return .imc }
        if h.contains("dual") || h.contains("trainingreceived") || h == "instructionreceived" { return .dual }
        if h.contains("instructor") || h.contains("instructiongiven") || h.contains("dualgiven") { return .instructor }
        if h.contains("solo") { return .solo }
        if h.contains("approach") || h == "appr" || h == "app" || h == "nrinstapp" || h == "nrapp" {
            return h.contains("count") || h.contains("number") || h == "appr" || h == "app" || h.hasPrefix("nrinst") || h.hasPrefix("nrapp") ? .approachCount : .approaches
        }
        if h.contains("hold") { return .holds }
        if h.contains("night") { return .night }
        if h.contains("total") || h.contains("duration") || h == "time" || h == "hours" || h.contains("flighttime") { return .total }
        if h.contains("remark") || h.contains("comment") || h.contains("note") || h == "description" { return .notes }
        return .ignore
    }
    static func schema(_ table: ScanTable, schedule: Bool) -> ScanSchema {
        let width = table.rows.map(\.count).max() ?? 0
        var bestIndex = -1
        var bestScore = 0
        for (index, row) in table.rows.prefix(12).enumerated() {
            let tags = row.map { field($0, schedule: schedule) }
            let score = tags.filter { $0 != .ignore }.count
            if score > bestScore, !row.contains(where: { date($0, year: 2000) != nil }) {
                bestIndex = index; bestScore = score
            }
        }
        guard bestIndex >= 0 else {
            return ScanSchema(headers: (0..<width).map { "Column \($0 + 1)" }, fields: Array(repeating: .ignore, count: width), firstDataRow: 0)
        }
        var lastHeader = bestIndex
        // A second line of subheaders (such as day/night under Landings) belongs to the header.
        while lastHeader + 1 < min(table.rows.count, bestIndex + 3) {
            let row = table.rows[lastHeader + 1]
            let recognized = row.filter { field($0, schedule: schedule) != .ignore }.count
            if recognized >= 2 && !row.contains(where: { date($0, year: 2000) != nil }) { lastHeader += 1 }
            else { break }
        }
        var headers = [String]()
        var fields = [ScanField]()
        for column in 0..<width {
            let parts = (max(0, bestIndex - 2)...lastHeader).compactMap { index -> String? in
                guard column < table.rows[index].count else { return nil }
                let value = table.rows[index][column].trimmingCharacters(in: .whitespacesAndNewlines)
                // Page titles and account information must not become column labels.
                return field(value, schedule: schedule) != .ignore ? value : nil
            }
            let header = parts.joined(separator: " ")
            headers.append(header.isEmpty ? "Column \(column + 1)" : header)
            fields.append(field(header, schedule: schedule))
        }
        return ScanSchema(headers: headers, fields: fields, firstDataRow: lastHeader + 1)
    }
    static func date(_ text: String, year: Int) -> Date? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = matches(#"\b(?:\d{4}[-/]\d{1,2}[-/]\d{1,2}|\d{1,2}[/\-]\d{1,2}(?:[/\-]\d{2,4})?)\b"#, in: raw).first
        if let numeric {
            let pieces = numeric.split(whereSeparator: { $0 == "/" || $0 == "-" }).compactMap { Int($0) }
            guard pieces.count >= 2 else { return nil }
            let iso = numeric.prefix(4).allSatisfy(\.isNumber) && numeric.count > 4 && (numeric[numeric.index(numeric.startIndex, offsetBy: 4)] == "-" || numeric[numeric.index(numeric.startIndex, offsetBy: 4)] == "/")
            let month = iso ? pieces[1] : pieces[0]
            let day = iso ? pieces[2] : pieces[1]
            var resolvedYear = iso ? pieces[0] : pieces.count == 3 ? pieces[2] : year
            if resolvedYear < 100 { resolvedYear += (year / 100) * 100 }
            guard (1900...2199).contains(resolvedYear), (1...12).contains(month), (1...31).contains(day) else { return nil }
            let calendar = Calendar(identifier: .gregorian)
            guard let result = calendar.date(from: DateComponents(year: resolvedYear, month: month, day: day)),
                  calendar.component(.month, from: result) == month, calendar.component(.day, from: result) == day else { return nil }
            return result
        }
        let months = #"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"#
        let patterns = ["\\b" + months + #"\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?\b"#,
                        #"\b\d{1,2}(?:st|nd|rd|th)?\s+(?:of\s+)?"# + months + #"\.?(?:,?\s+\d{4})?\b"#]
        for pattern in patterns {
            guard var match = matches(pattern, in: raw).first else { continue }
            match = match.replacingOccurrences(of: #"(?<=\d)(st|nd|rd|th)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"\s+of\s+"#, with: " ", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "")
            if matches(#"\b\d{4}\b"#, in: match).isEmpty { match += " \(year)" }
            for format in ["MMM d yyyy", "MMMM d yyyy", "d MMM yyyy", "d MMMM yyyy"] {
                let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.isLenient = false; f.dateFormat = format
                if let result = f.date(from: match) { return result }
            }
        }
        return nil
    }
    static func clock(_ text: String) -> (hour: Int, minute: Int, explicitPeriod: Bool)? {
        let cleaned = text.uppercased().replacingOccurrences(of: "A.M.", with: "AM").replacingOccurrences(of: "P.M.", with: "PM")
        let patterns = [#"\b(\d{1,2}):(\d{2})(?::\d{2})?\s*(AM|PM)?\b"#,
                        #"\b(\d{1,2})()\s*(AM|PM)\b"#,
                        #"(?:\bAT\s+|@\s*)(\d{1,2})()\s*(AM|PM)?\b"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
                  let hr = Range(match.range(at: 1), in: cleaned), var hour = Int(cleaned[hr]) else { continue }
            let minute = Range(match.range(at: 2), in: cleaned).flatMap { Int(cleaned[$0]) } ?? 0
            let period = Range(match.range(at: 3), in: cleaned).map { String(cleaned[$0]) }
            guard minute < 60 else { return nil }
            let unambiguous24Hour = hour == 0 || hour > 12
            if let period {
                guard (1...12).contains(hour) else { return nil }
                hour %= 12
                if period == "PM" { hour += 12 }
            } else if hour > 23 { return nil }
            return (hour, minute, period != nil || unambiguous24Hour)
        }
        return nil
    }
    static func dateTime(_ text: String, fallback: Date?, year: Int) -> Date? {
        guard let day = date(text, year: year) ?? fallback, let time = clock(text) else { return nil }
        return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
    }
    static func hoursValue(_ text: String) -> Double? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "hours", with: "").replacingOccurrences(of: "hrs", with: "").replacingOccurrences(of: "hr", with: "").replacingOccurrences(of: " h", with: "").trimmingCharacters(in: .whitespaces)
        if raw.range(of: #"^\d{1,3}:\d{2}$"#, options: .regularExpression) != nil {
            let parts = raw.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2, parts[1] < 60 else { return nil }
            return parts[0] + parts[1] / 60
        }
        // Do not silently turn a handwritten '05' with a missing decimal into five hours.
        if raw.range(of: #"^0\d+$"#, options: .regularExpression) != nil { return nil }
        // Handwritten decimals are sometimes recognized as two separated digits.
        if raw.range(of: #"^\d{1,2}\s+\d$"#, options: .regularExpression) != nil {
            return Double(raw.split(whereSeparator: \.isWhitespace).joined(separator: "."))
        }
        guard raw.range(of: #"^(?:\d{1,3}(?:\.\d{1,2})?|\.\d{1,2})$"#, options: .regularExpression) != nil,
              let value = Double(raw), value.isFinite else { return nil }
        return value
    }
    static func registration(_ text: String, bareAllowed: Bool = true) -> String {
        let raw = text.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = matches(#"\bN[1-9][0-9]{0,4}[A-HJ-NP-Z]{0,2}\b"#, in: raw).first, match.count <= 6 { return match }
        let firstToken = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? raw
        let compact = firstToken.filter { $0.isLetter || $0.isNumber }
        guard !firstToken.contains(where: { ".:/".contains($0) }) else { return "" }
        if bareAllowed, compact.range(of: #"^[1-9][0-9]{0,4}[A-HJ-NP-Z]{0,2}$"#, options: .regularExpression) != nil,
           compact.count <= 5 { return "N" + compact }
        return ""
    }
    nonisolated static func isBlank(_ text: String) -> Bool {
        ["", "-", "—", "–", ".", "n/a"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    static func isDitto(_ text: String) -> Bool {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["ditto", "same", "do", "do.", "〃", "\"", "''", "“", "”"].contains(raw)
            || (!raw.isEmpty && raw.allSatisfy { "\"'〃“”".contains($0) || $0.isWhitespace })
    }
    static func parsedDrafts(_ tables: [ScanTable], schedule: Bool, year: Int, overrides: [String: [ScanField]]) -> [ScanFlightDraft] {
        var output = [ScanFlightDraft]()
        for table in tables {
            var schema = schema(table, schedule: schedule)
            if let selected = overrides[table.id], selected.count == schema.fields.count { schema.fields = selected }
            var previousDate: Date?
            var previousRegistration = ""
            var previousModel = ""
            for rowIndex in schema.firstDataRow..<table.rows.count {
                let row = table.rows[rowIndex]
                let fullText = row.joined(separator: " | ")
                let clean = normalized(fullText)
                if row.allSatisfy(isBlank) || ["totals", "subtotal", "carriedforward", "broughtforward", "pagetotal", "amountforward"].contains(where: { clean.hasPrefix($0) }) { continue }
                var values = [ScanField: String]()
                var extras = [String]()
                for (column, value) in row.enumerated() where !isBlank(value) {
                    let tag = column < schema.fields.count ? schema.fields[column] : .ignore
                    if tag == .ignore {
                        if !["download", "edit", "delete", "|"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                            extras.append("\(column < schema.headers.count ? schema.headers[column] : "Column \(column + 1)"): \(value)")
                        }
                    } else if values[tag] != value { values[tag] = [values[tag], value].compactMap { $0 }.joined(separator: " ") }
                }
                let dateText = [values[.date], values[.start]].compactMap { $0 }.joined(separator: " ")
                let resource = values[.resource] ?? values[.registration] ?? ""
                var reg = registration(resource)
                let grounded = normalized(resource).contains("ground")
                let classFields: [(ScanField, String)] = [(.aselHours, "ASEL"), (.asesHours, "ASES"), (.amelHours, "AMEL"), (.amesHours, "AMES"), (.rotorHours, "Rotorcraft"), (.gliderHours, "Glider")]
                let classTimes = classFields.compactMap { field, category -> (String, Double)? in
                    guard let raw = values[field], let value = hoursValue(raw) else { return nil }
                    return (category, value)
                }
                var total = hoursValue(values[.total] ?? "")
                if total == nil, !classTimes.isEmpty { total = classTimes.reduce(0) { $0 + $1.1 } }
                let repeatedRegistration = !schedule && isDitto(resource) && !previousRegistration.isEmpty
                if repeatedRegistration { reg = previousRegistration }
                let explicitDate = date(dateText, year: year)
                let aggregate = row.contains { value in
                    let label = normalized(value)
                    return label == "total" || ["totals", "totalthispage", "pagetotal", "subtotal", "carriedforward", "broughtforward", "amountforward", "amtforward", "totalstodate"].contains { label.hasPrefix($0) }
                }
                if aggregate, explicitDate == nil, reg.isEmpty { continue }
                let rowIdentity = [values[.model], values[.route], values[.departure], values[.arrival]].compactMap { $0 }.contains { !isBlank($0) }
                let hasEvidence = explicitDate != nil || !reg.isEmpty || (schedule && grounded) || (!schedule && total != nil && rowIdentity)
                let inheritedEvidence = !schedule && previousDate != nil && (total != nil || !reg.isEmpty)
                guard hasEvidence || inheritedEvidence,
                      schedule ? (explicitDate != nil || !resource.isEmpty) : (total != nil || !reg.isEmpty || !isBlank(values[.route] ?? "")) else { continue }
                var warnings = [String]()
                if repeatedRegistration { warnings.append("Aircraft registration carried from a ditto mark in the preceding row. Verify it.") }
                if !reg.isEmpty { previousRegistration = reg }
                if values[.total] == nil, !classTimes.isEmpty { warnings.append("Total time was calculated from the aircraft category/class time columns. Verify it against the full logbook page.") }
                for (field, raw) in values where raw.range(of: #"^\d{1,2}\s+\d$"#, options: .regularExpression) != nil {
                    if field.title.contains("hours") { warnings.append("\(field.title): read \(raw) as a decimal. Check the handwritten value.") }
                }
                var day = explicitDate
                if day == nil, !schedule, let previousDate,
                   isBlank(dateText) || isDitto(dateText) {
                    day = previousDate; warnings.append("Date carried from the preceding row. Verify it against the photo.")
                }
                if let day { previousDate = day }
                if day == nil { warnings.append("Date was not readable. Set the correct date before confirming.") }
                if explicitDate != nil, !dateText.contains(String(year)), matches(#"\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}|\d{4}[-/]"#, in: dateText).isEmpty {
                    warnings.append("Year \(year) was supplied for this date. Verify the year.")
                }
                let notes = values[.notes] ?? ""
                if !extras.isEmpty { warnings.append("Other scanned columns: " + extras.joined(separator: "; ")) }
                let routeText = values[.route] ?? [values[.departure], values[.arrival]].compactMap { $0 }.joined(separator: " ")
                let bounds = rowIndex < table.rowBounds.count ? table.rowBounds[rowIndex] : nil
                if schedule {
                    var item = ScheduledFlight()
                    let start = dateTime(dateText, fallback: day, year: year)
                    if let start { item.date = start }
                    else {
                        item.date = day ?? Date()
                        warnings.append("Start time was not readable. Enter the correct time.")
                    }
                    if let endText = values[.end], let start {
                        var end = dateTime(endText, fallback: start, year: year)
                        if let candidate = end, candidate <= start, date(endText, year: year) == nil {
                            end = Calendar.current.date(byAdding: .day, value: 1, to: candidate)
                            warnings.append("End time appears to be on the following day. Verify the dates.")
                        }
                        if let end, end > start { item.endDate = end; item.estimatedTime = end.timeIntervalSince(start) / 3600 }
                        else { warnings.append("End time was not readable or precedes the start. Check the end time.") }
                        if let period = clock(endText), !period.explicitPeriod { warnings.append("End time has no AM/PM marker. Verify it.") }
                    } else { warnings.append("End time was not found. You may add an end time or estimated duration; both can be left unspecified.") }
                    if let period = clock(dateText), !period.explicitPeriod { warnings.append("Start time has no AM/PM marker. Verify it.") }
                    if item.endDate == nil, let total { item.estimatedTime = total }
                    item.registration = grounded ? "" : reg
                    item.resource = resource
                    item.activityType = grounded ? "ground" : "flight"
                    item.title = grounded ? "Ground lesson" : "Flight"
                    item.route = AirportRoute.formatted(routeText)
                    item.pilotName = values[.pilot]; item.instructorName = values[.cfi]
                    item.sourceScheduleID = values[.reference]; item.notes = notes.isEmpty ? nil : notes
                    if !grounded && reg.isEmpty { warnings.append("Aircraft registration was not readable. Check the resource / aircraft field.") }
                    output.append(ScanFlightDraft(schedule: item, sourceText: fullText, sourceBounds: bounds, warnings: warnings))
                } else {
                    var flight = Flight()
                    if let day { flight.date = FlightDates.string(day) }
                    let rawModel = values[.model] ?? ""
                    let carriedModel = isDitto(rawModel) && !previousModel.isEmpty
                    let model = AircraftNames.display(carriedModel ? previousModel : rawModel)
                    if carriedModel { warnings.append("Make/model carried from a ditto mark in the preceding row. Verify it.") }
                    if !model.isEmpty { previousModel = model }
                    flight.aircraft = reg + " · " + model
                    flight.route = AirportRoute.formatted(routeText)
                    flight.notes = notes
                    if !extras.isEmpty { flight.facts.text["photoImportOtherColumns"] = extras.joined(separator: "; ") }
                    flight.duration = total.map { String($0) } ?? "0.0"
                    let times: [(ScanField, WritableKeyPath<Flight, Double>)] = [(.pic, \.pic), (.night, \.night), (.imc, \.imc), (.simulated, \.simulatedInstrument), (.dual, \.dual), (.instructor, \.instructor), (.crossCountry, \.crossCountry)]
                    for (field, path) in times {
                        if let raw = values[field], !isBlank(raw) {
                            if let value = hoursValue(raw) { flight[keyPath: path] = value }
                            else { warnings.append("\(field.title) was not readable: \(raw). Enter it manually.") }
                        }
                    }
                    let counts: [(ScanField, WritableKeyPath<Flight, Int>)] = [(.dayLandings, \.dayLandings), (.nightLandings, \.nightLandings), (.approachCount, \.approachCount), (.holds, \.holds)]
                    for (field, path) in counts {
                        if let raw = values[field], !isBlank(raw) {
                            if let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 { flight[keyPath: path] = value }
                            else { warnings.append("\(field.title) was not readable: \(raw). Enter it manually.") }
                        }
                    }
                    if let raw = values[.landings], !isBlank(raw) {
                        if let total = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), total >= flight.landings, total < 100_000 {
                            flight.facts.counts["importedLandingTotal"] = total
                            flight.facts.counts["unclassifiedLandings"] = total - flight.landings
                        } else { flight.facts.text["photoImportLandingReading"] = raw }
                        warnings.append("Landing count has no day/night label. Assign it to the correct landing field.")
                    }
                    if let raw = values[.approaches] {
                        if let count = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), count >= 0 { flight.approachCount = count }
                        else { flight.approaches = raw }
                    }
                    if let raw = values[.solo], let solo = hoursValue(raw) { flight.progress["solo"] = solo }
                    let categoriesWithTime = classTimes.filter { $0.1 > 0 }.map { $0.0 }
                    if categoriesWithTime.count == 1 { flight.category = categoriesWithTime[0] }
                    if let category = values[.category], let matched = AircraftLookup.categories.first(where: { normalized($0) == normalized(category) }) { flight.category = matched }
                    if let instructor = values[.cfi] { flight.facts.text["importedInstructorName"] = instructor }
                    if total == nil { warnings.append("Total hours were not readable. Enter the flight's total time.") }
                    if reg.isEmpty { warnings.append("Registration was not readable. Enter the correct aircraft.") }
                    if flight.route.isEmpty { warnings.append("Route was not readable. You can leave it blank or enter airports.") }
                    if !AircraftNames.hasMake(model) { warnings.append("Full make/model was not found. Aircraft lookup can fill it after the registration is confirmed.") }
                    var draft = ScanFlightDraft(flight: flight, sourceText: fullText, sourceBounds: bounds, warnings: warnings)
                    draft.repeatsRegistration = isDitto(resource); draft.repeatsModel = isDitto(rawModel)
                    if draft.repeatsRegistration && reg.isEmpty { draft.warnings.append("Aircraft ditto mark refers to an unreadable preceding aircraft. Correct that entry first.") }
                    output.append(draft)
                }
            }
        }
        return output
    }
}

// Read lists, notes and labelled booking cards without assuming a table layout.
enum ScanTextEntries {
    static func captured(_ pattern: String, _ text: String, group: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              group < result.numberOfRanges, let range = Range(result.range(at: group), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func timeStrings(_ text: String) -> [String] {
        let raw = text.replacingOccurrences(of: "a.m.", with: "AM", options: .caseInsensitive)
            .replacingOccurrences(of: "p.m.", with: "PM", options: .caseInsensitive)
        let pattern = #"\b\d{1,2}:\d{2}(?::\d{2})?\s*(?:AM|PM)?\b|\b\d{1,2}\s*(?:AM|PM)\b|(?:\bat\s+|@\s*)\d{1,2}(?![\d/:])\s*(?:AM|PM)?\b"#
        var found = ScanParsing.matches(pattern, in: raw)
        // '2–4pm' carries the period to the first time only when written as a range.
        if found.count < 2, let range = captured(#"\b(\d{1,2}(?::\d{2})?\s*(?:AM|PM)?\s*(?:-|–|—|to)\s*\d{1,2}(?::\d{2})?\s*(?:AM|PM))\b"#, raw) {
            guard let separator = try? NSRegularExpression(pattern: #"\s*(?:-|–|—|to)\s*"#, options: [.caseInsensitive]) else { return found }
            let parts = range.components(separatedBy: separator)
            if parts.count == 2 {
                let period = ScanParsing.matches(#"AM|PM"#, in: parts[1]).last ?? ""
                found = [ScanParsing.matches(#"AM|PM"#, in: parts[0]).isEmpty ? parts[0] + " " + period : parts[0], parts[1]]
            }
        }
        return found
    }
    static func grounded(_ text: String) -> Bool {
        text.range(of: #"\bground(?:\s+(?:lesson|training|school|instruction))?\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func blocks(_ text: String, schedule: Bool, year: Int) -> [(text: String, day: Date?)] {
        var output = [(text: String, day: Date?)]()
        var pending = [String]()
        var sharedDay: Date?
        var pendingDay: Date?
        func finish() {
            let raw = pending.joined(separator: "\n")
            let hasAircraft = !ScanParsing.registration(raw, bareAllowed: false).isEmpty
            let hasDate = ScanParsing.date(raw, year: year) != nil
            let hasTime = !timeStrings(raw).isEmpty
            if (schedule && (hasAircraft || grounded(raw) || (hasDate && hasTime))) || (!schedule && (hasAircraft || hasDate)) {
                output.append((raw, pendingDay))
            }
            pending = []; pendingDay = nil
        }
        let source = text.replacingOccurrences(of: ";", with: "\n")
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let compact = ScanParsing.normalized(line)
            if ["totals", "subtotal", "totalthispage", "totalstodate", "amtforward", "amountforward", "carriedforward", "broughtforward"].contains(where: { compact.hasPrefix($0) }) { finish(); continue }
            let date = ScanParsing.date(line, year: year)
            let reg = ScanParsing.registration(line, bareAllowed: false)
            let isGround = grounded(line)
            let hasTime = !timeStrings(line).isEmpty
            let pendingText = pending.joined(separator: " ")
            let priorReg = ScanParsing.registration(pendingText, bareAllowed: false)
            let priorTime = !timeStrings(pendingText).isEmpty
            let priorDate = ScanParsing.date(pendingText, year: year)
            let hasPriorEntry = !priorReg.isEmpty || grounded(pendingText) || (priorDate != nil && priorTime)
            let newDate = date != nil && (priorDate != nil || (hasPriorEntry && priorTime))
            let newAircraft = (!reg.isEmpty || isGround) && hasPriorEntry && (priorTime || !schedule)
            let newTime = schedule && hasTime && priorTime && (!reg.isEmpty || isGround)
            if !pending.isEmpty && (newDate || newAircraft || newTime) { finish() }
            if let date { sharedDay = date }
            if pending.isEmpty { pendingDay = date ?? sharedDay }
            // A standalone date is a heading shared by the bookings that follow.
            if date != nil && reg.isEmpty && !isGround && !hasTime && schedule {
                if pending.isEmpty { pendingDay = date }
                pending.append(line); continue
            }
            if pending.isEmpty && date == nil && reg.isEmpty && !isGround && !hasTime { continue }
            pending.append(line)
        }
        finish()
        return output
    }
    static func labelledValues(_ text: String, schedule: Bool) -> [ScanField: String] {
        var values = [ScanField: String]()
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = String(line[..<colon]); let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let field = ScanParsing.field(label, schedule: schedule)
            if field != .ignore && !value.isEmpty { values[field] = value }
        }
        // Inline time/count labels are accepted as well as one label per line.
        let labels: [(ScanField, String)] = [(.total, "(?:total(?:\\s+time)?|duration)"), (.pic, "PIC"), (.night, "night(?:\\s+time)?"),
            (.imc, "(?:IMC|actual(?:\\s+instrument)?)"), (.simulated, "(?:hood|simulated(?:\\s+instrument)?)"), (.dual, "dual(?:\\s+received)?"),
            (.instructor, "instructor(?:\\s+time)?"), (.crossCountry, "(?:XC|cross[ -]?country)"), (.dayLandings, "day\\s+landings"),
            (.nightLandings, "night\\s+landings"), (.landings, "landings"), (.approachCount, "approach(?:es|\\s+count)"), (.holds, "holds?")]
        for (field, label) in labels where values[field] == nil {
            if let value = captured("\\b" + label + #"\s*[:=]?\s*(\d+(?:[.,:]\d+)?)\b"#, text) { values[field] = value }
        }
        for (field, label) in [(ScanField.pilot, "(?:pilot|student)"), (.cfi, "(?:CFI|instructor)"), (.route, "route"), (.model, "(?:model|make/model|aircraft type)")] where values[field] == nil {
            values[field] = captured("\\b" + label + #"\s*[:=]\s*([^\n;]+)"#, text)
        }
        return values
    }
    static func delimitedTable(_ text: String, schedule: Bool) -> ScanTable? {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let header = lines.first else { return nil }
        let delimiter: Character = header.contains("\t") ? "\t" : header.contains("|") ? "|" : ","
        func cells(_ line: String) -> [String] {
            var result = [String](); var current = ""; var quoted = false
            for c in line {
                if c == "\"", delimiter == "," { quoted.toggle() }
                else if c == delimiter && !quoted { result.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
                else { current.append(c) }
            }
            result.append(current.trimmingCharacters(in: .whitespaces)); return result
        }
        let headers = cells(header)
        guard headers.count >= 3, headers.filter({ ScanParsing.field($0, schedule: schedule) != .ignore }).count >= 2 else { return nil }
        return ScanTable(rows: lines.map(cells))
    }
    static func drafts(_ text: String, schedule: Bool, year: Int) -> [ScanFlightDraft] {
        if let table = delimitedTable(text, schedule: schedule) {
            return ScanParsing.parsedDrafts([table], schedule: schedule, year: year, overrides: [:])
        }
        var result = [ScanFlightDraft]()
        for block in blocks(text, schedule: schedule, year: year) {
            let raw = block.text
            let labelled = labelledValues(raw, schedule: schedule)
            let explicit = ScanParsing.date(raw, year: year)
            let day = explicit ?? block.day
            let reg = ScanParsing.registration(labelled[.registration] ?? labelled[.resource] ?? raw, bareAllowed: labelled[.registration] != nil || labelled[.resource] != nil)
            var warnings = [String]()
            if explicit == nil { warnings.append(day == nil ? "Date was not readable. Set the correct date." : "Date taken from the preceding heading. Check it.") }
            else if ScanParsing.matches(#"\b\d{4}\b|\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}"#, in: raw).isEmpty { warnings.append("Year \(year) was supplied. Check the year.") }
            if schedule {
                let ground = grounded(raw)
                let clocks = timeStrings(raw)
                var item = ScheduledFlight()
                item.date = ScanParsing.dateTime(labelled[.start] ?? clocks.first ?? "", fallback: day, year: year) ?? day ?? Date()
                if clocks.isEmpty && labelled[.start] == nil { warnings.append("Start time was not readable. Set the correct time.") }
                let startText = labelled[.start] ?? clocks.first ?? ""
                if let clock = ScanParsing.clock(startText), !clock.explicitPeriod { warnings.append("Start time does not specify AM or PM. The displayed time is provisional; choose the correct period.") }
                if let endText = labelled[.end] ?? (clocks.count > 1 ? clocks[1] : nil), var end = ScanParsing.dateTime(endText, fallback: item.date, year: year) {
                    if end <= item.date, ScanParsing.date(endText, year: year) == nil {
                        end = Calendar.current.date(byAdding: .day, value: 1, to: end) ?? end
                        warnings.append("End time was placed on the next day. Check the dates.")
                    }
                    if end > item.date { item.endDate = end; item.estimatedTime = end.timeIntervalSince(item.date) / 3600 }
                    if ScanParsing.clock(endText)?.explicitPeriod == false { warnings.append("End time has no AM/PM marker. Check it.") }
                } else {
                    item.estimatedTime = ScanParsing.hoursValue(labelled[.total] ?? "") ?? 0
                    warnings.append("End time and duration can be left unspecified or added before saving.")
                }
                item.registration = ground ? "" : reg; item.activityType = ground ? "ground" : "flight"
                item.resource = ground ? "GROUND" : reg
                item.title = ground ? "Ground lesson" : "Flight"
                item.route = AirportRoute.formatted(labelled[.route] ?? "")
                item.pilotName = labelled[.pilot]; item.instructorName = labelled[.cfi]
                item.sourceScheduleID = labelled[.reference]; item.notes = raw
                if !ground && reg.isEmpty { warnings.append("Aircraft registration was not readable. Enter it.") }
                result.append(ScanFlightDraft(schedule: item, sourceText: raw, sourceBounds: nil, warnings: warnings))
            } else {
                var fields = labelled
                fields[.date] = day.map { FlightDates.string($0) } ?? ""
                fields[.registration] = reg
                fields[.notes] = raw
                if fields[.route] == nil {
                    let codes = ScanParsing.matches(#"\b[A-Z][A-Z0-9]{3}\b"#, in: raw).filter { $0.uppercased().hasPrefix("K") }
                    if !codes.isEmpty { fields[.route] = codes.joined(separator: " ") }
                }
                let order = ScanField.allCases.filter { fields[$0] != nil }
                let table = ScanTable(rows: [order.map(\.title), order.map { fields[$0] ?? "" }])
                let extracted = ScanParsing.parsedDrafts([table], schedule: false, year: year, overrides: [:])
                for var draft in extracted { draft.sourceText = raw; draft.warnings += warnings; result.append(draft) }
            }
        }
        return result
    }
}

// A small helper keeps range splitting independent of locale and whitespace.
private extension String {
    func components(separatedBy regex: NSRegularExpression) -> [String] {
        var output = [String](); var cursor = startIndex
        for match in regex.matches(in: self, range: NSRange(startIndex..., in: self)) {
            guard let range = Range(match.range, in: self) else { continue }
            output.append(String(self[cursor..<range.lowerBound])); cursor = range.upperBound
        }
        output.append(String(self[cursor...])); return output
    }
}

// Reconstruct rows from coordinates if the OS cannot return a structured table.
enum ScanLayout {
    static func lines(_ words: [ScanBox]) -> [[ScanBox]] {
        var rows = [[ScanBox]]()
        for word in words.sorted(by: { $0.midY < $1.midY }) {
            if let index = rows.indices.last, let first = rows[index].first,
               abs(word.midY - first.midY) <= max(0.0025, min(word.height, first.height) * 0.6) { rows[index].append(word) }
            else { rows.append([word]) }
        }
        return rows.map { $0.sorted { $0.x < $1.x } }
    }
    static func fallbackTable(_ words: [ScanBox], schedule: Bool) -> ScanTable? {
        let lineGroups = lines(words)
        var header = [ScanBox]()
        var columns = [ScanField]()
        var best = 0
        for sourceLine in lineGroups {
            let line = sourceLine.filter { $0.text != "|" }
            let score = line.filter { ScanParsing.field($0.text, schedule: schedule) != .ignore }.count
            if score > best, !line.contains(where: { ScanParsing.date($0.text, year: 2000) != nil }) {
                best = score; header = line; columns = line.map { ScanParsing.field($0.text, schedule: schedule) }
            }
        }
        let allDates = words.filter { ScanParsing.date($0.text, year: 2000) != nil }
        guard !allDates.isEmpty else { return nil }
        let leftDateX = allDates.map(\.midX).min() ?? 0
        let dateColumn = header.firstIndex { ScanParsing.field($0.text, schedule: schedule) == .start || ScanParsing.field($0.text, schedule: schedule) == .date }
        var dateCenter = leftDateX
        if let dateColumn { dateCenter = header[dateColumn].midX }
        let dateCandidates = allDates.filter { abs($0.midX - dateCenter) < 0.06 }
        var anchors = [ScanBox]()
        for box in dateCandidates.sorted(by: { $0.y < $1.y }) {
            if let previous = anchors.last, abs(box.midY - previous.midY) < max(box.height, previous.height) * 0.7 { continue }
            anchors.append(box)
        }
        guard !anchors.isEmpty else { return nil }
        if best < 2 && schedule { return nil }
        if best < 2 {
            // Infer column positions from the first entry, but leave unlabelled numbers unassigned.
            let top = anchors[0].y - anchors[0].height * 0.3
            let bottom = anchors.count > 1 ? anchors[1].y - anchors[1].height * 0.3 : top + 0.12
            header = words.filter {
                $0.midY >= top && $0.midY < bottom && $0.text != "|"
                    && ScanParsing.clock($0.text) == nil && !["AM", "PM"].contains($0.text.uppercased())
            }.sorted { $0.x < $1.x }
            var inferred = [ScanBox]()
            for box in header {
                if let last = inferred.last, abs(last.midX - box.midX) < 0.035 { continue }
                inferred.append(box)
            }
            header = inferred
            var inferredDates = 0
            columns = header.map {
                if ScanParsing.date($0.text, year: 2000) != nil {
                    inferredDates += 1
                    return schedule ? (inferredDates == 1 ? .start : .end) : .date
                }
                if ScanParsing.normalized($0.text).contains("ground") { return .resource }
                if !ScanParsing.registration($0.text, bareAllowed: false).isEmpty { return .registration }
                if schedule, $0.text.count >= 3, !$0.text.contains(where: { ".:/".contains($0) }),
                   !ScanParsing.registration($0.text).isEmpty { return .resource }
                return .ignore
            }
        }
        let order = header.indices.sorted { header[$0].midX < header[$1].midX }
        header = order.map { header[$0] }; columns = order.map { columns[$0] }
        guard !header.isEmpty else { return nil }
        let firstY = anchors[0].y
        // Read neighbouring header lines to retain grouped labels such as Night Landings.
        for index in header.indices {
            let neighbours = words.filter { $0.y < firstY && $0.midY < header[index].midY && header[index].midY - $0.midY < 0.04 && $0.x < header[index].midX && $0.x + $0.width > header[index].midX }
            let parent = neighbours.map(\.text).joined(separator: " ")
            let combined = parent + " " + header[index].text
            if combined.lowercased().contains("landing") { columns[index] = ScanParsing.field(combined, schedule: schedule) }
        }
        var rows = [columns.enumerated().map { index, field in field == .ignore ? "Unassigned column \(index + 1)" : field.title }]
        var bounds: [CGRect?] = [nil]
        let medianHeight = anchors.map(\.height).sorted()[anchors.count / 2]
        for (index, anchor) in anchors.enumerated() {
            let top = max(0, anchor.y - medianHeight * 0.4)
            let bottom = index + 1 < anchors.count ? anchors[index + 1].y - medianHeight * 0.4 : min(1, anchor.y + (index > 0 ? max(medianHeight * 2.5, anchor.y - anchors[index - 1].y) : 0.1))
            let rowWords = words.filter { $0.midY >= top && $0.midY < bottom && $0.text != "|" }
            var cells = Array(repeating: [ScanBox](), count: header.count)
            for word in rowWords {
                let closest = header.indices.min { abs(header[$0].midX - word.midX) < abs(header[$1].midX - word.midX) } ?? 0
                cells[closest].append(word)
            }
            rows.append(cells.map { lines($0).map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n") })
            bounds.append(CGRect(x: 0, y: top, width: 1, height: max(0.01, bottom - top)))
        }
        return ScanTable(rows: rows, rowBounds: bounds)
    }
    static func ruledTable(_ page: ScanPage, schedule: Bool) -> ScanTable? {
        let ys = page.horizontalRules.sorted(), xs = page.verticalRules.sorted()
        guard ys.count >= 4, xs.count >= 4 else { return nil }
        var rows = [[String]](); var bounds = [CGRect?]()
        for r in 0..<(ys.count - 1) where ys[r + 1] - ys[r] > 0.005 {
            var cells = [String]()
            for c in 0..<(xs.count - 1) {
                let words = page.words.filter { $0.midY >= ys[r] && $0.midY < ys[r + 1] && $0.midX >= xs[c] && $0.midX < xs[c + 1] }
                cells.append(lines(words).map { $0.map(\.text).joined(separator: " ") }.joined(separator: " "))
            }
            rows.append(cells)
            bounds.append(CGRect(x: max(0, xs[0] - 0.01), y: max(0, ys[r] - 0.005),
                width: min(1 - xs[0], xs[xs.count - 1] - xs[0] + 0.02), height: ys[r + 1] - ys[r] + 0.01))
        }
        let table = ScanTable(rows: rows, rowBounds: bounds)
        let schema = ScanParsing.schema(table, schedule: schedule)
        guard schema.fields.filter({ $0 != .ignore }).count >= 3 else { return nil }
        return table
    }
    static func score(_ tables: [ScanTable], schedule: Bool, year: Int) -> Int {
        let drafts = ScanParsing.parsedDrafts(tables, schedule: schedule, year: year, overrides: [:])
        return drafts.reduce(0) { total, draft in
            if let flight = draft.flight {
                let hasHours = (Double(flight.duration) ?? 0) > 0
                return total + 2 + (hasHours ? 3 : 0) + (ScanParsing.registration(flight.aircraft, bareAllowed: false).isEmpty ? 0 : 3)
            }
            if let item = draft.schedule { return total + 2 + (item.isGround || !item.registration.isEmpty ? 3 : 0) + (item.endDate != nil ? 1 : 0) }
            return total
        }
    }
    static func chooseTables(_ page: ScanPage, schedule: Bool, year: Int) -> [ScanTable] {
        let native = page.tables.filter {
            let schema = ScanParsing.schema($0, schedule: schedule)
            return schema.fields.filter { $0 != .ignore }.count >= 2
        }
        var candidates = [[ScanTable]]()
        if !native.isEmpty { candidates.append(native) }
        if let grid = ruledTable(page, schedule: schedule) { candidates.append([grid]) }
        if let fallback = fallbackTable(page.words, schedule: schedule) { candidates.append([fallback]) }
        return candidates.max { score($0, schedule: schedule, year: year) < score($1, schedule: schedule, year: year) } ?? page.tables
    }

}

// Printed row/column rules provide structure even when dates and ditto marks are faint.
enum ScanGrid {
    nonisolated static func rules(_ image: CGImage) -> (horizontal: [Double], vertical: [Double]) {
        let scale = min(1, 1200 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return ([], []) }
        var horizontal = [Int](repeating: 0, count: height), vertical = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] < 115 {
                horizontal[y] += 1; vertical[x] += 1
            }
        }
        func centers(_ counts: [Int], threshold: Int) -> [Double] {
            var ranges = [(Int, Int)](); var start: Int?
            for i in counts.indices {
                if counts[i] >= threshold { if start == nil { start = i } }
                else if let first = start { ranges.append((first, i - 1)); start = nil }
            }
            if let first = start { ranges.append((first, counts.count - 1)) }
            return ranges.filter { $0.1 - $0.0 < max(4, counts.count / 35) }.map { Double($0.0 + $0.1) / (2 * Double(counts.count)) }
        }
        let h = centers(horizontal, threshold: max(8, Int(Double(width) * 0.48)))
        let v = centers(vertical, threshold: max(8, Int(Double(height) * 0.40)))
        return (h.count >= 4 ? h : [], v.count >= 4 ? v : [])
    }
}

enum TextScan {
    nonisolated static func read(_ data: Data, schedule: Bool) async throws -> ScanPage {
        let worker = Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw URLError(.cannotDecodeContentData) }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = CGImagePropertyOrientation(rawValue: (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1) ?? .up
            var input = CIImage(cgImage: cg).oriented(orientation)
            let context = CIContext()
            if !schedule, let upright = context.createCGImage(input, from: input.extent) {
                // Rectify photographed paper before OCR; keep the corrected page as review evidence.
                let rectangleRequest = VNDetectRectanglesRequest()
                rectangleRequest.minimumAspectRatio = 0.2; rectangleRequest.maximumAspectRatio = 1
                rectangleRequest.minimumSize = 0.4; rectangleRequest.minimumConfidence = 0.75
                rectangleRequest.maximumObservations = 6
                try? VNImageRequestHandler(cgImage: upright, orientation: .up).perform([rectangleRequest])
                let candidates = (rectangleRequest.results ?? []).filter { $0.boundingBox.width > 0.65 && $0.boundingBox.height > 0.45 }
                if let rectangle = candidates.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                    func point(_ p: CGPoint) -> CIVector {
                        CIVector(x: input.extent.minX + p.x * input.extent.width, y: input.extent.minY + p.y * input.extent.height)
                    }
                    input = input.applyingFilter("CIPerspectiveCorrection", parameters: [
                        "inputTopLeft": point(rectangle.topLeft), "inputTopRight": point(rectangle.topRight),
                        "inputBottomLeft": point(rectangle.bottomLeft), "inputBottomRight": point(rectangle.bottomRight)])
                }
            }
            guard let image = context.createCGImage(input, from: input.extent) else { throw URLError(.cannotDecodeContentData) }
            let png = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil) else { throw URLError(.cannotDecodeContentData) }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw URLError(.cannotDecodeContentData) }
            var tables = [ScanTable]()
            var transcript = ""
            if #available(iOS 26.0, *) {
                // Document recognition retains empty cells, rows, and column relationships.
                do {
                    let observations = try await RecognizeDocumentsRequest().perform(on: png as Data)
                    if let document = observations.first?.document {
                        transcript = document.text.transcript
                        tables = document.tables.map { table in
                            ScanTable(rows: table.rows.map { row in row.map { $0.content.text.transcript } })
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { /* Coordinate-based recognition below remains available. */ }
            }
            let enhanced = CIImage(cgImage: image).applyingFilter("CIColorControls", parameters: ["inputSaturation": 0, "inputContrast": 1.4])
            let enhancedImage = context.createCGImage(enhanced, from: enhanced.extent)
            if !schedule, tables.isEmpty, #available(iOS 26.0, *), let enhancedImage {
                do {
                    let observations = try await RecognizeDocumentsRequest().perform(on: enhancedImage)
                    if let document = observations.first?.document {
                        if transcript.isEmpty { transcript = document.text.transcript }
                        tables = document.tables.map { table in ScanTable(rows: table.rows.map { row in row.map { $0.content.text.transcript } }) }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { /* OCR and printed-rule reconstruction still run. */ }
            }
            var words = [ScanBox]()
            let width = Double(image.width), height = Double(image.height)
            // Overlapping crops retain small table text that can be missed in a full-page OCR pass.
            let regions: [CGRect] = [CGRect(x: 0, y: 0, width: 1, height: 1), CGRect(x: 0, y: 0, width: 0.55, height: 0.56), CGRect(x: 0.45, y: 0, width: 0.55, height: 0.56), CGRect(x: 0, y: 0.44, width: 0.55, height: 0.56), CGRect(x: 0.45, y: 0.44, width: 0.55, height: 0.56)]
            let passes: [(CGImage, CGRect)] = regions.map { (image, $0) } + (!schedule ? enhancedImage.map { [($0, CGRect(x: 0, y: 0, width: 1, height: 1))] } ?? [] : [])
            for (passImage, region) in passes {
                try Task.checkCancellation()
                let pixels = CGRect(x: region.minX * width, y: region.minY * height, width: region.width * width, height: region.height * height).integral
                guard let crop = passImage.cropping(to: pixels) else { continue }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.002
                request.recognitionLanguages = ["en-US"]
                try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
                for observation in request.results ?? [] {
                    guard let candidate = observation.topCandidates(1).first,
                          let regex = try? NSRegularExpression(pattern: #"\S+"#) else { continue }
                    let text = candidate.string
                    let tokens = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    for token in tokens {
                        guard let range = Range(token.range, in: text) else { continue }
                        let rectangle = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                        var word = ScanBox(text: String(text[range]), x: (pixels.minX + rectangle.minX * pixels.width) / width,
                            y: (pixels.minY + (1 - rectangle.maxY) * pixels.height) / height,
                            width: rectangle.width * pixels.width / width, height: rectangle.height * pixels.height / height,
                            confidence: candidate.confidence)
                        if let index = words.firstIndex(where: { existing in
                            let sameText = ScanParsing.normalized(existing.text) == ScanParsing.normalized(word.text)
                            let nearby = abs(existing.midX - word.midX) < max(0.004, min(existing.width, word.width) * 0.4)
                                && abs(existing.midY - word.midY) < max(0.002, min(existing.height, word.height) * 0.6)
                            let oldBounds = CGRect(x: existing.x, y: existing.y, width: existing.width, height: existing.height)
                            let newBounds = CGRect(x: word.x, y: word.y, width: word.width, height: word.height)
                            let overlap = oldBounds.intersection(newBounds)
                            let oldArea = existing.width * existing.height, newArea = word.width * word.height
                            let areaRatio = min(oldArea, newArea) / max(0.000001, max(oldArea, newArea))
                            let sharedArea = overlap.isNull ? 0 : Double(overlap.width * overlap.height)
                            return (sameText && nearby) || (areaRatio > 0.55 && sharedArea > min(oldArea, newArea) * 0.75)
                        }) {
                            let existing = words[index]
                            let different = ScanParsing.normalized(existing.text) != ScanParsing.normalized(word.text)
                            let alternatives = Array(Set(existing.alternatives + (different ? [existing.text, word.text] : []))).sorted()
                            if word.confidence > existing.confidence { word.alternatives = alternatives; words[index] = word }
                            else { words[index].alternatives = alternatives }
                        } else { words.append(word) }
                    }
                }
            }
            let rules = schedule ? (horizontal: [Double](), vertical: [Double]()) : ScanGrid.rules(image)
            return ScanPage(tables: tables, words: words, imagePNG: png as Data, transcript: transcript,
                horizontalRules: rules.horizontal, verticalRules: rules.vertical)
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}

struct ScanMappingEditor: View {
    @Environment(\.dismiss) var dismiss
    @State var fields: [ScanField]
    let headers: [String]
    let onSave: ([ScanField]) -> Void
    var body: some View {
        SheetFrame(title: "Match the columns") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose what each photo column contains. Unassigned columns stay in the entry's comments.").font(.subheadline)
                ForEach(fields.indices, id: \.self) { index in
                    Picker(index < headers.count ? headers[index] : "Column \(index + 1)", selection: $fields[index]) {
                        ForEach(ScanField.allCases) { field in Text(field.title).tag(field) }
                    }.pickerStyle(.menu)
                }
                AccentButton(title: "Apply column mapping") { onSave(fields); dismiss() }
            }
        }
    }
}

// Apple's guided document camera supplies edge detection, perspective correction and recapture controls.
struct GuidedDocumentCamera: UIViewControllerRepresentable {
    let finished: ([Data]) -> Void
    let cancelled: () -> Void
    let failed: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let owner: GuidedDocumentCamera
        init(_ owner: GuidedDocumentCamera) { self.owner = owner }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0, scan.pageCount <= 10 else { owner.failed("Scan between 1 and 10 pages at a time."); return }
            var pages: [Data] = []
            for index in 0..<scan.pageCount {
                guard let data = scan.imageOfPage(at: index).jpegData(compressionQuality: 0.94) else {
                    owner.failed("A scanned page could not be opened. Please recapture it."); return
                }
                pages.append(data)
            }
            owner.finished(pages)
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { owner.cancelled() }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { owner.failed(error.localizedDescription) }
    }
}

@MainActor struct ScanReview: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var store: FlightStore
    var schedule: Bool
    var onCompletionChanged: ((Bool) -> Void)? = nil
    @State private var photo: PhotosPickerItem?
    @State private var selectedImageData: Data?
    @State private var preparationRun = 0
    @State private var showDocumentCamera = false
    @State private var cameraPages: [Data] = []
    @State private var cameraPageIndex = 0
    @State private var qualityWarnings: [String] = []
    @State private var cameraPermissionTask: Task<Void, Never>?
    @State private var originalPhoto: Data?
    @State private var inputs: [AIPhotoInput] = []
    @State private var ocrHints: [AITextHint] = []
    @State private var page: ScanPage?
    @State private var tables: [ScanTable] = []
    @State private var overrides: [String: [ScanField]] = [:]
    @State private var drafts: [ScanFlightDraft] = []
    @State private var working = false
    @State private var problem = ""
    @State private var reviewing = false
    @State private var index = 0
    @State private var saved = 0
    @State private var skipped = 0
    @State private var previousSaved = 0
    @State private var previousSkipped = 0
    @State private var automaticallySaved = 0
    @State private var previousAutomaticallySaved = 0
    @State private var duplicateCount = 0
    @State private var previousDuplicateCount = 0
    @State private var bypassedScheduleReview = false
    @State private var notAdded: [ImportFailure] = []
    @State private var previousNotAdded: [ImportFailure] = []
    @State private var confirmWithoutReview = false
    @State private var year = String(Calendar.current.component(.year, from: Date()))
    @State private var mapping: ScanTable?
    @State private var rawText = ""
    @State private var correctedText = false
    @State private var showSource = false
    @State private var showSettings = false
    @State private var configured = AIImportConfiguration.ready
    @State private var scanRun = 0
    @State private var requestedBasic = false
    @State private var basicResult = false
    @State private var pageWarnings: [String] = []
    private var resolvedYear: Int { Int(year).flatMap { (1900...2199).contains($0) ? $0 : nil } ?? Calendar.current.component(.year, from: Date()) }
    var body: some View {
        reviewContent
        .task(id: photo) {
            guard let photo else { return }
            working = true
            defer { working = false }
            do {
                guard let data = try await photo.loadTransferable(type: Data.self) else { throw URLError(.cannotDecodeContentData) }
                try Task.checkCancellation()
                cameraPages = []; cameraPageIndex = 0; resetImportSummary(); stageImage(data)
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
        .task(id: preparationRun) {
            guard preparationRun > 0, let data = selectedImageData else { return }
            working = true; resetReading(); originalPhoto = nil; inputs = []; ocrHints = []; page = nil; qualityWarnings = []
            defer { working = false }
            do {
                let prepared = try await AIPhotoImporter.prepareImage(data, schedule: schedule)
                try Task.checkCancellation()
                originalPhoto = data; inputs = prepared.inputs; ocrHints = prepared.textHints
                qualityWarnings = prepared.qualityWarnings
                page = ScanPage(tables: [], words: [], imagePNG: prepared.preview)
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
        .task(id: scanRun) {
            guard scanRun > 0, let data = originalPhoto else { return }
            working = true; resetReading()
            defer { working = false }
            do {
                if requestedBasic { try await readBasic(data) }
                else {
                    let result = try await AIPhotoImporter.read(inputs, schedule: schedule, year: resolvedYear, ocrHints: ocrHints)
                    try Task.checkCancellation()
                    drafts = AIPhotoImporter.drafts(result); pageWarnings = qualityWarnings + result.pageWarnings; basicResult = false
                    rawText = result.entries.map { "Entry \($0.rowNumber): " + $0.sourceText }.joined(separator: "\n\n")
                    if drafts.isEmpty { problem = "No flight entries were found. Check that the complete page is readable, then try another photo or a smaller section." }
                }
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { problem = error.localizedDescription + " No entries were saved. You can retry or choose basic text reading." } }
        }
        .sheet(isPresented: $showSettings, onDismiss: { configured = AIImportConfiguration.ready }) { AIImportSettings() }
        .fullScreenCover(isPresented: $showDocumentCamera) {
            GuidedDocumentCamera(finished: { pages in
                showDocumentCamera = false; cameraPages = pages; cameraPageIndex = 0
                resetImportSummary()
                if let first = pages.first { stageImage(first) }
            }, cancelled: { showDocumentCamera = false }, failed: { message in
                showDocumentCamera = false; problem = message
            }).ignoresSafeArea()
        }
        .sheet(isPresented: $showSource) {
            if let image = page.flatMap({ UIImage(data: $0.imagePNG) }) {
                SheetFrame(title: "Source photo") { ScanPhotoZoom(image: image).frame(height: 540) }
            }
        }
        .sheet(item: $mapping) { table in
            let schema = ScanParsing.schema(table, schedule: schedule)
            ScanMappingEditor(fields: overrides[table.id] ?? schema.fields, headers: schema.headers) { fields in
                overrides[table.id] = fields; rebuildDrafts()
            }
        }
        .alert("Save without reviewing?", isPresented: $confirmWithoutReview) {
            Button("Go back", role: .cancel) {}
            Button("Continue") {
                if schedule { beginScheduleImport(.withoutReview) }
                else { beginPhotoImport(.withoutReview) }
            }
        } message: {
            Text("We recommend reviewing at least the flagged flights before saving. Continue to save without checking them? Entries missing required details will be listed on the completion screen and won't be added.")
        }
    }
    @ViewBuilder private var reviewContent: some View {
        if reviewing, drafts.indices.contains(index) {
            reviewEditor(drafts[index])
        } else if reviewing {
            reviewCompletion
        } else {
            preparation
        }
    }
    @ViewBuilder private func reviewEditor(_ current: ScanFlightDraft) -> some View {
        if let item = current.schedule {
            ScheduleEditor(item: item, importReview: scheduledReviewContext(current),
                           onImportSaved: { advance(saved: true) },
                           onImportSkipped: { advance(saved: false) }).id(current.id)
        } else if let flight = current.flight {
            FlightEditor(flight: flight, importReview: reviewContext(current),
                         onImportSaved: { advance(saved: true) },
                         onImportSkipped: { advance(saved: false) }).id(current.id)
        }
    }
    private var reviewCompletion: ImportReviewCompletion {
        let destination = schedule ? "calendar" : "logbook"
        let savedCount = previousSaved + saved
        let skippedCount = previousSkipped + skipped
        let automaticCount = previousAutomaticallySaved + automaticallySaved
        let duplicates = previousDuplicateCount + duplicateCount
        let failures = previousNotAdded + notAdded
        if cameraPageIndex + 1 < cameraPages.count {
            return ImportReviewCompletion(title: bypassedScheduleReview ? "Page saved" : "Page reviews complete", saved: savedCount, skipped: skippedCount,
                duplicates: duplicates, automaticallySaved: automaticCount, savedWithoutReview: bypassedScheduleReview, destination: destination,
                notAdded: failures,
                nextPageTitle: "Continue to scanned page \(cameraPageIndex + 2) of \(cameraPages.count)",
                onNextPage: { continueScannedPage() }, onClose: { dismiss() })
        }
        return ImportReviewCompletion(title: "All reviews complete", saved: savedCount, skipped: skippedCount,
            duplicates: duplicates, automaticallySaved: automaticCount, savedWithoutReview: bypassedScheduleReview, destination: destination,
            notAdded: failures, onClose: { dismiss() })
    }
    private var preparation: some View {
        SheetFrame(title: schedule ? "Import schedule photo" : "Import logbook photo") {
            VStack(alignment: .leading, spacing: 18) {
                Text(schedule ? "AI reads each booking's date, time, aircraft and details from the image. Choose how to review the scheduled flights and ground lessons before adding them to your calendar." : "AI reads the handwriting, headings and rows together. Review each flight's extracted details before adding it to your logbook.")
                    .font(.subheadline).foregroundStyle(theme.muted)
                AccentButton(title: "Scan document") { openDocumentCamera() }.disabled(working)
                PhotosPicker(selection: $photo, matching: .images) {
                    AccentButtonLabel(title: "Choose photo")
                }.buttonStyle(.plain).disabled(working)
                if !cameraPages.isEmpty { Text("Scanned page \(cameraPageIndex + 1) of \(cameraPages.count)").font(.caption).foregroundStyle(theme.muted) }
                Text("Capture the whole page, including headings, landing columns and remarks. Keep it flat and evenly lit.")
                    .font(.caption).foregroundStyle(theme.muted)
                if let image = page.flatMap({ UIImage(data: $0.imagePNG) }) {
                    Button { showSource = true } label: {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220).clipShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                    Text("Tap the photo to zoom in.").font(.caption).foregroundStyle(theme.muted)
                }
                if originalPhoto != nil, !reviewing {
                    if !qualityWarnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Check photo quality", systemImage: "exclamationmark.circle.fill").font(.subheadline.bold())
                            ForEach(qualityWarnings, id: \.self) { Text($0).font(.caption) }
                            Text("You can recapture the page or continue and check every draft.").font(.caption)
                        }.foregroundStyle(ScanReviewColors.warning(theme.dark)).logbookCard()
                    }
                    LogField(title: "Year if the photo does not show one", value: $year, hint: "2026", keyboard: .numberPad).disabled(working)
                    if configured {
                        Text("Your photo is sent securely for AI reading. Review the editable drafts before saving.")
                            .font(.caption).foregroundStyle(theme.muted)
                        AccentButton(title: "Read with AI") { requestedBasic = false; scanRun += 1 }.disabled(working)
                    } else {
                        Text("AI image reading needs a connected import service. Basic text reading remains available, with more limited handwriting and layout recognition.")
                            .font(.subheadline).foregroundStyle(theme.muted)
                        Button("Connect AI image imports") { showSettings = true }.foregroundStyle(theme.cyan).disabled(working)
                    }
                    Button("Use basic text reading") { requestedBasic = true; scanRun += 1 }.font(.subheadline).foregroundStyle(theme.muted).disabled(working)
                }
                if working { ProgressView(inputs.isEmpty ? "Preparing photo and checking quality…" : requestedBasic ? "Reading text and columns…" : "Reading handwriting and separating entries…") }
                if !problem.isEmpty { Text(problem).foregroundStyle(theme.accent) }
                if !working, !reviewing, page != nil {
                    if !pageWarnings.isEmpty {
                        DisclosureGroup("Other scan notes") {
                            ForEach(Array(pageWarnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.subheadline).foregroundStyle(theme.accent) }
                        }.logbookCard()
                    }
                    if !drafts.isEmpty {
                        Text("\(drafts.count) \(drafts.count == 1 ? "entry" : "entries") ready to review").font(.headline)
                        Text(basicResult ? "Read with basic text recognition" : "Read with AI image interpretation").font(.caption).foregroundStyle(theme.muted)
                        if schedule { scheduleReviewChoices }
                        else { photoReviewChoices }
                    }
                    if basicResult {
                        ForEach(Array(tables.enumerated()), id: \.element.id) { tableIndex, table in
                            Button("Check column mapping\(tables.count > 1 ? " · table \(tableIndex + 1)" : "")") { mapping = table }.foregroundStyle(theme.cyan)
                        }
                        DisclosureGroup("Recognized text / correct a reading") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Correct missed characters or separate entries onto new lines. For a table, keep | separators and empty cells.").font(.caption).foregroundStyle(theme.muted)
                                TextEditor(text: $rawText).font(.system(size: 13, design: .monospaced)).frame(minHeight: 200)
                                    .scrollContentBackground(.hidden).padding(10).background(theme.raised).clipShape(RoundedRectangle(cornerRadius: 12))
                                Button("Use corrected text") { correctedText = true; rebuildDrafts() }.foregroundStyle(theme.cyan)
                            }.padding(.top, 10)
                        }
                    } else if !rawText.isEmpty {
                        DisclosureGroup("AI source readings") { Text(rawText).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).padding(.top, 10) }
                    }
                    if drafts.isEmpty, !problem.isEmpty { Button("Enter a draft with this photo") { startUncertainDraft() }.foregroundStyle(theme.cyan) }
                }
            }
        }
    }
    @ViewBuilder private var scheduleReviewChoices: some View {
        AccentButton(title: "Review all scheduled flights") { beginScheduleImport(.all) }
        scheduleSecondaryAction("Review flagged flights only", symbol: "exclamationmark.circle") { beginScheduleImport(.flagged) }
        scheduleSecondaryAction("Save without reviewing", symbol: "square.and.arrow.down") { confirmWithoutReview = true }
    }
    @ViewBuilder private var photoReviewChoices: some View {
        AccentButton(title: "Review all flights") { beginPhotoImport(.all) }
        scheduleSecondaryAction("Review flagged flights only", symbol: "exclamationmark.circle") { beginPhotoImport(.flagged) }
        scheduleSecondaryAction("Save without reviewing", symbol: "square.and.arrow.down") { confirmWithoutReview = true }
    }
    private func beginPhotoImport(_ mode: CSVReviewMode) {
        guard !schedule else { return }
        var automatic: [Flight] = []
        var review: [ScanFlightDraft] = []
        var failures: [ImportFailure] = []
        for (number, draft) in drafts.enumerated() {
            guard var flight = draft.flight else {
                if mode == .withoutReview {
                    failures.append(ImportFailure(id: draft.id, title: "Flight \(number + 1)", subtitle: "Missing flight details",
                        issues: [ScanFieldIssue(field: "date", message: "The flight could not be read. Enter its date and registration.")]))
                } else { review.append(draft) }
                continue
            }
            let issues = FlightEntryValidation.requiredIssues(flight, missingDate: draft.unresolvedFields.contains("date"))
            let evidence = reviewContext(draft)
            if mode == .all || (mode == .flagged && (!issues.isEmpty || !evidence.fieldIssues.isEmpty || !evidence.otherNotes.isEmpty)) {
                review.append(draft)
            } else if !issues.isEmpty {
                failures.append(.flight(flight, number: number + 1, issues: issues))
            } else {
                flight.facts.text["importReviewStatus"] = mode == .withoutReview ? "Saved without review" : "No flagged fields; saved automatically"
                flight.facts.text["importUnreviewedFields"] = evidence.fieldIssues.map(\.field).joined(separator: ", ")
                flight.facts.text["scanImportWarnings"] = evidence.warnings.joined(separator: "\n")
                flight.facts.text["scanSource"] = draft.sourceText
                automatic.append(flight)
            }
        }
        guard store.saveImportedFlights(automatic) else {
            problem = store.errorMessage ?? "The imported flights could not be saved."; return
        }
        drafts = review; index = 0; saved = automatic.count; skipped = 0
        automaticallySaved = automatic.count; duplicateCount = 0; notAdded = failures
        if mode == .withoutReview { bypassedScheduleReview = true }
        problem = ""; reviewing = true; onCompletionChanged?(drafts.isEmpty)
    }
    private func scheduleSecondaryAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.cyan).frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(theme.surface).clipShape(Capsule()).overlay(Capsule().stroke(theme.line, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func beginScheduleImport(_ mode: ScheduleReviewMode) {
        guard schedule else { return }
        let plan = ScheduleImportReview.plan(drafts, existing: store.schedules, mode: mode, context: { scheduledReviewContext($0) })
        guard store.saveImportedSchedules(plan.automatic) else {
            problem = store.errorMessage ?? "The scheduled flights could not be saved."; return
        }
        if !plan.automatic.isEmpty { Task { await ReminderManager.rebuild(store.schedules) } }
        drafts = plan.review; index = 0; saved = plan.automatic.count; skipped = 0
        automaticallySaved = plan.automatic.count; duplicateCount = plan.duplicates
        notAdded = plan.notAdded
        if mode == .withoutReview { bypassedScheduleReview = true }
        problem = ""; reviewing = true; onCompletionChanged?(drafts.isEmpty)
    }
    private func scheduledReviewContext(_ draft: ScanFlightDraft) -> ScanReviewContext {
        var context = reviewContext(draft)
        let additionalWarnings = pageWarnings.filter { !context.warnings.contains($0) }
        context.warnings += additionalWarnings
        if let item = draft.schedule { context.issues += ScheduleImportReview.validationIssues(item) }
        return context
    }
    private func resetImportSummary() {
        previousSaved = 0; previousSkipped = 0; previousAutomaticallySaved = 0; previousDuplicateCount = 0
        bypassedScheduleReview = false
        notAdded = []; previousNotAdded = []
    }
    private func resetReading() {
        problem = ""; reviewing = false; rawText = ""; drafts = []; tables = []; overrides = [:]
        correctedText = false; basicResult = false; pageWarnings = []
        automaticallySaved = 0; duplicateCount = 0
        notAdded = []
        onCompletionChanged?(false)
    }
    private func stageImage(_ data: Data) {
        reviewing = false; onCompletionChanged?(false)
        selectedImageData = data; preparationRun += 1
    }
    private func continueScannedPage() {
        guard cameraPageIndex + 1 < cameraPages.count else { return }
        previousSaved += saved; previousSkipped += skipped
        previousAutomaticallySaved += automaticallySaved; previousDuplicateCount += duplicateCount
        previousNotAdded += notAdded
        cameraPageIndex += 1; stageImage(cameraPages[cameraPageIndex])
    }
    private func openDocumentCamera() {
        guard VNDocumentCameraViewController.isSupported else { problem = "Document scanning is not supported on this device. Choose a photo instead."; return }
        guard let description = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
              !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            problem = "Add Privacy - Camera Usage Description (NSCameraUsageDescription) to the Xcode target's Info settings to enable document scanning."
            return
        }
        cameraPermissionTask?.cancel()
        cameraPermissionTask = Task { @MainActor in
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            let allowed: Bool
            if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
            else { allowed = status == .authorized }
            guard !Task.isCancelled else { return }
            if allowed { showDocumentCamera = true; problem = "" }
            else { problem = "Camera access is off. Enable it in iOS Settings for LogMate, or choose a photo." }
        }
    }
    private func readBasic(_ data: Data) async throws {
        let result = try await TextScan.read(data, schedule: schedule)
        try Task.checkCancellation()
        page = result; basicResult = true; pageWarnings = qualityWarnings
        tables = ScanLayout.chooseTables(result, schedule: schedule, year: resolvedYear)
        let lines = ScanLayout.lines(result.words).map { $0.map(\.text).joined(separator: " ") }.joined(separator: "\n")
        let geometric = ScanTextEntries.drafts(lines, schedule: schedule, year: resolvedYear)
        let document = ScanTextEntries.drafts(result.transcript, schedule: schedule, year: resolvedYear)
        rawText = document.count > geometric.count ? result.transcript : lines
        rebuildDrafts()
        if !tables.isEmpty, ScanLayout.score(tables, schedule: schedule, year: resolvedYear) >= draftScore(ScanTextEntries.drafts(rawText, schedule: schedule, year: resolvedYear)),
           let table = tables.first, tables.count == 1 {
            let schema = ScanParsing.schema(table, schedule: schedule)
            let rows = [schema.headers] + Array(table.rows.dropFirst(schema.firstDataRow))
            rawText = rows.map { $0.map { $0.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") }.joined(separator: "\n")
        }
    }
    private func draftScore(_ items: [ScanFlightDraft]) -> Int {
        items.reduce(0) { total, draft in
            if let flight = draft.flight { return total + 2 + (flight.total > 0 ? 3 : 0) + (!flight.registration.isEmpty ? 3 : 0) }
            if let item = draft.schedule { return total + 2 + (item.isGround || !item.registration.isEmpty ? 3 : 0) + (item.endDate != nil ? 1 : 0) }
            return total
        }
    }
    private func rebuildDrafts() {
        let textDrafts = ScanTextEntries.drafts(rawText, schedule: schedule, year: resolvedYear)
        if correctedText { drafts = textDrafts }
        else {
            let rowDrafts = ScanParsing.parsedDrafts(tables, schedule: schedule, year: resolvedYear, overrides: overrides)
            drafts = draftScore(rowDrafts) >= draftScore(textDrafts) ? rowDrafts : textDrafts
        }
        problem = drafts.isEmpty ? "Basic text reading could not separate entries. Try AI reading, correct the recognized text, or enter a draft from the photo." : ""
    }
    private func startUncertainDraft() {
        let warnings = ["Enter the date and registration from the source before saving. Other fields can be left blank."]
        drafts = schedule
            ? [ScanFlightDraft(schedule: ScheduledFlight(), sourceText: rawText, sourceBounds: nil, warnings: warnings, unresolvedFields: ["date", "start"])]
            : [ScanFlightDraft(flight: Flight(), sourceText: rawText, sourceBounds: nil, warnings: warnings, unresolvedFields: ["date"])]
        index = 0; saved = 0; skipped = 0; reviewing = true
    }
    private func advance(saved accepted: Bool) {
        if accepted {
            saved += 1
            // Carry a corrected aircraft through following ditto rows, keeping every row editable.
            if let scanned = drafts[index].flight, let confirmed = store.flights.first(where: { $0.id == scanned.id }), index + 1 < drafts.count {
                for next in (index + 1)..<drafts.count {
                    guard drafts[next].repeatsRegistration, var flight = drafts[next].flight else { break }
                    let makeModel = drafts[next].repeatsModel ? confirmed.aircraftModel : flight.aircraftModel
                    flight.aircraft = confirmed.registration + " · " + makeModel
                    drafts[next].flight = flight
                    drafts[next].warnings.append("Aircraft updated from the preceding saved entry's ditto mark. Check it against this row.")
                }
            }
        } else { skipped += 1 }
        index += 1
        if index >= drafts.count { onCompletionChanged?(true) }
    }
    private func reviewContext(_ draft: ScanFlightDraft) -> ScanReviewContext {
        var warnings = draft.warnings + qualityWarnings
        if let bounds = draft.sourceBounds, let page,
           page.words.contains(where: { bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) && $0.confidence < 0.5 }) {
            warnings.append("Some writing in this row has low recognition confidence. Compare the draft with the photo.")
        }
        if let bounds = draft.sourceBounds, let page,
           page.words.contains(where: { bounds.contains(CGPoint(x: $0.midX, y: $0.midY)) && !$0.alternatives.isEmpty }) {
            warnings.append("Recognition passes disagreed on some characters in this row. Check numbers and aircraft registration against the photo.")
        }
        if let item = draft.schedule, store.schedules.contains(where: { existing in
            if let source = item.sourceScheduleID, !source.isEmpty, source == existing.sourceScheduleID { return true }
            return abs(existing.date.timeIntervalSince(item.date)) < 60 && existing.registration == item.registration && existing.isGround == item.isGround
        }) { warnings.append("A matching booking is already in your calendar. Skip this entry to avoid a duplicate.") }
        if let flight = draft.flight, store.flights.contains(where: { $0.date == flight.date && $0.registration == flight.registration && $0.route == flight.route && abs($0.total - flight.total) < 0.001 }) {
            warnings.append("A matching flight is already in your logbook. Skip it unless this is a separate flight.")
        }
        let image = page.flatMap { UIImage(data: $0.imagePNG) }
        var rowImage: UIImage?
        if let cg = image?.cgImage, let rect = draft.sourceBounds {
            let pixels = CGRect(x: rect.minX * Double(cg.width), y: rect.minY * Double(cg.height), width: rect.width * Double(cg.width), height: rect.height * Double(cg.height)).integral
            if let crop = cg.cropping(to: pixels) { rowImage = UIImage(cgImage: crop) }
        }
        return ScanReviewContext(title: "Review \(schedule ? "booking" : "flight") \(index + 1) of \(drafts.count)", sourceText: draft.sourceText, image: image, warnings: warnings, unresolvedFields: draft.unresolvedFields, issues: draft.issues, rowImage: rowImage)
    }
}
