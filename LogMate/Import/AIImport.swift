// AI photo-import: the endpoint/access-code configuration (Keychain-backed),
// request/response models, document preparation, the importer client with
// its session delegate, and the import settings screen.
import Foundation
import SwiftUI
import UIKit
import Security
import Vision

@MainActor enum AIImportConfiguration {
    static let urlKey = "logmateAIImportServiceURL"
    private static var keychainService: String { (Bundle.main.bundleIdentifier ?? "LogMate") + ".photo-import" }
    static var endpoint: String { UserDefaults.standard.string(forKey: urlKey) ?? "" }
    static var accessCode: String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: "access-code",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static var ready: Bool { (try? validate(endpoint: endpoint, accessCode: accessCode)) != nil }
    static func validate(endpoint: String, accessCode: String) throws -> URL {
        guard let components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              !host.lowercased().hasSuffix("openai.com"), let url = components.url else {
            throw AIImportFailure.message("Enter your HTTPS import-service address, for example https://your-service.workers.dev. This is the LogMate service, not the OpenAI API address.")
        }
        guard accessCode.range(of: "^lm_[A-Za-z0-9_-]{40,100}$", options: .regularExpression) != nil else {
            throw AIImportFailure.message("Enter the personal import access code supplied by your service. Do not enter an OpenAI API key here.")
        }
        return url
    }
    static func save(endpoint: String, accessCode: String) throws {
        _ = try validate(endpoint: endpoint, accessCode: accessCode)
        let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: "access-code"]
        let values: [String: Any] = [kSecValueData as String: Data(accessCode.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(identity as CFDictionary, values as CFDictionary)
        let final = status == errSecItemNotFound ? SecItemAdd(identity.merging(values) { _, new in new } as CFDictionary, nil) : status
        guard final == errSecSuccess else { throw AIImportFailure.message("The access code could not be saved securely on this device.") }
        UserDefaults.standard.set(endpoint.trimmingCharacters(in: .whitespacesAndNewlines), forKey: urlKey)
    }
    static func disconnect() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: "access-code"] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: urlKey)
    }
}

enum AIImportFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Reject redirects rather than forwarding a private access code to a different service.
private final class AIImportSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

struct AIPhotoInput: Encodable, Sendable {
    var label: String
    var imageBase64: String
    var mimeType: String
}
struct AITextHint: Encodable, Sendable {
    var text: String
    var confidence: Double
    // Normalized coordinates on the prepared FULL page, origin at the top left.
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}
struct AIPhotoPrepared: Sendable {
    var preview: Data
    var inputs: [AIPhotoInput]
    var textHints: [AITextHint]
    var qualityWarnings: [String] = []
}
struct AIPhotoRequest: Encodable {
    var kind: String
    var defaultYear: Int
    var timezone: String
    var images: [AIPhotoInput]
    var ocrHints: [AITextHint] = []
}

