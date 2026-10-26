import Foundation
import CoreLocation

/// Free, keyless OpenStreetMap data via the public Overpass API, cached on device.
struct Coord: Codable, Hashable {
    var lat: Double
    var lon: Double
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    init(lat: Double, lon: Double) { self.lat = lat; self.lon = lon }
    init(_ c: CLLocationCoordinate2D) { lat = c.latitude; lon = c.longitude }
}

enum HazardKind: String, Codable {
    case camera, avgSpeed, redLight, school, crossing, bump
}

struct OSMHazard: Codable, Identifiable, Hashable {
    var id: String
    var kind: HazardKind
    var lat: Double
    var lon: Double
    var maxspeed: Double?         // km/h
    var direction: Double?        // camera facing, degrees (if tagged)
    var sectionEnd: Coord?        // average-speed section end
    var name: String?
    var detail: String? = nil     // "tunnel" when the camera is tagged inside a tunnel
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

struct OSMRoad: Codable, Identifiable {
    var id: Int64
    var coords: [Coord]
    var tags: [String: String]
    var minLat: Double, maxLat: Double, minLon: Double, maxLon: Double

    init(id: Int64, coords: [Coord], tags: [String: String]) {
        self.id = id; self.coords = coords; self.tags = tags
        minLat = coords.map(\.lat).min() ?? 0; maxLat = coords.map(\.lat).max() ?? 0
        minLon = coords.map(\.lon).min() ?? 0; maxLon = coords.map(\.lon).max() ?? 0
    }

    var highway: String { tags["highway"] ?? "" }
    var isMinor: Bool { ["service", "track"].contains(highway) }
    var oneway: Bool { tags["oneway"] == "yes" || tags["oneway"] == "1" || highway == "motorway" || tags["junction"] == "roundabout" }
    var name: String? { tags["name"] ?? tags["ref"] }

    func near(_ c: CLLocationCoordinate2D, margin: Double) -> Bool {
        let dLat = margin / 111_320
        let dLon = margin / (111_320 * max(0.1, cos(c.latitude * .pi / 180)))
        return c.latitude >= minLat - dLat && c.latitude <= maxLat + dLat && c.longitude >= minLon - dLon && c.longitude <= maxLon + dLon
    }

    /// Speed limit in km/h for the given travel direction (forward = node order).
    func maxspeed(forward: Bool) -> Double? {
        let dirKey = forward ? "maxspeed:forward" : "maxspeed:backward"
        return OSMService.parseSpeed(tags[dirKey]) ?? OSMService.parseSpeed(tags["maxspeed"])
    }

    /// Lane turn indications for the travel direction, e.g. [["left"], ["through"], ["through","right"]].
    func turnLanes(forward: Bool) -> [[String]]? {
        let raw: String? = forward ? (tags["turn:lanes:forward"] ?? (oneway ? tags["turn:lanes"] : nil)) : tags["turn:lanes:backward"]
        guard let raw, !raw.isEmpty else { return nil }
        return raw.split(separator: "|", omittingEmptySubsequences: false).map { lane in
            let parts = lane.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "none" }
            return parts.isEmpty ? ["through"] : parts
        }
    }

    func laneCount(forward: Bool) -> Int? {
        if let s = tags[forward ? "lanes:forward" : "lanes:backward"], let n = Int(s) { return n }
        if let s = tags["lanes"], let n = Int(s) { return oneway ? n : max(1, n / 2) }
        return nil
    }
}

private struct OverpassResponse: Decodable {
    struct LatLon: Decodable { let lat: Double; let lon: Double }
    struct Member: Decodable {
        let type: String
        let ref: Int64
        let role: String
        let lat: Double?
        let lon: Double?
        let geometry: [LatLon?]?
    }
    struct Element: Decodable {
        let type: String
        let id: Int64
        let lat: Double?
        let lon: Double?
        let center: LatLon?
        let tags: [String: String]?
        let geometry: [LatLon?]?
        let members: [Member]?
    }
    let elements: [Element]
}

private struct HazardCache: Codable {
    var center: Coord
    var fetched: Date
    var hazards: [OSMHazard]
}

