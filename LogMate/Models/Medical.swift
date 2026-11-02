// FAA medical model: class, the privileges per class, the saved medical
// record, and the validity/currency computation.
import Foundation

enum MedicalClass: Int, CaseIterable, Codable, Identifiable {
    case first = 1, second = 2, third = 3
    var id: Int { rawValue }
    var title: String { ["", "First class", "Second class", "Third class"][rawValue] }
}

enum MedicalPrivilege: String, CaseIterable, Identifiable {
    case first, second, third
    var id: String { rawValue }
    var title: String {
        switch self { case .first: return "First-class operations"; case .second: return "Second-class operations"; case .third: return "Third-class operations" }
    }
    var detail: String {
        switch self {
        case .first: return "ATP PIC / specified airline crew"
        case .second: return "Commercial / applicable ATP SIC"
        case .third: return "Private, student / applicable CFI PIC"
        }
    }
}

struct FAAMedical: Codable {
    var medicalClass = MedicalClass.third
    var examDate = Date()
    var age40OrOlderAtExam = false
    var notValidAfter: Date? = nil
    var privilegeLimits: [String: Date] = [:]
    var limitations = ""
}

enum MedicalValidity {
    // 14 CFR 61.23(d): periods run from the examination month, not the pilot's next birthday.
    static func months(_ medical: FAAMedical, privilege: MedicalPrivilege) -> Int? {
        switch privilege {
        case .first: return medical.medicalClass == .first ? (medical.age40OrOlderAtExam ? 6 : 12) : nil
        case .second: return medical.medicalClass == .third ? nil : 12
        case .third: return medical.age40OrOlderAtExam ? 24 : 60
        }
    }
    static func endExclusive(_ medical: FAAMedical, privilege: MedicalPrivilege, calendar: Calendar = .current) -> Date? {
        guard let months = months(medical, privilege: privilege),
              let start = calendar.date(from: calendar.dateComponents([.year, .month], from: medical.examDate)),
              var end = calendar.date(byAdding: .month, value: months + 1, to: start) else { return nil }
        // Printed certificate restrictions can shorten a period; they never extend the standard rule.
        for date in [medical.notValidAfter, medical.privilegeLimits[privilege.rawValue]].compactMap({ $0 }) {
            if let restrictedEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) { end = min(end, restrictedEnd) }
        }
        return end
    }
    static func lastDay(_ end: Date, calendar: Calendar = .current) -> Date { calendar.date(byAdding: .day, value: -1, to: end) ?? end }
    static func remaining(_ end: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let expiry = lastDay(end, calendar: calendar)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: expiry)).day ?? 0
        if now >= end { return "Expired" }
        if days == 0 { return "Expires today" }
        if days == 1 { return "1 day left" }
        return "\(days) days left"
    }
}
