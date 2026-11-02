// Instructor records: profile (name, email, certificate, expiry),
// the signed-in-entry signature capture data, and milestone confirmations.
import Foundation

struct InstructorProfile: Identifiable, Codable {
    var name = ""
    var email = ""
    var certificate = ""
    var expiration: Date? = nil
    var noExpiration = false
    var recentExperienceEnd: Date? = nil
    var id: String { certificate.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
}

struct InstructorSignature: Codable {
    var instructor: InstructorProfile
    var comments: String
    var inkPNG: Data
    var signedAt: Date
    var agreedAt: Date
    var flightDigest: String
    var flightSnapshot: Data
    var version = 1
    static let agreement = "The app cannot verify a signature or an instructor's identity, certificate, or authority. I affirm that the instructor named on this entry will personally review and sign it; the student will not sign on the instructor's behalf."
    func matches(_ flight: Flight) -> Bool { version == 1 && flightDigest == flight.recordDigest }
}

struct MilestoneConfirmation: Codable {
    var flightDigest: String
    var confirmedAt: Date
    var accepted: Bool
    var creditedValue: Double
    var statement: String
    var version = 1
    func matches(_ flight: Flight, statement: String) -> Bool {
        version == 1 && flightDigest == flight.recordDigest && self.statement == statement
    }
}

// Optional facts supplement ordinary logbook times; no separate checkride hour ledger.
