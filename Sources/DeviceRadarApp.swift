import SwiftUI

@main
struct DeviceRadarApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.driveSettings)
                .environmentObject(model.traps)
                .environmentObject(model.drive)
                .environmentObject(model.drive.nav)
                .environmentObject(model.drive.alerts)
                .environmentObject(model.drive.trips)
                .preferredColorScheme(AppTheme.scheme)
                .tint(Theme.accent)
                .onAppear {
                    for case let ws as UIWindowScene in UIApplication.shared.connectedScenes {
                        ws.windows.forEach { $0.overrideUserInterfaceStyle = AppTheme.isDark ? .dark : .light }
                    }
                    #if DEBUG
                    if UserDefaults.standard.object(forKey: "tab") != nil { model.selectedTab = UserDefaults.standard.integer(forKey: "tab") }
                    #endif
                    model.start(); _ = Referral.firstLaunch; _ = Referral.code }
                .onOpenURL { url in
                    if url.scheme == "radarbot", url.host == "navigate" {
                        model.selectedTab = 0
                        NavLink.pending = url
                        NotificationCenter.default.post(name: .radarNavigate, object: url)
                    } else {
                        Referral.handle(url)
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let notifier = Notifier()
    let driveSettings = DriveSettings()
    let traps = TrapStore()
    let drive: DriveEngine

    @Published var selectedTab = 0
    private var started = false

    init() {
        drive = DriveEngine(settings: driveSettings, traps: traps)
    }

    func start() {
        guard !started else { return }
        started = true
        notifier.requestAuthorization()
        drive.start()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            drive.enteredBackground()
        case .active:
            drive.enteredForeground()
        default:
            break
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var ds: DriveSettings
    @State private var showSplash = true
    @AppStorage("dr.theme") private var theme = "dark"

    var body: some View {
        ZStack {
        TabView(selection: $model.selectedTab) {
            DriveView()
                .tabItem { Label("Drive", systemImage: "car.fill") }
                .tag(0)
            InsightsView()
                .tabItem { Label("Insights", systemImage: "chart.bar.xaxis") }
                .tag(1)
            DriveSettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(2)
        }
        if showSplash {
            SplashView().transition(.opacity).zIndex(10)
        }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { withAnimation(.easeOut(duration: 0.35)) { showSplash = false } }
        }
        .tint(Theme.accent)
        .preferredColorScheme(theme == "dark" ? .dark : .light)
        .onAppear(perform: Self.styleTabBar)
        .onChange(of: theme) { _, t in
            Self.styleTabBar()
            for case let ws as UIWindowScene in UIApplication.shared.connectedScenes {
                ws.windows.forEach { $0.overrideUserInterfaceStyle = t == "dark" ? .dark : .light }
            }
        }
        .buttonStyle(PressableStyle())
        .fontDesign(.rounded)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: model.selectedTab)
        .sensoryFeedback(.selection, trigger: model.selectedTab)
    }

    private static func styleTabBar() {
        let a = UITabBarAppearance()
        a.configureWithTransparentBackground()
        a.backgroundEffect = nil
        let dark = AppTheme.isDark
        a.backgroundEffect = UIBlurEffect(style: dark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight)
        a.backgroundColor = dark ? UIColor(red: 0.03, green: 0.05, blue: 0.10, alpha: 0.65) : UIColor.white.withAlphaComponent(0.8)
        a.shadowColor = dark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.10)
        let item = UITabBarItemAppearance()
        let dim = dark ? UIColor.white.withAlphaComponent(0.55) : UIColor.black.withAlphaComponent(0.45)
        item.normal.iconColor = dim
        item.normal.titleTextAttributes = [.foregroundColor: dim]
        item.selected.iconColor = UIColor(Theme.accent)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(Theme.accent)]
        a.stackedLayoutAppearance = item
        a.inlineLayoutAppearance = item
        a.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = a
        UITabBar.appearance().scrollEdgeAppearance = a
    }
}


/// Holds a navigate link that arrived before the Drive screen was listening (cold launch).
enum NavLink { @MainActor static var pending: URL? }

extension Notification.Name {
    /// radarbot://navigate?q=<query>[&via=<road or place>]
    static let radarNavigate = Notification.Name("radarbot.navigate")
}
