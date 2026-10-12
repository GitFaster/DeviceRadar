import SwiftUI
import MapKit

/// Instrument-cluster / HUD (items D + 18). Mirror option for windshield reflection, auto-dim at night,
/// tap to show/hide secondary info.
struct HUDView: View {
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var nav: NavigationEngine
    @EnvironmentObject var ds: DriveSettings
    @EnvironmentObject var alerts: AlertCenter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSecondary = true
    var obdRPM: Double? = nil

    private var night: Bool { Geo.isNight(at: engine.location?.coordinate) }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Color.black.ignoresSafeArea()
                Group {
                    if landscape {
                        HStack(spacing: Space.l) {
                            speedBlock(size: min(geo.size.height * 0.85, geo.size.width * 0.42))
                            VStack(spacing: Space.m) { rightColumn }
                                .frame(maxWidth: .infinity)
                        }
                        .padding(Space.l)
                    } else {
                        VStack(spacing: Space.m) {
                            speedBlock(size: min(geo.size.width * 0.86, geo.size.height * 0.45))
                            rightColumn
                            Spacer(minLength: 0)
                        }
                        .padding(Space.m)
                        .padding(.top, Space.l)
                    }
                }
                .scaleEffect(x: ds.hudMirror ? -1 : 1, y: 1)
                .opacity(night ? 0.78 : 1)

                if showSecondary {
                    VStack {
                        HStack {
                            Spacer()
                            HUDMiniMap()
                                .frame(width: landscape ? 150 : 120, height: landscape ? 150 : 120)
                                .clipShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).stroke(Theme.hairline))
                                .opacity(night ? 0.7 : 1)
                        }
                        Spacer()
                        HStack(spacing: Space.s) {
                            PillButton(title: ds.hudMirror ? "Mirrored" : "Mirror", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right") { ds.hudMirror.toggle() }
                            PillButton(title: ds.speedUnits.label, icon: "speedometer") {
                                let all = SpeedUnits.allCases
                                ds.speedUnits = all[((all.firstIndex(of: ds.speedUnits) ?? 0) + 1) % all.count]
                            }
                            Spacer()
                            PillButton(title: "Close", icon: "xmark", tint: .white) { dismiss() }
                        }
                    }
                    .padding(Space.m)
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Motion.spring(reduceMotion)) { showSecondary.toggle() } }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func speedBlock(size: CGFloat) -> some View {
        let s = ds.speedUnits.speed(engine.speed)
        let rpm = obdRPM ?? DriveEngine.estimatedRPM(engine.speed)
        return ZStack {
            TachArc(rpm: rpm, lineWidth: max(10, size * 0.045))
            VStack(spacing: 0) {
                Text(s.value)
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(engine.isSpeeding ? Theme.mutedRed : .white)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5)
                Text(s.unit).font(.system(size: size * 0.07, weight: .semibold, design: .rounded)).foregroundStyle(Theme.secondaryText)
                if let sec = s.secondary {
                    Text(sec).font(.system(size: size * 0.06, weight: .medium, design: .rounded)).foregroundStyle(Theme.secondaryText)
                }
                Text("\(Int(rpm.rounded())) RPM \(obdRPM == nil ? "(est.)" : "")")
                    .font(.system(size: size * 0.045, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 4)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private var rightColumn: some View {
        HStack(alignment: .center, spacing: Space.m) {
            LimitSign(limitKmh: engine.speedLimit, units: ds.speedUnits, speeding: engine.isSpeeding, size: 84)
            if let n = nav.next, let d = nav.distanceToNext {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Image(systemName: n.kind.symbol).font(.system(size: 40, weight: .bold)).foregroundStyle(Theme.accent)
                        Text(ds.speedUnits.distance(d)).font(Typo.number(40, .bold)).foregroundStyle(.white)
                    }
                    Text(n.instruction).font(Typo.headline).foregroundStyle(.white.opacity(0.85)).lineLimit(2)
                    if let t = nav.then {
                        Label("then \(t.kind.shortText)", systemImage: t.kind.symbol)
                            .font(Typo.caption.weight(.semibold)).foregroundStyle(Theme.secondaryText)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Geo.compassText(engine.heading)).font(Typo.number(30, .bold)).foregroundStyle(.white)
                    if let r = engine.roadName { Text(r).font(Typo.headline).foregroundStyle(Theme.secondaryText).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
        }
        if let lanes = engine.lanes, lanes.count > 1 {
            RoadPerspective(lanes: lanes, kind: nav.next?.kind)
                .frame(height: 110)
        }
        if let a = alerts.current {
            AlertCard(alert: a, compact: true)
                .environment(\.colorScheme, .dark)
                .transition(.alertSlide(reduceMotion))
        }
    }
}

struct HUDMiniMap: View {
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var nav: NavigationEngine
    @State private var position: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        Map(position: $position, interactionModes: []) {
            if let r = nav.route {
                MapPolyline(r.polyline).stroke(Theme.accent, lineWidth: 5)
            }
            if let c = engine.displayCoordinate {
                Annotation("", coordinate: c) {
                    Image(systemName: "location.north.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .environment(\.colorScheme, .dark)
        .onReceive(engine.$location) { _ in
            guard let c = engine.displayCoordinate else { return }
            withAnimation(.linear(duration: 0.9)) {
                position = .camera(MapCamera(centerCoordinate: c, distance: 900, heading: engine.heading, pitch: 0))
            }
        }
    }
}
