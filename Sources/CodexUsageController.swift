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
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var blocks = Set<String>()
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var lastAttempt = Date.distantPast
    @ObservationIgnored private var failures = 0

    var selectedBucket: CodexUsageBucket? {
        snapshot?.buckets.first { $0.id == selectedBucketID }
            ?? snapshot?.buckets.first { $0.id == "codex" } ?? snapshot?.buckets.first
    }
    var fresh: Bool { enabled && blocks.isEmpty && error == nil && snapshot?.isFresh(at: now) == true }
    var compactText: String {
        guard fresh, let window = selectedBucket?.limitingWindow(at: now) else { return "—" }
        return "\(window.remainingPercent)%"
    }
    var status: String {
        if !enabled { return "Sin conectar" }
        if !blocks.isEmpty { return "En pausa mientras tu Mac descansa" }
        if let error { return error.message }
        if snapshot == nil && refreshing { return "Consultando Codex…" }
        if snapshot?.ordinaryUsageAllowed == false { return "Codex informa que el uso incluido está bloqueado" }
        if fresh, let window = selectedBucket?.limitingWindow(at: now) {
            return "\(window.remainingPercent)% restante · \(window.title)"
        }
        if snapshot != nil && !fresh { return "Datos pendientes de actualizar" }
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
        reschedule()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        observers.append((center, token))
    }
    func connect() {
        enabled = true; LumaEnvironment.preferences.set(true, forKey: "codexUsageEnabled")
        error = nil; failures = 0; lastAttempt = .distantPast; reschedule()
    }
    func disconnect() {
        enabled = false; LumaEnvironment.preferences.set(false, forKey: "codexUsageEnabled")
        cancel(); timer?.invalidate(); timer = nil; snapshot = nil; error = nil
    }
    private func block(_ key: String, active: Bool) {
        if active { blocks.insert(key) } else { blocks.remove(key) }
        cancel(); reschedule()
    }
    private func reschedule() {
        timer?.invalidate(); timer = nil; now = Date()
        guard started, enabled, blocks.isEmpty else { return }
        refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }; self.now = Date()
                let delay: TimeInterval = self.failures == 0 ? 50 : (self.failures < 3 ? 120 : 300)
                if self.now.timeIntervalSince(self.lastAttempt) >= delay { self.refresh() }
            }
        }
        timer.tolerance = 10; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func refresh() {
        guard started, enabled, blocks.isEmpty, !refreshing, Date().timeIntervalSince(lastAttempt) >= 5 else { return }
        now = Date(); lastAttempt = now
        guard let executable = CodexExecutable.locate() else { error = .missingCLI; failures += 1; return }
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
            self.now = Date(); self.refreshing = false; self.task = nil; self.request = nil
        }
    }
    private func cancel() {
        generation += 1; task?.cancel(); request?.shutdown()
        task = nil; request = nil; refreshing = false
    }
    func stop() {
        cancel(); timer?.invalidate(); timer = nil; snapshot = nil; started = false
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
    }
}
