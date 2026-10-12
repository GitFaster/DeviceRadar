// Advanced Drive HUD components — SwiftUI / MapKit
//
// Integration note: this file intentionally reuses the app's existing domain types
// and design system (DriveAlert, DriveEngine, DriveSettings, NavigationEngine,
// SpeedUnits, TurnKind, HazardKind, TrapType, Theme, Typo, Radius, and Color(hex:)).
// Keep those declarations in the host project; this file contains the UI layer.

import SwiftUI

import MapKit

// MARK: - Alert card (item 16)

struct AlertCard: View {

    let alert: DriveAlert

    var compact = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pulse = false

    private var tint: Color { alert.imminent ? Theme.mutedRed : alert.kind.tint }

    var body: some View {

        HStack(spacing: 12) {

            ZStack {

                Circle().fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: tint.opacity(0.4), radius: 6, y: 3)
                Image(systemName: alert.kind.icon)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: compact ? 15 : 18, weight: .bold))
                    .foregroundStyle(.white)

                    .scaleEffect(pulse ? 1.12 : 1)

            }

            .frame(width: compact ? 34 : 42, height: compact ? 34 : 42)

            VStack(alignment: .leading, spacing: 4) {

                Text(alert.title)

                    .font(.system(compact ? .subheadline : .headline, design: .rounded).weight(.semibold))

                    .foregroundStyle(.primary)

                    .lineLimit(1)

                if !alert.subtitle.isEmpty {

                    Text(alert.subtitle)

                        .font(.system(.subheadline, design: .rounded).monospacedDigit())

                        .foregroundStyle(.secondary)

                        .lineLimit(1)

                        .minimumScaleFactor(0.8)

                }

                if let p = alert.progress {

                    GeometryReader { g in

                        ZStack(alignment: .leading) {

                            Capsule().fill(Color.primary.opacity(0.1))

                            Capsule().fill(tint).frame(width: g.size.width * min(max(p, 0), 1))

                        }

                    }

                    .frame(height: 3)

                    .animation(reduceMotion ? nil : .linear(duration: 0.8), value: p)

                }

            }

            Spacer(minLength: 0)

        }

        .padding(.horizontal, 14)

        .padding(.vertical, compact ? 10 : 12)

        .overlay(alignment: .leading) {
            Capsule().fill(tint).frame(width: 4).padding(.vertical, 10).padding(.leading, 5)
        }
        .glassPanel(radius: Radius.card)
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .scale(scale: 0.92)).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.96))))

        .accessibilityElement(children: .combine)

        .onAppear {

            guard !reduceMotion else { return }

            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }

        }

    }

}

extension AnyTransition {

    static func alertSlide(_ reduceMotion: Bool) -> AnyTransition {

        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)

    }

}

// MARK: - Speed limit sign with refined speeding ring

struct LimitSign: View {

    let limitKmh: Double?

    let units: SpeedUnits

    var speeding: Bool

    var size: CGFloat = 64

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var ringPulse = false

    var body: some View {

        ZStack {

            if speeding {

                Circle()

                    .stroke(Theme.mutedRed.opacity(0.85), lineWidth: 3)

                    .frame(width: size + 14, height: size + 14)

                    .scaleEffect(ringPulse ? 1.06 : 1)

                    .opacity(ringPulse ? 0.55 : 1)

            }

            Circle().fill(Color.white)

            Circle().stroke(Color(hex: 0xD0312D), lineWidth: size * 0.11).padding(size * 0.055)

            if let l = limitKmh {

                let t = units.limit(l)

                VStack(spacing: -2) {

                    Text(t.value)

                        .font(.system(size: size * (t.value.count > 2 ? 0.32 : 0.4), weight: .heavy, design: .rounded))

                        .monospacedDigit()

                    if units == .mph { Text("mph").font(.system(size: size * 0.13, weight: .bold, design: .rounded)) }

                }

                .foregroundStyle(.black)

            } else {

                Text("--").font(.system(size: size * 0.32, weight: .heavy, design: .rounded)).foregroundStyle(.gray)

            }

        }

        .frame(width: size, height: size)

        .onAppear { pulseRing(speeding) }

        .onChange(of: speeding) { _, on in pulseRing(on) }

        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limitKmh.map { "Speed limit \(units.limit($0).value)" } ?? "Speed limit unknown")
        .accessibilityValue(speeding ? "Speeding" : "Within speed limit")

    }

    private func pulseRing(_ on: Bool) {

        guard on, !reduceMotion else { ringPulse = false; return }

        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { ringPulse = true }

    }

}

