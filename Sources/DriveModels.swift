import SwiftUI
import CoreLocation
import AVFoundation

// MARK: - Units

enum SpeedUnits: String, CaseIterable, Identifiable, Codable {
    case kmh, mph, both
    var id: String { rawValue }
    var label: String {
        switch self { case .kmh: return "km/h"; case .mph: return "mph"; case .both: return "Both" }
    }
    var metricDistances: Bool { self != .mph }

    static func kmh(_ mps: Double) -> Double { mps * 3.6 }
    static func mph(_ mps: Double) -> Double { mps * 2.236936 }

    /// Main value / unit, plus optional secondary for `.both`.
    func speed(_ mps: Double) -> (value: String, unit: String, secondary: String?) {
        let k = Int(Self.kmh(max(mps, 0)).rounded())
        let m = Int(Self.mph(max(mps, 0)).rounded())
        switch self {
        case .kmh: return ("\(k)", "km/h", nil)
        case .mph: return ("\(m)", "mph", nil)
        case .both: return ("\(k)", "km/h", "\(m) mph")
        }
    }

    /// Speed limit (stored in km/h) in display units.
    func limit(_ kmh: Double) -> (value: String, secondary: String?) {
        switch self {
        case .kmh: return ("\(Int(kmh.rounded()))", nil)
        case .mph: return ("\(Int((kmh / 1.609344).rounded()))", nil)
        case .both: return ("\(Int(kmh.rounded()))", "\(Int((kmh / 1.609344).rounded())) mph")
        }
    }

    func speedText(_ mps: Double) -> String {
        let s = speed(mps)
        return s.secondary.map { "\(s.value) \(s.unit) (\($0))" } ?? "\(s.value) \(s.unit)"
    }

    func distance(_ meters: Double) -> String {
        if metricDistances {
            if meters >= 1000 { return String(format: meters >= 10_000 ? "%.0f km" : "%.1f km", meters / 1000) }
            let r = meters >= 300 ? (meters / 50).rounded() * 50 : (meters / 10).rounded() * 10
            return "\(Int(max(r, 0))) m"
        } else {
            let miles = meters / 1609.344
            if miles >= 0.2 { return String(format: miles >= 10 ? "%.0f mi" : "%.1f mi", miles) }
            let ft = (meters * 3.28084 / 50).rounded() * 50
            return "\(Int(max(ft, 0))) ft"
        }
    }

    /// Phrase for speech, e.g. "500 metres".
    func spokenDistance(_ meters: Double) -> String {
        if metricDistances {
            if meters >= 950 { return String(format: "%.0f kilometre%@", (meters / 1000).rounded(), meters >= 1500 ? "s" : "") }
            let r = meters >= 300 ? (meters / 100).rounded() * 100 : (meters / 50).rounded() * 50
            return "\(Int(max(r, 50))) metres"
        } else {
            let miles = meters / 1609.344
            if miles >= 0.4 {
                if miles < 0.75 { return "half a mile" }
                return String(format: "%.0f mile%@", miles.rounded(), miles >= 1.5 ? "s" : "")
            }
            let ft = (meters * 3.28084 / 100).rounded() * 100
            return "\(Int(max(ft, 100))) feet"
        }
    }
}

enum VehicleKind: String, CaseIterable, Identifiable {
    case car, motorcycle, truck
    var id: String { rawValue }
    var label: String {
        switch self { case .car: return "Car"; case .motorcycle: return "Motorcycle"; case .truck: return "Truck" }
    }
    /// How much earlier alerts start. Trucks need more room; motorcycles a little more.
    var distanceScale: Double {
        switch self { case .car: return 1; case .motorcycle: return 1.25; case .truck: return 1.7 }
    }
}

enum WarnReach: String, CaseIterable, Identifiable {
    case near, normal, far
    var id: String { rawValue }
    var label: String {
        switch self { case .near: return "Near"; case .normal: return "Normal"; case .far: return "Far" }
    }
    var scale: Double {
        switch self { case .near: return 0.65; case .normal: return 1; case .far: return 1.55 }
    }
}

