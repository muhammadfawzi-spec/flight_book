// Flight story: the story style, the color helper (file-private), the
// story builder, the story art, the story view, and the share image /
// photo saver.
import SwiftUI
import Foundation
import UIKit
import MapKit
import PhotosUI

struct ShareImage: Identifiable { let id = UUID(); let image: UIImage }
@MainActor enum StoryPhotoSaver {
    static func save(_ image: UIImage) async throws {
        guard let purpose = Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String, !purpose.isEmpty else {
            throw CSVImportError.invalid("Enable photo saving in Xcode: Target → Info → Privacy - Photo Library Additions Usage Description. Use: Save flight stories to your photo library.")
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw CSVImportError.invalid("Allow LogMate to add photos in iPhone Settings, then try again.") }
        try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: image) }
    }
}

enum FlightStoryStyle: String, CaseIterable, Identifiable {
    case midnight, light, photo
    var id: String { rawValue }
    var title: String { switch self { case .midnight: return "Midnight"; case .light: return "Light"; case .photo: return "Photo" } }
}

private extension UIColor {
    convenience init(hex: String) {
        let value = UInt32(hex, radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

@MainActor final class FlightStoryBuilder: ObservableObject {
    @Published private(set) var stories: [FlightStoryStyle: UIImage] = [:]
    @Published private(set) var working = false
    @Published private(set) var message: String?
    @Published private(set) var hasPhoto = false
    private var background: UIImage?
    private var darkMap: UIImage?
    private var lightMap: UIImage?
    private var snapshotter: MKMapSnapshotter?
    private var timeout: Task<Void, Never>?
    private var requestID = UUID()
    private var flight: Flight?
    private var distance = 0.0

    func setPhoto(_ photo: UIImage?) {
        background = photo; hasPhoto = photo != nil
        compose()
    }
    func prepare(_ flight: Flight, catalog: AirportCatalog) async {
        cancel()
        let request = requestID
        self.flight = flight; working = true; message = nil
        stories = [:]; darkMap = nil; lightMap = nil
        let codes = flight.airports
        guard !codes.isEmpty else { fail("This flight needs an airport in its route before a map can be shared.", request: request); return }
        await catalog.load(codes)
        guard request == requestID, !Task.isCancelled else { return }
        let missing = Array(Set(codes.filter { code in
            guard let info = catalog.airports[code] else { return true }
            return !CLLocationCoordinate2DIsValid(info.coordinate)
        })).sorted()
        guard missing.isEmpty else {
            fail("Airport coordinates could not be loaded for \(missing.joined(separator: ", ")). Check the route and try again.", request: request)
            return
        }
        let route = codes.compactMap { catalog.airports[$0] }
        distance = zip(route, route.dropFirst()).reduce(0) { $0 + RouteGeometry.distance($1.0, $1.1) }
        timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(35)) } catch { return }
            guard let self, request == self.requestID, self.working else { return }
            self.fail("The map request timed out. Check your connection and try again.", request: request)
        }
        capture(route, light: false, request: request)
    }
    func cancel() {
        requestID = UUID(); timeout?.cancel(); timeout = nil
        snapshotter?.cancel(); snapshotter = nil; working = false
    }
    private func fail(_ text: String, request: UUID) {
        guard request == requestID else { return }
        requestID = UUID(); timeout?.cancel(); timeout = nil
        snapshotter?.cancel(); snapshotter = nil; message = text; working = false
    }
    private func capture(_ route: [AirportInfo], light: Bool, request: UUID) {
        let options = MKMapSnapshotter.Options()
        options.size = CGSize(width: 848, height: 806)
        options.scale = 1
        options.mapRect = FlightStoryArt.mapRect(route)
        options.mapType = .mutedStandard
        options.traitCollection = UITraitCollection(userInterfaceStyle: light ? .light : .dark)
        options.pointOfInterestFilter = .excludingAll
        options.showsBuildings = false
        let renderer = MKMapSnapshotter(options: options)
        snapshotter = renderer
        renderer.start(with: DispatchQueue.main) { [weak self] snapshot, error in
            // MapKit explicitly delivers this callback on the main queue.
            MainActor.assumeIsolated {
                guard let self, self.requestID == request else { return }
                guard let snapshot else {
                    self.fail(error?.localizedDescription ?? "The map could not be rendered. Please try again.", request: request)
                    return
                }
                let map = FlightStoryArt.routeMap(snapshot, route: route, light: light)
                if light {
                    self.lightMap = map; self.snapshotter = nil
                    self.timeout?.cancel(); self.timeout = nil
                    self.compose(); self.working = false
                } else {
                    self.darkMap = map
                    self.capture(route, light: true, request: request)
                }
            }
        }
    }
    private func compose() {
        guard let flight, let darkMap, let lightMap else { return }
        var results: [FlightStoryStyle: UIImage] = [
            .midnight: FlightStoryArt.render(flight, map: darkMap, distance: distance, style: .midnight, photo: nil),
            .light: FlightStoryArt.render(flight, map: lightMap, distance: distance, style: .light, photo: nil)
        ]
        if let background { results[.photo] = FlightStoryArt.render(flight, map: darkMap, distance: distance, style: .photo, photo: background) }
        stories = results
    }
}

