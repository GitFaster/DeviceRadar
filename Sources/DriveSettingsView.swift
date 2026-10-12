import SwiftUI
import AVFoundation

struct DriveSettingsView: View {
    @EnvironmentObject var ds: DriveSettings
    @EnvironmentObject var engine: DriveEngine
    @EnvironmentObject var alerts: AlertCenter
    @EnvironmentObject var traps: TrapStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @AppStorage("dr.nightMode") private var nightMode = "auto"
    @AppStorage("dr.theme") private var theme = "dark"

    var body: some View {
        NavigationStack {
            Form {
                Section(header: SettingsHeader(title: "Appearance", icon: "paintpalette.fill")) {
                    Picker(selection: $theme) {
                        Text("Dark (neon)").tag("dark")
                        Text("Light").tag("light")
                    } label: { Label("Theme", systemImage: "circle.lefthalf.filled") }
                    Picker(selection: $nightMode) {
                        ForEach(NightMode.allCases) { Text($0.label).tag($0.rawValue) }
                    } label: { Label("Night driving mode", systemImage: "moon.stars.fill") }
                    NavigationLink { InviteFriendsView().toolbar(.hidden, for: .navigationBar) } label: {
                        Label("Invite your friends", systemImage: "person.2.fill")
                    }
                    NavigationLink { ProfileView() } label: { Label("DriveRadar XP", systemImage: "trophy.fill") }
                }
                Section(header: SettingsHeader(title: "Units", icon: "speedometer")) {
                    Picker("Vehicle", selection: $ds.vehicle) {
                        ForEach(VehicleKind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Speed", selection: $ds.speedUnits) {
                        ForEach(SpeedUnits.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper("Speeding tolerance: +\(Int(ds.speedingTolerance)) km/h", value: $ds.speedingTolerance, in: 0...15)
                    Picker("Your speed alarm", selection: $ds.personalCapKmh) {
                        Text("Off").tag(0.0)
                        ForEach([80.0, 90, 100, 110, 120, 130, 140], id: \.self) { n in
                            Text("\(Int(n)) km/h").tag(n)
                        }
                    }
                }

                Section {
                    Picker("Sounds", selection: $ds.soundMode) {
                        ForEach(SoundMode.allCases) { Text($0.label).tag($0) }
                    }
                    VStack(alignment: .leading) {
                        Text("Chime volume \(Int(ds.chimeVolume * 100))%")
                        Slider(value: $ds.chimeVolume, in: 0.05...1, onEditingChanged: { editing in if !editing { alerts.playChime() } })
                    }
                    Toggle("Haptics", isOn: $ds.hapticsOn)
                    Button("Test alert") {
                        alerts.raise(DriveAlert(key: "test-\(UUID().uuidString)", kind: .camera, title: "Speed camera (test)",
                                                subtitle: "in 350 m · 18 s", distance: 350, startDistance: 500, lifetime: 4),
                                     speech: "Speed camera ahead", notify: false)
                    }
                } header: { SettingsHeader(title: "Alert sounds", icon: "speaker.wave.2.fill") } footer: {
                    Text("One soft chime per event, at most every 20 s per alert type; music ducks while DriveRadar speaks.")
                }

                Section {
                    Picker("Warning distance", selection: $ds.warnReach) {
                        ForEach(WarnReach.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: { Text("How early to warn") } footer: {
                    Text("Far speaks sooner. Motorcycle warns a little earlier than a car, and a truck earlier still, because it needs more room to slow down.")
                }

                SettingsAlertToggles()
                SettingsMapToggles()

                Section {
                    Toggle("Keep running in background", isOn: $ds.backgroundDriving)
                } header: { Text("Background") } footer: {
                    Text("While a trip or route is active, location keeps alerts and voice prompts working with the screen off (uses more battery).")
                }

                Section {
                    LabeledContent("Camera data", value: engine.hazardStatus)
                    LabeledContent("Your reports", value: "\(traps.reports.count)")
                    Button("Delete all my reports", role: .destructive) { confirmClear = true }
                } header: { Text("Data") } footer: {
                    Text("Speed cameras, limits, lanes, schools and crossings come from OpenStreetMap volunteers via the free Overpass API and may be incomplete or out of date. DriveRadar does not detect radar or police — alerts are based on mapped locations and your own reports. Obey posted limits.")
                }
            }
            .scrollContentBackground(.hidden)
            .tint(Theme.accent)
            .environment(\.defaultMinListRowHeight, 48)
            .background(
                ZStack {
                    Theme.background
                    RadialGradient(colors: [Theme.accent.opacity(0.0), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
                    RadialGradient(colors: [Color(hex: 0x7B61FF).opacity(0.0), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 460)
                }.ignoresSafeArea())
            .toolbarBackground(Color.white, for: .navigationBar)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: ds.speedUnits)
            .navigationTitle("Drive settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Delete all reports?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { traps.removeAllReports() }
            }
        }
    }
}

private struct SettingsAlertToggles: View {
    @EnvironmentObject var ds: DriveSettings
    var body: some View {
        Section(header: SettingsHeader(title: "Alerts", icon: "bell.badge.fill")) {
            Toggle("Speed cameras (OpenStreetMap)", isOn: $ds.cameraAlerts)
            Toggle("Speed bumps", isOn: $ds.bumpAlerts)
            Toggle("My trap reports", isOn: $ds.trapAlerts)
            Toggle("Chime when over the posted limit", isOn: $ds.speedingAlerts)
            Toggle("School zones", isOn: $ds.schoolAlerts)
            Toggle("Railway level crossings", isOn: $ds.crossingAlerts)
            Toggle("Off-road drift warning", isOn: $ds.offRoadWarnings)
            Toggle("Weather along the drive", isOn: $ds.weatherAlerts)
            Toggle("Your hotspot reminders", isOn: $ds.hotspotAlerts)
            Toggle("Break reminder after 2 hours", isOn: $ds.fatigueReminder)
            Toggle("Impact check", isOn: $ds.crashDetection)
        }
    }
}

private struct SettingsMapToggles: View {
    @EnvironmentObject var ds: DriveSettings
    @AppStorage("dr.autoFaster") private var autoReroute = true
    var body: some View {
        Section {
            Picker("Map style", selection: $ds.mapStyle) {
                ForEach(MapStyleChoice.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
            }
            Toggle("Show traffic", isOn: $ds.showTraffic)
            Toggle("Reroute when a faster route appears", isOn: $autoReroute)
            Toggle("Auto night map", isOn: $ds.autoNight)
            Toggle("Always dark appearance", isOn: $ds.forceDark)
            Toggle("Prefer routes with fewer traps", isOn: $ds.avoidTraps)
            Toggle("Mirror HUD (windshield)", isOn: $ds.hudMirror)
        } header: { Text("Map & navigation") }
    }
}


/// Section header with a tinted SF Symbol badge.
struct SettingsHeader: View {
    var title: String
    var icon: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22).background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title).font(Typo.footnote.weight(.semibold)).foregroundStyle(Theme.inkSecondary).textCase(nil)
        }
        .padding(.bottom, 2)
    }
}