// MARK: - Tachometer arc (estimated unless OBD)

struct TachArc: View {

    let rpm: Double

    var maxRPM: Double = 7000

    var lineWidth: CGFloat = 8

    var body: some View {

        Canvas { ctx, size in
            let safeLineWidth = max(1, lineWidth)
            let safeMaxRPM = max(1, maxRPM)
            let safeRPM = rpm.isFinite ? max(0, rpm) : 0
            let r = min(size.width, size.height) / 2 - safeLineWidth
            guard r > 0 else { return }

            let c = CGPoint(x: size.width / 2, y: size.height / 2)

            let start = Angle.degrees(135), sweep = 270.0

            var track = Path()

            track.addArc(center: c, radius: r, startAngle: start, endAngle: .degrees(135 + sweep), clockwise: false)

            ctx.stroke(track, with: .color(.white.opacity(0.1)), style: StrokeStyle(lineWidth: safeLineWidth, lineCap: .round))

            var red = Path()

            red.addArc(center: c, radius: r, startAngle: .degrees(135 + sweep * min(6000 / safeMaxRPM, 1)), endAngle: .degrees(135 + sweep), clockwise: false)

            ctx.stroke(red, with: .color(Theme.mutedRed.opacity(0.45)), style: StrokeStyle(lineWidth: safeLineWidth, lineCap: .butt))

            let frac = min(max(safeRPM / safeMaxRPM, 0), 1)

            var fill = Path()

            fill.addArc(center: c, radius: r, startAngle: start, endAngle: .degrees(135 + sweep * frac), clockwise: false)

            ctx.stroke(fill, with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0.6), Theme.accent, safeRPM > 6000 ? Theme.mutedRed : Theme.accent]),

                                                   startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: size.width, y: 0)),

                       style: StrokeStyle(lineWidth: safeLineWidth, lineCap: .round))

            for i in 0...7 {

                let a = (135 + sweep * Double(i) * 1000 / safeMaxRPM) * .pi / 180

                let p1 = CGPoint(x: c.x + cos(a) * (r - safeLineWidth), y: c.y + sin(a) * (r - safeLineWidth))

                let p2 = CGPoint(x: c.x + cos(a) * (r - safeLineWidth - 5), y: c.y + sin(a) * (r - safeLineWidth - 5))

                var tick = Path(); tick.move(to: p1); tick.addLine(to: p2)

                ctx.stroke(tick, with: .color(.white.opacity(0.35)), lineWidth: 1.5)

            }

        }

    }

}

// MARK: - Speed cluster (bottom-left on the Drive map)

struct SpeedCluster: View {

    @EnvironmentObject var engine: DriveEngine

    @EnvironmentObject var ds: DriveSettings

    var obdRPM: Double? = nil

    var body: some View {

        let s = ds.speedUnits.speed(engine.speed)

        HStack(spacing: 14) {

            ZStack {

                SpeedGlowArc(fraction: min(engine.speed * 3.6 / 160, 1), hot: engine.isSpeeding)
                    .frame(width: 122, height: 122)
                TachArc(rpm: obdRPM ?? DriveEngine.estimatedRPM(engine.speed), lineWidth: 4)
                    .frame(width: 96, height: 96)
                    .opacity(0.55)

                VStack(spacing: -1) {

                    Text(s.value)

                        .font(Typo.number(46, .bold))

                        .foregroundStyle(engine.isSpeeding ? Theme.mutedRed : .white)
                        .contentTransition(.numericText())
                        .shadow(color: (engine.isSpeeding ? Theme.mutedRed : Theme.accent).opacity(0.6), radius: 10)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: s.value)

                    Text(s.unit).font(Typo.label).foregroundStyle(Theme.secondaryText)

                    if engine.isSpeeding, let over = overLimit {

                        Text(over)

                            .font(Typo.label.weight(.bold))

                            .foregroundStyle(Theme.mutedRed)

                    } else if let sec = s.secondary {

                        Text(sec).font(Typo.label).foregroundStyle(Theme.secondaryText)

                    }

                }

            }

            VStack(spacing: 6) {

                LimitSign(limitKmh: engine.speedLimit, units: ds.speedUnits, speeding: engine.isSpeeding, size: 58)

                if let sec = engine.speedLimit.flatMap({ ds.speedUnits.limit($0).secondary }) {

                    Text(sec).font(Typo.label).foregroundStyle(Theme.secondaryText)

                }

            }

        }

