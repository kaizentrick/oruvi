import AppKit
import SwiftUI
import Observation
import ImageIO
import IOKit.ps
import IOKit.pwr_mgt
import os

struct RGB: Equatable {
    var r: Double, g: Double, b: Double
    var color: Color { Color(red: r, green: g, blue: b) }
    static let dusk = [RGB(r: 0.16, g: 0.10, b: 0.28), RGB(r: 0.55, g: 0.29, b: 0.47), RGB(r: 0.93, g: 0.49, b: 0.32), RGB(r: 0.27, g: 0.39, b: 0.55)]
    static func fallback(for track: TrackIdentity) -> [RGB] {
        guard !track.id.isEmpty else { return aurora }
        let hash = (track.artist + "|" + track.album + "|" + track.title).utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
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
    var anchor = PlaybackAnchor() {
        didSet {
            if anchor.playing != oldValue.playing { playbackIsPlaying = anchor.playing }
        }
    }
    private(set) var playbackIsPlaying = false
    var artwork: NSImage?
    var artworkLink: URL?
    var artworkStatus = ""
    private(set) var cacheClearStatus = ""
    private(set) var isClearingDownloadCache = false
    var palette = RGB.aurora
    var lines: [LyricLine] = []
    var activeLine: Int?
    var lyricSource = ""
    var lyricsAvailability: LyricsAvailability = .idle
    var toastMessage: String?
    var activePlayer: PlayerSource = .music
    private var playerSelections = SurfacePlaybackPreferences(defaults: LumaEnvironment.preferences)
    private(set) var playbackSurface: PlaybackSurface = .notch
    @ObservationIgnored private var lastSurfacePlayers: [PlaybackSurface: PlayerSource] = [:]
    /// Existing settings bind to Standby only. The notch has a separate persisted key.
    var playerPreference: PlayerPreference {
        get { playerSelections.standby }
        set { setPlayerPreference(newValue, for: .standby) }
    }
    var notchPlayerPreference: PlayerPreference {
        get { playerSelections.notch }
        set { setPlayerPreference(newValue, for: .notch) }
    }
    var effectivePlayerPreference: PlayerPreference { playerSelections.preference(for: playbackSurface) }
    private func setPlayerPreference(_ value: PlayerPreference, for surface: PlaybackSurface) {
        guard playerSelections.preference(for: surface) != value else { return }
        playerSelections.set(value, for: surface, defaults: prefs)
        guard started, playbackSurface == surface else { return }
        invalidatePlaybackRequests(); clearTrack()
        activePlayer = value.source ?? lastSurfacePlayers[surface] ?? .music
        connectMusic()
    }
    /// Returns whether the new surface requires a different playback session.
    private func updatePlaybackSurface() -> Bool {
        let next: PlaybackSurface = isVisible ? .standby : .notch
        guard next != playbackSurface else { return false }
        lastSurfacePlayers[playbackSurface] = activePlayer
        let previousPreference = effectivePlayerPreference
        playbackSurface = next
        guard !demoMode else { return false }
        let nextConnected = prefs.bool(forKey: next.enabledKey)
        if connected && nextConnected && previousPreference == effectivePlayerPreference { return false }
        invalidatePlaybackRequests()
        clearTrack()
        activePlayer = effectivePlayerPreference.source ?? lastSurfacePlayers[next] ?? .music
        connected = nextConnected
        connectionStatus = connected ? "Actualizando reproductor de " + next.title + "…" : "Conecta el reproductor de " + next.title
        return true
    }
    var notchEnabled = true {
        didSet { prefs.set(notchEnabled, forKey: "notchEnabled"); notch?.reconcile() }
    }
    private(set) var nativeWidgetInUse = false
    var systemProhibitsSkip = false
    func setNativeWidgetPresence(_ present: Bool) {
        guard nativeWidgetInUse != present else { return }
        nativeWidgetInUse = present
        if started { policyChanged() }
    }
    private(set) var activeSystemBundleID = ""
    @ObservationIgnored private var systemArtworkData: Data?
    @ObservationIgnored private var appliedSystemArtwork: Data?
    @ObservationIgnored private var retainedArtwork: (track: TrackIdentity, image: NSImage, palette: [RGB], link: URL?, systemData: Data?, spotifyURL: String?)?
    var notchVisible = false
    var notchExpanded = false {
        didSet {
            guard started, oldValue != notchExpanded else { return }
            updateLyricsVisibility()
        }
    }
    @ObservationIgnored private var playerArtworkURL = ""
    var meshTheme: MeshTheme = .aurora {
        didSet { prefs.set(meshTheme.rawValue, forKey: "meshTheme") }
    }
    var hasLyrics: Bool { hasTrack && !lines.isEmpty }
    var visibleLyrics: Bool { musicShowsLyrics && hasLyrics }
    private var standbyCanShowLyrics: Bool { isVisible && layout != .clock }
    private var notchCanShowLyrics: Bool { notchVisible && notchExpanded }
    private var lyricsLookupVisible: Bool { (standbyCanShowLyrics || notchCanShowLyrics) && !screenSleeping }
    private var lyricsSurfaceVisible: Bool { ((standbyCanShowLyrics && visibleLyrics) || notchCanShowLyrics) && !screenSleeping }
    var currentLyricText: String? {
        guard !isResynchronizing, let activeLine, lines.indices.contains(activeLine) else { return nil }
        let text = lines[activeLine].text
        return text.isEmpty ? nil : text
    }
    var needsPlayback: Bool { (isVisible || notchVisible || nativeWidgetInUse) && !screenSleeping }
    var connectionStatus = "Conecta Música de este Mac"
    var connected = false
    var demoMode = false
    var isVisible = false
    var onBattery = false
    var lowPower = false
    var hot = false
    var reduceMotion = false
    var reduceTransparency = false
    enum SleepSource: Hashable { case system, display }
    @ObservationIgnored private var sleepingSources: Set<SleepSource> = []
    private(set) var screenSleeping = false {
        didSet { if started && oldValue != screenSleeping { policyChanged() } }
    }
    private(set) var playbackReadMilliseconds: Int?
    var settingsOpen = false
    var settingsSection: SettingsSection = .typography
    var isResynchronizing = true
    var automaticActivationStatus = "En espera"
    var autoPausedUntil: Date?
    var shuffleEnabled = false
    var repeatMode = 0
    var playbackOptionsAvailable = false
    var musicShowsLyrics = false {
        didSet { prefs.set(musicShowsLyrics, forKey: "musicShowsLyrics"); updateLyricsVisibility() }
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
    var lyricTypefaceOverride: AmbientTypeface? {
        didSet { prefs.set(lyricTypefaceOverride?.rawValue, forKey: "lyricTypeface") }
    }
    var lyricTypeface: AmbientTypeface { lyricTypefaceOverride ?? contentTypeface }
    var lyricSizePercent = LyricTypography.defaultSize {
        didSet {
            let value = SafePreference.number(lyricSizePercent, range: LyricTypography.sizeRange, fallback: LyricTypography.defaultSize)
            if !lyricSizePercent.isFinite || lyricSizePercent != value { lyricSizePercent = value; return }
            prefs.set(value, forKey: "lyricSizePercent")
        }
    }
    var avoidMedia = true {
        didSet { prefs.set(avoidMedia, forKey: "avoidMedia"); runtime?.rescheduleIdle() }
    }
    var protectBrowsers = true {
        didSet { prefs.set(protectBrowsers, forKey: "protectBrowsers"); runtime?.rescheduleIdle() }
    }
    var automaticSession = false
    var phraseIndex = 0
    var currentPhrase: String { MotivationalPhrases.all[phraseIndex] }
    var meshPalette: [RGB] { meshFollowsMusic && hasTrack ? palette : meshTheme.palette }
    var layout: LayoutMode = .editorial {
        didSet { prefs.set(layout.rawValue, forKey: "layout"); runtime?.refreshPhrases(); updateLyricsVisibility() }
    }
    var energyMode: EnergyMode = .adaptive {
        didSet { prefs.set(energyMode.rawValue, forKey: "energyMode"); policyChanged() }
    }
    var automaticLyrics = true {
        didSet { prefs.set(automaticLyrics, forKey: "automaticLyrics"); fetchLyrics() }
    }
    var automaticArtwork = true {
        didSet {
            prefs.set(automaticArtwork, forKey: "automaticArtwork")
            guard oldValue != automaticArtwork, activePlayer == .music else { return }
            artworkTask?.cancel(); artworkTask = nil
            if artwork == nil { fetchArtwork() }
        }
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
    @ObservationIgnored private let playerRouter = PlayerRouter()
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private let artworkQueue = DispatchQueue(label: "com.kaizentrick.luma.artwork", qos: .utility)
    @ObservationIgnored private var recovery = PlaybackRecovery()
    @ObservationIgnored private let artworkRepository: ArtworkRepository
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var scheduledPollInterval = 0.0
    @ObservationIgnored private var cueTimer: Timer?
    @ObservationIgnored private var cueDeadline: TimeInterval?
    #if LUMA_QA
    var scheduledLyricCue: Timer? { cueTimer }
    #endif
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    @ObservationIgnored private let playbackGeneration = OSAllocatedUnfairLock(initialState: 0)
    private var generation: Int { playbackGeneration.withLock { $0 } }
    private func invalidatePlaybackRequests() { playbackGeneration.withLock { $0 += 1 } }
    @ObservationIgnored private var lastAppliedSnapshotSequence: UInt64 = 0
    @ObservationIgnored private var lastPlaybackDemand = false
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
    @ObservationIgnored weak var notch: NotchController?

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
    var canSkip: Bool { hasTrack && !systemProhibitsSkip }
    var canSeek: Bool { canSkip && anchor.duration > 0 && !isResynchronizing }

    func lyricSeekPosition(at index: Int) -> TimeInterval? {
        guard canSeek, lines.indices.contains(index) else { return nil }
        let position = lines[index].time - lyricOffset
        guard position.isFinite, position <= anchor.duration else { return nil }
        return max(0, position)
    }
    func seekToLyric(_ line: LyricLine, at index: Int, on recording: TrackIdentity) {
        guard track == recording, let position = lyricSeekPosition(at: index), lines[index] == line else { return }
        control("seek", position: position)
    }
    var preferredScheme: ColorScheme? { appearance == "Sistema" ? nil : (appearance == "Claro" ? .light : .dark) }
    var effectiveAwake: Bool { keepAwake && isVisible && !screenSleeping && !onBattery && !lowPower && !hot }

    init(artworkRepository: ArtworkRepository = ArtworkRepository()) {
        self.artworkRepository = artworkRepository
        let defaults = LumaEnvironment.preferences
        defaults.register(defaults: ["twentyFourHour": true, "energyMode": "Automático", "appearance": "Oscuro", "automaticArtwork": true,
                                     "meshFollowsMusic": true, "idleEnabled": true, "idleMinutes": 5.0, "showPhrases": true, "phraseInterval": 60.0, "avoidMedia": true, "protectBrowsers": true, "notchEnabled": true])
        // One-time migration implements the requested automatic recovery; subsequent opt-outs persist.
        if defaults.integer(forKey: "settingsSchema") < 2 {
            defaults.set(true, forKey: "automaticLyrics")
            defaults.set(true, forKey: "automaticArtwork")
            defaults.set(2, forKey: "settingsSchema")
        }
        notchEnabled = defaults.bool(forKey: "notchEnabled")
        meshTheme = MeshTheme(rawValue: defaults.string(forKey: "meshTheme") ?? "") ?? .aurora
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
        if let name = defaults.string(forKey: "lyricTypeface"), let typeface = AmbientTypeface(rawValue: name), typeface.installed {
            lyricTypefaceOverride = typeface
        }
        lyricSizePercent = SafePreference.number(defaults.object(forKey: "lyricSizePercent") as? Double ?? LyricTypography.defaultSize,
                                                 range: LyricTypography.sizeRange, fallback: LyricTypography.defaultSize)
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
        else if prefs.bool(forKey: playbackSurface.enabledKey) { connectMusic() }
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
        guard visible != isVisible else { return }
        isVisible = visible
        if visible { notch?.hideForPresentation() } else { notch?.reconcile() }
        policyChanged()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }
        notificationTokens.append((center, token))
    }
    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter, standard = NotificationCenter.default
        observe(standard, .oruviSystemMediaChanged) { [weak self] in
            guard let self, self.connected, self.needsPlayback, !self.demoMode,
                  self.effectivePlayerPreference == .automatic else { return }
            if self.reading { self.pendingMusicHint = true } else { self.readMusic() }
        }
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observe(standard, name) { [weak self] in self?.refreshVisibility() }
        }
        for (source, sleep, wake) in [
            (SleepSource.system, NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            (SleepSource.display, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification)
        ] {
            observe(workspace, sleep) { [weak self] in self?.setSleeping(true, source: source) }
            observe(workspace, wake) { [weak self] in self?.setSleeping(false, source: source) }
        }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in self?.refreshPower() }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = app.bundleIdentifier else { return }
                MainActor.assumeIsolated { self?.nativePlayerLifecycleChanged(bundleID) }
            }
            notificationTokens.append((workspace, token))
        }
        observe(standard, .NSProcessInfoPowerStateDidChange) { [weak self] in self?.refreshPower() }
        observe(standard, ProcessInfo.thermalStateDidChangeNotification) { [weak self] in self?.refreshPower() }
        for name in ["com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"] {
            // Best-effort notification hints. Public Apple Events remain the source of truth.
            observe(DistributedNotificationCenter.default(), Notification.Name(name)) { [weak self] in
                guard let self, self.connected, self.needsPlayback, !self.demoMode else { return }
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
    func setSleeping(_ sleeping: Bool, source: SleepSource) {
        if sleeping { sleepingSources.insert(source) } else { sleepingSources.remove(source) }
        // System and display wake can arrive independently. Keep all playback surfaces
        // suspended until neither source is asleep.
        let blocked = !sleepingSources.isEmpty
        guard blocked != screenSleeping else { return }
        screenSleeping = blocked
        if blocked {
            runtime?.dismiss()
        } else {
            refreshPower()
            runtime?.didWake()
        }
        refreshVisibility()
    }
    private func nativePlayerLifecycleChanged(_ bundleID: String) {
        guard let source = PlayerSource(rawValue: bundleID), source != .system,
              connected, needsPlayback, !demoMode else { return }
        if let explicit = effectivePlayerPreference.source, explicit != source { return }
        // Discard any queued sample from before the process started or stopped.
        invalidatePlaybackRequests()
        if reading { pendingMusicHint = true } else { readMusic() }
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
        let previousSurface = playbackSurface
        let sessionChanged = updatePlaybackSurface()
        let previousDemand = lastPlaybackDemand
        let demand = needsPlayback
        lastPlaybackDemand = demand
        updateDisplayAssertion()

        guard previousSurface != playbackSurface || previousDemand != demand else {
            if pollTimer != nil && scheduledPollInterval != playbackPollInterval { schedulePoll() }
            return
        }
        runtime?.refreshPhrases()
        if demand && connected && !demoMode {
            if previousDemand && !sessionChanged {
                updateLyricsVisibility()
                readMusic()
            } else {
                refreshPlayback()
            }
        } else {
            suspendPlaybackSampling()
            if demoMode { updateCue() }
        }
        if !lyricsLookupVisible { stopLyricsUpdates() }
        if !demand {
            artworkTask?.cancel(); artworkTask = nil
        }
    }
    private func suspendPlaybackSampling() {
        SystemMediaBridge.shared.setEnabled(false)
        invalidatePlaybackRequests()
        playbackReadMilliseconds = nil
        pendingMusicHint = false
        pollTimer?.invalidate(); pollTimer = nil
    }
    private func updateDisplayAssertion() {
        if effectiveAwake && !hasAssertion {
            hasAssertion = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Oruvi: pantalla ambiental con corriente" as CFString, &assertion) == kIOReturnSuccess
        } else if !effectiveAwake && hasAssertion { IOPMAssertionRelease(assertion); hasAssertion = false }
    }
    /// Every reveal, wake and explicit reconnect requests fresh metadata AND position.
    func refreshPlayback(restartingSystem: Bool = false) {
        guard connected, !demoMode, needsPlayback else { return }
        SystemMediaBridge.shared.setEnabled(!LumaEnvironment.isTesting && effectivePlayerPreference == .automatic,
                                            restarting: restartingSystem)
        invalidatePlaybackRequests()
        lyricsRetryAt = 0; artworkRetryAt = 0
        playbackReadMilliseconds = nil
        recovery.invalidate(); isResynchronizing = true
        cancelCueTimer()
        if reading { pendingMusicHint = true } else { readMusic() }
    }
    func connectMusic() {
        demoMode = false; connected = true
        prefs.set(true, forKey: playbackSurface.enabledKey)
        connectionStatus = "Conectando reproductor…"
        musicQueue.async { [playerRouter] in playerRouter.reset() }
        refreshPlayback(restartingSystem: true)
    }
    func disconnectMusic() {
        suspendPlaybackSampling()
        connected = false; demoMode = false
        prefs.set(false, forKey: playbackSurface.enabledKey)
        retainedArtwork = nil
        clearTrack(); isResynchronizing = false; connectionStatus = "Música desconectada"
    }
    private func clearTrack() {
        lyricsTask?.cancel(); lyricsTask = nil; artworkTask?.cancel(); artworkTask = nil
        track = .empty; anchor = PlaybackAnchor(); artwork = nil; artworkLink = nil; palette = RGB.aurora
        playbackReadMilliseconds = nil
        playerArtworkURL = ""; activeSystemBundleID = ""; systemArtworkData = nil; systemProhibitsSkip = false
        appliedSystemArtwork = nil
        lyricsAvailability = .idle; toastMessage = nil
        lyricsRetryAt = 0; artworkRetryAt = 0
        lines = []; activeLine = nil; lyricSource = ""; artworkStatus = ""
        playbackOptionsAvailable = false; shuffleEnabled = false; repeatMode = 0
        cancelCueTimer()
    }
    private func readMusic() {
        guard !LumaEnvironment.isTesting, connected, needsPlayback, !reading, !demoMode else { return }
        reading = true; pollTimer?.invalidate(); pollTimer = nil
        let session = generation, preference = effectivePlayerPreference, preferred = activePlayer
        musicQueue.async { [weak self, playerRouter, playbackGeneration] in
            let snapshot = playbackGeneration.withLock { $0 == session }
                ? playerRouter.snapshot(preference: preference, preferred: preferred) : nil
            DispatchQueue.main.async {
                guard let self else { return }; self.reading = false
                guard let snapshot, session == self.generation, self.connected, self.needsPlayback else {
                    if self.connected && self.needsPlayback && self.pendingMusicHint {
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
        if let sequence = snapshot["playbackSequence"] as? UInt64 {
            guard sequence > lastAppliedSnapshotSequence else { return }
            lastAppliedSnapshotSequence = sequence
        }
        let status = snapshot["status"] as? String ?? "error"
        if status != "ok" { playbackReadMilliseconds = nil }
        if status == "denied" {
            // A denied provider suspends this surface, not the independent preference
            // or opt-in of the other surface. Only Disconnect persists an opt-out.
            connected = false
            suspendPlaybackSampling()
            clearTrack(); isResynchronizing = false
            connectionStatus = snapshot["message"] as? String ?? "Permiso de Automatización requerido."; return
        }
        if status == "notRunning" {
            clearTrack(); recovery.succeed(at: ProcessInfo.processInfo.systemUptime); isResynchronizing = false
            connectionStatus = effectivePlayerPreference.source.map { "Abre " + $0.name + " en este Mac" }
                ?? "Reproduce contenido compatible con Ahora suena en este Mac"
            return
        }
        if status == "stopped" {
            if recovery.observeStopped() {
                clearTrack(); recovery.succeed(at: ProcessInfo.processInfo.systemUptime); isResynchronizing = false
                connectionStatus = "Elige una canción en tu reproductor"
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
        var next = TrackIdentity(id: snapshot["id"] as? String ?? "", title: snapshot["title"] as? String ?? "Sin título", artist: snapshot["artist"] as? String ?? "", album: snapshot["album"] as? String ?? "", duration: (snapshot["duration"] as? NSNumber)?.doubleValue ?? 0)
        guard next.duration.isFinite, next.duration >= 0, next.duration < 86400 else {
            playbackReadMilliseconds = nil
            recovery.fail(); isResynchronizing = true; updateCue(); return
        }
        let source = PlayerSource(rawValue: snapshot["source"] as? String ?? "") ?? .music
        next.sourceID = source.rawValue
        let changed = activePlayer != source || !PlaybackRecovery.sameRecording(track, next)
        let sample = (snapshot["sampleUptime"] as? NSNumber)?.doubleValue ?? ProcessInfo.processInfo.systemUptime
        let position = (snapshot["position"] as? NSNumber)?.doubleValue ?? 0
        let playing = (snapshot["playing"] as? NSNumber)?.boolValue ?? false
        guard sample.isFinite, position.isFinite, position >= 0 else {
            playbackReadMilliseconds = nil
            recovery.fail(); isResynchronizing = true; updateCue(); return
        }
        // Never clear a valid song for a corrupt/incomplete playback sample.
        activePlayer = source; lastSurfacePlayers[playbackSurface] = source
        if changed {
            lyricsTask?.cancel(); lyricsTask = nil; artworkTask?.cancel(); artworkTask = nil
            lyricsRetryAt = 0; artworkRetryAt = 0
            track = next; artwork = nil; artworkLink = nil
            appliedSystemArtwork = nil
            lyricsAvailability = .idle
            artworkStatus = ""
            if let retainedArtwork, PlaybackRecovery.sameRecording(retainedArtwork.track, next),
               retainedArtwork.track.sourceID == next.sourceID {
                artwork = retainedArtwork.image; artworkLink = retainedArtwork.link
                appliedSystemArtwork = retainedArtwork.systemData
                setPalette(retainedArtwork.palette)
            } else {
                setPalette(RGB.fallback(for: next))
            }
            lines = []; activeLine = nil; lyricSource = ""
            playbackOptionsAvailable = false; shuffleEnabled = false; repeatMode = 0
        }
        activeSystemBundleID = snapshot["systemBundleID"] as? String ?? ""
        systemProhibitsSkip = source == .system && ((snapshot["systemProhibitsSkip"] as? NSNumber)?.boolValue ?? false)
        let nextSystemArtwork = snapshot["systemArtwork"] as? Data
        let nextArtworkURL = snapshot["artworkURL"] as? String ?? ""
        let newSystemArtwork = nextSystemArtwork.map { $0 != systemArtworkData } ?? false
        if changed { playerArtworkURL = "" }
        let newArtworkURL = source == .spotify && playerArtworkURL != nextArtworkURL
            && ArtworkURLPolicy.spotify(nextArtworkURL) != nil
        if newArtworkURL { playerArtworkURL = nextArtworkURL }
        if (newSystemArtwork && nextSystemArtwork != appliedSystemArtwork) || (newArtworkURL && needsSpotifyCover) {
            artworkTask?.cancel(); artworkTask = nil; artworkRetryAt = 0
        }
        if changed || nextSystemArtwork != nil { systemArtworkData = nextSystemArtwork }
        if let shuffle = snapshot["shuffle"] as? NSNumber, let repeated = snapshot["repeatMode"] as? NSNumber {
            shuffleEnabled = shuffle.boolValue; repeatMode = min(2, max(0, repeated.intValue)); playbackOptionsAvailable = true
        }
        let adjusted = changed ? position : PlaybackRecovery.reconciledPosition(position, sampleUptime: sample, previous: anchor, playing: playing)
        let reportedRate = (snapshot["playbackRate"] as? NSNumber)?.doubleValue ?? 1
        let rate = SafePreference.number(reportedRate, range: 0...16, fallback: 1)
        // Keep TrackIdentity stable for lyrics and artwork, but use the newest duration for transport.
        anchor = PlaybackAnchor(position: adjusted, uptime: sample, duration: next.duration, playing: playing, rate: rate)
        recovery.succeed(at: sample); isResynchronizing = false
        let duration = (snapshot["playbackReadDuration"] as? NSNumber)?.doubleValue
        let milliseconds = duration.flatMap { $0 >= 0 ? Int(exactly: ($0 * 1000).rounded()) : nil }
        if playbackReadMilliseconds != milliseconds { playbackReadMilliseconds = milliseconds }
        connectionStatus = activePlayer.name + (playing ? " · reproduciendo" : " · en pausa")
        // Missing resources recover without having to close and reopen the app. Cooldowns
        // prevent a failed or unavailable lyric from being requested on every playback tick.
        let now = ProcessInfo.processInfo.systemUptime
        if lines.isEmpty && lyricsTask == nil && now >= lyricsRetryAt && lyricsLookupVisible { fetchLyrics() }
        let needsSystemCover = systemArtworkData.map { $0 != appliedSystemArtwork } ?? false
        if artworkTask == nil && now >= artworkRetryAt && (artwork == nil || needsSystemCover || needsSpotifyCover) { fetchArtwork() }
        updateCue()
    }
    private var playbackPollInterval: TimeInterval {
        let normalInterval = policy.visible ? (policy.pollingInterval(playing: anchor.playing) ?? 5) : (anchor.playing ? (onBattery ? 5.0 : 3.0) : 8.0)
        return recovery.waiting ? max(policy.visible ? 0.25 : 1.0, recovery.retryInterval) : normalInterval
    }
    private func schedulePoll() {
        guard !LumaEnvironment.isTesting, connected, !demoMode, !reading, needsPlayback else { return }
        let interval = playbackPollInterval
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.readMusic() } }
        scheduledPollInterval = interval
        timer.tolerance = 0.1; pollTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func control(_ command: String, position: Double = 0) {
        guard hasTrack, position.isFinite else { return }
        if command == "seek" && !canSeek { return }
        if (command == "next" || command == "previous") && !canSkip { return }
        let duration = anchor.duration
        let target = duration > 0 ? min(max(0, position), duration) : max(0, position)
        if demoMode {
            let now = ProcessInfo.processInfo.systemUptime, current = anchor.value(at: ProcessInfo.processInfo.systemUptime)
            if command == "toggle" { anchor = PlaybackAnchor(position: current, uptime: now, duration: duration, playing: !anchor.playing) }
            else if command == "shuffle" { shuffleEnabled.toggle() }
            else if command == "repeat" { repeatMode = (repeatMode + 1) % 3 }
            else { anchor = PlaybackAnchor(position: command == "seek" ? target : 0, uptime: now, duration: duration, playing: anchor.playing) }
            updateCue(); return
        }
        guard connected else { return }
        let session = generation, source = activePlayer
        let preference = effectivePlayerPreference, expectedTrackID = track.id
        musicQueue.async { [weak self, playerRouter, playbackGeneration] in
            let result = playerRouter.command(command, position: target, source: source, preference: preference,
                                              expectedTrackID: expectedTrackID) { playbackGeneration.withLock { $0 == session } }
            DispatchQueue.main.async {
                guard let self, session == self.generation, self.connected else { return }
                if result["status"] as? String != "ok" {
                    let message = result["message"] as? String ?? "Abre tu reproductor para usar los controles."
                    self.connectionStatus = message
                    self.showToast(message)
                }
                if self.reading { self.pendingMusicHint = true } else { self.readMusic() }
            }
        }
    }
    /// Native widget buttons execute inside the containing app. Validate the
    /// displayed session before dispatch and finish reading the real state before
    /// the App Intent's automatic timeline reload. Never change either selector.
    func controlFromNativeWidget(_ command: String, expectedTrackID: String,
                                 sourceID: String, preference: String) async -> String {
        guard ["previous", "toggle", "next"].contains(command), !LumaEnvironment.isTesting,
              connected, !demoMode, !screenSleeping else { return "Conecta los controles en Oruvi." }
        guard expectedTrackID == track.id, sourceID == activePlayer.rawValue,
              preference == effectivePlayerPreference.rawValue else {
            _ = await synchronizeNativeWidget(connectIfNeeded: false)
            return "El contenido cambió. Vuelve a pulsar el control."
        }
        if command != "toggle" && !canSkip { return "Este contenido no permite saltar." }
        let session = generation, source = activePlayer, selection = effectivePlayerPreference, queue = musicQueue
        let result: ([String: Any], [String: Any])? = await withCheckedContinuation { continuation in
            queue.async { [playerRouter, playbackGeneration] in
                let commandResult = playerRouter.command(command, position: 0, source: source,
                    preference: selection, expectedTrackID: expectedTrackID, requireSameTrack: true) {
                        playbackGeneration.withLock { $0 == session }
                    }
                if commandResult["status"] as? String == "ok" {
                    queue.asyncAfter(deadline: .now() + 0.15) {
                        guard playbackGeneration.withLock({ $0 == session }) else { continuation.resume(returning: nil); return }
                        let value = playerRouter.snapshot(preference: selection, preferred: source, refreshSystem: true)
                        continuation.resume(returning: (commandResult, value))
                    }
                } else {
                    guard playbackGeneration.withLock({ $0 == session }) else { continuation.resume(returning: nil); return }
                    let value = playerRouter.snapshot(preference: selection, preferred: source, refreshSystem: true)
                    continuation.resume(returning: (commandResult, value))
                }
            }
        }
        guard let result, session == generation, connected, !screenSleeping else { return "La sesión de Oruvi cambió." }
        apply(result.1)
        if result.0["status"] as? String != "ok" {
            return result.0["message"] as? String ?? "El reproductor no aceptó el control."
        }
        return ""
    }
    /// Explicit widget recovery awaits a fresh read before WidgetKit reloads.
    /// No transport command is sent here and neither source selector is edited.
    func synchronizeNativeWidget(connectIfNeeded: Bool) async -> String {
        guard !LumaEnvironment.isTesting, !screenSleeping else { return "Oruvi está en reposo." }
        if !connected || demoMode {
            guard connectIfNeeded else { return "Conecta el reproductor en los ajustes de Oruvi." }
            connectMusic()
        }
        guard connected, !demoMode else { return "Conecta el reproductor en Oruvi." }
        let session = generation, selection = effectivePlayerPreference, source = activePlayer
        let snapshot: [String: Any]? = await withCheckedContinuation { continuation in
            musicQueue.async { [playerRouter, playbackGeneration] in
                guard playbackGeneration.withLock({ $0 == session }) else { continuation.resume(returning: nil); return }
                continuation.resume(returning: playerRouter.snapshot(preference: selection, preferred: source, refreshSystem: true))
            }
        }
        guard let snapshot, session == generation, connected, !screenSleeping else { return "La sesión cambió. Actualiza el widget." }
        apply(snapshot)
        schedulePoll()
        return snapshot["status"] as? String == "ok" ? "" : connectionStatus
    }
    func fetchLyrics() {
        lyricsTask?.cancel(); lyricsTask = nil
        // Browser/video titles must never be sent to a music-lyrics service.
        guard activePlayer != .system else {
            lyricsAvailability = .unavailable; lyricsRetryAt = .greatestFiniteMagnitude
            return
        }
        guard !demoMode, hasTrack, lyricsLookupVisible, !isResynchronizing else { return }
        lines = []; activeLine = nil; lyricSource = ""
        lyricsAvailability = .loading
        let identity = track, allowed = automaticLyrics
        lyricsRetryAt = ProcessInfo.processInfo.systemUptime + 600
        lyricsTask = Task { [weak self, repository] in
            for delay in [0, 15, 45] {
                do { if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) }; try Task.checkCancellation() }
                catch { return }
                let result = await repository.load(for: identity, allowNetwork: allowed)
                guard !Task.isCancelled, let self, self.track == identity, self.automaticLyrics == allowed, self.lyricsLookupVisible else { return }
                switch result {
                case .available(let payload):
                    self.lines = payload.lines; self.lyricsAvailability = .ready; self.lyricSource = payload.source; self.updateCue(); self.lyricsTask = nil; return
                case .unavailable: self.lyricsAvailability = .unavailable; self.lyricsTask = nil; return
                case .message: self.lyricsAvailability = allowed ? .offline : .disabled; self.lyricsTask = nil; return
                case .rateLimited(let deadline):
                    self.lyricsAvailability = .offline
                    self.lyricsRetryAt = deadline
                    self.lyricsTask = nil
                    return
                case .retry: self.lyricsAvailability = .offline
                }
            }
            guard !Task.isCancelled, let self, self.track == identity else { return }
            self.lyricsRetryAt = ProcessInfo.processInfo.systemUptime + 30
            self.lyricsTask = nil
        }
    }
    private func stopLyricsUpdates() {
        cancelCueTimer()
        if lyricsTask != nil { lyricsTask?.cancel(); lyricsTask = nil; lyricsRetryAt = 0 }
    }
    private func updateLyricsVisibility() {
        guard started else { return }
        guard lyricsLookupVisible else { stopLyricsUpdates(); return }
        if lines.isEmpty && lyricsTask == nil && ProcessInfo.processInfo.systemUptime >= lyricsRetryAt { fetchLyrics() }
        updateCue()
    }
    private var needsSpotifyCover: Bool {
        guard activePlayer == .spotify, !playerArtworkURL.isEmpty else { return false }
        guard let artwork, let retainedArtwork, artwork === retainedArtwork.image else { return true }
        return retainedArtwork.systemData == nil && retainedArtwork.spotifyURL != playerArtworkURL
    }

    func fetchArtwork() {
        artworkTask?.cancel(); artworkTask = nil
        guard !demoMode, hasTrack, connected, needsPlayback, !isResynchronizing else { return }
        let identity = track, source = activePlayer, artworkURL = playerArtworkURL, allowNetwork = automaticArtwork
        let embedded = systemArtworkData == appliedSystemArtwork ? nil : systemArtworkData
        artworkRetryAt = ProcessInfo.processInfo.systemUptime + 60
        artworkStatus = "Recuperando portada…"
        artworkTask = Task { [weak self, artworkRepository] in
            guard !Task.isCancelled else { return }
            if let embedded {
                let decoded = await Task.detached(priority: .utility) { Self.decodeArtwork(embedded) }.value
                guard !Task.isCancelled, let self, self.track == identity, self.needsPlayback else { return }
                self.appliedSystemArtwork = embedded
                if let decoded {
                    self.setArtwork(decoded, systemData: embedded)
                    self.artworkStatus = "Portada del reproductor"; self.artworkTask = nil; return
                }
                if self.artwork != nil && !self.needsSpotifyCover { self.artworkTask = nil; return }
            }
            if source == .system || (source == .spotify && artworkURL.isEmpty) {
                self?.artworkStatus = "Portada no disponible"; self?.artworkTask = nil; return
            }
            for attempt in 0..<3 {
                do { if attempt > 0 { try await Task.sleep(nanoseconds: attempt == 1 ? 2_000_000_000 : 12_000_000_000) }; try Task.checkCancellation() }
                catch { return }
                guard let self, self.track == identity, self.connected, self.needsPlayback else { return }
                if source == .spotify {
                    do {
                        if let remote = try await artworkRepository.loadSpotify(artworkURL) {
                            let decoded = await Task.detached(priority: .utility) { Self.decodeArtwork(remote.data) }.value
                            guard !Task.isCancelled, self.track == identity, self.needsPlayback else { return }
                            if let decoded {
                                self.setArtwork(decoded, spotifyURL: artworkURL)
                                self.artworkStatus = "Portada de Spotify"; self.artworkTask = nil; return
                            }
                        }
                    } catch RemoteError.rateLimited(let deadline) {
                        guard !Task.isCancelled, self.track == identity, self.needsPlayback else { return }
                        self.artworkStatus = "Spotify limitó temporalmente las descargas de portadas."
                        self.artworkRetryAt = deadline
                        self.artworkTask = nil
                        return
                    } catch { if Task.isCancelled { return } }
                    continue
                }
                let local: (NSImage, [RGB])? = await withCheckedContinuation { continuation in
                    self.artworkQueue.async {
                        let result = LumaReadMusicArtwork(identity.id, identity.title, identity.album).flatMap(Self.decodeArtwork)
                        continuation.resume(returning: result)
                    }
                }
                guard !Task.isCancelled, self.track == identity, self.needsPlayback else { return }
                if let local {
                    self.setArtwork(local); self.artworkStatus = "Portada de Música"; self.artworkTask = nil; return
                }
                if attempt >= 1 && allowNetwork {
                    do {
                        if let remote = try await artworkRepository.load(for: identity) {
                            let decoded = await Task.detached(priority: .utility) { Self.decodeArtwork(remote.data) }.value
                            guard !Task.isCancelled, self.track == identity, self.needsPlayback, self.automaticArtwork else { return }
                            if let decoded {
                                self.setArtwork(decoded, link: remote.link)
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
    private func setArtwork(_ decoded: (NSImage, [RGB]), link: URL? = nil, systemData: Data? = nil, spotifyURL: String? = nil) {
        artwork = decoded.0; artworkLink = link
        setPalette(decoded.1)
        retainedArtwork = (track, decoded.0, decoded.1, link, systemData, spotifyURL)
    }
    private func setPalette(_ value: [RGB]) {
        palette = value // Interpolate only the mesh, not every view in the application.
    }
    private func cancelCueTimer() {
        cueTimer?.invalidate(); cueTimer = nil
        cueDeadline = nil
    }
    private func updateCue() {
        guard lyricsSurfaceVisible, !isResynchronizing else { cancelCueTimer(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let position = anchor.value(at: now) + lyricOffset
        let index = LRCParser.index(at: position, in: lines)
        if activeLine != index { activeLine = index }
        let next = (index ?? -1) + 1
        guard next < lines.count, let delay = anchor.delay(until: lines[next].time - lyricOffset, at: now) else {
            cancelCueTimer(); return
        }
        let deadline = now + delay
        let tolerance = 0.012
        // A consistent playback sample predicts the same cue, so leave its timer armed.
        if let cueTimer, cueTimer.isValid, let cueDeadline, abs(cueDeadline - deadline) <= tolerance { return }
        cancelCueTimer()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] fired in
            MainActor.assumeIsolated {
                guard let self, self.cueTimer === fired else { return }
                self.cancelCueTimer()
                self.updateCue()
            }
        }
        timer.tolerance = tolerance
        cueTimer = timer; cueDeadline = deadline
        RunLoop.main.add(timer, forMode: .common)
    }
    func clearLyricsCache() {
        guard !isClearingDownloadCache else { return }
        isClearingDownloadCache = true
        cacheClearStatus = "Vaciando caché…"
        Task {
            async let lyricsCleared = repository.clearDownloadedCache()
            async let artworkCleared = artworkRepository.clearCache()
            let (lyrics, artwork) = await (lyricsCleared, artworkCleared)
            cacheClearStatus = lyrics && artwork
                ? "Caché de letras y portadas vacía."
                : "No se pudieron borrar todos los archivos de caché."
            isClearingDownloadCache = false
        }
    }
    func setNotchVisible(_ value: Bool) {
        guard notchVisible != value else { return }
        notchVisible = value
        if started { policyChanged() }
    }
    func toggleLyrics() {
        guard hasLyrics else { return }
        musicShowsLyrics.toggle()
    }
    func showToast(_ text: String) {
        toastTask?.cancel(); toastMessage = text
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(2800))
        toastTask = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            guard !Task.isCancelled else { return }; self?.toastMessage = nil
        }
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
    func openMusic(source requestedSource: PlayerSource? = nil) {
        // Capture the source BEFORE dismissing Standby changes the active surface.
        let source = requestedSource ?? effectivePlayerPreference.source ?? activePlayer
        let bundleID = source == .system ? activeSystemBundleID : source.rawValue
        if requestedSource == nil && !connected && !demoMode { connectMusic() }
        notch?.collapse(); runtime?.dismiss()
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            connectionStatus = source.name + " no está instalado."; return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if NSApp.isActive { NSApp.yieldActivation(toApplicationWithBundleIdentifier: bundleID) }
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                if error != nil {
                    self?.connectionStatus = "No se pudo abrir " + source.name + "."
                } else if let app {
                    if NSApp.isActive {
                        NSApp.yieldActivation(to: app)
                        app.activate(from: .current, options: [.activateAllWindows])
                    } else {
                        app.activate(options: [.activateAllWindows])
                    }
                }
            }
        }
    }
    func useDemo() {
        suspendPlaybackSampling()
        connected = false; demoMode = true; isResynchronizing = false
        systemProhibitsSkip = false
        playbackOptionsAvailable = true; shuffleEnabled = false; repeatMode = 0
        lyricsTask?.cancel(); lyricsTask = nil; artworkTask?.cancel(); artworkTask = nil
        track = TrackIdentity(id: "luma-demo", title: "Still, here.", artist: "Oruvi · demostración", album: "Slow mornings", duration: 214)
        anchor = PlaybackAnchor(position: 84, uptime: ProcessInfo.processInfo.systemUptime, duration: 214, playing: true)
        artwork = nil; artworkLink = nil; palette = RGB.aurora
        lyricsAvailability = .ready
        lines = LRCParser.parse("[00:00.00]Un espacio para bajar el ritmo.\n[00:32.00]La luz se mueve despacio.\n[01:00.00]Deja que el día espere.\n[01:20.00]Quédate en este instante.\n[01:36.00]La música encuentra su lugar.\n[02:00.00]Todo lo demás puede esperar.\n[02:35.00]Respira. Ya estás aquí.\n[03:25.00]")
        lyricSource = "Demostración · texto original, sin audio"; connectionStatus = "Vista de demostración · sin audio"; updateCue()
    }
    func shutdown() {
        suspendPlaybackSampling()
        cancelCueTimer(); lyricsTask?.cancel(); artworkTask?.cancel(); toastTask?.cancel(); runtime?.stop(); notch?.stop()
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
