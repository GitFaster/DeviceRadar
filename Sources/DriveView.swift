import SwiftUI
import MapKit
import Combine

struct DriveMapView: View {
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var nav: NavigationEngine
    @EnvironmentObject var ds: DriveSettings
    @EnvironmentObject var traps: TrapStore
    @ObservedObject var marker: MarkerAnimator
    @Binding var following: Bool
    @Binding var selectedOption: UUID?
    @State private var position: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var cameraHeading: Double = 0
    @State private var cameraPitch: Double = 0
    @State private var metersPerPoint: Double = 1
    @State private var lastFollow = Date.distantPast
    @State private var mapPick: CLLocationCoordinate2D?
    @State private var resumeFollow: Task<Void, Never>?
    @AppStorage("dr.map3D") private var map3D = true
    @State private var routeGlow = false

    @Environment(\.colorScheme) private var systemScheme

    private var isNight: Bool { Geo.isNight(at: engine.location?.coordinate) }

    // Always light map tiles (night/auto-dark map logic disabled).
    @AppStorage("dr.nightMode") private var nightMode = "auto"
    private var mapScheme: ColorScheme { NightMode.isActive(nightMode, at: engine.location, navigating: nav.isNavigating) ? .dark : .light }

    private var style: MapStyle {
        // Light reference look: always the light standard map (flat, no 3D/satellite).
        if ds.lightNav { return .standard(elevation: map3D ? .realistic : .flat, emphasis: .automatic, pointsOfInterest: .all, showsTraffic: ds.showTraffic) }
        switch ds.mapStyle {
        case .tesla: return .standard(elevation: .realistic, pointsOfInterest: .excludingAll, showsTraffic: ds.showTraffic)
        case .standard: return .standard(elevation: .automatic, pointsOfInterest: .all, showsTraffic: ds.showTraffic)
        case .satellite: return .imagery(elevation: .automatic)
        case .hybrid: return .hybrid(elevation: .automatic, pointsOfInterest: .all, showsTraffic: ds.showTraffic)
        case .terrain: return .hybrid(elevation: .realistic, pointsOfInterest: .excludingAll, showsTraffic: false)
        }
    }

    private var visibleHazards: [OSMHazard] {
        guard let c = engine.location?.coordinate else { return engine.nearbyHazards }
        return engine.nearbyHazards.filter { h in
            let d = Geo.distance(h.coordinate, c)
            switch h.kind {
            case .school, .crossing: return d < 1200
            case .bump: return d < 500
            default:
                if d < 350 { return true }
                guard engine.speed > 3, d < 2200 else { return d < 800 }
                return Geo.angleDiff(Geo.bearing(c, h.coordinate), engine.heading) <= 55
            }
        }
    }