        .padding(12)
        .glowPanel(engine.isSpeeding ? Theme.mutedRed : Theme.accent)
        .animation(.spring(response: 0.45, dampingFraction: 0.75), value: engine.isSpeeding)
        .sensoryFeedback(trigger: engine.isSpeeding) { _, on in on && ds.hapticsOn ? .warning : nil }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Current speed \(s.value) \(s.unit)")
        .accessibilityValue(engine.isSpeeding ? "Above the posted speed limit" : "Speed limit status")

    }

    /// How far over the posted limit, in the units on screen. Nil when not speeding.

    private var overLimit: String? {

        guard engine.isSpeeding, let lim = engine.speedLimit else { return nil }

        let overKmh = engine.speed * 3.6 - lim

        guard overKmh > 0 else { return nil }

        switch ds.speedUnits {

        case .mph:

            return "+\(Int((overKmh / 1.609344).rounded()))"

        case .kmh, .both:

            return "+\(Int(overKmh.rounded()))"

        }

    }

}

// MARK: - Speed glow arc

struct SpeedGlowArc: View {
    var fraction: Double
    var hot: Bool
    @State private var spin = false
    private let span = 0.75
    var body: some View {
        let colors: [Color] = hot ? [Color(hex: 0xFF8A5B), Theme.mutedRed, Color(hex: 0xFF3B6B)]
                                  : [Theme.accent, Color(hex: 0x7B61FF), Theme.good]
        ZStack {
            Circle().trim(from: 0, to: span)
                .stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            Circle().trim(from: 0, to: span * max(0.02, fraction))
                .stroke(AngularGradient(colors: colors + [colors[0]], center: .center,
                                        angle: .degrees(spin ? 360 : 0)),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .shadow(color: (hot ? Theme.mutedRed : Theme.accent).opacity(0.8), radius: 8)
        }
        .rotationEffect(.degrees(135))
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: fraction)
        .animation(.easeInOut(duration: 0.4), value: hot)
        .onAppear { withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = true } }
        .accessibilityHidden(true)
    }
}

struct TurnProgressBar: View {
    var progress: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(Theme.glowGradient)
                    .frame(width: max(6, g.size.width * min(max(progress, 0), 1)))
                    .shadow(color: Theme.accent.opacity(0.7), radius: 5)
            }
        }
        .frame(height: 5)
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: progress)
        .accessibilityHidden(true)
    }
}

// MARK: - Turn banner (items 14 + C)

struct TurnBanner: View {

    @EnvironmentObject var nav: NavigationEngine

    @EnvironmentObject var engine: DriveEngine

    @EnvironmentObject var ds: DriveSettings

