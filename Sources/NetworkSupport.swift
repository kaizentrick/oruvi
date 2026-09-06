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
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LumaStandby", isDirectory: true)
    }()
    static func cleanTestingData() {
        guard isTesting else { return }
        preferences.removePersistentDomain(forName: testDomain)
        try? FileManager.default.removeItem(at: supportDirectory)
    }
    static func cacheName(_ track: TrackIdentity) -> String {
        SHA256.hash(data: Data(track.cacheKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct HTTPReply: Sendable {
    let status: Int
    let data: Data
    let retryAfter: String?
}
enum RemoteError: Error { case invalidURL, invalidResponse, oversized, unavailable }

/// Rejects redirects away from the requested provider. No arbitrary image hosts, HTTP or cookies.
private final class SafeRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url,
              ArtworkURLPolicy.redirect(from: original, to: target) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
final class BoundedHTTPClient: @unchecked Sendable {
    private let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 18
        config.httpMaximumConnectionsPerHost = 1
        self.session = URLSession(configuration: config, delegate: SafeRedirects(), delegateQueue: nil)
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
    static func retryDate(_ value: String?, now: Date = Date()) -> Date {
        if let value, let seconds = Double(value), seconds.isFinite {
            return now.addingTimeInterval(max(1, min(seconds, 86400)))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return value.flatMap { formatter.date(from: $0) } ?? now.addingTimeInterval(60)
    }
}