enum SoundMode: String, CaseIterable, Identifiable {
    case both, voiceOnly, chimeOnly, silent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .both: return "Chime + voice"
        case .voiceOnly: return "Voice only"
        case .chimeOnly: return "Chime only"
        case .silent: return "Silent"
        }
    }
    var chime: Bool { self == .both || self == .chimeOnly }
    var voice: Bool { self == .both || self == .voiceOnly }
}

enum MapStyleChoice: String, CaseIterable, Identifiable {
    case tesla, standard, satellite, hybrid, terrain
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tesla: return "3D City"
        case .standard: return "Standard"
        case .satellite: return "Satellite"
        case .hybrid: return "Hybrid"
        case .terrain: return "Terrain 3D"
        }
    }
    var icon: String {
        switch self {
        case .tesla: return "building.2.fill"
        case .standard: return "map.fill"
        case .satellite: return "globe.americas.fill"
        case .hybrid: return "square.2.layers.3d.fill"
        case .terrain: return "mountain.2.fill"
        }
    }
}

// MARK: - Drive settings

final class DriveSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var speedUnits: SpeedUnits { didSet { d.set(speedUnits.rawValue, forKey: "dr.speedUnits") } }
    @Published var soundMode: SoundMode { didSet { d.set(soundMode.rawValue, forKey: "dr.soundMode") } }
    @Published var chimeVolume: Double { didSet { d.set(chimeVolume, forKey: "dr.chimeVolume") } }
    @Published var hapticsOn: Bool { didSet { d.set(hapticsOn, forKey: "dr.haptics") } }
    @Published var cameraAlerts: Bool { didSet { d.set(cameraAlerts, forKey: "dr.cameraAlerts") } }
    @Published var trapAlerts: Bool { didSet { d.set(trapAlerts, forKey: "dr.trapAlerts") } }
    @Published var schoolAlerts: Bool { didSet { d.set(schoolAlerts, forKey: "dr.schoolAlerts") } }
    @Published var crossingAlerts: Bool { didSet { d.set(crossingAlerts, forKey: "dr.crossingAlerts") } }
    @Published var speedingAlerts: Bool { didSet { d.set(speedingAlerts, forKey: "dr.speedingAlerts") } }
    @Published var speedingTolerance: Double { didSet { d.set(speedingTolerance, forKey: "dr.speedingTolerance") } }
    @Published var offRoadWarnings: Bool { didSet { d.set(offRoadWarnings, forKey: "dr.offRoad") } }
    @Published var backgroundDriving: Bool { didSet { d.set(backgroundDriving, forKey: "dr.background") } }
    @Published var mapStyle: MapStyleChoice { didSet { d.set(mapStyle.rawValue, forKey: "dr.mapStyle") } }
    @Published var showTraffic: Bool { didSet { d.set(showTraffic, forKey: "dr.traffic") } }
    @Published var autoNight: Bool { didSet { d.set(autoNight, forKey: "dr.autoNight") } }
    @Published var forceDark: Bool { didSet { d.set(forceDark, forKey: "dr.forceDark") } }
    /// Drive screen look: false = Dark (default), true = Light nav style with a light map.
    @Published var lightNav: Bool { didSet { d.set(lightNav, forKey: "dr.lightNav") } }
    @Published var avoidTraps: Bool { didSet { d.set(avoidTraps, forKey: "dr.avoidTraps") } }
    @Published var hudMirror: Bool { didSet { d.set(hudMirror, forKey: "dr.hudMirror") } }
    @Published var fuelPer100km: Double { didSet { d.set(fuelPer100km, forKey: "dr.fuel") } }
    @Published var voiceIdentifier: String { didSet { d.set(voiceIdentifier, forKey: "dr.voice") } }
    @Published var crashDetection: Bool { didSet { d.set(crashDetection, forKey: "dr.crash") } }
    @Published var fatigueReminder: Bool { didSet { d.set(fatigueReminder, forKey: "dr.fatigue") } }
    @Published var hotspotAlerts: Bool { didSet { d.set(hotspotAlerts, forKey: "dr.hotspots") } }
    @Published var weatherAlerts: Bool { didSet { d.set(weatherAlerts, forKey: "dr.weather") } }
    @Published var bumpAlerts: Bool { didSet { d.set(bumpAlerts, forKey: "dr.bumps") } }
    @Published var vehicle: VehicleKind { didSet { d.set(vehicle.rawValue, forKey: "dr.vehicle") } }
    @Published var warnReach: WarnReach { didSet { d.set(warnReach.rawValue, forKey: "dr.warnReach") } }
    @Published var personalCapKmh: Double { didSet { d.set(personalCapKmh, forKey: "dr.personalCap") } }

    init() {
        d.register(defaults: [
            "dr.speedUnits": SpeedUnits.kmh.rawValue, "dr.soundMode": SoundMode.both.rawValue,
            "dr.chimeVolume": 0.3, "dr.haptics": true, "dr.cameraAlerts": true, "dr.trapAlerts": true,
            "dr.schoolAlerts": true, "dr.crossingAlerts": true, "dr.speedingAlerts": true,
            "dr.speedingTolerance": 3.0, "dr.offRoad": true, "dr.background": true,
            "dr.mapStyle": MapStyleChoice.tesla.rawValue, "dr.traffic": true, "dr.autoNight": true,
            "dr.forceDark": true, "dr.lightNav": true, "dr.avoidTraps": false, "dr.hudMirror": false, "dr.fuel": 8.0,
            "dr.voice": "", "dr.crash": true, "dr.fatigue": true, "dr.hotspots": true, "dr.weather": true,
            "dr.bumps": true, "dr.vehicle": VehicleKind.car.rawValue, "dr.warnReach": WarnReach.normal.rawValue,
            "dr.personalCap": 0.0,
        ])
        speedUnits = SpeedUnits(rawValue: d.string(forKey: "dr.speedUnits") ?? "") ?? .kmh
        soundMode = SoundMode(rawValue: d.string(forKey: "dr.soundMode") ?? "") ?? .both
        chimeVolume = d.double(forKey: "dr.chimeVolume")
        hapticsOn = d.bool(forKey: "dr.haptics")
        cameraAlerts = d.bool(forKey: "dr.cameraAlerts")
        trapAlerts = d.bool(forKey: "dr.trapAlerts")
        schoolAlerts = d.bool(forKey: "dr.schoolAlerts")
        crossingAlerts = d.bool(forKey: "dr.crossingAlerts")
        speedingAlerts = d.bool(forKey: "dr.speedingAlerts")
        speedingTolerance = d.double(forKey: "dr.speedingTolerance")
        offRoadWarnings = d.bool(forKey: "dr.offRoad")
        backgroundDriving = d.bool(forKey: "dr.background")
        mapStyle = MapStyleChoice(rawValue: d.string(forKey: "dr.mapStyle") ?? "") ?? .tesla
        showTraffic = d.bool(forKey: "dr.traffic")
        autoNight = d.bool(forKey: "dr.autoNight")
        forceDark = d.bool(forKey: "dr.forceDark")
        lightNav = d.bool(forKey: "dr.lightNav")
        // The whole app now uses the light reference look; Light is forced.
        d.set(true, forKey: "dr.lightMigrated")
        lightNav = true
        d.set(true, forKey: "dr.lightNav")
        avoidTraps = d.bool(forKey: "dr.avoidTraps")
        hudMirror = d.bool(forKey: "dr.hudMirror")
        fuelPer100km = d.double(forKey: "dr.fuel")
        voiceIdentifier = d.string(forKey: "dr.voice") ?? ""
        crashDetection = d.bool(forKey: "dr.crash")
        fatigueReminder = d.bool(forKey: "dr.fatigue")
        hotspotAlerts = d.bool(forKey: "dr.hotspots")
        weatherAlerts = d.bool(forKey: "dr.weather")
        bumpAlerts = d.bool(forKey: "dr.bumps")
        vehicle = VehicleKind(rawValue: d.string(forKey: "dr.vehicle") ?? "") ?? .car
        warnReach = WarnReach(rawValue: d.string(forKey: "dr.warnReach") ?? "") ?? .normal
        personalCapKmh = d.double(forKey: "dr.personalCap")
    }
}

