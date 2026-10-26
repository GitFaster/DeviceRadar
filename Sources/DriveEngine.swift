import Foundation
import CoreLocation
import CoreMotion
import MapKit
import UIKit
import UserNotifications
//
/// Smoothly interpolates the car marker between GPS fixes.
final class MarkerAnimator: ObservableObject {
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var bearing: Double = 0
    private var from: CLLocationCoordinate2D?
    private var to: CLLocationCoordinate2D?
    private var fromBearing = 0.0
    private var toBearing = 0.0
    private var start = Date()
    private var duration = 1.0
    private var timer: Timer?

    func move(to c: CLLocationCoordinate2D, bearing b: Double, duration d: Double) {
        guard let current = coordinate else {
            coordinate = c; bearing = b; return
        }
        if Geo.distance(current, c) > 300 { coordinate = c; bearing = b; return }
        from = current
        to = c
        fromBearing = bearing
        toBearing = b
        start = Date()
        duration = max(0.25, min(d, 2))
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func tick() {
        guard let from, let to else { stopTimer(); return }
        let t = min(1, Date().timeIntervalSince(start) / duration)
        coordinate = Geo.interpolate(from, to, t)
        bearing = Geo.interpolateAngle(fromBearing, toBearing, t)
        if t >= 1 { stopTimer() }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

struct AvgSpeedSection: Equatable {
    var id: String
    var limit: Double?
    var end: CLLocationCoordinate2D
    var started: Date
    var distance: Double
    var average: Double { let t = Date().timeIntervalSince(started); return t > 0 ? distance / t : 0 }
    static func == (a: AvgSpeedSection, b: AvgSpeedSection) -> Bool { a.id == b.id && a.distance == b.distance }
}

final class DriveEngine: NSObject, ObservableObject, CLLocationManagerDelegate {
    let settings: DriveSettings
    let osm = OSMService()
    let alerts: AlertCenter
    let trips = TripRecorder()
    let nav = NavigationEngine()
    let traps: TrapStore
    let marker = MarkerAnimator()

    @Published private(set) var location: CLLocation?
    @Published private(set) var speed: Double = 0
    @Published private(set) var course: Double = 0
    @Published private(set) var deviceHeading: Double?
    @Published private(set) var snapped: CLLocationCoordinate2D?
    @Published private(set) var snappedToRoute = false
    @Published private(set) var roadName: String?
    @Published private(set) var speedLimit: Double?
    @Published private(set) var isSpeeding = false
    @Published private(set) var nearbyHazards: [OSMHazard] = []
    @Published private(set) var lanes: [[String]]?
    @Published private(set) var offRoad = false
    @Published private(set) var section: AvgSpeedSection?
    @Published private(set) var hazardStatus = "Camera data not loaded yet"
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var running = false
    @Published var crashSuspected = false

    private let manager = CLLocationManager()
    private var lastHazardFilterCenter: CLLocationCoordinate2D?
    private var speedingSince: Date?
    private var offRoadSince: Date?
    private var lastLimitDate = Date.distantPast
    private var lastRoadId: Int64?
    private var sectionCandidate: OSMHazard?
    // speed estimation
    private var lastSpeedFix = Date.distantPast
    private var lastSpeedValue = 0.0
    private var derivedFrom: CLLocation?
    private var speedTimer: Timer?
    var isBackground = false {
        didSet {
            let center = alerts
            let background = isBackground
            Task { @MainActor in
                center.isBackground = background
            }
        }
    }

    var heading: Double { speed > 2 ? course : (deviceHeading ?? course) }
    var displayCoordinate: CLLocationCoordinate2D? { snapped ?? location?.coordinate }

    /// Best location usable for routing. On Mac Catalyst this also accepts the manager's
    /// last known (approximate Wi-Fi) fix; on iOS it is exactly `location`.
    var routingLocation: CLLocation? {
        #if targetEnvironment(macCatalyst)
        return location ?? manager.location
        #else
        return location
        #endif
    }

    @MainActor
    init(settings: DriveSettings, traps: TrapStore) {
        self.settings = settings
        self.traps = traps
        self.alerts = AlertCenter(settings: settings)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = 2
        manager.pausesLocationUpdatesAutomatically = false
        #if targetEnvironment(macCatalyst)
        // Macs only have Wi-Fi positioning: ask for what the hardware can deliver.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 10
        #endif
        authorization = manager.authorizationStatus

        nav.spoken = { [weak self] d in self?.settings.speedUnits.spokenDistance(d) ?? "\(Int(d)) metres" }
        nav.onRouteStartedSeed = { [weak self] in self?.location }
        nav.onPrompt = { [weak self] text in
            guard let center = self?.alerts else { return }
            Task { @MainActor in
                center.navigationPrompt(text)
            }
        }
        nav.avoidTraps = { [weak self] in self?.settings.avoidTraps ?? false }
        nav.hazardScorer = { [weak self] coords in self?.hazardCount(along: coords) ?? 0 }
        nav.onRouteStarted = { [weak self] coords in
            self?.osm.refreshRouteHazards(along: coords) { _ in self?.refilterHazards(force: true) }
        }
        trips.fuelPer100km = { [weak self] in self?.settings.fuelPer100km ?? 8 }
        trips.onMotion = { [weak self] motion in self?.checkCrash(motion) }
        trips.onTripEnded = { [weak self] rec, end in
            self?.fatigueNoted = false
            if let end { self?.rememberParked(end); self?.remindParked(rec, at: end) }
        }
        extraChecks = { [weak self] loc in self?.runExtra(loc) }
        updateHazardStatus()
    }

    // MARK: Main-actor alert bridge

    /// DriveEngine's location and detection pipeline remains synchronous.
    /// AlertCenter owns UI/audio state on the main actor, so bridge each event
    /// explicitly rather than making the entire engine main-actor isolated.
    private func postAlert(
        _ alert: DriveAlert,
        speech: String? = nil,
        notify: Bool = true,
        oncePerKey: Bool = true
    ) {
        let center = alerts
        Task { @MainActor in
            center.raise(
                alert,
                speech: speech,
                notify: notify,
                oncePerKey: oncePerKey
            )
        }
    }

    private func updateOrRaise(
        _ alert: DriveAlert,
        speech: String?
    ) {
        let center = alerts
        Task { @MainActor in
            if center.current?.key == alert.key {
                center.update(alert)
            } else {
                center.raise(alert, speech: speech)
            }
        }
    }

    private func forgetAlert(key: String) {
        let center = alerts
        Task { @MainActor in
            center.forget(key: key)
        }
    }

    // MARK: Lifecycle

    func start() {
        authorization = manager.authorizationStatus

        switch authorization {
        case .notDetermined:
            running = false
            manager.requestWhenInUseAuthorization()
            return
        case .authorizedWhenInUse, .authorizedAlways:
            break
        case .denied, .restricted:
            running = false
            return
        @unknown default:
            running = false
            return
        }

        if settings.backgroundDriving, authorization == .authorizedWhenInUse {
            manager.requestAlwaysAuthorization()
        }

        manager.allowsBackgroundLocationUpdates = settings.backgroundDriving && authorization == .authorizedAlways
        manager.showsBackgroundLocationIndicator = manager.allowsBackgroundLocationUpdates
        manager.startUpdatingLocation()
        #if targetEnvironment(macCatalyst)
        // Seed with the last known fix so routing doesn't sit on "Waiting for GPS…".
        if location == nil, let last = manager.location { process(last) }
        #endif
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        trips.ensureMotion()
        running = true
    }

    func stop() {
        trips.endTrip()
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        running = false
    }

    func enteredBackground() {
        isBackground = true
        manager.stopUpdatingHeading()
        trips.persistInProgress()
        let keep = settings.backgroundDriving && (trips.active || nav.isNavigating || speed > 3)
        if !keep { stop() }
    }

    func enteredForeground() {
        isBackground = false
        start()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways { start() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        deviceHeading = h
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    // MARK: Speed (always a finite number; GPS -> derived -> hold 3 s -> decay)

    private func updateSpeed(with loc: CLLocation) {
        var measured: Double?
        if loc.speed >= 0, loc.speedAccuracy >= 0, loc.speed.isFinite {
            measured = loc.speed
        } else if let p = derivedFrom, loc.horizontalAccuracy < 65 {
            let dt = loc.timestamp.timeIntervalSince(p.timestamp)
            if dt >= 0.5, dt <= 10 {
                let raw = loc.distance(from: p) / dt
                if raw.isFinite, raw < 90 { measured = 0.6 * raw + 0.4 * lastSpeedValue }
            }
        }
        if loc.horizontalAccuracy < 65 { derivedFrom = loc }
        if let m = measured {
            lastSpeedValue = max(0, m)
            lastSpeedFix = Date()
            speed = lastSpeedValue
        }
        ensureSpeedTimer()
    }

    private func ensureSpeedTimer() {
        guard speedTimer == nil else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.speedTick() }
        RunLoop.main.add(t, forMode: .common)
        speedTimer = t
    }

    private func speedTick() {
        let age = Date().timeIntervalSince(lastSpeedFix)
        guard age > 3 else { return }            // hold last value for up to 3 s
        let decayed = lastSpeedValue * max(0, 1 - (age - 3) / 3)   // then decay to 0 over ~3 s
        let v = decayed < 0.3 ? 0 : decayed
        if v != speed || !speed.isFinite { speed = v.isFinite ? v : 0 }
    }

    // MARK: Location pipeline

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations { process(loc) }
    }

    private func process(_ loc: CLLocation) {
        guard loc.horizontalAccuracy >= 0 else { return }
        let previous = location
        location = loc
        updateSpeed(with: loc)
        if loc.course >= 0 && speed > 1.5 { course = loc.course }
        let courseHint: Double? = speed > 2 ? course : nil

        // 1. Snap: active route first (heading disambiguates), else OSM road geometry.
        var snapCoord: CLLocationCoordinate2D?
        var snapBearing: Double?
        snappedToRoute = false
        let moving = speed >= 1
        if nav.isNavigating, let hit = nav.update(loc, course: courseHint, stationary: !moving), moving {
            snapCoord = hit.coordinate
            snapBearing = hit.bearing
            snappedToRoute = true
        }
        let match = osm.nearestRoad(to: loc.coordinate, course: courseHint)
        let snapRadius = max(20, min(loc.horizontalAccuracy * 1.5, 45))
        if let m = match, m.hit.distance <= snapRadius {
            if snapCoord == nil {
                snapCoord = m.hit.coordinate
                snapBearing = m.forward ? m.hit.bearing : Geo.normalize(m.hit.bearing + 180)
            }
            roadName = m.road.name
            if let lim = m.road.maxspeed(forward: m.forward) {
                if let prev = speedLimit, lim + 15 <= prev, speed > 5 {
                    let shown = settings.speedUnits.limit(lim)
                    postAlert(DriveAlert(key: "drop-\(m.road.id)-\(Int(lim))", kind: .speeding,
                                            title: "Limit drops",
                                            subtitle: "Now \(shown.value) \(settings.speedUnits == .mph ? "mph" : "km/h")",
                                            imminent: false, lifetime: 6),
                                 speech: "Speed limit drops to \(shown.value)")
                }
                speedLimit = lim
                lastLimitDate = Date()
            } else if m.road.id != lastRoadId, !m.road.isMinor {
                speedLimit = nil
            }
            lastRoadId = m.road.id
            lanes = m.road.turnLanes(forward: m.forward)
        } else {
            if Date().timeIntervalSince(lastLimitDate) > 15 { speedLimit = nil }
            lanes = nil
            if match == nil { roadName = nil }
        }
        // Marker: true GPS position unless moving and snapped within 25 m (route first, then road).
        if !moving || snapCoord.map({ Geo.distance($0, loc.coordinate) > 25 }) == true { snapCoord = nil }
        snapped = snapCoord
        if let b = snapBearing, speed > 2 {
            // trust road bearing only if it roughly agrees with GPS course
            if Geo.angleDiff(b, course) < 50 { course = b }
        }
        marker.move(to: snapCoord ?? loc.coordinate, bearing: heading,
                    duration: previous == nil ? 0 : 0.9)

        // 2. Data refresh (throttled)
        nav.currentRoadName = roadName
        if !RoutePrefs.offline { osm.refreshRoadsIfNeeded(at: loc.coordinate) { } }
        if !RoutePrefs.offline, osm.needsHazardRefresh(at: loc.coordinate) {
            hazardStatus = "Updating camera data…"
            osm.refreshHazards(around: loc.coordinate) { [weak self] ok in
                guard let self else { return }
                if !ok { self.hazardStatus = self.osm.hazards.isEmpty ? "Camera data unavailable (offline?) — will retry" : "Using cached camera data" }
                else { self.updateHazardStatus() }
                self.refilterHazards(force: true)
            }
        }
        refilterHazards(force: false)

        // 3. Alerts
        checkSpeeding(loc)
        checkHazards(loc)
        checkSection(loc, previous: previous)
        checkOffRoad(loc)
        trips.update(loc, speeding: isSpeeding, speed: speed)
        extraChecks(loc)
    }

    /// Fatigue, weather, personal hotspots. Assigned in init.
    var extraChecks: (CLLocation) -> Void = { _ in }
    private var fatigueNoted = false
    private var crashLatched = false
    private var lastFastDate = Date.distantPast
    private var lastWeatherFetch = Date.distantPast
    private var lastWeatherCoord: CLLocationCoordinate2D?

    private func runExtra(_ loc: CLLocation) {
        if speed > 8 { lastFastDate = Date() }
        checkFatigue()
        checkHotspots(loc)
        checkWeather(loc)
    }

    private func checkFatigue() {
        guard settings.fatigueReminder, trips.active else { return }
        guard trips.live.moving >= 2 * 3600, !fatigueNoted else { return }
        fatigueNoted = true
        postAlert(DriveAlert(key: "fatigue-\(Int(trips.live.start.timeIntervalSince1970))", kind: .fatigue,
                                title: "Time for a break",
                                subtitle: "You've been moving for 2 hours",
                                lifetime: 12),
                     speech: "You've been driving for two hours. Time for a break.")
    }

    private func checkHotspots(_ loc: CLLocation) {
        guard settings.hotspotAlerts, speed > 3 else { return }
        let pos = loc.coordinate
        let look = max(200, speed * 12)
        let ahead = trips.eventSpots
            .filter { $0.kind == "brake" || $0.kind == "corner" }
            .filter { Date().timeIntervalSince($0.date) > 120 }
            .map { spot -> (EventSpot, Double) in
                let c = CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
                return (spot, Geo.distance(pos, c))
            }
            .filter { d in
                let c = CLLocationCoordinate2D(latitude: d.0.latitude, longitude: d.0.longitude)
                return d.1 <= look && d.1 > 20 && Geo.angleDiff(Geo.bearing(pos, c), heading) <= 50
            }
            .sorted { $0.1 < $1.1 }
        guard let (spot, d) = ahead.first else { return }
        let key = String(format: "hot-%@-%.3f-%.3f", spot.kind, spot.latitude, spot.longitude)
        let title = spot.kind == "brake" ? "Hard brake here before" : "Hard corner here before"
        postAlert(DriveAlert(key: key, kind: .hotspot, title: title,
                                subtitle: "in \(settings.speedUnits.distance(d))",
                                distance: d, startDistance: look, lifetime: 6),
                     speech: title)
    }

    private func checkWeather(_ loc: CLLocation) {
        guard settings.weatherAlerts else { return }
        let movedFar = lastWeatherCoord.map { Geo.distance($0, loc.coordinate) > 25_000 } ?? true
        guard movedFar || Date().timeIntervalSince(lastWeatherFetch) > 900 else { return }
        lastWeatherFetch = Date()
        lastWeatherCoord = loc.coordinate
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        parts?.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "weather_code,wind_speed_10m,precipitation,temperature_2m"),
            URLQueryItem(name: "wind_speed_unit", value: "kmh"),
        ]
        guard let url = parts?.url else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            if let error {
                // Failed fetch: allow another try in ~2 min instead of waiting the full 15.
                DispatchQueue.main.async { self?.lastWeatherFetch = Date().addingTimeInterval(-780) }
                print("[weather] fetch failed: \(error.localizedDescription)")
                return
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                print("[weather] HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let current = json["current"] as? [String: Any] else { return }
            let code = current["weather_code"] as? Int ?? 0
            let wind = current["wind_speed_10m"] as? Double ?? 0
            let temp = current["temperature_2m"] as? Double ?? 20
            let precip = current["precipitation"] as? Double ?? 0
            guard let warning = Self.weatherWarning(code: code, wind: wind, temp: temp, precip: precip) else { return }
            let (title, speech) = warning
            let hour = Int(Date().timeIntervalSince1970 / 3600)
            DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.postAlert(
                DriveAlert(
                    key: "wx-\(code)-\(hour)",
                    kind: .weather,
                    title: title,
                    subtitle: String(format: "%.0f km/h wind", wind),
                    lifetime: 10
                ),
                speech: speech
            )
            }
        }.resume()
    }

    private static func weatherWarning(code: Int, wind: Double, temp: Double, precip: Double) -> (String, String)? {
        if code >= 95 { return ("Thunderstorm nearby", "Thunderstorm nearby") }
        if (code == 56 || code == 57 || code == 66 || code == 67) || (temp <= 1 && precip > 0) {
            return ("Icy conditions", "Possible ice on the road")
        }
        if (71...77).contains(code) || code == 85 || code == 86 { return ("Snow nearby", "Snow nearby") }
        if (51...67).contains(code) || (80...82).contains(code) { return ("Rain nearby", "Rain nearby") }
        if wind >= 60 { return ("High wind", "High wind") }
        return nil
    }

    private func checkCrash(_ motion: CMDeviceMotion) {
        guard settings.crashDetection, !crashLatched else { return }
        let u = motion.userAcceleration
        let g = sqrt(u.x * u.x + u.y * u.y + u.z * u.z)
        guard g > 5, Date().timeIntervalSince(lastFastDate) < 8 else { return }
        crashLatched = true
        crashSuspected = true
        postAlert(DriveAlert(key: "crash-\(Int(Date().timeIntervalSince1970))", kind: .info,
                                title: "Possible impact",
                                subtitle: "Tap Call 911 if you need help",
                                imminent: true, lifetime: 30),
                     speech: "Possible impact. Call 911 if you need help.")
    }

    func clearCrash() {
        crashSuspected = false
        crashLatched = false
    }

    private func rememberParked(_ c: CLLocationCoordinate2D) {
        traps.parking = FavouritePlace(name: "My car", latitude: c.latitude, longitude: c.longitude, icon: "car.fill")
    }

    private func remindParked(_ trip: TripRecord, at c: CLLocationCoordinate2D) {
        let content = UNMutableNotificationContent()
        content.title = "Car parked"
        content.body = String(format: "Saved at %.4f, %.4f. Open the map to walk back.", c.latitude, c.longitude)
        content.sound = .default
        let id = "park-\(trip.id.uuidString)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func clearParked() {
        traps.parking = nil
    }

    private func updateHazardStatus() {
        let cams = osm.allHazards.filter { $0.kind == .camera || $0.kind == .avgSpeed || $0.kind == .redLight }.count
        if let f = osm.hazardFetched {
            let mins = Int(Date().timeIntervalSince(f) / 60)
            let age = mins < 1 ? "just now" : (mins < 120 ? "\(mins) min ago" : "\(mins / 60) h ago")
            hazardStatus = "\(cams) OSM cameras nearby · updated \(age)"
        }
    }

    private func refilterHazards(force: Bool) {
        guard let c = location?.coordinate else { return }
        if !force, let last = lastHazardFilterCenter, Geo.distance(last, c) < 300 { return }
        lastHazardFilterCenter = c
        nearbyHazards = osm.allHazards.filter { Geo.distance($0.coordinate, c) < 6000 }
        if force { updateHazardStatus() }
    }

    func hazardCount(along coords: [CLLocationCoordinate2D]) -> Int {
        guard coords.count >= 2 else { return 0 }
        let points: [CLLocationCoordinate2D] = osm.allHazards.filter { $0.kind != .school && $0.kind != .crossing && $0.kind != .bump }.map(\.coordinate)
            + traps.reports.map(\.coordinate)
        var n = 0
        for p in points {
            if let hit = Geo.project(p, onto: coords), hit.distance < 60 { n += 1 }
        }
        return n
    }

    // MARK: Speeding

    private func checkSpeeding(_ loc: CLLocation) {
        let cap = settings.personalCapKmh
        let overCap = cap >= 50 && speed * 3.6 > cap
        guard let lim = speedLimit, speed > 2 else {
            if overCap {
                isSpeeding = true
                postAlert(DriveAlert(key: "cap-\(Int(cap))", kind: .speeding,
                                        title: "Above your alarm",
                                        subtitle: "Set to \(Int(cap)) km/h",
                                        lifetime: 5),
                             speech: "Above your speed alarm")
            } else {
                isSpeeding = false
                speedingSince = nil
            }
            return
        }
        let over = speed * 3.6 > lim + settings.speedingTolerance
        if over {
            if speedingSince == nil { speedingSince = Date() }
            if let s = speedingSince, Date().timeIntervalSince(s) >= 3 {
                if !isSpeeding, settings.speedingAlerts {
                    let u = settings.speedUnits
                    let limText = u.limit(lim)
                    postAlert(DriveAlert(key: "speed-\(lastRoadId ?? 0)-\(Int(lim))", kind: .speeding,
                                            title: "Over the limit",
                                            subtitle: "Limit \(limText.value) · you \(u.speedText(speed))",
                                            imminent: false, lifetime: 5),
                                 speech: "Speed limit \(limText.value)")
                }
                isSpeeding = true
            }
        } else if overCap {
            isSpeeding = true
            postAlert(DriveAlert(key: "cap-\(Int(cap))", kind: .speeding,
                                    title: "Above your alarm",
                                    subtitle: "Set to \(Int(cap)) km/h",
                                    lifetime: 5),
                         speech: "Above your speed alarm")
        } else {
            isSpeeding = false
            speedingSince = nil
        }
    }

    // MARK: Ahead-only proximity alerts

    private func checkHazards(_ loc: CLLocation) {
        guard speed > 3 else { return }
        let pos = loc.coordinate
        let u = settings.speedUnits
        var best: (alert: DriveAlert, speech: String, d: Double)?

        func consider(key: String, kind: AlertKind, coord: CLLocationCoordinate2D, lookahead: Double, title: String, extra: String, speech: String) {
            let d = Geo.distance(pos, coord)
            guard d <= lookahead, d > 5 else {
                if d > lookahead * 3 { forgetAlert(key: key) }
                return
            }
            guard Geo.angleDiff(Geo.bearing(pos, coord), heading) <= 45 else { return }
            let secs = Int((d / max(speed, 1)).rounded())
            let sub = "in \(u.distance(d)) · \(secs) s" + (extra.isEmpty ? "" : " · \(extra)")
            let imminent = d < max(80, speed * 4)
            let a = DriveAlert(key: key, kind: kind, title: title, subtitle: sub, distance: d, startDistance: lookahead,
                               imminent: imminent, lifetime: max(4, Double(secs) + 3))
            if best == nil || d < best!.d { best = (a, speech, d) }
        }

        let scale = settings.vehicle.distanceScale * settings.warnReach.scale
        let camLook = max(200, speed * 15) * scale
        let poiLook = max(150, speed * 10) * scale
        for h in nearbyHazards {
            switch h.kind {
            case .camera where settings.cameraAlerts:
                let lim = h.maxspeed.map { "limit \(u.limit($0).value)" } ?? ""
                let tunnel = h.detail == "tunnel"
                consider(key: h.id, kind: .camera, coord: h.coordinate, lookahead: camLook,
                         title: tunnel ? "Tunnel speed camera" : "Speed camera", extra: lim,
                         speech: (tunnel ? "Tunnel speed camera ahead" : "Speed camera ahead") + (h.maxspeed.map { ", limit \(u.limit($0).value)" } ?? ""))
            case .avgSpeed where settings.cameraAlerts:
                let lim = h.maxspeed.map { "limit \(u.limit($0).value)" } ?? ""
                consider(key: h.id, kind: .avgSpeed, coord: h.coordinate, lookahead: camLook, title: "Average-speed zone (OSM)", extra: lim,
                         speech: "Average speed check ahead")
                if Geo.distance(pos, h.coordinate) < 60 { sectionCandidate = h }
            case .redLight where settings.cameraAlerts:
                consider(key: h.id, kind: .redLight, coord: h.coordinate, lookahead: camLook, title: "Red-light camera (OSM)", extra: "",
                         speech: "Red light camera ahead")
            case .school where settings.schoolAlerts:
                consider(key: h.id, kind: .school, coord: h.coordinate, lookahead: poiLook, title: "School nearby", extra: h.name ?? "",
                         speech: "School zone. Watch for children")
            case .crossing where settings.crossingAlerts:
                consider(key: h.id, kind: .crossing, coord: h.coordinate, lookahead: poiLook, title: "Railway level crossing", extra: "",
                         speech: "Level crossing ahead")
            case .bump where settings.bumpAlerts:
                consider(key: h.id, kind: .info, coord: h.coordinate, lookahead: max(80, speed * 8), title: "Speed bump", extra: "",
                         speech: "Speed bump ahead")
            default:
                break
            }
        }
        if settings.trapAlerts {
            for r in traps.reports {
                consider(key: "rep-\(r.id.uuidString)", kind: .trap, coord: r.coordinate, lookahead: camLook,
                         title: "Your report: \(r.type.label)", extra: "", speech: "\(r.type.label) reported ahead")
            }
        }
        if let b = best {
            updateOrRaise(b.alert, speech: b.speech)
        }
    }

    // MARK: Average-speed section mode (only when OSM tags a section end)

    private func checkSection(_ loc: CLLocation, previous: CLLocation?) {
        if section == nil, let c = sectionCandidate, let end = c.sectionEnd {
            if Geo.distance(loc.coordinate, c.coordinate) < 40 {
                section = AvgSpeedSection(id: c.id, limit: c.maxspeed, end: end.cl, started: Date(), distance: 0)
                sectionCandidate = nil
            }
        }
        guard var s = section else { return }
        if let p = previous { s.distance += loc.distance(from: p) }
        if Geo.distance(loc.coordinate, s.end) < 50 || Date().timeIntervalSince(s.started) > 3600 {
            let avg = s.average
            section = nil
            postAlert(DriveAlert(key: "secend-\(s.id)", kind: .avgSpeed, title: "Section complete",
                                    subtitle: "Average \(settings.speedUnits.speedText(avg))", lifetime: 6), speech: nil)
        } else {
            section = s
        }
    }

    // MARK: Drift off road (distinct from off-route rerouting)

    private func checkOffRoad(_ loc: CLLocation) {
        guard settings.offRoadWarnings, speed * 3.6 > 15, loc.horizontalAccuracy < 50,
              osm.roadsCover(loc.coordinate) else {
            offRoadSince = nil; offRoad = false; return
        }
        let threshold = max(25, 2 * loc.horizontalAccuracy)
        let d = osm.distanceToNearestRoad(loc.coordinate) ?? .infinity
        if d > threshold {
            if offRoadSince == nil { offRoadSince = Date() }
            if let s = offRoadSince, Date().timeIntervalSince(s) > 3, !offRoad {
                offRoad = true
                let bucket = Int(Date().timeIntervalSince1970 / 90)
                postAlert(DriveAlert(key: "offroad-\(bucket)", kind: .offRoad, title: "Off road?",
                                        subtitle: d.isFinite ? "\(settings.speedUnits.distance(d)) from nearest mapped road" : "No mapped road nearby",
                                        imminent: true, lifetime: 5),
                             speech: "Off road?")
                if settings.hapticsOn { UINotificationFeedbackGenerator().notificationOccurred(.error) }
            }
        } else {
            offRoadSince = nil
            offRoad = false
        }
    }

    // MARK: Reports

    func report(_ type: TrapType) {
        guard let c = displayCoordinate else { return }
        traps.add(type, at: c, heading: speed > 2 ? course : nil)
        postAlert(DriveAlert(key: "reported-\(UUID().uuidString)", kind: .info, title: "\(type.label) saved",
                                subtitle: "Stored on this iPhone only", lifetime: 3), speech: nil, notify: false)
    }

    // MARK: Estimated RPM (no OBD): simple 6-speed gear model

    static func estimatedRPM(_ mps: Double) -> Double {
        let kmh = mps * 3.6
        if kmh < 3 { return 800 }
        let shift: [Double] = [18, 35, 55, 80, 105, 400]
        let k: [Double] = [110, 62, 43, 32, 26, 21]
        let g = shift.firstIndex { kmh < $0 } ?? 5
        return max(900, min(6500, kmh * k[g]))
    }
}
