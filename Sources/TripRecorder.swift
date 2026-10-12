import Foundation
import CoreLocation
import CoreMotion
import UIKit

/// Records trips and driving-behaviour events. Longitudinal acceleration comes from GPS speed change,
/// cornering from the gyro yaw rate (orientation-independent) times speed.
final class TripRecorder: ObservableObject {
    struct Live: Codable {
        var start = Date()
        var distance = 0.0
        var maxSpeed = 0.0
        var moving = 0.0
        var idle = 0.0
        var speeding = 0.0
        var brakes = 0
        var accels = 0
        var corners = 0
        var startLat: Double?
        var startLon: Double?
        var lastLat: Double?
        var lastLon: Double?
        var updated = Date()
        var startCoord: CLLocationCoordinate2D? {
            get { startLat.flatMap { la in startLon.map { CLLocationCoordinate2D(latitude: la, longitude: $0) } } }
            set { startLat = newValue?.latitude; startLon = newValue?.longitude }
        }
    }

    static let minTripMeters = 100.0
    static let stopTimeout: TimeInterval = 120
    private static let activeFile = "active_trip.json"
    private var lastCheckpoint = Date.distantPast
    /// Last fix accepted for distance (accuracy-filtered).
    private var lastGoodLoc: CLLocation?

    @Published private(set) var trips: [TripRecord] = []
    @Published private(set) var active = false
    @Published private(set) var live = Live()
    @Published private(set) var lastEvent: (text: String, date: Date)?
    private(set) var eventSpots: [EventSpot] = []

    var onEvent: ((String, CLLocationCoordinate2D?) -> Void)?
    var onTripEnded: ((TripRecord, CLLocationCoordinate2D?) -> Void)?
    var onMotion: ((CMDeviceMotion) -> Void)?
    var fuelPer100km: () -> Double = { 8 }

    private let motion = CMMotionManager()
    private var lastLoc: CLLocation?
    private var lastSpeed: Double?
    private var accelEMA = 0.0
    private var movingFixes = 0
    private var stoppedSince: Date?
    private var lastBrake = Date.distantPast
    private var lastAccel = Date.distantPast
    private var lastCorner = Date.distantPast
    private var cornerSince: Date?
    private var currentSpeed = 0.0
    private var lastCoord: CLLocationCoordinate2D?
    private(set) var lastMovingDate: Date?

