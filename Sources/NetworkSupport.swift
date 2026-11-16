import Foundation
import CryptoKit

/// QA launches use an isolated preferences domain and data directory, never the user's settings.
enum LumaEnvironment {
    #if LUMA_QA
    static let isTesting = ProcessInfo.processInfo.arguments.contains("--smoke-test")
    #else
    static let isTesting = false
    #endif
    static let testDomain = "com.kaizentrick.Oruvi.QA.\(ProcessInfo.processInfo.processIdentifier)"
    static let preferences: UserDefaults = {
        if isTesting { return UserDefaults(suiteName: testDomain)! }
        let defaults = UserDefaults.standard
        OruviRelease.migratePreferences(into: defaults)
        return defaults
    }()
    static let supportDirectory: URL = {
        if isTesting { return FileManager.default.temporaryDirectory.appendingPathComponent(testDomain, isDirectory: true) }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let current = appSupport.appendingPathComponent("Oruvi", isDirectory: true)
        let legacy = appSupport.appendingPathComponent("LumaStandby", isDirectory: true)
        if !FileManager.default.fileExists(atPath: current.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: current)
        }
        return current
    }()
    static func cleanTestingData() {
        guard isTesting else { return }
        preferences.removePersistentDomain(forName: testDomain)
        try? FileManager.default.removeItem(at: supportDirectory)
    }
    static func cacheName(_ track: TrackIdentity) -> String {
        SHA256.hash(data: Data(track.cacheKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func removeDownloadedCache(in directory: URL) -> Bool {
        let manager = FileManager.default
        do {
            let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            var succeeded = true
            for entry in entries where entry.pathExtension == "json" {
                do { try manager.removeItem(at: entry) }
                catch let error as CocoaError where error.code == .fileNoSuchFile { continue }
                catch { succeeded = false }
            }
            return succeeded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return true
        } catch {
            return false
        }
    }
}

struct HTTPReply: Sendable {
    let status: Int
    let data: Data
    let retryAfter: String?

    var retryDeadline: TimeInterval? {
        guard status == 429 || (status == 503 && retryAfter != nil) else { return nil }
        return ProcessInfo.processInfo.systemUptime + BoundedHTTPClient.retryDelay(retryAfter)
    }
}
enum RemoteError: Error {
    case invalidURL, invalidResponse, oversized, unavailable
    case rateLimited(until: TimeInterval)
}

final class BoundedHTTPClient: @unchecked Sendable {
    private let session: URLSession
    private static let retryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        config.httpMaximumConnectionsPerHost = 1
        self.session = URLSession(configuration: config)
    }
    func get(_ url: URL, maxBytes: Int = 1_000_000) async throws -> HTTPReply {
        guard maxBytes > 0, ArtworkURLPolicy.allowed(url) else { throw RemoteError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Oruvi/\(OruviRelease.version)", forHTTPHeaderField: "User-Agent")
        try Task.checkCancellation()
        let transfer = BoundedRequest(limit: maxBytes)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                transfer.start(in: session, request: request, continuation: continuation)
            }
        }, onCancel: { transfer.cancel() })
    }
    static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = text.flatMap(Double.init).flatMap { $0.isFinite ? $0 : nil }
        let delay = seconds ?? text.flatMap { retryFormatter.date(from: $0)?.timeIntervalSince(now) } ?? 60
        return max(1, min(delay, 86400))
    }
}
