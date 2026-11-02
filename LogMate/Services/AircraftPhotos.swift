// The aircraft photo service: photo quality/candidate/source definitions,
// the photo processor, the gallery item model, and the Photos store object
// that fetches, caches and persists public aircraft photos.
import Foundation
import UIKit
import ImageIO
import CryptoKit

nonisolated struct AircraftPhotoQuality: Codable, Sendable {
    static let currentVersion = 4
    let width: Int
    let height: Int
    let sharpness: Double
    let differenceHash: UInt64
    let averageHash: UInt64
    let version: Int
    var sufficientPixels: Bool { max(width, height) >= 1600 && min(width, height) >= 900 }
    // This rejects visibly soft/upscaled previews. It is a quality heuristic,
    // not a claim that pixel count or a single score can prove a photo is sharp.
    var acceptable: Bool { sufficientPixels && sharpness >= 20 && version == Self.currentVersion }
    var rank: Double { acceptable ? log1p(sharpness) * sqrt(Double(width) * Double(height)) : 0 }
    func sameImage(as other: AircraftPhotoQuality) -> Bool {
        (differenceHash ^ other.differenceHash).nonzeroBitCount <= 2 &&
        (averageHash ^ other.averageHash).nonzeroBitCount <= 2
    }
    static func edgeEnergy(_ pixels: [UInt8], width: Int, height: Int) -> Double {
        guard width > 2, height > 2, pixels.count == width * height else { return 0 }
        var sum = 0.0, square = 0.0, count = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let edge = Double(Int(pixels[i - 1]) + Int(pixels[i + 1]) + Int(pixels[i - width]) + Int(pixels[i + width]) - 4 * Int(pixels[i]))
                sum += edge; square += edge * edge; count += 1
            }
        }
        return max(0, square / count - pow(sum / count, 2))
    }
}

nonisolated struct AircraftPhotoCandidate: Sendable {
    let url: URL
    let page: URL
    let credit: String
    let license: URL?
    let date: Date?
}