    init() {
        trips = DiskStore.load([TripRecord].self, "trips.json") ?? []
        eventSpots = DiskStore.load([EventSpot].self, "events.json") ?? []
        recoverInterruptedTrip()
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endTrip(synchronous: true)
        }
    }

    /// A trip that was in progress when the app was killed is committed on next launch.
    private func recoverInterruptedTrip() {
        guard let l = DiskStore.load(Live.self, Self.activeFile) else { return }
        clearCheckpoint()
        commit(l, end: l.updated, endCoord: l.lastLat.flatMap { la in l.lastLon.map { CLLocationCoordinate2D(latitude: la, longitude: $0) } }, synchronous: false)
    }

    private func checkpoint(force: Bool = false) {
        guard active, force || Date().timeIntervalSince(lastCheckpoint) >= 30 else { return }
        lastCheckpoint = Date()
        var l = live
        l.updated = Date()
        l.lastLat = lastCoord?.latitude; l.lastLon = lastCoord?.longitude
        writeSync(l, Self.activeFile)
    }

    private func clearCheckpoint() {
        try? FileManager.default.removeItem(at: DiskStore.dir.appendingPathComponent(Self.activeFile))
    }

    private func writeSync<T: Encodable>(_ v: T, _ name: String) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(v) { try? d.write(to: DiskStore.dir.appendingPathComponent(name), options: .atomic) }
    }

    /// Called when the app goes to background: persist progress immediately.
    func persistInProgress() { checkpoint(force: true) }

    func update(_ loc: CLLocation, speeding: Bool, speed derivedSpeed: Double? = nil) {
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy < 65 else { return }
        // loc.speed is -1 when CoreLocation has no Doppler speed; prefer the engine-derived speed.
        let speed = max(derivedSpeed ?? loc.speed, 0)
        currentSpeed = speed
        lastCoord = loc.coordinate
        if speed > 1.5 { lastMovingDate = Date() }

        if !active {
            movingFixes = speed > 4.2 ? movingFixes + 1 : 0
            if movingFixes >= 3 { startTrip(at: loc) }
            lastLoc = loc
            lastSpeed = speed
            return
        }

        if let prev = lastLoc {
            let dt = loc.timestamp.timeIntervalSince(prev.timestamp)
            if dt > 0, dt < 10 {
                accumulateDistance(loc, speed: speed)
                if speed > 1 { live.moving += dt; stoppedSince = nil } else {
                    live.idle += dt
                    if stoppedSince == nil { stoppedSince = Date() }
                }
                if speeding { live.speeding += dt }
                live.maxSpeed = max(live.maxSpeed, speed)
                if let ls = lastSpeed, dt >= 0.5, dt <= 3, (loc.speedAccuracy < 0 || loc.speedAccuracy < 2.5) {
                    let a = (speed - ls) / dt
                    accelEMA = 0.6 * a + 0.4 * accelEMA
                    let now = Date()
                    if accelEMA < -3.5, now.timeIntervalSince(lastBrake) > 6 {
                        lastBrake = now
                        live.brakes += 1
                        record("Harsh braking", kind: "brake", at: loc.coordinate)
                    } else if accelEMA > 3.0, now.timeIntervalSince(lastAccel) > 6 {
                        lastAccel = now
                        live.accels += 1
                        record("Harsh acceleration", kind: "accel", at: loc.coordinate)
                    }
                }
            }
        }
        lastLoc = loc
        lastSpeed = speed
        live.lastLat = loc.coordinate.latitude; live.lastLon = loc.coordinate.longitude
        checkpoint()

        if let s = stoppedSince, Date().timeIntervalSince(s) > Self.stopTimeout { endTrip() }
    }

    /// Accurate distance: only fresh fixes with <= 20 m accuracy, no drift while stationary, no teleport jumps.
    private func accumulateDistance(_ loc: CLLocation, speed: Double) {
        guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 20,
              abs(loc.timestamp.timeIntervalSinceNow) <= 5 else { return }
        guard let g = lastGoodLoc else { lastGoodLoc = loc; return }
        let dt = loc.timestamp.timeIntervalSince(g.timestamp)
        guard dt > 0 else { return }
        let d = loc.distance(from: g)
        if d / dt > 70 { lastGoodLoc = loc; return }          // impossible jump: re-anchor, don't count
        if speed < 1 && d < max(loc.horizontalAccuracy, g.horizontalAccuracy) { return } // stationary drift
        live.distance += d
        lastGoodLoc = loc
    }

    private func record(_ text: String, kind: String, at c: CLLocationCoordinate2D?) {
        lastEvent = (text, Date())
        if let c {
            eventSpots.append(EventSpot(latitude: c.latitude, longitude: c.longitude, kind: kind, date: Date()))
            if eventSpots.count > 500 { eventSpots.removeFirst(eventSpots.count - 500) }
            DiskStore.save(eventSpots, "events.json")
        }
        onEvent?(text, c)
    }

    private func startTrip(at loc: CLLocation) {
        active = true
        live = Live()
        live.startCoord = loc.coordinate
        lastGoodLoc = loc
        stoppedSince = nil
        accelEMA = 0
        startMotion()
    }

    func endTrip(synchronous: Bool = false) {
        guard active else { return }
        active = false
        stopMotion()
        let l = live
        live = Live()
        lastGoodLoc = nil
        clearCheckpoint()
        commit(l, end: Date(), endCoord: lastCoord, synchronous: synchronous)
    }

    private func commit(_ l: Live, end: Date, endCoord: CLLocationCoordinate2D?, synchronous: Bool) {
        guard l.distance >= Self.minTripMeters else { return }
        let lastCoord = endCoord
        let fuel = l.distance / 1000 * fuelPer100km() / 100
        let rec = TripRecord(start: l.start, end: end, distance: l.distance, maxSpeed: l.maxSpeed,
                             movingSeconds: l.moving, idleSeconds: l.idle, speedingSeconds: l.speeding,
                             harshBrakes: l.brakes, harshAccels: l.accels, hardCorners: l.corners,
                             score: Self.score(distance: l.distance, moving: l.moving, idle: l.idle, speeding: l.speeding,
                                               brakes: l.brakes, accels: l.accels, corners: l.corners),
                             startLat: l.startCoord?.latitude, startLon: l.startCoord?.longitude,
                             endLat: lastCoord?.latitude, endLon: lastCoord?.longitude, fuelLitres: fuel)
        trips.insert(rec, at: 0)
        if trips.count > 400 { trips.removeLast(trips.count - 400) }
        if synchronous { writeSync(trips, "trips.json") } else { DiskStore.save(trips, "trips.json") }
        onTripEnded?(rec, lastCoord)
    }

    func deleteTrip(_ t: TripRecord) {
        trips.removeAll { $0.id == t.id }
        DiskStore.save(trips, "trips.json")
    }

    var liveScore: Int {
        Self.score(distance: live.distance, moving: live.moving, idle: live.idle, speeding: live.speeding,
                   brakes: live.brakes, accels: live.accels, corners: live.corners)
    }

    static func score(distance: Double, moving: Double, idle: Double, speeding: Double, brakes: Int, accels: Int, corners: Int) -> Int {
        let km = distance / 1000
        let scale = 10 / max(km, 10)
        var s = 100.0
        s -= Double(8 * brakes + 5 * accels + 5 * corners) * scale
        if moving > 0 { s -= min(35, speeding / moving * 35) }
        let total = moving + idle
        if total > 0 { s -= min(10, idle / total * 20) }
        return Int(max(0, min(100, s)).rounded())
    }

    // MARK: Motion (cornering)

    private func startMotion() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self, let m else { return }
            self.onMotion?(m)
            let g = m.gravity
            let gn = sqrt(g.x * g.x + g.y * g.y + g.z * g.z)
            guard gn > 0.5 else { return }
            let r = m.rotationRate
            let yaw = abs((r.x * g.x + r.y * g.y + r.z * g.z) / gn)   // rad/s around vertical
            let lateral = yaw * self.currentSpeed                         // m/s²
            let now = Date()
            if lateral > 3.5 && self.currentSpeed > 5 {
                if self.cornerSince == nil { self.cornerSince = now }
                if let s = self.cornerSince, now.timeIntervalSince(s) >= 0.6, now.timeIntervalSince(self.lastCorner) > 8 {
                    self.lastCorner = now
                    self.live.corners += 1
                    self.record("Hard cornering", kind: "corner", at: self.lastCoord)
                }
            } else {
                self.cornerSince = nil
            }
        }
    }

    private func stopMotion() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }

    /// Keeps the motion sensor running for crash detection even before a trip starts (when driving mode on).
    func ensureMotion() { startMotion() }
}
