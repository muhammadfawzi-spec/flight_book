// The saved-aircraft model (registration, make/model, photo credit) plus
// its display helpers.
import Foundation

struct SavedAircraft: Identifiable, Codable {
    var registration: String
    var model: String
    var category: String? = nil
    var complex: Bool? = nil
    var highPerformance: Bool? = nil
    var taa: Bool? = nil
    var turbine: Bool? = nil
    // Optional fields preserve aircraft saved by earlier builds.
    var detectedFeatures: [String: Bool]? = nil
    var featureCorrections: [String: Bool]? = nil
    var equipmentInfo: AircraftInfo? = nil
    var id: String { registration }
}

extension SavedAircraft {
    var equipmentCorrections: [String: Bool] {
        if let featureCorrections { return featureCorrections }
        var legacy: [String: Bool] = [:]
        if let complex { legacy["complex"] = complex }; if let highPerformance { legacy["hp"] = highPerformance }
        if let taa { legacy["taa"] = taa }; if let turbine { legacy["turbine"] = turbine }
        return legacy
    }
    var resolvedEquipmentFeatures: [String: Bool] {
        let corrections = equipmentCorrections
        let known = (detectedFeatures ?? [:]).merging(corrections, uniquingKeysWith: { _, edit in edit })
        return AircraftFeatures.derived(known, category: category ?? "Unspecified")
            .merging(corrections, uniquingKeysWith: { _, edit in edit })
    }
}
