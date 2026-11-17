import Foundation
import ImageIO

struct ArtworkPayload: Codable, Sendable {
    var data: Data
    var link: URL?
    var savedAt: Date
}

actor ArtworkRepository {
    private let root: URL
    private let client: BoundedHTTPClient
    private let lookupQueue = MediaLookupQueue()
    private var lastRequest: TimeInterval = -.infinity
    private var appleBlockedUntil: TimeInterval = 0
    private var spotifyBlockedUntil: TimeInterval = 0
    private var cacheGeneration = 0
    private var catalogMisses: [String: TimeInterval] = [:]

    #if LUMA_QA
    var queuedLookupCount: Int { lookupQueue.waitingCount }
    #endif
    private static let sizePattern = try! NSRegularExpression(pattern: #"/[0-9]+x[0-9]+bb\."#)

    init(root: URL = LumaEnvironment.supportDirectory, client: BoundedHTTPClient = BoundedHTTPClient()) {
        self.root = root.appendingPathComponent("ArtworkCache", isDirectory: true)
        self.client = client
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        var location = self.root
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try? location.setResourceValues(attributes)
    }
    func load(for track: TrackIdentity) async throws -> ArtworkPayload? {
        let name = LumaEnvironment.cacheName(track)
        let file = root.appendingPathComponent(name + ".json")
        if let cached = cachedArtwork(at: file) { return cached }
        if hasRecentMiss(name) { return nil }
        guard track.duration.isFinite, track.duration > 0, !track.artist.isEmpty else { return nil }
        let generation = cacheGeneration
        let waited = try await lookupQueue.acquire()
        defer { lookupQueue.release() }
        try Task.checkCancellation()
        if waited {
            if let cached = cachedArtwork(at: file) { return cached }
            if hasRecentMiss(name) { return nil }
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= appleBlockedUntil else { throw RemoteError.rateLimited(until: appleBlockedUntil) }
        // Apple's documented Search API limit is roughly 20 calls/minute; stay below it.
        let wait = 3.2 - (now - lastRequest)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        try Task.checkCancellation()
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: track.title + " " + RecordingMatcher.primaryArtist(track.artist)),
            URLQueryItem(name: "media", value: "music"), URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "MX")
        ]
        lastRequest = ProcessInfo.processInfo.systemUptime
        let reply = try await client.get(components.url!)
        try checkAppleLimit(reply)
        guard reply.status == 200 else { throw RemoteError.unavailable }
        let matches = try JSONDecoder().decode(CatalogResults.self, from: reply.data).results
            .filter { RecordingMatcher.matches(track: track, title: $0.trackName ?? "", artist: $0.artistName ?? "", duration: ($0.trackTimeMillis ?? 0) / 1000) }
            .sorted {
                let a = RecordingMatcher.normalized($0.collectionName ?? "") == RecordingMatcher.normalized(track.album)
                let b = RecordingMatcher.normalized($1.collectionName ?? "") == RecordingMatcher.normalized(track.album)
                if a != b { return a }
                return abs(($0.trackTimeMillis ?? 0) / 1000 - track.duration) <
                    abs(($1.trackTimeMillis ?? 0) / 1000 - track.duration)
            }
        guard let record = matches.first(where: { $0.artworkUrl100.flatMap(RecordingMatcher.appleArtworkURL) != nil }),
              let original = record.artworkUrl100.flatMap(RecordingMatcher.appleArtworkURL) else {
            if generation == cacheGeneration, !Task.isCancelled { rememberMiss(name) }
            return nil
        }
        // The returned URL is the fallback if this image service doesn't accept a larger rendition.
        let sourceURL = original.absoluteString
        let larger = Self.sizePattern.stringByReplacingMatches(
            in: sourceURL, range: NSRange(sourceURL.startIndex..<sourceURL.endIndex, in: sourceURL), withTemplate: "/600x600bb.")
        let imageURL = RecordingMatcher.appleArtworkURL(larger) ?? original
        var image = try? await client.get(imageURL, maxBytes: 4_000_000)
        try checkAppleLimit(image)
        try Task.checkCancellation()
        if (image?.status != 200 || !Self.isImage(image?.data ?? Data())), imageURL != original {
            image = try await client.get(original, maxBytes: 4_000_000)
            try checkAppleLimit(image)
        }
        guard let image, image.status == 200, Self.isImage(image.data) else { throw RemoteError.invalidResponse }
        let link = record.trackViewUrl.flatMap(URL.init(string:)).flatMap { url -> URL? in
            guard url.scheme == "https", let host = url.host?.lowercased(), ["music.apple.com", "itunes.apple.com"].contains(host) else { return nil }
            return url
        }
        let payload = ArtworkPayload(data: image.data, link: link, savedAt: Date())
        // A request started before clearing can finish for playback without repopulating the cache.
        if generation == cacheGeneration, !Task.isCancelled, let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: file, options: .atomic)
            prune()
        }
        return payload
    }
    private func hasRecentMiss(_ name: String) -> Bool {
        guard let deadline = catalogMisses[name] else { return false }
        return ProcessInfo.processInfo.systemUptime < deadline
    }
    private func rememberMiss(_ name: String) {
        if catalogMisses.count >= 64, let oldest = catalogMisses.min(by: { $0.value < $1.value })?.key {
            catalogMisses.removeValue(forKey: oldest)
        }
        catalogMisses[name] = ProcessInfo.processInfo.systemUptime + 600
    }
    private func checkAppleLimit(_ reply: HTTPReply?) throws {
        if let deadline = reply?.retryDeadline {
            appleBlockedUntil = deadline
            throw RemoteError.rateLimited(until: deadline)
        }
    }
    private func cachedArtwork(at file: URL) -> ArtworkPayload? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 6_000_000,
              let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(ArtworkPayload.self, from: data),
              (0..<30 * 86400).contains(Date().timeIntervalSince(cached.savedAt)), Self.isImage(cached.data) else { return nil }
        return cached
    }
    /// Spotify supplies its own artwork URL. Never substitute a different catalog image.
    /// Keep only the current decoded image in the model; Spotify artwork is not persisted here.
    func loadSpotify(_ text: String) async throws -> ArtworkPayload? {
        guard let url = ArtworkURLPolicy.spotify(text) else { return nil }
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime >= spotifyBlockedUntil else {
            throw RemoteError.rateLimited(until: spotifyBlockedUntil)
        }
        let result = try await client.get(url, maxBytes: 4_000_000)
        if let deadline = result.retryDeadline {
            spotifyBlockedUntil = max(spotifyBlockedUntil, deadline)
            throw RemoteError.rateLimited(until: spotifyBlockedUntil)
        }
        guard result.status == 200, Self.isImage(result.data) else { throw RemoteError.invalidResponse }
        return ArtworkPayload(data: result.data, link: nil, savedAt: Date())
    }
    private static func isImage(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= 4_000_000,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) != nil && CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete
    }
    func clearCache() -> Bool {
        cacheGeneration &+= 1
        catalogMisses.removeAll()
        return LumaEnvironment.removeDownloadedCache(in: root)
    }
    private func prune() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let sorted = urls.filter { $0.pathExtension == "json" }.map { url -> (URL, Date, Int) in
            let value = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, value?.contentModificationDate ?? .distantPast, value?.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var bytes = 0
        for (index, item) in sorted.enumerated() {
            bytes += item.2
            if index >= 64 || bytes > 32 * 1024 * 1024 { try? FileManager.default.removeItem(at: item.0) }
        }
    }
}
private struct CatalogResults: Decodable { let results: [CatalogSong] }
private struct CatalogSong: Decodable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let trackTimeMillis: Double?
    let artworkUrl100: String?
    let trackViewUrl: String?
}
