import Foundation
import CoreLocation

/// User's own trap/hazard reports, favourites and saved parking spot. All on device.
final class TrapStore: ObservableObject {
    @Published private(set) var reports: [TrapReport] = []
    @Published private(set) var favourites: [FavouritePlace] = []
    @Published var parking: FavouritePlace? { didSet { saveParking() } }

    init() {
        reports = DiskStore.load([TrapReport].self, "reports.json") ?? []
        favourites = DiskStore.load([FavouritePlace].self, "favourites.json") ?? []
        parking = DiskStore.load(FavouritePlace.self, "parking.json")
    }

    func add(_ type: TrapType, at c: CLLocationCoordinate2D, heading: Double?) {
        // merge with an identical report within 40 m
        if let i = reports.firstIndex(where: { $0.type == type && Geo.distance($0.coordinate, c) < 40 }) {
            reports[i].created = Date()
        } else {
            reports.append(TrapReport(type: type, latitude: c.latitude, longitude: c.longitude, heading: heading))
        }
        DiskStore.save(reports, "reports.json")
    }

    func remove(_ r: TrapReport) {
        reports.removeAll { $0.id == r.id }
        DiskStore.save(reports, "reports.json")
    }

    func removeAllReports() {
        reports = []
        DiskStore.save(reports, "reports.json")
    }

    // MARK: Export / import (JSON via share sheet)

    struct ExportFile: Codable {
        var app = "TrapRadar"
        var version = 1
        var exported = Date()
        var reports: [TrapReport]
    }

    func exportURL() -> URL? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(ExportFile(reports: reports)) else { return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TrapRadar-reports-\(df.string(from: Date())).json")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    /// Merges reports from a JSON file. Returns number of new reports added.
    func importFile(_ url: URL) throws -> Int {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let incoming: [TrapReport]
        if let file = try? dec.decode(ExportFile.self, from: data) { incoming = file.reports }
        else { incoming = try dec.decode([TrapReport].self, from: data) }
        var added = 0
        for r in incoming {
            if reports.contains(where: { $0.id == r.id }) { continue }
            if let i = reports.firstIndex(where: { $0.type == r.type && Geo.distance($0.coordinate, r.coordinate) < 40 }) {
                if r.created > reports[i].created { reports[i].created = r.created }
                continue
            }
            reports.append(r)
            added += 1
        }
        DiskStore.save(reports, "reports.json")
        return added
    }

    // MARK: Favourites

    func addFavourite(name: String, at c: CLLocationCoordinate2D, icon: String = "star.fill") {
        favourites.append(FavouritePlace(name: name, latitude: c.latitude, longitude: c.longitude, icon: icon))
        DiskStore.save(favourites, "favourites.json")
    }

    func removeFavourite(_ f: FavouritePlace) {
        favourites.removeAll { $0.id == f.id }
        DiskStore.save(favourites, "favourites.json")
    }

    private func saveParking() {
        if let parking { DiskStore.save(parking, "parking.json") }
        else { try? FileManager.default.removeItem(at: DiskStore.dir.appendingPathComponent("parking.json")) }
    }
}
