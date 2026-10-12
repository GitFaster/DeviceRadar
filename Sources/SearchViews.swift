import Combine
import SwiftUI
import MapKit
import UniformTypeIdentifiers

struct PlaceResult: Identifiable {
    let id = UUID()
    let item: MKMapItem
    let distance: Double
    var eta: Double?
}

// MARK: - Destination search + favourites

struct DestinationSearchView: View {
    var onPick: (MKMapItem) -> Void
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var traps: TrapStore
    @EnvironmentObject var ds: DriveSettings
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var searching = false
    @State private var naming = false
    @State private var newName = ""
    @State private var pendingFavourite: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            List {
                if results.isEmpty {
                    Section("Favourites") {
                        ForEach(traps.favourites) { f in
                            Button { onPick(makeMapItem(f.coordinate, name: f.name)) } label: {
                                Label(f.name, systemImage: f.icon)
                            }
                        }
                        .onDelete { idx in idx.map { traps.favourites[$0] }.forEach(traps.removeFavourite) }
                        Button {
                            pendingFavourite = engine.location?.coordinate
                            newName = ""
                            naming = pendingFavourite != nil
                        } label: { Label("Save current location", systemImage: "plus.circle") }
                        if let p = traps.parking {
                            Button { onPick(makeMapItem(p.coordinate, name: "My car")) } label: {
                                Label("Find my car", systemImage: "car.fill")
                            }
                        }
                    }
                }
                if searching { ProgressView() }
                ForEach(results) { r in
                    Button { onPick(r.item) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.item.name ?? "Place").font(Typo.headline)
                                Text(address(r.item)).font(Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(ds.speedUnits.distance(r.distance)).font(Typo.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button {
                            traps.addFavourite(name: r.item.name ?? "Place", at: mapItemCoordinate(r.item))
                        } label: { Label("Add to favourites", systemImage: "star") }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search places or addresses")
            .onSubmit(of: .search) { search() }
            .navigationTitle("Where to?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .alert("Name this place", isPresented: $naming) {
                TextField("Home, Work…", text: $newName)
                Button("Save") {
                    if let c = pendingFavourite { traps.addFavourite(name: newName.isEmpty ? "Saved place" : newName, at: c) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func search() {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        searching = true
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        if let c = engine.location?.coordinate {
            req.region = MKCoordinateRegion(center: c, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        MKLocalSearch(request: req).start { resp, _ in
            DispatchQueue.main.async {
                searching = false
                let here = engine.location?.coordinate
                results = (resp?.mapItems ?? []).map { item in
                    PlaceResult(item: item, distance: here.map { Geo.distance($0, mapItemCoordinate(item)) } ?? 0)
                }
                .sorted { $0.distance < $1.distance }
            }
        }
    }
}

func address(_ item: MKMapItem) -> String {
    let p = item.placemark
    return [p.subThoroughfare, p.thoroughfare, p.locality].compactMap { $0 }.joined(separator: " ")
}

// MARK: - Nearby (MKLocalSearch, no Google)

enum NearbyCategory: String, CaseIterable, Identifiable {
    case food, gas, ev, parking, coffee
    var id: String { rawValue }
    var label: String {
        switch self { case .food: return "Food"; case .gas: return "Gas"; case .ev: return "EV charging"; case .parking: return "Parking"; case .coffee: return "Coffee" }
    }
    var icon: String {
        switch self { case .food: return "fork.knife"; case .gas: return "fuelpump.fill"; case .ev: return "bolt.car.fill"; case .parking: return "parkingsign"; case .coffee: return "cup.and.saucer.fill" }
    }
    var categories: [MKPointOfInterestCategory] {
        switch self {
        case .food: return [.restaurant, .cafe, .bakery, .foodMarket]
        case .gas: return [.gasStation]
        case .ev: return [.evCharger]
        case .parking: return [.parking]
        case .coffee: return [.cafe]
        }
    }
    var extraQuery: String? {
        switch self { case .food: return "fast food"; case .coffee: return "coffee"; default: return nil }
    }
}

struct NearbyPlacesView: View {
    var onPick: (MKMapItem) -> Void
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var ds: DriveSettings
    @Environment(\.dismiss) private var dismiss
    @State private var category: NearbyCategory = .food
    @State private var results: [PlaceResult] = []
    @State private var loading = false
    @State private var radius: Double = 5000
    @State private var token = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s) {
                        ForEach(NearbyCategory.allCases) { c in
                            PillButton(title: c.label, icon: c.icon, filled: c == category) {
                                category = c
                                load()
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                }
                List {
                    if loading { ProgressView("Searching within \(ds.speedUnits.distance(radius))…") }
                    if !loading && results.isEmpty {
                        Text("Nothing found nearby.").foregroundStyle(.secondary)
                    }
                    ForEach(results) { r in
                        Button { onPick(r.item) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.item.name ?? "Place").font(Typo.headline)
                                    Text(address(r.item)).font(Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(ds.speedUnits.distance(r.distance)).font(Typo.caption.monospacedDigit())
                                    if let e = r.eta { Text(durationText(e)).font(Typo.caption.monospacedDigit()).foregroundStyle(Theme.good) }
                                }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .background(Theme.background)
            .navigationTitle("Nearby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onAppear { load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() {
        guard let here = engine.location?.coordinate else { return }
        let t = UUID()
        token = t
        loading = true
        results = []
        search(here: here, radius: 5000, token: t)
    }

    private func search(here: CLLocationCoordinate2D, radius r: Double, token t: UUID) {
        radius = r
        let cat = category
        let group = DispatchGroup()
        var items: [MKMapItem] = []
        let poi = MKLocalPointsOfInterestRequest(center: here, radius: r)
        poi.pointOfInterestFilter = MKPointOfInterestFilter(including: cat.categories)
        group.enter()
        MKLocalSearch(request: poi).start { resp, _ in
            DispatchQueue.main.async { items += resp?.mapItems ?? []; group.leave() }
        }
        if let q = cat.extraQuery {
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            req.resultTypes = .pointOfInterest
            req.region = MKCoordinateRegion(center: here, latitudinalMeters: r * 2, longitudinalMeters: r * 2)
            group.enter()
            MKLocalSearch(request: req).start { resp, _ in
                DispatchQueue.main.async { items += resp?.mapItems ?? []; group.leave() }
            }
        }
        group.notify(queue: .main) {
            guard t == token else { return }
            var seen = Set<String>()
            let list = items.compactMap { item -> PlaceResult? in
                let c = mapItemCoordinate(item)
                let key = "\(item.name ?? "")-\(Int(c.latitude * 10000))-\(Int(c.longitude * 10000))"
                guard !seen.contains(key) else { return nil }
                seen.insert(key)
                let d = Geo.distance(here, c)
                return d <= r * 1.2 ? PlaceResult(item: item, distance: d) : nil
            }
            .sorted { $0.distance < $1.distance }
            if list.count < 3 && r < 20_000 {
                search(here: here, radius: r * 2, token: t)
                return
            }
            loading = false
            results = Array(list.prefix(25))
            fetchETAs(from: here, token: t, index: 0)
        }
    }

    /// Sequential ETAs for the closest results (keeps within Apple's request limits).
    private func fetchETAs(from here: CLLocationCoordinate2D, token t: UUID, index: Int) {
        guard t == token, index < min(results.count, 8) else { return }
        let req = MKDirections.Request()
        req.source = makeMapItem(here)
        req.destination = results[index].item
        req.transportType = .automobile
        req.departureDate = Date()
        MKDirections(request: req).calculateETA { resp, _ in
            DispatchQueue.main.async {
                guard t == token, index < results.count else { return }
                results[index].eta = resp?.expectedTravelTime
                fetchETAs(from: here, token: t, index: index + 1)
            }
        }
    }
}

// MARK: - Reports (add, list, export / import JSON)

struct ReportSheet: View {
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var traps: TrapStore
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var message: String?
    @State private var exportURL: URL?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                        ForEach(TrapType.allCases) { t in
                            Button {
                                engine.report(t)
                                dismiss()
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: t.icon).font(.title2).symbolRenderingMode(.hierarchical)
                                    Text(t.label).font(Typo.caption.weight(.semibold))
                                }
                                .foregroundStyle(Theme.amber)
                                .frame(maxWidth: .infinity, minHeight: 74)
                                .background(Theme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: { Text("Report at my position") } footer: {
                    Text("Reports stay on this iPhone. You'll get an alert when approaching them. Share them with friends as a JSON file.")
                }

                Section("Share") {
                    if let url = exportURL {
                        ShareLink(item: url) { Label("Export \(traps.reports.count) reports (JSON)", systemImage: "square.and.arrow.up") }
                    }
                    Button { importing = true } label: { Label("Import reports (JSON)", systemImage: "square.and.arrow.down") }
                    if let message { Text(message).font(Typo.caption).foregroundStyle(.secondary) }
                }

                Section("My reports (\(traps.reports.count))") {
                    ForEach(traps.reports.sorted { $0.created > $1.created }) { r in
                        HStack {
                            Image(systemName: r.type.icon).foregroundStyle(Theme.amber)
                            VStack(alignment: .leading) {
                                Text(r.type.label)
                                Text(r.created, style: .relative).font(Typo.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let c = engine.location?.coordinate {
                                Text(SpeedUnits.kmh.distance(Geo.distance(c, r.coordinate))).font(Typo.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions { Button(role: .destructive) { traps.remove(r) } label: { Label("Delete", systemImage: "trash") } }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    do {
                        let n = try traps.importFile(url)
                        message = "Imported \(n) new report\(n == 1 ? "" : "s") (duplicates merged)."
                        exportURL = traps.exportURL()
                    } catch {
                        message = "Couldn't read that file: \(error.localizedDescription)"
                    }
                case .failure(let e):
                    message = e.localizedDescription
                }
            }
            .onAppear { exportURL = traps.exportURL() }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Reference-style light flows (Where to / POI list / Route preview / Contacts)

import Speech
import Contacts
import AVFoundation

enum LightUI {
    static let blue = Theme.accent
    static let bg = Theme.dyn(0xF2F4F7, 0x060A14)
    static let card = Theme.dyn(0xFFFFFF, 0x0B1220)
    static let text = Theme.ink
    static let sub = Theme.dyn(0x6B7280, 0x8B95AB)
    static let green = Color(hex: 0x1E9E5A)
    static let orange = Color(hex: 0xF08A24)
}

struct RecentPlace: Codable, Identifiable, Equatable {
    var id: String { "\(name)|\(lat)|\(lon)" }
    var name: String
    var address: String
    var lat: Double
    var lon: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var mapItem: MKMapItem { makeMapItem(coordinate, name: name) }
}

enum RecentStore {
    private static let key = "dr.recentPlaces"
    static func load() -> [RecentPlace] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let r = try? JSONDecoder().decode([RecentPlace].self, from: d) else { return [] }
        return r
    }
    static func add(_ item: MKMapItem) {
        let c = mapItemCoordinate(item)
        let p = RecentPlace(name: item.name ?? "Destination", address: address(item), lat: c.latitude, lon: c.longitude)
        var list = load().filter { $0.id != p.id && !($0.name == p.name && Geo.distance($0.coordinate, c) < 30) }
        list.insert(p, at: 0)
        if let d = try? JSONEncoder().encode(Array(list.prefix(25))) { UserDefaults.standard.set(d, forKey: key) }
    }
}

func kmText(_ m: Double) -> String {
    m < 1000 ? "\(Int(m.rounded())) m" : String(format: m < 10_000 ? "%.1f km" : "%.0f km", m / 1000)
}

// MARK: Speech-to-text

final class SpeechInput: ObservableObject {
    @Published var listening = false
    @Published var transcript = ""
    private let recognizer = SFSpeechRecognizer()
    private let audio = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() { listening ? stop() : start() }

    func start() {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else { return }
                AVAudioApplication.requestRecordPermission { ok in
                    DispatchQueue.main.async { if ok { self.begin() } }
                }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { return }
        SpeechInput.queue.async {
            let session = AVAudioSession.sharedInstance()
            let ok = (try? session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])) != nil
                && (try? session.setActive(true, options: .notifyOthersOnDeactivation)) != nil
            DispatchQueue.main.async { if ok { self.beginRecognition(recognizer) } }
        }
    }

    static let queue = DispatchQueue(label: "radarbot.speech-session")

    private func beginRecognition(_ recognizer: SFSpeechRecognizer) {
        do {
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req
            let input = audio.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in req.append(buf) }
            audio.prepare()
            try audio.start()
            listening = true
            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                DispatchQueue.main.async {
                    if let r = result { self?.transcript = r.bestTranscription.formattedString }
                    if error != nil || (result?.isFinal ?? false) { self?.stop() }
                }
            }
        } catch { stop() }
    }

    func stop() {
        audio.stop()
        audio.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        listening = false
        SpeechInput.queue.async { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}

// MARK: Where do you want to go?

enum WhereRoute: Hashable {
    case pois(POICategory)
    case preview(PreviewTarget)
    case contacts
    case favourites
}

struct PreviewTarget: Hashable {
    let item: MKMapItem
    static func == (a: Self, b: Self) -> Bool { a.item === b.item }
    func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(item)) }
}

enum POICategory: String, Hashable {
    case gas, hotel
    var title: String { self == .gas ? "Gas stations" : "Hotels" }
    var icon: String { self == .gas ? "fuelpump.fill" : "bed.double.fill" }
    var mk: MKPointOfInterestCategory { self == .gas ? .gasStation : .hotel }
}

struct WhereToView: View {
    @EnvironmentObject var nav: NavigationEngine
    var onStart: (RouteOption, MKMapItem, [MKMapItem]) -> Void
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var traps: TrapStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var speech = SpeechInput()
    @State private var path: [WhereRoute] = []
    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var recents: [RecentPlace] = RecentStore.load()
    @State private var showContactPrompt = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                VStack(spacing: 14) {
                    header
                    modePicker
                    searchField
                    chips
                    list
                }
                .padding(.horizontal, 16)
                .background(LightUI.bg.ignoresSafeArea())
                if showContactPrompt {
                    ContactPermissionCard(onDecline: { withAnimation(.spring) { showContactPrompt = false } },
                                          onAccept: requestContacts)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: WhereRoute.self) { r in
                Group { switch r {
                case .pois(let c): POIListView(category: c) { item in open(item) }
                case .contacts: ContactsListView { item in open(item) }
                case .favourites: FavouritesListView { item in open(item) }
                case .preview(let t): RoutePreviewView(destination: t.item) { opt, first, rest in
                    RecentStore.add(t.item)
                    onStart(opt, first, rest)
                }
                } }
                .toolbar(.hidden, for: .navigationBar)
                .navigationBarBackButtonHidden(true)
            }
        }
        .preferredColorScheme(AppTheme.scheme)
        .onChange(of: speech.transcript) { _, t in if !t.isEmpty { query = t } }
        .onChange(of: query) { _, _ in scheduleSearch() }
        #if DEBUG
        .onAppear {
            let d = UserDefaults.standard
            if let q = d.string(forKey: "query") { query = q }
            if d.string(forKey: "push") == "favourites" { path.append(.favourites) }
            if d.string(forKey: "push") == "contacts" { path.append(.contacts) }
        }
        #endif
    }

    private func open(_ item: MKMapItem) { path.append(.preview(PreviewTarget(item: item))) }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.title3.weight(.semibold)).foregroundStyle(LightUI.text)
                    .frame(width: 44, height: 44)
            }
            Text("Where do you want to...").font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(LightUI.text)
            Spacer()
            Menu {
                Button(role: .destructive) {
                    UserDefaults.standard.removeObject(forKey: "dr.recentPlaces"); recents = []
                } label: { Label("Clear recents", systemImage: "clock.arrow.circlepath") }
            } label: {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.title3).foregroundStyle(LightUI.text)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.top, 8)
    }

    private var modePicker: some View {
        HStack(spacing: 8) {
            modeButton("Driving", icon: "car.fill", mode: .automobile)
            modeButton("Walking", icon: "figure.walk", mode: .walking)
        }
        .padding(5)
        .background(LightUI.card, in: Capsule())
        .overlay(Capsule().stroke(Color.black.opacity(0.12), lineWidth: 1))
    }

    private func modeButton(_ title: String, icon: String, mode: MKDirectionsTransportType) -> some View {
        let selected = nav.transport == mode
        return Button { nav.transport = mode } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(selected ? .white : LightUI.text)
                .frame(maxWidth: .infinity).frame(height: 40)
                .background(selected ? LightUI.blue : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(LightUI.sub)
            TextField("Enter your destination", text: $query)
                .textInputAutocapitalization(.words).autocorrectionDisabled()
                .foregroundStyle(LightUI.text)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(LightUI.sub) }
            }
            Button { speech.toggle() } label: {
                Image(systemName: speech.listening ? "waveform" : "mic.fill")
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(speech.listening ? Color.red : LightUI.blue, in: Circle())
                    .symbolEffect(.pulse, isActive: speech.listening)
            }
            .accessibilityLabel(speech.listening ? "Stop dictation" : "Dictate destination")
        }
        .padding(.leading, 16).padding(.trailing, 5).frame(height: 52)
        .background(LightUI.card, in: Capsule())
        .overlay(Capsule().stroke(Color.black.opacity(0.18), lineWidth: 1))
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                chip("Home", "house") {
                    if let h = traps.favourites.first(where: { $0.icon == "house.fill" }) { open(makeMapItem(h.coordinate, name: "Home")) } else { path.append(.favourites) }
                }
                chip("Work", "briefcase") {
                    if let w = traps.favourites.first(where: { $0.icon == "briefcase.fill" }) { open(makeMapItem(w.coordinate, name: "Work")) } else { path.append(.favourites) }
                }
                chip("Favourites", "star") { path.append(.favourites) }
                chip("My contacts", "person.crop.circle") { withAnimation(.spring) { showContactPrompt = true } }
                chip("Gas stations", "fuelpump") { path.append(.pois(.gas)) }
                chip("Hotels", "bed.double") { path.append(.pois(.hotel)) }
            }
            .padding(.vertical, 2)
        }
    }

    private func chip(_ t: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(t, systemImage: icon).font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(LightUI.blue)
                .padding(.horizontal, 16).frame(height: 40)
                .background(LightUI.card, in: Capsule())
                .overlay(Capsule().stroke(Color.black.opacity(0.18), lineWidth: 1))
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !results.isEmpty {
                    ForEach(results) { r in
                        PlaceRow(icon: "mappin.circle.fill", name: r.item.name ?? "Place", subtitle: address(r.item), distance: r.distance) { open(r.item) }
                        Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5).padding(.leading, 70)
                    }
                } else if !query.trimmingCharacters(in: .whitespaces).isEmpty && searchTask == nil {
                    EmptyStateView(icon: "magnifyingglass", title: "No results", message: "Nothing matched \u{201C}\(query)\u{201D}. Try a different name or address.")
                } else {
                    ForEach(recents) { p in
                        PlaceRow(icon: "clock", name: p.name, subtitle: p.address, distance: here.map { Geo.distance($0, p.coordinate) }) { open(p.mapItem) }
                        Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5).padding(.leading, 70)
                    }
                    if recents.isEmpty {
                        EmptyStateView(icon: "clock.arrow.circlepath", title: "No recent destinations", message: "Places you navigate to will appear here.")
                    }
                }
            }
            .glassPanel(radius: 28)
        }
    }