    var body: some View {
        MapReader { proxy in
        Map(position: $position) {
            ForEach(nav.options) { opt in
                MapPolyline(opt.route.polyline)
                    .stroke(opt.id == (selectedOption ?? nav.options.first?.id) ? Theme.accent : Color.gray.opacity(0.7),
                            style: StrokeStyle(lineWidth: opt.id == (selectedOption ?? nav.options.first?.id) ? 8 : 5, lineCap: .round, lineJoin: .round))
            }
            if let route = nav.route {
                MapPolyline(route.polyline)
                    .stroke(Theme.accent.opacity(0.28), style: StrokeStyle(lineWidth: 24, lineCap: .round, lineJoin: .round))
                MapPolyline(route.polyline)
                    .stroke(Color(hex: 0x7B5CFF).opacity(0.45), style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
                MapPolyline(route.polyline)
                    .stroke(LinearGradient(colors: routeGlow ? [Color.white, Color(hex: 0x8FD0FF), Color(hex: 0xB9A8FF)]
                                                             : [Color(hex: 0xB9A8FF), Color.white, Color(hex: 0x8FD0FF)],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            }
            ForEach(visibleHazards) { h in
                Annotation(h.name ?? "", coordinate: h.coordinate) { HazardPin(kind: h.kind) }
                    .annotationTitles(.hidden)
            }
            ForEach(traps.reports) { r in
                Annotation(r.type.label, coordinate: r.coordinate) { ReportPin(type: r.type) }
                    .annotationTitles(.hidden)
            }
            if let dest = nav.destinationCoordinate {
                Marker(nav.destinationName, systemImage: "flag.checkered", coordinate: dest).tint(Theme.accent)
            }
            if let p = traps.parking {
                Marker("My car", systemImage: "car.fill", coordinate: p.coordinate).tint(.purple)
            }
            if let c = marker.coordinate {
                Annotation(nav.transport == .walking ? "You" : "", coordinate: c, anchor: .center) {
                    if nav.transport == .walking {
                        ZStack {
                            Circle().fill(Color.white).frame(width: 38, height: 38)
                            Circle().fill(LightUI.blue).frame(width: 32, height: 32)
                            Image(systemName: "figure.walk")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .shadow(color: LightUI.blue.opacity(0.35), radius: 8, y: 3)
                    } else {
                        CarMarker(rotation: marker.bearing - cameraHeading,
                                  accuracy: engine.location?.horizontalAccuracy ?? 10,
                                  metersPerPoint: metersPerPoint,
                                  speed: engine.speed,
                                  pitch: cameraPitch)
                    }
                }
                .annotationTitles(.hidden)
            } else {
                UserAnnotation()
            }
        }
        .mapStyle(style)
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .environment(\.colorScheme, mapScheme)
        .onMapCameraChange(frequency: .continuous) { ctx in
            cameraHeading = ctx.camera.heading
            cameraPitch = ctx.camera.pitch
            let span = ctx.region.span.latitudeDelta * 111_320
            metersPerPoint = span / 700
        }
        .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in
            resumeFollow?.cancel()
            if following { following = false }
            else { scheduleResume() }
        })
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                .onEnded { value in
                    guard case .second(true, let drag?) = value,
                          let c = proxy.convert(drag.location, from: .local) else { return }
                    mapPick = c
                }
        )
        .confirmationDialog("This point", isPresented: Binding(get: { mapPick != nil }, set: { if !$0 { mapPick = nil } }), titleVisibility: .visible) {
            Button("Route here") {
                guard let c = mapPick, let from = engine.location?.coordinate else { return }
                following = false
                nav.requestRoutes(to: makeMapItem(c, name: "Dropped pin"), from: from, transport: nav.transport)
                mapPick = nil
            }
            Button("Save favourite") {
                if let c = mapPick { traps.addFavourite(name: "Saved place", at: c, icon: "mappin") }
                mapPick = nil
            }
            Button("Report a speed check") {
                if let c = mapPick { traps.add(.speedTrap, at: c, heading: engine.speed > 2 ? engine.course : nil) }
                mapPick = nil
            }
            Button("Cancel", role: .cancel) { mapPick = nil }
        }
        .onReceive(engine.$location) { loc in
            follow(force: loc != nil && lastFollow == .distantPast)
            if !following, resumeFollow == nil { scheduleResume() }
        }
        .onChange(of: following) { _, on in
            resumeFollow?.cancel()
            if on { follow(force: true) }
            else { scheduleResume() }
        }
        .onAppear { follow(force: true) }
        .onDisappear { resumeFollow?.cancel() }
        .onChange(of: map3D) { _, _ in follow(force: true) }
        .onReceive(Timer.publish(every: 1.4, on: .main, in: .common).autoconnect()) { _ in
            guard nav.route != nil else { return }
            withAnimation(.easeInOut(duration: 1.4)) { routeGlow.toggle() }
        }
        .onChange(of: nav.options.count) { _, n in
            if n > 0, let r = nav.options.first?.route {
                following = false
                let rect = r.polyline.boundingMapRect
                withAnimation(.easeInOut(duration: 0.6)) {
                    position = .rect(rect.insetBy(dx: -rect.size.width * 0.15, dy: -rect.size.height * 0.3))
                }
            }
        }
        }
    }

    private func follow(force: Bool = false) {
        guard following else { return }
        guard let c = engine.displayCoordinate else {
            position = .userLocation(followsHeading: true, fallback: .automatic)
            return
        }
        let now = Date()
        guard force || now.timeIntervalSince(lastFollow) > 0.9 else { return }
        lastFollow = now
        let v = engine.speed
        let moving = v > 3 || nav.isNavigating
        let distance = moving ? min(1800, max(380, 280 + v * 36)) : 700
        let center = moving ? Geo.destination(c, bearing: engine.heading, distance: distance * 0.22) : c
        let cam = MapCamera(centerCoordinate: center, distance: distance, heading: engine.heading, pitch: nav.transport == .walking ? 0 : (map3D ? (moving ? 60 : 42) : 0))
        withAnimation(force ? .easeInOut(duration: 0.35) : .linear(duration: 0.9)) { position = .camera(cam) }
    }

    /// After a look around, lock back onto the car while driving or navigating.
    private func scheduleResume() {
        guard nav.options.isEmpty, mapPick == nil else { return }
        guard engine.speed > 2 || nav.isNavigating else { return }
        resumeFollow?.cancel()
        resumeFollow = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, nav.options.isEmpty, mapPick == nil else { return }
            following = true
        }
    }
}

