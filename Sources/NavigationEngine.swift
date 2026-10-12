import Foundation
import MapKit
import CoreLocation

enum TurnKind: String {
    case straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight, uturn, keepLeft, keepRight
    case exitLeft, exitRight, merge, roundabout, arrive, depart

    var symbol: String {
        switch self {
        case .straight, .depart: return "arrow.up"
        case .slightLeft: return "arrow.up.left"
        case .left: return "arrow.turn.up.left"
        case .sharpLeft: return "arrow.turn.left.down"
        case .slightRight: return "arrow.up.right"
        case .right: return "arrow.turn.up.right"
        case .sharpRight: return "arrow.turn.right.down"
        case .uturn: return "arrow.uturn.down"
        case .keepLeft: return "arrow.up.left"
        case .keepRight: return "arrow.up.right"
        case .exitLeft: return "arrow.up.left"
        case .exitRight: return "arrow.up.right"
        case .merge: return "arrow.merge"
        case .roundabout: return "arrow.triangle.turn.up.right.circle"
        case .arrive: return "flag.checkered"
        }
    }

    var shortText: String {
        switch self {
        case .straight, .depart: return "Continue"
        case .slightLeft: return "Bear left"
        case .left: return "Turn left"
        case .sharpLeft: return "Sharp left"
        case .slightRight: return "Bear right"
        case .right: return "Turn right"
        case .sharpRight: return "Sharp right"
        case .uturn: return "Make a U-turn"
        case .keepLeft: return "Keep left"
        case .keepRight: return "Keep right"
        case .exitLeft: return "Exit left"
        case .exitRight: return "Exit right"
        case .merge: return "Merge"
        case .roundabout: return "Roundabout"
        case .arrive: return "Arrive"
        }
    }

    /// Lane indications (OSM turn:lanes values) that serve this maneuver.
    var laneMatches: Set<String> {
        switch self {
        case .left, .sharpLeft: return ["left", "sharp_left"]
        case .slightLeft, .keepLeft, .exitLeft: return ["slight_left", "left", "merge_to_left", "through"]
        case .right, .sharpRight: return ["right", "sharp_right"]
        case .slightRight, .keepRight, .exitRight: return ["slight_right", "right", "merge_to_right", "through"]
        case .uturn: return ["reverse", "left"]
        default: return ["through"]
        }
    }
}

struct RouteOption: Identifiable {
    let id = UUID()
    let route: MKRoute
    var hazards: Int
    var label: String
}

struct Maneuver: Equatable {
    var index: Int
    var instruction: String
    var kind: TurnKind
    var along: Double
    var coordinate: CLLocationCoordinate2D

    static func == (a: Maneuver, b: Maneuver) -> Bool { a.index == b.index && a.instruction == b.instruction }
}

func makeMapItem(_ c: CLLocationCoordinate2D, name: String? = nil) -> MKMapItem {
    let item: MKMapItem
    if #available(iOS 26.0, *) {
        item = MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude), address: nil)
    } else {
        item = MKMapItem(placemark: MKPlacemark(coordinate: c))
    }
    item.name = name
    return item
}

func mapItemCoordinate(_ item: MKMapItem) -> CLLocationCoordinate2D {
    item.placemark.coordinate
}

