import SwiftUI
import Charts

struct DayStat: Identifiable {
    let id = UUID()
    let day: Date
    let km: Double
    let score: Double?
}

/// Precise distance formatting (0.01 km / 0.01 mi).
func preciseDistance(_ m: Double, metric: Bool) -> (value: String, unit: String) {
    metric ? (String(format: "%.2f", m / 1000), "km") : (String(format: "%.2f", m / 1609.344), "mi")
}

struct InsightsView: View {
    @EnvironmentObject var trips: TripRecorder
    @EnvironmentObject var ds: DriveSettings
    @State private var appeared = false
    @State private var range = 1   // 0 today, 1 week, 2 all time

    private var metric: Bool { ds.speedUnits.metricDistances }
    private var liveMeters: Double { trips.active ? trips.live.distance : 0 }

    private func trips(since d: Date?) -> [TripRecord] {
        guard let d else { return trips.trips }
        return trips.trips.filter { $0.start >= d }
    }
    private var todayStart: Date { Calendar.current.startOfDay(for: Date()) }
    private var weekStart: Date { Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date() }
    private func meters(_ list: [TripRecord]) -> Double { list.reduce(0) { $0 + $1.distance } }

    private var rangeTrips: [TripRecord] { trips(since: range == 0 ? todayStart : range == 1 ? weekStart : nil) }

