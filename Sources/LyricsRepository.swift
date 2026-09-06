import Foundation

enum LyricsResult: Sendable {
    case available(LyricsPayload)
    case message(String)
    case retry(String)
}

actor LyricsRepository {
    private let root: URL
    private let local: URL
    private let client: BoundedHTTPClient
    private var busy = false
    private var blockedUntil = Date.distantPast
    private var lastRequest = Date.distantPast
    private var misses: [String: Date] = [:]

    init(root: URL = LumaEnvironment.supportDirectory, client: BoundedHTTPClient = BoundedHTTPClient()) {
        self.root = root.appendingPathComponent("LyricsCache", isDirectory: true)
        self.local = root.appendingPathComponent("ImportedLyrics", isDirectory: true)
        self.client = client
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: self.local, withIntermediateDirectories: true)
        var cacheURL = self.root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? cacheURL.setResourceValues(values)
    }
    private func filename(_ track: TrackIdentity) -> String { LumaEnvironment.cacheName(track) + ".json" }
    private func read(_ url: URL, maxAge: TimeInterval? = nil) -> LyricsPayload? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_000_000,
              let data = try? Data(contentsOf: url), let payload = try? JSONDecoder().decode(LyricsPayload.self, from: data),
              !payload.lines.isEmpty, payload.lines.allSatisfy({ $0.time.isFinite && $0.time >= 0 }),
              zip(payload.lines, payload.lines.dropFirst()).allSatisfy({ $0.time <= $1.time }) else { return nil }
        if let maxAge, Date().timeIntervalSince(payload.savedAt) > maxAge { return nil }
        return payload
    }
    func importLocal(_ source: String, for track: TrackIdentity) throws -> LyricsPayload {
        let lines = LRCParser.parse(source)
        guard !lines.isEmpty else {
            throw NSError(domain: "LumaStandby", code: 1, userInfo: [NSLocalizedDescriptionKey: "El archivo no contiene tiempos LRC válidos o supera 512 KB."])
        }
        let payload = LyricsPayload(lines: lines, source: "LRC local · por línea", savedAt: Date())
        try JSONEncoder().encode(payload).write(to: local.appendingPathComponent(filename(track)), options: .atomic)
        return payload
    }
    func clearDownloadedCache() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == "json" { try? FileManager.default.removeItem(at: url) }
        misses.removeAll()
    }
    private func request(_ endpoint: String, items: [URLQueryItem]) async throws -> HTTPReply {
        guard Date() >= blockedUntil else { throw RemoteError.unavailable }
        let pause = 0.65 - Date().timeIntervalSince(lastRequest)
        if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
        try Task.checkCancellation()
        var url = URLComponents(string: "https://lrclib.net/api/" + endpoint)!
        url.queryItems = items
        lastRequest = Date()
        let reply = try await client.get(url.url!)
        if reply.status == 429 { blockedUntil = BoundedHTTPClient.retryDate(reply.retryAfter) }
        return reply
    }
    func load(for track: TrackIdentity, allowNetwork: Bool) async -> LyricsResult {
        let name = filename(track)
        if let saved = read(local.appendingPathComponent(name)) { return .available(saved) }
        guard allowNetwork else { return .message("Letras automáticas desactivadas. Puedes importar un .lrc local.") }
        if let saved = read(root.appendingPathComponent(name), maxAge: 30 * 86400) { return .available(saved) }
        guard !track.id.isEmpty, !track.title.isEmpty, !track.artist.isEmpty,
              track.duration.isFinite, track.duration >= 1, track.duration <= 3600 else {
            return .message("Faltan datos de esta grabación para buscar su letra.")
        }
        if let date = misses[name], Date().timeIntervalSince(date) < 600 { return .message("Sin letra sincronizada para esta versión. Puedes importar un .lrc.") }
        do {
            while busy { try await Task.sleep(nanoseconds: 100_000_000); try Task.checkCancellation() }
            busy = true
            defer { busy = false }
            let reply = try await request("get", items: [
                URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: track.artist),
                URLQueryItem(name: "album_name", value: track.album), URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))
            ])
            if reply.status == 429 { return .retry("El proveedor pidió una pausa; se reintentará automáticamente.") }
            guard reply.status == 200 || reply.status == 404 else { return .retry("El proveedor de letras no respondió. Se reintentará.") }
            var records: [RemoteLyrics] = []
            if reply.status == 200 { records = [try JSONDecoder().decode(RemoteLyrics.self, from: reply.data)] }
            if let record = records.first, record.matches(track), record.instrumental == true { return .message("Pista instrumental.") }
            if let record = records.first, record.matches(track), let payload = payload(record) {
                save(payload, name: name); return .available(payload)
            }
            // A strict search fallback handles collaborative credits and differing album spellings.
            // It never assigns the first search result or fabricates timestamps for plain lyrics.
            let search = try await request("search", items: [
                URLQueryItem(name: "track_name", value: track.title),
                URLQueryItem(name: "artist_name", value: RecordingMatcher.primaryArtist(track.artist))
            ])
            if search.status == 429 { return .retry("El proveedor pidió una pausa; se reintentará automáticamente.") }
            guard search.status == 200 else { return .retry("No se pudo completar la búsqueda de letras.") }
            records = try JSONDecoder().decode([RemoteLyrics].self, from: search.data)
                .filter { $0.matches(track) }
                .sorted {
                    let a = RecordingMatcher.normalized($0.albumName ?? "") == RecordingMatcher.normalized(track.album)
                    let b = RecordingMatcher.normalized($1.albumName ?? "") == RecordingMatcher.normalized(track.album)
                    if a != b { return a }
                    return abs(($0.duration ?? 0) - track.duration) < abs(($1.duration ?? 0) - track.duration)
                }
            for record in records {
                if let payload = payload(record) { save(payload, name: name); return .available(payload) }
            }
            rememberMiss(name)
            return .message("Sin letra sincronizada que coincida con esta grabación. Puedes importar un .lrc.")
        } catch is CancellationError { return .message("") }
        catch { return .retry("Letras temporalmente sin conexión. Se reintentará automáticamente.") }
    }
    private func payload(_ record: RemoteLyrics) -> LyricsPayload? {
        let lines = LRCParser.parse(record.syncedLyrics ?? "")
        return lines.isEmpty ? nil : LyricsPayload(lines: lines, source: "LRCLIB · sincronización por línea", savedAt: Date())
    }
    private func save(_ payload: LyricsPayload, name: String) {
        if let data = try? JSONEncoder().encode(payload), data.count <= 1_000_000 {
            try? data.write(to: root.appendingPathComponent(name), options: .atomic)
            pruneCache()
        }
    }
    private func rememberMiss(_ name: String) {
        if misses.count >= 128, let oldest = misses.min(by: { $0.value < $1.value })?.key { misses.removeValue(forKey: oldest) }
        misses[name] = Date()
    }
    private func pruneCache() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let files = urls.filter { $0.pathExtension == "json" }.map { url -> (URL, Date, Int) in
            let info = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            return (url, info?.contentModificationDate ?? .distantPast, info?.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var size = 0
        for (index, file) in files.enumerated() {
            size += file.2
            if index >= 128 || size > 16 * 1024 * 1024 { try? FileManager.default.removeItem(at: file.0) }
        }
    }
}
private struct RemoteLyrics: Decodable {
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let syncedLyrics: String?
    func matches(_ track: TrackIdentity) -> Bool {
        RecordingMatcher.matches(track: track, title: trackName ?? "", artist: artistName ?? "", duration: duration ?? 0)
    }
}