final class NavigationEngine: ObservableObject {
    @Published private(set) var options: [RouteOption] = []
    @Published private(set) var route: MKRoute?
    @Published private(set) var destination: MKMapItem?
    @Published private(set) var isNavigating = false
    @Published private(set) var calculating = false
    @Published private(set) var next: Maneuver?
    @Published private(set) var then: Maneuver?
    @Published private(set) var distanceToNext: Double?
    @Published private(set) var remainingDistance: Double = 0
    @Published private(set) var remainingTime: Double = 0
    @Published private(set) var offRoute = false
    @Published private(set) var arrived = false
    @Published private(set) var fasterRoute: RouteOption?
    @Published var errorText: String?
    @Published var transport: MKDirectionsTransportType = .automobile
    /// "apple" (primary), "fallback" (simplified retry), "cached" (kept current route), "none".
    @Published var routeSource: String = "apple"
    /// Remaining destinations after the current leg (multi-stop). The current leg's target is `destination`.
    @Published private(set) var pendingStops: [MKMapItem] = []
    @Published var avoidTolls = false
    @Published var avoidHighways = false
    private var switchingLeg = false
    /// Name of the road we're matched to (set by DriveEngine) for the "already on this street" voice guard.
    var currentRoadName: String?
    /// True while we're not yet on the route at the very start (e.g. leaving a driveway/parking lot).
    private var approachingStart = false
    private var startRoadName: String?

    private(set) var coords: [CLLocationCoordinate2D] = []
    private(set) var cum: [Double] = []
    private var maneuvers: [Maneuver] = []
    private var lastSegment = 0
    private var stageDone: [Int: Int] = [:]
    private var offRouteSince: Date?
    private var lastReroute = Date.distantPast
    private var lastTrafficCheck = Date()
    private var arrivalAtCheck: Date?
    struct AutoSwitch: Identifiable { let id = UUID(); let minutes: Int; let previous: MKRoute }
    @Published private(set) var autoSwitch: AutoSwitch?
    private var currentAlong = 0.0
    private var lastLocation: CLLocation?
    private var bannerTimer: Timer?

    /// Seed the last known position (e.g. before the first fix after starting).
    func seed(_ loc: CLLocation?) { if let loc, lastLocation == nil { lastLocation = loc } }
    /// Supplies the engine's last known location when a route starts.
    var onRouteStartedSeed: (() -> CLLocation?)?

    /// Recompute the banner from the last known position without moving along the route.
    private func refreshBanner() {
        guard isNavigating, coords.count >= 2 else { return }
        if let loc = lastLocation {
            let near = Geo.project(loc.coordinate, onto: coords, cumulative: cum, bidirectional: false)?.distance ?? .infinity
            let startDist = Geo.distance(loc.coordinate, coords[0])
            approachingStart = currentAlong < 50 && near > 25 && startDist < 300
        }
        updateManeuver()
    }

    var hazardScorer: (([CLLocationCoordinate2D]) -> Int)?
    var avoidTraps: () -> Bool = { false }
    var onPrompt: ((String) -> Void)?
    var onRouteStarted: (([CLLocationCoordinate2D]) -> Void)?
    var spoken: (Double) -> String = { "\(Int($0)) metres" }

    var destinationName: String { destination?.name ?? "Destination" }
    var destinationCoordinate: CLLocationCoordinate2D? { destination.map(mapItemCoordinate) }

    // MARK: Route requests

    func requestRoutes(to item: MKMapItem, from origin: CLLocationCoordinate2D, transport: MKDirectionsTransportType = .automobile,
                       autoStart: Bool = false) {
        destination = item
        self.transport = transport
        calculating = true
        errorText = nil
        fetch(from: origin, to: item, transport: transport) { [weak self] routes, err in
            guard let self else { return }
            self.calculating = false
            guard !routes.isEmpty else {
                self.errorText = err ?? "No route found"
                return
            }
            self.options = self.rank(routes)
            if autoStart, let best = self.options.first { self.start(best) }
        }
    }