@MainActor enum FlightStoryArt {
    static let canvas = CGSize(width: 1080, height: 1920)
    private static func format() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1; format.opaque = true
        return format
    }
    static func mapRect(_ route: [AirportInfo]) -> MKMapRect {
        AirportMapGeometry.mapRect(route.map(\.coordinate), aspectRatio: 848.0 / 806.0) ?? .world
    }
    static func routeMap(_ snapshot: MKMapSnapshotter.Snapshot, route: [AirportInfo], light: Bool) -> UIImage {
        let size = snapshot.image.size
        return UIGraphicsImageRenderer(size: size, format: format()).image { context in
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            let accent = UIColor(hex: light ? "DA9200" : "FFC548")
            let text = UIColor(hex: light ? "142A36" : "F5F7F8")
            let points = route.map { snapshot.point(for: $0.coordinate) }
            let path = UIBezierPath()
            for (index, point) in points.enumerated() {
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            cg.saveGState(); cg.setShadow(offset: .zero, blur: 9, color: UIColor.black.withAlphaComponent(0.45).cgColor)
            UIColor(hex: light ? "FFF8DC" : "10212A").setStroke(); path.lineWidth = 13; path.stroke()
            accent.setStroke(); path.lineWidth = 7; path.stroke(); cg.restoreGState()
            var seen: Set<String> = []
            let unique = route.filter { seen.insert($0.code).inserted }
            // Limit labels on complex routes while keeping every route leg and airport marker.
            let labeled = Set(unique.count <= 6 ? unique.map(\.code) : Array(unique.prefix(3).map(\.code)) + Array(unique.suffix(3).map(\.code)))
            for airport in unique {
                let point = snapshot.point(for: airport.coordinate)
                let dot = UIBezierPath(ovalIn: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20))
                cg.saveGState(); cg.setShadow(offset: .zero, blur: 7, color: UIColor.black.withAlphaComponent(0.35).cgColor)
                (airport.code == route.first?.code ? UIColor(hex: "19D7EE") : accent).setFill(); dot.fill()
                UIColor.white.setStroke(); dot.lineWidth = 3; dot.stroke(); cg.restoreGState()
                guard labeled.contains(airport.code) else { continue }
                let font = UIFont.systemFont(ofSize: 23, weight: .heavy)
                let measured = (airport.code as NSString).size(withAttributes: [.font: font])
                var x = point.x + 18
                if x + measured.width + 20 > size.width - 18 { x = point.x - measured.width - 32 }
                x = max(18, min(size.width - measured.width - 22, x))
                // Leave the original MapKit logo and legal attribution visible at the bottom.
                let y = max(18, min(size.height - 75, point.y - 17))
                let label = CGRect(x: x, y: y, width: measured.width + 16, height: 36)
                UIColor(hex: light ? "FFFFFF" : "14232D").withAlphaComponent(0.90).setFill()
                UIBezierPath(roundedRect: label, cornerRadius: 8).fill()
                draw(airport.code, in: label.insetBy(dx: 8, dy: 3), size: 23, color: text, weight: .heavy)
            }
        }
    }
    static func render(_ flight: Flight, map: UIImage, distance: Double, style: FlightStoryStyle, photo: UIImage?) -> UIImage {
        UIGraphicsImageRenderer(size: canvas, format: format()).image { context in
            let cg = context.cgContext
            let light = style == .light
            let text = UIColor(hex: light ? "102431" : "F5F7F8")
            let muted = UIColor(hex: light ? "687986" : "96AAB4")
            let accent = UIColor(hex: light ? "CA8300" : "FFC548")
            gradient(cg, rect: CGRect(origin: .zero, size: canvas), colors: light ? ["EDF2F4", "FFFFFF", "DDE9ED"] : ["080B0E", "172933", "091217"])
            if style == .photo, let photo {
                aspectFill(blur(photo), in: CGRect(origin: .zero, size: canvas))
                gradient(cg, rect: CGRect(origin: .zero, size: canvas), colors: ["080B0E", "0A151C"], alphas: [0.57, 0.88])
            }
            cg.saveGState()
            cg.addPath(LogMateLogo().path(in: CGRect(x: 90, y: 170, width: 43, height: 43)).cgPath)
            cg.setStrokeColor(accent.cgColor); cg.setLineWidth(2.6)
            cg.setLineCap(.round); cg.setLineJoin(.round); cg.strokePath(); cg.restoreGState()
            draw(AppBrand.name, in: CGRect(x: 144, y: 176, width: 720, height: 40), size: 30, color: text, weight: .heavy)
            draw("FLIGHT RECAP", in: CGRect(x: 92, y: 233, width: 896, height: 30), size: 19, color: muted, weight: .semibold)

            let card = CGRect(x: 84, y: 314, width: 912, height: 1294)
            let shape = UIBezierPath(roundedRect: card, cornerRadius: 46)
            cg.saveGState(); cg.setShadow(offset: CGSize(width: 0, height: 25), blur: 45, color: UIColor.black.withAlphaComponent(light ? 0.13 : 0.45).cgColor)
            UIColor(hex: light ? "FFFFFF" : "121D25").setFill(); shape.fill(); cg.restoreGState()
            cg.saveGState(); shape.addClip()
            gradient(cg, rect: card, colors: light ? ["FFFFFF", "F6F9FA"] : ["1C2C36", "101A21"])
            cg.restoreGState()
            UIColor(hex: light ? "DAE4E9" : "344550").withAlphaComponent(0.8).setStroke(); shape.lineWidth = 2; shape.stroke()
            let mapFrame = CGRect(x: 116, y: 346, width: 848, height: 806)
            cg.saveGState(); UIBezierPath(roundedRect: mapFrame, cornerRadius: 26).addClip()
            // Draw the complete map, including its attribution. Never aspect-fill or crop it.
            UIColor(hex: light ? "E3ECEF" : "182A34").setFill(); UIRectFill(mapFrame)
            // This inset keeps all four image corners inside the rounded frame.
            map.draw(in: mapFrame.insetBy(dx: 8, dy: 8)); cg.restoreGState()
            let codes = flight.airports
            let route = codes.count <= 4 ? codes.joined(separator: " → ") : "\(codes.first ?? "") → \(codes.last ?? "")"
            draw(route, in: CGRect(x: 128, y: 1193, width: 824, height: 122), size: 57, minimumSize: 38, color: text, weight: .heavy, lines: 2)
            if codes.count > 4 {
                draw("via " + codes.dropFirst().dropLast().joined(separator: " · "), in: CGRect(x: 128, y: 1303, width: 824, height: 29), size: 21, minimumSize: 14, color: muted)
            }
            draw("\(flight.aircraftModel) · \(flight.registration)", in: CGRect(x: 128, y: 1347, width: 824, height: 45), size: 30, minimumSize: 18, color: muted, weight: .medium)
            let date = flight.flightDate.map { FlightDates.string($0, format: "MMM d, yyyy") } ?? flight.date
            draw(date, in: CGRect(x: 128, y: 1398, width: 824, height: 33), size: 24, color: muted)
            cg.setStrokeColor(UIColor(hex: light ? "DCE5E9" : "354550").cgColor); cg.setLineWidth(2)
            cg.move(to: CGPoint(x: 128, y: 1450)); cg.addLine(to: CGPoint(x: 952, y: 1450)); cg.strokePath()
            draw(hours(max(0, flight.total)), in: CGRect(x: 128, y: 1471, width: 376, height: 85), size: 64, minimumSize: 40, color: accent, weight: .heavy)
            draw(String(format: "%.0f", distance), in: CGRect(x: 560, y: 1471, width: 392, height: 85), size: 64, minimumSize: 40, color: text, weight: .heavy)
            draw("TOTAL HOURS", in: CGRect(x: 128, y: 1561, width: 376, height: 27), size: 18, color: muted, weight: .semibold)
            draw("ROUTE NM", in: CGRect(x: 560, y: 1561, width: 392, height: 27), size: 18, color: muted, weight: .semibold)
            draw("Straight-line legs between logged airports.", in: CGRect(x: 92, y: 1680, width: 896, height: 32), size: 21, color: muted)
        }
    }
    private static func draw(_ text: String, in rect: CGRect, size: CGFloat, minimumSize: CGFloat? = nil, color: UIColor, weight: UIFont.Weight = .regular, lines: Int = 1) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
        paragraph.lineSpacing = 5
        var fontSize = size
        var attributes: [NSAttributedString.Key: Any] = [:]
        repeat {
            let base = UIFont.systemFont(ofSize: fontSize, weight: weight)
            let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: fontSize) } ?? base
            attributes = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
            let bounds = (text as NSString).boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
            if bounds.height <= rect.height, (lines > 1 || (text as NSString).size(withAttributes: attributes).width <= rect.width) { break }
            fontSize -= 1
        } while fontSize >= (minimumSize ?? size)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
    }
    private static func gradient(_ cg: CGContext, rect: CGRect, colors: [String], alphas: [CGFloat]? = nil) {
        let values = colors.enumerated().map { index, value in UIColor(hex: value).withAlphaComponent(alphas?[index] ?? 1).cgColor }
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: values as CFArray, locations: nil) else { return }
        cg.saveGState(); cg.clip(to: rect)
        cg.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        cg.restoreGState()
    }
    private static func aspectFill(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        let target = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        let cg = UIGraphicsGetCurrentContext(); cg?.saveGState(); cg?.clip(to: rect)
        image.draw(in: target); cg?.restoreGState()
    }
    private static func blur(_ image: UIImage) -> UIImage {
        guard let input = CIImage(image: image) else { return image }
        let output = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 12]).cropped(to: input.extent)
        guard let cg = CIContext().createCGImage(output, from: input.extent) else { return image }
        return UIImage(cgImage: cg)
    }
}

