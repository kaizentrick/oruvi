// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import Foundation
import Darwin

struct CursorUsageSnapshot {
    let remainingPercent: Int
    let resetLabel: String
    let fetchedAt: Date
    static let maximumAge: TimeInterval = 300

    func isFresh(at now: Date) -> Bool { (0..<Self.maximumAge).contains(now.timeIntervalSince(fetchedAt)) }

    static func decode(_ transcript: String, at date: Date = Date()) throws -> Self {
        struct Reading: Decodable {
            let status: String
            let usedPercent: Double?
            let resetLabel: String?
        }
        let prefix = "ORUVI_CURSOR_USAGE "
        guard let line = transcript.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else {
            throw CursorUsageError.unavailable
        }
        let reading = try JSONDecoder().decode(Reading.self, from: Data(line.dropFirst(prefix.count).utf8))
        if reading.status == "signIn" { throw CursorUsageError.signInRequired }
        guard reading.status == "ok",
              let used = reading.usedPercent, used.isFinite, (0...100).contains(used),
              let reset = reading.resetLabel, (1...40).contains(reset.count),
              reset.rangeOfCharacter(from: .decimalDigits) != nil,
              reset.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw CursorUsageError.dashboardUnavailable
        }
        return Self(remainingPercent: Int((100 - used).rounded(.down)), resetLabel: reset, fetchedAt: date)
    }
}

enum CursorUsageError: Error {
    case missingAside, unavailable, timeout, signInRequired, dashboardUnavailable

    var message: String {
        switch self {
        case .missingAside: return "Instala Aside y su CLI para consultar la cuota de Cursor."
        case .unavailable: return "Abre Aside y vuelve a actualizar."
        case .timeout: return "Grok tardó en responder. Vuelve a actualizar."
        case .signInRequired: return "Inicia sesión en Grok desde Aside y vuelve a actualizar."
        case .dashboardUnavailable: return "Grok no mostró la cuota semanal. Revisa el panel de uso en Aside."
        }
    }
}

/// Aside owns the browser session. The only data returned by this script are
/// the published weekly meter and its reset label.
final class CursorUsageRequest: @unchecked Sendable {
    static let dashboard = "https://grok.com/dashboard/usage"
    static let script = #"""
    const url = "\#(dashboard)";
    // Refresh the dashboard in a temporary tab without disturbing an open view.
    const tab = await openTab(url);
    try {
        let reading = {status: "unavailable"};
        for (let attempt = 0; attempt < 12; attempt++) {
            const result = await tab.evaluate(() => {
                if (location.origin !== "https://grok.com" || location.pathname.replace(/\/$/, "") !== "/dashboard/usage") {
                    return {status: "signIn"};
                }
                const meter = document.querySelector('[role="meter"][aria-label="Weekly included usage"]');
                const card = meter?.closest('[role="region"][aria-label="Weekly included usage"]');
                const used = meter?.getAttribute("aria-valuenow");
                const reset = card?.innerText.split("\n").map(line => line.trim())
                    .map(line => /^Resets\s+(.{1,40})$/i.exec(line)?.[1]).find(Boolean);
                if (used !== null && used !== undefined && used.trim() !== "" && reset) {
                    return {status: "ok", usedPercent: Number(used), resetLabel: reset};
                }
                if (document.querySelector('input[type="password"]')) return {status: "signIn"};
                return {status: "unavailable"};
            }).catch(() => ({status: "unavailable"}));
            reading = result;
            if (reading.status === "ok") break;
            if (attempt < 11) await sleep(500);
        }
        console.log("ORUVI_CURSOR_USAGE " + JSON.stringify(reading));
    } finally {
        await closeTab(tab);
    }
    """#

    private let queue = DispatchQueue(label: "com.kaizentrick.Oruvi.cursor-usage", qos: .utility)
    private var continuation: CheckedContinuation<CursorUsageSnapshot, Error>?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var frames = CodexUsageFrames()
    private var cancelled = false

    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/aside"),
            URL(fileURLWithPath: "/opt/homebrew/bin/aside"),
            URL(fileURLWithPath: "/usr/local/bin/aside")
        ]
        return candidates.first(where: CodexExecutable.isSafeExecutable)
    }

    func read() async throws -> CursorUsageSnapshot {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    start()
                }
            }
        } onCancel: {
            self.queue.async { [self] in
                cancelled = true
                finish(.failure(CancellationError()))
            }
        }
    }

    private func start() {
        guard let executable = Self.executable() else {
            finish(.failure(CursorUsageError.missingAside))
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable.resolvingSymlinksInPath()
        child.arguments = ["mcp", "--host", "local"]
        child.currentDirectoryURL = home
        child.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        process = child
        input = stdin
        output = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            self?.queue.async { [weak self] in self?.receive(bytes) }
        }
        do {
            try child.run()
            try send(["id": 1, "method": "initialize", "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: String],
                "clientInfo": ["name": "Oruvi", "version": "1.0"]
            ]])
            queue.asyncAfter(deadline: .now() + 35) { [weak self] in self?.finish(.failure(CursorUsageError.timeout)) }
        } catch {
            finish(.failure(CursorUsageError.unavailable))
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let input else { throw CursorUsageError.unavailable }
        var request = message
        request["jsonrpc"] = "2.0"
        var bytes = try JSONSerialization.data(withJSONObject: request)
        bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }

    private func receive(_ bytes: Data) {
        guard continuation != nil else { return }
        guard !bytes.isEmpty else { finish(.failure(CursorUsageError.unavailable)); return }
        do {
            for line in try frames.append(bytes) {
                guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = reply["id"] as? Int, id == 1 || id == 2 else { continue }
                guard let result = reply["result"] as? [String: Any], result["isError"] as? Bool != true else {
                    throw CursorUsageError.unavailable
                }
                if id == 1 {
                    try send(["method": "notifications/initialized"])
                    try send(["id": 2, "method": "tools/call", "params": [
                        "name": "repl", "arguments": ["code": Self.script, "title": "Consultar cuota semanal de Cursor"]
                    ]])
                } else {
                    guard let content = result["content"] as? [[String: Any]],
                          let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
                        throw CursorUsageError.unavailable
                    }
                    finish(.success(try CursorUsageSnapshot.decode(text)))
                    return
                }
            }
        } catch {
            finish(.failure(error as? CursorUsageError ?? CursorUsageError.unavailable))
        }
    }

    private func finish(_ result: Result<CursorUsageSnapshot, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if let child = process, child.isRunning {
            child.terminate()
            queue.asyncAfter(deadline: .now() + 0.5) {
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            }
        }
        input = nil
        output = nil
        process = nil
        continuation.resume(with: result)
    }
}