    private var here: CLLocationCoordinate2D? { engine.location?.coordinate }

    private func scheduleSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { results = []; return }
        searchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = q
            if let h = here { req.region = MKCoordinateRegion(center: h, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
            let items = (try? await MKLocalSearch(request: req).start())?.mapItems ?? []
            guard !Task.isCancelled else { return }
            results = items.map { it in PlaceResult(item: it, distance: here.map { h in Geo.distance(h, mapItemCoordinate(it)) } ?? 0) }
        }
    }

    private func requestContacts() {
        CNContactStore().requestAccess(for: .contacts) { ok, _ in
            DispatchQueue.main.async {
                withAnimation(.spring) { showContactPrompt = false }
                if ok { path.append(.contacts) }
            }
        }
    }
}

struct PlaceRow: View {
    var icon: String
    var name: String
    var subtitle: String
    var distance: Double?
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    GradientIconBadge(icon: icon, size: 40)
                    if let d = distance { Text(kmText(d)).font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(LightUI.blue) }
                }
                .frame(width: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 16, weight: .bold)).foregroundStyle(LightUI.text).lineLimit(1)
                    if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(LightUI.sub).lineLimit(1) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(LightUI.sub.opacity(0.6))
            }
            .padding(.vertical, 12).padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Contacts

struct ContactPermissionCard: View {
    var onDecline: () -> Void
    var onAccept: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onDecline)
            VStack(spacing: 16) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "book.closed.fill").font(.system(size: 54)).foregroundStyle(LightUI.blue.opacity(0.2))
                        .overlay(Image(systemName: "person.fill").font(.system(size: 22)).foregroundStyle(LightUI.blue))
                    Image(systemName: "mappin.circle.fill").font(.system(size: 28)).foregroundStyle(.white, LightUI.blue)
                        .offset(x: 12, y: 6)
                }
                .padding(.top, 8)
                Text("Contact access").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(LightUI.text)
                Text("Allowing DriveRadar to access your contacts lets you search for destinations by contact name. Your contacts are used only for these searches.")
                    .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(LightUI.sub)
                HStack(spacing: 12) {
                    Button(action: onDecline) {
                        Text("No, thanks").font(.headline).foregroundStyle(LightUI.blue)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .overlay(Capsule().stroke(LightUI.blue, lineWidth: 1.5))
                    }
                    Button(action: onAccept) {
                        Text("I'm interested").font(.headline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).frame(height: 48)
                            .background(LightUI.blue, in: Capsule())
                    }
                }
            }
            .padding(22)
            .glassPanel(radius: 28)
            .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
            .padding(.horizontal, 28)
        }
    }
}

struct ContactPlace: Identifiable {
    let id = UUID()
    let name: String
    let label: String
    let address: CNPostalAddress
    var formatted: String { CNPostalAddressFormatter.string(from: address, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ") }
}

struct ContactsListView: View {
    var onPick: (MKMapItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ContactPlace] = []
    @State private var loaded = false
    @State private var filter = ""
    @State private var geocoding: UUID?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)).foregroundStyle(LightUI.text).frame(width: 44, height: 44) }
                Text("My contacts").font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(LightUI.text)
                Spacer()
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(LightUI.sub)
                TextField("Search contacts", text: $filter).foregroundStyle(LightUI.text)
            }
            .padding(.horizontal, 16).frame(height: 46).background(LightUI.card, in: Capsule())
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(shown) { c in
                        PlaceRow(icon: geocoding == c.id ? "hourglass" : "person.crop.circle", name: c.name,
                                 subtitle: "\(c.label.isEmpty ? "" : c.label + " · ")\(c.formatted)", distance: nil) { geocode(c) }
                        Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5).padding(.leading, 70)
                    }
                    if !loaded { ShimmerRows() }
                    if loaded && items.isEmpty {
                        EmptyStateView(icon: "person.crop.circle.badge.questionmark", title: "No addresses", message: "None of your contacts have a postal address yet.")
                    }
                }
                .glassPanel(radius: 28)
            }
        }
        .padding(.horizontal, 16)
        .background(LightUI.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private var shown: [ContactPlace] {
        filter.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(filter) || $0.formatted.localizedCaseInsensitiveContains(filter) }
    }

    private func load() async {
        let list: [ContactPlace] = await Task.detached {
            let keys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                           CNContactPostalAddressesKey as CNKeyDescriptor]
            let req = CNContactFetchRequest(keysToFetch: keys)
            req.sortOrder = .givenName
            var out: [ContactPlace] = []
            try? CNContactStore().enumerateContacts(with: req) { c, _ in
                let name = CNContactFormatter.string(from: c, style: .fullName) ?? "Contact"
                for a in c.postalAddresses {
                    let label = a.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? ""
                    out.append(ContactPlace(name: name, label: label, address: a.value))
                }
            }
            return out
        }.value
        items = list
        loaded = true
    }

    private func geocode(_ c: ContactPlace) {
        geocoding = c.id
        error = nil
        CLGeocoder().geocodePostalAddress(c.address) { marks, _ in
            DispatchQueue.main.async {
                geocoding = nil
                guard let loc = marks?.first?.location else { error = "Couldn't find that address."; return }
                onPick(makeMapItem(loc.coordinate, name: c.name))
            }
        }
    }
}

// MARK: POI list (gas stations / hotels)

struct POIListView: View {
    var category: POICategory
    var onPick: (MKMapItem) -> Void
    @EnvironmentObject var engine: DriveEngine
    @Environment(\.dismiss) private var dismiss
    @State private var results: [PlaceResult] = []
    @State private var loading = true
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                UserAnnotation()
                ForEach(results) { r in
                    Annotation(r.item.name ?? "", coordinate: mapItemCoordinate(r.item)) {
                        Image(systemName: category.icon).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 30, height: 30).background(LightUI.blue, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2)).shadow(radius: 2)
                            .onTapGesture { onPick(r.item) }
                    }
                }
            }
            .mapControls { MapCompass() }
            .mapStyle(.standard(elevation: .flat, emphasis: .automatic, pointsOfInterest: .all, showsTraffic: false))
            .environment(\.colorScheme, AppTheme.scheme)
            .renderWhenSized()
            .ignoresSafeArea()

            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.headline).foregroundStyle(LightUI.text)
                        .frame(width: 44, height: 44).background(LightUI.card, in: Circle()).shadow(radius: 3)
                }
                Text(category.title).font(.headline).foregroundStyle(LightUI.text)
                    .padding(.horizontal, 16).frame(height: 44).background(LightUI.card, in: Capsule()).shadow(radius: 3)
                Spacer()
            }
            .padding(.horizontal, 16)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { sheet }
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.gray.opacity(0.35)).frame(width: 40, height: 5).padding(.vertical, 10)
            if loading {
                ShimmerRows(count: 4)
            } else if results.isEmpty {
                EmptyStateView(icon: category.icon, title: "Nothing nearby", message: "No \(category.title.lowercased()) found within 10 km.")
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { r in
                        Button { onPick(r.item) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: category.icon).font(.title3).foregroundStyle(LightUI.blue)
                                    .frame(width: 44, height: 44).background(LightUI.blue.opacity(0.1), in: Circle())
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text((r.item.name ?? "").uppercased()).font(.system(size: 15, weight: .bold)).foregroundStyle(LightUI.text).lineLimit(1)
                                        Spacer()
                                        Text(kmText(r.distance)).font(.system(size: 14, weight: .semibold).monospacedDigit()).foregroundStyle(LightUI.blue)
                                    }
                                    Text(address(r.item)).font(.subheadline).foregroundStyle(LightUI.sub).lineLimit(1)
                                }
                            }
                            .padding(.vertical, 10).padding(.horizontal, 16).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 72)
                    }
                }
            }
        }
        .frame(maxHeight: 360)
        .background(LightUI.card, in: UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: -3)
    }

    private func load() async {
        guard let here = engine.location?.coordinate else { loading = false; return }
        let req = MKLocalPointsOfInterestRequest(center: here, radius: 10_000)
        req.pointOfInterestFilter = MKPointOfInterestFilter(including: [category.mk])
        var items = (try? await MKLocalSearch(request: req).start())?.mapItems ?? []
        if items.isEmpty {
            let q = MKLocalSearch.Request()
            q.naturalLanguageQuery = category == .gas ? "gas station" : "hotel"
            q.pointOfInterestFilter = MKPointOfInterestFilter(including: [category.mk])
            q.region = MKCoordinateRegion(center: here, latitudinalMeters: 20_000, longitudinalMeters: 20_000)
            items = (try? await MKLocalSearch(request: q).start())?.mapItems ?? []
        }
        results = items.map { PlaceResult(item: $0, distance: Geo.distance(here, mapItemCoordinate($0))) }
            .sorted { $0.distance < $1.distance }
        loading = false
    }
}

// MARK: Route preview