struct FlightStoryView: View {
    @EnvironmentObject var theme: AppTheme
    @EnvironmentObject var catalog: AirportCatalog
    @EnvironmentObject var photos: AircraftPhotos
    let flight: Flight
    @StateObject private var builder = FlightStoryBuilder()
    @State private var style = FlightStoryStyle.midnight
    @State private var chosenPhoto: UUID?
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var copied = false
    @State private var share: ShareImage?
    @State private var savingPhoto = false
    @State private var problem: String?
    private var ownedPhotos: [AircraftGalleryItem] { (photos.galleries[flight.registration] ?? []).filter(\.userAdded) }
    private var styles: [FlightStoryStyle] { builder.hasPhoto ? FlightStoryStyle.allCases : [.midnight, .light] }
    var body: some View {
        let photoPickerBackground = theme.raised
        let photoPickerTitle = importing ? "Saving…" : "Add photo"
        return SheetFrame(title: "Share flight") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Make a story from your flight.").font(.subheadline).foregroundStyle(theme.muted)
                preview
                HStack(spacing: 24) {
                    ForEach(styles) { option in
                        Button { withAnimation(.easeInOut(duration: 0.3)) { style = option }; copied = false } label: {
                            VStack(spacing: 7) {
                                Circle().fill(option == .light ? Color(hex: 0xEEF3F5) : option == .photo ? theme.cyan : Color(hex: 0x152B37))
                                    .frame(width: 42, height: 42)
                                    .overlay(Circle().stroke(style == option ? theme.accent : theme.line, lineWidth: style == option ? 3 : 1))
                                Text(option.title).font(.caption).foregroundStyle(style == option ? theme.accent : theme.muted)
                            }
                        }.buttonStyle(.plain).accessibilityLabel(option.title + " story style")
                    }
                    Spacer()
                    PhotosPicker(selection: $photo, matching: .images) {
                        VStack(spacing: 7) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 20)).frame(width: 42, height: 42).background(photoPickerBackground).clipShape(Circle())
                            Text(photoPickerTitle).font(.caption)
                        }
                    }.disabled(importing)
                }
                if ownedPhotos.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(ownedPhotos) { item in
                                if let image = photos.image(item) {
                                    Button {
                                        chosenPhoto = item.id; builder.setPhoto(image); style = .photo; copied = false
                                    } label: {
                                        Image(uiImage: image).resizable().scaledToFill().frame(width: 62, height: 62).clipped()
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(chosenPhoto == item.id ? theme.accent : theme.line, lineWidth: chosenPhoto == item.id ? 3 : 1))
                                    }.buttonStyle(.plain).accessibilityLabel("Use aircraft photo as story background")
                                }
                            }
                        }.padding(3)
                    }
                }
                Text("1080 × 1920 · Distance is the sum of straight-line route legs, not a recorded GPS track.").font(.caption).foregroundStyle(theme.muted)
                Button {
                    guard let image = builder.stories[style] else { return }
                    Task { @MainActor in
                        savingPhoto = true; defer { savingPhoto = false }
                        do { try await StoryPhotoSaver.save(image); problem = "Saved to Photos." }
                        catch { problem = error.localizedDescription }
                    }
                } label: { Label(savingPhoto ? "Saving…" : "Save to Photos", systemImage: "square.and.arrow.down").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(14).background(theme.raised).clipShape(Capsule()) }
                    .disabled(savingPhoto || builder.working || builder.stories[style] == nil)
                HStack(spacing: 12) {
                    Button { export() } label: {
                        Label("Share image", systemImage: "square.and.arrow.up").font(.system(size: 16, weight: .bold))
                            .frame(maxWidth: .infinity).padding(.vertical, 15).foregroundStyle(Color.black).background(theme.accent).clipShape(Capsule())
                    }.buttonStyle(.plain)
                    Button {
                        if let image = builder.stories[style] { UIPasteboard.general.image = image; copied = true }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 15, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 15)
                            .background(theme.raised).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }.disabled(builder.working || builder.stories[style] == nil)
            }
        }
        .task {
            photos.loadSaved(flight.registration); selectBackground()
            await builder.prepare(flight, catalog: catalog)
        }
        .onDisappear { builder.cancel() }
        .onChange(of: ownedPhotos.map(\.id)) { _, _ in selectBackground() }
        .onChange(of: style) { _, _ in copied = false }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task { @MainActor in
                importing = true; defer { importing = false; photo = nil }
                guard let data = try? await item.loadTransferable(type: Data.self), let image = AircraftPhotos.decodedPhoto(data) else {
                    problem = "The selected photo could not be read."; return
                }
                guard photos.add(image, registration: flight.registration) else { problem = photos.errorMessage ?? "The photo could not be saved."; return }
                chosenPhoto = photos.galleries[flight.registration]?.first?.id
                builder.setPhoto(image); style = .photo; copied = false
            }
        }
        .sheet(item: $share) { ShareSheet(items: [$0.image]) }
        .alert("Share flight", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) { problem = nil }
        } message: { Text(problem ?? "") }
    }
    @ViewBuilder private var preview: some View {
        if builder.working {
            VStack(spacing: 14) { ProgressView().tint(theme.accent); Text("Preparing your route map…").foregroundStyle(theme.muted) }
                .frame(maxWidth: .infinity).frame(height: 480).background(theme.raised).clipShape(RoundedRectangle(cornerRadius: 24))
        } else if let message = builder.message {
            VStack(spacing: 15) {
                Image(systemName: "map").font(.system(size: 38)).foregroundStyle(theme.accent)
                Text(message).multilineTextAlignment(.center).foregroundStyle(theme.muted)
                Button("Try again") { Task { await builder.prepare(flight, catalog: catalog) } }.foregroundStyle(theme.accent).fontWeight(.bold)
            }.padding(24).frame(maxWidth: .infinity).frame(height: 360).background(theme.raised).clipShape(RoundedRectangle(cornerRadius: 24))
        } else {
            TabView(selection: $style) {
                ForEach(styles) { option in
                    if let image = builder.stories[option] {
                        Image(uiImage: image).resizable().scaledToFit().padding(.bottom, 32).tag(option)
                            .accessibilityLabel("\(option.title) flight story preview")
                    }
                }
            }.tabViewStyle(.page(indexDisplayMode: .always)).frame(height: 480)
        }
    }
    private func selectBackground() {
        let item = ownedPhotos.first { $0.id == chosenPhoto } ?? ownedPhotos.first
        chosenPhoto = item?.id
        builder.setPhoto(item.flatMap { photos.image($0) } ?? PhotoStore.load(flight).first)
        if !builder.hasPhoto, style == .photo { style = .midnight }
    }
    private func export() {
        guard let image = builder.stories[style] else { problem = "The story image could not be created."; return }
        share = ShareImage(image: image)
    }
}

// MARK: - More, OCR review, CSV and PDF exports
