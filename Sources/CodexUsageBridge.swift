// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import Foundation
import Darwin

enum CodexExecutable {
    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex"),
            home.appendingPathComponent(".codex/packages/standalone/current/bin/codex"),
            home.appendingPathComponent(".local/bin/codex")
        ]
        return candidates.first { isSafeExecutable($0) }
    }
    static func isSafeExecutable(_ url: URL) -> Bool {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.contains("\0") else { return false }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let path = resolved.path, parent = resolved.deletingLastPathComponent().path
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        var fileInfo = stat(), parentInfo = stat()
        guard stat(path, &fileInfo) == 0, stat(parent, &parentInfo) == 0 else { return false }
        let uid = getuid()
        let validFile = (fileInfo.st_mode & S_IFMT) == S_IFREG &&
            (fileInfo.st_uid == 0 || fileInfo.st_uid == uid) &&
            (fileInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0
        let validParent = (parentInfo.st_mode & S_IFMT) == S_IFDIR &&
            (parentInfo.st_uid == 0 || parentInfo.st_uid == uid) &&
            (parentInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0
        return validFile && validParent
    }
    static func validatedHome(_ raw: String?) -> String? {
        guard let raw, raw.hasPrefix("/"), !raw.contains("\0") else { return nil }
        let lexical = URL(fileURLWithPath: raw)
        guard !lexical.pathComponents.contains("..") else { return nil }
        var linkInfo = stat()
        guard lstat(raw, &linkInfo) == 0, (linkInfo.st_mode & S_IFMT) == S_IFDIR else { return nil }
        let resolved = lexical.standardizedFileURL.resolvingSymlinksInPath().path
        var dirInfo = stat()
        let uid = getuid()
        guard stat(resolved, &dirInfo) == 0,
              (dirInfo.st_mode & S_IFMT) == S_IFDIR,
              (dirInfo.st_uid == 0 || dirInfo.st_uid == uid),
              (dirInfo.st_mode & (S_IWGRP | S_IWOTH)) == 0 else { return nil }
        return resolved
    }
}

/// A short-lived read-only app-server connection. Codex owns authentication;
/// Oruvi never opens auth.json, reads Keychain secrets, starts a turn or writes
/// Codex configuration. All process/pipe state is confined to one serial queue.
final class CodexUsageRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.kaizentrick.Oruvi.codex-usage", qos: .utility)
    private var continuation: CheckedContinuation<CodexUsageSnapshot, Error>?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var frames = CodexUsageFrames()
    private var cancelled = false
    private var initialized = false

    func read(executable: URL, timeout: TimeInterval = 15) async throws -> CodexUsageSnapshot {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancelled else { continuation.resume(throwing: CodexUsageError.cancelled); return }
                    self.continuation = continuation
                    start(executable: executable)
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(CodexUsageError.timeout)) }
                }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() { queue.async { [self] in cancelled = true; finish(.failure(CodexUsageError.cancelled)) } }
    func shutdown() {
        queue.sync { [self] in
            cancelled = true
            if let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            finish(.failure(CodexUsageError.cancelled))
        }
    }
    private func start(executable: URL) {
        guard CodexExecutable.isSafeExecutable(executable) else {
            finish(.failure(CodexUsageError.unavailable)); return
        }
        let resolvedExecutable = executable.standardizedFileURL.resolvingSymlinksInPath()
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = resolvedExecutable
        child.arguments = ["app-server", "--listen", "stdio://"]
        child.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        // Retain Codex's chosen home/profile, but never inherit shell injection
        // variables. No shell is used and stderr is never recorded.
        var environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                           "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]
        if let codexHome = CodexExecutable.validatedHome(ProcessInfo.processInfo.environment["CODEX_HOME"]) {
            environment["CODEX_HOME"] = codexHome
        }
        child.environment = environment
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = FileHandle.nullDevice
        process = child; input = stdin; output = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            self?.queue.sync { [weak self] in self?.receive(bytes) }
        }
        child.terminationHandler = { [weak self] _ in
            // Let the final readable bytes drain before reporting early exit.
            self?.queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.finish(.failure(CodexUsageError.unavailable)) }
        }
        do {
            try child.run()
            try send(["id": 1, "method": "initialize", "params": [
                "clientInfo": ["name": "oruvi_usage", "version": "1.0"],
                "capabilities": ["experimentalApi": false]
            ]])
        } catch { finish(.failure(CodexUsageError.unavailable)) }
    }
    private func send(_ value: [String: Any]) throws {
        guard let input else { throw CodexUsageError.unavailable }
        var bytes = try JSONSerialization.data(withJSONObject: value); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }
    private func receive(_ bytes: Data) {
        guard continuation != nil else { return }
        guard !bytes.isEmpty else { finish(.failure(CodexUsageError.unavailable)); return }
        do {
            for line in try frames.append(bytes) {
                guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = response["id"] as? Int, id == 1 || id == 2 else { continue }
                if let error = response["error"] as? [String: Any] {
                    let message = (error["message"] as? String ?? "").lowercased()
                    let login = ["unauthorized", "not logged", "not authenticated", "chatgpt", "authentication"].contains { message.contains($0) }
                    finish(.failure(login ? CodexUsageError.signInRequired : CodexUsageError.unavailable)); return
                }
                guard let result = response["result"] as? [String: Any] else { throw CodexUsageError.invalidResponse }
                if id == 1 && !initialized {
                    initialized = true
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": [:] as [String: String]])
                } else if id == 2 && initialized {
                    let snapshot = try CodexUsageSnapshot.decode(JSONSerialization.data(withJSONObject: result))
                    finish(.success(snapshot)); return
                }
            }
        } catch { finish(.failure(CodexUsageError.invalidResponse)) }
    }
    private func finish(_ result: Result<CodexUsageSnapshot, Error>) {
        guard let continuation else { return }; self.continuation = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        if let child = process, child.isRunning {
            child.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
            }
        }
        input = nil; output = nil; process = nil
        continuation.resume(with: result)
    }
}