struct DriveView: View {
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var nav: NavigationEngine
    @EnvironmentObject var alerts: AlertCenter
    @EnvironmentObject var ds: DriveSettings
    @EnvironmentObject var traps: TrapStore
    @EnvironmentObject var trips: TripRecorder
    @EnvironmentObject var model: AppModel
    @State private var pendingNavURL: URL?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var following = true
    @State private var selectedOption: UUID?
    @State private var sheet: DriveSheet?
    @State private var showHUD = false
    @State private var showStylePicker = false
    @State private var showMenu = false
    @AppStorage("dr.xpWelcomed") private var xpWelcomed = false
    @AppStorage("dr.sleepMode") private var sleepMode = true
    @State private var showReady = false
    @State private var savedRoute: [MKMapItem]? = ActiveRouteStore.load()
    @State private var resumingRoute = false
    @State private var pendingResume: [MKMapItem]?
    private static var readyShown = false
    @AppStorage("dr.immersive") private var immersive = false
    @AppStorage("dr.nightMode") private var nightMode = "auto"
    private var uiScheme: ColorScheme { NightMode.isActive(nightMode, at: engine.location, navigating: nav.isNavigating) ? .dark : .light }
    @Namespace private var driveNS

    var body: some View {
        ZStack(alignment: .top) {
            DriveMapView(marker: engine.marker, following: $following, selectedOption: $selectedOption)
                .renderWhenSized()
                .environment(\.colorScheme, uiScheme)
                .ignoresSafeArea()

            if nav.isNavigating && immersive {
                DriveModeOverlay(onExit: { withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { immersive = false } },
                                 onEnd: { nav.stop(); following = true })
                    .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                    .environment(\.driveNamespace, driveNS)
                    .environment(\.colorScheme, uiScheme)
                    .autoRerouteBanner()
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.04)), removal: .opacity))
            } else if nav.isNavigating && ds.lightNav {
                LightNavOverlay(onMenu: { showMenu = true },
                                onAddStop: { sheet = .addStop },
                                onMore: { showStylePicker = true },
                                onRouteOptions: { sheet = .routeOptions },
                                onEnd: { nav.stop(); following = true })
                    .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                    .overlay(alignment: .trailing) {
                        WhiteRoundButton(icon: "car.top.radiowaves.rear.right.fill", tint: Theme.accent, size: 48, label: "Drive mode") {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { immersive = true }
                        }
                        .padding(.trailing, Space.m)
                    }
                    .environment(\.colorScheme, uiScheme)
                    .autoRerouteBanner()
                    .transition(.opacity)
            } else if ds.lightNav && !nav.isNavigating {
                LightIdleOverlay(onMenu: { showMenu = true },
                                 onSearch: { sheet = .search },
                                 onStyle: { showStylePicker = true },
                                 onRecenter: { following = true })
                    .environment(\.driveNamespace, driveNS)
                    .environment(\.colorScheme, uiScheme)
                    .autoRerouteBanner()
                    .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                    .transition(.opacity)
                if !nav.options.isEmpty {
                    VStack {
                        Spacer()
                        RouteOptionsPanel(selected: $selectedOption) { opt in
                            nav.start(opt)
                            following = true
                        } onCancel: {
                            nav.clearOptions()
                            following = true
                        }
                    }
                    .padding(.horizontal, Space.m).padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
            VStack(spacing: Space.s) {
                if nav.isNavigating { TurnBanner() }
                if engine.crashSuspected {
                    CrashCard(onClear: { engine.clearCrash() })
                }
                if let a = alerts.current {
                    AlertCard(alert: a)
                        .id(a.key)
                        .transition(.alertSlide(reduceMotion))
                        .onTapGesture { alerts.dismiss() }
                }
                if let f = nav.fasterRoute {
                    FasterRouteCard(option: f)
                }
                if let s = engine.section {
                    SectionChip(section: s)
                }
                topChips
                Spacer()
                HStack(alignment: .bottom) {
                    SpeedCluster()
                    Spacer()
                    sideButtons
                }
                bottomPanel
            }
            .padding(.horizontal, Space.m)
            .padding(.top, Space.s)
            .padding(.bottom, Space.s)
            .animation(Motion.spring(reduceMotion), value: alerts.current?.key)
            .animation(Motion.spring(reduceMotion), value: nav.isNavigating)
            }

            if nav.isNavigating && nav.transport == .walking {
                Label("WALKING MODE", systemImage: "figure.walk")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(LightUI.blue, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.35), lineWidth: 1))
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            SideMenu(isOpen: $showMenu) { a in
                switch a {
                case .profile: sheet = .profile
                case .settings: sheet = .settings
                case .invite: sheet = .invite
                case .cameras: sheet = .cameras
                case .achievements: sheet = .achievements
                case .help: sheet = .help
                }
            }
            .zIndex(5)

            if showReady {
                ReadyBanner()
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { withAnimation(.spring) { showReady = false } }
            }

            if nav.calculating || resumingRoute {
                CalculatingRouteCard()
            }

            if let saved = savedRoute, !nav.isNavigating {
                ContinueRouteCard(name: saved.last?.name ?? "your destination", onCancel: {
                    ActiveRouteStore.clear()
                    withAnimation(.spring) { savedRoute = nil }
                }, onAccept: {
                    withAnimation(.spring) { savedRoute = nil; resumingRoute = true }
                    tryResume(saved)
                })
            }

            if !xpWelcomed {
                XPWelcomeCard { withAnimation(.spring) { xpWelcomed = true } }
                    .transition(.opacity)
            }
        }
        .sheet(item: $sheet) { s in
            Group {
            switch s {
            case .search: WhereToView { opt, item, rest in
                sheet = nil
                selectedOption = nil
                nav.start(opt, to: item, thenStops: rest, transport: nav.transport)
                following = true
            }
            .presentationDragIndicator(.hidden)
            case .nearby: NearbyPlacesView { item in route(to: item) }
            case .report: ReportSheet()
            case .settings: DriveSettingsView()
            case .invite: InviteFriendsView()
            case .profile: ProfileView()
            case .achievements: AchievementsView()
            case .cameras: TrafficCamerasView()
            case .help: HelpView()
            case .addStop: StopPickerView { item in
                sheet = nil
                nav.insertStop(item, from: engine.location)
            }
            case .routeOptions: RouteOptionsScreen { nav.recalculate(from: engine.location) }
            }
            }
            .presentationDetents(s == .report || s == .nearby || s == .addStop || s == .routeOptions ? [.medium, .large] : [.large])
            .presentationCornerRadius(28)
            .presentationBackgroundInteraction(.disabled)
        }
        .sensoryFeedback(.selection, trigger: sheet)
        .fullScreenCover(isPresented: $showHUD) { HUDView() }
        .onReceive(NotificationCenter.default.publisher(for: .radarNavigate)) { n in
            if let u = n.object as? URL { NavLink.pending = nil; handleNavigate(u) }
        }
        .onReceive(engine.$location) { loc in
            if loc != nil, let r = pendingResume { pendingResume = nil; tryResume(r) }
            if loc != nil, let u = pendingNavURL { pendingNavURL = nil; handleNavigate(u) }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: ds.lightNav)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: nav.calculating)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: showMenu)
        .confirmationDialog("Map style", isPresented: $showStylePicker, titleVisibility: .visible) {
            Button(ds.showTraffic ? "Hide traffic" : "Show traffic") { ds.showTraffic.toggle() }
        }
        #if DEBUG
        .task {
            guard let scr = UserDefaults.standard.string(forKey: "screen") else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if scr == "menu" { showMenu = true } else if scr == "style" { showStylePicker = true } else if scr == "hud" { showHUD = true }
            else if let d = DriveSheet(rawValue: scr) { sheet = d }
        }
        #endif
        .onAppear {
            engine.start()
            if let u = NavLink.pending { NavLink.pending = nil; handleNavigate(u) }
            UIApplication.shared.isIdleTimerDisabled = !sleepMode
            if !Self.readyShown {
                Self.readyShown = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) { showReady = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                        withAnimation(.spring(response: 0.5, dampingFraction: 0.9)) { showReady = false }
                    }
                }
            }
        }
    }

    /// radarbot://navigate?q=<query>&via=<road/place>: geocode and start live navigation immediately.
    private func handleNavigate(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let q = items.first(where: { $0.name == "q" })?.value?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return }
        let via = items.first(where: { $0.name == "via" })?.value
        sheet = nil
        savedRoute = nil
        guard let here = engine.routingLocation?.coordinate else {
            pendingNavURL = url
            nav.errorText = "Waiting for GPS…"
            return
        }
        resumingRoute = true
        Task { @MainActor in
            defer { resumingRoute = false }
            guard let dest = await Self.geocode(q, near: here) else { nav.errorText = "Couldn't find \(q)."; return }
            let routes = await Self.directions(from: makeMapItem(here, name: "My location"), to: dest, alternates: true)
            if let via, !via.isEmpty {
                let tokens = Self.viaTokens(via)
                if let match = routes.first(where: { r in Self.routeMentions(r, tokens) }) {
                    startNow(match, to: dest, rest: [])
                    return
                }
                // No alternate uses that road: add a waypoint on it.
                let waypointQuery = tokens.contains("97") ? "Penticton, BC" : via
                if let wp = await Self.geocode(waypointQuery, near: here),
                   let leg = await Self.directions(from: makeMapItem(here, name: "My location"), to: wp, alternates: false).first {
                    startNow(leg, to: wp, rest: [dest])
                    return
                }
            }
            guard let best = routes.min(by: { $0.expectedTravelTime < $1.expectedTravelTime }) else { nav.errorText = "No route to \(q)."; return }
            startNow(best, to: dest, rest: [])
        }
    }

    private func startNow(_ r: MKRoute, to item: MKMapItem, rest: [MKMapItem]) {
        let h = engine.hazardCount(along: Geo.coordinates(of: r.polyline))
        nav.start(RouteOption(route: r, hazards: h, label: ""), to: item, thenStops: rest)
        following = true
    }

    private static func viaTokens(_ via: String) -> [String] {
        let digits = via.filter(\.isNumber)
        return digits.isEmpty ? [via.lowercased()] : [digits]
    }

    private static func routeMentions(_ r: MKRoute, _ tokens: [String]) -> Bool {
        let text = ([r.name] + r.steps.map(\.instructions)).joined(separator: " ").lowercased()
        return tokens.contains { t in
            if t.allSatisfy(\.isNumber) {
                return text.range(of: "(bc-|hwy-?|highway |route |^| )\(t)(\\b|$)", options: .regularExpression) != nil
            }
            return text.contains(t)
        }
    }

    private static func geocode(_ q: String, near c: CLLocationCoordinate2D) async -> MKMapItem? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.region = MKCoordinateRegion(center: c, latitudinalMeters: 600_000, longitudinalMeters: 600_000)
        if let item = (try? await MKLocalSearch(request: req).start())?.mapItems.first {
            if item.name == nil { item.name = q }
            return item
        }
        if let pm = try? await CLGeocoder().geocodeAddressString(q).first, let loc = pm.location {
            return makeMapItem(loc.coordinate, name: pm.locality ?? q)
        }
        return nil
    }

    private static func directions(from a: MKMapItem, to b: MKMapItem, alternates: Bool) async -> [MKRoute] {
        let req = MKDirections.Request()
        req.source = a; req.destination = b
        req.transportType = .automobile
        req.requestsAlternateRoutes = alternates
        req.departureDate = Date()
        req.tollPreference = RoutePrefs.allowTolls ? .any : .avoid
        req.highwayPreference = RoutePrefs.allowMotorways ? .any : .avoid
        return (try? await MKDirections(request: req).calculate())?.routes ?? []
    }

    /// Restart navigation to a saved destination (with any remaining stops).
    private func tryResume(_ targets: [MKMapItem]) {
        guard let first = targets.first else { resumingRoute = false; return }
        guard let here = engine.routingLocation?.coordinate else { pendingResume = targets; return }
        nav.resume(to: first, thenStops: Array(targets.dropFirst()), from: here) { ok in
            resumingRoute = false
            if ok { following = true } else { nav.errorText = "Couldn't resume the route." }
        }
    }

    private func route(to item: MKMapItem) {
        guard let c = engine.routingLocation?.coordinate else {
            nav.errorText = "Waiting for GPS…"
            return
        }
        sheet = nil
        selectedOption = nil
        nav.requestRoutes(to: item, from: c, transport: nav.transport)
    }

    private var topChips: some View {
        HStack(spacing: Space.s) {
            if let h = engine.location.map({ _ in engine.heading }) {
                Label(Geo.compassText(h), systemImage: "location.north.line.fill")
                    .font(Typo.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if let road = engine.roadName, !nav.isNavigating {
                Text(road).font(Typo.caption.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if let parked = traps.parking, let here = engine.location?.coordinate, Geo.distance(parked.coordinate, here) > 80, !nav.isNavigating {
                Button {
                    route(to: makeMapItem(parked.coordinate, name: "Parked car"))
                } label: {
                    Label("Parked car", systemImage: "car.fill")
                        .font(Typo.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Forget parked spot", role: .destructive) { engine.clearParked() }
                }
            }
            if engine.offRoad {
                Label("Off road?", systemImage: "road.lanes")
                    .font(Typo.caption.weight(.semibold))
                    .foregroundStyle(Theme.amber)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
        }
    }

    private var sideButtons: some View {
        VStack(spacing: 10) {
            CircleIconButton(icon: ds.mapStyle.icon) { showStylePicker = true }
            CircleIconButton(icon: ds.mapStyle == .terrain ? "building.2.fill" : "mountain.2.fill") {
                ds.mapStyle = ds.mapStyle == .terrain ? .tesla : .terrain
            }
            CircleIconButton(icon: "gauge.open.with.lines.needle.33percent") { showHUD = true }
            CircleIconButton(icon: "exclamationmark.triangle.fill", tint: Theme.amber) { sheet = .report }
            if !following {
                CircleIconButton(icon: "location.north.line.fill", tint: Theme.accent) { following = true }
            }
        }
    }

    @ViewBuilder
    private var bottomPanel: some View {
        if nav.isNavigating {
            NavigationBottomBar(onEnd: { nav.stop(); following = true })
        } else if !nav.options.isEmpty {
            RouteOptionsPanel(selected: $selectedOption) { opt in
                nav.start(opt)
                following = true
            } onCancel: {
                nav.clearOptions()
                following = true
            }
        } else {
            VStack(spacing: Space.s) {
                if nav.calculating {
                    ProgressView("Finding routes…").font(Typo.caption).frame(maxWidth: .infinity)
                }
                if let e = nav.errorText {
                    Text(e).font(Typo.caption).foregroundStyle(Theme.amber)
                }
                HStack(spacing: Space.s) {
                    Button { sheet = .search } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text("Where to?").foregroundStyle(Theme.secondaryText)
                            Spacer()
                        }
                        .font(Typo.headline)
                        .padding(.horizontal, Space.m)
                        .frame(height: 50)
                        .glassPanel(radius: 28)
                    }
                    .buttonStyle(.plain)
                    CircleIconButton(icon: "line.3.horizontal", size: 50) { showMenu = true }
                    CircleIconButton(icon: "fork.knife", size: 50) { sheet = .nearby }
                    CircleIconButton(icon: "gearshape.fill", size: 50) { sheet = .settings }
                }
                if trips.active {
                    HStack {
                        Label("Trip recording", systemImage: "record.circle").foregroundStyle(Theme.good)
                        Spacer()
                        Text(ds.speedUnits.distance(trips.live.distance)).monospacedDigit()
                        Text("Score \(trips.liveScore)").monospacedDigit().foregroundStyle(Theme.secondaryText)
                    }
                    .font(Typo.caption.weight(.semibold))
                    .padding(.horizontal, 4)
                }
                Text(engine.hazardStatus)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }
}

enum DriveSheet: String, Identifiable {
    case search, nearby, report, settings, invite, profile, achievements, cameras, help, addStop, routeOptions
    var id: String { rawValue }
}

struct CrashCard: View {
    var onClear: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Possible impact").font(Typo.headline)
            Text("A hard jolt was detected. Nothing is called until you tap.")
                .font(Typo.caption)
                .foregroundStyle(Theme.secondaryText)
            HStack {
                Button("Call 911") {
                    if let url = URL(string: "tel:911") { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.mutedRed)
                Button("I'm OK", action: onClear)
                    .buttonStyle(.bordered)
            }
            .font(Typo.caption.weight(.semibold))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.mutedRed.opacity(0.4)))
    }
}

struct SectionChip: View {
    let section: AvgSpeedSection
    @EnvironmentObject var ds: DriveSettings
    var body: some View {
        let avgKmh = section.average * 3.6
        let over = section.limit.map { avgKmh > $0 } ?? false
        HStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(over ? Theme.mutedRed : Theme.amber)
            VStack(alignment: .leading, spacing: 1) {
                Text("Average-speed section").font(Typo.caption.weight(.semibold))
                if section.limit != nil {
                    Text(over ? "Your average is over the limit" : "Your average is under the limit")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(over ? Theme.mutedRed : Theme.good)
                }
            }
            Spacer()
            Text(ds.speedUnits.speedText(section.average)).font(Typo.caption.monospacedDigit().weight(.bold))
            if let l = section.limit { Text("limit \(ds.speedUnits.limit(l).value)").font(Typo.caption).foregroundStyle(Theme.secondaryText) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
    }
}

struct FasterRouteCard: View {
    let option: RouteOption
    @EnvironmentObject var nav: NavigationEngine
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.car.fill").foregroundStyle(Theme.good).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Faster route available").font(Typo.headline)
                Text(option.label).font(Typo.caption).foregroundStyle(.secondary)
            }
            Spacer()
            PillButton(title: "Switch", tint: Theme.good, filled: true) { nav.acceptFasterRoute() }
            Button { nav.dismissFasterRoute() } label: { Image(systemName: "xmark").foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
    }
}

struct NavigationBottomBar: View {
    @EnvironmentObject var nav: NavigationEngine
    @EnvironmentObject var ds: DriveSettings
    var onEnd: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date().addingTimeInterval(nav.remainingTime), style: .time)
                    .font(Typo.number(22, .bold)).foregroundStyle(Theme.goodGradient)
                    .shadow(color: Theme.good.opacity(0.5), radius: 6)
                Text("arrival").font(Typo.label).foregroundStyle(Theme.secondaryText)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(durationText(nav.remainingTime)).font(Typo.number(22, .bold))
                    .contentTransition(.numericText())
                Text(ds.speedUnits.distance(nav.remainingDistance)).font(Typo.label).foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            ShareLink(item: etaText) {
                Image(systemName: "square.and.arrow.up").font(.headline)
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            Button(action: onEnd) {
                Text("End").font(Typo.headline).foregroundStyle(.white)
                    .padding(.horizontal, 20).frame(height: 44)
                    .background(Theme.hotGradient, in: Capsule())
                    .shadow(color: Theme.mutedRed.opacity(0.5), radius: 8)
            }
        }
        .padding(14)
        .overlay(alignment: .top) {
            Capsule().fill(Theme.goodGradient).frame(height: 3).padding(.horizontal, 24).opacity(0.8)
        }
        .glowPanel(Theme.good)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: nav.remainingTime)
    }

    private var etaText: String {
        let df = DateFormatter()
        df.timeStyle = .short
        return "I'm on my way to \(nav.destinationName). ETA \(df.string(from: Date().addingTimeInterval(nav.remainingTime))) (\(durationText(nav.remainingTime)), \(ds.speedUnits.distance(nav.remainingDistance)) to go)."
    }
}