    private var days: [DayStat] {
        let cal = Calendar.current
        return (0..<7).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: todayStart) ?? todayStart
            let list = trips.trips.filter { cal.isDate($0.start, inSameDayAs: day) }
            var km = meters(list) / 1000
            if offset == 0 { km += liveMeters / 1000 }
            let score: Double? = list.isEmpty ? nil : Double(list.map(\.score).reduce(0, +)) / Double(list.count)
            return DayStat(day: day, km: km, score: score)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    let list = rangeTrips
                    let sum = WeekSummary(list)
                    hero(total: sum.distance + liveMeters, count: list.count)
                    if range == 1 { weeklyReport(list) }
                    if trips.active { liveCard }
                    totalsRow
                    HStack(spacing: 14) {
                        ScoreRing(score: list.isEmpty ? nil : sum.avgScore).frame(width: 120, height: 120)
                        VStack(spacing: 10) {
                            GlowCard(title: "Drive time", value: durationText(sum.time), icon: "clock.fill", colors: [.cyan, .blue])
                            GlowCard(title: "Avg speed", value: ds.speedUnits.speedText(sum.moving > 0 ? sum.distance / sum.moving : 0), icon: "gauge.medium", colors: [.mint, .teal])
                        }
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        GlowCard(title: "Max speed", value: ds.speedUnits.speedText(sum.maxSpeed), icon: "speedometer", colors: [.pink, .red])
                        GlowCard(title: "Speeding", value: durationText(sum.speeding), icon: "exclamationmark.triangle.fill", colors: [.orange, .red])
                        GlowCard(title: "Harsh brakes", value: "\(sum.brakes)", icon: "exclamationmark.octagon.fill", colors: [.yellow, .orange])
                        GlowCard(title: "Harsh accel", value: "\(sum.accels)", icon: "hare.fill", colors: [.yellow, .orange])
                        GlowCard(title: "Hard corners", value: "\(sum.corners)", icon: "arrow.triangle.turn.up.right.diamond.fill", colors: [.purple, .pink])
                        GlowCard(title: "Idle", value: durationText(sum.idle), icon: "pause.circle.fill", colors: [.gray, .blue])
                    }
                    chart
                    Text("RECENT TRIPS").font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(2)
                        .foregroundStyle(Theme.secondaryText)
                    if trips.trips.isEmpty {
                        EmptyStateView(icon: "car.side.fill", title: "No trips yet",
                                       message: "Trips record automatically once you drive faster than 15 km/h with the Drive tab active. Trips of 100 m or more are saved.")
                    }
                    ForEach(Array(trips.trips.prefix(50).enumerated()), id: \.element.id) { i, t in
                        TripRow(trip: t)
                            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 20)
                            .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(min(i, 10)) * 0.04), value: appeared)
                            .contextMenu { Button(role: .destructive) { trips.deleteTrip(t) } label: { Label("Delete trip", systemImage: "trash") } }
                    }
                    Text("Distance uses only fixes with ≤20 m accuracy, ignores GPS jumps and stationary drift. Harsh events are estimates.")
                        .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.secondaryText)
                }
                .padding()
            }
            .background(
                Theme.background.ignoresSafeArea()
            )
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { appeared = true }
        }
    }

    private func hero(total: Double, count: Int) -> some View {
        let d = preciseDistance(total, metric: metric)
        return VStack(alignment: .leading, spacing: 8) {
            Picker("Range", selection: $range.animation(.spring())) {
                Text("Today").tag(0); Text("7 days").tag(1); Text("All time").tag(2)
            }.pickerStyle(.segmented)
            Text("DISTANCE DRIVEN").font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(3)
                .foregroundStyle(Theme.secondaryText).padding(.top, 6)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(d.value)
                    .font(.system(size: 68, weight: .black, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText(value: total))
                    .foregroundStyle(Theme.accent)
                    .animation(.spring(response: 0.6), value: total)
                Text(d.unit).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(Theme.secondaryText)
            }
            .scaleEffect(appeared ? 1 : 0.85).opacity(appeared ? 1 : 0)
            .animation(.spring(response: 0.7, dampingFraction: 0.7), value: appeared)
            Text("\(count) trip\(count == 1 ? "" : "s")\(trips.active ? " + 1 in progress" : "") · stored on this iPhone")
                .font(Typo.caption).foregroundStyle(Theme.secondaryText)
        }
    }

    private func weeklyReport(_ list: [TripRecord]) -> some View {
        let sum = WeekSummary(list)
        let d = preciseDistance(sum.distance, metric: metric)
        let best = list.max { a, b in
            if a.score != b.score { return a.score < b.score }
            return a.distance < b.distance
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("WEEKLY DRIVING REPORT").font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(2)
                .foregroundStyle(Theme.secondaryText)
            Text("\(d.value) \(d.unit)").font(.system(size: 28, weight: .black, design: .rounded)).monospacedDigit()
                .foregroundStyle(Theme.accent)
            Text("Average score \(list.isEmpty ? "—" : "\(sum.avgScore)")").font(Typo.caption).foregroundStyle(Theme.secondaryText)
            if let best {
                let bd = preciseDistance(best.distance, metric: metric)
                Text("Best trip \(bd.value) \(bd.unit) · score \(best.score) · \(best.start.formatted(date: .abbreviated, time: .shortened))")
                    .font(Typo.caption.weight(.semibold)).foregroundStyle(Theme.ink)
            } else {
                Text("No trips in the last 7 days.").font(Typo.caption).foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .premiumCard(radius: 20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.hairline, lineWidth: 1))
    }

    private var liveCard: some View {
        let d = preciseDistance(trips.live.distance, metric: metric)
        return HStack {
            Circle().fill(Color.red).frame(width: 10, height: 10)
                .shadow(color: .red, radius: 6)
                .opacity(appeared ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: appeared)
            Text("LIVE TRIP").font(.system(size: 12, weight: .heavy, design: .rounded)).tracking(2)
            Spacer()
            Text("\(d.value) \(d.unit)").font(Typo.number(20, .bold)).monospacedDigit()
                .contentTransition(.numericText(value: trips.live.distance))
                .animation(.spring(), value: trips.live.distance)
            Text("· \(durationText(Date().timeIntervalSince(trips.live.start)))").font(Typo.caption).foregroundStyle(Theme.secondaryText)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.red.opacity(0.5), lineWidth: 1))
    }

    private var totalsRow: some View {
        let t = preciseDistance(meters(trips(since: todayStart)) + liveMeters, metric: metric)
        let w = preciseDistance(meters(trips(since: weekStart)) + liveMeters, metric: metric)
        let a = preciseDistance(meters(trips.trips) + liveMeters, metric: metric)
        return HStack(spacing: 10) {
            GlowCard(title: "Today", value: "\(t.value) \(t.unit)", icon: "sun.max.fill", colors: [.yellow, .orange])
            GlowCard(title: "7 days", value: "\(w.value) \(w.unit)", icon: "calendar", colors: [.cyan, .blue])
            GlowCard(title: "All time", value: "\(a.value) \(a.unit)", icon: "infinity", colors: [.purple, .pink])
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DISTANCE PER DAY").font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(2)
                .foregroundStyle(Theme.secondaryText)
            Chart(days) { d in
                BarMark(x: .value("Day", d.day, unit: .day), y: .value(metric ? "km" : "mi", appeared ? (metric ? d.km : d.km / 1.609344) : 0))
                    .foregroundStyle(Theme.accent.gradient)
                    .cornerRadius(6)
            }
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .frame(height: 170)
            .animation(.spring(response: 0.8, dampingFraction: 0.75), value: appeared)
        }
        .padding(16)
        .premiumCard(radius: 20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct GlowCard: View {
    let title: String
    let value: String
    let icon: String
    let colors: [Color]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title.uppercased(), systemImage: icon)
                .font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(1)
                .foregroundStyle(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .premiumCard(radius: 16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct WeekSummary {
    var distance = 0.0, time = 0.0, speeding = 0.0, idle = 0.0, maxSpeed = 0.0, moving = 0.0
    var brakes = 0, accels = 0, corners = 0, avgScore = 0

    init(_ trips: [TripRecord]) {
        var scoreSum = 0
        for t in trips {
            distance += t.distance
            time += t.duration
            speeding += t.speedingSeconds
            idle += t.idleSeconds
            moving += t.movingSeconds
            maxSpeed = max(maxSpeed, t.maxSpeed)
            brakes += t.harshBrakes
            accels += t.harshAccels
            corners += t.hardCorners
            scoreSum += t.score
        }
        avgScore = trips.isEmpty ? 0 : scoreSum / trips.count
    }
}

struct ScoreRing: View {
    let score: Int?
    @State private var progress: CGFloat = 0
    var body: some View {
        ZStack {
            Circle().stroke(Color.black.opacity(0.07), lineWidth: 12)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(AngularGradient(colors: [color.opacity(0.5), color, color.opacity(0.5)], center: .center),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(score.map { "\($0)" } ?? "--").font(.system(size: 36, weight: .black, design: .rounded))
                Text("SCORE").font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(2).foregroundStyle(Theme.secondaryText)
            }
        }
        .onAppear { withAnimation(.spring(response: 1.1, dampingFraction: 0.8)) { progress = CGFloat(score ?? 0) / 100 } }
        .onChange(of: score) { _, s in withAnimation(.spring()) { progress = CGFloat(s ?? 0) / 100 } }
    }
    private var color: Color {
        guard let s = score else { return .gray }
        return s >= 80 ? Theme.good : (s >= 60 ? Theme.amber : Theme.mutedRed)
    }
}

struct TripRow: View {
    let trip: TripRecord
    @EnvironmentObject var ds: DriveSettings
    var body: some View {
        let d = preciseDistance(trip.distance, metric: ds.speedUnits.metricDistances)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.start, format: .dateTime.weekday().day().month().hour().minute())
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.secondaryText)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(d.value).font(.system(size: 26, weight: .black, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.accent)
                    Text(d.unit).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(Theme.secondaryText)
                }
                Text("\(durationText(trip.duration)) · avg \(ds.speedUnits.speedText(trip.avgSpeed)) · max \(ds.speedUnits.speedText(trip.maxSpeed))")
                    .font(Typo.caption.monospacedDigit()).foregroundStyle(Color.black.opacity(0.75))
                HStack(spacing: 10) {
                    Label("\(trip.harshBrakes)", systemImage: "exclamationmark.octagon")
                    Label("\(trip.harshAccels)", systemImage: "hare")
                    Label("\(trip.hardCorners)", systemImage: "arrow.triangle.turn.up.right.diamond")
                    if let f = trip.fuelLitres { Label(String(format: "%.2f L", f), systemImage: "fuelpump") }
                }
                .font(Typo.label).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            ScoreRing(score: trip.score).frame(width: 54, height: 54)
        }
        .padding(14)
        .premiumCard(radius: 18)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Places to go (nearby parks, dog parks, likely-shady spots)

import MapKit

enum PlaceCategory: String, CaseIterable, Identifiable {
    case all = "All", parks = "Parks", dogParks = "Dog Parks", shady = "Shady Spots", water = "Beaches", views = "Trails & Views"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .all: return "sparkles"
        case .parks: return "tree.fill"
        case .dogParks: return "pawprint.fill"
        case .shady: return "leaf.fill"
        case .water: return "beach.umbrella.fill"
        case .views: return "figure.hiking"
        }
    }
}

struct SuggestedPlace: Identifiable {
    let id: String
    let item: MKMapItem
    let distance: CLLocationDistance
    var tags: Set<PlaceCategory>
    var name: String { item.name ?? "Unnamed place" }
}

@MainActor
final class PlacesSuggester: ObservableObject {
    @Published var places: [SuggestedPlace] = []
    @Published var loading = false
    @Published var error: String?
    private var lastCenter: CLLocation?

    func refresh(near loc: CLLocation, force: Bool = false) async {
        if !force, let last = lastCenter, last.distance(from: loc) < 500, !places.isEmpty { return }
        guard !loading else { return }
        loading = true; error = nil
        defer { loading = false }
        lastCenter = loc
        let region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 8000, longitudinalMeters: 8000)
        var bucket: [String: SuggestedPlace] = [:]

        func add(_ items: [MKMapItem], _ tags: Set<PlaceCategory>) {
            for it in items {
                guard let c = it.placemark.location else { continue }
                let key = "\(it.name ?? "")|\(String(format: "%.4f,%.4f", c.coordinate.latitude, c.coordinate.longitude))"
                var t = tags
                let n = (it.name ?? "").lowercased()
                if n.contains("dog") || n.contains("off-leash") || n.contains("off leash") { t.insert(.dogParks) }
                if ["forest", "wood", "trail", "garden", "nature", "reserve", "grove", "arboretum"].contains(where: n.contains) { t.insert(.shady) }
                if var e = bucket[key] { e.tags.formUnion(t); bucket[key] = e }
                else { bucket[key] = SuggestedPlace(id: key, item: it, distance: c.distance(from: loc), tags: t) }
            }
        }

        // 1) Points of interest by category (no API keys; Apple Maps).
        let poi: [(MKPointOfInterestCategory, Set<PlaceCategory>)] = [
            (.park, [.parks]), (.nationalPark, [.parks, .shady, .views]), (.beach, [.water]),
        ]
        for (cat, tags) in poi {
            let req = MKLocalPointsOfInterestRequest(center: loc.coordinate, radius: 5000)
            req.pointOfInterestFilter = MKPointOfInterestFilter(including: [cat])
            if let r = try? await MKLocalSearch(request: req).start() { add(r.mapItems, tags) }
        }
        // 2) Natural-language searches for things POI categories don't cover.
        let queries: [(String, Set<PlaceCategory>)] = [
            ("dog park", [.dogParks, .parks]),
            ("forest", [.shady]), ("trail", [.shady, .views]), ("garden", [.shady, .parks]),
            ("nature reserve", [.shady, .parks]), ("viewpoint", [.views]), ("playground", [.parks]),
        ]
        var anyOK = false
        for (q, tags) in queries {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            req.region = region
            req.resultTypes = .pointOfInterest
            do { let r = try await MKLocalSearch(request: req).start(); add(r.mapItems, tags); anyOK = true }
            catch { continue }
        }
        places = bucket.values.filter { $0.distance < 15_000 }.sorted { $0.distance < $1.distance }
        if places.isEmpty { error = anyOK ? "Nothing found nearby." : "Couldn't reach Apple Maps. Check your connection." }
    }
}

