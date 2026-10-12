import Foundation
import CoreLocation
import MapKit
//

/// Flat-earth projection around an origin; accurate to well under a metre over a few km.
struct LocalProjector {
    let lat0: Double
    let lon0: Double
    let kx: Double
    let ky: Double

    init(_ origin: CLLocationCoordinate2D) {
        lat0 = origin.latitude
        lon0 = origin.longitude
        ky = 111_320
        kx = 111_320 * cos(origin.latitude * .pi / 180)
    }

    func xy(_ c: CLLocationCoordinate2D) -> SIMD2<Double> {
        SIMD2((c.longitude - lon0) * kx, (c.latitude - lat0) * ky)
    }

    func coord(_ p: SIMD2<Double>) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat0 + p.y / ky, longitude: lon0 + p.x / kx)
    }
}

struct PolylineHit {
    var coordinate: CLLocationCoordinate2D
    var distance: Double        // perpendicular distance, m
    var segment: Int            // index of segment start
    var along: Double           // distance along polyline from its start, m
    var bearing: Double         // segment bearing in node order, degrees
}

enum Geo {
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(la1) * cos(la2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    static func bearing(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let la1 = a.latitude * .pi / 180, la2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(la2)
        let x = cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dLon)
        return normalize(atan2(y, x) * 180 / .pi)
    }

    static func normalize(_ deg: Double) -> Double {
        var d = deg.truncatingRemainder(dividingBy: 360)
        if d < 0 { d += 360 }
        return d
    }

    /// Smallest absolute difference between two bearings (0...180).
    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(normalize(a) - normalize(b))
        return d > 180 ? 360 - d : d
    }

    /// Signed turn from a to b (-180...180, positive = right).
    static func signedTurn(_ a: Double, _ b: Double) -> Double {
        var d = normalize(b) - normalize(a)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    static func compassPoint(_ deg: Double) -> String {
        let names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return names[Int((normalize(deg) + 22.5) / 45) % 8]
    }

    static func compassText(_ deg: Double) -> String {
        "\(compassPoint(deg)) \(Int(normalize(deg).rounded()) % 360)°"
    }

    static func destination(_ from: CLLocationCoordinate2D, bearing: Double, distance: Double) -> CLLocationCoordinate2D {
        let r = 6_371_000.0
        let d = distance / r
        let b = bearing * .pi / 180
        let la1 = from.latitude * .pi / 180, lo1 = from.longitude * .pi / 180
        let la2 = asin(sin(la1) * cos(d) + cos(la1) * sin(d) * cos(b))
        let lo2 = lo1 + atan2(sin(b) * sin(d) * cos(la1), cos(d) - sin(la1) * sin(la2))
        return CLLocationCoordinate2D(latitude: la2 * 180 / .pi, longitude: lo2 * 180 / .pi)
    }

    static func interpolate(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                               longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    static func interpolateAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        normalize(a + signedTurn(a, b) * t)
    }

    static func cumulative(_ coords: [CLLocationCoordinate2D]) -> [Double] {
        var out = [Double](repeating: 0, count: coords.count)
        var acc = 0.0
        for i in 1..<max(coords.count, 1) where i < coords.count {
            acc += distance(coords[i - 1], coords[i])
            out[i] = acc
        }
        return out
    }

    /// Projects `p` onto a polyline. `course` (if valid) penalises segments pointing the wrong way;
    /// `bidirectional` treats both directions as valid (roads), otherwise node order is the travel direction (routes).
    static func project(_ p: CLLocationCoordinate2D, onto coords: [CLLocationCoordinate2D], cumulative cum: [Double]? = nil,
                        course: Double? = nil, bidirectional: Bool = true, range: Range<Int>? = nil) -> PolylineHit? {
        guard coords.count >= 2 else { return nil }
        let proj = LocalProjector(p)
        let lo = max(0, range?.lowerBound ?? 0)
        let hi = min(coords.count - 1, range?.upperBound ?? coords.count - 1)
        guard lo < hi else { return nil }
        var best: PolylineHit?
        var bestCost = Double.infinity
        var prev = proj.xy(coords[lo])
        for i in lo..<hi {
            let a = prev
            let b = proj.xy(coords[i + 1])
            prev = b
            let ab = b - a
            let len2 = ab.x * ab.x + ab.y * ab.y
            var t = 0.0
            if len2 > 0.0001 { t = min(1, max(0, -(a.x * ab.x + a.y * ab.y) / len2)) }
            let q = a + ab * t
            let dist = sqrt(q.x * q.x + q.y * q.y)
            if dist > 400 { continue }
            let segBearing = normalize(atan2(ab.x, ab.y) * 180 / .pi)
            var cost = dist
            if let c = course, len2 > 0.0001 {
                let diff = bidirectional ? min(angleDiff(segBearing, c), angleDiff(segBearing + 180, c)) : angleDiff(segBearing, c)
                cost += diff > 100 ? 40 : diff / 100 * 12
            }
            if cost < bestCost {
                bestCost = cost
                let segLen = sqrt(len2)
                let along = (cum?[i] ?? 0) + segLen * t
                best = PolylineHit(coordinate: proj.coord(q), distance: dist, segment: i, along: along, bearing: segBearing)
            }
        }
        return best
    }

    static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }

    /// Point at a given along-distance on a polyline.
    static func point(along d: Double, coords: [CLLocationCoordinate2D], cumulative cum: [Double]) -> CLLocationCoordinate2D? {
        guard let last = coords.last, coords.count == cum.count else { return nil }
        if d <= 0 { return coords.first }
        for i in 1..<coords.count where cum[i] >= d {
            let seg = cum[i] - cum[i - 1]
            let t = seg > 0 ? (d - cum[i - 1]) / seg : 0
            return interpolate(coords[i - 1], coords[i], t)
        }
        return last
    }

    /// Approximate time of sunrise/sunset check (NOAA simplified). Returns true when the sun is below the horizon.
    static func isNight(at c: CLLocationCoordinate2D?, date: Date = Date()) -> Bool {
        guard let c else {
            let h = Calendar.current.component(.hour, from: date)
            return h < 7 || h >= 19
        }
        let cal = Calendar(identifier: .gregorian)
        let doy = Double(cal.ordinality(of: .day, in: .year, for: date) ?? 1)
        var utc = cal
        utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = utc.dateComponents([.hour, .minute], from: date)
        let hourUTC = Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60
        let gamma = 2 * Double.pi / 365 * (doy - 1 + (hourUTC - 12) / 24)
        let decl = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma) - 0.006758 * cos(2 * gamma)
            + 0.000907 * sin(2 * gamma) - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let eqt = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma) - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let solarMinutes = hourUTC * 60 + eqt + 4 * c.longitude
        let ha = (solarMinutes / 4 - 180) * .pi / 180
        let lat = c.latitude * .pi / 180
        let cosZen = sin(lat) * sin(decl) + cos(lat) * cos(decl) * cos(ha)
        let elevation = 90 - acos(max(-1, min(1, cosZen))) * 180 / .pi
        return elevation < -0.83
    }
}
