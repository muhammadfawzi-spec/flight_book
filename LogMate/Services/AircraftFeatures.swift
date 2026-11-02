// Aircraft equipment/feature domain: the feature definitions, the equipment
// state persistence, feature synchronization, and the make/model name
// normalizers.
import Foundation

nonisolated enum AircraftNames {
    static func registration(_ value: String) -> String {
        value.uppercased().filter { $0.isLetter || $0.isNumber }
    }
    static func display(_ value: String) -> String {
        let raw = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // Some exports put a precise model code before a comma and the marketing name after it.
        // Only normalize recognized codes; never guess a variant from the marketing name.
        if let comma = raw.firstIndex(of: ",") {
            let code = String(raw[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = display(code)
            if normalized != code { return normalized }
            let compactCode = code.uppercased().filter { $0.isLetter || $0.isNumber }
            if compactCode.range(of: #"^BE[0-9]{2,3}[A-Z]?$"#, options: .regularExpression) != nil {
                return "Beechcraft " + String(compactCode.dropFirst(2))
            }
        }
        let compact = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        let cessnas = ["150", "150L", "150M", "152", "172", "172N", "172P", "172R", "172S", "172RG", "177", "177RG", "182", "182P", "182Q", "182R", "182S", "182T", "T182T", "182RG", "T182RG", "206", "U206G", "T206H"]
        for code in cessnas where [code, "C" + code, "CESSNA" + code, "CESSNAAIRCRAFTCOMPANY" + code, "CESSNAAIRCRAFTCO" + code, "TEXTRONAVIATIONINC" + code].contains(compact) {
            return "Cessna " + code
        }
        var cessnaCode = compact
        for maker in ["CESSNAAIRCRAFTCOMPANY", "CESSNAAIRCRAFTCO", "CESSNA", "TEXTRONAVIATIONINC"] {
            if cessnaCode.hasPrefix(maker) { cessnaCode = String(cessnaCode.dropFirst(maker.count)); break }
        }
        if cessnaCode.hasPrefix("C") { cessnaCode = String(cessnaCode.dropFirst()) }
        let knownSeries = ["150", "152", "172", "177", "180", "182", "185", "188", "206", "207", "210", "310", "340", "402", "414", "421", "425"]
        if cessnaCode.range(of: "^[TU]?[0-9]{3}[A-Z]{0,3}$", options: .regularExpression) != nil,
           knownSeries.contains(where: { cessnaCode.hasPrefix($0) || cessnaCode.hasPrefix("T" + $0) || cessnaCode.hasPrefix("U" + $0) }) {
            return "Cessna " + cessnaCode
        }
        for (make, prefix) in [("Piper", "PA"), ("Diamond", "DA"), ("Cirrus", "SR")] {
            var model = compact
            for maker in [make.uppercased() + "AIRCRAFTINDUSTRIESINC", make.uppercased() + "AIRCRAFTINC", make.uppercased()] {
                if model.hasPrefix(maker) { model = String(model.dropFirst(maker.count)); break }
            }
            if model.hasPrefix(prefix), model.dropFirst(prefix.count).first?.isNumber == true {
                if prefix == "PA" { model = "PA-" + String(model.dropFirst(2)) }
                return make + " " + model
            }
        }
        if compact == "A36" || compact == "BEECHCRAFTA36" { return "Beechcraft A36" }
        if compact == "G36" || compact == "BEECHCRAFTG36" { return "Beechcraft G36" }
        return raw
    }
    static func hasMake(_ value: String) -> Bool {
        let display = display(value)
        return display.split(separator: " ").count >= 2 && display.contains(where: { $0.isLetter })
    }
    static func baseModel(_ value: String) -> String {
        let name = display(value)
        let patterns: [(String, String)] = [
            (#"^CESSNA\s+[TU]?([0-9]{3})[A-Z0-9 -]*$"#, "Cessna "),
            (#"^PIPER\s+PA-?([0-9]{2})[A-Z0-9 -]*$"#, "Piper PA-"),
            (#"^DIAMOND\s+DA-?([0-9]{2})[A-Z0-9 -]*$"#, "Diamond DA"),
            (#"^CIRRUS\s+SR-?([0-9]{2})[A-Z0-9 -]*$"#, "Cirrus SR"),
            (#"^CIRRUS\s+SF-?([0-9]{2})[A-Z0-9 -]*$"#, "Cirrus SF"),
            (#"^ROBINSON\s+R-?([0-9]{2})[A-Z0-9 -]*$"#, "Robinson R")
        ]
        let upper = name.uppercased()
        for (pattern, make) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: upper, range: NSRange(upper.startIndex..., in: upper)),
                  let range = Range(match.range(at: 1), in: upper) else { continue }
            return make + String(upper[range])
        }
        // Keep an unfamiliar model intact rather than guessing which part names a variant.
        return name
    }
}

enum AircraftFeature: String, CaseIterable, Identifiable, Codable {
    case complex, highPerformance = "hp", taa, turbine, tailwheel
    case fixedGear, retractableGear, tricycleGear, skids, skis, floats, amphibious, flyingBoat
    case fixedPitchPropeller, controllablePitchPropeller, constantSpeedPropeller, flaps
    case manualControllablePitchPropeller
    case piston, turboprop, turboshaft, turbojet, turbofan, electric, rotaryEngine
    case pressurized, highAltitude, largeAircraft, typeRatingRequired, twoPilotCrew, simplifiedControls, robinsonSFAR73
    case glassCockpit, pfd, mfd, gps, twoAxisAutopilot
    case standardAirworthiness, experimental, restricted, specialLightSport, utilityCategory, aerobaticCategory
    var id: String { rawValue }
    var title: String {
        switch self {
        case .complex: return "Complex"
        case .highPerformance: return "High performance"
        case .taa: return "Technically advanced airplane"
        case .turbine: return "Turbine powered"
        case .tailwheel: return "Tailwheel"
        case .fixedGear: return "Fixed landing gear"
        case .retractableGear: return "Retractable landing gear"
        case .tricycleGear: return "Tricycle landing gear"
        case .skids: return "Skid landing gear"
        case .skis: return "Skis"
        case .floats: return "Floats"
        case .amphibious: return "Amphibious configuration"
        case .flyingBoat: return "Flying-boat hull"
        case .fixedPitchPropeller: return "Fixed-pitch propeller"
        case .controllablePitchPropeller: return "Controllable-pitch propeller"
        case .manualControllablePitchPropeller: return "Manual controllable-pitch propeller"
        case .constantSpeedPropeller: return "Constant-speed propeller"
        case .flaps: return "Flaps"
        case .piston: return "Piston engine"
        case .turboprop: return "Turboprop"
        case .turboshaft: return "Turboshaft"
        case .turbojet: return "Turbojet"
        case .turbofan: return "Turbofan"
        case .electric: return "Electric propulsion"
        case .rotaryEngine: return "Rotary engine"
        case .pressurized: return "Pressurized cabin"
        case .highAltitude: return "High-altitude pressurized airplane"
        case .largeAircraft: return "Large aircraft (over 12,500 lb)"
        case .typeRatingRequired: return "Type rating required"
        case .twoPilotCrew: return "Two-pilot minimum crew"
        case .simplifiedControls: return "Designated simplified flight controls"
        case .robinsonSFAR73: return "Robinson R22 / R44 (SFAR 73)"
        case .glassCockpit: return "Glass cockpit"
        case .pfd: return "Electronic primary flight display"
        case .mfd: return "Moving-map multifunction display"
        case .gps: return "GPS navigation"
        case .twoAxisAutopilot: return "Integrated two-axis autopilot"
        case .standardAirworthiness: return "Standard airworthiness certificate"
        case .experimental: return "Experimental certificate"
        case .restricted: return "Restricted certificate"
        case .specialLightSport: return "Special light-sport certificate"
        case .utilityCategory: return "Utility certification category"
        case .aerobaticCategory: return "Aerobatic certification category"
        }
    }
    var group: String {
        switch self {
        case .complex, .highPerformance, .taa, .turbine, .tailwheel: return "Training and experience"
        case .fixedGear, .retractableGear, .tricycleGear, .skids, .skis, .floats, .amphibious, .flyingBoat: return "Landing gear and configuration"
        case .fixedPitchPropeller, .controllablePitchPropeller, .constantSpeedPropeller, .flaps,
             .piston, .turboprop, .turboshaft, .turbojet, .turbofan, .electric, .rotaryEngine: return "Powerplant and controls"
        case .glassCockpit, .pfd, .mfd, .gps, .twoAxisAutopilot: return "Avionics"
        case .standardAirworthiness, .experimental, .restricted, .specialLightSport, .utilityCategory, .aerobaticCategory: return "Certification"
        default: return "Operating characteristics"
        }
    }
    // Public classifications drive forms, filters and totals. Retain the other cases
    // for detection and compatibility with previously saved equipment and signatures.
    static let pilotFeatures: [AircraftFeature] = [
        .complex, .highPerformance, .taa, .turbine, .tailwheel
    ]
    static let pilotGroups = ["Training and experience"]
    var pilotGroup: String { "Training and experience" }
    // Parent/child features can coexist. Mutually exclusive configurations cannot.
    var alternatives: [AircraftFeature] {
        switch self {
        case .fixedGear: return [.retractableGear]
        case .retractableGear: return [.fixedGear]
        case .tailwheel: return [.tricycleGear, .skids]
        case .tricycleGear: return [.tailwheel, .skids]
        case .skids: return [.tailwheel, .tricycleGear]
        case .fixedPitchPropeller: return [.controllablePitchPropeller, .constantSpeedPropeller, .manualControllablePitchPropeller]
        case .controllablePitchPropeller, .constantSpeedPropeller, .manualControllablePitchPropeller: return [.fixedPitchPropeller]
        case .piston, .turboprop, .turboshaft, .turbojet, .turbofan, .electric, .rotaryEngine:
            return [.piston, .turboprop, .turboshaft, .turbojet, .turbofan, .electric, .rotaryEngine].filter { $0 != self }
        case .standardAirworthiness, .experimental, .restricted, .specialLightSport:
            return [.standardAirworthiness, .experimental, .restricted, .specialLightSport].filter { $0 != self }
        default: return []
        }
    }
}

enum AircraftFeatures {
    struct Detection {
        var values: [String: Bool] = [:]
        var horsepower: Double? = nil
        var engines: Int? = nil
        var source = ""
        var modelSourceURL: URL? = nil
    }
    nonisolated static func parts(_ model: String, info: AircraftInfo?) -> (String, String) {
        if let info, AircraftNames.display(info.model) == AircraftNames.display(model),
           let make = info.registryMake, let code = info.registryModel { return (make, code) }
        let text = AircraftNames.display(model).uppercased()
        let makers = ["AMERICAN CHAMPION", "ROBINSON HELICOPTER", "DIAMOND AIRCRAFT", "CIRRUS DESIGN", "TEXTRON AVIATION", "BEECHCRAFT", "BEECH", "CHAMPION", "CESSNA", "PIPER", "DIAMOND", "CIRRUS", "ROBINSON"]
        for maker in makers where text.hasPrefix(maker + " ") {
            return (maker, String(text.dropFirst(maker.count)).trimmingCharacters(in: .whitespaces))
        }
        let words = text.split(separator: " ")
        return (words.dropLast().joined(separator: " "), String(words.last ?? ""))
    }
    static func detect(_ model: String, category: String, info: AircraftInfo? = nil) -> Detection {
        let (make, rawCode) = parts(model, info: info)
        let code = AircraftReference.key(rawCode)
        let maker = AircraftReference.key(make)
        let matchingInfo = info.flatMap { AircraftNames.display($0.model) == AircraftNames.display(model) ? $0 : nil }
        let reference = AircraftReference.model(make: make, code: rawCode)
        let engine = matchingInfo.flatMap { AircraftReference.engine(make: $0.engineMake ?? "", code: $0.engineModel ?? "") }
        var result = Detection(engines: reference?.engines)
        var sources: [String] = []
        func set(_ feature: AircraftFeature, _ value: Bool = true) { result.values[feature.rawValue] = value }
        func stock(_ features: [AircraftFeature], horsepower: Double? = nil) {
            features.forEach { set($0) }; if let horsepower { result.horsepower = horsepower }
            if !sources.contains("Stock model equipment") { sources.append("Stock model equipment") }
        }
        let airplane = ["ASEL", "ASES", "AMEL", "AMES"].contains(category)
            || ["4", "5"].contains(reference?.type ?? "")
        let sea = ["ASES", "AMES"].contains(category)
        let isCessna = maker.contains("CESSNA") || maker.contains("TEXTRON")
        let isPiper = maker.contains("PIPER")
        let isDiamond = maker.contains("DIAMOND")
        let isCirrus = maker.contains("CIRRUS")
        let isChampion = maker.contains("CHAMPION") || maker.contains("BELLANCA")
        if isCessna {
            if code.range(of: "^(150[A-M]?|A150[KL M]?|152|A152|172[A-S]?|R172[EK]|177[A-B]?)$".replacingOccurrences(of: " ", with: ""), options: .regularExpression) != nil {
                stock([.fixedGear, .tricycleGear, .fixedPitchPropeller, .flaps, .piston]); set(.complex, false)
                if ["172N", "172P", "172R"].contains(code) { result.horsepower = 160 }
                if code == "172S" { result.horsepower = 180 }
            }
            if ["172RG", "177RG", "R182", "TR182", "182RG", "T182RG"].contains(code) {
                stock([.retractableGear, .tricycleGear, .constantSpeedPropeller, .controllablePitchPropeller, .flaps, .piston])
                if code == "172RG" { result.horsepower = 180 }
            }
            if code.range(of: "^T?182[A-T]?$", options: .regularExpression) != nil {
                stock([.fixedGear, .tricycleGear, .constantSpeedPropeller, .controllablePitchPropeller, .flaps, .piston, .highPerformance]); set(.complex, false)
                if code == "182T" { result.horsepower = 230 }; if code == "T182T" { result.horsepower = 235 }
            }
            if ["180", "180A", "180B", "180C", "180D", "180E", "180F", "180G", "180H", "180J", "180K", "185", "185A", "185B", "185C", "185D", "185E", "A185E", "A185F"].contains(code) {
                stock([.fixedGear, .tailwheel, .constantSpeedPropeller, .controllablePitchPropeller, .flaps, .piston, .highPerformance])
            }
            if ["208", "208A", "208B"].contains(code) {
                stock([.fixedGear, .tricycleGear, .constantSpeedPropeller, .controllablePitchPropeller, .flaps, .turboprop, .highPerformance])
            }
        }
        if isPiper {
            if ["PA28140", "PA28150", "PA28151", "PA28160", "PA28161", "PA28180", "PA28181"].contains(code) {
                stock([.fixedGear, .tricycleGear, .fixedPitchPropeller, .flaps, .piston]); set(.complex, false)
            }
            if ["PA28R180", "PA28R200", "PA28R201", "PA28RT201", "PA28R201T", "PA28RT201T", "PA44180", "PA44180T"].contains(code) {
                stock([.retractableGear, .tricycleGear, .constantSpeedPropeller, .controllablePitchPropeller, .flaps, .piston])
                if ["PA28R200", "PA28R201", "PA28RT201", "PA28R201T", "PA28RT201T"].contains(code) { result.horsepower = 200 }
                if code == "PA44180" { result.horsepower = 180 }
            }
            if ["PA46", "PA46350P", "PA46310P", "PA46500TP", "PA46600TP", "PA46700TP"].contains(code), code != "PA46" {
                stock([.retractableGear, .tricycleGear, .constantSpeedPropeller, .controllablePitchPropeller, .flaps, .pressurized])
                // The M350's 25,000-ft limit does NOT satisfy the >25,000-ft endorsement threshold.
                if ["PA46500TP", "PA46600TP", "PA46700TP"].contains(code) { stock([.highAltitude, .turboprop]) }
            }
        }
        // Beechcraft Duchess 76 POH: retractable gear, flaps and constant-speed props;
        // two 180-hp engines. Power is evaluated per engine, not as 360 hp combined.
        if maker.contains("BEECH"), ["76", "BE76", "76DUCHESS", "DUCHESS76"].contains(code) {
            stock([.retractableGear, .tricycleGear, .constantSpeedPropeller, .controllablePitchPropeller, .flaps, .piston], horsepower: 180)
        }
        if maker.contains("BEECH"), ["A36", "A36TC", "B36TC", "G36", "B58", "G58", "58", "58P", "58TC"].contains(code) {
            stock([.retractableGear, .tricycleGear, .constantSpeedPropeller, .controllablePitchPropeller, .flaps, .piston, .highPerformance])
        }
        if isChampion, ["7AC", "7BCM", "7CCM", "7DC", "7EC", "7ECA", "7FC", "7GCAA", "7GCBC", "7HC", "7KCAB", "8KCAB", "8GCBC"].contains(code) {
            if code != "7FC" { stock([.tailwheel, .fixedGear, .piston]) }
            else { stock([.tricycleGear, .fixedGear, .piston]) }
            if ["7AC", "7ECA", "7GCAA", "7GCBC"].contains(code) { stock([.fixedPitchPropeller]); set(.complex, false) }
            if ["7GCBC", "8GCBC"].contains(code) { set(.flaps) }
            if ["8KCAB", "8GCBC"].contains(code) { stock([.constantSpeedPropeller, .controllablePitchPropeller]) }
        }
        if isCirrus, ["SR20", "SR22", "SR22T"].contains(code) {
            stock([.fixedGear, .tricycleGear, .constantSpeedPropeller, .controllablePitchPropeller, .flaps, .piston]); set(.complex, false)
            if code == "SR22" { result.horsepower = 310 }; if code == "SR22T" { result.horsepower = 315 }
        }
        if isDiamond {
            if ["DA20", "DA20A1", "DA20C1"].contains(code) { stock([.fixedGear, .tricycleGear, .flaps, .piston]); set(.complex, false) }
            if code == "DA20C1" { set(.fixedPitchPropeller) }
            if code == "DA20A1" { stock([.constantSpeedPropeller, .controllablePitchPropeller]) }
            if ["DA40", "DA40NG", "DA40D", "DA40XLT", "DA40XL"].contains(code) {
                stock([.fixedGear, .tricycleGear, .constantSpeedPropeller, .controllablePitchPropeller, .flaps, .piston]); set(.complex, false)
            }
            if ["DA42", "DA42NG", "DA42VI", "DA42L360", "DA62", "DA50RG"].contains(code) {
                stock([.retractableGear, .tricycleGear, .constantSpeedPropeller, .controllablePitchPropeller, .flaps, .piston])
            }
            if ["DA40NG", "DA40XLT", "DA42NG", "DA42VI", "DA62", "DA50RG"].contains(code) { stock([.glassCockpit, .pfd, .mfd, .gps]) }
            if code == "DA50RG" || (code == "DA42VI" && (matchingInfo?.manufactureYear ?? 0) >= 2025) {
                stock([.twoAxisAutopilot]) // Current factory standard; older optional installations stay unknown.
            }
        }
        if maker.contains("ROBINSON") {
            if ["R22", "R22BETA", "R22MARINER", "R44", "R44II", "R44CADET", "R44RAVEN", "R44RAVENII", "R66"].contains(code) {
                stock([.skids, .fixedGear]); set(.complex, false); set(.highPerformance, false)
                stock(code == "R66" ? [.turboshaft] : [.piston])
                if code != "R66" { set(.robinsonSFAR73) }
            }
        }
        // A controllable-pitch or constant-speed propeller alone does not establish
        // the manual control required by the sport-pilot rule in 14 CFR 61.331(b).
        // Use known conventional stock installations; leave unknown controls unset.
        if result.values[AircraftFeature.constantSpeedPropeller.rawValue] == true {
            if isCessna || isPiper || maker.contains("BEECH") || isChampion
                || (isDiamond && ["DA20A1", "DA40XLT", "DA40XL", "DA42L360"].contains(code)) {
                set(.manualControllablePitchPropeller)
            }
        }
        if isDiamond, ["DA40NG", "DA40D", "DA42NG", "DA42VI", "DA62", "DA50RG"].contains(code) {
            set(.manualControllablePitchPropeller, false) // Automatic engine/propeller control.
        }
        if let reference {
            sources.append("FAA model reference")
            if reference.configuration == "3" { set(.amphibious) }
            if reference.weightClass == "3" { set(.largeAircraft) }
            if reference.weightClass == "1" { set(.largeAircraft, false) }
            // CLASS 2 includes exactly 12,500 lb. It cannot establish a >12,500-lb feature.
        }
        var engineType = matchingInfo?.engineType ?? ""
        if engineType.isEmpty { engineType = engine?.type ?? reference?.engineType ?? "" }
        var detectedEngine: AircraftFeature?
        switch AircraftReference.key(engineType) {
        case "1", "7", "8", "RECIPROCATING", "PISTON", "2CYCLE", "4CYCLE": detectedEngine = .piston
        case "2", "TURBOPROP": detectedEngine = .turboprop
        case "3", "TURBOSHAFT": detectedEngine = .turboshaft
        case "4", "TURBOJET": detectedEngine = .turbojet
        case "5", "TURBOFAN": detectedEngine = .turbofan
        case "10", "ELECTRIC": detectedEngine = .electric
        case "11", "ROTARY": detectedEngine = .rotaryEngine
        default: break
        }
        if let detectedEngine {
            set(detectedEngine)
            for alternative in detectedEngine.alternatives { set(alternative, false) }
        }
        // Registry series-level ratings can describe multiple engine subvariants.
        // Use the exact engine rating or the known airframe rating, never add twin-engine power.
        // FAA ENGINE's rating column can contain pounds of thrust for jets.
        // Jet thrust must never be treated as horsepower or as a high-performance endorsement.
        if detectedEngine == .turbojet || detectedEngine == .turbofan {
            result.horsepower = nil
            result.values.removeValue(forKey: AircraftFeature.highPerformance.rawValue)
        } else if !(matchingInfo?.engineModel ?? "").uppercased().contains("SER"), let hp = engine?.horsepower, hp > 0 {
            result.horsepower = hp
        }
        if airplane, let hp = result.horsepower { set(.highPerformance, hp > 200) }
        if airplane, let matchingInfo, let evidence = matchingInfo.modelEquipment,
           evidence.modelIdentity == AircraftModelLookup.identity(matchingInfo), evidence.category == category,
           AircraftFeatures.derived(result.values, category: category)["complex"] == nil {
            // Supplement missing stock equipment only. Installed avionics are not
            // inferred from this public make/model catalog.
            let allowed: Set<String> = ["complex", "flaps", "retractableGear", "controllablePitchPropeller"]
            for (key, value) in evidence.features where allowed.contains(key) && value && result.values[key] == nil {
                result.values[key] = true
            }
            sources.append(evidence.sourceName)
            result.modelSourceURL = evidence.sourceURL
        }
        if matchingInfo != nil { sources.insert("FAA registry", at: 0) }
        let classification = (matchingInfo?.airworthinessClass ?? "").uppercased()
        if classification == "STANDARD" { set(.standardAirworthiness) }
        if classification == "EXPERIMENTAL" { set(.experimental) }
        if classification == "RESTRICTED" { set(.restricted) }
        if classification == "LIGHT SPORT" || classification == "LIGHT-SPORT" { set(.specialLightSport) }
        let certification = (matchingInfo?.certificationCategory ?? "").uppercased()
        if certification.contains("UTILITY") { set(.utilityCategory) }
        if certification.contains("ACROBATIC") || certification.contains("AEROBATIC") { set(.aerobaticCategory) }
        if sea { // Do not assume a landplane's wheel arrangement is present on floats.
            for feature in [AircraftFeature.tricycleGear, .tailwheel, .fixedGear, .retractableGear] { result.values.removeValue(forKey: feature.rawValue) }
            result.values.removeValue(forKey: AircraftFeature.complex.rawValue)
        }
        result.values = derived(result.values, category: category, aircraftType: matchingInfo?.aircraftType ?? reference?.type ?? "")
        result.source = sources.isEmpty ? "Equipment could not be determined for this model." : Array(NSOrderedSet(array: sources)).compactMap { $0 as? String }.joined(separator: " · ")
        return result
    }
    static func derived(_ input: [String: Bool], category: String, aircraftType: String = "") -> [String: Bool] {
        var values = input
        func yes(_ key: AircraftFeature) -> Bool { values[key.rawValue] == true }
        let airplane = ["ASEL", "ASES", "AMEL", "AMES"].contains(category) || ["4", "5"].contains(aircraftType)
        if yes(.constantSpeedPropeller) { values[AircraftFeature.controllablePitchPropeller.rawValue] = true }
        if yes(.manualControllablePitchPropeller) {
            values[AircraftFeature.controllablePitchPropeller.rawValue] = true
            values[AircraftFeature.fixedPitchPropeller.rawValue] = false
        }
        if [.turboprop, .turboshaft, .turbojet, .turbofan].contains(where: yes) { values[AircraftFeature.turbine.rawValue] = true }
        if yes(.piston) || yes(.electric) || yes(.rotaryEngine) { values[AircraftFeature.turbine.rawValue] = false }
        if airplane {
            let required: [AircraftFeature] = ["ASES", "AMES"].contains(category) ? [.flaps, .controllablePitchPropeller] : [.retractableGear, .flaps, .controllablePitchPropeller]
            if required.allSatisfy(yes) { values[AircraftFeature.complex.rawValue] = true }
            if required.contains(where: { values[$0.rawValue] == false }) { values[AircraftFeature.complex.rawValue] = false }
            if [.pfd, .mfd, .gps, .twoAxisAutopilot].allSatisfy(yes) { values[AircraftFeature.taa.rawValue] = true }
            if yes(.turbojet) || yes(.turbofan) || yes(.largeAircraft) { values[AircraftFeature.typeRatingRequired.rawValue] = true }
        }
        let type = AircraftReference.key(aircraftType)
        let lighterThanAir = ["2", "3"].contains(type) || ["BALLOON", "BLIMP", "DIRIGIBLE", "AIRSHIP"].contains { type.contains($0) }
        if (yes(.largeAircraft) && !lighterThanAir && !type.isEmpty)
            || type.contains("HYBRIDLIFT") || type.contains("POWEREDLIFT") || type == "H" {
            values[AircraftFeature.typeRatingRequired.rawValue] = true
        }
        return values
    }
}

struct AircraftEquipmentState {
    var detected: [String: Bool] = [:]
    var corrections: [String: Bool] = [:]
    var visible: Set<String> = []
    var category = "Unspecified"
    var source = ""
    var horsepower: Double? = nil
    var engines: Int? = nil
    var recordedFlight = false
    var modelSourceURL: URL? = nil
    var resetSavedCorrections = false
    var clearedCorrections: Set<String> = []
    var values: [String: Bool] {
        var result = detected.merging(corrections, uniquingKeysWith: { _, new in new })
        if !recordedFlight { result = AircraftFeatures.derived(result, category: category) }
        // An explicit false is a correction, not a missing value. Never lose it to inference.
        return result.merging(corrections, uniquingKeysWith: { _, new in new })
    }
    func selected(_ feature: AircraftFeature) -> Bool { values[feature.rawValue] == true }
    var rows: [AircraftFeature] { AircraftFeature.pilotFeatures.filter { selected($0) || visible.contains($0.rawValue) } }
    mutating func update(model: String, category: String, info: AircraftInfo?, saved: SavedAircraft?) {
        self.category = category
        guard !recordedFlight else { return }
        let detection = AircraftFeatures.detect(model, category: category, info: info)
        detected = detection.values
        horsepower = detection.horsepower; engines = detection.engines; source = detection.source
        modelSourceURL = detection.modelSourceURL
        // New files distinguish automatic values from user corrections. Legacy choices remain respected.
        let sameModel = saved.map { AircraftNames.display($0.model) == AircraftNames.display(model) } ?? false
        let remembered = !resetSavedCorrections ? saved?.equipmentCorrections ?? [:] : [:]
        corrections = remembered.merging(corrections, uniquingKeysWith: { _, current in current })
        if sameModel, saved?.category == category, let cached = saved?.detectedFeatures, info == nil {
            // Preserve earlier evidence during a network failure, but prefer fresh model evidence.
            // Retired operator avionics claims must not reappear from old automatic
            // caches. User-confirmed TAA remains in corrections; factory data is redetected.
            let avionics: Set<String> = ["taa", "glassCockpit", "pfd", "mfd", "gps", "twoAxisAutopilot"]
            let equipmentOnly = cached.filter { !avionics.contains($0.key) }
            detected = equipmentOnly.merging(detected, uniquingKeysWith: { _, new in new })
        }
    }
    mutating func useDetectedFeatures() {
        guard !recordedFlight else { return }
        clearedCorrections.formUnion(corrections.keys)
        resetSavedCorrections = true
        corrections = [:]; visible = []
    }
    // Explicit edits, their dependent features, and cleared corrections are
    // aircraft-wide. An unchanged recorded flight does not overwrite other flights.
    var synchronizedFeatures: [String: Bool] {
        let resolved = values
        var changes = corrections
        for (key, value) in resolved where detected[key] != value { changes[key] = value }
        for key in clearedCorrections { changes[key] = resolved[key] ?? false }
        return changes
    }
    mutating func choose(_ feature: AircraftFeature, enabled: Bool) {
        corrections[feature.rawValue] = enabled; visible.insert(feature.rawValue)
        if enabled {
            for alternative in feature.alternatives { corrections[alternative.rawValue] = false }
            var children: [AircraftFeature] = []
            if feature == .taa { children = [.glassCockpit, .pfd, .mfd, .gps, .twoAxisAutopilot] }
            if feature == .complex { children = ["ASES", "AMES"].contains(category) ? [.flaps, .controllablePitchPropeller] : [.retractableGear, .flaps, .controllablePitchPropeller] }
            if feature == .constantSpeedPropeller { children = [.controllablePitchPropeller] }
            if feature == .manualControllablePitchPropeller { children = [.controllablePitchPropeller] }
            if [.turboprop, .turboshaft, .turbojet, .turbofan].contains(feature) { children.append(.turbine) }
            if feature == .highAltitude { children.append(.pressurized) }
            for child in children {
                corrections[child.rawValue] = true
                for alternative in child.alternatives { corrections[alternative.rawValue] = false }
            }
        }
        if (!enabled && [.pfd, .mfd, .gps, .twoAxisAutopilot].contains(feature)) { corrections[AircraftFeature.taa.rawValue] = false }
        if !enabled && feature == .controllablePitchPropeller {
            corrections[AircraftFeature.constantSpeedPropeller.rawValue] = false
            corrections[AircraftFeature.manualControllablePitchPropeller.rawValue] = false
        }
        if !enabled && feature == .turbine {
            for engine in [AircraftFeature.turboprop, .turboshaft, .turbojet, .turbofan] { corrections[engine.rawValue] = false }
        }
        if !enabled && [.turboprop, .turboshaft, .turbojet, .turbofan].contains(feature),
           ![AircraftFeature.turboprop, .turboshaft, .turbojet, .turbofan].contains(where: selected) {
            corrections[AircraftFeature.turbine.rawValue] = false
        }
        if (!enabled && [.retractableGear, .flaps, .controllablePitchPropeller].contains(feature)) {
            if feature != .retractableGear || !["ASES", "AMES"].contains(category) { corrections[AircraftFeature.complex.rawValue] = false }
        }
        if enabled && feature == .fixedGear && !["ASES", "AMES"].contains(category) { corrections[AircraftFeature.complex.rawValue] = false }
        if enabled && feature == .fixedPitchPropeller { corrections[AircraftFeature.complex.rawValue] = false }
        if enabled && [.piston, .electric, .rotaryEngine].contains(feature) { corrections[AircraftFeature.turbine.rawValue] = false }
        if !enabled && feature == .pressurized { corrections[AircraftFeature.highAltitude.rawValue] = false }
    }
    static func recorded(_ flight: Flight) -> AircraftEquipmentState {
        var state = AircraftEquipmentState(category: flight.category, source: "Equipment recorded for this flight", recordedFlight: true)
        state.detected = Dictionary(uniqueKeysWithValues: AircraftFeature.allCases.map { ($0.rawValue, flight.hasAircraftFeature($0)) })
        return state
    }
    static func imported(_ flight: Flight, model: String, category: String,
                         info: AircraftInfo?, saved: SavedAircraft?) -> AircraftEquipmentState {
        var state = recorded(flight)
        state.category = category
        let detection = AircraftFeatures.detect(model, category: category, info: info ?? saved?.equipmentInfo)
        state.detected = state.detected.merging(detection.values, uniquingKeysWith: { _, registry in registry })
        if let saved {
            for (key, enabled) in saved.resolvedEquipmentFeatures {
                // An old unchecked default must not erase positive CSV evidence.
                // Explicit aircraft corrections, including false, still take priority.
                if !enabled, state.detected[key] == true, saved.featureCorrections?[key] == nil { continue }
                state.detected[key] = enabled
            }
            state.corrections = saved.featureCorrections ?? saved.equipmentCorrections.filter { $0.value }
        }
        state.horsepower = detection.horsepower; state.engines = detection.engines
        state.source = detection.source; state.modelSourceURL = detection.modelSourceURL
        return state
    }
    func aircraft(registration: String, model: String, category: String, previous: SavedAircraft?, info: AircraftInfo?) -> SavedAircraft {
        var saved = previous ?? SavedAircraft(registration: registration, model: model)
        saved.registration = registration; saved.model = AircraftNames.display(model); saved.category = category
        if !recordedFlight {
            saved.detectedFeatures = detected
            saved.featureCorrections = corrections
            saved.equipmentInfo = info ?? previous?.equipmentInfo
        } else if !corrections.isEmpty {
            saved.featureCorrections = saved.equipmentCorrections.merging(corrections, uniquingKeysWith: { _, new in new })
        }
        let resolved = recordedFlight ? (saved.detectedFeatures ?? [:]).merging(saved.equipmentCorrections, uniquingKeysWith: { _, new in new }) : values
        if !recordedFlight || !corrections.isEmpty {
            saved.complex = resolved["complex"]; saved.highPerformance = resolved["hp"]
            saved.taa = resolved["taa"]; saved.turbine = resolved["turbine"]
        }
        return saved
    }
    func apply(to flight: inout Flight) {
        let result = values
        flight.complex = result["complex"] == true; flight.highPerformance = result["hp"] == true; flight.taa = result["taa"] == true
        for feature in AircraftFeature.allCases where ![.complex, .highPerformance, .taa].contains(feature) {
            let key = feature == .turbine ? "turbine" : "aircraftFeature." + feature.rawValue
            if feature == .tailwheel { flight.facts.flags.remove("tailwheel") }
            if feature == .turbine { flight.facts.flags.remove("aircraftFeature.turbine") }
            if result[feature.rawValue] == true { flight.facts.flags.insert(key) } else { flight.facts.flags.remove(key) }
        }
    }
}

enum AircraftFeatureSync {
    @discardableResult static func apply(_ values: [String: Bool], registration: String,
                                        to flights: inout [Flight], explicitCSVCorrections: Set<String>? = nil) -> Bool {
        let target = AircraftNames.registration(registration)
        guard !target.isEmpty, !values.isEmpty else { return false }
        var changed = false
        for index in flights.indices where !flights[index].isDevice && flights[index].registration == target {
            for feature in AircraftFeature.allCases {
                guard let enabled = values[feature.rawValue], flights[index].hasAircraftFeature(feature) != enabled else { continue }
                if !enabled, flights[index].facts.text["csvSource"] != nil,
                   let explicitCSVCorrections, !explicitCSVCorrections.contains(feature.rawValue) { continue }
                switch feature {
                case .complex: flights[index].complex = enabled
                case .highPerformance: flights[index].highPerformance = enabled
                case .taa: flights[index].taa = enabled
                default:
                    let key = feature == .turbine ? "turbine" : "aircraftFeature." + feature.rawValue
                    if feature == .tailwheel { flights[index].facts.flags.remove("tailwheel") }
                    if feature == .turbine { flights[index].facts.flags.remove("aircraftFeature.turbine") }
                    if enabled { flights[index].facts.flags.insert(key) }
                    else { flights[index].facts.flags.remove(key) }
                }
                changed = true
            }
        }
        // Keep the original signature and confirmation receipts. Their existing
        // digest checks report any changed record instead of re-signing it.
        return changed
    }
    @discardableResult static func applySavedFeatures(_ aircraft: [SavedAircraft],
                                                     to flights: inout [Flight]) -> Bool {
        var changed = false
        for item in aircraft {
            if apply(item.resolvedEquipmentFeatures, registration: item.registration, to: &flights,
                     explicitCSVCorrections: Set((item.featureCorrections ?? [:]).keys)) { changed = true }
        }
        return changed
    }
}
