// The stats computation layer: the background workers (map geometry,
// memory photos), the persisted stats model, and the memory-photo value
// type.
import Foundation
import UIKit

actor StatsWorker {
    private var revision = -1
    private var cached: [String: StatsSnapshot] = [:]
    func build(_ inputs: [StatsInput], revision: Int, range: String, now: Date) throws -> StatsSnapshot {
        if self.revision != revision { cached.removeAll(); self.revision = revision }
        let day = Calendar.current.startOfDay(for: now).timeIntervalSince1970
        let key = "\(revision)|\(range)|\(Int(day))"
        if let snapshot = cached[key] { return snapshot }
        let formats = Dictionary(uniqueKeysWithValues: ["yyyy-MM-dd", "MMM d, yyyy", "MMMM d, yyyy", "M/d/yyyy", "M/d/yy"].map { format in
            let parser = DateFormatter(); parser.locale = Locale(identifier: "en_US_POSIX"); parser.dateFormat = format
            return (format, parser)
        })
        let display = DateFormatter(); display.locale = Locale(identifier: "en_US_POSIX"); display.dateFormat = "M/d/yy"
        var dates: [String: Date] = [:], invalid = Set<String>()
        var routeCache: [String: [String]] = [:], modelCache: [String: String] = [:]
        let days = range == "Past week" ? 7 : range == "Past 30 days" ? 30 : 0
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) ?? .distantPast
        var snapshot = StatsSnapshot(); snapshot.key = key
        for (index, input) in inputs.enumerated() {
            if index % 64 == 0 { try Task.checkCancellation() }
            if dates[input.date] == nil && !invalid.contains(input.date) {
                if let date = FlightDates.formats(for: input.date).lazy.compactMap({ formats[$0]?.date(from: input.date) }).first { dates[input.date] = date }
                else { invalid.insert(input.date) }
            }
            let date = dates[input.date] ?? .distantPast
            if days > 0 && (date < cutoff || date > now) { continue }
            let airports = routeCache[input.route] ?? AirportRoute.codes(input.route)
            routeCache[input.route] = airports
            snapshot.flights.append(StatsFlight(input: input, parsedDate: date,
                shortDate: dates[input.date].map { display.string(from: $0) } ?? input.date, airports: airports))
        }
        snapshot.flights.sort { a, b in a.parsedDate == b.parsedDate ? a.input.order > b.input.order : a.parsedDate > b.parsedDate }
        var variants = Set<String>(), models = Set<String>(), recent = Set<StatsLeg>(), others = Set<StatsLeg>()
        for (index, f) in snapshot.flights.enumerated() {
            if index % 64 == 0 { try Task.checkCancellation() }
            snapshot.byID[f.id] = f; snapshot.total += f.total
            snapshot.registrationCounts[f.input.registration, default: 0] += 1
            if !f.input.model.isEmpty {
                let variant = f.input.model.uppercased()
                let model = modelCache[variant] ?? StatsMath.baseModel(f.input.model).uppercased()
                modelCache[variant] = model
                variants.insert(variant); models.insert(model)
            }
            for code in Set(f.airports) {
                // Mutate in place so appending IDs does not copy the growing
                // per-airport flight array for every logbook entry.
                snapshot.airports[code, default: StatsAirportActivity()].record(f)
            }
            for code in f.airports.dropFirst() { snapshot.airports[code, default: StatsAirportActivity()].arrivals += 1 }
            for (a, b) in zip(f.airports, f.airports.dropFirst()) where a != b {
                if index == 0 { recent.insert(StatsLeg(a, b)) } else { others.insert(StatsLeg(a, b)) }
            }
        }
        snapshot.codes = snapshot.airports.keys.sorted {
            let a = snapshot.airports[$0]?.arrivals ?? 0, b = snapshot.airports[$1]?.arrivals ?? 0
            return a == b ? $0 < $1 : a > b
        }
        snapshot.mostFlown = snapshot.registrationCounts.keys.sorted().max {
            snapshot.registrationCounts[$0, default: 0] < snapshot.registrationCounts[$1, default: 0]
        }
        snapshot.mostFlownModel = snapshot.flights.first { $0.input.registration == snapshot.mostFlown }?.input.model ?? ""
        snapshot.variantCount = variants.count; snapshot.modelCount = models.count
        snapshot.recentLegs = recent.sorted { $0.id < $1.id }
        snapshot.otherLegs = others.subtracting(recent).sorted { $0.id < $1.id }
        cached = cached.filter { $0.key.hasSuffix("|\(Int(day))") }; cached[key] = snapshot
        return snapshot
    }
    func longest(_ snapshot: StatsSnapshot, coordinates: [String: StatsCoordinate]) throws -> [StatsDistance] {
        try Task.checkCancellation()
        return StatsMath.distances(snapshot, coordinates: coordinates)
    }
}
nonisolated struct FlightMemoryReference: Identifiable, Sendable {
    let flightID: UUID
    let key: String
    let index: Int
    let fileRevision: String
    var id: String { "\(flightID)|\(key)|\(index)|\(fileRevision)" }
}
actor FlightMemoryLoader {
    static let shared = FlightMemoryLoader()
    private var indexed: [String: (stamp: String, count: Int)] = [:]
    private let thumbnails = NSCache<NSString, NSData>()
    init() { thumbnails.countLimit = 12; thumbnails.totalCostLimit = 24 * 1024 * 1024 }
    private func safe(_ text: String) -> String { text.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() }
    func index(_ flights: [StatsFlight], folder: URL) async throws -> [FlightMemoryReference] {
        var refs: [FlightMemoryReference] = []
        for (offset, flight) in flights.enumerated() {
            try Task.checkCancellation()
            if offset % 32 == 0 { await Task.yield() }
            let stable = folder.appendingPathComponent(safe(flight.input.photoKey) + ".plist")
            let key = FileManager.default.fileExists(atPath: stable.path) ? flight.input.photoKey : flight.input.legacyPhotoKey
            let url = folder.appendingPathComponent(safe(key) + ".plist")
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            let stamp = "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attributes[.size] ?? 0)"
            let count: Int
            if let saved = indexed[key], saved.stamp == stamp { count = saved.count }
            else {
                count = autoreleasepool {
                    guard let data = try? Data(contentsOf: url), let photos = try? PropertyListDecoder().decode([Data].self, from: data) else { return 0 }
                    return photos.count
                }
                indexed[key] = (stamp, count)
            }
            refs += (0..<count).map { FlightMemoryReference(flightID: flight.id, key: key, index: $0, fileRevision: stamp) }
        }
        return refs
    }
    func thumbnail(_ reference: FlightMemoryReference, folder: URL) throws -> Data? {
        try Task.checkCancellation()
        if let cached = thumbnails.object(forKey: reference.id as NSString) { return cached as Data }
        let url = folder.appendingPathComponent(safe(reference.key) + ".plist")
        let data: Data? = autoreleasepool {
            guard let saved = try? Data(contentsOf: url), let photos = try? PropertyListDecoder().decode([Data].self, from: saved),
                  photos.indices.contains(reference.index), let source = CGImageSourceCreateWithData(photos[reference.index] as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1200, kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }
        if let data { thumbnails.setObject(data as NSData, forKey: reference.id as NSString, cost: data.count) }
        return data
    }
}
@MainActor final class StatsModel: ObservableObject {
    @Published private(set) var snapshot = StatsSnapshot()
    @Published private(set) var longest: [StatsDistance] = []
    @Published private(set) var memories: [FlightMemoryReference] = []
    @Published private(set) var calculating = false
    private let worker = StatsWorker()
    private var updateID = UUID()
    private var memoryID = UUID()
    private var distanceID = UUID()
    private var memoryKey = ""
    private var coordinateCache: [String: StatsCoordinate] = [:]
    func update(_ inputs: [StatsInput], revision: Int, range: String) async {
        let token = UUID(); updateID = token; calculating = true
        defer { if updateID == token { calculating = false } }
        do {
            let result = try await worker.build(inputs, revision: revision, range: range, now: Date())
            guard !Task.isCancelled, token == updateID else { return }
            if snapshot.key != result.key {
                snapshot = result; longest = []; coordinateCache = [:]; memories = []; memoryKey = ""
            }
        } catch { /* A cancelled tab/range request never publishes stale data. */ }
    }
    func updateMemories(revision: Int, folder: URL) async {
        let key = snapshot.key + "|photos:\(revision)"
        guard !snapshot.key.isEmpty, key != memoryKey else { return }
        let token = UUID(); memoryID = token; let captured = snapshot
        do {
            let refs = try await FlightMemoryLoader.shared.index(captured.flights, folder: folder)
            guard !Task.isCancelled, token == memoryID, captured.key == snapshot.key else { return }
            memories = refs; memoryKey = key
        } catch { }
    }
    func updateDistances(_ coordinates: [String: StatsCoordinate]) async {
        guard coordinates != coordinateCache else { return }
        let token = UUID(); distanceID = token; let captured = snapshot
        do {
            let result = try await worker.longest(captured, coordinates: coordinates)
            guard !Task.isCancelled, token == distanceID, captured.key == snapshot.key else { return }
            longest = result; coordinateCache = coordinates
        } catch { }
    }
}