final class OSMService {
    private let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
    ]
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpAdditionalHeaders = ["User-Agent": "TrapRadar-iOS/1.0 (personal, on-device)"]
        return URLSession(configuration: cfg)
    }()

    private(set) var hazardCenter: Coord?
    private(set) var hazardFetched: Date?
    private(set) var hazards: [OSMHazard] = []
    private var routeHazards: [OSMHazard] = []
    private var hazardLoading = false

    var allHazards: [OSMHazard] {
        if routeHazards.isEmpty { return hazards }
        var seen = Set(hazards.map(\.id))
        var out = hazards
        for h in routeHazards where !seen.contains(h.id) { out.append(h); seen.insert(h.id) }
        return out
    }

    init() {
        if let c = DiskStore.load(HazardCache.self, "osm-hazards.json") {
            hazards = c.hazards; hazardCenter = c.center; hazardFetched = c.fetched
        }
    }

    // MARK: Speed parsing

    static func parseSpeed(_ s: String?) -> Double? {
        guard let s else { return nil }
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        if t == "none" || t == "signals" || t == "variable" { return nil }
        let first = t.split(separator: ";").first.map(String.init) ?? t
        let digits = first.prefix { $0.isNumber || $0 == "." }
        guard let n = Double(digits), n > 0 else { return nil }
        return first.contains("mph") ? n * 1.609344 : (first.contains("knots") ? n * 1.852 : n)
    }

    // MARK: Hazards (cameras, enforcement, schools, level crossings)

    func needsHazardRefresh(at c: CLLocationCoordinate2D) -> Bool {
        guard !hazardLoading else { return false }
        guard let center = hazardCenter, let fetched = hazardFetched else { return true }
        return Geo.distance(center.cl, c) > 10_000 || Date().timeIntervalSince(fetched) > 24 * 3600
    }

    func refreshHazards(around c: CLLocationCoordinate2D, completion: @escaping (Bool) -> Void) {
        guard !hazardLoading else { return }
        hazardLoading = true
        let lat = String(format: "%.5f", c.latitude), lon = String(format: "%.5f", c.longitude)
        let a = "(around:15000,\(lat),\(lon))"
        let b = "(around:6000,\(lat),\(lon))"
        let q = """
        [out:json][timeout:40];
        node["highway"="speed_camera"]\(a);out body;
        relation["type"="enforcement"]\(a);out geom;
        node["railway"="level_crossing"]\(b);out body;
        node["traffic_calming"~"^(bump|hump|table|cushion)$"]\(b);out body;
        (node["amenity"="school"]\(b);way["amenity"="school"]\(b););out tags center;
        """
        run(q) { [weak self] resp in
            guard let self else { return }
            self.hazardLoading = false
            guard let resp else { completion(false); return }
            self.hazards = Self.parseHazards(resp)
            self.hazardCenter = Coord(c)
            self.hazardFetched = Date()
            DiskStore.save(HazardCache(center: Coord(c), fetched: Date(), hazards: self.hazards), "osm-hazards.json")
            completion(true)
        }
    }

    /// Cameras / enforcement along a route polyline (Overpass `around` accepts a line of coordinates).
    func refreshRouteHazards(along coords: [CLLocationCoordinate2D], completion: @escaping (Bool) -> Void) {
        guard coords.count >= 2 else { completion(false); return }
        var sampled: [CLLocationCoordinate2D] = [coords[0]]
        var acc = 0.0
        for i in 1..<coords.count {
            acc += Geo.distance(coords[i - 1], coords[i])
            if acc >= 1500 { sampled.append(coords[i]); acc = 0 }
        }
        sampled.append(coords[coords.count - 1])
        if sampled.count > 120 {
            let step = Double(sampled.count) / 120
            sampled = (0..<120).map { sampled[min(sampled.count - 1, Int(Double($0) * step))] }
        }
        let line = sampled.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) }.joined(separator: ",")
        let a = "(around:300,\(line))"
        let q = """
        [out:json][timeout:40];
        node["highway"="speed_camera"]\(a);out body;
        relation["type"="enforcement"]\(a);out geom;
        node["railway"="level_crossing"]\(a);out body;
        node["traffic_calming"~"^(bump|hump|table|cushion)$"]\(a);out body;
        (node["amenity"="school"]\(a);way["amenity"="school"]\(a););out tags center;
        """
        run(q) { [weak self] resp in
            guard let self, let resp else { completion(false); return }
            self.routeHazards = Self.parseHazards(resp)
            completion(true)
        }
    }

    func clearRouteHazards() { routeHazards = [] }

    private static func parseHazards(_ r: OverpassResponse) -> [OSMHazard] {
        var out: [OSMHazard] = []
        for e in r.elements {
            let tags = e.tags ?? [:]
            if e.type == "relation" {
                let enforcement = tags["enforcement"] ?? ""
                let members = e.members ?? []
                func memberCoord(_ role: String) -> Coord? {
                    for m in members where m.role == role {
                        if let la = m.lat, let lo = m.lon { return Coord(lat: la, lon: lo) }
                        if let g = m.geometry?.compactMap({ $0 }).first { return Coord(lat: g.lat, lon: g.lon) }
                    }
                    return nil
                }
                let device = memberCoord("device")
                let from = memberCoord("from")
                let to = memberCoord("to")
                let limit = parseSpeed(tags["maxspeed"])
                switch enforcement {
                case "average_speed":
                    if let start = from ?? device {
                        out.append(OSMHazard(id: "r\(e.id)", kind: .avgSpeed, lat: start.lat, lon: start.lon,
                                             maxspeed: limit, direction: nil, sectionEnd: to, name: tags["name"]))
                    }
                case "traffic_signals":
                    if let p = device ?? from {
                        out.append(OSMHazard(id: "r\(e.id)", kind: .redLight, lat: p.lat, lon: p.lon,
                                             maxspeed: nil, direction: nil, sectionEnd: nil, name: tags["name"]))
                    }
                case "maxspeed", "mindistance", "":
                    if let p = device ?? from {
                        out.append(OSMHazard(id: "r\(e.id)", kind: .camera, lat: p.lat, lon: p.lon,
                                             maxspeed: limit, direction: nil, sectionEnd: nil, name: tags["name"]))
                    }
                default:
                    continue
                }
                continue
            }
            guard let lat = e.lat ?? e.center?.lat, let lon = e.lon ?? e.center?.lon else { continue }
            if tags["highway"] == "speed_camera" {
                let dir = tags["direction"].flatMap { Double($0) } ?? tags["camera:direction"].flatMap { Double($0) }
                let tunnel = tags["tunnel"] == "yes" || tags["location"] == "tunnel"
                out.append(OSMHazard(id: "n\(e.id)", kind: .camera, lat: lat, lon: lon,
                                     maxspeed: parseSpeed(tags["maxspeed"]), direction: dir, sectionEnd: nil,
                                     name: tags["name"], detail: tunnel ? "tunnel" : nil))
            } else if let calming = tags["traffic_calming"], ["bump", "hump", "table", "cushion"].contains(calming) {
                out.append(OSMHazard(id: "b\(e.id)", kind: .bump, lat: lat, lon: lon, maxspeed: nil, direction: nil, sectionEnd: nil, name: calming))
            } else if tags["railway"] == "level_crossing" {
                out.append(OSMHazard(id: "x\(e.id)", kind: .crossing, lat: lat, lon: lon, maxspeed: nil, direction: nil, sectionEnd: nil, name: nil))
            } else if tags["amenity"] == "school" {
                out.append(OSMHazard(id: "s\(e.type.prefix(1))\(e.id)", kind: .school, lat: lat, lon: lon, maxspeed: nil, direction: nil, sectionEnd: nil, name: tags["name"]))
            }
        }
        // Drop camera nodes duplicated by an enforcement relation's device.
        var result: [OSMHazard] = []
        for h in out {
            if h.kind == .camera, h.id.hasPrefix("n"),
               out.contains(where: { $0.id.hasPrefix("r") && $0.kind != .school && Geo.distance($0.coordinate, h.coordinate) < 25 }) {
                continue
            }
            result.append(h)
        }
        return result
    }

    // MARK: Roads (snapping, speed limits, lanes)

    private(set) var roads: [Int64: OSMRoad] = [:]
    private(set) var roadCenter: CLLocationCoordinate2D?
    private var roadFetched = Date.distantPast
    private var roadLoading = false
    private var roadFailures = 0
    let roadRadius = 600.0

    /// True when road data covers this position, so "no road nearby" is meaningful.
    func roadsCover(_ c: CLLocationCoordinate2D) -> Bool {
        guard let center = roadCenter else { return false }
        return Geo.distance(center, c) < roadRadius - 120
    }

    func refreshRoadsIfNeeded(at c: CLLocationCoordinate2D, completion: @escaping () -> Void) {
        guard !roadLoading else { return }
        let minInterval = roadFailures > 0 ? min(120.0, 20.0 * Double(roadFailures)) : 12.0
        guard Date().timeIntervalSince(roadFetched) > minInterval else { return }
        if let center = roadCenter, Geo.distance(center, c) < roadRadius * 0.55 { return }
        roadLoading = true
        roadFetched = Date()
        let lat = String(format: "%.5f", c.latitude), lon = String(format: "%.5f", c.longitude)
        let q = """
        [out:json][timeout:25];
        way(around:\(Int(roadRadius)),\(lat),\(lon))["highway"~"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link|road|service)$"];
        out tags geom;
        """
        run(q) { [weak self] resp in
            guard let self else { return }
            self.roadLoading = false
            guard let resp else { self.roadFailures += 1; return }
            self.roadFailures = 0
            var fresh: [Int64: OSMRoad] = [:]
            for e in resp.elements where e.type == "way" {
                let coords = (e.geometry ?? []).compactMap { $0 }.map { Coord(lat: $0.lat, lon: $0.lon) }
                guard coords.count >= 2 else { continue }
                fresh[e.id] = OSMRoad(id: e.id, coords: coords, tags: e.tags ?? [:])
            }
            // keep previous roads within 1.5 km so we never lose the way we're on
            for (id, r) in self.roads where fresh[id] == nil && r.near(c, margin: 1500) { fresh[id] = r }
            self.roads = fresh
            self.roadCenter = c
            completion()
        }
    }

    struct RoadMatch {
        var road: OSMRoad
        var hit: PolylineHit
        var forward: Bool
    }

    /// Nearest road, preferring major roads and matching heading.
    func nearestRoad(to c: CLLocationCoordinate2D, course: Double?, includeMinor: Bool = true) -> RoadMatch? {
        var best: RoadMatch?
        var bestCost = Double.infinity
        for road in roads.values where road.near(c, margin: 80) {
            if !includeMinor && road.isMinor { continue }
            let coords = road.coords.map(\.cl)
            guard let hit = Geo.project(c, onto: coords, course: course, bidirectional: !road.oneway) else { continue }
            var cost = hit.distance + (road.isMinor ? 12 : 0)
            var forward = true
            if let course {
                let diff = Geo.angleDiff(hit.bearing, course)
                forward = diff <= 90
                let eff = road.oneway ? diff : min(diff, 180 - diff)
                cost += eff > 100 ? 40 : eff / 100 * 12
            }
            if cost < bestCost {
                bestCost = cost
                best = RoadMatch(road: road, hit: hit, forward: forward)
            }
        }
        return best
    }

    /// Plain nearest distance to any road (for off-road detection).
    func distanceToNearestRoad(_ c: CLLocationCoordinate2D) -> Double? {
        var best: Double?
        for road in roads.values where road.near(c, margin: 150) {
            if let hit = Geo.project(c, onto: road.coords.map(\.cl)) {
                if best == nil || hit.distance < best! { best = hit.distance }
            }
        }
        return best
    }

    // MARK: Transport

    private func run(_ query: String, attempt: Int = 0, completion: @escaping (OverpassResponse?) -> Void) {
        var req = URLRequest(url: endpoints[attempt % endpoints.count])
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = "data=" + (query.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        req.httpBody = body.data(using: .utf8)
        session.dataTask(with: req) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            var parsed: OverpassResponse?
            if status == 200, let data {
                do { parsed = try JSONDecoder().decode(OverpassResponse.self, from: data) }
                catch { print("[overpass] decode failed: \(error)") }
            } else {
                print("[overpass] \(self?.endpoints[attempt % (self?.endpoints.count ?? 1)].host ?? "?") status \(status) \(error?.localizedDescription ?? "")")
            }
            DispatchQueue.main.async {
                if parsed == nil, attempt == 0, let self {
                    // Back off before hitting the mirror; 429/504 mean the public server is busy.
                    let delay: Double = (status == 429 || status == 504) ? 5 : 1.5
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { completion(nil); return }
                        self.run(query, attempt: 1, completion: completion)
                    }
                } else {
                    completion(parsed)
                }
            }
        }.resume()
    }
}
