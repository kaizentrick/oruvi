import AppKit
import SwiftUI
import CoreGraphics

final class StandbyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// A borderless full-screen presentation: no Dock icon and no asynchronous Space transitions.
/// Menu-bar-level presentation stays below protected login/lock/screen-saver surfaces.
/// Process switching and Force Quit are never disabled.
@MainActor
final class AmbientRuntime {
    private let model: StandbyModel
    private let window: NSWindow
    private var idleTimer: Timer?
    private var phraseTimer: Timer?
    private var localEvents: Any?
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var sleeping = false
    private var sessionInactive = false
    private var locked = false
    private var lastDismissed = -Double.greatestFiniteMagnitude
    private var lastWake = ProcessInfo.processInfo.systemUptime
    private var stopped = false
    private var presentationSerial = 0
    private var savedPresentation: NSApplication.PresentationOptions?
    private var mediaCheck: Task<Void, Never>?
    private var mediaSerial = 0
    private var wasMediaProtected = false
    private var lastMediaProtected = -Double.greatestFiniteMagnitude
    var isBlocked: Bool { sleeping || sessionInactive || locked }
    var hasIdleTimer: Bool { idleTimer?.isValid == true }
    var hasPhraseTimer: Bool { phraseTimer?.isValid == true }
    var isFullScreenPresentation: Bool {
        window.isVisible && NSScreen.screens.contains { abs($0.frame.width - window.frame.width) < 1 && abs($0.frame.height - window.frame.height) < 1 && $0.frame.origin == window.frame.origin }
    }
    init(model: StandbyModel, window: NSWindow) {
        self.model = model; self.window = window; model.runtime = self
        installObservers()
        localEvents = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .swipe]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }
    /// Opening the app is not permission to cover an ongoing film. Explicit menu activation is.
    func launchRespectingMedia() {
        guard !stopped, !isBlocked else { return }
        guard model.avoidMedia else { activate(); return }
        mediaSerial += 1
        let serial = mediaSerial
        let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let ownPID = ProcessInfo.processInfo.processIdentifier
        mediaCheck = Task { [weak self] in
            let sample = await Task.detached(priority: .utility) {
                MediaProtection.sample(frontmostBundleID: foreground, ownPID: ownPID)
            }.value
            guard !Task.isCancelled, let self, self.mediaSerial == serial, !self.stopped, !self.isBlocked else { return }
            self.mediaCheck = nil
            if sample.shouldProtect(enabled: self.model.avoidMedia, conservativeBrowsers: self.model.protectBrowsers) {
                self.wasMediaProtected = true
                self.lastMediaProtected = ProcessInfo.processInfo.systemUptime
                self.model.automaticActivationStatus = sample.reason
                self.rescheduleIdle()
            } else { self.activate() }
        }
    }
    func activate(automatic: Bool = false) {
        guard !stopped, !isBlocked else { return }
        idleTimer?.invalidate(); idleTimer = nil
        mediaSerial += 1; mediaCheck?.cancel(); mediaCheck = nil
        model.automaticActivationStatus = automatic ? "Presentación automática" : "Presentación manual"
        model.automaticSession = automatic
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? window.screen ?? NSScreen.main
        if let screen {
            window.setFrame(screen.frame, display: true)
            window.contentView?.setFrameSize(screen.frame.size)
        }
        NSApp.setActivationPolicy(.accessory)
        applyAppearance()
        if savedPresentation == nil { savedPresentation = NSApp.presentationOptions }
        window.ignoresMouseEvents = false
        presentationSerial += 1
        let serial = presentationSerial
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        NSApp.activate()
        applySystemPresentation()
        model.refreshVisibility()
        model.refreshPlayback()
        refreshPhrases()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.presentationSerial == serial, self.window.isVisible, !self.isBlocked else { return }
            self.applySystemPresentation()
            self.model.refreshVisibility()
        }
    }
    private func applySystemPresentation() {
        guard window.isVisible, !isBlocked else { return }
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
    }
    func applyAppearance() {
        window.appearance = model.appearance == "Sistema" ? nil : NSAppearance(named: model.appearance == "Claro" ? .aqua : .darkAqua)
    }
    func dismiss() {
        presentationSerial += 1
        model.settingsOpen = false
        window.orderOut(nil)
        window.level = .normal
        if let savedPresentation { NSApp.presentationOptions = savedPresentation; self.savedPresentation = nil }
        lastDismissed = ProcessInfo.processInfo.systemUptime
        model.automaticSession = false
        model.refreshVisibility()
        refreshPhrases(); rescheduleIdle()
    }
    func rescheduleIdle() {
        idleTimer?.invalidate(); idleTimer = nil
        mediaSerial += 1; mediaCheck?.cancel(); mediaCheck = nil
        if !model.idleEnabled { model.automaticActivationStatus = "Activación automática desactivada" }
        guard !stopped, !LumaEnvironment.isTesting, model.idleEnabled, !isBlocked else { return }
        if let until = model.autoPausedUntil, until > Date() {
            model.automaticActivationStatus = "Activación automática en pausa"
            scheduleIdleTimer(after: min(30, max(1, until.timeIntervalSinceNow))); return
        }
        model.autoPausedUntil = nil
        if window.isVisible {
            if NSApp.isActive || model.settingsOpen || window.attachedSheet != nil { return }
            dismiss(); return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let idle = Self.systemIdleSeconds()
        let delay = min(120, max(1, model.idleMinutes.isFinite ? model.idleMinutes : 5)) * 60
        let policy = IdleActivationPolicy(enabled: true, delay: delay, visible: false, blocked: isBlocked, now: now, lastDismissed: lastDismissed, lastWake: lastWake)
        if policy.shouldActivate(idle: idle) { checkMediaBeforeActivation(); return }
        let remaining = max(delay - max(0, idle), max(delay - (now - lastDismissed), delay - (now - lastWake)))
        let interval = min(30, max(1, remaining.isFinite ? remaining : 30))
        model.automaticActivationStatus = "En espera · después de \(Int(delay / 60)) min"
        scheduleIdleTimer(after: interval)
    }
    private func scheduleIdleTimer(after seconds: Double) {
        idleTimer?.invalidate()
        let interval = max(1, seconds)
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.rescheduleIdle() } }
        timer.tolerance = min(0.25, interval * 0.05)
        idleTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func checkMediaBeforeActivation() {
        guard model.avoidMedia else { activate(automatic: true); return }
        let serial = mediaSerial
        let foreground = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let pid = ProcessInfo.processInfo.processIdentifier
        model.automaticActivationStatus = "Comprobando reproducción"
        mediaCheck = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { MediaProtection.sample(frontmostBundleID: foreground, ownPID: pid) }.value
            guard !Task.isCancelled, let self, self.mediaSerial == serial, !self.stopped, !self.isBlocked, !self.window.isVisible, self.model.idleEnabled else { return }
            self.mediaCheck = nil
            // Another app could become active while a system query is in flight.
            guard foreground == (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else { self.rescheduleIdle(); return }
            if result.shouldProtect(enabled: self.model.avoidMedia, conservativeBrowsers: self.model.protectBrowsers) {
                self.wasMediaProtected = true
                self.lastMediaProtected = ProcessInfo.processInfo.systemUptime
                self.model.automaticActivationStatus = result.reason
                self.scheduleIdleTimer(after: 12); return
            }
            if self.wasMediaProtected {
                // A full new idle period after playback ends prevents covering the final frame,
                // credits, or a page the person has just returned to.
                self.wasMediaProtected = false
                let now = ProcessInfo.processInfo.systemUptime
                if MediaProtection.needsFreshIdlePeriod(idle: Self.systemIdleSeconds(), now: now, lastProtected: self.lastMediaProtected) { self.lastWake = now }
                self.rescheduleIdle(); return
            }
            let delay = self.model.idleMinutes * 60
            let policy = IdleActivationPolicy(enabled: true, delay: delay, visible: false, blocked: self.isBlocked, now: ProcessInfo.processInfo.systemUptime, lastDismissed: self.lastDismissed, lastWake: self.lastWake)
            if policy.shouldActivate(idle: Self.systemIdleSeconds()) { self.activate(automatic: true) }
            else { self.rescheduleIdle() }
        }
    }
    func pauseAutomatic(minutes: Double?) {
        model.autoPausedUntil = minutes.map { Date().addingTimeInterval($0 * 60) }
        rescheduleIdle()
    }
    static func systemIdleSeconds() -> Double {
        // Reads only elapsed time since any input, not event contents. No global keyboard monitor.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
    }
    func refreshPhrases() {
        phraseTimer?.invalidate(); phraseTimer = nil
        guard !stopped, model.showPhrases, model.policy.visible, model.layout != .listening else { return }
        let seconds = min(600, max(15, model.phraseInterval.isFinite ? model.phraseInterval : 60))
        let timer = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.model.advancePhrase() } }
        timer.tolerance = 0.5; phraseTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping () -> Void) {
        tokens.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in action() }))
    }
    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observe(workspace, name) { [weak self] in self?.sleeping = true; self?.dismiss() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observe(workspace, name) { [weak self] in self?.sleeping = false; self?.didWake() }
        }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.sessionInactive = true; self?.dismiss() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.sessionInactive = false; self?.didWake() }
        // Additional best-effort lock notifications, not relied on as a public API contract.
        // System window ordering and normal level are the independent safety boundary.
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.locked = true; self?.dismiss() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.locked = false; self?.didWake() }
        observe(NotificationCenter.default, NSApplication.didResignActiveNotification) { [weak self] in
            guard let self, !LumaEnvironment.isTesting, self.window.isVisible else { return }
            // A settings sheet must never leave a top-level overlay covering another application.
            self.dismiss()
        }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { [weak self] in
            guard let self, self.window.isVisible else { return }
            self.applySystemPresentation()
            self.model.refreshVisibility(); self.model.refreshPlayback()
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] in
            guard let self, !self.window.isVisible else { return }
            self.rescheduleIdle()
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self else { return }; if self.window.isVisible { self.activate(automatic: self.model.automaticSession) }
        }
    }
    private func didWake() { lastWake = ProcessInfo.processInfo.systemUptime; rescheduleIdle() }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard window.isVisible else { return event }
        let belongs = event.window === window || event.window?.sheetParent === window
        guard belongs else { return event }
        if event.type == .keyDown && event.keyCode == 53 && model.settingsOpen {
            model.settingsOpen = false; return nil
        }
        guard !model.settingsOpen, window.attachedSheet == nil else { return event }
        if event.type == .swipe, event.deltaX != 0 { model.cycleLayout(event.deltaX > 0 ? -1 : 1); return nil }
        guard event.type == .keyDown else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53 { dismiss(); return nil }
        if flags.isDisjoint(with: [.command, .control, .option]) {
            if event.keyCode == 123 { model.cycleLayout(-1); return nil }
            if event.keyCode == 124 { model.cycleLayout(1); return nil }
            if event.keyCode == 49 { model.control("toggle"); return nil }
        }
        if flags.isDisjoint(with: [.control, .option]), let text = event.charactersIgnoringModifiers {
            if let digit = Int(text), (1...3).contains(digit) { model.selectLayout(LayoutMode.allCases[digit - 1]); return nil }
            if flags.contains(.command) && text == "," { model.settingsOpen = true; return nil }
            if flags.contains(.command) && text == "w" { dismiss(); return nil }
            if flags.contains(.command) && text == "q" { NSApp.terminate(nil); return nil }
            if flags.contains(.command) && text == "o" { model.importLRC(); return nil }
        }
        return event
    }
    func stop() {
        stopped = true; idleTimer?.invalidate(); phraseTimer?.invalidate()
        mediaSerial += 1; mediaCheck?.cancel(); mediaCheck = nil
        if let localEvents { NSEvent.removeMonitor(localEvents); self.localEvents = nil }
        for (center, token) in tokens { center.removeObserver(token) }; tokens.removeAll()
        presentationSerial += 1
        if let savedPresentation { NSApp.presentationOptions = savedPresentation; self.savedPresentation = nil }
        window.level = .normal
    }
}
