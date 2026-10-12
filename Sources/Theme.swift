import SwiftUI
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// TrapRadar design system: near-black base, layered surfaces, one electric accent.
/// Amber / red are reserved for alerts.
enum Theme {
    // Light reference look: off-white base, white cards with thin dark outlines, blue accent.
    static let accent = dyn(0x1E7BFF, 0x2F8BFF)
    static let blue = dyn(0x1E7BFF, 0x2F8BFF)
    static let background = dyn(0xF4F5F7, 0x060A14)
    static let surface1 = dyn(0xFFFFFF, 0x0B1220)
    static let surface2 = dyn(0xF7F8FA, 0x111A2C)
    static let surface3 = dyn(0xEEF0F3, 0x18233A)
    static let card = dyn(0xFFFFFF, 0x0B1220)
    static let cardStroke = dyn(0x000000, 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.12)
    static let hairline = dyn(0x000000, 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.12)
    static let amber = Color(hex: 0xF5A524)
    static let mutedRed = Color(hex: 0xE5534B)
    static let good = Color(hex: 0x34C77B)
    static let secondaryText = dyn(0x6B7280, 0x8B95AB)

    static var cardGradient: LinearGradient {
        LinearGradient(colors: [Color.white, Color.white], startPoint: .top, endPoint: .bottom)
    }

    /// 0 = cold (blue) ... 1 = hot (red)
    static func heat(_ p: Double) -> Color {
        let c = min(max(p, 0), 1)
        return Color(hue: 0.62 * (1 - c), saturation: 0.85, brightness: 1.0)
    }
}

/// 8-pt spacing grid.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

enum Radius {
    static let s: CGFloat = 10
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 28
}

enum Typo {
    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func number(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
    static let title = Font.system(.title2, design: .rounded).weight(.semibold)
    static let headline = Font.system(.headline, design: .rounded).weight(.semibold)
    static let body = Font.system(.body, design: .rounded)
    static let caption = Font.system(.caption, design: .rounded)
    static let label = Font.system(.caption2, design: .rounded).weight(.semibold)
}

extension Theme {
    static let glowGradient = LinearGradient(colors: [Color(hex: 0x3EA6FF), Color(hex: 0x7B61FF)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let hotGradient = LinearGradient(colors: [Color(hex: 0xFF6B5B), Color(hex: 0xE5304B)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let goodGradient = LinearGradient(colors: [Color(hex: 0x34C77B), Color(hex: 0x3EA6FF)], startPoint: .leading, endPoint: .trailing)
}

/// Dark glass panel with hairline gradient stroke and soft glow.
struct GlowPanel: ViewModifier {
    var glow: Color = Theme.accent
    var radius: CGFloat = Radius.l
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(glow == Theme.accent ? Theme.glassStroke : glow.opacity(0.45), lineWidth: 1))
            .softShadow()
    }
}

extension View {
    func glowPanel(_ glow: Color = Theme.accent, radius: CGFloat = Radius.l) -> some View { modifier(GlowPanel(glow: glow, radius: radius)) }
}

/// Only renders content once it has a real (non-zero) size. Prevents Metal-backed views (Map, glow
/// effects) from encoding into a zero-sized drawable, which trips Metal API Validation.
struct RenderWhenSized<Content: View>: View {
    let content: Content
    var body: some View {
        GeometryReader { g in
            if g.size.width >= 1, g.size.height >= 1 {
                content.frame(width: g.size.width, height: g.size.height)
            } else {
                Color.clear
            }
        }
    }
}

extension View {
    func renderWhenSized() -> some View { RenderWhenSized(content: self) }
}

// MARK: - Premium polish kit

/// Global pressable feel: scale + dim on press, light haptic on release.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: configuration.isPressed) { old, new in old && !new }
    }
}

/// Animated shimmer highlight for loading placeholders.
struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { g in
                    LinearGradient(colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: max(g.size.width * 0.6, 1))
                        .offset(x: phase * max(g.size.width, 1) * 1.6)
                }
                .mask(content)
            }
            .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// Grey placeholder rows with shimmer, shown while a list loads.