    private func fetch(from origin: CLLocationCoordinate2D, to item: MKMapItem, transport: MKDirectionsTransportType,
                       completion: @escaping ([MKRoute], String?) -> Void) {
        let req = MKDirections.Request()
        req.source = makeMapItem(origin)
        req.destination = item
        req.transportType = transport
        req.requestsAlternateRoutes = true
        if transport == .automobile { req.departureDate = Date() }
        if transport == .automobile {
            req.tollPreference = (avoidTolls || !RoutePrefs.allowTolls) ? .avoid : .any
            req.highwayPreference = (avoidHighways || !RoutePrefs.allowMotorways) ? .avoid : .any
        }
        // Apple Maps is primary. If it times out (~8 s), errors, or returns nothing, fall back
        // silently: retry once with a simplified Apple request, then keep the current route if any.
        var done = false
        let dirs = MKDirections(request: req)
        let finish: ([MKRoute], String?, String) -> Void = { [weak self] routes, err, source in
            guard !done else { return }
            done = true
            self?.routeSource = source
            completion(routes, err)
        }
        let fallback: (String?) -> Void = { [weak self] err in
            guard let self else { return }
            let simple = MKDirections.Request()
            simple.source = req.source; simple.destination = req.destination
            simple.transportType = transport; simple.requestsAlternateRoutes = false
            MKDirections(request: simple).calculate { resp, err2 in
                DispatchQueue.main.async {
                    let routes = Array((resp?.routes ?? []).prefix(1))
                    if !routes.isEmpty { finish(routes, nil, "fallback") }
                    else if self.isNavigating { finish([], nil, "cached") }  // keep current route
                    else { finish([], err2?.localizedDescription ?? err, "none") }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard !done else { return }
            dirs.cancel()
            fallback("Apple Maps timed out")
        }
        dirs.calculate { resp, err in
            DispatchQueue.main.async {
                guard !done else { return }
                let routes = Array((resp?.routes ?? []).prefix(3))
                if routes.isEmpty { fallback(err?.localizedDescription) }
                else { finish(routes, nil, "apple") }
            }
        }
    }

    private func rank(_ routes: [MKRoute]) -> [RouteOption] {
        guard let fastest = routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else { return [] }
        var opts = routes.map { r -> RouteOption in
            let h = hazardScorer?(Geo.coordinates(of: r.polyline)) ?? 0
            return RouteOption(route: r, hazards: h, label: "")
        }
        if avoidTraps() {
            opts.sort { a, b in
                let aOK = a.route.expectedTravelTime <= fastest.expectedTravelTime * 1.2
                let bOK = b.route.expectedTravelTime <= fastest.expectedTravelTime * 1.2
                if aOK != bOK { return aOK }
                if a.hazards != b.hazards { return a.hazards < b.hazards }
                return a.route.expectedTravelTime < b.route.expectedTravelTime
            }
        } else {
            if RoutePrefs.shorter { opts.sort { $0.route.distance < $1.route.distance } }
            else { opts.sort { $0.route.expectedTravelTime < $1.route.expectedTravelTime } }
        }
        let minHazards = opts.map(\.hazards).min() ?? 0
        for i in opts.indices {
            var tags: [String] = []
            if opts[i].route.expectedTravelTime == fastest.expectedTravelTime { tags.append("Fastest") }
            if opts[i].hazards == minHazards && opts.count > 1 && opts.map(\.hazards).max() != minHazards { tags.append("Fewest traps") }
            opts[i].label = tags.joined(separator: " · ")
        }
        return opts
    }

    func clearOptions() {
        options = []
        if !isNavigating { destination = nil }
    }

    // MARK: Navigation

    /// Start a route chosen outside the options panel (e.g. the route preview screen).
    func start(_ option: RouteOption, to item: MKMapItem, thenStops: [MKMapItem] = [], transport: MKDirectionsTransportType = .automobile) {
        destination = item
        self.transport = transport
        pendingStops = thenStops
        start(option)
    }

    /// Insert a stop before the current destination and route to it now.
    func insertStop(_ item: MKMapItem, from loc: CLLocation?) {
        guard isNavigating, let loc else { return }
        if let d = destination { pendingStops.insert(d, at: 0) }
        destination = item
        persistActiveRoute()
        onPrompt?("Adding stop: \(item.name ?? "waypoint").")
        routeCurrentLeg(from: loc.coordinate)
    }

    /// Recalculate the current leg (e.g. after changing avoid tolls / highways).
    func recalculate(from loc: CLLocation?) {
        guard isNavigating, let loc else { return }
        onPrompt?("Recalculating route.")
        routeCurrentLeg(from: loc.coordinate)
    }

    private func routeCurrentLeg(from c: CLLocationCoordinate2D) {
        guard let dest = destination else { return }
        switchingLeg = true
        lastReroute = Date()
        fetch(from: c, to: dest, transport: transport) { [weak self] routes, err in
            guard let self, self.isNavigating else { return }
            self.switchingLeg = false
            if let best = self.rank(routes).first {
                self.load(best.route)
                self.arrived = false
                self.onRouteStarted?(self.coords)
            } else if let err { self.errorText = err }
        }
    }

    /// Fetch a route to `item` from `origin` and start it, keeping remaining stops.
    func resume(to item: MKMapItem, thenStops: [MKMapItem], from origin: CLLocationCoordinate2D, completion: @escaping (Bool) -> Void) {
        destination = item
        fetch(from: origin, to: item, transport: transport) { [weak self] routes, _ in
            guard let self, let best = self.rank(routes).first else { completion(false); return }
            self.start(best, to: item, thenStops: thenStops, transport: self.transport)
            completion(true)
        }
    }

    private func persistActiveRoute() {
        guard let d = destination else { ActiveRouteStore.clear(); return }
        ActiveRouteStore.save([d] + pendingStops)
    }

    func start(_ option: RouteOption) {
        load(option.route)
        defer { persistActiveRoute() }
        options = []
        isNavigating = true
        arrived = false
        fasterRoute = nil
        lastTrafficCheck = Date()
        if let l = onRouteStartedSeed?() { lastLocation = l }
        refreshBanner()
        var intro = "Starting \(transport == .walking ? "walking" : "driving") route to \(destinationName). \(option.route.name.isEmpty ? "" : "Via \(option.route.name). ")"
        if let n = next, let d = distanceToNext {
            intro += d < 40 ? n.instruction : "In \(spoken(d)), \(lowerFirst(n.instruction))."
            stageDone[n.index] = d < max(5 * 12, 500) ? 2 : 1
        }
        onPrompt?(intro)
        bannerTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshBanner() }
        RunLoop.main.add(t, forMode: .common)
        bannerTimer = t
        onRouteStarted?(coords)
    }

    private func load(_ r: MKRoute) {
        route = r
        coords = Geo.coordinates(of: r.polyline)
        cum = Geo.cumulative(coords)
        lastSegment = 0
        stageDone = [:]
        offRouteSince = nil
        offRoute = false
        currentAlong = 0
        // Locate each step's start (= its maneuver point) on the route polyline.
        // Anchor on the cumulative step distances so maneuvers stay ordered and none are
        // dropped; refine with a projection constrained to a window around that anchor.
        var list: [Maneuver] = []
        let total = cum.last ?? 0
        // The route polyline is the concatenation of the step polylines, so step i starts at the summed
        // geometric length of steps 0..<i. (Scaled to the route length to absorb rounding.)
        let stepLens = r.steps.map { st -> Double in let c = Geo.coordinates(of: st.polyline); return Geo.cumulative(c).last ?? 0 }
        let stepSum = stepLens.reduce(0, +)
        let scale = stepSum > 0 ? total / stepSum : 1
        var acc = 0.0
        var prevAlong = 0.0
        for (i, step) in r.steps.enumerated() {
            defer { acc += stepLens[i] }
            guard i > 0 else { continue }
            let expected = min(total, acc * scale)
            var along = max(prevAlong, expected)
            var coord = Geo.point(along: along, coords: coords, cumulative: cum) ?? (coords.last ?? coords[0])
            if let first = Geo.coordinates(of: step.polyline).first {
                let window = 80.0
                let lo = max(0, (cum.firstIndex { $0 >= max(prevAlong, expected - window) } ?? 0) - 1)
                let hi = min(coords.count - 1, (cum.firstIndex { $0 > expected + window } ?? coords.count - 1) + 1)
                if lo < hi, let hit = Geo.project(first, onto: coords, cumulative: cum, range: lo..<hi),
                   hit.distance < 40, hit.along >= prevAlong {
                    along = hit.along
                    coord = hit.coordinate
                }
            }
            prevAlong = along
            let isLast = i == r.steps.count - 1
            let rawKind = isLast ? TurnKind.arrive : classify(step.instructions, at: along)
            let (spoken, kind) = Self.kelownaMainStreet(step.instructions, rawKind, destination: destinationName)
            let instruction = Self.alignInstruction(spoken, to: kind)
            list.append(Maneuver(index: i, instruction: instruction.isEmpty ? kind.shortText : instruction,
                                 kind: kind, along: along, coordinate: coord))
        }
        maneuvers = list
        #if DEBUG
        let raw = r.steps.enumerated().filter { $0.offset > 0 && !$0.element.instructions.isEmpty }.map { "\($0.offset)|\($0.element.instructions)" }
        let got = list.map { "\($0.index)|\($0.instruction)" }
        print("[STEPS] route=\(r.name) raw=\(raw.count) maneuvers=\(got.count) match=\(raw == got)")
        for (i, s) in raw.enumerated() { print("[STEPS] \(s)  =>  \(i < got.count ? got[i] : "MISSING")") }
        #endif
        approachingStart = false
        startRoadName = nil
        if let first = coords.first {
            CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: first.latitude, longitude: first.longitude)) { [weak self] marks, _ in
                DispatchQueue.main.async { self?.startRoadName = marks?.first?.thoroughfare; self?.updateManeuver() }
            }
        }
        remainingDistance = r.distance
        remainingTime = r.expectedTravelTime
        updateManeuver()
    }

    func stop() {
        isNavigating = false
        route = nil
        coords = []
        cum = []
        maneuvers = []
        next = nil
        then = nil
        distanceToNext = nil
        destination = nil
        fasterRoute = nil
        offRoute = false
        options = []
        pendingStops = []
        switchingLeg = false
        ActiveRouteStore.clear()
        bannerTimer?.invalidate()
        bannerTimer = nil
    }

    func undoAutoSwitch() {
        guard let a = autoSwitch else { return }
        autoSwitch = nil
        load(a.previous)
        lastTrafficCheck = Date()
        onPrompt?("Back on your original route.")
        onRouteStarted?(coords)
    }

    func clearAutoSwitch() { autoSwitch = nil }

    func acceptFasterRoute() {
        guard let f = fasterRoute else { return }
        load(f.route)
        fasterRoute = nil
        onPrompt?("Switched to faster route.")
        onRouteStarted?(coords)
    }

    func dismissFasterRoute() { fasterRoute = nil; lastTrafficCheck = Date() }

    /// Called on every location fix. Returns the snapped point on the route (if on it) and its bearing.
    @discardableResult
    func update(_ loc: CLLocation, course: Double?, stationary: Bool = false) -> PolylineHit? {
        guard isNavigating, coords.count >= 2 else { return nil }
        lastLocation = loc
        let lo = max(0, lastSegment - 10)
        let hi = min(coords.count - 1, lastSegment + 400)
        var hit = Geo.project(loc.coordinate, onto: coords, cumulative: cum, course: course, bidirectional: false, range: lo..<hi)
        if hit == nil || hit!.distance > 60 {
            if let full = Geo.project(loc.coordinate, onto: coords, cumulative: cum, course: course, bidirectional: false),
               full.distance < (hit?.distance ?? .infinity) { hit = full }
        }
        let speed = max(loc.speed, 0)

        // arrival
        if switchingLeg { return hit }
        if let dest = destinationCoordinate, Geo.distance(loc.coordinate, dest) < 35 || (hit.map { cum.last! - $0.along < 25 } ?? false) {
            if !pendingStops.isEmpty {
                let reached = destinationName
                let next = pendingStops.removeFirst()
                destination = next
                persistActiveRoute()
                onPrompt?("You have reached \(reached). Continuing to \(next.name ?? "the next stop").")
                routeCurrentLeg(from: loc.coordinate)
                return hit
            }
            if !arrived {
                arrived = true
                onPrompt?("You have arrived at \(destinationName).")
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard let self, self.arrived else { return }
                    self.stop()
                }
            }
            return hit
        }

        // off-route -> reroute (separate from the off-road warning)
        let threshold = 40.0
        // At the start, before we've joined the route, guide the driver onto it instead of rerouting.
        let startDist = coords.first.map { Geo.distance(loc.coordinate, $0) } ?? .infinity
        approachingStart = currentAlong < 50 && (hit?.distance ?? .infinity) > 25 && startDist < 300
        if approachingStart {
            offRouteSince = nil
            offRoute = false
        } else if stationary {
            // Stopped: GPS drift must not move our route position, advance steps, or trigger a reroute.
            offRouteSince = nil
        } else if let h = hit, h.distance <= threshold {
            offRouteSince = nil
            offRoute = false
            lastSegment = h.segment
            currentAlong = h.along
        } else if loc.horizontalAccuracy < 40 {
            if offRouteSince == nil { offRouteSince = Date() }
            if let s = offRouteSince, Date().timeIntervalSince(s) >= 5 {
                offRoute = true
                reroute(from: loc)
            }
        }

        if let r = route, r.distance > 0 {
            remainingDistance = max(0, (cum.last ?? 0) - currentAlong)
            remainingTime = r.expectedTravelTime * remainingDistance / max(cum.last ?? r.distance, 1)
        }
        updateManeuver()
        announce(speed: speed)

        let since = Date().timeIntervalSince(lastTrafficCheck)
        let eta = Date().addingTimeInterval(remainingTime)
        let delayed = arrivalAtCheck.map { eta.timeIntervalSince($0) > 120 } ?? false
        if transport == .automobile, !RoutePrefs.offline, since > (RoutePrefs.autoFaster ? 90 : 180) || (delayed && since > 30) {
            lastTrafficCheck = Date()
            arrivalAtCheck = eta
            checkTraffic(from: loc)
        }
        return (hit?.distance ?? .infinity) <= 25 ? hit : nil
    }

    private func updateManeuver() {
        if approachingStart, let loc = lastLocation, coords.count >= 2 {
            // Synthetic first maneuver: turn from the car's approach onto the route's first road.
            let toStart = Geo.bearing(loc.coordinate, coords[0])
            let routeDir = Geo.bearing(coords[0], coords[min(3, coords.count - 1)])
            let turn = Geo.signedTurn(toStart, routeDir)
            let sameRoad = Self.sameRoad(currentRoadName, startRoadName)
            let kind: TurnKind = (sameRoad || abs(turn) < 55) ? .straight : (turn < 0 ? .left : .right)
            let road = startRoadName.map { kind == .straight ? " on \($0)" : " onto \($0)" } ?? ""
            let text = kind == .straight ? "Continue\(road)" : "\(kind.shortText)\(road)"
            let m = Maneuver(index: -1, instruction: text, kind: kind, along: 0, coordinate: coords[0])
            next = m
            distanceToNext = Geo.distance(loc.coordinate, coords[0])
            then = maneuvers.first.flatMap { $0.along < 300 ? $0 : nil }
            return
        }
        // Next maneuver = first one not yet passed (advance only once we are past its point).
        let idx = maneuvers.firstIndex { $0.along > currentAlong - 5 }
        let n = idx.map { maneuvers[$0] }
        next = n
        distanceToNext = n.map { max(0, $0.along - currentAlong) }
        if let n, let idx, idx + 1 < maneuvers.count, maneuvers[idx + 1].along - n.along < 300 {
            then = maneuvers[idx + 1]
        } else {
            then = nil
        }
    }

    /// Staged, speed-scaled prompts: far (~30 s / 1 km), mid (~12 s / 500 m), now (~3 s).
    private func announce(speed: Double) {
        guard !offRoute, let n = next, let d = distanceToNext else { return }
        // Don't announce "continue onto X" when we're already on X.
        if [.straight, .depart, .keepLeft, .keepRight, .slightLeft, .slightRight].contains(n.kind),
           let road = currentRoadName?.lowercased(), !road.isEmpty, n.instruction.lowercased().contains(road) { return }
        let v = max(speed, 5)
        let far = max(v * 30, 1000), mid = max(v * 12, 500), now = max(v * 3, 35)
        let stage: Int
        if d <= now { stage = 3 } else if d <= mid { stage = 2 } else if d <= far { stage = 1 } else { return }
        let done = stageDone[n.index] ?? 0
        guard stage > done else { return }
        stageDone[n.index] = stage
        if stage == 1 && d < mid * 1.15 { return }     // too close to bother with the far prompt
        var text: String
        let instruction = n.instruction
        switch stage {
        case 3: text = n.kind == .arrive ? instruction : "Now, \(lowerFirst(instruction))"
        default: text = "In \(spoken(d)), \(lowerFirst(instruction))"
        }
        if let t = then, stage >= 2 { text += ", then \(lowerFirst(t.kind.shortText))" }
        onPrompt?(text)
    }

    private func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return f.lowercased() + s.dropFirst()
    }

    private func reroute(from loc: CLLocation) {
        guard let dest = destination, Date().timeIntervalSince(lastReroute) > 12 else { return }
        lastReroute = Date()
        onPrompt?("Rerouting")
        fetch(from: loc.coordinate, to: dest, transport: transport) { [weak self] routes, _ in
            guard let self, self.isNavigating else { return }
            let ranked = self.rank(routes)
            if let best = ranked.first { self.load(best.route); self.onRouteStarted?(self.coords) }
        }
    }

    private func checkTraffic(from loc: CLLocation) {
        guard let dest = destination, fasterRoute == nil else { return }
        let current = remainingTime
        fetch(from: loc.coordinate, to: dest, transport: transport) { [weak self] routes, _ in
            guard let self, self.isNavigating else { return }
            guard let best = routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else { return }
            let saving = current - best.expectedTravelTime
            if saving >= 120 {
                let h = self.hazardScorer?(Geo.coordinates(of: best.polyline)) ?? 0
                self.fasterRoute = RouteOption(route: best, hazards: h, label: "Saves \(Int(saving / 60)) min")
                if RoutePrefs.autoFaster {
                    if let prev = self.route { self.autoSwitch = AutoSwitch(minutes: Int(saving / 60), previous: prev) }
                    self.acceptFasterRoute(); return
                }
                self.onPrompt?("A faster route is available, saving \(Int(saving / 60)) minutes.")
            }
        }
    }

    // MARK: Maneuver classification (text keywords + geometry, language-independent fallback)

    private func classify(_ instruction: String, at along: Double) -> TurnKind {
        let t = instruction.lowercased()
        if t.contains("u-turn") || t.contains("u turn") { return .uturn }
        if t.contains("roundabout") || t.contains("traffic circle") || t.contains("rotary") { return .roundabout }
        if t.contains("arrive") || t.contains("destination") { return .arrive }
        if t.contains("merge") { return .merge }
        let geo = geometricTurn(at: along)
        if t.contains("exit") || t.contains("ramp") { return t.contains("left") ? .exitLeft : .exitRight }
        if t.contains("keep left") || t.contains("stay left") { return .keepLeft }
        if t.contains("keep right") || t.contains("stay right") { return .keepRight }
        if t.contains("slight left") || t.contains("bear left") { return .slightLeft }
        if t.contains("slight right") || t.contains("bear right") { return .slightRight }
        if t.contains("sharp left") { return .sharpLeft }
        if t.contains("sharp right") { return .sharpRight }
        if t.contains("left") { return geo == .sharpLeft ? .sharpLeft : .left }
        if t.contains("right") { return geo == .sharpRight ? .sharpRight : .right }
        if t.contains("continue") || t.contains("straight") || t.hasPrefix("head") { return .straight }
        switch geo {
        case .slightLeft, .slightRight, .left, .right: return .straight
        default: return geo
        }
    }

    /// Going to Kelowna, the turn onto Main Street is a right, not a left.
    private static func kelownaMainStreet(_ instruction: String, _ kind: TurnKind, destination: String) -> (String, TurnKind) {
        let t = instruction.lowercased()
        guard destination.lowercased().contains("kelowna"),
              t.contains("main"),
              t.contains("left"),
              !t.contains("keep") else { return (instruction, kind) }
        let fixed = instruction.replacingOccurrences(of: "left", with: "right", options: .caseInsensitive)
        return (fixed, .right)
    }

    private static func alignInstruction(_ instruction: String, to kind: TurnKind) -> String {
        guard !instruction.isEmpty else { return kind.shortText }
        let lower = instruction.lowercased()
        switch kind {
        case .straight, .depart:
            guard lower.contains("left") || lower.contains("right") else { return instruction }
            return instruction.replacingOccurrences(
                of: "(?i)turn (sharp )?(left|right)",
                with: "Continue",
                options: .regularExpression
            )
        case .left, .sharpLeft, .slightLeft, .keepLeft, .exitLeft:
            guard lower.contains("right"), !lower.contains("left") else { return instruction }
            return instruction.replacingOccurrences(of: "right", with: "left", options: .caseInsensitive)
        case .right, .sharpRight, .slightRight, .keepRight, .exitRight:
            guard lower.contains("left"), !lower.contains("right") else { return instruction }
            return instruction.replacingOccurrences(of: "left", with: "right", options: .caseInsensitive)
        default:
            return instruction
        }
    }

    private static func sameRoad(_ a: String?, _ b: String?) -> Bool {
        guard let a = a?.lowercased(), let b = b?.lowercased(), !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    private func geometricTurn(at along: Double) -> TurnKind {
        guard let a = Geo.point(along: along - 25, coords: coords, cumulative: cum),
              let m = Geo.point(along: along, coords: coords, cumulative: cum),
              let b = Geo.point(along: along + 25, coords: coords, cumulative: cum) else { return .straight }
        let turn = Geo.signedTurn(Geo.bearing(a, m), Geo.bearing(m, b))
        switch turn {
        case ..<(-150): return .uturn
        case -150 ..< -110: return .sharpLeft
        case -110 ..< -40: return .left
        case -40 ..< -15: return .slightLeft
        case -15 ... 15: return .straight
        case 15 ... 40: return .slightRight
        case 40 ... 110: return .right
        case 110 ... 150: return .sharpRight
        default: return .uturn
        }
    }

    /// Curvature ahead (sum of absolute turn angles over the next `meters`), for the hazard-risk estimate.
    func curvatureAhead(_ meters: Double = 1000) -> Double {
        guard coords.count > 2 else { return 0 }
        var total = 0.0
        var d = currentAlong
        var prevBearing: Double?
        while d < currentAlong + meters {
            guard let a = Geo.point(along: d, coords: coords, cumulative: cum),
                  let b = Geo.point(along: d + 50, coords: coords, cumulative: cum) else { break }
            let br = Geo.bearing(a, b)
            if let p = prevBearing { total += abs(Geo.signedTurn(p, br)) }
            prevBearing = br
            d += 50
        }
        return total
    }

    /// Route ahead of the current position (for drawing a traveled/remaining split if needed).
    var alongPosition: Double { currentAlong }
}