    var body: some View {

        if let n = nav.next, let d = nav.distanceToNext {

            VStack(alignment: .leading, spacing: 10) {

                HStack(spacing: 14) {

                    Image(systemName: n.kind.symbol)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 58, height: 58)
                        .background(Theme.glowGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .shadow(color: Theme.accent.opacity(0.55), radius: 10)
                        .contentTransition(.symbolEffect(.replace))

                    VStack(alignment: .leading, spacing: 2) {

                        HStack(alignment: .firstTextBaseline, spacing: 8) {

                            Text(ds.speedUnits.distance(d)).font(Typo.number(30, .bold)).foregroundStyle(.white)
                                .contentTransition(.numericText())

                            if engine.speed.isFinite, engine.speed > 2 {

                                Text("\(Int((d / max(engine.speed, 1)).rounded())) s").font(Typo.number(15)).foregroundStyle(Theme.secondaryText)

                            }

                        }

                        Text(n.instruction).font(Typo.headline).foregroundStyle(.white.opacity(0.9)).lineLimit(2)

                    }

                    Spacer(minLength: 0)

                }

                TurnProgressBar(progress: turnProgress(d))
                if let lanes = engine.lanes, d.isFinite, d >= 0, d < 1500, lanes.count > 1 {

                    LanesView(lanes: lanes, kind: n.kind)

                }

                if let t = nav.then {

                    HStack(spacing: 6) {

                        Text("Then").font(Typo.caption).foregroundStyle(Theme.secondaryText)

                        Image(systemName: t.kind.symbol).font(.caption.weight(.bold))

                        Text(t.kind.shortText).font(Typo.caption.weight(.semibold))

                    }

                    .foregroundStyle(.white)

                    .padding(.horizontal, 10).padding(.vertical, 5)

                    .background(Color.white.opacity(0.08), in: Capsule())

                }

            }

            .padding(14)
            .glowPanel()
            .id(n.index)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: n.index)
            .animation(.smooth(duration: 0.4), value: d)
            .sensoryFeedback(trigger: n.index) { _, _ in ds.hapticsOn ? .impact(weight: .medium) : nil }

        } else if nav.offRoute {
            AlertCard(alert: DriveAlert(key: "reroute", kind: .turn, title: "Rerouting…", subtitle: ""))
        }
    }

    /// Visual-only progress toward the turn over the last 500 m (or 30 s at speed).
    private func turnProgress(_ d: Double) -> Double {
        let window = max(500, engine.speed * 30)
        return 1 - min(d, window) / window
    }

}

enum LaneArrow {

    static func symbol(_ indication: String) -> String {

        switch indication {

        case "left": return "arrow.turn.up.left"

        case "sharp_left": return "arrow.turn.left.down"

        case "slight_left", "merge_to_left": return "arrow.up.left"

        case "right": return "arrow.turn.up.right"

        case "sharp_right": return "arrow.turn.right.down"

        case "slight_right", "merge_to_right": return "arrow.up.right"

        case "reverse": return "arrow.uturn.down"

        default: return "arrow.up"

        }

    }

    static func active(_ lane: [String], kind: TurnKind) -> Bool {

        !kind.laneMatches.isDisjoint(with: lane)

    }

}

struct LanesView: View {

    let lanes: [[String]]

    let kind: TurnKind

    var size: CGFloat = 22

    var body: some View {

        HStack(spacing: 0) {

            ForEach(Array(lanes.enumerated()), id: \.offset) { i, lane in

                let on = LaneArrow.active(lane, kind: kind)

                let ind = lane.first { kind.laneMatches.contains($0) } ?? lane.first ?? "through"

                Image(systemName: LaneArrow.symbol(ind))

                    .font(.system(size: size, weight: .bold))

                    .foregroundStyle(on ? Color.white : Color.white.opacity(0.25))

                    .frame(width: size * 1.7, height: size * 1.6)

                if i < lanes.count - 1 {

                    Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: size * 1.2)

                }

            }

        }

        .padding(.horizontal, 6)

        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lane guidance for the upcoming turn")
        .accessibilityValue("\(lanes.count) lanes")

    }

}

// MARK: - Car marker (item 11)

struct CarMarker: View {
    var rotation: Double
    var accuracy: Double = 10
    var metersPerPoint: Double = 1
    var speed: Double = 0
    var pitch: Double = 0
    @Environment(\.colorScheme) private var scheme
    @State private var pulse = false

    private var dark: Bool { scheme == .dark }
    private var moving: Bool { speed > 1.5 }
    private var glow: Color { dark ? Color(hex: 0x2E8BFF) : Color(hex: 0x5AA9FF) }
    /// Slightly larger when zoomed in / pitched in 3D, smaller when zoomed out.
    private var scale: CGFloat {
        let mpp = metersPerPoint.isFinite ? max(metersPerPoint, 0.05) : 1
        let zoom = min(1.12, max(0.78, 1.05 - log10(mpp) * 0.12))
        let tilt = 1 + min(max(pitch, 0), 70) / 70 * 0.12
        return CGFloat(zoom * tilt)
    }