struct RoutePreviewView: View {
    @State var destination: MKMapItem
    @EnvironmentObject var nav: NavigationEngine
    /// (first-leg option, first-leg target, remaining targets in order)
    var onStart: (RouteOption, MKMapItem, [MKMapItem]) -> Void
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var traps: TrapStore
    @State private var stops: [MKMapItem] = []
    @State private var extraLegs: [MKRoute] = []
    @Environment(\.dismiss) private var dismiss
    @State private var routes: [MKRoute] = []
    @State private var selected = 0
    @State private var loading = true
    @State private var errorText: String?
    @State private var avoidTolls = false
    @State private var avoidHighways = false
    @State private var showOptions = false
    @State private var showAddStop = false
    @State private var reversed = false
    @State private var favourite = false
    @State private var position: MapCameraPosition = .automatic

    @State private var resolvedName: String?
    @State private var showFavCard = false
    @State private var askCustomName = false
    @State private var customName = ""
    @State private var showRouteOptions = false
    @Environment(\.openURL) private var openURL
    private var destName: String { resolvedName ?? destination.name ?? "Destination" }

    private func pickRoute(near c: CLLocationCoordinate2D) {
        guard extraLegs.isEmpty, routes.count > 1 else { return }
        let scored = routes.indices.compactMap { i -> (Int, Double)? in
            Geo.project(c, onto: Geo.coordinates(of: routes[i].polyline)).map { (i, $0.distance) }
        }
        if let best = scored.min(by: { $0.1 < $1.1 }), best.1 < 400, best.0 != selected {
            withAnimation(.spring) { selected = best.0 }
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private var needsName: Bool {
        guard let n = destination.name, !n.isEmpty else { return true }
        if ["Dropped pin", "Starred place", "Destination", "Saved place", "Unknown Location", "Test destination"].contains(n) { return true }
        return n.range(of: #"^-?\d+(\.\d+)?\s*,\s*-?\d+(\.\d+)?$"#, options: .regularExpression) != nil
    }

    private func resolveName() {
        guard needsName else { return }
        let c = mapItemCoordinate(destination)
        CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: c.latitude, longitude: c.longitude)) { marks, _ in
            guard let p = marks?.first else { return }
            let street = [p.subThoroughfare, p.thoroughfare].compactMap { $0 }.joined(separator: " ")
            let name = p.areasOfInterest?.first ?? p.name ?? (street.isEmpty ? p.locality : street)
            DispatchQueue.main.async {
                if let name, !name.isEmpty { resolvedName = name; destination.name = name }
            }
        }
    }

    private func saveFavourite(name: String, icon: String) {
        let c = mapItemCoordinate(destination)
        if icon == "house.fill" || icon == "briefcase.fill" {
            traps.favourites.filter { $0.icon == icon }.forEach(traps.removeFavourite)
        }
        traps.favourites.filter { Geo.distance($0.coordinate, c) < 30 && $0.icon == "star.fill" }.forEach(traps.removeFavourite)
        traps.addFavourite(name: name, at: c, icon: icon)
        var f = UserDefaults.standard.stringArray(forKey: "dr.favPlaces") ?? []
        if !f.contains(favKey) { f.append(favKey) }
        UserDefaults.standard.set(f, forKey: "dr.favPlaces")
        withAnimation(.spring) { favourite = true; showFavCard = false }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func handOff(_ app: String) -> Bool {
        let c = mapItemCoordinate(destination)
        switch app {
        case "apple":
            destination.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            return true
        case "google":
            let app = URL(string: "comgooglemaps://?daddr=\(c.latitude),\(c.longitude)&directionsmode=driving")!
            let web = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(c.latitude),\(c.longitude)&travelmode=driving")!
            openURL(app) { ok in if !ok { openURL(web) } }
            return true
        default: return false
        }
    }
    private var region: String {
        let p = destination.placemark
        return [p.locality, p.administrativeArea].compactMap { $0 }.joined(separator: ", ")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            transportPicker
            fromTo
            ZStack(alignment: .topTrailing) {
                map
                Button { showOptions = true } label: {
                    Label("Route options", systemImage: "slider.horizontal.3").font(.subheadline.weight(.semibold))
                        .foregroundStyle(LightUI.blue).padding(.horizontal, 14).frame(height: 38)
                        .background(LightUI.card, in: Capsule()).shadow(radius: 3)
                }
                .padding(12)
            }
            details
        }
        .background(LightUI.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await calculate() }
        .onAppear {
            favourite = UserDefaults.standard.stringArray(forKey: "dr.favPlaces")?.contains(favKey) ?? false
            avoidTolls = !RoutePrefs.allowTolls; avoidHighways = !RoutePrefs.allowMotorways
            resolveName()
        }
        .onChange(of: showOptions) { _, v in if v { showOptions = false; showRouteOptions = true } }
        .sheet(isPresented: $showRouteOptions) {
            RouteOptionsScreen {
                avoidTolls = !RoutePrefs.allowTolls; avoidHighways = !RoutePrefs.allowMotorways
                Task { await calculate() }
            }
        }
        .overlay {
            if showFavCard {
                AddFavouriteCard(onCustom: { customName = destName; askCustomName = true },
                                 onHome: { saveFavourite(name: "Home", icon: "house.fill") },
                                 onWork: { saveFavourite(name: "Work", icon: "briefcase.fill") },
                                 onClose: { withAnimation(.spring) { showFavCard = false } })
            }
        }
        .alert("Name this favourite", isPresented: $askCustomName) {
            TextField("Name", text: $customName)
            Button("Save") { saveFavourite(name: customName.trimmingCharacters(in: .whitespaces).isEmpty ? destName : customName, icon: "star.fill") }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showAddStop) {
            StopPickerView { item in
                showAddStop = false
                withAnimation(.spring) { stops.append(item) }
                Task { await calculate() }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var favKey: String { let c = mapItemCoordinate(destination); return String(format: "%.5f,%.5f", c.latitude, c.longitude) }

    private var header: some View {
        HStack {
            Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)).foregroundStyle(LightUI.text).frame(width: 44, height: 44) }
            VStack(alignment: .leading, spacing: 1) {
                Text(destName).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(LightUI.text).lineLimit(1)
                if !region.isEmpty { Text(region).font(.caption).foregroundStyle(LightUI.sub) }
            }
            Spacer()
            Button {
                if !favourite { withAnimation(.spring) { showFavCard = true }; return }
                favourite.toggle()
                var f = UserDefaults.standard.stringArray(forKey: "dr.favPlaces") ?? []
                if favourite { f.append(favKey) } else { f.removeAll { $0 == favKey } }
                UserDefaults.standard.set(f, forKey: "dr.favPlaces")
                let c = mapItemCoordinate(destination)
                if favourite {
                    if !traps.favourites.contains(where: { Geo.distance($0.coordinate, c) < 30 }) { traps.addFavourite(name: destName, at: c) }
                } else {
                    traps.favourites.filter { Geo.distance($0.coordinate, c) < 30 }.forEach(traps.removeFavourite)
                }
            } label: {
                Image(systemName: favourite ? "star.fill" : "star").font(.title3).foregroundStyle(favourite ? .yellow : LightUI.text)
                    .frame(width: 44, height: 44).symbolEffect(.bounce, value: favourite)
            }
        }
        .padding(.horizontal, 8).padding(.top, 4)
    }


    private var transportPicker: some View {
        HStack(spacing: 8) {
            transportButton(title: "Drive", icon: "car.fill", mode: .automobile)
            transportButton(title: "Walk", icon: "figure.walk", mode: .walking)
        }
        .padding(5)
        .background(LightUI.card, in: Capsule())
        .overlay(Capsule().stroke(Color.black.opacity(0.12), lineWidth: 1))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Travel mode")
    }

    private func transportButton(title: String, icon: String, mode: MKDirectionsTransportType) -> some View {
        let selected = nav.transport == mode
        return Button {
            guard nav.transport != mode else { return }
            nav.transport = mode
            Task { await calculate() }
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(selected ? .white : LightUI.text)
                .frame(maxWidth: .infinity).frame(height: 42)
                .background(selected ? LightUI.blue : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fromTo: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                Circle().stroke(LightUI.blue, lineWidth: 3).frame(width: 12, height: 12)
                ForEach(0..<3) { _ in Circle().fill(LightUI.sub.opacity(0.4)).frame(width: 3, height: 3) }
                Image(systemName: "mappin").foregroundStyle(.red).font(.system(size: 14, weight: .bold))
            }
            VStack(alignment: .leading, spacing: 0) {
                field("From", reversed ? destName : "My location")
                Divider()
                ForEach(Array(stops.enumerated()), id: \.offset) { i, s in
                    Divider()
                    HStack {
                        Text("Stop \(i + 1)").font(.caption).foregroundStyle(LightUI.sub).frame(width: 40, alignment: .leading)
                        Text(s.name ?? "Stop").font(.system(size: 15, weight: .semibold)).foregroundStyle(LightUI.text).lineLimit(1)
                        Spacer()
                        Button {
                            withAnimation(.spring) { _ = stops.remove(at: i) }
                            Task { await calculate() }
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                        .accessibilityLabel("Remove stop \(i + 1)")
                    }
                    .frame(height: 38)
                }
                Divider()
                field("To", reversed ? "My location" : destName)
            }
            Button {
                withAnimation(.spring) { reversed.toggle() }
                Task { await calculate() }
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.headline).foregroundStyle(LightUI.blue)
                    .frame(width: 40, height: 40).background(LightUI.blue.opacity(0.1), in: Circle())
            }
        }
        .padding(14)
        .glassPanel(radius: 28)
        .padding(.horizontal, 16).padding(.bottom, 10)
    }

    private func field(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(LightUI.sub).frame(width: 40, alignment: .leading)
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(LightUI.text).lineLimit(1)
            Spacer()
        }
        .frame(height: 38)
    }