func durationText(_ s: Double) -> String {
    let t = Int(max(s, 0).rounded())
    if t < 60 { return "\(t) s" }
    let m = t / 60
    if m < 60 { return t % 60 == 0 || m >= 10 ? "\(m) min" : "\(m) min \(t % 60) s" }
    return "\(m / 60) h \(m % 60) min"
}

struct RouteOptionsPanel: View {
    @EnvironmentObject var nav: NavigationEngine
    @EnvironmentObject var ds: DriveSettings
    @Binding var selected: UUID?
    var onStart: (RouteOption) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(nav.destinationName).font(Typo.title).lineLimit(1)
                Spacer()
                Button(action: onCancel) { Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary) }
            }
            ForEach(nav.options) { opt in
                let isSel = opt.id == (selected ?? nav.options.first?.id)
                Button { selected = opt.id } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(durationText(opt.route.expectedTravelTime)).font(Typo.number(20, .bold))
                                if !opt.label.isEmpty {
                                    Text(opt.label).font(Typo.label).foregroundStyle(Theme.good)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Theme.good.opacity(0.15), in: Capsule())
                                }
                            }
                            Text("\(ds.speedUnits.distance(opt.route.distance)) · \(opt.route.name)")
                                .font(Typo.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Label("\(opt.hazards)", systemImage: "camera.fill")
                            .font(Typo.caption.monospacedDigit())
                            .foregroundStyle(opt.hazards > 0 ? Theme.amber : .secondary)
                    }
                    .padding(10)
                    .background(isSel ? Theme.accent.opacity(0.14) : Color.white.opacity(0.04),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(isSel ? Theme.accent.opacity(0.5) : .clear))
                }
                .buttonStyle(.plain)
            }
            Button {
                if let o = nav.options.first(where: { $0.id == (selected ?? nav.options.first?.id) }) { onStart(o) }
            } label: {
                Label("Go", systemImage: "location.fill")
                    .font(Typo.headline).foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            }
            .buttonStyle(.plain)
            Text(nav.transport == .walking
                 ? "Walking directions from Apple Maps. Follow pedestrian paths and local crossing signs."
                 : "Camera count = OSM cameras + your reports within 60 m of the route. Traffic-aware ETAs from Apple Maps.")
                .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.secondaryText)
        }
        .padding(14)
        .glassPanel(radius: 28)
    }
}


// MARK: - Smart reroute banner

struct AutoRerouteBanner: View {
    @EnvironmentObject var nav: NavigationEngine
    var body: some View {
        if let a = nav.autoSwitch {
            HStack(spacing: 12) {
                Image(systemName: "bolt.car.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(Theme.goodGradient, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Faster route found").font(Typo.headline).foregroundStyle(Theme.ink)
                    Text("Saves \(a.minutes) min · traffic-aware").font(Typo.caption).foregroundStyle(Theme.inkSecondary)
                }
                Spacer(minLength: 0)
                Button { Haptics.tap(); withAnimation(.spring) { nav.undoAutoSwitch() } } label: {
                    Text("Undo").font(Typo.headline).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 14).frame(height: 36).background(Theme.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(PressableStyle())
            }
            .padding(12)
            .glassPanel(radius: 22)
            .padding(.horizontal, Space.m)
            .id(a.id)
            .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.95)))
            .task(id: a.id) {
                Haptics.success()
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                withAnimation(.spring) { nav.clearAutoSwitch() }
            }
        }
    }
}

extension View {
    func autoRerouteBanner() -> some View {
        overlay(alignment: .center) { AutoRerouteBanner().offset(y: 40) }
    }
}