nonisolated enum AircraftPhotoSource {
    static func matchesTail(_ text: String, registration: String) -> Bool {
        let normalized = text.uppercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: " ")
        let tail = NSRegularExpression.escapedPattern(for: registration.replacingOccurrences(of: "-", with: ""))
        return normalized.range(of: "(?<![A-Z0-9])" + tail + "(?![A-Z0-9])", options: .regularExpression) != nil
    }
    static func airportURL(_ raw: String, base: URL) -> URL? {
        let text = WebData.plainEntities(raw).replacingOccurrences(of: "\\/", with: "/")
        guard let resolved = URL(string: text, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true),
              let host = components.host?.lowercased(), ["airport-data.com", "www.airport-data.com", "image.airport-data.com"].contains(host),
              components.user == nil, components.password == nil, components.port == nil,
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { return nil }
        components.scheme = "https"; components.fragment = nil
        if host == "www.airport-data.com" { components.host = "airport-data.com" }
        if components.path.hasSuffix(".html") { components.path = String(components.path.dropLast(5)) }
        return components.url
    }
    static func links(_ html: String, base: URL) -> [URL] {
        var seen = Set<String>()
        return WebData.matches(#"href\s*=\s*["']([^"']+)["']"#, in: html).compactMap {
            guard let url = airportURL($0, base: base), seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }
    static func isPhotoPage(_ url: URL) -> Bool {
        url.host == "airport-data.com" && url.path.range(of: #"^/aircraft/photo/[0-9]+$"#, options: .regularExpression) != nil
    }
    static func isGallery(_ url: URL, registration: String) -> Bool {
        guard url.host == "airport-data.com" else { return false }
        let parts = url.path.split(separator: "/")
        guard parts.count >= 3, parts[0] == "aircraft", parts[1] == "photos" else { return false }
        let galleryID = String(parts[2])
        let decodedID = galleryID.removingPercentEncoding ?? galleryID
        let tail = decodedID.split(separator: ":").first.map(String.init) ?? ""
        return tail.uppercased().replacingOccurrences(of: "-", with: "") == registration.uppercased().replacingOccurrences(of: "-", with: "")
    }
    static func photoPages(_ html: String, base: URL) -> [URL] { links(html, base: base).filter(isPhotoPage) }
    static func galleries(_ html: String, base: URL, registration: String) -> [URL] {
        links(html, base: base).filter { isGallery($0, registration: registration) }
    }
    static func detail(_ encoded: String, page: URL, registration: String) -> AircraftPhotoCandidate? {
        let html = WebData.plainEntities(encoded)
        let photoID = page.lastPathComponent
        func verifiedImage(_ raw: String) -> URL? {
            guard let url = airportURL(raw, base: page), url.host == "image.airport-data.com",
                  url.path.hasPrefix("/aircraft/"), !url.path.lowercased().contains("thumb"),
                  url.deletingPathExtension().lastPathComponent == photoID else { return nil }
            return url
        }
        let scripts = WebData.matches(#"<script\b[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#, in: html)
        func imageObjects(_ value: Any) -> [[String: Any]] {
            if let list = value as? [Any] { return list.flatMap(imageObjects) }
            guard let object = value as? [String: Any] else { return [] }
            let type = object["@type"] as? String ?? ""
            if type == "ImageObject" { return [object] }
            return (object["@graph"] as? [Any] ?? []).flatMap(imageObjects)
        }
        for script in scripts {
            guard let data = script.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) else { continue }
            for image in imageObjects(value) {
                let identity = [image["name"] as? String, image["description"] as? String].compactMap { $0 }.joined(separator: " ")
                guard matchesTail(identity, registration: registration), let raw = image["contentUrl"] as? String, let url = verifiedImage(raw) else { continue }
                let creator = (image["creator"] as? [String: Any])?["name"] as? String
                let credit = image["creditText"] as? String ?? creator ?? "Airport-Data photographer"
                let date = (image["dateCreated"] as? String).flatMap { ISO8601DateFormatter().date(from: $0 + "T12:00:00Z") }
                return AircraftPhotoCandidate(url: url, page: page, credit: "Airport-Data · " + WebData.plain(credit),
                    license: (image["license"] as? String).flatMap(URL.init(string:)), date: date)
            }
        }
        // Legacy pages: validate the primary heading/description, not the related-photo grid.
        let primary = WebData.matches(#"<h1\b[^>]*>(.*?)</h1>"#, in: html).first ??
            WebData.matches(#"<title\b[^>]*>(.*?)</title>"#, in: html).first ?? ""
        guard matchesTail(WebData.plain(primary), registration: registration),
              let raw = WebData.matches(#"["']((?:https:)?//image\.airport-data\.com/aircraft/[^"'<>\s]+)["']"#, in: html).first,
              let url = verifiedImage(raw) else { return nil }
        let photographer = WebData.matches(#"photo by\s+([^<"\n]+)"#, in: primary).first ?? "Airport-Data photographer"
        return AircraftPhotoCandidate(url: url, page: page, credit: "Airport-Data · " + WebData.plain(photographer), license: nil, date: nil)
    }
}

nonisolated struct ProcessedAircraftPhoto: Sendable {
    let data: Data
    let quality: AircraftPhotoQuality
}

actor AircraftPhotoProcessor {
    static let shared = AircraftPhotoProcessor()
    func process(_ data: Data) -> ProcessedAircraftPhoto? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 3200, kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary), max(image.width, image.height) >= 1600,
                  min(image.width, image.height) >= 900 else { return nil }
            func gray(_ width: Int, _ height: Int) -> [UInt8] {
                var pixels = [UInt8](repeating: 0, count: width * height)
                pixels.withUnsafeMutableBytes { buffer in
                    if let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                        bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                        context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    }
                }
                return pixels
            }
            let sampleScale = 320.0 / Double(max(image.width, image.height))
            let sampleWidth = max(32, Int(Double(image.width) * sampleScale))
            let sampleHeight = max(32, Int(Double(image.height) * sampleScale))
            let sharpness = AircraftPhotoQuality.edgeEnergy(gray(sampleWidth, sampleHeight), width: sampleWidth, height: sampleHeight)
            let difference = gray(9, 8), average = gray(8, 8), mean = Double(average.reduce(0) { $0 + Int($1) }) / 64
            var differenceHash: UInt64 = 0, averageHash: UInt64 = 0
            for y in 0..<8 {
                for x in 0..<8 {
                    let bit = UInt64(1) << UInt64(y * 8 + x)
                    if difference[y * 9 + x] > difference[y * 9 + x + 1] { differenceHash |= bit }
                    if Double(average[y * 8 + x]) > mean { averageHash |= bit }
                }
            }
            let quality = AircraftPhotoQuality(width: image.width, height: image.height, sharpness: sharpness,
                differenceHash: differenceHash, averageHash: averageHash, version: AircraftPhotoQuality.currentVersion)
            guard quality.acceptable else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return ProcessedAircraftPhoto(data: output as Data, quality: quality)
        }
    }
}

struct AircraftGalleryItem: Identifiable, Codable {
    var id = UUID()
    var filename: String
    var addedAt = Date()
    var userAdded: Bool
    var credit: String
    var link: URL? = nil
    var checksum: String? = nil
    var quality: AircraftPhotoQuality? = nil
    var imageURL: URL? = nil
    var licenseURL: URL? = nil
    var photoDate: Date? = nil
}

@MainActor final class AircraftPhotos: ObservableObject {
    @Published private(set) var images: [String: UIImage] = [:]
    @Published private(set) var galleries: [String: [AircraftGalleryItem]] = [:]
    @Published private(set) var sources: [String: String] = [:]
    @Published private(set) var links: [String: URL] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published var errorMessage: String?
    private var jobs: [String: Task<Void, Never>] = [:]
    private var retryAfter: [String: Date] = [:]
    @Published private(set) var lookupNotes: [String: String] = [:]
    private var hydrated: Set<String> = []
    private var unreadable: Set<String> = []
    private let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private var folder: URL {
        let url = PhotoStore.folder.appendingPathComponent("Aircraft", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func manifest(_ registration: String) -> URL {
        folder.appendingPathComponent(PhotoStore.safe(registration) + "-gallery.json")
    }
    func image(_ item: AircraftGalleryItem) -> UIImage? {
        if let cached = imageCache.object(forKey: item.filename as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: folder.appendingPathComponent(item.filename).path) else { return nil }
        cacheImage(image, filename: item.filename)
        return image
    }
    private func cacheImage(_ image: UIImage, filename: String) {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        imageCache.setObject(image, forKey: filename as NSString, cost: Int(min(CGFloat(Int.max / 4), max(0, pixels))) * 4)
    }
    private func hydrate(_ registration: String) {
        guard !hydrated.contains(registration) else { return }
        hydrated.insert(registration)
        let url = manifest(registration)
        if FileManager.default.fileExists(atPath: url.path) {
            do { galleries[registration] = try JSONDecoder().decode([AircraftGalleryItem].self, from: Data(contentsOf: url)) }
            catch {
                unreadable.insert(registration)
                errorMessage = "The saved photo gallery for \(registration) could not be read. Its files have been retained."
            }
        } else {
            // Migrate the previous single-photo cache without replacing or deleting its image.
            let filename = PhotoStore.safe(registration) + ".jpg"
            if let image = UIImage(contentsOfFile: folder.appendingPathComponent(filename).path) {
                let credit = UserDefaults.standard.string(forKey: "photoCredit-" + registration) ?? "Your photo"
                let item = AircraftGalleryItem(filename: filename, userAdded: credit == "Your photo", credit: credit,
                    link: UserDefaults.standard.url(forKey: "photoLink-" + registration))
                cacheImage(image, filename: filename)
                _ = persist([item], registration: registration)
            } else { galleries[registration] = [] }
        }
        refreshCover(registration)
    }
    private func refreshCover(_ registration: String) {
        let first = (galleries[registration] ?? []).first { image($0) != nil }
        images[registration] = first.flatMap { image($0) }
        sources[registration] = first?.credit
        links[registration] = first?.link
    }
    @discardableResult private func persist(_ items: [AircraftGalleryItem], registration: String) -> Bool {
        guard !unreadable.contains(registration) else { errorMessage = "Restore this aircraft's unreadable gallery before changing its photos."; return false }
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: manifest(registration), options: .atomic)
            galleries[registration] = items; refreshCover(registration)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func loadSaved(_ input: String) {
        let registration = AircraftNames.registration(input)
        if !registration.isEmpty { hydrate(registration) }
    }
    static func decodedPhoto(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3200,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return UIImage(data: data) }
        return UIImage(cgImage: cg)
    }
    @discardableResult func add(_ image: UIImage, registration input: String) -> Bool {
        let registration = AircraftNames.registration(input)
        guard !registration.isEmpty else { errorMessage = "Choose an aircraft before adding its photos."; return false }
        hydrate(registration)
        return savePhoto(image, registration: registration, userAdded: true, credit: "Your photo", link: nil)
    }
    static let maximumPhotos = 5
    func visibleItems(_ registration: String) -> [AircraftGalleryItem] {
        // Preserve old overflow photos on disk; every gallery displays at most five.
        Array((galleries[AircraftNames.registration(registration)] ?? []).prefix(Self.maximumPhotos))
    }
    static func isDetailQuality(_ image: UIImage) -> Bool {
        let width = image.size.width * image.scale, height = image.size.height * image.scale
        return max(width, height) >= 1600 && min(width, height) >= 900
    }
    private func publicGalleryComplete(_ registration: String) -> Bool {
        let items = visibleItems(registration)
        return items.count >= Self.maximumPhotos && items.allSatisfy { $0.userAdded || $0.quality?.acceptable == true }
    }
    private func savePhoto(_ image: UIImage, registration: String, userAdded: Bool, credit: String, link: URL?) -> Bool {
        guard !unreadable.contains(registration), let data = image.jpegData(compressionQuality: 0.95) else { return false }
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var items = galleries[registration] ?? []
        if let index = items.firstIndex(where: { $0.checksum == checksum }) {
            if userAdded {
                // An uploaded copy can be managed/deleted by its uploader, while
                // retaining the original public source attribution if present.
                if !items[index].userAdded {
                    guard items.filter(\.userAdded).count < Self.maximumPhotos else { return false }
                    items[index].userAdded = true
                    let item = items.remove(at: index); items.insert(item, at: 0)
                    return persist(items, registration: registration)
                }
                return makeCover(items[index].id, registration: registration)
            }
            return true
        }
        if userAdded && items.filter(\.userAdded).count >= Self.maximumPhotos {
            errorMessage = "An aircraft can have up to five photos. Delete one of your photos before adding another."; return false
        }
        // Upgrade a previously cached thumbnail using the same source page.
        if !userAdded, let link, let index = items.firstIndex(where: { !$0.userAdded && $0.link == link }) {
            if let existing = self.image(items[index]), Self.isDetailQuality(existing) { return true }
            items.remove(at: index)
        }
        if !userAdded {
            // Low-quality public images remain cached until a verified larger photo is available.
            items.removeAll { !$0.userAdded && self.image($0).map(Self.isDetailQuality) != true }
            guard items.count < Self.maximumPhotos else { return false }
        }
        let filename = PhotoStore.safe(registration) + "-" + UUID().uuidString + ".jpg"
        let url = folder.appendingPathComponent(filename)
        do { try data.write(to: url, options: .atomic) }
        catch { errorMessage = error.localizedDescription; return false }
        let item = AircraftGalleryItem(filename: filename, userAdded: userAdded, credit: credit, link: link, checksum: checksum)
        // Keep user photos first. A retry of the public lookup never replaces them.
        if userAdded {
            items.insert(item, at: 0)
            while items.count > Self.maximumPhotos, let index = items.lastIndex(where: { !$0.userAdded }) { items.remove(at: index) }
        } else { items.append(item) }
        cacheImage(image, filename: filename)
        if !persist(items, registration: registration) {
            imageCache.removeObject(forKey: filename as NSString); try? FileManager.default.removeItem(at: url); return false
        }
        return true
    }
    @discardableResult func makeCover(_ id: UUID, registration input: String) -> Bool {
        let registration = AircraftNames.registration(input); hydrate(registration)
        var items = galleries[registration] ?? []
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        let item = items.remove(at: index); items.insert(item, at: 0)
        return persist(items, registration: registration)
    }
    @discardableResult func delete(_ id: UUID, registration input: String) -> Bool {
        let registration = AircraftNames.registration(input); hydrate(registration)
        let items = galleries[registration] ?? []
        guard let item = items.first(where: { $0.id == id }), item.userAdded else { return false }
        guard persist(items.filter { $0.id != id }, registration: registration) else { return false }
        imageCache.removeObject(forKey: item.filename as NSString)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(item.filename))
        return true
    }
    func load(_ input: String, retry: Bool = false) async {
        let registration = AircraftNames.registration(input)
        guard !registration.isEmpty else { return }
        hydrate(registration)
        guard !unreadable.contains(registration) else { return }
        if let job = jobs[registration] { await job.value; return }
        if visibleItems(registration).filter(\.userAdded).count >= Self.maximumPhotos { return }
        let checked = UserDefaults.standard.double(forKey: "publicPhotoChecked-v4-" + registration)
        if !retry, publicGalleryComplete(registration), Date().timeIntervalSince1970 - checked < 7 * 86400 { return }
        if !retry, (retryAfter[registration] ?? .distantPast) > Date() { return }
        loading.insert(registration); lookupNotes[registration] = nil
        // Shared work survives scrolling away or switching tabs. A failed or
        // incomplete lookup can run again; it is not permanently marked attempted.
        let job = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchGallery(registration)
            self.loading.remove(registration); self.jobs.removeValue(forKey: registration)
            self.retryAfter[registration] = Date().addingTimeInterval(120)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "publicPhotoChecked-v4-" + registration)
        }
        jobs[registration] = job
        await job.value
    }
    private func savePublic(_ photo: ProcessedAircraftPhoto, candidate: AircraftPhotoCandidate, registration: String) -> Bool {
        guard !unreadable.contains(registration), photo.quality.acceptable else { return false }
        var items = galleries[registration] ?? []
        let checksum = SHA256.hash(data: photo.data).map { String(format: "%02x", $0) }.joined()
        let match = items.firstIndex { item in
            item.checksum == checksum || item.link == candidate.page || item.quality.map { photo.quality.sameImage(as: $0) } == true
        }
        if let match, items[match].userAdded { return true }
        if let match, let quality = items[match].quality, quality.acceptable, quality.rank >= photo.quality.rank * 0.95 { return true }
        let existingID = match.map { items[$0].id }
        if let match { items.remove(at: match) }
        // Preserve the old image files for recovery. The manifest switches to
        // the verified original only after its download and quality checks pass.
        items.removeAll { !$0.userAdded && $0.quality?.acceptable != true }
        if items.count >= Self.maximumPhotos {
            let publicIndices = items.indices.filter { !items[$0].userAdded }
            guard let worst = publicIndices.min(by: { (items[$0].quality?.rank ?? 0) < (items[$1].quality?.rank ?? 0) }) else { return false }
            let newer = candidate.date.map { $0 > (items[worst].photoDate ?? .distantPast) } ?? false
            guard newer || photo.quality.rank > (items[worst].quality?.rank ?? 0) * 1.15 else { return true }
            items.remove(at: worst)
        }
        let filename = PhotoStore.safe(registration) + "-" + UUID().uuidString + ".jpg"
        let url = folder.appendingPathComponent(filename)
        do { try photo.data.write(to: url, options: .atomic) } catch { errorMessage = error.localizedDescription; return false }
        var item = AircraftGalleryItem(filename: filename, userAdded: false, credit: candidate.credit, link: candidate.page, checksum: checksum)
        if let existingID { item.id = existingID }
        item.quality = photo.quality; item.imageURL = candidate.url; item.licenseURL = candidate.license; item.photoDate = candidate.date
        let insertion = items.firstIndex { !$0.userAdded && (candidate.date ?? .distantPast) > ($0.photoDate ?? .distantPast) }
        items.insert(item, at: insertion ?? items.count)
        guard persist(items, registration: registration) else { try? FileManager.default.removeItem(at: url); return false }
        return true
    }
    private func fetchGallery(_ registration: String) async {
        let initiallyComplete = publicGalleryComplete(registration)
        var photoPages: [URL] = [], galleries: [URL] = [], visitedGalleries = Set<String>()
        let profile = URL(string: "https://airport-data.com/aircraft/\(registration)")!
        if let data = try? await WebData.data(profile), let html = String(data: data, encoding: .utf8) {
            photoPages = AircraftPhotoSource.photoPages(html, base: profile)
            galleries = AircraftPhotoSource.galleries(html, base: profile, registration: registration)
        }
        // Registration-only lookup works even when FAA model lookup is offline.
        if photoPages.isEmpty, let api = URL(string: "https://airport-data.com/api/ac_thumb.json?r=\(registration)&n=10"),
           let json = await WebData.json(api), let rows = json["data"] as? [[String: Any]] {
            photoPages += rows.compactMap { row in
                guard let raw = row["link"] as? String, let url = AircraftPhotoSource.airportURL(raw, base: profile),
                      AircraftPhotoSource.isPhotoPage(url) else { return nil }
                return url
            }
        }
        if galleries.isEmpty { galleries = [URL(string: "https://airport-data.com/aircraft/photos/\(registration)/")!] }
        // Follow actual full-gallery and pagination links. Scope them to the
        // same registration/airframe gallery; never crawl unrelated galleries.
        while !galleries.isEmpty, visitedGalleries.count < 4 {
            let page = galleries.removeFirst()
            guard visitedGalleries.insert(page.absoluteString).inserted else { continue }
            guard let data = try? await WebData.data(page), let html = String(data: data, encoding: .utf8) else { continue }
            photoPages += AircraftPhotoSource.photoPages(html, base: page)
            let scope = page.path.split(separator: "/").prefix(3).joined(separator: "/")
            let next = AircraftPhotoSource.galleries(html, base: page, registration: registration).filter {
                $0.path.split(separator: "/").prefix(3).joined(separator: "/") == scope && !visitedGalleries.contains($0.absoluteString)
            }
            galleries += next
        }
        var seen = Set<String>()
        photoPages = Array(photoPages.filter { seen.insert($0.absoluteString).inserted }.prefix(24))
        // At most three originals are in flight. Decode, sharpness analysis and
        // perceptual hashing run on their own actor, not the UI actor.
        await withTaskGroup(of: (AircraftPhotoCandidate?, ProcessedAircraftPhoto?).self) { group in
            var iterator = photoPages.makeIterator()
            func add(_ page: URL) {
                group.addTask {
                    guard let data = try? await WebData.data(page), let html = String(data: data, encoding: .utf8),
                          let candidate = AircraftPhotoSource.detail(html, page: page, registration: registration),
                          let original = try? await WebData.data(candidate.url) else { return (nil, nil) }
                    return (candidate, await AircraftPhotoProcessor.shared.process(original))
                }
            }
            for _ in 0..<min(3, photoPages.count) { if let page = iterator.next() { add(page) } }
            while let (candidate, processed) = await group.next() {
                if let candidate, let processed { _ = savePublic(processed, candidate: candidate, registration: registration) }
                if publicGalleryComplete(registration) && !initiallyComplete { group.cancelAll(); break }
                if let page = iterator.next() { add(page) }
            }
        }
        if publicGalleryComplete(registration) { return }
        // Commons provides independently licensed originals as a fallback.
        var query = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        query.queryItems = [
            URLQueryItem(name: "action", value: "query"), URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: "\"\(registration)\""), URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "15"), URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|size|timestamp|extmetadata"), URLQueryItem(name: "iiurlwidth", value: "2400"),
            URLQueryItem(name: "format", value: "json")
        ]
        if let url = query.url, let json = await WebData.json(url),
           let q = json["query"] as? [String: Any], let pages = q["pages"] as? [String: Any] {
            func photoDate(_ value: Any) -> Date {
                guard let page = value as? [String: Any], let info = (page["imageinfo"] as? [[String: Any]])?.first else { return .distantPast }
                let metadata = info["extmetadata"] as? [String: [String: Any]]
                let original = WebData.plain(metadata?["DateTimeOriginal"]?["value"] as? String ?? "")
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.isLenient = false
                for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "d MMMM yyyy", "MMMM d, yyyy", "yyyy:MM:dd HH:mm:ss"] {
                    formatter.dateFormat = format
                    if let date = formatter.date(from: original) { return date }
                }
                return ISO8601DateFormatter().date(from: info["timestamp"] as? String ?? "") ?? .distantPast
            }
            let candidates = pages.values.sorted { photoDate($0) > photoDate($1) }
            for value in candidates {
                guard let page = value as? [String: Any], let title = page["title"] as? String,
                      AircraftPhotoSource.matchesTail(title, registration: registration),
                      let infos = page["imageinfo"] as? [[String: Any]], let info = infos.first,
                      let text = info["url"] as? String, let photoURL = URL(string: text) else { continue }
                if publicGalleryComplete(registration) { break }
                let metadata = (info["extmetadata"] as? [String: [String: Any]]) ?? [:]
                let artist = WebData.plain(metadata["Artist"]?["value"] as? String ?? "Wikimedia Commons")
                let license = (metadata["LicenseShortName"]?["value"] as? String) ?? ""
                let credit = [artist, license].filter { !$0.isEmpty }.joined(separator: " · ")
                guard !license.isEmpty, photoURL.host == "upload.wikimedia.org",
                      let page = (info["descriptionurl"] as? String).flatMap(URL.init(string:)),
                      let data = try? await WebData.data(photoURL), let photo = await AircraftPhotoProcessor.shared.process(data) else { continue }
                let candidate = AircraftPhotoCandidate(url: photoURL, page: page, credit: credit,
                    license: (metadata["LicenseUrl"]?["value"] as? String).flatMap(URL.init(string:)), date: photoDate(value))
                _ = savePublic(photo, candidate: candidate, registration: registration)
            }
        }
        let verified = visibleItems(registration).filter { $0.userAdded || $0.quality?.acceptable == true }.count
        if verified < Self.maximumPhotos {
            if verified == 0 {
                lookupNotes[registration] = visibleItems(registration).isEmpty ? "No suitable public photo was available. You can add your own." :
                    "No sharper public original was available. Your saved photo is retained."
            } else { lookupNotes[registration] = "Found \(verified) usable photos. Retry lookup or add your own." }
        }
    }
}
