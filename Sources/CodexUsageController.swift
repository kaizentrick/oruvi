// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import Observation

@MainActor @Observable
final class CodexUsageController {
    static let shared = CodexUsageController()
    private(set) var enabled = LumaEnvironment.preferences.bool(forKey: "codexUsageEnabled")
    var pinned = LumaEnvironment.preferences.object(forKey: "codexUsagePinned") as? Bool ?? true {
        didSet { LumaEnvironment.preferences.set(pinned, forKey: "codexUsagePinned") }
    }
    var selectedBucketID = LumaEnvironment.preferences.string(forKey: "codexUsageBucket") ?? "codex" {
        didSet { LumaEnvironment.preferences.set(selectedBucketID, forKey: "codexUsageBucket") }
    }
    private(set) var snapshot: CodexUsageSnapshot?
    private(set) var error: CodexUsageError?
    private(set) var refreshing = false
    private(set) var now = Date()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var request: CodexUsageRequest?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var displayTimer: Timer?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var blocks = Set<String>()
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var lastAttemptUptime = -Double.infinity
    @ObservationIgnored private var failures = 0

    var selectedBucket: CodexUsageBucket? {
        snapshot?.buckets.first { $0.id == selectedBucketID }
            ?? snapshot?.buckets.first { $0.id == "codex" } ?? snapshot?.buckets.first
    }
    var fresh: Bool { enabled && blocks.isEmpty && error == nil && snapshot?.canReportRemaining(at: now) == true }
    private var currentWindow: CodexUsageWindow? { fresh ? selectedBucket?.limitingWindow(at: now) : nil }
    var hasCurrentQuota: Bool { currentWindow != nil }
    var compactText: String {
        guard let window = currentWindow else { return "—" }
        return "\(window.remainingPercent)%"
    }
    var status: String {
        if !enabled { return "Sin conectar" }
        if !blocks.isEmpty { return "En pausa mientras tu Mac descansa" }
        if let error { return error.message }
        if snapshot == nil && refreshing { return "Consultando Codex…" }
        if let snapshot, !snapshot.isFresh(at: now) { return "Datos pendientes de actualizar" }
        if snapshot?.ordinaryUsageAllowed == false { return "Codex informa que el uso incluido está bloqueado" }
        if let window = currentWindow {
            return "\(window.remainingPercent)% restante · \(window.title)"
        }
        if selectedBucket?.windows.isEmpty == false { return "Reinicio pendiente de confirmar" }
        return "Esta cuenta no informa de límites disponibles"
    }
    var compactHelp: String { "\(selectedBucket?.title ?? "Codex") · \(status). Abrir conexiones." }

    func start() {
        guard !started, !LumaEnvironment.isTesting else { return }; started = true
        let workspace = NSWorkspace.shared.notificationCenter
        for (block, sleep, wake) in [
            ("system", NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            ("display", NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            ("session", NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)
        ] {
            observe(workspace, sleep) { [weak self] in self?.block(block, active: true) }
            observe(workspace, wake) { [weak self] in self?.block(block, active: false) }
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.block("lock", active: true) }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.block("lock", active: false) }
        observe(.default, .NSSystemClockDidChange) { [weak self] in self?.updateDisplayClock() }
        reschedule()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        observers.append((center, token))
    }
    func connect() {
        enabled = true; LumaEnvironment.preferences.set(true, forKey: "codexUsageEnabled")
        error = nil; failures = 0; lastAttemptUptime = -Double.infinity; reschedule()
    }
    func disconnect() {
        enabled = false; LumaEnvironment.preferences.set(false, forKey: "codexUsageEnabled")
        cancel(); timer?.invalidate(); timer = nil; snapshot = nil; error = nil
        updateDisplayClock()
    }
    private func block(_ key: String, active: Bool) {
        let changed = active ? blocks.insert(key).inserted : blocks.remove(key) != nil
        guard changed else { return }
        cancel(); reschedule()
    }
    private func reschedule() {
        timer?.invalidate(); timer = nil; updateDisplayClock()
        guard started, enabled, blocks.isEmpty else { return }
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }; self.now = Date()
                let delay: TimeInterval = self.failures == 0 ? 50 : (self.failures < 3 ? 120 : 300)
                if ProcessInfo.processInfo.systemUptime - self.lastAttemptUptime >= delay { self.refresh() }
            }
        }
        timer.tolerance = 10; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func updateDisplayClock() {
        displayTimer?.invalidate(); displayTimer = nil
        now = Date()
        guard started, enabled, blocks.isEmpty, error == nil,
              let deadline = snapshot?.nextDisplayChange(after: now) else { return }
        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDisplayClock() }
        }
        displayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func refresh() {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard started, enabled, blocks.isEmpty, !refreshing, uptime - lastAttemptUptime >= 5 else { return }
        now = Date(); lastAttemptUptime = uptime
        guard let executable = CodexExecutable.locate() else {
            error = .missingCLI; failures += 1; updateDisplayClock(); return
        }
        refreshing = true; generation += 1
        let serial = generation, request = CodexUsageRequest(); self.request = request
        task = Task { [weak self] in
            do {
                let snapshot = try await request.read(executable: executable)
                guard let self, self.generation == serial, !Task.isCancelled else { return }
                self.snapshot = snapshot; self.error = nil; self.failures = 0
            } catch {
                guard let self, self.generation == serial, !Task.isCancelled else { return }
                self.error = error as? CodexUsageError ?? .unavailable; self.failures += 1
            }
            guard let self, self.generation == serial else { return }
            self.updateDisplayClock(); self.refreshing = false; self.task = nil; self.request = nil
        }
    }
    private func cancel() {
        generation += 1; task?.cancel(); request?.shutdown()
        task = nil; request = nil; refreshing = false
    }
    func stop() {
        cancel(); timer?.invalidate(); timer = nil; snapshot = nil; started = false
        updateDisplayClock()
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
    }
}