    private var map: some View {
        MapReader { proxy in
        Map(position: $position) {
            UserAnnotation()
            ForEach(Array(extraLegs.enumerated()), id: \.offset) { _, r in
                MapPolyline(r.polyline).stroke(Color.white, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                MapPolyline(r.polyline).stroke(LightUI.blue, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(stops.enumerated()), id: \.offset) { i, s in
                Annotation("", coordinate: mapItemCoordinate(s)) {
                    Text("S\(i + 1)").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 30, height: 30).background(LightUI.orange, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            ForEach(Array(routes.enumerated()).reversed(), id: \.offset) { i, r in
                if i == selected {
                    MapPolyline(r.polyline).stroke(Color.white, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                    MapPolyline(r.polyline).stroke(LightUI.blue, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                } else {
                    MapPolyline(r.polyline).stroke(Color.gray.opacity(0.75), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
            }
            if let r = current, let step = r.steps.dropFirst().first(where: { !$0.instructions.isEmpty }),
               let c = Geo.coordinates(of: step.polyline).first {
                Annotation("", coordinate: c) {
                    Text("1").font(.system(size: 13, weight: .heavy)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(LightUI.blue, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            if let end = endCoordinate {
                Annotation("", coordinate: end, anchor: .bottomLeading) {
                    Image(systemName: "flag.checkered").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.ink)
                        .padding(4).glassPanel(radius: 28).shadow(radius: 2)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .automatic, pointsOfInterest: .all, showsTraffic: true))
        .environment(\.colorScheme, AppTheme.scheme)
        .onTapGesture { pt in if let c = proxy.convert(pt, from: .local) { pickRoute(near: c) } }
        }
        .renderWhenSized()
        .overlay { if loading { CalculatingRouteCard() } }
    }

    private var current: MKRoute? { routes.indices.contains(selected) ? routes[selected] : nil }
    private var endCoordinate: CLLocationCoordinate2D? {
        (extraLegs.last ?? current).flatMap { Geo.coordinates(of: $0.polyline).last }
    }

    private var details: some View {
        VStack(spacing: 0) {
            if routes.count > 0 {
                HStack(spacing: 0) {
                    ForEach(routes.indices, id: \.self) { i in
                        let isSel = i == selected
                        let delta = Int(((routes[i].expectedTravelTime - routes[0].expectedTravelTime) / 60).rounded())
                        Button { withAnimation(.spring) { selected = i } } label: {
                            VStack(spacing: 6) {
                                Rectangle().fill(isSel ? LightUI.green : .clear).frame(height: 4)
                                Text(i == 0 ? durationText(routes[i].expectedTravelTime) : (delta > 0 ? "+" + durationText(Double(delta * 60)) : durationText(routes[i].expectedTravelTime)))
                                    .font(.system(size: 18, weight: .bold).monospacedDigit())
                                    .foregroundStyle(i == 0 ? (isSel ? LightUI.green : LightUI.text) : LightUI.orange)
                                    .padding(.bottom, 8)
                            }
                            .frame(maxWidth: .infinity)
                            .background(isSel ? LightUI.card : LightUI.bg)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let r = current {
                VStack(alignment: .leading, spacing: 8) {
                    let totalT = r.expectedTravelTime + extraLegs.reduce(0) { $0 + $1.expectedTravelTime }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(durationText(totalT)).font(Typo.number(26, .bold)).foregroundStyle(Theme.ink)
                            .contentTransition(.numericText())
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        InfoChip(icon: "flag.checkered", text: Date().addingTimeInterval(totalT).formatted(date: .omitted, time: .shortened), tint: Theme.good)
                        InfoChip(icon: "point.topleft.down.to.point.bottomright.curvepath.fill", text: kmText(r.distance + extraLegs.reduce(0) { $0 + $1.distance }))
                        if !stops.isEmpty { InfoChip(icon: "mappin.and.ellipse", text: "\(stops.count) stop\(stops.count == 1 ? "" : "s")", tint: Theme.amber) }
                    }
                    if !r.name.isEmpty { Text("Via \(r.name)").font(.subheadline.weight(.semibold)).foregroundStyle(LightUI.text) }
                    HStack(spacing: 14) {
                        Label(nav.transport == .walking ? "Walking route" : delayText(r), systemImage: nav.transport == .walking ? "figure.walk" : "clock")
                            .foregroundStyle(LightUI.green)
                        if nav.transport == .automobile {
                            Label("Speed camera density \(density(r))", systemImage: "camera.fill").foregroundStyle(LightUI.sub)
                        }
                    }
                    .font(.footnote.weight(.medium))
                }
                .padding(16)
            } else if let e = errorText {
                Label(e, systemImage: e.contains("GPS") ? "location.slash.fill" : "exclamationmark.triangle.fill")
                    .font(Typo.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(16)
            }
            HStack(spacing: 12) {
                Button { Haptics.tap(); showAddStop = true } label: {
                    Label("Add stop", systemImage: "plus")
                }
                .buttonStyle(SecondaryCapsuleStyle(tint: reversed ? .gray : Theme.accent))
                Button {
                    guard let r = current else { return }
                    let h = engine.hazardCount(along: Geo.coordinates(of: r.polyline))
                    if stops.isEmpty, nav.transport == .automobile, handOff(RoutePrefs.navApp) { return }
                    let targets = stops + [destination]
                    onStart(RouteOption(route: r, hazards: h, label: ""), targets[0], Array(targets.dropFirst()))
                    Haptics.success()
                } label: {
                    Label("Start", systemImage: "location.fill")
                }
                .buttonStyle(PrimaryCapsuleStyle(enabled: !(current == nil || reversed)))
                .disabled(current == nil || reversed)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .background(LightUI.card)
    }

    private func delayText(_ r: MKRoute) -> String {
        let typical = r.distance / max(r.expectedTravelTime, 1)
        _ = typical
        return r.advisoryNotices.isEmpty ? "No delays" : "Advisories on route"
    }

    private func density(_ r: MKRoute) -> String {
        let n = engine.hazardCount(along: Geo.coordinates(of: r.polyline))
        let perKm = Double(n) / max(r.distance / 1000, 0.5)
        return perKm < 0.15 ? "low" : (perKm < 0.5 ? "med" : "high")
    }

    @MainActor
    private func calculate() async {
        guard let here = engine.routingLocation?.coordinate else { loading = false; errorText = "Waiting for GPS…"; return }
        loading = true
        errorText = nil
        let req = MKDirections.Request()
        let me = makeMapItem(here, name: "My location")
        req.source = reversed ? destination : me
        req.destination = reversed ? me : destination
        req.transportType = nav.transport
        req.requestsAlternateRoutes = true
        if nav.transport == .automobile { req.departureDate = Date() }
        req.tollPreference = avoidTolls ? .avoid : .any
        req.highwayPreference = avoidHighways ? .avoid : .any
        if !stops.isEmpty && !reversed {
            // Multi-stop: route each leg sequentially (here -> S1 -> S2 ... -> destination).
            var legs: [MKRoute] = []
            var from = me
            for target in stops + [destination] {
                let r = MKDirections.Request()
                r.source = from; r.destination = target
                r.transportType = nav.transport; if nav.transport == .automobile { r.departureDate = Date() }
                r.tollPreference = req.tollPreference; r.highwayPreference = req.highwayPreference
                guard let leg = try? await MKDirections(request: r).calculate().routes.first else {
                    routes = []; extraLegs = []; errorText = "Couldn't route to \(target.name ?? "a stop")."; loading = false; return
                }
                legs.append(leg)
                from = target
            }
            routes = [legs[0]]
            extraLegs = Array(legs.dropFirst())
            selected = 0
            let rect = legs.dropFirst().reduce(legs[0].polyline.boundingMapRect) { $0.union($1.polyline.boundingMapRect) }
            position = .rect(rect.insetBy(dx: -rect.width * 0.2, dy: -rect.height * 0.25))
            loading = false
            return
        }
        extraLegs = []
        do {
            let resp = try await MKDirections(request: req).calculate()
            routes = Array(resp.routes.sorted { $0.expectedTravelTime < $1.expectedTravelTime }.prefix(2))
            selected = 0
            if let r = routes.first {
                let rect = r.polyline.boundingMapRect
                position = .rect(rect.insetBy(dx: -rect.width * 0.2, dy: -rect.height * 0.25))
            }
        } catch {
            routes = []
            errorText = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - Favourites (old saved places + route-preview stars)

struct FavouritesListView: View {
    var onPick: (MKMapItem) -> Void
    @EnvironmentObject var traps: TrapStore
    @EnvironmentObject var engine: DriveEngine
    @Environment(\.dismiss) private var dismiss

    private var legacyStars: [CLLocationCoordinate2D] {
        (UserDefaults.standard.stringArray(forKey: "dr.favPlaces") ?? []).compactMap { k in
            let p = k.split(separator: ",").compactMap { Double($0) }
            guard p.count == 2 else { return nil }
            let c = CLLocationCoordinate2D(latitude: p[0], longitude: p[1])
            return traps.favourites.contains { Geo.distance($0.coordinate, c) < 30 } ? nil : c
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title3.weight(.semibold)).foregroundStyle(LightUI.text).frame(width: 44, height: 44) }
                Text("Favourites").font(.system(size: 19, weight: .bold, design: .rounded)).foregroundStyle(LightUI.text)
                Spacer()
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let p = traps.parking {
                        PlaceRow(icon: "car.fill", name: "My car", subtitle: "Parked spot", distance: dist(p.coordinate)) { onPick(makeMapItem(p.coordinate, name: "My car")) }
                        Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5).padding(.leading, 70)
                    }
                    ForEach(traps.favourites.sorted { rank($0) < rank($1) }) { f in
                        PlaceRow(icon: f.icon, name: f.name, subtitle: "Saved place", distance: dist(f.coordinate)) { onPick(makeMapItem(f.coordinate, name: f.name)) }
                            .contextMenu { Button("Remove", role: .destructive) { traps.removeFavourite(f) } }
                        Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5).padding(.leading, 70)
                    }
                    ForEach(Array(legacyStars.enumerated()), id: \.offset) { _, c in
                        PlaceRow(icon: "star.fill", name: "Starred place", subtitle: String(format: "%.4f, %.4f", c.latitude, c.longitude), distance: dist(c)) { onPick(makeMapItem(c, name: "Starred place")) }
                        Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5).padding(.leading, 70)
                    }
                    if traps.favourites.isEmpty && legacyStars.isEmpty && traps.parking == nil {
                        EmptyStateView(icon: "star", title: "No favourites yet", message: "Tap the star on a route preview, or long-press the map, to save a favourite.")
                    }
                }
                .glassPanel(radius: 28)
            }
        }
        .padding(.horizontal, 16)
        .background(LightUI.bg.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func dist(_ c: CLLocationCoordinate2D) -> Double? { engine.location.map { Geo.distance($0.coordinate, c) } }
    private func rank(_ f: FavouritePlace) -> Int { f.icon == "house.fill" ? 0 : f.icon == "briefcase.fill" ? 1 : 2 }
}

// MARK: - XP, levels, achievements (computed locally from trip data)

struct XPLevel { let name: String; let min: Int; let icon: String }

enum RadarXP {
    static let levels = [XPLevel(name: "Rookie", min: 0, icon: "car.fill"),
                         XPLevel(name: "Explorer", min: 500, icon: "map.fill"),
                         XPLevel(name: "Intermediate", min: 2000, icon: "steeringwheel"),
                         XPLevel(name: "Expert", min: 5000, icon: "crown.fill")]

    static func isClean(_ t: TripRecord) -> Bool { t.distance >= 1000 && t.speedingSeconds < 5 }

    /// 1 pt per km, +20 per clean trip (≥1 km, no speeding), +10 per trip scoring 90+.
    static func points(_ trips: [TripRecord]) -> Int {
        UserDefaults.standard.integer(forKey: "dr.xpBonus") + trips.reduce(0) { acc, t in
            acc + Int(t.distance / 1000) + (isClean(t) ? 20 : 0) + (t.score >= 90 && t.distance >= 1000 ? 10 : 0)
        }
    }
    static func level(for p: Int) -> (current: XPLevel, next: XPLevel?) {
        let i = levels.lastIndex { p >= $0.min } ?? 0
        return (levels[i], i + 1 < levels.count ? levels[i + 1] : nil)
    }
    static func totalKm(_ trips: [TripRecord]) -> Double { trips.reduce(0) { $0 + $1.distance } / 1000 }
}

struct Achievement: Identifiable {
    let id: String; let title: String; let detail: String; let icon: String; let progress: Double
    var done: Bool { progress >= 1 }
}

func achievements(_ trips: [TripRecord]) -> [Achievement] {
    let km = RadarXP.totalKm(trips)
    let clean = trips.filter(RadarXP.isClean).count
    let best = trips.map(\.score).max() ?? 0
    let longest = (trips.map(\.distance).max() ?? 0) / 1000
    func a(_ id: String, _ t: String, _ d: String, _ i: String, _ v: Double, _ goal: Double) -> Achievement {
        Achievement(id: id, title: t, detail: d, icon: i, progress: min(v / goal, 1))
    }
    return [
        a("first", "First drive", "Record your first trip", "flag.fill", Double(trips.count), 1),
        a("ten", "Regular", "Record 10 trips", "repeat", Double(trips.count), 10),
        a("fifty", "Road warrior", "Record 50 trips", "road.lanes", Double(trips.count), 50),
        a("100km", "Century", "Drive 100 km in total", "gauge.with.dots.needle.50percent", km, 100),
        a("1000km", "Long haul", "Drive 1,000 km in total", "globe.americas.fill", km, 1000),
        a("clean5", "Smooth operator", "5 trips with no speeding", "checkmark.seal.fill", Double(clean), 5),
        a("clean10", "Model driver", "10 trips with no speeding", "rosette", Double(clean), 10),
        a("score90", "Top marks", "Score 90 or more on a trip", "star.circle.fill", Double(best), 90),
        a("road100", "Road trip", "A single trip of 100 km", "car.side.fill", longest, 100),
    ]
}

struct AchievementsView: View {
    @EnvironmentObject var trips: TripRecorder
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(achievements(trips.trips)) { a in
                HStack(spacing: 14) {
                    Image(systemName: a.icon).font(.title3).foregroundStyle(a.done ? .white : LightUI.sub)
                        .frame(width: 44, height: 44)
                        .background(a.done ? AnyShapeStyle(LinearGradient(colors: [LightUI.blue, Color(hex: 0x7B61FF)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(LightUI.bg), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.title).font(.headline).foregroundStyle(LightUI.text)
                        Text(a.detail).font(.caption).foregroundStyle(LightUI.sub)
                        if !a.done { ProgressView(value: a.progress).tint(LightUI.blue) }
                    }
                    Spacer()
                    if a.done { Image(systemName: "checkmark.circle.fill").foregroundStyle(LightUI.green) }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Achievements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(AppTheme.scheme)
    }
}

struct ProfileView: View {
    @EnvironmentObject var trips: TripRecorder
    @EnvironmentObject var traps: TrapStore
    @State private var confirmReset = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dr.profileName") private var name = "Driver"
    @State private var editing = false
    @State private var draft = ""
    @State private var showAchievements = false

    var body: some View {
        let pts = RadarXP.points(trips.trips)
        let lv = RadarXP.level(for: pts)
        let progress = lv.next.map { Double(pts - lv.current.min) / Double($0.min - lv.current.min) } ?? 1
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ZStack {
                        AvatarView(size: 96, fallbackIcon: lv.current.icon)
                            .shadow(color: LightUI.blue.opacity(0.4), radius: 12)
                    }
                    .padding(.top, 12)
                    Text(name).font(.title2.bold()).foregroundStyle(LightUI.text)
                    Text("User active since \(Referral.firstLaunch.formatted(date: .long, time: .omitted))").font(.caption).foregroundStyle(LightUI.sub)
                    HStack(spacing: 6) {
                        Text(lv.current.name).font(.headline).foregroundStyle(LightUI.blue)
                        Text("· \(pts) pts").font(.headline.monospacedDigit()).foregroundStyle(LightUI.sub)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: min(max(progress, 0), 1)).tint(LightUI.blue).scaleEffect(y: 2)
                        Text(lv.next.map { "\($0.min - pts) pts to \($0.name)" } ?? "Top level reached")
                            .font(.caption).foregroundStyle(LightUI.sub)
                    }
                    .padding(16).glassPanel(radius: 28)
                    HStack(spacing: 14) {
                        Image(systemName: "car.fill").font(.title2).foregroundStyle(LightUI.blue)
                            .frame(width: 50, height: 50).background(LightUI.blue.opacity(0.1), in: Circle())
                        VStack(alignment: .leading) {
                            Text("Distance traveled").font(.subheadline).foregroundStyle(LightUI.sub)
                            Text("\(Int(RadarXP.totalKm(trips.trips).rounded())) km").font(.title2.bold().monospacedDigit()).foregroundStyle(LightUI.text)
                        }
                        Spacer()
                    }
                    .padding(16).glassPanel(radius: 28)
                    VStack(spacing: 0) {
                        row("Achievements", "trophy.fill") { showAchievements = true }
                        Divider().padding(.leading, 52)
                        row("Edit profile", "pencil") { editing = true }
                    }
                    .glassPanel(radius: 28)
                    VStack(spacing: 0) {
                        row("Reset profile", "arrow.counterclockwise") { confirmReset = true }
                        Divider().padding(.leading, 52)
                        Button { confirmDelete = true } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "trash").foregroundStyle(.red).frame(width: 24)
                                Text("Delete all my data").foregroundStyle(.red)
                                Spacer()
                            }
                            .padding(16).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .glassPanel(radius: 28)
                    Text("Earn 1 point per km, plus bonuses for trips without speeding. Points are stored on this iPhone only.")
                        .font(.caption).foregroundStyle(LightUI.sub).multilineTextAlignment(.center)
                }
                .padding(16)
            }
            .background(LightUI.bg.ignoresSafeArea())
            .navigationTitle("DriveRadar XP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $editing) { EditProfileView() }
            .confirmationDialog("Reset profile?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset profile", role: .destructive) { LocalData.resetProfile() }
            } message: { Text("Your name and photo go back to the defaults. Trips and points are kept.") }
            .confirmationDialog("Delete all my data?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) { LocalData.deleteAll(trips: trips, traps: traps); dismiss() }
            } message: { Text("This permanently removes your trips, points, achievements, recents, favourites and profile from this iPhone. It can't be undone.") }
            .sheet(isPresented: $showAchievements) { AchievementsView() }
        }
        .preferredColorScheme(AppTheme.scheme)
    }

    private func row(_ t: String, _ i: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: i).foregroundStyle(LightUI.blue).frame(width: 24)
                Text(t).foregroundStyle(LightUI.text)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(LightUI.sub.opacity(0.6))
            }
            .padding(16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct XPWelcomeCard: View {
    var onAccept: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [LightUI.blue, Color(hex: 0x7B61FF)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 84, height: 84)
                    Image(systemName: "trophy.fill").font(.system(size: 36)).foregroundStyle(.white)
                }
                Text("Start your adventure in DriveRadar XP!").font(.system(size: 21, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center).foregroundStyle(LightUI.text)
                Text("Every kilometre you drive earns points. Drive without speeding for bonus points, unlock achievements and level up from Rookie to Expert.")
                    .font(.subheadline).multilineTextAlignment(.center).foregroundStyle(LightUI.sub)
                Button(action: onAccept) {
                    Text("Accept").font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 50).background(LightUI.blue, in: Capsule())
                }
            }
            .padding(24)
            .glassPanel(radius: 28)
            .padding(.horizontal, 28)
            .shadow(radius: 24)
        }
        .environment(\.colorScheme, AppTheme.scheme)
    }
}

// MARK: - Invite friends

struct ActivityShare: UIViewControllerRepresentable {
    let items: [Any]
    var completion: (Bool) -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, done, _, _ in completion(done) }
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct InviteFriendsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false
    @State private var thanks = false
    @AppStorage("dr.invitesSent") private var invitesSent = 0
    @State private var copied = false
    private var message: String {
        "I'm using DriveRadar for turn-by-turn navigation with speed limit and camera alerts. Join me with my code \(Referral.code): \(Referral.webLink.absoluteString) (or open \(Referral.appLink.absoluteString) if you already have the app)."
    }

    var body: some View {
        ZStack {
            VStack(spacing: 22) {
                HStack {
                    Text("Invite friends").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(LightUI.text)
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).foregroundStyle(LightUI.text).frame(width: 44, height: 44) }
                }
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "person.3.fill").font(.system(size: 64)).foregroundStyle(LightUI.blue)
                    Image(systemName: "plus.circle.fill").font(.system(size: 30)).foregroundStyle(.white, LightUI.green).offset(x: 10, y: 8)
                }
                .padding(.vertical, 10)
                section("square.and.arrow.up", "Share DriveRadar", "Send your friends a link by message, mail or any app you like.")
                section("person.2.wave.2.fill", "Your friends are joining", "The more drivers who use DriveRadar, the more speed traps get reported for everyone.")
                Text("The more, the merrier!").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(LightUI.text)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your referral code").font(.caption).foregroundStyle(LightUI.sub)
                        Text(Referral.code).font(.system(size: 22, weight: .heavy, design: .monospaced)).foregroundStyle(LightUI.text)
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = Referral.webLink.absoluteString
                        withAnimation(.spring) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { copied = false } }
                    } label: {
                        Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(LightUI.blue)
                            .padding(.horizontal, 14).frame(height: 38).overlay(Capsule().stroke(LightUI.blue))
                    }
                }
                .padding(16).glassPanel(radius: 28)
                Text("Invites sent: \(invitesSent)").font(.subheadline.monospacedDigit()).foregroundStyle(LightUI.sub)
                Spacer()
                Button { sharing = true } label: {
                    Text("Invite your friends").font(.headline).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 54).background(LightUI.blue, in: Capsule())
                }
            }
            .padding(20)
            .background(LightUI.bg.ignoresSafeArea())
            if thanks {
                ZStack {
                    Color.black.opacity(0.4).ignoresSafeArea()
                    VStack(spacing: 14) {
                        Image(systemName: "heart.circle.fill").font(.system(size: 54)).foregroundStyle(.white, LightUI.green)
                        Text("Thanks for sharing!").font(.title3.bold()).foregroundStyle(LightUI.text)
                        Text("Every new driver makes DriveRadar better for everyone on the road.").font(.subheadline)
                            .multilineTextAlignment(.center).foregroundStyle(LightUI.sub)
                        Button { withAnimation(.spring) { thanks = false } } label: {
                            Text("Understood").font(.headline).foregroundStyle(.white)
                                .frame(maxWidth: .infinity).frame(height: 48).background(LightUI.blue, in: Capsule())
                        }
                    }
                    .padding(22).glassPanel(radius: 28).padding(.horizontal, 32)
                }
                .transition(.opacity)
            }
        }
        .sheet(isPresented: $sharing) {
            ActivityShare(items: [message]) { done in
                sharing = false
                if done { invitesSent += 1 }
                if done { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { withAnimation(.spring) { thanks = true } } }
            }
            .presentationDetents([.medium, .large])
        }
        .preferredColorScheme(AppTheme.scheme)
    }

    private func section(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(LightUI.blue)
                .frame(width: 44, height: 44).background(LightUI.blue.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).foregroundStyle(LightUI.text)
                Text(text).font(.subheadline).foregroundStyle(LightUI.sub)
            }
            Spacer(minLength: 0)
        }
        .padding(16).glassPanel(radius: 28)
    }
}

