import AppKit
import SwiftUI
import Observation
import ImageIO
import IOKit.ps
import IOKit.pwr_mgt

struct RGB: Equatable {
    var r: Double, g: Double, b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
    static let dusk = [RGB(r: 0.16, g: 0.10, b: 0.28), RGB(r: 0.55, g: 0.29, b: 0.47), RGB(r: 0.93, g: 0.49, b: 0.32), RGB(r: 0.27, g: 0.39, b: 0.55)]
    static func fallback(for track: TrackIdentity) -> [RGB] {
        guard !track.id.isEmpty else { return dusk }
        let hash = (track.artist + "|" + track.album).utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let hue = Double(hash % 1000) / 1000
        return [0.0, 0.10, 0.26, 0.56].enumerated().map { index, shift in
            let color = NSColor(calibratedHue: (hue + shift).truncatingRemainder(dividingBy: 1), saturation: 0.42, brightness: [0.30, 0.56, 0.78, 0.46][index], alpha: 1).usingColorSpace(.deviceRGB)!
            return RGB(r: color.redComponent, g: color.greenComponent, b: color.blueComponent)
        }
    }
}
enum LayoutMode: String, CaseIterable, Identifiable {
    case editorial = "Editorial", listening = "Escucha", clock = "Reloj"
    var id: String { rawValue }
    var displayName: String { self == .editorial ? "Reloj + música" : (self == .listening ? "Música" : "Reloj") }
    var symbol: String { switch self { case .editorial: return "rectangle.split.2x1"; case .listening: return "music.note"; case .clock: return "clock" } }
}