// All pixel processing and local OCR run off the UI thread. No extra model call is made.
nonisolated enum PhotoDocumentPreparation {
    static func regions(width: Double, height: Double) -> [CGRect] {
        if width >= height {
            return [CGRect(x: 0, y: 0, width: 0.58, height: 1), CGRect(x: 0.42, y: 0, width: 0.58, height: 1)]
        }
        return [CGRect(x: 0, y: 0, width: 1, height: 0.58), CGRect(x: 0, y: 0.42, width: 1, height: 0.58)]
    }
    static func qualityWarnings(_ cg: CGImage, words: [VNRecognizedTextObservation]) -> [String] {
        var warnings: [String] = []
        if max(cg.width, cg.height) < 1200 || min(cg.width, cg.height) < 450 {
            warnings.append("Low-resolution photo. Move closer or use Scan document; keep every column in view.")
        }
        let side = 160
        var pixels = [UInt8](repeating: 0, count: side * side)
        let measured = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        if measured {
            let brightness = pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count)
            if brightness < 55 { warnings.append("The page is dark. Use even lighting and avoid shadows over the writing.") }
            var sum = 0.0, square = 0.0, count = 0.0
            for y in 1..<(side - 1) {
                for x in 1..<(side - 1) {
                    let i = y * side + x
                    let laplacian = Double(pixels[i - 1]) + Double(pixels[i + 1]) + Double(pixels[i - side]) + Double(pixels[i + side]) - 4 * Double(pixels[i])
                    sum += laplacian; square += laplacian * laplacian; count += 1
                }
            }
            if square / count - pow(sum / count, 2) < 40 {
                warnings.append("Soft focus or little visible detail. Check that handwriting and landing columns are sharp before reading.")
            }
        }
        if words.count < 3 { warnings.append("Very little text was detected. Check focus, glare and whether the whole page is visible.") }
        return warnings
    }
    static func targetedRegions(_ words: [VNRecognizedTextObservation]) -> [(label: String, region: CGRect)] {
        var result: [(label: String, region: CGRect)] = []
        for (pattern, label) in [(#"\b(?:landings?|ldgs?)\b"#, "Landing-column detail; read its headings and every row."),
                                 (#"\b(?:remarks?|comments?|notes?)\b"#, "Remarks-column detail; keep notes attached to their row.")] {
            let boxes = words.filter { observation in
                let text = observation.topCandidates(1).first?.string ?? ""
                return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil && observation.boundingBox.midY > 0.45
            }.map(\.boundingBox)
            guard let first = boxes.first else { continue }
            let left = max(0, (boxes.map(\.minX).min() ?? first.minX) - 0.055)
            let right = min(1, (boxes.map(\.maxX).max() ?? first.maxX) + 0.075)
            let width = min(1 - left, max(label.hasPrefix("Remarks") ? 0.30 : 0.22, right - left))
            result.append((label, CGRect(x: left, y: 0, width: width, height: 1)))
        }
        return result
    }
    private static func recognized(_ cg: CGImage) throws -> [VNRecognizedTextObservation] {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.003
        try VNImageRequestHandler(cgImage: cg, orientation: .up).perform([request])
        return request.results ?? []
    }
    private static func image(_ input: CIImage, context: CIContext) throws -> CGImage {
        guard let cg = context.createCGImage(input, from: input.extent.integral) else { throw AIImportFailure.message("The photo could not be prepared.") }
        return cg
    }
    private static func jpeg(_ cg: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { throw AIImportFailure.message("The photo could not be prepared.") }
        CGImageDestinationAddImage(writer, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw AIImportFailure.message("The photo could not be prepared.") }
        return data as Data
    }
    private static func bounded(_ image: CIImage, longest: CGFloat) -> CIImage {
        let factor = min(1, longest / max(image.extent.width, image.extent.height))
        return image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
    }
    static func prepare(_ data: Data, schedule: Bool) throws -> AIPhotoPrepared {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw AIImportFailure.message("The selected image could not be opened.") }
        // ImageIO downsamples before decoding very large camera images and respects EXIF rotation.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw AIImportFailure.message("The selected image could not be opened.") }
        let context = CIContext(options: [.cacheIntermediates: false])
        var page = CIImage(cgImage: decoded)
        let initialText = (try? recognized(decoded)) ?? []
        if !schedule {
            let request = VNDetectRectanglesRequest()
            request.minimumAspectRatio = 0.15; request.maximumAspectRatio = 1
            request.minimumSize = 0.2; request.minimumConfidence = 0.75
            request.maximumObservations = 12; request.quadratureTolerance = 35
            try? VNImageRequestHandler(cgImage: decoded, orientation: .up).perform([request])
            // Open logbooks can occupy less than half of a camera photo's height.
            // Reject narrow single-page/table detections and crops that exclude recognized text.
            let useful = initialText.filter { ($0.topCandidates(1).first?.confidence ?? 0) >= 0.35 }
            let anchors = useful.filter { observation in
                let text = observation.topCandidates(1).first?.string ?? ""
                return text.range(of: #"\b\d{1,2}[/.-]\d{1,2}(?:[/.-]\d{2,4})?\b|\bN\d{1,5}[A-Z]{0,2}\b|\b(?:date|total|landings|remarks|dual|pilot)\b"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
            }
            let candidates = (request.results ?? []).filter { candidate in
                let rect = candidate.boundingBox
                guard rect.width >= 0.65, rect.height >= 0.22, rect.width * rect.height >= 0.20 else { return false }
                let expanded = rect.insetBy(dx: -0.025, dy: -0.025)
                guard anchors.allSatisfy({ expanded.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }) else { return false }
                return useful.isEmpty || Double(useful.filter { expanded.contains(CGPoint(x: $0.boundingBox.midX, y: $0.boundingBox.midY)) }.count) / Double(useful.count) >= 0.95
            }
            if let rectangle = candidates.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                let center = CGPoint(x: rectangle.boundingBox.midX, y: rectangle.boundingBox.midY)
                func corner(_ p: CGPoint) -> CIVector {
                    // A small margin protects handwriting touching the page edges.
                    let x = min(1, max(0, center.x + (p.x - center.x) * 1.025))
                    let y = min(1, max(0, center.y + (p.y - center.y) * 1.025))
                    return CIVector(x: x * page.extent.width + page.extent.minX, y: y * page.extent.height + page.extent.minY)
                }
                let corrected = page.applyingFilter("CIPerspectiveCorrection", parameters: ["inputTopLeft": corner(rectangle.topLeft), "inputTopRight": corner(rectangle.topRight), "inputBottomLeft": corner(rectangle.bottomLeft), "inputBottomRight": corner(rectangle.bottomRight)])
                if corrected.extent.width >= 300, corrected.extent.height >= 120 { page = corrected }
            }
        }
        page = bounded(page, longest: 4096)
        var full = try image(page, context: context)
        var words = (try? recognized(full)) ?? []
        func legibility(_ words: [VNRecognizedTextObservation]) -> Double {
            words.reduce(0) { $0 + Double($1.topCandidates(1).first?.confidence ?? 0) * Double(min(50, $1.topCandidates(1).first?.string.count ?? 0)) }
        }
        // Recover sideways/upside-down photos only when OCR provides a clearly stronger orientation.
        if legibility(words) < 160 {
            var best = legibility(words)
            for orientation in [CGImagePropertyOrientation.right, .down, .left] {
                try Task.checkCancellation()
                let candidate = page.oriented(orientation)
                let cg = try image(candidate, context: context)
                let text = (try? recognized(cg)) ?? []
                let score = legibility(text)
                if score > best * 1.35 + 20 { best = score; full = cg; words = text }
            }
            page = CIImage(cgImage: full)
        }
        // Mild adjustments retain faint pen strokes; no aggressive thresholding or invented details.
        let enhanced = page.applyingFilter("CIColorControls", parameters: ["inputContrast": 1.08, "inputBrightness": 0.015, "inputSaturation": 0.95])
            .applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": 0.18]).cropped(to: page.extent)
        full = try image(enhanced, context: context)
        let regions = regions(width: Double(full.width), height: Double(full.height))
        let quality = qualityWarnings(full, words: words)
        var images = [full]
        var labels = ["Full prepared page; use this to count and order rows."]
        var hints: [AITextHint] = []
        func appendHints(_ observations: [VNRecognizedTextObservation], region: CGRect) {
            for observation in observations {
                guard let text = observation.topCandidates(1).first, text.confidence >= 0.3, !text.string.isEmpty else { continue }
                let box = observation.boundingBox
                let hint = AITextHint(text: String(text.string.prefix(180)), confidence: Double((text.confidence * 100).rounded()) / 100,
                    x: Double(region.minX + box.minX * region.width), y: Double(region.minY + (1 - box.maxY) * region.height),
                    width: Double(box.width * region.width), height: Double(box.height * region.height))
                if !hints.contains(where: { $0.text == hint.text && abs($0.x - hint.x) < 0.025 && abs($0.y - hint.y) < 0.025 }) { hints.append(hint) }
            }
        }
        appendHints(words, region: CGRect(x: 0, y: 0, width: 1, height: 1))
        let details = regions.enumerated().map { (label: "Overlapping detail \($0.offset + 1) of the SAME page, not another page.", region: $0.element) }
            + (schedule ? [] : targetedRegions(words))
        for detail in details {
            let region = detail.region
            try Task.checkCancellation()
            let rect = CGRect(x: region.minX * CGFloat(full.width), y: region.minY * CGFloat(full.height), width: region.width * CGFloat(full.width), height: region.height * CGFloat(full.height)).integral
            guard let crop = full.cropping(to: rect) else { continue }
            appendHints((try? recognized(crop)) ?? [], region: region)
            // Enlarge a small crop for legibility without exceeding the API's high-detail dimension.
            let factor = min(2, 2048 / CGFloat(max(crop.width, crop.height)))
            images.append(factor > 1 ? try image(CIImage(cgImage: crop).transformed(by: CGAffineTransform(scaleX: factor, y: factor)), context: context) : crop)
            labels.append(detail.label)
        }
        guard images.count >= 3, images.count <= 5 else { throw AIImportFailure.message("The detail crops could not be prepared. Choose another photo.") }
        var encoded: [Data] = []
        for quality in [0.92, 0.86, 0.78] {
            encoded = try images.map { try jpeg($0, quality: quality) }
            if encoded.reduce(0, { $0 + $1.count }) <= 7_500_000 { break }
        }
        guard encoded.reduce(0, { $0 + $1.count }) <= 7_500_000 else { throw AIImportFailure.message("This photo is too large. Choose one page or a smaller section.") }
        var textSize = 0
        hints = hints.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }.filter { hint in
            textSize += hint.text.utf8.count; return textSize <= 6000
        }
        return AIPhotoPrepared(preview: encoded[0], inputs: zip(labels, encoded).map { AIPhotoInput(label: $0, imageBase64: $1.base64EncodedString(), mimeType: "image/jpeg") }, textHints: Array(hints.prefix(80)), qualityWarnings: quality)
    }
}
struct AIImageBounds: Decodable {
    var x: Double; var y: Double; var width: Double; var height: Double
    var rect: CGRect? {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1.001, y + height <= 1.001 else { return nil }
        return CGRect(x: x, y: y, width: min(width, 1 - x), height: min(height, 1 - y))
    }
}
struct AIPhotoEntry: Decodable {
    var rowNumber: Int
    var sourceText: String
    var warnings: [String]
    var inferredFields: [String]
    var uncertainFields: [String]
    var inheritedRegistration: Bool
    var inheritedModel: Bool
    var sourceBounds: AIImageBounds?
    var date: String?
    var endDate: String?
    var startTime: String?
    var endTime: String?
    var registration: String?
    var makeModel: String?
    var notes: String?
    var pilotName: String?
    var instructorName: String?
    var resource: String?
    var sourceId: String?
    var title: String?
    var approaches: String?
    var category: String?
    var activityType: String?
    var route: [String]?
    var totalHours: Double?
    var picHours: Double?
    var nightHours: Double?
    var actualInstrumentHours: Double?
    var simulatedInstrumentHours: Double?
    var dualReceivedHours: Double?
    var instructorHours: Double?
    var crossCountryHours: Double?
    var soloHours: Double?
    var dayHours: Double?
    var dayLandings: Int?
    var nightLandings: Int?
    var unclassifiedLandings: Int?
    var approachCount: Int?
    var holds: Int?
}
struct AIPageTotals: Decodable {
    var totalHours: Double?
    var dualReceivedHours: Double?
    var picHours: Double?
    var dayHours: Double?
    var landings: Int?
}
struct AIPhotoResult: Decodable {
    var schemaVersion: Int
    var kind: String
    var visibleEntryCount: Int?
    var pageWarnings: [String]
    var entries: [AIPhotoEntry]
    var pageTotals: AIPageTotals?
}

