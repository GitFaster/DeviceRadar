import Foundation
import AVFoundation
import UIKit
import UserNotifications
import os

// MARK: - Advanced Alert Center

/// Production-oriented alert manager for an iOS driving application.
///
/// Features:
/// - Observable alert cards
/// - Bounded alert history
/// - Per-key duplicate suppression
/// - Per-kind sound cooldowns
/// - Generated in-memory chime
/// - Configurable speech synthesis
/// - Haptic feedback
/// - Background local notifications
/// - Audio-session lifecycle management
/// - Automatic alert dismissal
/// - Expired-key cleanup
/// - Structured diagnostics
///
/// Requires the existing DriveAlert, DriveSettings, and AlertKind models.

@MainActor
final class AlertCenter: NSObject,
                         ObservableObject,
                         AVSpeechSynthesizerDelegate,
                         AVAudioPlayerDelegate {

    /// Audio-session calls can block; keep them off the main thread (serial to preserve ordering).
    private nonisolated static let audioQueue = DispatchQueue(label: "radarbot.audio-session", qos: .userInitiated)

    // MARK: Published State

    @Published private(set) var current: DriveAlert?

    @Published private(set) var recent: [DriveAlert] = []

    @Published private(set) var isSpeaking = false

    @Published private(set) var lastAlertDate: Date?

    // MARK: Configuration

    private let settings: DriveSettings

    private let historyLimit = 30

    private let duplicateWindow: TimeInterval = 30 * 60

    private let soundCooldown: TimeInterval = 20

    private let maximumTrackedKeys = 500

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DriveAlerts",
        category: "AlertCenter"
    )

    // MARK: Audio

    private let synthesizer = AVSpeechSynthesizer()

    private var chimePlayer: AVAudioPlayer?

    private let audioSession = AVAudioSession.sharedInstance()

    private let haptic = UINotificationFeedbackGenerator()

    private var audioSessionActive = false

    private var shouldDeactivateAudioSession = false

    // MARK: Tracking

    private var lastSoundByKind: [AlertKind: Date] = [:]

    private var announcedKeys: [String: Date] = [:]

    private var dismissWork: DispatchWorkItem?

    private var deactivateWork: DispatchWorkItem?

    private var cleanupTimer: Timer?

    private var activeSpeechToken: UUID?

    private var isStoppingSpeech = false

    /// Set this when your app is operating in the background.
    ///
    /// Keep it synchronized with your application's lifecycle.
    var isBackground = false

    // MARK: Initialization

    init(settings: DriveSettings) {
        self.settings = settings

        super.init()

        synthesizer.delegate = self

        configureChime()

        configureAudioNotifications()

        startCleanupTimer()

        haptic.prepare()

        logger.info("AlertCenter initialized")
    }

    deinit {
        dismissWork?.cancel()
        deactivateWork?.cancel()
        cleanupTimer?.invalidate()

        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public Alert API

    /// Raises an alert and optionally announces it.
    ///
    /// - Parameters:
    ///   - alert: The alert to display.
    ///   - speech: Optional spoken announcement.
    ///   - notify: Whether to create a background notification.
    ///   - oncePerKey: Whether to suppress repeat alerts for this key.
    ///
    /// - Returns: True if the alert was accepted.
    ///
    /// All public UI-facing methods execute on the main actor.

    @discardableResult
    func raise(
        _ alert: DriveAlert,
        speech: String? = nil,
        notify: Bool = true,
        oncePerKey: Bool = true
    ) -> Bool {

        let now = Date()

        pruneExpiredKeys(now: now)

        // MARK: Duplicate Protection

        if oncePerKey,
           let previous = announcedKeys[alert.key],
           now.timeIntervalSince(previous) < duplicateWindow {

            // Refresh the active card without generating another event.
            if current?.key == alert.key {
                update(alert)
            }

            logger.debug(
                "Suppressed duplicate alert: \(alert.key, privacy: .private)"
            )

            return false
        }

        // Only record keys when duplicate suppression is enabled.
        if oncePerKey {
            announcedKeys[alert.key] = now
        }

        // MARK: Present Alert

        show(alert)

        lastAlertDate = now

        // MARK: Sound Rate Limiting

        let soundAllowed: Bool

        if let previous = lastSoundByKind[alert.kind] {
            soundAllowed =
                now.timeIntervalSince(previous) >= soundCooldown
        } else {
            soundAllowed = true
        }

        if soundAllowed {

            lastSoundByKind[alert.kind] = now

            if settings.soundMode.chime {
                playChime()
            }

            if settings.soundMode.voice,
               let speech,
               !speech.trimmingCharacters(
                   in: .whitespacesAndNewlines
               ).isEmpty {

                speak(speech)
            }

            if settings.hapticsOn {
                haptic.notificationOccurred(
                    alert.imminent ? .warning : .success
                )

                haptic.prepare()
            }
        }

        // MARK: Background Notification

        if notify && isBackground {
            scheduleNotification(for: alert)
        }

        logger.info(
            "Alert raised: \(alert.key, privacy: .private)"
        )

        return true
    }

    // MARK: - Alert Updates

    /// Updates the active alert without replaying sounds or speech.
    ///
    /// Useful for changing distance, ETA, and proximity information.

    func update(_ alert: DriveAlert) {

        guard var active = current,
              active.key == alert.key else {
            return
        }

        active.distance = alert.distance
        active.subtitle = alert.subtitle
        active.imminent = alert.imminent
        active.title = alert.title

        current = active

        // Keep the corresponding history entry synchronized.
        if let index = recent.firstIndex(
            where: { $0.key == alert.key }
        ) {
            recent[index] = active
        }

        scheduleDismiss(after: alert.lifetime)
    }

    // MARK: - Dismissal

    /// Dismisses the currently displayed alert.

    func dismiss() {

        dismissWork?.cancel()
        dismissWork = nil

        current = nil

        logger.debug("Current alert dismissed")
    }

    /// Dismisses an alert only if its key matches the active card.

    func dismiss(key: String) {

        guard current?.key == key else {
            return
        }

        dismiss()
    }

    /// Allows a previously suppressed key to be announced again.

    func forget(key: String) {

        announcedKeys.removeValue(forKey: key)

        logger.debug(
            "Forgot alert key: \(key, privacy: .private)"
        )
    }

    /// Clears alert history and duplicate tracking.

    func clearHistory() {

        recent.removeAll()

        announcedKeys.removeAll()

        lastSoundByKind.removeAll()

        dismiss()

        logger.info("Alert history cleared")
    }

    // MARK: - Alert Presentation

    private func show(_ alert: DriveAlert) {

        dismissWork?.cancel()

        current = alert

        // Remove the previous occurrence before inserting the newest.
        recent.removeAll { $0.key == alert.key }

        recent.insert(alert, at: 0)

        if recent.count > historyLimit {
            recent = Array(recent.prefix(historyLimit))
        }

        scheduleDismiss(after: alert.lifetime)
    }

    // MARK: - Automatic Dismissal

    private func scheduleDismiss(after seconds: TimeInterval) {

        dismissWork?.cancel()

        guard seconds.isFinite, seconds > 0 else {
            current = nil
            dismissWork = nil
            return
        }

        // Avoid retaining a work item indefinitely.
        let boundedDelay = min(seconds, 300)

        let expectedKey = current?.key

        let work = DispatchWorkItem { [weak self] in

            guard let self else {
                return
            }

            // Do not dismiss a newer alert accidentally.
            guard self.current?.key == expectedKey else {
                return
            }

            self.current = nil
            self.dismissWork = nil
        }

        dismissWork = work

        DispatchQueue.main.asyncAfter(
            deadline: .now() + boundedDelay,
            execute: work
        )
    }

    // MARK: - Key Cleanup

    private func pruneExpiredKeys(now: Date = Date()) {

        announcedKeys = announcedKeys.filter { _, date in
            now.timeIntervalSince(date) < duplicateWindow
        }

        // A safety bound protects against unusually high event volume.
        if announcedKeys.count > maximumTrackedKeys {

            let sorted = announcedKeys.sorted {
                $0.value < $1.value
            }

            let overflow = announcedKeys.count - maximumTrackedKeys

            for entry in sorted.prefix(overflow) {
                announcedKeys.removeValue(forKey: entry.key)
            }
        }

        lastSoundByKind = lastSoundByKind.filter { _, date in
            now.timeIntervalSince(date) < soundCooldown
        }
    }

    private func startCleanupTimer() {

        cleanupTimer?.invalidate()

        cleanupTimer = Timer.scheduledTimer(
            withTimeInterval: 60,
            repeats: true
        ) { [weak self] _ in

            Task { @MainActor [weak self] in
                self?.pruneExpiredKeys()
            }
        }
    }

    // MARK: - Chime Setup

    private func configureChime() {

        do {
            chimePlayer = try AVAudioPlayer(
                data: Self.makeChime()
            )

            chimePlayer?.delegate = self

            chimePlayer?.prepareToPlay()

        } catch {

            logger.error(
                "Chime initialization failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Audio Session

    private func configureAudioNotifications() {

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioInterruptionThunk(_:)),
            name: AVAudioSession.interruptionNotification,
            object: audioSession
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(audioRouteChangeThunk(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: audioSession
        )
    }

    private func activateAudioSession() -> Bool {

        deactivateWork?.cancel()
        deactivateWork = nil

        if !audioSessionActive {
            audioSessionActive = true
            let log = logger
            Self.audioQueue.async { [weak self] in
                do {
                    let session = AVAudioSession.sharedInstance()
                    // Plays over background music: mix + duck, voice-prompt mode.
                    try session.setCategory(.playback, mode: .voicePrompt,
                                            options: [.mixWithOthers, .duckOthers, .interruptSpokenAudioAndMixWithOthers])
                    try session.setActive(true)
                } catch {
                    log.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
                    Task { @MainActor in self?.audioSessionActive = false }
                }
            }
        }
        return true
    }

    private func scheduleAudioDeactivation(
        after seconds: TimeInterval = 0.8
    ) {

        deactivateWork?.cancel()

        let work = DispatchWorkItem { [weak self] in

            guard let self else {
                return
            }

            // Never deactivate audio while another output is active.
            guard !self.synthesizer.isSpeaking,
                  !(self.chimePlayer?.isPlaying ?? false) else {
                return
            }

            self.audioSessionActive = false
            let log = self.logger
            Self.audioQueue.async {
                do {
                    try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                } catch {
                    log.error("Audio deactivation failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        deactivateWork = work

        DispatchQueue.main.asyncAfter(
            deadline: .now() + seconds,
            execute: work
        )
    }

    // MARK: - Play Chime

    func playChime() {

        guard let player = chimePlayer else {
            return
        }

        guard activateAudioSession() else {
            return
        }

        player.volume = Float(
            max(0.05, min(1.0, settings.chimeVolume))
        )

        player.currentTime = 0

        guard player.play() else {

            logger.error("Chime playback could not start")

            scheduleAudioDeactivation()

            return
        }

        shouldDeactivateAudioSession = true
    }

    // MARK: - Chime Completion

    private func chimeDidFinish(_ player: AVAudioPlayer, successfully flag: Bool) {

        guard player === chimePlayer else {
            return
        }

        if !flag {
            logger.warning("Chime playback ended unsuccessfully")
        }

        if shouldDeactivateAudioSession {
            scheduleAudioDeactivation(after: 0.3)
        }
    }

    private func chimeDecodeError(_ error: Error?) {

        logger.error(
            "Chime decoding error: \(error?.localizedDescription ?? "Unknown error", privacy: .public)"
        )

        scheduleAudioDeactivation()
    }

    // MARK: - Speech

    func speak(_ text: String) {

        let cleanedText = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !cleanedText.isEmpty else {
            return
        }

        guard activateAudioSession() else {
            return
        }

        // Stop old speech without allowing its completion callback
        // to deactivate the session needed by the new utterance.
        if synthesizer.isSpeaking {

            isStoppingSpeech = true

            synthesizer.stopSpeaking(at: .immediate)

            isStoppingSpeech = false
        }

        let utterance = AVSpeechUtterance(
            string: cleanedText
        )

        if !settings.voiceIdentifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(
               identifier: settings.voiceIdentifier
           ) {

            utterance.voice = voice

        } else {

            utterance.voice = AVSpeechSynthesisVoice(
                language: AVSpeechSynthesisVoice.currentLanguageCode()
            )
        }

        utterance.rate = min(
            AVSpeechUtteranceMaximumSpeechRate,
            AVSpeechUtteranceDefaultSpeechRate * 1.02
        )

        utterance.preUtteranceDelay =
            settings.soundMode.chime ? 0.35 : 0

        activeSpeechToken = UUID()

        isSpeaking = true

        shouldDeactivateAudioSession = true

        synthesizer.speak(utterance)
    }

    // MARK: - Stop Speech

    func stopSpeech() {

        guard synthesizer.isSpeaking else {
            isSpeaking = false
            return
        }

        isStoppingSpeech = true

        synthesizer.stopSpeaking(at: .immediate)

        isStoppingSpeech = false

        activeSpeechToken = nil

        isSpeaking = false

        scheduleAudioDeactivation(after: 0.4)
    }

    // MARK: - Navigation Prompts

    /// Navigation announcement without creating an alert card.

    func navigationPrompt(_ text: String) {

        if settings.soundMode.voice {

            speak(text)

        } else if settings.soundMode.chime {

            playChime()
        }
    }

    // MARK: - Delegate thunks (callbacks arrive off the main thread)

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speechDidStart() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speechDidFinish() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.speechDidCancel() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let box = UncheckedBox(player)
        Task { @MainActor [weak self] in self?.chimeDidFinish(box.value, successfully: flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let box = UncheckedBox(error)
        Task { @MainActor [weak self] in self?.chimeDecodeError(box.value) }
    }

    // AVAudioSession notifications can be posted on a background thread; hop to main.
    @objc nonisolated private func audioInterruptionThunk(_ n: Notification) {
        let box = UncheckedBox(n)
        Task { @MainActor [weak self] in self?.handleAudioInterruption(box.value) }
    }

    @objc nonisolated private func audioRouteChangeThunk(_ n: Notification) {
        let box = UncheckedBox(n)
        Task { @MainActor [weak self] in self?.handleAudioRouteChange(box.value) }
    }

    // MARK: - Speech Delegate

    private func speechDidStart() {

        isSpeaking = true

        logger.debug("Speech started")
    }

    private func speechDidFinish() {

        guard !isStoppingSpeech else {
            return
        }

        isSpeaking = false

        activeSpeechToken = nil

        if shouldDeactivateAudioSession {
            scheduleAudioDeactivation(after: 0.4)
        }

        logger.debug("Speech finished")
    }

    private func speechDidCancel() {

        guard !isStoppingSpeech else {
            return
        }

        isSpeaking = false

        activeSpeechToken = nil

        if shouldDeactivateAudioSession {
            scheduleAudioDeactivation(after: 0.4)
        }

        logger.debug("Speech cancelled")
    }

    // MARK: - Audio Interruption

    @objc
    private func handleAudioInterruption(
        _ notification: Notification
    ) {

        guard let userInfo = notification.userInfo,
              let rawType = userInfo[
                  AVAudioSessionInterruptionTypeKey
              ] as? UInt,
              let type = AVAudioSession.InterruptionType(
                  rawValue: rawType
              ) else {
            return
        }

        switch type {

        case .began:

            logger.warning("Audio session interrupted")

            chimePlayer?.pause()

            if synthesizer.isSpeaking {

                isStoppingSpeech = true

                synthesizer.stopSpeaking(at: .immediate)

                isStoppingSpeech = false
            }

            isSpeaking = false

            activeSpeechToken = nil

            audioSessionActive = false

        case .ended:

            logger.info("Audio interruption ended")

            // Do not automatically resume an old navigation prompt.
            // A new prompt can activate the session when needed.

        @unknown default:
            break
        }
    }

    // MARK: - Audio Route Changes

    @objc
    private func handleAudioRouteChange(
        _ notification: Notification
    ) {

        guard let userInfo = notification.userInfo,
              let rawReason = userInfo[
                  AVAudioSessionRouteChangeReasonKey
              ] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(
                  rawValue: rawReason
              ) else {
            return
        }

        switch reason {

        case .oldDeviceUnavailable:

            logger.warning(
                "Audio output device disconnected"
            )

            // Avoid unexpectedly restarting sound on a new route.
            chimePlayer?.pause()

        default:
            break
        }
    }

    // MARK: - Local Notifications

    private func scheduleNotification(
        for alert: DriveAlert
    ) {

        let content = UNMutableNotificationContent()

        content.title = alert.title

        content.body = alert.subtitle

        // No notification sound: the in-app alert system owns audio.
        content.sound = nil

        content.threadIdentifier = "drive-alerts"

        content.categoryIdentifier = "DRIVE_ALERT"

        content.userInfo = [
            "alertKey": alert.key,
            "alertKind": String(describing: alert.kind)
        ]

        // A stable identifier replaces an existing pending notification
        // with the same key instead of creating unlimited duplicates.
        let identifier = notificationIdentifier(
            for: alert.key
        )

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) {
            @Sendable [weak self] error in

            guard let error else {
                return
            }

            Task { @MainActor [weak self] in

                self?.logger.error(
                    "Notification scheduling failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func notificationIdentifier(
        for key: String
    ) -> String {

        // Avoid placing arbitrary object identifiers directly
        // into the notification request identifier.
        let encoded = Data(key.utf8).base64EncodedString()

        return "drive-alert-\(encoded)"
    }

    /// Requests notification permission.
    ///
    /// Call this from onboarding or your notification settings screen,
    /// not every time an alert is raised.

    func requestNotificationAuthorization() async -> Bool {

        do {

            let granted = try await
                UNUserNotificationCenter.current()
                    .requestAuthorization(
                        options: [.alert, .badge, .sound]
                    )

            logger.info(
                "Notification authorization: \(granted)"
            )

            return granted

        } catch {

            logger.error(
                "Notification authorization failed: \(error.localizedDescription, privacy: .public)"
            )

            return false
        }
    }

    // MARK: - Generated Chime

    /// Generates a soft two-partial bell as an in-memory WAV.
    ///
    /// No bundled audio file is required.

    private static func makeChime() -> Data {

        let sampleRate = 44_100

        let duration = 0.26

        let sampleCount = Int(
            Double(sampleRate) * duration
        )

        var samples = [Int16](
            repeating: 0,
            count: sampleCount
        )

        for index in 0..<sampleCount {

            let time = Double(index) / Double(sampleRate)

            let attack = min(1.0, time / 0.008)

            let envelope = attack * exp(-time * 14)

            let fundamental =
                0.62 * sin(2 * Double.pi * 880 * time)

            let harmonic =
                0.28 * sin(2 * Double.pi * 1318.5 * time)

            let overtone =
                0.10 * sin(2 * Double.pi * 1760 * time)

            let signal =
                (fundamental + harmonic + overtone)
                * envelope
                * 0.8

            let clipped = max(
                -1.0,
                min(1.0, signal)
            )

            samples[index] = Int16(
                clipped * Double(Int16.max)
            )
        }

        var data = Data()

        func appendLE<T: FixedWidthInteger>(_ value: T) {

            var littleEndian = value.littleEndian

            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }

        // RIFF header
        data.append(contentsOf: Array("RIFF".utf8))

        appendLE(UInt32(36 + sampleCount * 2))

        data.append(contentsOf: Array("WAVE".utf8))

        // PCM format chunk
        data.append(contentsOf: Array("fmt ".utf8))

        appendLE(UInt32(16))             // Chunk size
        appendLE(UInt16(1))              // PCM
        appendLE(UInt16(1))              // Mono
        appendLE(UInt32(sampleRate))     // Sample rate
        appendLE(UInt32(sampleRate * 2)) // Byte rate
        appendLE(UInt16(2))              // Block alignment
        appendLE(UInt16(16))             // Bits per sample

        // Audio data chunk
        data.append(contentsOf: Array("data".utf8))

        appendLE(UInt32(sampleCount * 2))

        for sample in samples {
            appendLE(sample)
        }

        return data
    }
}


/// Carries a non-Sendable delegate argument across to the main actor.
private struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }
