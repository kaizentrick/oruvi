import Foundation

struct ArtworkPayload: Codable, Sendable {
    var data: Data
    var link: URL?
    var savedAt: Date
}

actor ArtworkRepository {
    private let root: URL
    private let client: BoundedHTTPClient
    private var busy = false
    private var lastRequest = Date.distantPast
    private var blockedUntil = Date.distantPast
    init(root: URL = LumaEnvironment.supportDirectory, client: BoundedHTTPClient = BoundedHTTPClient()) {
        self.root = root.appendingPathComponent("ArtworkCache", isDirectory: true)
        self.client = client
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        var location = self.root
        var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try? location.setResourceValues(attributes)
    }
    func load(for track: TrackIdentity) async throws -> ArtworkPayload? {
        let file = root.appendingPathComponent(LumaEnvironment.cacheName(track) + ".json")
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 6_000_000,
           let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(ArtworkPayload.self, from: data),
           !cached.data.isEmpty, cached.data.count <= 4_000_000, Date().timeIntervalSince(cached.savedAt) < 30 * 86400 { return cached }
        guard track.duration.isFinite, track.duration > 0, !track.artist.isEmpty else { return nil }
        while busy { try await Task.sleep(nanoseconds: 100_000_000); try Task.checkCancellation() }
        busy = true
        defer { busy = false }
        guard Date() >= blockedUntil else { throw RemoteError.unavailable }
        // Apple's documented Search API limit is roughly 20 calls/minute; stay below it.
        let wait = 3.2 - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        try Task.checkCancellation()
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: track.title + " " + RecordingMatcher.primaryArtist(track.artist)),
            URLQueryItem(name: "media", value: "music"), URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "country", value: Locale.current.region?.identifier ?? "MX")
        ]
        lastRequest = Date()
        let reply = try await client.get(components.url!)
        if reply.status == 429 { blockedUntil = BoundedHTTPClient.retryDate(reply.retryAfter); throw RemoteError.unavailable }
        guard reply.status == 200 else { throw RemoteError.unavailable }
        let matches = try JSONDecoder().decode(CatalogResults.self, from: reply.data).results
            .filter { RecordingMatcher.matches(track: track, title: $0.trackName ?? "", artist: $0.artistName ?? "", duration: ($0.trackTimeMillis ?? 0) / 1000) }
            .sorted {
                let a = RecordingMatcher.normalized($0.collectionName ?? "") == RecordingMatcher.normalized(track.album)
                let b = RecordingMatcher.normalized($1.collectionName ?? "") == RecordingMatcher.normalized(track.album)
                return a && !b
            }
        guard let record = matches.first, let original = record.artworkUrl100.flatMap(RecordingMatcher.appleArtworkURL) else { return nil }
        // The returned URL is the fallback if this image service doesn't accept a larger rendition.
        let larger = original.absoluteString.replacingOccurrences(of: #"/[0-9]+x[0-9]+bb\."#, with: "/600x600bb.", options: .regularExpression)
        let imageURL = RecordingMatcher.appleArtworkURL(larger) ?? original
        var image = try await client.get(imageURL, maxBytes: 4_000_000)
        if image.status != 200 && imageURL != original { image = try await client.get(original, maxBytes: 4_000_000) }
        guard image.status == 200, !image.data.isEmpty else { throw RemoteError.unavailable }
        let link = record.trackViewUrl.flatMap(URL.init(string:)).flatMap { url -> URL? in
            guard url.scheme == "https", let host = url.host?.lowercased(), ["music.apple.com", "itunes.apple.com"].contains(host) else { return nil }
            return url
        }
        let payload = ArtworkPayload(data: image.data, link: link, savedAt: Date())
        if let data = try? JSONEncoder().encode(payload) { try? data.write(to: file, options: .atomic); prune() }
        return payload
    }
    /// Spotify supplies its own artwork URL. Never substitute a different catalog image.
    /// Keep only the current decoded image in the model; Spotify artwork is not persisted here.
    func loadSpotify(_ text: String) async throws -> ArtworkPayload? {
        guard let url = ArtworkURLPolicy.spotify(text) else { return nil }
        try Task.checkCancellation()
        let result = try await client.get(url, maxBytes: 4_000_000)
        guard result.status == 200, !result.data.isEmpty else { throw RemoteError.unavailable }
        return ArtworkPayload(data: result.data, link: nil, savedAt: Date())
    }
    func clearCache() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for file in urls where file.pathExtension == "json" { try? FileManager.default.removeItem(at: file) }
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