@MainActor enum AIPhotoImporter {
    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 210; config.timeoutIntervalForResource = 240
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: AIImportSessionDelegate(), delegateQueue: nil)
    }
    private static func call(_ request: URLRequest) async throws -> Data {
        let session = session(); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AIImportFailure.message("The import service returned an unreadable response.") }
        guard (200...299).contains(http.statusCode) else {
            struct ErrorReply: Decodable { var error: String }
            let message = (try? JSONDecoder().decode(ErrorReply.self, from: data).error)
            throw AIImportFailure.message(message ?? "The AI import service returned an error (\(http.statusCode)). Check its address and access code.")
        }
        guard data.count <= 4 * 1024 * 1024 else { throw AIImportFailure.message("Too much data was returned. Import a smaller section of the page.") }
        return data
    }
    static func connection(endpoint: String, accessCode: String) async throws {
        let base = try AIImportConfiguration.validate(endpoint: endpoint, accessCode: accessCode)
        var request = URLRequest(url: base.appendingPathComponent("v1/connection"))
        request.setValue("Bearer " + accessCode, forHTTPHeaderField: "Authorization")
        struct Connection: Decodable { var schemaVersion: Int; var ready: Bool }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let reply = try decoder.decode(Connection.self, from: await call(request))
        guard reply.schemaVersion == 1, reply.ready else { throw AIImportFailure.message("The service is not ready for image imports.") }
    }
    static func prepareImage(_ data: Data, schedule: Bool = false) async throws -> AIPhotoPrepared {
        let task = Task.detached(priority: .userInitiated) { try PhotoDocumentPreparation.prepare(data, schedule: schedule) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    static func read(_ inputs: [AIPhotoInput], schedule: Bool, year: Int, ocrHints: [AITextHint] = []) async throws -> AIPhotoResult {
        let code = AIImportConfiguration.accessCode
        let base = try AIImportConfiguration.validate(endpoint: AIImportConfiguration.endpoint, accessCode: code)
        var request = URLRequest(url: base.appendingPathComponent("v1/import")); request.httpMethod = "POST"
        request.setValue("Bearer " + code, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        request.httpBody = try encoder.encode(AIPhotoRequest(kind: schedule ? "schedule" : "logbook", defaultYear: year, timezone: TimeZone.current.identifier, images: inputs, ocrHints: ocrHints))
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let result = try decoder.decode(AIPhotoResult.self, from: await call(request))
        guard result.schemaVersion == 1, result.kind == (schedule ? "schedule" : "logbook"), result.entries.count <= 100 else {
            throw AIImportFailure.message("The AI returned an incompatible result. Check the import service version.")
        }
        return result
    }
    // Map extracted values to editable drafts. Nothing is saved here.
    static func drafts(_ result: AIPhotoResult) -> [ScanFlightDraft] {
        result.entries.map { entry in
            var warnings = result.pageWarnings + entry.warnings
            var issues = entry.uncertainFields.compactMap { name -> ScanFieldIssue? in
                guard let field = ScanReviewFields.key(name) else { return nil }
                return ScanFieldIssue(field: field, message: "Check " + ScanReviewFields.title(field).lowercased() + " against the photo.")
            }
            if entry.inheritedRegistration { issues.append(ScanFieldIssue(field: "registration", message: "Check the repeated registration against this row.")) }
            if !entry.inferredFields.isEmpty {
                let names = entry.inferredFields.map { ScanReviewFields.key($0).map(ScanReviewFields.title) ?? $0.replacingOccurrences(of: "_", with: " ") }
                warnings.append("Read using headings, shorthand or repeated values: " + names.joined(separator: ", ") + ".")
            }
            let route = (entry.route ?? []).joined(separator: " → ")
            let registration = entry.registration ?? ""
            var unresolved: Set<String> = []
            if FlightDates.parse(entry.date ?? "") == nil { unresolved.insert("date"); warnings.append("Date was not read. Choose it from the source photo before saving.") }
            if result.kind == "schedule" {
                var item = ScheduledFlight()
                let parsedStart = localDate(entry.date, clock: entry.startTime)
                item.date = parsedStart ?? localDate(entry.date, clock: "00:00") ?? Date()
                if entry.startTime == nil || (entry.date != nil && parsedStart == nil) { unresolved.insert("start"); warnings.append("Start time was not read. Set it before saving; the displayed time is a placeholder.") }
                item.activityType = entry.activityType ?? "flight"
                if item.activityType == "ground" { item.registration = ""; item.resource = "GROUND"; item.route = "" }
                else { item.registration = registration; item.route = route; item.resource = entry.resource }
                item.title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if item.title.isEmpty { item.title = item.isGround ? "Ground lesson" : "Flight" }
                item.estimatedTime = entry.totalHours ?? 0
                if let end = localDate(entry.endDate ?? entry.date, clock: entry.endTime), end > item.date { item.endDate = end }
                else if entry.endTime != nil { warnings.append("End time could not be placed after the start. Check the date and time before including it.") }
                item.pilotName = entry.pilotName; item.instructorName = entry.instructorName
                item.notes = entry.notes; item.sourceScheduleID = entry.sourceId
                return ScanFlightDraft(schedule: item, sourceText: entry.sourceText, sourceBounds: entry.sourceBounds?.rect,
                    warnings: Array(Set(warnings)).sorted(), repeatsRegistration: entry.inheritedRegistration,
                    repeatsModel: entry.inheritedModel, unresolvedFields: unresolved, issues: ScanReviewFields.unique(issues))
            }
            var flight = Flight()
            flight.date = entry.date ?? ""; flight.aircraft = registration + " · " + (entry.makeModel ?? "")
            flight.route = route; flight.duration = entry.totalHours.map(editableHours) ?? "0.0"
            if entry.totalHours == nil { warnings.append("Total time was not read. You can leave it blank.") }
            flight.pic = entry.picHours ?? 0; flight.night = entry.nightHours ?? 0
            flight.imc = entry.actualInstrumentHours ?? 0; flight.simulatedInstrument = entry.simulatedInstrumentHours ?? 0
            flight.dual = entry.dualReceivedHours ?? 0; flight.instructor = entry.instructorHours ?? 0
            flight.crossCountry = entry.crossCountryHours ?? 0; flight.progress["solo"] = entry.soloHours ?? 0
            flight.dayLandings = entry.dayLandings ?? 0; flight.nightLandings = entry.nightLandings ?? 0
            flight.approachCount = entry.approachCount ?? 0; flight.holds = entry.holds ?? 0
            flight.approaches = entry.approaches ?? ""; flight.category = entry.category ?? "Unspecified"
            flight.notes = entry.notes ?? ""
            if let landings = entry.unclassifiedLandings, landings > 0 {
                issues.append(ScanFieldIssue(field: "landings", message: "Assign \(landings) landings to day / night."))
                flight.facts.counts["unclassifiedLandings"] = landings
                flight.facts.counts["importedLandingTotal"] = flight.landings + landings
            }
            if let day = entry.dayHours { flight.facts.amounts["importedDayHours"] = day }
            if let cfi = entry.instructorName, !cfi.isEmpty {
                flight.facts.text["importedInstructorName"] = cfi
            }
            // Preserve source interpretation with the saved flight for later auditing; never fabricate a signature/endorsement.
            flight.facts.text["photoImportSource"] = entry.sourceText
            flight.facts.text["photoImportMethod"] = "AI image interpretation"
            flight.facts.text["photoImportInferences"] = entry.inferredFields.joined(separator: ", ")
            flight.facts.text["photoImportUncertainty"] = entry.uncertainFields.joined(separator: ", ")
            flight.facts.text["photoImportWarnings"] = warnings.joined(separator: "\n")
            return ScanFlightDraft(flight: flight, sourceText: entry.sourceText, sourceBounds: entry.sourceBounds?.rect,
                warnings: Array(Set(warnings)).sorted(), repeatsRegistration: entry.inheritedRegistration,
                repeatsModel: entry.inheritedModel, unresolvedFields: unresolved, issues: ScanReviewFields.unique(issues))
        }
    }
    private static func localDate(_ date: String?, clock: String?) -> Date? {
        guard let date, let clock else { return nil }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd HH:mm"; formatter.isLenient = false
        let raw = date + " " + clock
        guard let result = formatter.date(from: raw), formatter.string(from: result) == raw else { return nil }
        return result
    }
}

@MainActor struct AIImportSettings: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) var dismiss
    @State private var endpoint = AIImportConfiguration.endpoint
    @State private var accessCode = AIImportConfiguration.accessCode
    @State private var message = ""
    @State private var checking = false
    @State private var connectionTask: Task<Void, Never>?
    var body: some View {
        SheetFrame(title: "AI image imports") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connect LogMate to its image-reading service. It interprets schedules and logbook pages, then returns editable drafts for review.").foregroundStyle(theme.muted)
                LogField(title: "Import service address", value: $endpoint, hint: "https://your-service.workers.dev", keyboard: .URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Personal import access code").font(.subheadline).foregroundStyle(theme.muted)
                    SecureField("lm_…", text: $accessCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(14).background(theme.raised).clipShape(RoundedRectangle(cornerRadius: 12))
                }
                Text("When you choose Read with AI, your photo is sent to LogMate's connected service and OpenAI to create editable drafts. Review them before saving.")
                    .font(.caption).foregroundStyle(theme.muted)
                if !message.isEmpty { Text(message).foregroundStyle(theme.accent) }
                AccentButton(title: checking ? "Checking connection…" : "Check connection and save") {
                    connectionTask?.cancel(); checking = true; message = ""
                    connectionTask = Task { @MainActor in
                        defer { checking = false }
                        do {
                            try await AIPhotoImporter.connection(endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines), accessCode: accessCode.trimmingCharacters(in: .whitespacesAndNewlines))
                            try Task.checkCancellation()
                            try AIImportConfiguration.save(endpoint: endpoint, accessCode: accessCode.trimmingCharacters(in: .whitespacesAndNewlines))
                            dismiss()
                        } catch is CancellationError { return }
                        catch { if !Task.isCancelled { message = error.localizedDescription } }
                    }
                }.disabled(checking)
                if AIImportConfiguration.ready {
                    Button("Disconnect", role: .destructive) { AIImportConfiguration.disconnect(); endpoint = ""; accessCode = ""; message = "Disconnected." }
                        .disabled(checking)
                }
            }
        }.onDisappear { connectionTask?.cancel() }
    }
}

// MARK: - Structured photo imports
