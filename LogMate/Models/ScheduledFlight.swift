// A scheduled (future) flight/booking as tracked against the schedule tab.
import Foundation

struct ScheduledFlight: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    var title = ""
    var registration = ""
    var route = ""
    var estimatedTime = 0.0
    // Optional fields keep calendars saved by earlier builds readable.
    var endDate: Date? = nil
    var pilotName: String? = nil
    var instructorName: String? = nil
    var notes: String? = nil
    var resource: String? = nil
    var sourceScheduleID: String? = nil
    var activityType: String? = nil
    var importReviewStatus: String? = nil
    var importUnreviewedFields: [String]? = nil
    var importWarnings: [String]? = nil
    var isGround: Bool {
        activityType == "ground" || resource?.uppercased() == "GROUND"
    }
}