// MARK: - Traffic cameras list

struct TrafficCamerasView: View {
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var ds: DriveSettings
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let here = engine.location?.coordinate
        let cams = engine.osm.allHazards.filter { $0.kind == .camera || $0.kind == .avgSpeed || $0.kind == .redLight }
            .map { h in (h, here.map { Geo.distance($0, h.coordinate) } ?? 0) }
            .sorted { $0.1 < $1.1 }.prefix(100)
        NavigationStack {
            List(Array(cams), id: \.0.id) { h, d in
                HStack {
                    Image(systemName: h.kind == .redLight ? "light.beacon.max.fill" : "camera.fill").foregroundStyle(LightUI.blue).frame(width: 28)
                    VStack(alignment: .leading) {
                        Text(h.kind == .camera ? "Speed camera" : h.kind == .avgSpeed ? "Average-speed camera" : "Red-light camera").font(.headline)
                        if let m = h.maxspeed { Text("Limit \(ds.speedUnits.limit(m).value)").font(.caption).foregroundStyle(LightUI.sub) }
                    }
                    Spacer()
                    Text(kmText(d)).font(.subheadline.monospacedDigit()).foregroundStyle(LightUI.blue)
                }
            }
            .overlay { if cams.isEmpty { ContentUnavailableView("No cameras loaded", systemImage: "camera", description: Text("Use Update speed cameras in the menu.")) } }
            .navigationTitle("Traffic cameras").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(AppTheme.scheme)
    }
}

// MARK: - Side menu

enum SideMenuAction { case profile, settings, invite, cameras, achievements, help }

struct SideMenu: View {
    @Binding var isOpen: Bool
    var onSelect: (SideMenuAction) -> Void
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var trips: TripRecorder
    @AppStorage("dr.profileName") private var name = "Driver"
    @AppStorage("dr.sleepMode") private var sleepMode = true
    @State private var updating = false
    @State private var updateResult: Bool?

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear
            if isOpen {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
                panel
                    .transition(.move(edge: .leading))
            }
        }
        .overlay {
            if updating {
                CenterCard {
                    ProgressView().controlSize(.large).tint(LightUI.blue)
                    Text("Updating speed cameras...").font(.headline).foregroundStyle(LightUI.text)
                }
            } else if let ok = updateResult {
                CenterCard {
                    Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 54)).foregroundStyle(ok ? LightUI.green : LightUI.orange)
                    Text(ok ? "Speed cameras up to date" : "Couldn't update speed cameras").font(.headline)
                        .multilineTextAlignment(.center).foregroundStyle(LightUI.text)
                    if !ok { Text("Check your connection and try again. Cached data is still used.").font(.subheadline).multilineTextAlignment(.center).foregroundStyle(LightUI.sub) }
                    Button { withAnimation(.spring) { updateResult = nil } } label: {
                        Text("OK").font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 48).background(LightUI.blue, in: Capsule())
                    }
                }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.88), value: isOpen)
        .animation(.spring, value: updating)
        .animation(.spring, value: updateResult)
    }

    private var panel: some View {
        let lv = RadarXP.level(for: RadarXP.points(trips.trips))
        return VStack(alignment: .leading, spacing: 0) {
            Button { pick(.profile) } label: {
                HStack(spacing: 14) {
                    AvatarView(size: 58, fallbackIcon: lv.current.icon)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DRIVERADAR").font(.system(size: 13, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(LightUI.blue)
                        Text(name).font(.title3.bold()).foregroundStyle(LightUI.text)
                        Text(lv.current.name).font(.caption).foregroundStyle(LightUI.sub)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 18)
            }
            .buttonStyle(.plain)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    row("gearshape.fill", "Settings") { pick(.settings) }
                    row("arrow.triangle.2.circlepath.camera.fill", "Update speed cameras", subtitle: updateText) { updateCameras() }
                    row("person.2.fill", "Invite your friends") { pick(.invite) }
                    row("camera.fill", "Traffic cameras") { pick(.cameras) }
                    row("trophy.fill", "Achievements") { pick(.achievements) }
                    row("questionmark.circle.fill", "Help & feedback") { pick(.help) }
                    HStack(spacing: 16) {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(LightUI.blue).frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sleep mode").foregroundStyle(LightUI.text)
                            Text(sleepMode ? "Screen can turn off" : "Screen stays on").font(.caption).foregroundStyle(LightUI.sub)
                        }
                        Spacer()
                        Toggle("", isOn: $sleepMode).labelsHidden().tint(LightUI.blue)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
            }
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 12) {
                ShareLink(item: "I'm using DriveRadar for navigation with speed limit and camera alerts. Give it a try!") {
                    Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                Button { pick(.invite) } label: { Label("Rate", systemImage: "star.fill").frame(maxWidth: .infinity) }
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(LightUI.blue)
            .padding(16).padding(.bottom, 64)
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(LightUI.card.ignoresSafeArea())
        .environment(\.colorScheme, AppTheme.scheme)
        .onChange(of: sleepMode) { _, s in UIApplication.shared.isIdleTimerDisabled = !s }
    }

    private var updateText: String {
        if updating { return "Updating…" }
        guard let d = engine.osm.hazardFetched else { return "Not updated yet" }
        return "Last update \(d.formatted(date: .abbreviated, time: .shortened))"
    }

    private func updateCameras() {
        guard !updating else { return }
        guard let c = engine.location?.coordinate else { updateResult = false; return }
        updating = true
        engine.osm.refreshHazards(around: c) { ok in DispatchQueue.main.async { updating = false; updateResult = ok } }
    }

    private func close() { isOpen = false }
    private func pick(_ a: SideMenuAction) { isOpen = false; onSelect(a) }

    private func row(_ icon: String, _ title: String, subtitle: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon).foregroundStyle(LightUI.blue).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(LightUI.text)
                    if let s = subtitle { Text(s).font(.caption).foregroundStyle(LightUI.sub) }
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.vertical, 14).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Light navigation overlay (Drive screen, Map style = Light)

struct LightNavOverlay: View {
    var onMenu: () -> Void
    var onAddStop: () -> Void
    var onMore: () -> Void
    var onRouteOptions: () -> Void = {}
    var onEnd: () -> Void
    @EnvironmentObject var nav: NavigationEngine
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var ds: DriveSettings

