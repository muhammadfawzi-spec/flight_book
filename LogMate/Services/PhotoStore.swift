// The on-disk location rules and image persist/load helpers for
// aircraft photos (Application Support).
import Foundation
import UIKit

enum PhotoStore {
    static let folder: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlightPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static func safe(_ key: String) -> String {
        key.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }
    static func load(key: String) -> [UIImage] {
        let url = folder.appendingPathComponent(safe(key) + ".plist")
        guard let data = try? Data(contentsOf: url),
              let images = try? PropertyListDecoder().decode([Data].self, from: data) else { return [] }
        return images.compactMap { UIImage(data: $0) }
    }
    static func load(_ flight: Flight) -> [UIImage] {
        let stableURL = folder.appendingPathComponent(safe(flight.photoKey) + ".plist")
        if FileManager.default.fileExists(atPath: stableURL.path) { return load(key: flight.photoKey) }
        return load(key: flight.legacyPhotoKey ?? "\(flight.route)-\(flight.date)-\(flight.aircraft)")
    }
    static func save(_ images: [UIImage], key: String) throws {
        let data = try PropertyListEncoder().encode(images.compactMap { $0.jpegData(compressionQuality: 0.82) })
        try data.write(to: folder.appendingPathComponent(safe(key) + ".plist"), options: .atomic)
    }
}