// MARK: - Alerts

enum AlertKind: String, Codable, CaseIterable, Sendable {
    case camera, avgSpeed, redLight, trap, speeding, school, crossing, offRoad, hotspot, weather, turn, fatigue, info

    var icon: String {
        switch self {
        case .camera: return "camera.fill"
        case .avgSpeed: return "gauge.with.dots.needle.33percent"
        case .redLight: return "light.beacon.max.fill"
        case .trap: return "exclamationmark.triangle.fill"
        case .speeding: return "speedometer"
        case .school: return "figure.and.child.holdinghands"
        case .crossing: return "tram.fill"
        case .offRoad: return "road.lanes"
        case .hotspot: return "flame.fill"
        case .weather: return "cloud.heavyrain.fill"
        case .turn: return "arrow.turn.up.right"
        case .fatigue: return "cup.and.saucer.fill"
        case .info: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .camera, .avgSpeed, .redLight, .trap, .school, .crossing, .offRoad, .hotspot, .speeding: return Theme.amber
        case .weather, .fatigue: return Theme.amber
        case .turn, .info: return Theme.accent
        }
    }
}

struct DriveAlert: Identifiable, Equatable, Sendable {
    let id = UUID()
    var key: String
    var kind: AlertKind
    var title: String
    var subtitle: String
    var distance: Double?
    var startDistance: Double?
    var imminent = false
    var created = Date()
    var lifetime: TimeInterval = 8