struct PlacesView: View {
    @EnvironmentObject var drive: DriveEngine
    @StateObject private var model = PlacesSuggester()
    @State private var category: PlaceCategory = .all

    private var shown: [SuggestedPlace] {
        category == .all ? model.places : model.places.filter { $0.tags.contains(category) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PlaceCategory.allCases) { c in
                            Button { category = c } label: {
                                Label(c.rawValue, systemImage: c.icon)
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .background(Capsule().fill(category == c ? Theme.accent : Color.secondary.opacity(0.15)))
                                    .foregroundStyle(category == c ? Color.white : Color.primary)
                            }
                        }
                    }.padding(.horizontal).padding(.vertical, 10)
                }
                List {
                    if category == .shady {
                        Text("“Likely shady” is a guess from the type of place (forests, trails, gardens, reserves). Real tree-cover data isn't available.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if drive.location == nil {
                        Text("Waiting for your location…").foregroundStyle(.secondary)
                    } else if model.loading && model.places.isEmpty {
                        HStack { ProgressView(); Text("Finding places near you…") }
                    } else if let e = model.error, shown.isEmpty {
                        Text(e).foregroundStyle(.secondary)
                    } else if shown.isEmpty {
                        Text("No \(category.rawValue.lowercased()) nearby.").foregroundStyle(.secondary)
                    }
                    ForEach(shown) { p in
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: p)).foregroundStyle(Theme.accent).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).font(.body.weight(.semibold))
                                HStack(spacing: 6) {
                                    Text(distanceText(p.distance))
                                    if p.tags.contains(.dogParks) { Text("· Dog park") }
                                    if p.tags.contains(.shady) { Text("· Likely shady") }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                p.item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
                            } label: { Image(systemName: "map.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Open \(p.name) in Maps")
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { if let l = drive.location { await model.refresh(near: l, force: true) } }
            }
            .navigationTitle("Places to go")
        }
        .task(id: drive.location.map { "\(Int($0.coordinate.latitude * 200)),\(Int($0.coordinate.longitude * 200))" }) {
            if let l = drive.location { await model.refresh(near: l) }
        }
    }

    private func icon(for p: SuggestedPlace) -> String {
        if p.tags.contains(.dogParks) { return PlaceCategory.dogParks.icon }
        if p.tags.contains(.water) { return PlaceCategory.water.icon }
        if p.tags.contains(.shady) { return PlaceCategory.shady.icon }
        if p.tags.contains(.views) { return PlaceCategory.views.icon }
        return PlaceCategory.parks.icon
    }

    private func distanceText(_ m: CLLocationDistance) -> String {
        let f = MeasurementFormatter(); f.unitOptions = .naturalScale; f.numberFormatter.maximumFractionDigits = 1
        return f.string(from: Measurement(value: m, unit: UnitLength.meters))
    }
}
