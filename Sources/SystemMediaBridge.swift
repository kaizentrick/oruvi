// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension Notification.Name {
    static let oruviSystemMediaChanged = Notification.Name("com.kaizentrick.Oruvi.systemMediaChanged")
}

/// Owns one event-driven helper, not a second playback polling loop. Every helper
/// and pipe is bounded; nothing is downloaded or written to disk at runtime.
final class SystemMediaBridge: @unchecked Sendable {
    static let shared = SystemMediaBridge()
    private let queue = DispatchQueue(label: "com.kaizentrick.Oruvi.systemMedia", qos: .utility)
    private let lock = NSLock()
    private var cached: SystemMediaSnapshot?
    private var enabled = false
    private var process: Process?
    private var pipe: Pipe?
    private var generation = 0
    private var frames = SystemMediaFrames()

    var current: SystemMediaSnapshot? {
        lock.lock(); defer { lock.unlock() }; return cached
    }
    private func publish(_ value: SystemMediaSnapshot?) {
        lock.lock(); let changed = cached != value; cached = value; lock.unlock()
        if changed {
            DispatchQueue.main.async { NotificationCenter.default.post(name: .oruviSystemMediaChanged, object: nil) }
        }
    }
    func setEnabled(_ value: Bool) {
        queue.async { [self] in
            guard enabled != value else { return }
            enabled = value
            if value { start() } else { stop() }
        }
    }
    /// Explicit reconnect is the only immediate retry after a helper failure.
    func reconnect() {
        queue.async { [self] in guard enabled else { return }; stop(); start() }
    }
    private static func makeProcess(_ arguments: [String]) -> Process? {
        guard let resources = Bundle.main.resourceURL,
              let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let script = resources.appendingPathComponent("mediaremote-adapter.pl")
        let framework = frameworks.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.path) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        task.arguments = [script.path, framework.path] + arguments
        // Do not inherit injected Perl/module/library search paths from the caller.
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        task.standardInput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        return task
    }
    private func start() {
        generation += 1
        let session = generation
        guard let task = Self.makeProcess(["stream", "--no-diff", "--debounce=100", "--micros", "--allow-missing-title"]) else { publish(nil); return }
        let output = Pipe()
        frames = SystemMediaFrames(); process = task; pipe = output
        task.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            self?.queue.async { [weak self] in
                guard let self, self.generation == session else { return }
                if bytes.isEmpty { self.stop(); return }
                do {
                    for frame in try self.frames.append(bytes) {
                        guard let envelope = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
                              envelope["type"] as? String == "data", envelope["diff"] as? Bool != true else { continue }
                        let payload = envelope["payload"] as? [String: Any] ?? [:]
                        self.publish(SystemMediaSnapshot(payload: payload, uptime: ProcessInfo.processInfo.systemUptime, epoch: Date().timeIntervalSince1970))
                    }
                } catch { self.stop() }
            }
        }
        task.terminationHandler = { [weak self] _ in
            self?.queue.async { [weak self] in
                guard let self, self.generation == session else { return }; self.stop()
            }
        }
        do { try task.run() } catch { stop() }
    }
    private func stop() {
        generation += 1
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let task = process { Self.terminate(task) }
        pipe = nil; process = nil; frames = SystemMediaFrames(); publish(nil)
    }
    private static func terminate(_ task: Process) {
        guard task.isRunning else { return }
        task.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
            if task.isRunning { _ = kill(task.processIdentifier, SIGKILL) }
        }
    }

    /// Only called on PlayerRouter's serial background queue, never on the UI.
    /// A fresh get avoids sending a seek for yesterday's active session.
    func readNow() -> SystemMediaSnapshot? {
        guard let data = Self.run(["get", "--micros", "--allow-missing-title"]),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return SystemMediaSnapshot(payload: payload, uptime: ProcessInfo.processInfo.systemUptime, epoch: Date().timeIntervalSince1970)
    }
    func send(_ command: String, position: Double, expected: SystemMediaSnapshot) -> [String: Any] {
        // Recheck immediately before dispatch; never seek or skip an unrelated item.
        guard let fresh = readNow(), fresh.id == expected.id, fresh.bundleID == expected.bundleID else {
            return ["status": "transition", "message": "El contenido cambió; vuelve a pulsar el control."]
        }
        let arguments: [String]
        switch command {
        case "toggle": arguments = ["send", "2"]
        case "next", "previous":
            guard !fresh.prohibitsSkip else { return ["status": "error", "message": "Este contenido no permite saltar."] }
            arguments = ["send", command == "next" ? "4" : "5"]
        case "seek":
            guard position.isFinite, position >= 0, fresh.duration > 0, !fresh.prohibitsSkip else {
                return ["status": "error", "message": "Este contenido no permite cambiar de posición."]
            }
            arguments = ["seek", String(Int64(min(position, fresh.duration) * 1_000_000))]
        default: return ["status": "error", "message": "Control no disponible para este reproductor."]
        }
        guard Self.run(arguments) != nil else {
            return ["status": "error", "message": "El sistema no pudo entregar el control al reproductor."]
        }
        return ["status": "ok"] // Delivery, not a fabricated playback-state change.
    }
    private final class Output: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var overflow = false
        func append(_ bytes: Data) {
            lock.lock(); defer { lock.unlock() }
            guard !overflow, data.count + bytes.count <= SystemMediaFrames.maximumBytes else { overflow = true; return }
            data.append(bytes)
        }
        func result() -> Data? { lock.lock(); defer { lock.unlock() }; return overflow ? nil : data }
    }
    private static func run(_ arguments: [String]) -> Data? {
        guard !Thread.isMainThread, let task = makeProcess(arguments) else { return nil }
        let output = Pipe(), storage = Output(), exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        task.standardOutput = output
        task.terminationHandler = { _ in exited.signal() }
        do { try task.run() } catch { return nil }
        // Drain concurrently: waiting for a process with a full artwork pipe deadlocks.
        DispatchQueue.global(qos: .utility).async {
            while true {
                let bytes = output.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                storage.append(bytes)
                if storage.result() == nil { terminate(task); break }
            }
            drained.signal()
        }
        guard exited.wait(timeout: .now() + 2) == .success else { terminate(task); return nil }
        guard drained.wait(timeout: .now() + 0.5) == .success, task.terminationStatus == 0 else { return nil }
        return storage.result()
    }
}