    var body: some View {
        ZStack {
            // accuracy halo
            Circle().fill(glow.opacity(0.08))
                .overlay(Circle().stroke(glow.opacity(0.22), lineWidth: 1))
                .frame(width: halo, height: halo)
            // pulse ring while moving
            if moving {
                Circle().stroke(glow.opacity(pulse ? 0 : 0.55), lineWidth: 2)
                    .frame(width: pulse ? 76 : 34, height: pulse ? 76 : 34)
                    .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulse)
            }
            Group {
                // headlight cone
                HeadlightCone()
                    .fill(RadialGradient(colors: [Color.white.opacity(dark ? 0.45 : 0.28), .clear],
                                         center: .bottom, startRadius: 2, endRadius: 46))
                    .frame(width: 44, height: 46)
                    .offset(y: -42)
                    .blur(radius: 2.5)
                // neon underglow
                Ellipse().fill(RadialGradient(colors: [glow.opacity(dark ? 0.9 : 0.5), glow.opacity(0)],
                                              center: .center, startRadius: 2, endRadius: 30))
                    .frame(width: 46, height: 62).blur(radius: 6)
                // soft shadow
                CarShape().fill(Color.black.opacity(dark ? 0.5 : 0.3))
                    .frame(width: 24, height: 42).offset(x: 1.5, y: 3).blur(radius: 3)
                // body
                CarShape()
                    .fill(LinearGradient(colors: dark ? [Color(hex: 0x3D7BFF), Color(hex: 0x0F2A6B)]
                                                      : [Color(hex: 0x4F8DFF), Color(hex: 0x1C3F94)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 24, height: 42)
                    .overlay(CarShape().stroke(Color.white.opacity(0.35), lineWidth: 0.7))
                // windshield, roof, rear glass
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(LinearGradient(colors: [Color(hex: 0x9FC6FF).opacity(0.9), Color(hex: 0x0B1626)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 18, height: 8).offset(y: -7)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: 0x14306E)).frame(width: 17, height: 13).offset(y: 3)
                Ellipse().fill(LinearGradient(colors: [Color.white.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
                    .frame(width: 8, height: 10).offset(x: -3, y: 1).blur(radius: 0.8)
                RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0x0B1626)).frame(width: 15, height: 4.5).offset(y: 13)
                // headlights + taillights
                HStack(spacing: 11) { Capsule().fill(Color.white); Capsule().fill(Color.white) }
                    .frame(width: 20, height: 2.2).offset(y: -19.5).shadow(color: .white, radius: 2)
                HStack(spacing: 12) { Capsule().fill(Color.red); Capsule().fill(Color.red) }
                    .frame(width: 20, height: 1.8).offset(y: 20).shadow(color: .red.opacity(0.8), radius: 1.5)
            }
            .rotationEffect(.degrees(rotation))
            .animation(.interpolatingSpring(stiffness: 120, damping: 18), value: rotation)
        }
        .scaleEffect(scale)
        .animation(.easeInOut(duration: 0.3), value: scale)
        .frame(width: 100, height: 100)
        .compositingGroup()
        .onAppear { pulse = true }
        .allowsHitTesting(false)
    }

    private var halo: CGFloat {
        let safeAccuracy = accuracy.isFinite ? max(0, accuracy) : 10
        let safeScale = metersPerPoint.isFinite ? max(metersPerPoint, 0.1) : 1
        return CGFloat(min(80, max(30, safeAccuracy / safeScale * 2)))
    }
}

struct HeadlightCone: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX - 7, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.minY - 8))
        p.addLine(to: CGPoint(x: r.midX + 7, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct CarShape: Shape {

    func path(in r: CGRect) -> Path {

        let w = r.width, h = r.height

        var p = Path()

        p.move(to: CGPoint(x: w * 0.5, y: 0))

        p.addCurve(to: CGPoint(x: w, y: h * 0.22), control1: CGPoint(x: w * 0.85, y: 0), control2: CGPoint(x: w, y: h * 0.08))

        p.addLine(to: CGPoint(x: w, y: h * 0.86))

        p.addQuadCurve(to: CGPoint(x: w * 0.78, y: h), control: CGPoint(x: w, y: h))

        p.addLine(to: CGPoint(x: w * 0.22, y: h))

        p.addQuadCurve(to: CGPoint(x: 0, y: h * 0.86), control: CGPoint(x: 0, y: h))

        p.addLine(to: CGPoint(x: 0, y: h * 0.22))

        p.addCurve(to: CGPoint(x: w * 0.5, y: 0), control1: CGPoint(x: 0, y: h * 0.08), control2: CGPoint(x: w * 0.15, y: 0))

        p.closeSubpath()

        return p

    }

}

struct HazardPin: View {

    let kind: HazardKind

    private var icon: String {

        switch kind {

        case .camera: return "camera.fill"

        case .avgSpeed: return "gauge.with.dots.needle.33percent"

        case .redLight: return "light.beacon.max.fill"

        case .school: return "figure.and.child.holdinghands"

        case .crossing: return "tram.fill"

        case .bump: return "triangle.fill"

        }

    }

    private var tint: Color {

        switch kind {

        case .camera, .avgSpeed, .redLight: return Theme.amber

        case .school: return Color.yellow

        case .crossing: return Color.white

        case .bump: return Theme.amber

        }

    }

    var body: some View {

        Image(systemName: icon)

            .font(.system(size: 11, weight: .bold))

            .foregroundStyle(.black)

            .frame(width: 24, height: 24)

            .background(tint, in: Circle())

            .overlay(Circle().stroke(Color.black.opacity(0.4), lineWidth: 1))

            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)

    }

}

struct ReportPin: View {

    let type: TrapType

    var body: some View {

        Image(systemName: type.icon)

            .font(.system(size: 11, weight: .bold))

            .foregroundStyle(.white)

            .frame(width: 26, height: 26)

            .background(Theme.mutedRed.opacity(0.9), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.6), lineWidth: 1))

    }

}