    var progress: Double? {
        guard let d = distance, let s = startDistance, s > 0 else { return nil }
        return min(max(1 - d / s, 0), 1)
    }
}

// MARK: - Trap reports

enum TrapType: String, Codable, CaseIterable, Identifiable {
    case speedTrap, camera, hazard, accident, roadwork, traffic, police
    var id: String { rawValue }

    /// Unknown raw values (e.g. from a newer/older build or an imported file) decode as .hazard.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TrapType(rawValue: raw) ?? .hazard
    }
    var label: String {
        switch self {
        case .speedTrap: return "Speed check"
        case .camera: return "Camera"
        case .hazard: return "Hazard"
        case .accident: return "Crash"
        case .roadwork: return "Roadwork"
        case .traffic: return "Traffic"
        case .police: return "Police"
        }
    }
    var icon: String {
        switch self {
        case .speedTrap: return "exclamationmark.triangle.fill"
        case .camera: return "camera.fill"
        case .hazard: return "exclamationmark.octagon.fill"
        case .accident: return "car.side.rear.and.collision.and.car.side.front"
        case .roadwork: return "cone.fill"
        case .traffic: return "car.2.fill"
        case .police: return "shield.lefthalf.filled"
        }
    }
}

struct TrapReport: Codable, Identifiable, Hashable {
    var id = UUID()
    var type: TrapType
    var latitude: Double
    var longitude: Double
    var heading: Double?
    var created = Date()
    var note: String = ""
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

// MARK: - Places

struct FavouritePlace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var icon: String = "star.fill"
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

// MARK: - Trips

struct TripRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Date
    var end: Date
    var distance: Double            // m
    var maxSpeed: Double            // m/s
    var movingSeconds: Double
    var idleSeconds: Double
    var speedingSeconds: Double
    var harshBrakes: Int
    var harshAccels: Int
    var hardCorners: Int
    var score: Int
    var startLat: Double?
    var startLon: Double?
    var endLat: Double?
    var endLon: Double?
    var fuelLitres: Double?

    var duration: Double { end.timeIntervalSince(start) }
    var avgSpeed: Double { movingSeconds > 0 ? distance / movingSeconds : 0 }
}

struct EventSpot: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var kind: String
    var date: Date
}

// MARK: - Persistence helper

enum DiskStore {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrapRadar", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let url = dir.appendingPathComponent(name)
        DispatchQueue.global(qos: .utility).async {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(value) { try? data.write(to: url, options: .atomic) }
        }
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(type, from: data)
    }
}