@MainActor @Observable
final class StandbyModel {
    static let shared = StandbyModel()
    var track = TrackIdentity.empty
    var anchor = PlaybackAnchor()
    var artwork: NSImage?
    var artworkLink: URL?
    var artworkStatus = ""
    var palette = RGB.dusk
    var lines: [LyricLine] = []
    var activeLine: Int?
    var lyricStatus = "La letra se buscará al reproducir una canción."
    var lyricSource = ""
    var connectionStatus = "Conecta Música de este Mac"
    var connected = false
    var demoMode = false
    var isVisible = false
    var onBattery = false
    var lowPower = false
    var hot = false
    var reduceMotion = false
    var reduceTransparency = false
    var screenSleeping = false
    var syncRoundTrip: Double = 0
    var isResynchronizing = true
    var settingsOpen = false
    var automaticActivationStatus = "En espera"
    var autoPausedUntil: Date?
    var shuffleEnabled = false
    var repeatMode = 0
    var playbackOptionsAvailable = false
    var musicShowsLyrics = false {
        didSet { prefs.set(musicShowsLyrics, forKey: "musicShowsLyrics") }
    }
    var clockTypeface: AmbientTypeface = .editorial {
        didSet { prefs.set(clockTypeface.rawValue, forKey: "clockTypeface") }
    }
    var clockWeight: ClockWeight = .ultraLight {
        didSet { prefs.set(clockWeight.rawValue, forKey: "clockWeight") }
    }
    var contentTypeface: AmbientTypeface = .modern {
        didSet { prefs.set(contentTypeface.rawValue, forKey: "contentTypeface") }
    }
    var avoidMedia = true {
        didSet { prefs.set(avoidMedia, forKey: "avoidMedia"); runtime?.rescheduleIdle() }
    }
    var protectBrowsers = true {
        didSet { prefs.set(protectBrowsers, forKey: "protectBrowsers"); runtime?.rescheduleIdle() }
    }
    var automaticSession = false
    var phraseIndex = 0
    var qaClockText: String?
    var currentPhrase: String { MotivationalPhrases.all[phraseIndex] }
    var meshPalette: [RGB] { meshFollowsMusic ? palette : RGB.dusk }
    var layout: LayoutMode = .editorial {
        didSet { prefs.set(layout.rawValue, forKey: "layout"); runtime?.refreshPhrases() }
    }
    var energyMode: EnergyMode = .adaptive {
        didSet { prefs.set(energyMode.rawValue, forKey: "energyMode"); policyChanged() }
    }
    var automaticLyrics = true {
        didSet { prefs.set(automaticLyrics, forKey: "automaticLyrics"); fetchLyrics() }
    }
    var automaticArtwork = true {
        didSet { prefs.set(automaticArtwork, forKey: "automaticArtwork"); artworkTask?.cancel(); artworkTask = nil; if artwork == nil { fetchArtwork() } }
    }
    var meshFollowsMusic = true {
        didSet { prefs.set(meshFollowsMusic, forKey: "meshFollowsMusic") }
    }
    var idleEnabled = true {
        didSet { prefs.set(idleEnabled, forKey: "idleEnabled"); runtime?.rescheduleIdle() }
    }
    var idleMinutes = 5.0 {
        didSet {
            let value = SafePreference.number(idleMinutes, range: 1...120, fallback: 5)
            if !idleMinutes.isFinite || idleMinutes != value { idleMinutes = value; return }
            prefs.set(value, forKey: "idleMinutes"); runtime?.rescheduleIdle()
        }
    }
    var showPhrases = true {
        didSet { prefs.set(showPhrases, forKey: "showPhrases"); runtime?.refreshPhrases() }
    }
    var phraseInterval = 60.0 {
        didSet {
            let value = SafePreference.number(phraseInterval, range: 15...600, fallback: 60)
            if !phraseInterval.isFinite || phraseInterval != value { phraseInterval = value; return }
            prefs.set(value, forKey: "phraseInterval"); runtime?.refreshPhrases()
        }
    }
    var keepAwake = false {
        didSet { prefs.set(keepAwake, forKey: "keepAwake"); updateDisplayAssertion() }
    }
    var twentyFourHour = true {
        didSet { prefs.set(twentyFourHour, forKey: "twentyFourHour") }
    }
    var lyricOffset = 0.0 {
        didSet {
            let value = SafePreference.number(lyricOffset, range: -2...2, fallback: 0)
            if !lyricOffset.isFinite || lyricOffset != value { lyricOffset = value; return }
            prefs.set(value, forKey: "lyricOffset"); updateCue()
        }
    }
    var appearance = "Oscuro" {
        didSet { prefs.set(appearance, forKey: "appearance"); runtime?.applyAppearance() }
    }
    @ObservationIgnored private let prefs = LumaEnvironment.preferences
    @ObservationIgnored private let musicQueue = DispatchQueue(label: "com.kaizentrick.luma.music", qos: .userInitiated)
    @ObservationIgnored private let repository = LyricsRepository()
    @ObservationIgnored private let artworkQueue = DispatchQueue(label: "com.kaizentrick.luma.artwork", qos: .utility)
    @ObservationIgnored private var recovery = PlaybackRecovery()
    @ObservationIgnored private let artworkRepository = ArtworkRepository()
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var cueTimer: Timer?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var pendingMusicHint = false
    @ObservationIgnored private var lastMusicHint: Double = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var lyricsRetryAt = 0.0
    @ObservationIgnored private var artworkRetryAt = 0.0
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var hasAssertion = false
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored weak var runtime: AmbientRuntime?

    var policy: RenderPolicy {
        RenderPolicy(visible: isVisible && !screenSleeping, onBattery: onBattery, lowPower: lowPower, hot: hot, reduceMotion: reduceMotion, mode: energyMode)
    }
    var energyLabel: String {
        if !isVisible || screenSleeping { return "En espera" }
        if lowPower || hot || energyMode == .saver { return "Ahorro activo" }
        if onBattery && policy.framesPerSecond == 0 { return "Batería · fondo estático" }
        return onBattery ? "Batería · malla suave" : "Con corriente · malla fluida"
    }
    var hasTrack: Bool { !track.id.isEmpty }
    var preferredScheme: ColorScheme? { appearance == "Sistema" ? nil : (appearance == "Claro" ? .light : .dark) }
    var effectiveAwake: Bool { keepAwake && isVisible && !screenSleeping && !onBattery && !lowPower && !hot }