// MARK: - Stylised road perspective with lane arrows (HUD)

struct RoadPerspective: View {

    let lanes: [[String]]

    let kind: TurnKind?

    var body: some View {

        GeometryReader { g in

            let w = g.size.width, h = g.size.height

            let n = max(lanes.count, 1)

            ZStack {

                Canvas { ctx, size in

                    let topW = w * 0.28, botW = w * 0.96

                    let tl = CGPoint(x: (w - topW) / 2, y: 0), tr = CGPoint(x: (w + topW) / 2, y: 0)

                    let bl = CGPoint(x: (w - botW) / 2, y: h), br = CGPoint(x: (w + botW) / 2, y: h)

                    var road = Path()

                    road.move(to: tl); road.addLine(to: tr); road.addLine(to: br); road.addLine(to: bl); road.closeSubpath()

                    ctx.fill(road, with: .linearGradient(Gradient(colors: [Color.white.opacity(0.02), Color.white.opacity(0.1)]),

                                                         startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))

                    for i in 0...n {

                        let t = CGFloat(i) / CGFloat(n)

                        var line = Path()

                        line.move(to: CGPoint(x: tl.x + topW * t, y: 0))

                        line.addLine(to: CGPoint(x: bl.x + botW * t, y: h))

                        let edge = i == 0 || i == n

                        ctx.stroke(line, with: .color(.white.opacity(edge ? 0.7 : 0.35)),

                                   style: StrokeStyle(lineWidth: edge ? 2.5 : 2, dash: edge ? [] : [10, 10]))

                    }

                }

                HStack(spacing: 0) {

                    ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in

                        let on = kind.map { LaneArrow.active(lane, kind: $0) } ?? true

                        let ind = kind.flatMap { k in lane.first { k.laneMatches.contains($0) } } ?? lane.first ?? "through"

                        Image(systemName: LaneArrow.symbol(ind))

                            .font(.system(size: min(44, w * 0.9 / CGFloat(n) * 0.5), weight: .heavy))

                            .foregroundStyle(on ? Theme.accent : Color.white.opacity(0.2))

                            .frame(maxWidth: .infinity)

                    }

                }

                .frame(width: w * 0.86)

                .offset(y: h * 0.22)

            }

        }

    }

}