struct ShimmerRows: View {
    var count = 5
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 12) {
                    Circle().fill(Color.gray.opacity(0.18)).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.18)).frame(width: 160, height: 12)
                        RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.12)).frame(width: 220, height: 10)
                    }
                    Spacer()
                }
                .padding(.vertical, 12).padding(.horizontal, 16)
            }
        }
        .shimmer()
        .accessibilityLabel("Loading")
    }
}

/// Glass circle with a glossy gradient SF Symbol.
struct GradientIconBadge: View {
    var icon: String
    var size: CGFloat = 84
    var colors: [Color] = [Color(hex: 0x5AA8FF), Color(hex: 0x1A73E8), Color(hex: 0x5B4BFF)]
    var body: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(LinearGradient(colors: [colors[0].opacity(0.16), colors.last!.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().strokeBorder(LinearGradient(colors: [Theme.glassHighlight, Theme.glassStroke], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            Image(systemName: icon)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .center)
                        .mask(Image(systemName: icon).font(.system(size: size * 0.44, weight: .semibold)))
                )
                .shadow(color: colors[1].opacity(0.35), radius: size * 0.08, y: size * 0.04)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
    }
}

/// Empty state: big glass card, gradient badge, bold title, centred hint.
struct EmptyStateView: View {
    var icon: String
    var title: String
    var message: String
    @State private var appear = false
    var body: some View {
        VStack(spacing: 14) {
            GradientIconBadge(icon: icon, size: 92)
                .scaleEffect(appear ? 1 : 0.7)
            Text(title).font(.system(.title3, design: .rounded).weight(.bold)).foregroundStyle(Theme.ink)
            Text(message).font(.system(.subheadline, design: .rounded)).foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28).padding(.vertical, 36)
        .frame(maxWidth: .infinity)
        .glassPanel(radius: Radius.card)
        .padding(8)
        .opacity(appear ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { appear = true } }
    }
}

enum Motion {
    static func spring(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.82)
    }
}

// MARK: - Reusable components

struct GlassCard<Content: View>: View {
    var padding: CGFloat = Space.m
    var radius: CGFloat = Radius.card
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(radius: radius)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var unit: String = ""
    var icon: String = "gauge"
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label(title.uppercased(), systemImage: icon)
                .font(Typo.label)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(Typo.number(24, .bold)).foregroundStyle(Theme.ink).contentTransition(.numericText())
                if !unit.isEmpty { Text(unit).font(Typo.caption).foregroundStyle(Theme.secondaryText) }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }
        .padding(Space.m - 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardGradient, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

struct PillButton: View {
    let title: String
    var icon: String? = nil
    var tint: Color = Theme.accent
    var filled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).symbolRenderingMode(.hierarchical) }
                Text(title).lineLimit(1)
            }
            .font(Typo.headline)
            .padding(.horizontal, Space.m)
            .padding(.vertical, 10)
            .foregroundStyle(filled ? Color.white : tint)
            .background(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.10)), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(filled ? 0 : 0.3), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typo.title).foregroundStyle(Theme.ink)
            if let subtitle { Text(subtitle).font(Typo.caption).foregroundStyle(Theme.secondaryText) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Space.s)
    }
}

struct CircleIconButton: View {
    let icon: String
    var tint: Color = Theme.ink
    var size: CGFloat = 46
    let action: () -> Void
    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(.ultraThinMaterial, in: Circle())
                .background(Color.white.opacity(0.75), in: Circle())
                .overlay(Circle().strokeBorder(Theme.glassStroke, lineWidth: 1))
                .softShadow()
        }
        .buttonStyle(PressableStyle(scale: 0.9))
    }
}


// MARK: - Premium light design tokens (UI refresh)

extension Theme {
    static let ink = dyn(0x111827, 0xF3F4F6)
    static let inkSecondary = dyn(0x6B7280, 0xA1A7B3)
    static let inkTertiary = dyn(0x9CA3AF, 0x6B7280)
    static let canvas = dyn(0xF6F7F9, 0x16203A)
    static let glassHighlight = dyn(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.85, darkAlpha: 0.18)
    static let glassFill = dyn(0xFFFFFF, 0x0B1220, lightAlpha: 0.92, darkAlpha: 0.78)