    private init() {
        let defaults = LumaEnvironment.preferences
        defaults.register(defaults: ["twentyFourHour": true, "energyMode": "Automático", "appearance": "Oscuro", "automaticArtwork": true,
                                     "meshFollowsMusic": true, "idleEnabled": true, "idleMinutes": 5.0, "showPhrases": true, "phraseInterval": 60.0, "avoidMedia": true, "protectBrowsers": true])
        // One-time migration implements the requested automatic recovery; subsequent opt-outs persist.
        if defaults.integer(forKey: "settingsSchema") < 2 {
            defaults.set(true, forKey: "automaticLyrics")
            defaults.set(true, forKey: "automaticArtwork")
            defaults.set(2, forKey: "settingsSchema")
        }
        automaticLyrics = defaults.bool(forKey: "automaticLyrics")
        automaticArtwork = defaults.bool(forKey: "automaticArtwork")
        meshFollowsMusic = defaults.bool(forKey: "meshFollowsMusic")
        idleEnabled = defaults.bool(forKey: "idleEnabled")
        idleMinutes = SafePreference.number(defaults.double(forKey: "idleMinutes"), range: 1...120, fallback: 5)
        avoidMedia = defaults.bool(forKey: "avoidMedia")
        protectBrowsers = defaults.bool(forKey: "protectBrowsers")
        musicShowsLyrics = defaults.bool(forKey: "musicShowsLyrics")
        clockTypeface = AmbientTypeface(rawValue: defaults.string(forKey: "clockTypeface") ?? "") ?? .editorial
        clockWeight = ClockWeight(rawValue: defaults.string(forKey: "clockWeight") ?? "") ?? .ultraLight
        contentTypeface = AmbientTypeface(rawValue: defaults.string(forKey: "contentTypeface") ?? "") ?? .modern
        showPhrases = defaults.bool(forKey: "showPhrases")
        phraseInterval = SafePreference.number(defaults.double(forKey: "phraseInterval"), range: 15...600, fallback: 60)
        keepAwake = defaults.bool(forKey: "keepAwake")
        twentyFourHour = defaults.bool(forKey: "twentyFourHour")
        lyricOffset = SafePreference.number(defaults.double(forKey: "lyricOffset"), range: -2...2, fallback: 0)
        energyMode = EnergyMode(rawValue: defaults.string(forKey: "energyMode") ?? "") ?? .adaptive
        layout = LayoutMode(rawValue: defaults.string(forKey: "layout") ?? "") ?? .editorial
        appearance = defaults.string(forKey: "appearance") ?? "Oscuro"
    }
    func start() {
        guard !started else { return }; started = true
        installObservers(); refreshPower()
        if ProcessInfo.processInfo.arguments.contains("--demo") || LumaEnvironment.isTesting { useDemo() }
        else if prefs.bool(forKey: "musicEnabled") { connectMusic() }
    }
    func attach(window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        window.identifier = NSUserInterfaceItemIdentifier("oruvi.presentation")
        window.title = "Oruvi"
        window.isMovableByWindowBackground = false
        refreshVisibility()
    }
    func refreshVisibility() {
        let visible = (mainWindow?.isVisible ?? false) && (mainWindow?.occlusionState.contains(.visible) ?? false) && !(mainWindow?.isMiniaturized ?? false) && !NSApp.isHidden && !screenSleeping
        if visible != isVisible { isVisible = visible; policyChanged() }
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
        notificationTokens.append((center, token))
    }
    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter, standard = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observe(standard, name) { [weak self] in self?.refreshVisibility() }
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            observe(workspace, name) { [weak self] in self?.screenSleeping = true; self?.refreshVisibility() }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            observe(workspace, name) { [weak self] in self?.screenSleeping = false; self?.refreshPower(); self?.refreshVisibility() }
        }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in self?.refreshPower() }
        observe(standard, .NSProcessInfoPowerStateDidChange) { [weak self] in self?.refreshPower() }
        observe(standard, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in self?.refreshPower() }
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"] {
            // Best-effort notification hints. Public Apple Events remain the source of truth.
            observe(DistributedNotificationCenter.default(), Notification.Name(name)) { [weak self] in
                guard let self, self.connected, self.policy.visible, !self.demoMode else { return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now - self.lastMusicHint >= 0.25 else { return }
                self.lastMusicHint = now
                if self.reading { self.pendingMusicHint = true } else { self.readMusic() }
            }
        }
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let model = Unmanaged<StandbyModel>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { model.refreshPower() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            powerSource = source; CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
    func refreshPower() {
        var battery = false
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for item in list {
                if let description = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                   let state = description[kIOPSPowerSourceStateKey] as? String, state == kIOPSBatteryPowerValue { battery = true }
            }
        }
        onBattery = battery; lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        hot = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        policyChanged()
    }
    private func policyChanged() {
        pollTimer?.invalidate(); pollTimer = nil
        updateDisplayAssertion(); runtime?.refreshPhrases()
        if policy.visible {
            if connected { refreshPlayback() } else { updateCue() }
        } else {
            generation += 1
            recovery.invalidate(); isResynchronizing = !demoMode
            cueTimer?.invalidate(); cueTimer = nil
            lyricsTask?.cancel(); lyricsTask = nil
            artworkTask?.cancel(); artworkTask = nil
        }
    }
    private func updateDisplayAssertion() {
        if effectiveAwake && !hasAssertion {
            hasAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Oruvi: pantalla ambiental con corriente" as CFString, &assertion) == kIOReturnSuccess
        } else if !effectiveAwake && hasAssertion { IOPMAssertionRelease(assertion); hasAssertion = false }
    }
    /// Every reveal, wake and explicit reconnect requests fresh metadata AND position.
    func refreshPlayback() {
        guard connected, !demoMode, policy.visible else { return }
        generation += 1
        lyricsRetryAt = 0; artworkRetryAt = 0
        recovery.invalidate(); isResynchronizing = true
        cueTimer?.invalidate(); cueTimer = nil
        if reading { pendingMusicHint = true } else { readMusic() }
    }
    func connectMusic() {
        demoMode = false; connected = true
        prefs.set(true, forKey: "musicEnabled")
        connectionStatus = "Conectando con Música…"
        musicQueue.async { LumaResetMusicBridge() }; refreshPlayback()
    }
    func disconnectMusic() {
        generation += 1; connected = false; demoMode = false
        prefs.set(false, forKey: "musicEnabled")
        pollTimer?.invalidate(); pollTimer = nil
        clearTrack(); isResynchronizing = false; connectionStatus = "Música desconectada"
    }
    private func clearTrack() {
        lyricsTask?.cancel(); lyricsTask = nil; artworkTask?.cancel(); artworkTask = nil
        track = .empty; anchor = PlaybackAnchor(); artwork = nil; artworkLink = nil; palette = RGB.dusk
        lyricsRetryAt = 0; artworkRetryAt = 0
        lines = []; activeLine = nil; lyricSource = ""; artworkStatus = ""
        playbackOptionsAvailable = false; shuffleEnabled = false; repeatMode = 0
        lyricStatus = "Elige una canción en Música para empezar."
        cueTimer?.invalidate(); cueTimer = nil
    }
    private func readMusic() {
        guard connected, policy.visible, !reading, !demoMode else { return }
        reading = true; pollTimer?.invalidate(); pollTimer = nil
        let session = generation
        musicQueue.async { [weak self] in
            let snapshot = LumaReadMusicSnapshot()
            DispatchQueue.main.async {
                guard let self else { return }; self.reading = false
                guard session == self.generation, self.connected, self.policy.visible else {
                    if self.connected && self.policy.visible && self.pendingMusicHint {
                        self.pendingMusicHint = false; self.readMusic()
                    } else { self.schedulePoll() }
                    return
                }
                self.apply(snapshot)
                if self.pendingMusicHint { self.pendingMusicHint = false; self.readMusic() } else { self.schedulePoll() }
            }
        }
    }
    func apply(_ snapshot: [String: Any]) {
        let status = snapshot["status"] as? String ?? "error"
        if status == "denied" {
            connected = false; prefs.set(false, forKey: "musicEnabled"); clearTrack()
            connectionStatus = snapshot["message"] as? String ?? "Permiso de Automatización requerido."; return
        }
        if status == "notRunning" {
            clearTrack(); recovery.succeed(at: ProcessInfo.processInfo.systemUptime); isResynchronizing = false
            connectionStatus = "Abre Música en este Mac"; return
        }
        if status == "stopped" {
            if recovery.observeStopped() {
                clearTrack(); recovery.succeed(at: ProcessInfo.processInfo.systemUptime); isResynchronizing = false
                connectionStatus = "Elige una canción en Música"
            } else { isResynchronizing = true; updateCue() }
            return
        }
        guard status == "ok" else {
            // One brief timeout is not a pause or a different recording. Retain a recent cue
            // while retrying, but conceal it during track transitions or a prolonged outage.
            recovery.fail()
            let age = ProcessInfo.processInfo.systemUptime - (recovery.lastSuccess ?? -.greatestFiniteMagnitude)
            isResynchronizing = status == "transition" || age > 3 || !hasTrack
            connectionStatus = snapshot["message"] as? String ?? "Actualizando canción…"
            updateCue(); return
        }
        let next = TrackIdentity(id: snapshot["id"] as? String ?? "", title: snapshot["title"] as? String ?? "Sin título", artist: snapshot["artist"] as? String ?? "", album: snapshot["album"] as? String ?? "", duration: (snapshot["duration"] as? NSNumber)?.doubleValue ?? 0)
        guard next.duration.isFinite, next.duration >= 0, next.duration < 86400 else {
            recovery.fail(); isResynchronizing = true; updateCue(); return
        }
        let changed = !PlaybackRecovery.sameRecording(track, next)
        let sample = (snapshot["sampleUptime"] as? NSNumber)?.doubleValue ?? ProcessInfo.processInfo.systemUptime
        let position = (snapshot["position"] as? NSNumber)?.doubleValue ?? 0
        let playing = (snapshot["playing"] as? NSNumber)?.boolValue ?? false
        guard sample.isFinite, position.isFinite, position >= 0 else {
            recovery.fail(); isResynchronizing = true; updateCue(); return
        }
        // Never clear a valid song for a corrupt/incomplete playback sample.
        if changed {
            lyricsTask?.cancel(); lyricsTask = nil; artworkTask?.cancel(); artworkTask = nil
            lyricsRetryAt = 0; artworkRetryAt = 0
            track = next; artwork = nil; artworkLink = nil
            setPalette(RGB.fallback(for: next)); lines = []; activeLine = nil; lyricSource = ""
        }
        if let shuffle = snapshot["shuffle"] as? NSNumber, let repeated = snapshot["repeatMode"] as? NSNumber {
            shuffleEnabled = shuffle.boolValue; repeatMode = min(2, max(0, repeated.intValue)); playbackOptionsAvailable = true
        }
        let adjusted = changed ? position : PlaybackRecovery.reconciledPosition(position, sampleUptime: sample, previous: anchor, playing: playing)
        anchor = PlaybackAnchor(position: adjusted, uptime: sample, duration: next.duration, playing: playing)
        recovery.succeed(at: sample); isResynchronizing = false
        syncRoundTrip = (snapshot["roundTrip"] as? NSNumber)?.doubleValue ?? 0
        connectionStatus = playing ? "Música · en este Mac" : "Música · en pausa"
        // Missing resources recover without having to close and reopen the app. Cooldowns
        // prevent a failed or unavailable lyric from being requested on every playback tick.
        let now = ProcessInfo.processInfo.systemUptime
        if lines.isEmpty && lyricsTask == nil && now >= lyricsRetryAt { fetchLyrics() }
        if artwork == nil && artworkTask == nil && now >= artworkRetryAt { fetchArtwork() }
        updateCue()
    }
    private func schedulePoll() {
        guard connected, !demoMode, !reading, let normalInterval = policy.pollingInterval(playing: anchor.playing) else { return }
        let interval = recovery.waiting ? recovery.retryInterval : normalInterval
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.readMusic() } }
        timer.tolerance = 0.1; pollTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func control(_ command: String, position: Double = 0) {
        if demoMode {
            let now = ProcessInfo.processInfo.systemUptime, current = anchor.value(at: ProcessInfo.processInfo.systemUptime)
            if command == "toggle" { anchor = PlaybackAnchor(position: current, uptime: now, duration: track.duration, playing: !anchor.playing) }
            else if command == "shuffle" { shuffleEnabled.toggle() }
            else if command == "repeat" { repeatMode = (repeatMode + 1) % 3 }
            else { anchor = PlaybackAnchor(position: command == "seek" && position.isFinite ? max(0, min(track.duration, position)) : 0, uptime: now, duration: track.duration, playing: anchor.playing) }
            updateCue(); return
        }
        guard connected, position.isFinite else { return }
        let session = generation, target = min(max(0, position), track.duration > 0 ? track.duration : max(0, position))
        musicQueue.async { [weak self] in
            let result = LumaMusicCommand(command, target)
            DispatchQueue.main.async {
                guard let self, session == self.generation, self.connected else { return }
                if result["status"] as? String == "ok" {
                    if self.reading { self.pendingMusicHint = true } else { self.readMusic() }
                } else { self.connectionStatus = result["message"] as? String ?? "Abre Música para usar los controles." }
            }
        }
    }
    func fetchLyrics() {
        lyricsTask?.cancel(); lyricsTask = nil
        guard !demoMode, hasTrack, policy.visible, !isResynchronizing else { return }
        lines = []; activeLine = nil; lyricSource = ""
        lyricStatus = automaticLyrics ? "Recuperando letra sincronizada…" : "Buscando tu archivo LRC local…"
        let identity = track, allowed = automaticLyrics
        lyricsRetryAt = ProcessInfo.processInfo.systemUptime + 600
        lyricsTask = Task { [weak self, repository] in
            for delay in [0, 15, 45] {
                do { if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }; try Task.checkCancellation() }
                catch { return }
                let result = await repository.load(for: identity, allowNetwork: allowed)
                guard !Task.isCancelled, let self, self.track == identity, self.automaticLyrics == allowed, self.policy.visible else { return }
                switch result {
                case .available(let payload):
                    self.lines = payload.lines; self.lyricSource = payload.source; self.lyricStatus = ""; self.updateCue(); self.lyricsTask = nil; return
                case .message(let message): self.lyricStatus = message; self.lyricsTask = nil; return
                case .retry(let message): self.lyricStatus = message
                }
            }
            guard !Task.isCancelled, let self, self.track == identity else { return }
            self.lyricStatus = "Letra temporalmente no disponible. Reintentando automáticamente."
            self.lyricsRetryAt = ProcessInfo.processInfo.systemUptime + 30
            self.lyricsTask = nil
        }
    }
    func fetchArtwork() {
        artworkTask?.cancel(); artworkTask = nil
        guard !demoMode, hasTrack, connected, policy.visible, !isResynchronizing else { return }
        let identity = track, allowNetwork = automaticArtwork
        artworkRetryAt = ProcessInfo.processInfo.systemUptime + 60
        artworkStatus = "Recuperando portada…"
        artworkTask = Task { [weak self, artworkRepository] in
            for attempt in 0..<3 {
                do { if attempt > 0 { try await Task.sleep(nanoseconds: attempt == 1 ? 2_000_000_000 : 12_000_000_000) }; try Task.checkCancellation() }
                catch { return }
                guard let self, self.track == identity, self.connected, self.policy.visible else { return }
                let local: (NSImage, [RGB])? = await withCheckedContinuation { continuation in
                    self.artworkQueue.async {
                        let result = LumaReadMusicArtwork(identity.id, identity.title).flatMap(Self.decodeArtwork)
                        continuation.resume(returning: result)
                    }
                }
                guard !Task.isCancelled, self.track == identity, self.policy.visible else { return }
                if let local {
                    self.artwork = local.0; self.setPalette(local.1); self.artworkStatus = "Portada de Música"; self.artworkTask = nil; return
                }
                if attempt >= 1 && allowNetwork {
                    do {
                        if let remote = try await artworkRepository.load(for: identity) {
                            let decoded = await Task.detached(priority: .utility) { Self.decodeArtwork(remote.data) }.value
                            guard !Task.isCancelled, self.track == identity, self.policy.visible, self.automaticArtwork else { return }
                            if let decoded {
                                self.artwork = decoded.0; self.artworkLink = remote.link; self.setPalette(decoded.1)
                                self.artworkStatus = "Portada · catálogo Apple"; self.artworkTask = nil; return
                            }
                        }
                    } catch { if Task.isCancelled { return } }
                }
            }
            guard !Task.isCancelled, let self, self.track == identity else { return }
            self.artworkStatus = "Portada pendiente; se reintentará automáticamente"
            self.artworkRetryAt = ProcessInfo.processInfo.systemUptime + 60; self.artworkTask = nil
        }
    }
    private func setPalette(_ value: [RGB]) {
        withAnimation(reduceMotion || !policy.visible ? nil : .easeInOut(duration: 1.4)) { palette = value }
    }
    private func updateCue() {
        cueTimer?.invalidate(); cueTimer = nil
        guard policy.visible, !isResynchronizing else { return }
        let position = anchor.value(at: ProcessInfo.processInfo.systemUptime) + lyricOffset
        let index = LRCParser.index(at: position, in: lines)
        if activeLine != index { activeLine = index }
        guard anchor.playing, !lines.isEmpty else { return }
        let next = (index ?? -1) + 1
        guard next < lines.count else { return }
        let timer = Timer(timeInterval: max(0.012, lines[next].time - position), repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.updateCue() } }
        timer.tolerance = 0.012; cueTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func importLRC() {
        guard hasTrack, let window = mainWindow else { return }
        if settingsOpen || window.attachedSheet != nil {
            settingsOpen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.mainWindow?.attachedSheet == nil else { return }
                self.importLRC()
            }
            return
        }
        let identity = track, panel = NSOpenPanel()
        panel.title = "Importar letra sincronizada para \(identity.title)"
        panel.allowedContentTypes = [.plainText, .data]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.lyricsTask?.cancel(); self.lyricsTask = nil
            Task {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= LRCParser.maximumBytes else { throw NSError(domain: "Luma", code: 2, userInfo: [NSLocalizedDescriptionKey: "El límite es 512 KB por archivo LRC."]) }
                    let payload = try await self.repository.importLocal(String(contentsOf: url, encoding: .utf8), for: identity)
                    guard self.track == identity else { return }
                    self.lines = payload.lines; self.lyricSource = payload.source; self.lyricStatus = ""; self.updateCue()
                } catch { self.lyricStatus = error.localizedDescription }
            }
        }
    }
    func clearLyricsCache() {
        Task { await repository.clearDownloadedCache(); await artworkRepository.clearCache() }
    }
    func showWindow() { runtime?.activate() }
    func dismissStandby() { runtime?.dismiss() }
    func selectLayout(_ value: LayoutMode) {
        guard layout != value else { return }
        // Crossfades belong to the view container, not every geometry/text change in the app.
        layout = value
    }
    func cycleLayout(_ direction: Int) {
        let modes = LayoutMode.allCases, index = LayoutMode.allCases.firstIndex(of: layout) ?? 0
        selectLayout(modes[(index + direction + modes.count) % modes.count])
    }
    func advancePhrase() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.7)) { phraseIndex = MotivationalPhrases.next(after: phraseIndex, random: Int.random(in: 0...Int.max)) }
    }
    func openMusic() {
        // Activate Music without a content URL, so its current page/album/scroll position remain.
        // Dismissing first restores normal system UI; it never navigates to the catalog link.
        runtime?.dismiss()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async { if error != nil { self?.connectionStatus = "No se pudo abrir Música." } }
        }
    }
    func useDemo() {
        generation += 1; connected = false; demoMode = true; isResynchronizing = false
        playbackOptionsAvailable = true; shuffleEnabled = false; repeatMode = 0
        pollTimer?.invalidate(); pollTimer = nil; lyricsTask?.cancel(); lyricsTask = nil; artworkTask?.cancel(); artworkTask = nil
        track = TrackIdentity(id: "luma-demo", title: "Still, here.", artist: "Oruvi · demostración", album: "Slow mornings", duration: 214)
        anchor = PlaybackAnchor(position: 84, uptime: ProcessInfo.processInfo.systemUptime, duration: 214, playing: true)
        artwork = nil; artworkLink = nil; palette = RGB.dusk
        lines = LRCParser.parse("[00:00.00]Un espacio para bajar el ritmo.\n[00:32.00]La luz se mueve despacio.\n[01:00.00]Deja que el día espere.\n[01:20.00]Quédate en este instante.\n[01:36.00]La música encuentra su lugar.\n[02:00.00]Todo lo demás puede esperar.\n[02:35.00]Respira. Ya estás aquí.\n[03:25.00]")
        lyricSource = "Demostración · texto original, sin audio"; lyricStatus = ""; connectionStatus = "Vista de demostración · sin audio"; updateCue()
    }
    func shutdown() {
        generation += 1; pollTimer?.invalidate(); cueTimer?.invalidate(); lyricsTask?.cancel(); artworkTask?.cancel(); runtime?.stop()
        for (center, token) in notificationTokens { center.removeObserver(token) }; notificationTokens.removeAll()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        if hasAssertion { IOPMAssertionRelease(assertion); hasAssertion = false }
    }
    nonisolated static func decodeArtwork(_ data: Data) -> (NSImage, [RGB])? {
        guard data.count <= 8 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 960, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        var pixels = [UInt8](repeating: 0, count: 24 * 24 * 4)
        let colors: [RGB] = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 96, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return RGB.dusk }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 24, height: 24))
            let pointer = bytes.bindMemory(to: UInt8.self)
            var bins: [Int: (Double, Double, Double, Int)] = [:]
            for index in stride(from: 0, to: pointer.count, by: 4) {
                let r = Double(pointer[index]) / 255, g = Double(pointer[index + 1]) / 255, b = Double(pointer[index + 2]) / 255
                guard pointer[index + 3] > 200, max(r, max(g, b)) > 0.10, min(r, min(g, b)) < 0.94 else { continue }
                let key = (Int(pointer[index]) / 32) * 64 + (Int(pointer[index + 1]) / 32) * 8 + Int(pointer[index + 2]) / 32
                let old = bins[key] ?? (0, 0, 0, 0); bins[key] = (old.0 + r, old.1 + g, old.2 + b, old.3 + 1)
            }
            var result: [RGB] = []
            for bin in bins.sorted(by: { $0.value.3 == $1.value.3 ? $0.key < $1.key : $0.value.3 > $1.value.3 }) {
                let n = Double(bin.value.3), c = RGB(r: bin.value.0 / n, g: bin.value.1 / n, b: bin.value.2 / n)
                if result.allSatisfy({ abs($0.r - c.r) + abs($0.g - c.g) + abs($0.b - c.b) > 0.30 }) { result.append(c) }
                if result.count == 4 { break }
            }
            guard let first = result.first else { return RGB.dusk }
            while result.count < 4 {
                let k = [0.65, 0.85, 1.15, 0.75][result.count]
                result.append(RGB(r: min(0.88, first.r * k + 0.05), g: min(0.88, first.g * k + 0.05), b: min(0.88, first.b * k + 0.05)))
            }
            return result
        }
        return (NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), colors)
    }
}