    var body: some View {
        VStack(spacing: 10) {
            if let n = nav.next, let d = nav.distanceToNext {
                HStack(spacing: 14) {
                    VStack(spacing: 4) {
                        Image(systemName: n.kind.symbol).font(.system(size: 38, weight: .heavy)).foregroundStyle(Theme.accent)
                            .shadow(color: Theme.accent.opacity(0.6), radius: 8)
                            .contentTransition(.symbolEffect(.replace))
                        Text(ds.speedUnits.distance(d)).font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                            .contentTransition(.numericText())
                    }
                    .frame(width: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(n.kind.shortText).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                        Text(street(n.instruction)).font(.system(size: 17, weight: .medium, design: .rounded)).foregroundStyle(Theme.inkSecondary).lineLimit(2)
                        if let lanes = engine.lanes, d < 800, lanes.count > 1,
                           ![TurnKind.straight, .depart].contains(n.kind) {
                            LanesView(lanes: lanes, kind: n.kind, size: 16)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .glassPanel(radius: 28)
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .id(n.index)
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: n.index)
            } else if nav.offRoute {
                Text("Rerouting…").font(.headline).foregroundStyle(LightUI.text).padding(16).frame(maxWidth: .infinity)
                    .glassPanel(radius: 28)
            }
            Spacer()
            HStack(alignment: .bottom) {
                VStack(spacing: 8) {
                    lightLimit
                    VStack(spacing: -2) {
                        Text(ds.speedUnits.speed(engine.speed).value).font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(engine.isSpeeding ? .red : LightUI.text).contentTransition(.numericText())
                        Text(ds.speedUnits.speed(engine.speed).unit).font(.caption2.bold()).foregroundStyle(LightUI.sub)
                    }
                    .frame(width: 78, height: 78)
                    .background(LightUI.card, in: Circle())
                    .overlay(Circle().stroke(engine.isSpeeding ? Color.red : .clear, lineWidth: 3))
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                }
                Spacer()
                VStack(spacing: 12) {
                    roundButton("plus", action: onAddStop)
                    roundButton(ds.soundMode == .silent ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                        ds.soundMode = ds.soundMode == .silent ? .both : .silent
                    }
                    roundButton("ellipsis", action: onMore)
                }
            }
            if let road = engine.roadName {
                Text(road).font(.subheadline.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(height: 34).background(LightUI.blue, in: Capsule())
            }
            HStack(spacing: 14) {
                Button(action: onMenu) { Image(systemName: "line.3.horizontal").font(.title2).foregroundStyle(LightUI.text).frame(width: 44, height: 44) }
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(Int((nav.remainingTime / 60).rounded())) min").font(.system(size: 22, weight: .bold).monospacedDigit()).foregroundStyle(LightUI.green)
                    HStack(spacing: 4) {
                        Text(ds.speedUnits.distance(nav.remainingDistance))
                        Text("|")
                        Text(Date().addingTimeInterval(nav.remainingTime), style: .time)
                    }
                    .font(.subheadline.monospacedDigit()).foregroundStyle(LightUI.sub)
                }
                Spacer()
                Button(action: onRouteOptions) { Image(systemName: "arrow.triangle.branch").font(.title3).foregroundStyle(LightUI.blue).frame(width: 44, height: 44) }
                Button(action: onEnd) {
                    Image(systemName: "xmark").font(.headline.bold()).foregroundStyle(.white).frame(width: 44, height: 44).background(Color.red, in: Circle())
                }
                .accessibilityLabel("End navigation")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .glassPanel(radius: 28)
            .shadow(color: .black.opacity(0.15), radius: 10, y: -2)
        }

        .sensoryFeedback(trigger: nav.next?.index) { _, _ in ds.hapticsOn ? .impact(weight: .medium) : nil }
    }

    private var lightLimit: some View {
        ZStack {
            Circle().fill(.white)
            Circle().stroke(Color.red, lineWidth: 6).padding(3)
            Text(engine.speedLimit.map { ds.speedUnits.limit($0).value } ?? "--")
                .font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(engine.speedLimit == nil ? .gray : .black)
        }
        .frame(width: 56, height: 56)
        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
    }

    private func roundButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(LightUI.blue)
                .frame(width: 52, height: 52).background(LightUI.card, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        }
    }

    /// Pulls the street name out of an instruction ("Turn left onto McKinney Rd" -> "McKinney Rd").
    private func street(_ s: String) -> String {
        for k in [" onto ", " on ", " toward ", " towards ", " to "] {
            if let r = s.range(of: k, options: .caseInsensitive) { return String(s[r.upperBound...]) }
        }
        return s
    }
}


// MARK: - Referral (local only; no backend)

import PhotosUI

enum Referral {
    static var code: String {
        let d = UserDefaults.standard
        if let c = d.string(forKey: "dr.refCode") { return c }
        let c = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
        d.set(c, forKey: "dr.refCode")
        return c
    }
    static var webLink: URL { URL(string: "https://radarbot.app/invite?ref=\(code)")! }
    static var appLink: URL { URL(string: "radarbot://invite?ref=\(code)")! }

    static var firstLaunch: Date {
        let d = UserDefaults.standard
        if let t = d.object(forKey: "dr.firstLaunch") as? Date { return t }
        let now = Date(); d.set(now, forKey: "dr.firstLaunch"); return now
    }

    /// Handles radarbot://invite?ref=CODE and https://radarbot.app/invite?ref=CODE. Returns true if a bonus was awarded.
    @discardableResult
    static func handle(_ url: URL) -> Bool {
        let isApp = url.scheme == "radarbot" && url.host == "invite"
        let isWeb = (url.scheme == "https" || url.scheme == "http") && url.host?.hasSuffix("radarbot.app") == true && url.path.hasPrefix("/invite")
        guard isApp || isWeb,
              let ref = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ref" })?.value?
                .trimmingCharacters(in: .whitespaces).uppercased(),
              !ref.isEmpty, ref.count <= 32, ref != code else { return false }
        let d = UserDefaults.standard
        guard d.string(forKey: "dr.referredBy") == nil else { return false }
        d.set(ref, forKey: "dr.referredBy")
        d.set(d.integer(forKey: "dr.xpBonus") + 100, forKey: "dr.xpBonus")
        return true
    }
}

enum LocalData {
    static var avatarURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("avatar.jpg")
    }
    static func resetProfile() {
        let d = UserDefaults.standard
        d.removeObject(forKey: "dr.profileName")
        try? FileManager.default.removeItem(at: avatarURL)
        d.set(d.integer(forKey: "dr.avatarVersion") + 1, forKey: "dr.avatarVersion")
    }
    @MainActor
    static func deleteAll(trips: TripRecorder, traps: TrapStore) {
        trips.trips.forEach(trips.deleteTrip)
        traps.favourites.forEach(traps.removeFavourite)
        traps.parking = nil
        let d = UserDefaults.standard
        for k in ["dr.recentPlaces", "dr.favPlaces", "dr.xpBonus", "dr.referredBy", "dr.invitesSent", "dr.xpWelcomed"] { d.removeObject(forKey: k) }
        resetProfile()
        d.set(Date(), forKey: "dr.firstLaunch")
    }
}

struct AvatarView: View {
    var size: CGFloat
    var fallbackIcon: String
    @AppStorage("dr.avatarVersion") private var version = 0
    var body: some View {
        let _ = version
        ZStack {
            if let img = UIImage(contentsOfFile: LocalData.avatarURL.path) {
                Image(uiImage: img).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [LightUI.blue, Color(hex: 0x7B61FF)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: fallbackIcon).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .id(version)
    }
}

struct EditProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dr.profileName") private var name = "Driver"
    @AppStorage("dr.avatarVersion") private var version = 0
    @State private var draft = ""
    @State private var pick: PhotosPickerItem?
    @State private var removeRequested = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            AvatarView(size: 96, fallbackIcon: "person.fill")
                            PhotosPicker(selection: $pick, matching: .images) {
                                Text("Choose photo").font(.subheadline.weight(.semibold))
                            }
                            if FileManager.default.fileExists(atPath: LocalData.avatarURL.path) {
                                Button("Remove photo", role: .destructive) {
                                    try? FileManager.default.removeItem(at: LocalData.avatarURL); version += 1
                                }
                                .font(.subheadline)
                            }
                        }
                        Spacer()
                    }
                }
                Section("Name") { TextField("Your name", text: $draft) }
            }
            .navigationTitle("Edit profile").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let t = draft.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { name = t }
                        dismiss()
                    }
                }
            }
            .onAppear { draft = name }
            .onChange(of: pick) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
                    let side: CGFloat = 400
                    let scale = side / min(img.size.width, img.size.height)
                    let sz = CGSize(width: img.size.width * scale, height: img.size.height * scale)
                    let out = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                        img.draw(in: CGRect(x: (side - sz.width) / 2, y: (side - sz.height) / 2, width: sz.width, height: sz.height))
                    }
                    try? out.jpegData(compressionQuality: 0.85)?.write(to: LocalData.avatarURL, options: .atomic)
                    await MainActor.run { version += 1 }
                }
            }
        }
        .preferredColorScheme(AppTheme.scheme)
    }
}

// MARK: - Light idle Drive overlay + quick panels (bak9)

import MediaPlayer
import MessageUI

struct LightLimitSign: View {
    var limitKmh: Double?
    var units: SpeedUnits
    var size: CGFloat = 58
    var body: some View {
        ZStack {
            Circle().fill(.white)
            Circle().strokeBorder(LinearGradient(colors: [Color(hex: 0xF0453D), Theme.limitRed], startPoint: .top, endPoint: .bottom),
                                  lineWidth: size * 0.115).padding(1.5)
            Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5).padding(size * 0.13)
            Text(limitKmh.map { units.limit($0).value } ?? "--")
                .font(.system(size: size * 0.36, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(limitKmh == nil ? Theme.inkTertiary : Theme.ink)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
        }
        .frame(width: size, height: size)
        .softShadow()
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: limitKmh)
        .accessibilityLabel(limitKmh == nil ? "Speed limit unknown" : "Speed limit \(units.limit(limitKmh!).value)")
    }
}

struct LightSpeedo: View {
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var ds: DriveSettings
    @Environment(\.driveNamespace) private var ns
    var body: some View {
        let s = ds.speedUnits.speed(engine.speed)
        Group {
            if AppTheme.isDark {
                NeonSpeedGauge(speedKmh: engine.speed * 3.6, limitKmh: engine.speedLimit, speeding: engine.isSpeeding,
                               valueText: s.value, unitText: s.unit, size: 140)
            } else {
                SpeedRingGauge(speedKmh: engine.speed * 3.6, limitKmh: engine.speedLimit, speeding: engine.isSpeeding,
                               valueText: s.value, unitText: s.unit, size: 92)
            }
        }
            .matchedIfAvailable("speedo", ns)
            .sensoryFeedback(trigger: engine.isSpeeding) { _, on in on && ds.hapticsOn ? .warning : nil }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Current speed \(s.value) \(s.unit)")
    }
}

struct WhiteRoundButton: View {
    var icon: String
    var tint: Color = LightUI.text
    var size: CGFloat = 52
    var label: String
    var text: String? = nil
    var action: () -> Void
    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            Group {
                if let text { Text(text).font(.system(size: size * 0.34, weight: .heavy, design: .rounded)) }
                else { Image(systemName: icon).font(.system(size: size * 0.36, weight: .semibold)).symbolRenderingMode(.hierarchical).contentTransition(.symbolEffect(.replace)) }
            }
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .background(Theme.glassFill, in: Circle())
                .overlay(Circle().strokeBorder(Theme.glassStroke, lineWidth: 1))
                .softShadow()
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(label)
    }
}

struct LightIdleOverlay: View {
    var onMenu: () -> Void
    var onSearch: () -> Void
    var onStyle: () -> Void
    var onRecenter: () -> Void = {}
    @EnvironmentObject var trips: TripRecorder
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var ds: DriveSettings
    @EnvironmentObject var alerts: AlertCenter
    @State private var panel: Panel?
    @AppStorage("dr.map3D") private var map3D = true
    enum Panel { case music, audio, report }

    var body: some View {
        ZStack(alignment: .bottom) {
            if panel != nil {
                Color.black.opacity(0.001).ignoresSafeArea().onTapGesture { withAnimation(.spring) { panel = nil } }
            }
            VStack(spacing: 12) {
                if let a = alerts.current {
                    AlertCard(alert: a).id(a.key).onTapGesture { alerts.dismiss() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if AppTheme.isDark {
                        VStack(alignment: .leading, spacing: 12) {
                            recordButton
                            VStack(spacing: 6) {
                                ProBadge()
                                LightSpeedo()
                                    .overlay(alignment: .topTrailing) {
                                        HexLimitSign(text: engine.speedLimit.map { ds.speedUnits.limit($0).value } ?? "--", size: 50)
                                            .offset(x: 18, y: -14)
                                    }
                            }
                        }
                    } else {
                        VStack(spacing: 10) {
                            recordButton
                            LightLimitSign(limitKmh: engine.speedLimit, units: ds.speedUnits)
                            LightSpeedo()
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 12) {
                        WhiteRoundButton(icon: "location.north.line.fill", tint: Theme.accent, label: "Re-centre", action: onRecenter)
                        CompassDial(heading: engine.heading)
                        HStack(alignment: .center, spacing: 10) {
                            if panel == .music { MusicCard().transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity)) }
                            WhiteRoundButton(icon: "music.note", label: "Music") { toggle(.music) }
                        }
                        HStack(alignment: .center, spacing: 10) {
                            if panel == .audio { AudioOptionsCard().transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity)) }
                            WhiteRoundButton(icon: ds.soundMode == .silent ? "speaker.slash.fill" : "speaker.wave.2.fill", label: "Audio options") { toggle(.audio) }
                        }
                        WhiteRoundButton(icon: "view.3d", tint: map3D ? Theme.accent : LightUI.text, label: map3D ? "Switch to 2D" : "Switch to 3D", text: map3D ? "3D" : "2D") {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { map3D.toggle() }
                        }
                        WhiteRoundButton(icon: "square.3.layers.3d", label: "Map style", action: onStyle)
                        Button { Haptics.tap(); toggle(.report) } label: {
                            Image(systemName: "plus").font(.system(size: 28, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 66, height: 66)
                                .background(Circle().fill(Theme.accentGradient).padding(6))
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(Theme.accent.opacity(0.8), lineWidth: 1.5))
                                .shadow(color: Theme.accent.opacity(0.75), radius: 16)
                        }
                        .buttonStyle(PressableStyle(scale: 0.9))
                        .accessibilityLabel("Report")
                        .padding(.top, 6)
                    }
                }
                HStack(spacing: 6) {
                    Button(action: onMenu) {
                        Image(systemName: "line.3.horizontal").font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                            .frame(width: 42, height: 42).background(Theme.canvas, in: Circle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.9))
                    .accessibilityLabel("Menu")
                    Button(action: onSearch) {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 30, height: 30).background(Theme.accentGradient, in: Circle())
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Go to...").font(Typo.title3).foregroundStyle(Theme.ink)
                                Text("Search places, addresses, favourites").font(Typo.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.up").font(.footnote.weight(.bold)).foregroundStyle(Theme.inkTertiary)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 50).background(Theme.canvas, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.98))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .glassPanel(radius: 26)
                statusLine
            }
            if panel == .report {
                QuickReportSheet { withAnimation(.spring) { panel = nil } }
                    .transition(.move(edge: .bottom))
            }
        }

        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: panel)
        .animation(.spring, value: alerts.current?.key)
    }

    private func toggle(_ p: Panel) { panel = panel == p ? nil : p }

    private var recordButton: some View {
        Button { Haptics.tap(); if trips.active { trips.endTrip() } } label: {
            ZStack {
                Circle().fill(Theme.glassFill)
                Circle().strokeBorder(Color(hex: 0xFF3B4A), lineWidth: 2.5)
                    .shadow(color: Color(hex: 0xFF3B4A).opacity(trips.active ? 0.95 : 0.4), radius: trips.active ? 10 : 4)
                RoundedRectangle(cornerRadius: 4).strokeBorder(Color(hex: 0xFF5A66), lineWidth: 2.5).frame(width: 18, height: 18)
            }
            .frame(width: 56, height: 56)
        }
        .buttonStyle(PressableStyle(scale: 0.9))
        .accessibilityLabel(trips.active ? "Stop trip recording" : "Trip recording idle")
    }

    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(trips.active ? Theme.good : Theme.inkTertiary).frame(width: 8, height: 8)
                    .shadow(color: trips.active ? Theme.good : .clear, radius: 4)
                Text(trips.active ? "Trip recording" : "Not recording").foregroundStyle(trips.active ? Theme.good : Theme.inkSecondary)
                Spacer()
                if trips.active {
                    Text(ds.speedUnits.distance(trips.live.distance)).monospacedDigit().foregroundStyle(Theme.ink)
                    Text("Score \(trips.liveScore)").monospacedDigit().foregroundStyle(Theme.ink)
                }
            }
            .font(Typo.footnote.weight(.semibold))
            Text(engine.hazardStatus).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
        }
        .padding(.horizontal, 10)
    }
}