    /// Light/dark adaptive colour (dark is only used by automatic night driving mode).
    static func dyn(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        #if canImport(UIKit)
        func ui(_ h: UInt32, _ a: CGFloat) -> UIColor {
            UIColor(red: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: a)
        }
        return Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark, darkAlpha) : ui(light, lightAlpha) })
        #else
        return Color(hex: light, opacity: Double(lightAlpha))
        #endif
    }
    static let accentDeep = Color(hex: 0x0B57D0)
    static let glassStroke = dyn(0x000000, 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.10)
    static let accentGradient = LinearGradient(colors: [Color(hex: 0x4C9AFF), Color(hex: 0x1A73E8), Color(hex: 0x0B57D0)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
    static let canvasGradient = LinearGradient(colors: [Color.white, Color(hex: 0xF1F3F6)], startPoint: .top, endPoint: .bottom)
    static let limitRed = Color(hex: 0xE0322B)

    /// Green when within the limit, amber up to 10 % over, red beyond.
    static func speedColor(speedKmh: Double, limitKmh: Double?, speeding: Bool = false) -> Color {
        if speeding { return mutedRed }
        guard let l = limitKmh, l > 0 else { return accent }
        let r = speedKmh / l
        if r <= 1.0 { return good }
        if r <= 1.1 { return amber }
        return mutedRed
    }
}

extension Typo {
    static let largeTitle = Font.system(.largeTitle, design: .rounded).weight(.bold)
    static let title3 = Font.system(.title3, design: .rounded).weight(.semibold)
    static let subheadline = Font.system(.subheadline, design: .rounded)
    static let footnote = Font.system(.footnote, design: .rounded).weight(.medium)
}

extension Radius {
    static let pill: CGFloat = 999
    static let card: CGFloat = 32
}

/// Two-layer soft shadow: tight contact shadow + wide ambient shadow.
struct SoftShadow: ViewModifier {
    var tint: Color = .black
    var strength: Double = 1
    func body(content: Content) -> some View {
        content
            .shadow(color: tint.opacity(0.08 * strength), radius: 2, y: 1)
            .shadow(color: tint.opacity(0.10 * strength), radius: 14, y: 6)
    }
}

/// Frosted glass panel for floating map chrome.
struct GlassPanelModifier: ViewModifier {
    var radius: CGFloat = Radius.card
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .background(Theme.glassFill, in: shape)
            .overlay(shape.strokeBorder(Theme.glassStroke, lineWidth: 0.5))
            .overlay(shape.inset(by: 1).strokeBorder(LinearGradient(colors: [Theme.glassHighlight, Theme.glassHighlight.opacity(0.15)],
                                                                    startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
            .shadow(color: .black.opacity(0.12), radius: 30, y: 14)
    }
}

/// Solid white card with hairline and soft shadow (lists / insights).
struct PremiumCardModifier: ViewModifier {
    var radius: CGFloat = Radius.card
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .modifier(GlassPanelModifier(radius: radius))
    }
}

extension View {
    func softShadow(_ tint: Color = .black, strength: Double = 1) -> some View { modifier(SoftShadow(tint: tint, strength: strength)) }
    func glassPanel(radius: CGFloat = Radius.card) -> some View { modifier(GlassPanelModifier(radius: radius)) }
    func premiumCard(radius: CGFloat = Radius.card) -> some View { modifier(PremiumCardModifier(radius: radius)) }
}

/// Haptics, no-ops on Mac Catalyst.
enum Haptics {
    static func tap() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
    static func success() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
    static func warning() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}

/// Gradient primary capsule (START / GO).
struct PrimaryCapsuleStyle: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(enabled ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.gray.opacity(0.45)), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
            .shadow(color: Theme.accent.opacity(enabled ? 0.35 : 0), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Secondary outlined pill.
struct SecondaryCapsuleStyle: ButtonStyle {
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.headline)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity).frame(height: 52)
            .background(tint.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1.2))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Small info chip (ETA / distance / stops).
struct InfoChip: View {
    var icon: String
    var text: String
    var tint: Color = Theme.accent
    var body: some View {
        Label(text, systemImage: icon)
            .font(Typo.footnote.monospacedDigit())
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.opacity(0.10), in: Capsule())
            .lineLimit(1)
    }
}

