// FAA WINGS currency: a completion record and the store that persists and
// tracks expirations.
import Foundation
import UIKit

struct WINGSCompletion: Identifiable, Codable {
    var id = UUID()
    var date: Date
    var certificate: String?
}
@MainActor final class WINGSStore: ObservableObject {
    @Published private(set) var records: [WINGSCompletion] = []
    @Published var error = ""
    private var readable = true
    init() {
        if let data = UserDefaults.standard.data(forKey: "wings-completions-v1") {
            do { records = try JSONDecoder().decode([WINGSCompletion].self, from: data) }
            catch { readable = false; self.error = "Saved WINGS records could not be read. They have been retained." }
        }
    }
    func save(date: Date, image: UIImage?) -> Bool {
        guard readable, date <= Date() else { error = "Choose a completed WINGS phase date."; return false }
        var entry = WINGSCompletion(date: date)
        do {
            if let data = image?.jpegData(compressionQuality: 0.9) {
                entry.certificate = "WINGS-" + entry.id.uuidString + ".jpg"
                try data.write(to: PhotoStore.folder.appendingPathComponent(entry.certificate!), options: .atomic)
            }
            let next = (records + [entry]).sorted { $0.date > $1.date }
            UserDefaults.standard.set(try JSONEncoder().encode(next), forKey: "wings-completions-v1")
            records = next; error = ""; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func delete(_ entry: WINGSCompletion) {
        guard readable else { return }
        let next = records.filter { $0.id != entry.id }
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: "wings-completions-v1"); records = next
            if let filename = entry.certificate { try? FileManager.default.removeItem(at: PhotoStore.folder.appendingPathComponent(filename)) }
        }
    }
    func image(_ entry: WINGSCompletion) -> UIImage? { entry.certificate.flatMap { UIImage(contentsOfFile: PhotoStore.folder.appendingPathComponent($0).path) } }
}