struct MusicCard: View {
    @Environment(\.openURL) private var openURL
    @State private var playing = MPMusicPlayerController.systemMusicPlayer.playbackState == .playing
    @State private var title = MPMusicPlayerController.systemMusicPlayer.nowPlayingItem?.title
    var body: some View {
        let p = MPMusicPlayerController.systemMusicPlayer
        VStack(alignment: .leading, spacing: 8) {
            Text(title ?? "Nothing playing").font(.subheadline.bold()).foregroundStyle(LightUI.text).lineLimit(1)
            HStack(spacing: 18) {
                Button { p.skipToPreviousItem(); refresh() } label: { Image(systemName: "backward.fill") }
                Button { playing ? p.pause() : p.play(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: refresh) } label: {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { p.skipToNextItem(); refresh() } label: { Image(systemName: "forward.fill") }
                Button { openURL(URL(string: "music://")!) } label: { Image(systemName: "arrow.up.forward.app") }
                    .accessibilityLabel("Open Music")
            }
            .foregroundStyle(LightUI.blue)
        }
        .padding(14).frame(width: 210, alignment: .leading)
        .glassPanel(radius: 28)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
    private func refresh() {
        let p = MPMusicPlayerController.systemMusicPlayer
        playing = p.playbackState == .playing
        title = p.nowPlayingItem?.title
    }
}

struct AudioOptionsCard: View {
    @EnvironmentObject var ds: DriveSettings
    @EnvironmentObject var alerts: AlertCenter
    @State private var showAbout = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            option("Sound on", "speaker.wave.2.fill", .both)
            option("Voice only", "person.wave.2.fill", .voiceOnly)
            option("Alerts only", "bell.fill", .chimeOnly)
            option("Mute", "speaker.slash.fill", .silent)
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(Theme.inkSecondary)
                Slider(value: $ds.chimeVolume, in: 0.05...1) { e in if !e { alerts.playChime() } }
                    .tint(Theme.accent)
                    .shadow(color: Theme.accent.opacity(0.6), radius: 6)
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(Theme.inkSecondary)
            }
            .padding(.vertical, 8)
            Toggle("Haptics", isOn: $ds.hapticsOn).font(Typo.body.weight(.medium)).foregroundStyle(Theme.ink).tint(Theme.accent)
            Divider().overlay(Theme.hairline).padding(.vertical, 6)
            row("About App", "info.circle") { showAbout = true }
            Link(destination: URL(string: "mailto:")!) { rowLabel("Contact Us", "person.fill") }
            Link(destination: URL(string: "mailto:")!) { rowLabel("Email support", "envelope") }
        }
        .padding(16).frame(width: 260)
        .glassPanel(radius: 26)
        .alert("DriveRadar", isPresented: $showAbout) { Button("OK", role: .cancel) {} } message: {
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
        }
    }
    private func rowLabel(_ t: String, _ i: String) -> some View {
        HStack(spacing: 10) { Image(systemName: i).foregroundStyle(Theme.accent).frame(width: 22); Text(t).foregroundStyle(Theme.ink); Spacer() }
            .font(Typo.body.weight(.medium)).frame(height: 36).contentShape(Rectangle())
    }
    private func row(_ t: String, _ i: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { rowLabel(t, i) }.buttonStyle(.plain)
    }
    private func option(_ t: String, _ i: String, _ m: SoundMode) -> some View {
        Button { Haptics.tap(); ds.soundMode = m } label: {
            HStack(spacing: 10) {
                Image(systemName: i).frame(width: 22)
                Text(t)
                Spacer()
                if ds.soundMode == m { Image(systemName: "checkmark").font(.body.bold()) }
            }
            .font(Typo.body.weight(ds.soundMode == m ? .bold : .medium))
            .foregroundStyle(ds.soundMode == m ? Theme.accent : Theme.ink)
            .frame(height: 38).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Glass compass dial showing heading letter.
struct CompassDial: View {
    var heading: Double
    var size: CGFloat = 52
    var body: some View {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let letter = dirs[Int(((heading.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8]
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(Theme.glassFill)
            Circle().strokeBorder(Theme.glassStroke, lineWidth: 1)
            ForEach(0..<24) { i in
                Capsule().fill(Theme.ink.opacity(i % 6 == 0 ? 0.6 : 0.2)).frame(width: 1, height: i % 6 == 0 ? 5 : 3)
                    .offset(y: -size * 0.42).rotationEffect(.degrees(Double(i) * 15 - heading))
            }
            Triangle().fill(Color(hex: 0xFF3B4A)).frame(width: 6, height: 6).offset(y: -size * 0.36).rotationEffect(.degrees(-heading))
            Text(letter).font(.system(size: size * 0.32, weight: .heavy, design: .rounded)).foregroundStyle(Theme.accent)
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .softShadow()
        .animation(.easeInOut(duration: 0.4), value: heading)
        .accessibilityLabel("Heading \(letter)")
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath(); return p }
}

struct QuickReportSheet: View {
    var onClose: () -> Void
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var ds: DriveSettings
    private let items: [(String, String, TrapType, Color)] = [
        ("Speed camera", "camera.fill", .camera, Color(hex: 0x1A73E8)),
        ("Police", "shield.lefthalf.filled", .police, Color(hex: 0x3949AB)),
        ("Crash", "car.side.rear.and.collision.and.car.side.front", .accident, Color(hex: 0xE53935)),
        ("Hazard", "exclamationmark.triangle.fill", .hazard, Color(hex: 0xF08A24)),
        ("Roadwork", "cone.fill", .roadwork, Color(hex: 0xF5A524)),
        ("Traffic", "car.2.fill", .traffic, Color(hex: 0xD84315)),
    ]
    var body: some View {
        VStack(spacing: 14) {
            Capsule().fill(Color.gray.opacity(0.35)).frame(width: 40, height: 5)
            HStack {
                Text("Report").font(.title3.bold()).foregroundStyle(LightUI.text)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(LightUI.sub) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 16) {
                ForEach(items, id: \.0) { t, icon, type, color in
                    Button {
                        engine.report(type)
                        if ds.hapticsOn { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                        onClose()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: icon).font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 60, height: 60).background(color, in: Circle())
                            Text(t).font(.caption.weight(.semibold)).foregroundStyle(LightUI.text)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Reports are saved on this iPhone at your current position.").font(.caption2).foregroundStyle(LightUI.sub)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 24)
        .background(.white, in: UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 16, y: -4)
        .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: Launch banner / modals

struct ReadyBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.fill").font(.title3).foregroundStyle(.white)
                .frame(width: 42, height: 42).background(LightUI.blue, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("DriveRadar is ready").font(.subheadline.bold()).foregroundStyle(LightUI.text)
                Text("Start driving to begin receiving real-time speed camera and incident alerts.")
                    .font(.caption).foregroundStyle(LightUI.sub).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassPanel(radius: 28)
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .environment(\.colorScheme, AppTheme.scheme)
    }
}

struct CenterCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 16) { content }
                .padding(24).frame(maxWidth: 300)
                .glassPanel(radius: 28)
                .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        }
        .environment(\.colorScheme, AppTheme.scheme)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

struct CalculatingRouteCard: View {
    var body: some View {
        CenterCard {
            ProgressView().controlSize(.large).tint(LightUI.blue)
            Text("Calculating route...").font(.headline).foregroundStyle(LightUI.text)
        }
    }
}

// MARK: Help & feedback

struct MailCompose: UIViewControllerRepresentable {
    var to: String; var subject: String; var body: String
    var onDone: () -> Void
    func makeCoordinator() -> Coord { Coord(onDone: onDone) }
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.setToRecipients([to]); vc.setSubject(subject); vc.setMessageBody(body, isHTML: false)
        vc.mailComposeDelegate = context.coordinator
        return vc
    }
    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}
    final class Coord: NSObject, MFMailComposeViewControllerDelegate {
        let onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
        func mailComposeController(_ c: MFMailComposeViewController, didFinishWith r: MFMailComposeResult, error: Error?) { onDone() }
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var composing = false
    @State private var mailError = false
    static let supportAddress = "support@radarbot.example"
    private let faqs: [(String, String)] = [
        ("Where does camera data come from?", "Speed cameras, limits and road details come from OpenStreetMap contributors, plus reports you save yourself. Coverage varies by area."),
        ("Why is the speed limit showing --?", "The limit isn't mapped for that road yet, or GPS hasn't matched you to a road. It updates as you drive."),
        ("Does DriveRadar work in the background?", "Yes, if you enable background driving in Settings and allow location access 'Always'."),
        ("How do I report a speed camera or hazard?", "Tap the speech-bubble button on the map and pick a category. Reports are stored on this iPhone."),
        ("How are XP points earned?", "One point per kilometre driven, with bonuses for trips without speeding. Everything is calculated on your device."),
        ("Is my data shared?", "No. Trips, reports and your profile stay on this iPhone. You can delete everything from your profile."),
    ]
    var body: some View {
        NavigationStack {
            List {
                Section("Frequently asked questions") {
                    ForEach(faqs, id: \.0) { q, a in
                        DisclosureGroup {
                            Text(a).font(.subheadline).foregroundStyle(LightUI.sub).padding(.vertical, 4)
                        } label: { Text(q).font(.subheadline.weight(.semibold)) }
                    }
                }
                Section {
                    Button { contact() } label: { Label("Contact support", systemImage: "envelope.fill") }
                } footer: { Text("We usually reply within a few days.") }
            }
            .navigationTitle("How can we help?").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $composing) {
                MailCompose(to: Self.supportAddress, subject: "DriveRadar feedback", body: diag) { composing = false }
            }
            .alert("Mail isn't set up", isPresented: $mailError) {
                Button("Copy address") { UIPasteboard.general.string = Self.supportAddress }
                Button("OK", role: .cancel) {}
            } message: { Text("Add a mail account in Settings, or write to \(Self.supportAddress) from any mail app.") }
        }
        .tint(LightUI.blue)
        .preferredColorScheme(AppTheme.scheme)
    }
    private var diag: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "\n\n—\nDriveRadar \(v) · iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)"
    }
    private func contact() {
        if MFMailComposeViewController.canSendMail() { composing = true; return }
        let q = "subject=Radar%20Bot%20feedback"
        if let url = URL(string: "mailto:\(Self.supportAddress)?\(q)"), UIApplication.shared.canOpenURL(url) {
            openURL(url) { ok in if !ok { mailError = true } }
        } else {
            mailError = true
        }
    }
}


// MARK: - Stop picker + nav route options (bak11)

struct StopPickerView: View {
    var onPick: (MKMapItem) -> Void
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var traps: TrapStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(LightUI.sub)
                    TextField("Add a stop", text: $query).autocorrectionDisabled().foregroundStyle(LightUI.text)
                }
                .padding(.horizontal, 16).frame(height: 48).background(LightUI.card, in: Capsule())
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if searching { ShimmerRows(count: 3) }
                        if query.count < 2 {
                            ForEach(traps.favourites) { f in
                                PlaceRow(icon: f.icon, name: f.name, subtitle: "Favourite", distance: dist(f.coordinate)) { onPick(makeMapItem(f.coordinate, name: f.name)) }
                                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5).padding(.leading, 70)
                            }
                            ForEach(RecentStore.load()) { p in
                                PlaceRow(icon: "clock", name: p.name, subtitle: p.address, distance: dist(p.coordinate)) { onPick(p.mapItem) }
                                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5).padding(.leading, 70)
                            }
                        } else {
                            ForEach(results) { r in
                                PlaceRow(icon: "mappin.circle.fill", name: r.item.name ?? "Place", subtitle: address(r.item), distance: r.distance) { onPick(r.item) }
                                Rectangle().fill(Color.black.opacity(0.08)).frame(height: 0.5).padding(.leading, 70)
                            }
                            if !searching && results.isEmpty {
                                EmptyStateView(icon: "magnifyingglass", title: "No matches", message: "Try a different name or address.")
                            }
                        }
                    }
                    .glassPanel(radius: 28)
                }
            }
            .padding(16)
            .background(LightUI.bg.ignoresSafeArea())
            .navigationTitle("Add stop").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: query) { _, q in search(q) }
        }
        .preferredColorScheme(AppTheme.scheme)
    }

    private func dist(_ c: CLLocationCoordinate2D) -> Double? { engine.location.map { Geo.distance($0.coordinate, c) } }

    private func search(_ q: String) {
        task?.cancel()
        let t = q.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { results = []; searching = false; return }
        searching = true
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let req = MKLocalSearch.Request()
            req.naturalLanguageQuery = t
            let here = engine.location?.coordinate
            if let h = here { req.region = MKCoordinateRegion(center: h, latitudinalMeters: 50_000, longitudinalMeters: 50_000) }
            let items = (try? await MKLocalSearch(request: req).start())?.mapItems ?? []
            guard !Task.isCancelled else { return }
            results = items.map { it in PlaceResult(item: it, distance: here.map { Geo.distance($0, mapItemCoordinate(it)) } ?? 0) }
            searching = false
        }
    }
}

struct NavRouteOptionsSheet: View {
    @EnvironmentObject var nav: NavigationEngine
    @EnvironmentObject var engine: DriveEngine
    @Environment(\.dismiss) private var dismiss
    @State private var tolls = false
    @State private var highways = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $tolls) { Label("Avoid tolls", systemImage: "dollarsign.circle") }
                    Toggle(isOn: $highways) { Label("Avoid highways", systemImage: "road.lanes") }
                } footer: { Text("Your current route is recalculated from where you are.") }
                if !nav.pendingStops.isEmpty {
                    Section("Upcoming stops") {
                        ForEach(Array(nav.pendingStops.enumerated()), id: \.offset) { i, s in
                            Label(s.name ?? "Stop \(i + 1)", systemImage: i == nav.pendingStops.count - 1 ? "flag.checkered" : "mappin.circle")
                        }
                    }
                }
            }
            .tint(LightUI.blue)
            .navigationTitle("Route options").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let changed = tolls != nav.avoidTolls || highways != nav.avoidHighways
                        nav.avoidTolls = tolls; nav.avoidHighways = highways
                        if changed { nav.recalculate(from: engine.location) }
                        dismiss()
                    }
                }
            }
            .onAppear { tolls = nav.avoidTolls; highways = nav.avoidHighways }
        }
        .preferredColorScheme(AppTheme.scheme)
    }
}


// MARK: - Active route persistence, Continue route card, splash (bak12)