/// Animated ring gauge: speed vs. limit, colour shifts green / amber / red.
struct SpeedRingGauge: View {
    var speedKmh: Double
    var limitKmh: Double?
    var speeding: Bool
    var valueText: String
    var unitText: String
    var size: CGFloat = 92
    private let span = 0.75

    var body: some View {
        let maxK = max((limitKmh ?? 100) * 1.4, 60)
        let frac = min(max(speedKmh / maxK, 0), 1)
        let col = Theme.speedColor(speedKmh: speedKmh, limitKmh: limitKmh, speeding: speeding)
        let line = size * 0.085
        ZStack {
            Circle().fill(.ultraThinMaterial)
            Circle().fill(Theme.glassFill)
            Circle().strokeBorder(Theme.glassStroke, lineWidth: 1)
            Group {
                Circle().trim(from: 0, to: span)
                    .stroke(Theme.ink.opacity(0.08), style: StrokeStyle(lineWidth: line, lineCap: .round))
                Circle().trim(from: 0, to: span * max(frac, 0.004))
                    .stroke(AngularGradient(colors: [col.opacity(0.55), col], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * span * max(frac, 0.004))),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                if let l = limitKmh {
                    let lf = min(l / maxK, 1) * span
                    Circle().trim(from: max(lf - 0.005, 0), to: lf + 0.005)
                        .stroke(Theme.ink.opacity(0.75), style: StrokeStyle(lineWidth: line * 1.5, lineCap: .butt))
                }
            }
            .rotationEffect(.degrees(135))
            .padding(line * 0.9)
            VStack(spacing: -3) {
                Text(valueText)
                    .font(.system(size: size * 0.33, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(speeding ? Theme.mutedRed : Theme.ink)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                Text(unitText)
                    .font(.system(size: size * 0.12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: speeding ? Theme.mutedRed.opacity(0.35) : .clear, radius: 12)
        .softShadow()
        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: frac)
        .animation(.easeInOut(duration: 0.35), value: speeding)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: valueText)
    }
}


// MARK: - Automatic night driving mode

enum NightMode: String, CaseIterable, Identifiable {
    case auto, day, night
    var id: String { rawValue }
    var label: String {
        switch self { case .auto: "Auto"; case .day: "Always day"; case .night: "Always night" }
    }
    /// Auto: sunset→sunrise from location+date (Geo.isNight falls back to 19:00–07:00 without a fix),
    /// plus "tunnel" heuristic: navigating and no GPS fix for > 15 s.
    static func isActive(_ raw: String, at loc: CLLocation?, navigating: Bool = false) -> Bool {
        if AppTheme.isDark { return true }
        switch NightMode(rawValue: raw) ?? .auto {
        case .day: return false
        case .night: return true
        case .auto:
            if navigating, let l = loc, Date().timeIntervalSince(l.timestamp) > 15 { return true }
            return Geo.isNight(at: loc?.coordinate)
        }
    }
}


// MARK: - App appearance (dark neon default, light optional)

enum AppTheme {
    static let key = "dr.theme"
    static var isDark: Bool { (UserDefaults.standard.string(forKey: key) ?? "dark") == "dark" }
    static var scheme: ColorScheme { isDark ? .dark : .light }
    static let neon = LinearGradient(colors: [Color(hex: 0x2F8BFF), Color(hex: 0x7B5CFF), Color(hex: 0xB45CFF)], startPoint: .leading, endPoint: .trailing)
    static let gold = LinearGradient(colors: [Color(hex: 0xFFE08A), Color(hex: 0xE8A93B)], startPoint: .top, endPoint: .bottom)
}

struct Hexagon: InsettableShape {
    var inset: CGFloat = 0
    func path(in r: CGRect) -> Path {
        let rr = r.insetBy(dx: inset, dy: inset)
        let c = CGPoint(x: rr.midX, y: rr.midY), rad = min(rr.width, rr.height) / 2
        var p = Path()
        for i in 0..<6 {
            let a = Double(i) * .pi / 3 - .pi / 2
            let pt = CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath(); return p
    }
    func inset(by amount: CGFloat) -> Hexagon { Hexagon(inset: inset + amount) }
}

/// Red glowing hexagon speed-limit sign (dark theme).
struct HexLimitSign: View {
    var text: String
    var size: CGFloat = 54
    var body: some View {
        ZStack {
            Hexagon().fill(Color(hex: 0x120A10))
            Hexagon().strokeBorder(Color(hex: 0xFF3B4A), lineWidth: size * 0.08)
                .shadow(color: Color(hex: 0xFF3B4A).opacity(0.9), radius: 8)
            Text(text).font(.system(size: size * 0.38, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white).contentTransition(.numericText())
        }
        .frame(width: size, height: size)
    }
}

/// Gold "PRO" plate above the gauge.
struct ProBadge: View {
    var body: some View {
        Text("PRO").font(.system(size: 15, weight: .heavy, design: .rounded)).tracking(2)
            .foregroundStyle(AppTheme.gold)
            .padding(.horizontal, 18).frame(height: 28)
            .background(Hexagon().fill(Color(hex: 0x0B1220).opacity(0.85)).scaleEffect(x: 1.9, y: 1))
            .overlay(Hexagon().stroke(Color.white.opacity(0.25), lineWidth: 1).scaleEffect(x: 1.9, y: 1))
    }
}

/// Neon speedometer: outer tick ring, blue→violet glowing arc, gradient numerals.
struct NeonSpeedGauge: View {
    var speedKmh: Double
    var limitKmh: Double?
    var speeding: Bool
    var valueText: String
    var unitText: String
    var size: CGFloat = 150
    private let span = 0.75
    var body: some View {
        let maxK = max((limitKmh ?? 100) * 1.4, 60)
        let frac = min(max(speedKmh / maxK, 0), 1)
        let line = size * 0.055
        let arcColors: [Color] = speeding ? [Color(hex: 0xFF8A5B), Color(hex: 0xFF3B4A)] : [Color(hex: 0x2F8BFF), Color(hex: 0x7B5CFF), Color(hex: 0xC05CFF)]
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(hex: 0x101B33), Color(hex: 0x060A14)], center: .center, startRadius: 0, endRadius: size / 2))
            Circle().strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            ForEach(0..<41) { i in
                Capsule().fill(Color.white.opacity(i % 5 == 0 ? 0.7 : 0.25))
                    .frame(width: i % 5 == 0 ? 2 : 1, height: i % 5 == 0 ? size * 0.06 : size * 0.035)
                    .offset(y: -size * 0.455)
                    .rotationEffect(.degrees(-135 + Double(i) * 270 / 40))
            }
            Group {
                Circle().trim(from: 0, to: span).stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: line, lineCap: .round))
                Circle().trim(from: 0, to: span * max(frac, 0.004))
                    .stroke(AngularGradient(colors: arcColors, center: .center, startAngle: .degrees(0), endAngle: .degrees(270)),
                            style: StrokeStyle(lineWidth: line, lineCap: .round))
                    .shadow(color: arcColors[0].opacity(0.9), radius: 8)
                    .shadow(color: arcColors.last!.opacity(0.6), radius: 14)
            }
            .rotationEffect(.degrees(135))
            .padding(size * 0.13)
            VStack(spacing: -4) {
                Text(valueText)
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(speeding ? AnyShapeStyle(Color(hex: 0xFF3B4A)) : AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x6FB6FF), Color(hex: 0x9B7BFF)], startPoint: .top, endPoint: .bottom)))
                    .shadow(color: Color(hex: 0x2F8BFF).opacity(0.6), radius: 10)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                Text(unitText).font(.system(size: size * 0.09, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color(hex: 0x2F8BFF).opacity(0.25), radius: 20)
        .animation(.spring(response: 0.55, dampingFraction: 0.8), value: frac)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: valueText)
    }
}