enum ActiveRouteStore {
    private static let key = "dr.activeRoute"
    struct P: Codable { var name: String; var lat: Double; var lon: Double }
    static func save(_ items: [MKMapItem]) {
        let list = items.map { i -> P in let c = mapItemCoordinate(i); return P(name: i.name ?? "Destination", lat: c.latitude, lon: c.longitude) }
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }
    /// Ordered targets: current leg first, final destination last.
    static func load() -> [MKMapItem]? {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([P].self, from: d), !list.isEmpty else { return nil }
        return list.map { makeMapItem(CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon), name: $0.name) }
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

struct RouteIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xEEF0F3))
            Path { p in
                for x in stride(from: 0.0, through: 1.0, by: 0.2) { p.move(to: CGPoint(x: x * 160, y: 0)); p.addLine(to: CGPoint(x: x * 160, y: 100)) }
                for y in stride(from: 0.0, through: 1.0, by: 0.25) { p.move(to: CGPoint(x: 0, y: y * 100)); p.addLine(to: CGPoint(x: 160, y: y * 100)) }
            }
            .stroke(Color.white, lineWidth: 5)
            Path { p in
                p.move(to: CGPoint(x: 16, y: 88))
                p.addLine(to: CGPoint(x: 48, y: 88)); p.addLine(to: CGPoint(x: 48, y: 50))
                p.addLine(to: CGPoint(x: 96, y: 50)); p.addLine(to: CGPoint(x: 96, y: 25)); p.addLine(to: CGPoint(x: 128, y: 25))
            }
            .stroke(LightUI.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            Circle().fill(LightUI.blue).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2)).position(x: 16, y: 88)
            Image(systemName: "mappin.circle.fill").font(.system(size: 26)).foregroundStyle(.white, .red).position(x: 128, y: 18)
        }
        .frame(width: 160, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityHidden(true)
    }
}

struct ContinueRouteCard: View {
    var name: String
    var onCancel: () -> Void
    var onAccept: () -> Void
    var body: some View {
        CenterCard {
            RouteIllustration()
            Text("Continue route").font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(LightUI.text)
            Text("Do you want to resume your route to \(name)?").font(.subheadline).multilineTextAlignment(.center).foregroundStyle(LightUI.sub)
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text("Cancel").font(.headline).foregroundStyle(LightUI.blue).frame(maxWidth: .infinity).frame(height: 48)
                        .overlay(Capsule().stroke(LightUI.blue, lineWidth: 1.5))
                }
                Button(action: onAccept) {
                    Text("Accept").font(.headline).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 48)
                        .background(LightUI.blue, in: Capsule())
                }
            }
        }
    }
}

struct SplashView: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    var body: some View {
        ZStack {
            Color(hex: 0xF4F5F7).ignoresSafeArea()
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 26, style: .continuous).fill(LightUI.blue).frame(width: 96, height: 96)
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 44, weight: .bold)).foregroundStyle(.white)
                }
                .shadow(color: LightUI.blue.opacity(0.3), radius: 12, y: 6)
                Text("DRIVERADAR").font(.system(size: 28, weight: .heavy, design: .rounded)).tracking(3).foregroundStyle(LightUI.text)
            }
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    ForEach(0..<3) { i in
                        Circle().fill(LightUI.blue).frame(width: 9, height: 9)
                            .opacity(phase % 3 == i ? 1 : 0.3)
                            .scaleEffect(phase % 3 == i ? 1.25 : 1)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: phase)
                .padding(.bottom, 60)
            }
        }
        .onReceive(timer) { _ in phase += 1 }
        .accessibilityLabel("DriveRadar is loading")
    }
}


// MARK: - Route preferences, Route options screen, Add-to-favourites card (bak13)

enum RoutePrefs {
    private static var d: UserDefaults { .standard }
    static var allowMotorways: Bool { d.object(forKey: "dr.allowMotorways") as? Bool ?? true }
    static var allowTolls: Bool { d.object(forKey: "dr.allowTolls") as? Bool ?? true }
    static var shorter: Bool { d.string(forKey: "dr.routePref") == "shorter" }
    static var autoFaster: Bool {
        if d.object(forKey: "dr.autoFaster") == nil { return true }
        return d.bool(forKey: "dr.autoFaster")
    }
    static var offline: Bool { d.bool(forKey: "dr.offline") }
    static var navApp: String { d.string(forKey: "dr.navApp") ?? "radarbot" }
}

struct RouteOptionsScreen: View {
    var onDone: () -> Void = {}
    @EnvironmentObject var ds: DriveSettings
    @EnvironmentObject var engine: DriveEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dr.allowMotorways") private var motorways = true
    @AppStorage("dr.allowTolls") private var tolls = true
    @AppStorage("dr.routePref") private var pref = "faster"
    @AppStorage("dr.autoFaster") private var autoFaster = true
    @AppStorage("dr.offline") private var offline = false
    @AppStorage("dr.navApp") private var navApp = "radarbot"
    @State private var downloading = false
    @State private var downloadResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { download() } label: {
                        HStack(spacing: 14) {
                            icon("arrow.down.circle.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Download maps and radars").foregroundStyle(LightUI.text)
                                Text(downloadResult ?? lastUpdate).font(.caption).foregroundStyle(LightUI.sub)
                            }
                            Spacer()
                            if downloading { ProgressView() }
                        }
                    }
                    .disabled(downloading)
                    NavigationLink {
                        Form {
                            Picker("Vehicle type", selection: $ds.vehicle) {
                                ForEach(VehicleKind.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.inline)
                            Section("Fuel consumption") {
                                Stepper(String(format: "%.1f L/100 km", ds.fuelPer100km), value: $ds.fuelPer100km, in: 2...40, step: 0.5)
                            }
                        }
                        .navigationTitle("My vehicle")
                    } label: {
                        HStack(spacing: 14) {
                            icon("car.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("My vehicle").foregroundStyle(LightUI.text)
                                Text("\(ds.vehicle.label) · \(String(format: "%.1f", ds.fuelPer100km)) L/100 km").font(.caption).foregroundStyle(LightUI.sub)
                            }
                        }
                    }
                    Toggle(isOn: $offline) {
                        HStack(spacing: 14) {
                            icon("wifi.slash")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Activate offline mode")
                                Text("Use saved camera data and skip background downloads").font(.caption).foregroundStyle(LightUI.sub)
                            }
                        }
                    }
                    Picker(selection: $navApp) {
                        Text("DriveRadar").tag("radarbot")
                        Text("Apple Maps").tag("apple")
                        Text("Google Maps").tag("google")
                    } label: { HStack(spacing: 14) { icon("arrow.triangle.turn.up.right.diamond.fill"); Text("Default navigation app") } }
                    Picker(selection: $pref) {
                        Text("Faster").tag("faster")
                        Text("Shorter").tag("shorter")
                    } label: { HStack(spacing: 14) { icon("point.topleft.down.to.point.bottomright.curvepath.fill"); Text("Route preference") } }
                    Toggle(isOn: $autoFaster) {
                        HStack(spacing: 14) {
                            icon("bolt.car.fill")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Automatically accept faster routes")
                                Text("Switches when a route saves more than 2 minutes").font(.caption).foregroundStyle(LightUI.sub)
                            }
                        }
                    }
                }
                Section {
                    Toggle(isOn: $motorways) { HStack(spacing: 14) { icon("road.lanes"); Text("Motorways") } }
                    Toggle(isOn: $tolls) { HStack(spacing: 14) { icon("dollarsign.circle.fill"); Text("Tolls") } }
                    HStack(spacing: 14) {
                        icon("ferry.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ferries / unpaved roads").foregroundStyle(LightUI.sub)
                            Text("Apple Maps routing doesn't offer this option").font(.caption).foregroundStyle(LightUI.sub)
                        }
                    }
                } header: { Text("Permitted roads") } footer: {
                    Text("Offline mode keeps navigation working with saved camera data; Apple map tiles and directions still need a connection.")
                }
            }
            .tint(LightUI.blue)
            .scrollContentBackground(.hidden)
            .background(LightUI.bg.ignoresSafeArea())
            .navigationTitle("Route options").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { onDone(); dismiss() } } }
        }
        .preferredColorScheme(AppTheme.scheme)
    }

    private func icon(_ n: String) -> some View {
        Image(systemName: n).foregroundStyle(LightUI.blue).frame(width: 26)
    }
    private var lastUpdate: String {
        engine.osm.hazardFetched.map { "Camera data saved \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Save camera data for your area"
    }
    private func download() {
        guard let c = engine.location?.coordinate else { downloadResult = "Waiting for GPS…"; return }
        downloading = true; downloadResult = "Downloading camera data…"
        engine.osm.refreshHazards(around: c) { ok in
            DispatchQueue.main.async {
                downloading = false
                downloadResult = ok ? "Camera data for this area is saved" : "Download failed — check your connection"
            }
        }
    }
}

struct AddFavouriteCard: View {
    var onCustom: () -> Void
    var onHome: () -> Void
    var onWork: () -> Void
    var onClose: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 0) {
                Text("ADD TO FAVOURITES").font(.system(size: 14, weight: .heavy, design: .rounded)).tracking(1)
                    .foregroundStyle(LightUI.text).padding(.horizontal, 20).padding(.vertical, 16)
                Divider()
                row("star.fill", "Customised", onCustom)
                Divider().padding(.leading, 56)
                row("house.fill", "Home", onHome)
                Divider().padding(.leading, 56)
                row("briefcase.fill", "Work", onWork)
            }
            .glassPanel(radius: 28)
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.black.opacity(0.12)))
            .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
            .padding(.horizontal, 36)
        }
        .environment(\.colorScheme, AppTheme.scheme)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
    private func row(_ i: String, _ t: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            HStack(spacing: 16) {
                Image(systemName: i).foregroundStyle(LightUI.blue).frame(width: 24)
                Text(t).font(.system(size: 17, weight: .semibold)).foregroundStyle(LightUI.text)
                Spacer()
            }
            .padding(.horizontal, 20).frame(height: 54).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}


// MARK: - Immersive Drive mode (UI refresh)

private struct DriveNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    var driveNamespace: Namespace.ID? {
        get { self[DriveNamespaceKey.self] }
        set { self[DriveNamespaceKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder func matchedIfAvailable(_ id: String, _ ns: Namespace.ID?) -> some View {
        if let ns { self.matchedGeometryEffect(id: id, in: ns) } else { self }
    }
}

/// Full-screen glass HUD over the 3D map while navigating.
struct DriveModeOverlay: View {
    var onExit: () -> Void
    var onEnd: () -> Void
    @EnvironmentObject var nav: NavigationEngine
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var ds: DriveSettings
    @EnvironmentObject var alerts: AlertCenter
    @EnvironmentObject var trips: TripRecorder
    @Environment(\.driveNamespace) private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("dr.map3D") private var map3D = true
    @State private var arrowNudge = false

    var body: some View {
        VStack(spacing: 12) {
            maneuverCard
            statsStrip
            if let a = alerts.current {
                AlertCard(alert: a).id(a.key).onTapGesture { alerts.dismiss() }
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 12) {
                VStack(spacing: 10) {
                    LightLimitSign(limitKmh: engine.speedLimit, units: ds.speedUnits, size: 60)
                    let s = ds.speedUnits.speed(engine.speed)
                    SpeedRingGauge(speedKmh: engine.speed * 3.6, limitKmh: engine.speedLimit, speeding: engine.isSpeeding,
                                   valueText: s.value, unitText: s.unit, size: 120)
                        .matchedIfAvailable("speedo", ns)
                }
                Spacer()
                VStack(spacing: 10) {
                    WhiteRoundButton(icon: map3D ? "view.3d" : "view.2d", tint: map3D ? Theme.accent : Theme.ink, label: "2D or 3D") {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { map3D.toggle() }
                    }
                    WhiteRoundButton(icon: "arrow.down.right.and.arrow.up.left", label: "Exit drive mode", action: onExit)
                }
            }
            etaCard
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: nav.next?.instruction)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: alerts.current?.key)

    }

    private var maneuverCard: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.accentGradient)
                    .shadow(color: Theme.accent.opacity(0.4), radius: 12, y: 6)
                Image(systemName: nav.next?.kind.symbol ?? "arrow.up")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(y: arrowNudge ? -4 : 2)
                    .symbolEffect(.bounce, value: nav.next?.instruction)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text(nav.distanceToNext.map { ds.speedUnits.distance($0) } ?? "—")
                    .font(Typo.number(38, .bold)).foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(nav.next?.instruction ?? "Follow the route")
                    .font(Typo.title3).foregroundStyle(Theme.ink.opacity(0.85)).lineLimit(2)
                if let t = nav.then {
                    Label("then \(t.kind.shortText)", systemImage: t.kind.symbol)
                        .font(Typo.footnote).foregroundStyle(Theme.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .glassPanel(radius: 28)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { arrowNudge = true }
        }
    }

    private var statsStrip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = trips.active ? max(ctx.date.timeIntervalSince(trips.live.start), 0) : 0
            let avg = elapsed > 5 ? trips.live.distance / elapsed : 0
            HStack(spacing: 8) {
                InfoChip(icon: "timer", text: trips.active ? durationText(elapsed) : "—", tint: Theme.ink)
                InfoChip(icon: "gauge.with.dots.needle.33percent", text: "avg \(ds.speedUnits.speed(avg).value) \(ds.speedUnits.speed(avg).unit)", tint: Theme.accent)
                InfoChip(icon: "road.lanes", text: ds.speedUnits.distance(trips.live.distance), tint: Theme.good)
                Spacer(minLength: 0)
            }
        }
    }

    private var etaCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(nav.destinationName).font(Typo.headline).foregroundStyle(Theme.ink).lineLimit(1)
                HStack(spacing: 6) {
                    InfoChip(icon: "flag.checkered", text: Date().addingTimeInterval(nav.remainingTime).formatted(date: .omitted, time: .shortened), tint: Theme.good)
                    InfoChip(icon: "clock.fill", text: durationText(nav.remainingTime))
                    InfoChip(icon: "point.topleft.down.to.point.bottomright.curvepath.fill", text: ds.speedUnits.distance(nav.remainingDistance), tint: Theme.inkSecondary)
                }
            }
            Spacer(minLength: 0)
            Button { Haptics.warning(); onEnd() } label: {
                Text("End").font(Typo.headline).foregroundStyle(.white)
                    .padding(.horizontal, 22).frame(height: 46)
                    .background(Theme.hotGradient, in: Capsule())
                    .shadow(color: Theme.mutedRed.opacity(0.35), radius: 10, y: 5)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(14)
        .glassPanel(radius: 26)
    }
}
