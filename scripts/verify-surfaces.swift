import AppKit
import os
import Sparkle

/// Uses the real model, but never starts it, opens a window, prompts for access,
/// launches a player or contacts artwork/lyrics services. Preferences are isolated.
@main
struct VerifySurfaces {
    @MainActor static func main() async throws {
        precondition(LumaEnvironment.isTesting)
        let defaults = LumaEnvironment.preferences
        defaults.set("music", forKey: "playerPreference")
        defaults.set(false, forKey: "musicEnabled")
        defaults.set(false, forKey: "notchMusicEnabled")
        let model = StandbyModel.shared
        defer { model.shutdown(); LumaEnvironment.cleanTestingData() }
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            count += 1; precondition(condition(), message)
        }
        func noUpdate(_ reason: SPUNoUpdateFoundReason) -> NSError {
            NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                    userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)])
        }
        expect(OruviUpdates.noUpdateStatus(for: noUpdate(.onLatestVersion)) == "Oruvi está al día.",
               "Sparkle's no-update result must not become a feed error")
        expect(OruviUpdates.noUpdateStatus(for: noUpdate(.systemIsTooOld)) != "Oruvi está al día.",
               "an incompatible update must not be reported as the latest version")
        expect(OruviUpdates.noUpdateStatus(for: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.signatureError.rawValue))) == nil,
               "preserve errors when the signature fails")
        expect(OruviUpdates.noUpdateStatus(for: NSError(domain: "Other", code: Int(SUError.noUpdateError.rawValue))) == nil,
               "only Sparkle's no-update error has special meaning")
        let badSignature = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.validationError.rawValue))
        let signedFeedFailure = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.appcastParseError.rawValue),
                                        userInfo: [NSUnderlyingErrorKey: badSignature])
        expect(OruviUpdates.failureStatus(for: signedFeedFailure).contains("firma"),
               "Sparkle wraps public feed integrity errors as appcast parse failures")
        let signedArchiveFailure = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationError.rawValue),
                                           userInfo: [NSUnderlyingErrorKey: badSignature])
        expect(OruviUpdates.failureStatus(for: signedArchiveFailure).contains("firma"),
               "installer failures should report the underlying signature error")
        expect(OruviUpdates.failureStatus(for: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue))).contains("descargar"),
               "a download failure should explain the failed operation")
        expect(OruviUpdates.failureStatus(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)).contains("conexión"),
               "a network failure still offers connection troubleshooting")
        model.automaticLyrics = false; model.automaticArtwork = false
        model.contentTypeface = .rounded
        expect(model.lyricTypeface == .rounded && model.lyricSizePercent == 100, "existing preferences are inherited at the original size")
        model.lyricTypefaceOverride = .monospaced
        expect(model.lyricTypeface == .monospaced && model.contentTypeface == .rounded, "lyric fonts are independent and persistent")
        expect(defaults.string(forKey: "lyricTypeface") == "monospaced", "store the explicit lyric family")
        model.lyricTypefaceOverride = nil
        expect(model.lyricTypeface == .rounded && defaults.object(forKey: "lyricTypeface") == nil, "reset restores inheritance")
        model.lyricSizePercent = 200
        expect(model.lyricSizePercent == 135 && defaults.double(forKey: "lyricSizePercent") == 135, "save the bounded lyric size")
        model.lyricSizePercent = .nan
        expect(model.lyricSizePercent == 100 && defaults.double(forKey: "lyricSizePercent") == 100, "invalid lyric sizes reset safely")
        model.notchPlayerPreference = .spotify
        expect(model.playerPreference == .music, "Notch leaves Standby selection intact")
        expect(model.effectivePlayerPreference == .spotify, "desktop uses Notch preference")
        expect(!model.connected, "changing unused model does not start a bridge")
        model.isVisible = true; model.refreshPower()
        expect(model.playbackSurface == .standby, "visible presentation uses Standby")
        expect(model.effectivePlayerPreference == .music, "Standby uses its own source")
        model.track = TrackIdentity(id: "synthetic", title: "Synthetic", artist: "QA", album: "QA", duration: 120)
        model.notchPlayerPreference = .automatic
        expect(model.hasTrack && model.effectivePlayerPreference == .music, "editing hidden Notch cannot clear active Standby")
        model.isVisible = false; model.refreshPower()
        expect(model.playbackSurface == .notch && model.effectivePlayerPreference == .automatic, "restore Notch choice on exit")
        expect(!model.hasTrack, "clear old surface metadata before next sample")
        model.playerPreference = .spotify
        expect(model.notchPlayerPreference == .automatic, "editing Standby preserves Notch")
        model.isVisible = true; model.refreshPower()
        expect(model.effectivePlayerPreference == .spotify, "new Standby choice survives handoff")
        model.connected = true
        model.apply(["status": "ok", "source": "com.spotify.client", "id": "spotify:qa",
                     "title": "QA song", "duration": 120, "position": 12, "playing": true])
        model.lines = [LyricLine(id: 0, time: 0, text: "Synthetic lyric")]
        model.activeLine = 0
        model.refreshPower()
        expect(model.currentLyricText == "Synthetic lyric", "power notifications preserve the visible lyric and playback anchor")
        model.energyMode = .saver
        expect(model.currentLyricText == "Synthetic lyric", "changing cadence does not put playback back in recovery")
        defaults.set(true, forKey: "musicEnabled")
        defaults.set(true, forKey: "notchMusicEnabled")
        model.notchPlayerPreference = .spotify
        let beforeHandoff = model.anchor
        model.setNotchVisible(true)
        model.isVisible = false; model.refreshPower()
        expect(model.playbackSurface == .notch && model.connected && model.hasTrack && !model.isResynchronizing,
               "returning to the same opted-in provider keeps its active playback")
        model.isVisible = true; model.setNotchVisible(false); model.refreshPower()
        expect(model.playbackSurface == .standby && model.anchor == beforeHandoff && model.currentLyricText == "Synthetic lyric",
               "opening Standby for the same provider keeps its position and the current lyric")
        model.notchPlayerPreference = .automatic
        defaults.set(false, forKey: "musicEnabled")
        defaults.set(false, forKey: "notchMusicEnabled")
        model.apply(["status": "stopped"])
        expect(model.hasTrack && model.isResynchronizing, "a single stopped result retains the recording")
        model.refreshPower()
        model.apply(["status": "stopped"])
        expect(!model.hasTrack && !model.isResynchronizing, "a power notification does not reset stopped confirmation")
        model.apply(["status": "denied"])
        expect(model.notchPlayerPreference == .automatic, "denial cannot change other surface selection")
        expect(!model.connected && !model.isResynchronizing, "denial suspends current connection and ends resynchronizing")
        model.isVisible = false; model.refreshPower()
        expect(model.effectivePlayerPreference == .automatic && !model.connected, "respect independent saved opt-out")
        model.setNativeWidgetPresence(true)
        expect(model.needsPlayback, "desktop widget keeps the single sampler eligible with notch hidden")
        expect(defaults.object(forKey: "nativeWidgetInUse") == nil, "placement belongs to macOS, not a saved app flag")
        model.screenSleeping = true
        expect(!model.needsPlayback, "sleep suspends desktop playback")
        model.screenSleeping = false
        model.setNativeWidgetPresence(false)
        expect(!model.needsPlayback, "no surface needs playback after desktop opt-out")
        model.apply(["status": "ok", "source": "oruvi.system", "id": "system:qa", "title": "QA video", "artist": "", "album": "", "duration": 0, "position": 12, "playing": true, "systemBundleID": "com.example.Player"])
        expect(model.activePlayer == .system && model.hasTrack, "system video enters real model")
        expect(!model.playbackOptionsAvailable, "system cannot invent shuffle/repeat support")
        expect(!model.canSeek, "a stream with no duration cannot advertise seeking")
        model.fetchLyrics()
        expect(model.lyricsAvailability == .unavailable, "video metadata never requests music lyrics")
        model.musicShowsLyrics = true
        expect(!model.hasLyrics && !model.visibleLyrics, "a saved lyrics preference cannot show an empty pane")
        model.toggleLyrics()
        expect(model.musicShowsLyrics, "the unavailable control cannot overwrite the saved preference")
        model.lines = [LyricLine(id: 0, time: 0, text: "Synthetic lyric")]
        expect(model.hasLyrics && model.visibleLyrics, "available lyrics follow the saved preference")
        model.toggleLyrics()
        expect(model.hasLyrics && !model.visibleLyrics, "the button can still hide a real lyric")
        model.lines = []
        expect(model.playerPreference == .spotify && model.notchPlayerPreference == .automatic, "system playback preserves independent selectors")
        let widgets = NativeWidgetController(model: model)
        model.connected = true
        let ready = widgets.makeSnapshot()
        expect(ready.state == .ready && ready.canControl, "native snapshot has real content")
        expect(ready.trackID == model.track.id && ready.sourceID == "oruvi.system", "snapshot preserves active identity")
        expect(ready.preference == "automatic", "native widget preserves automatic selection")
        model.track.duration = 120
        expect(model.canSkip && model.canSeek, "known duration and a permitted session enable seeking")
        model.systemProhibitsSkip = true
        expect(!model.canSkip && !model.canSeek && !widgets.makeSnapshot().canSkip,
               "notch, Standby and native widget share system restrictions")
        model.screenSleeping = true
        let asleep = widgets.makeSnapshot()
        expect(asleep.state == .sleeping && !asleep.canControl && asleep.artwork == nil, "sleep snapshot removes private media")
        model.screenSleeping = false; model.connected = false
        expect(widgets.makeSnapshot().state == .disconnected, "disconnect cannot show playable media")
        model.connected = true; model.track = .empty
        expect(widgets.makeSnapshot().state == .idle, "empty session is not fabricated playback")
        expect(model.playerPreference == .spotify && model.notchPlayerPreference == .automatic, "widget never rewrites independent selectors")
        expect(!model.nativeWidgetInUse, "removing widget releases its sampler demand")
        model.useDemo()
        expect(model.canSkip && model.canSeek, "demo clears restrictions inherited from the last video")
        model.systemProhibitsSkip = true
        let protected = model.anchor
        model.control("next")
        model.control("seek", position: 100)
        expect(model.anchor == protected, "model rejects restricted controls even if a gesture already started")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkFixture.self]
        let session = URLSession(configuration: configuration)
        let covers = StandbyModel(artworkRepository: ArtworkRepository(client: BoundedHTTPClient(session: session)))
        defer { covers.shutdown(); session.invalidateAndCancel() }
        covers.connected = true
        covers.setNativeWidgetPresence(true)
        func applySpotify(_ path: String, id: String = "spotify:track:qa", embedded: Data? = nil) {
            var snapshot: [String: Any] = ["status": "ok", "source": PlayerSource.spotify.rawValue,
                                           "id": id, "title": "QA song", "artist": "QA", "duration": 120,
                                           "artworkURL": path.isEmpty ? "" : "https://i.scdn.co/" + path]
            if let embedded { snapshot["systemArtwork"] = embedded }
            covers.apply(snapshot)
        }
        applySpotify("original")
        await until { covers.artworkStatus == "Portada de Spotify" }
        guard let first = covers.artwork else { preconditionFailure("fixture cover must decode") }
        applySpotify("pending")
        await until { ArtworkFixture.usedPendingRequest }
        expect(covers.artwork === first, "retain the visible cover while Spotify retrieves its replacement")
        applySpotify("")
        covers.automaticArtwork.toggle()
        expect(covers.artworkStatus == "Recuperando portada…", "omitted URLs and Apple-catalog settings do not interrupt Spotify")
        let corruptArtwork = Data([0, 1, 2, 3])
        applySpotify("replacement", embedded: corruptArtwork)
        await until { covers.artworkStatus == "Portada de Spotify" }
        expect(covers.artwork != nil && covers.artwork !== first, "a later Spotify URL replaces the artwork even when embedded data is corrupt")
        applySpotify("replacement")
        expect(covers.artworkStatus == "Portada de Spotify", "unchanged Spotify URLs keep the decoded cover")
        applySpotify("replacement", embedded: ArtworkFixture.png)
        await until { covers.artworkStatus == "Portada del reproductor" }
        applySpotify("different")
        expect(covers.artworkStatus == "Portada del reproductor", "prefer embedded artwork while it is valid for the same song")
        applySpotify("", id: "spotify:track:next")
        expect(covers.artwork == nil, "a different song never inherits Spotify's previous cover or URL")
        applySpotify("late", id: "spotify:track:next")
        await until { covers.artworkStatus == "Portada de Spotify" }
        expect(covers.artwork != nil, "a URL arriving after the song did should be used immediately")

        let support = LumaEnvironment.supportDirectory
        let client = BoundedHTTPClient(session: session)
        let lyricRepository = LyricsRepository(root: support, client: client)
        let artworkRepository = ArtworkRepository(root: support, client: client)
        let track = TrackIdentity(id: "cache-qa", title: "Cache QA", artist: "QA Artist", album: "QA Album", duration: 120)
        let name = LumaEnvironment.cacheName(track) + ".json"
        let lyricFile = support.appendingPathComponent("LyricsCache").appendingPathComponent(name)
        let artworkFile = support.appendingPathComponent("ArtworkCache").appendingPathComponent(name)
        async let pendingLyrics = lyricRepository.load(for: track, allowNetwork: true)
        async let pendingArtwork = artworkRepository.load(for: track)
        await until { ArtworkFixture.isHolding("/api/get") && ArtworkFixture.isHolding("/600x600bb.png") }
        let clearedLyrics = await lyricRepository.clearDownloadedCache()
        let clearedArtwork = await artworkRepository.clearCache()
        expect(clearedLyrics && clearedArtwork, "empty caches can be cleared during downloads")
        ArtworkFixture.release("/api/get")
        ArtworkFixture.release("/600x600bb.png")
        guard case .available(let lyrics) = await pendingLyrics, try await pendingArtwork != nil else {
            preconditionFailure("downloads already in progress can still supply the current song")
        }
        let manager = FileManager.default
        expect(!manager.fileExists(atPath: lyricFile.path) && !manager.fileExists(atPath: artworkFile.path),
               "downloads that started before clearing must not recreate either cache file")
        let priorLyricsRequests = ArtworkFixture.requestCount("/api/get")
        let priorArtworkRequests = ArtworkFixture.requestCount("/search")
        ArtworkFixture.holdNext("/api/get")
        ArtworkFixture.holdNext("/600x600bb.png")
        async let freshLyrics = lyricRepository.load(for: track, allowNetwork: true)
        async let freshArtwork = artworkRepository.load(for: track)
        await until { ArtworkFixture.isHolding("/api/get") && ArtworkFixture.isHolding("/600x600bb.png") }
        async let repeatedLyrics = lyricRepository.load(for: track, allowNetwork: true)
        async let repeatedArtwork = artworkRepository.load(for: track)
        await until { await lyricRepository.queuedLookupCount == 1 }
        await until { await artworkRepository.queuedLookupCount == 1 }
        ArtworkFixture.release("/api/get")
        ArtworkFixture.release("/600x600bb.png")
        guard case .available = await freshLyrics, case .available = await repeatedLyrics,
              try await freshArtwork != nil, try await repeatedArtwork != nil else {
            preconditionFailure("downloaded media must be available to both callers")
        }
        expect(ArtworkFixture.requestCount("/api/get") == priorLyricsRequests + 1
               && ArtworkFixture.requestCount("/search") == priorArtworkRequests + 1,
               "queued requests reuse a freshly saved result for the same recording")
        expect(manager.fileExists(atPath: lyricFile.path) && manager.fileExists(atPath: artworkFile.path),
               "downloads starting after clearing may populate the cache")
        let imported = support.appendingPathComponent("ImportedLyrics")
        try manager.createDirectory(at: imported, withIntermediateDirectories: true)
        let importedFile = imported.appendingPathComponent(name)
        try JSONEncoder().encode(lyrics).write(to: importedFile)
        covers.clearLyricsCache()
        expect(covers.isClearingDownloadCache, "settings indicate cache clearing while in progress")
        await until { !covers.isClearingDownloadCache }
        expect(covers.cacheClearStatus.contains("vacía") && manager.fileExists(atPath: importedFile.path)
               && !manager.fileExists(atPath: lyricFile.path) && !manager.fileExists(atPath: artworkFile.path),
               "settings confirm that both downloaded caches were cleared and imported lyrics remain")
        let instrumental = TrackIdentity(id: "instrumental-qa", title: "Instrumental QA", artist: "QA Artist", album: "QA Album", duration: 120)
        let beforeInstrumental = ArtworkFixture.requestCount("/api/get")
        guard case .unavailable = await lyricRepository.load(for: instrumental, allowNetwork: true),
              case .unavailable = await lyricRepository.load(for: instrumental, allowNetwork: true) else {
            preconditionFailure("an explicitly instrumental track has no synchronized lyrics")
        }
        expect(ArtworkFixture.requestCount("/api/get") == beforeInstrumental + 1,
               "replaying a confirmed instrumental track reuses the cached absence of lyrics")
        _ = await lyricRepository.clearDownloadedCache()
        guard case .unavailable = await lyricRepository.load(for: instrumental, allowNetwork: true) else {
            preconditionFailure("a renewed lookup for the instrumental track must finish")
        }
        expect(ArtworkFixture.requestCount("/api/get") == beforeInstrumental + 2,
               "clearing the cache resets the confirmed absence of lyrics")

        let referenceTime = Date(timeIntervalSince1970: 1_767_225_600)
        expect(BoundedHTTPClient.retryDelay(" 120 ", now: referenceTime) == 120
               && BoundedHTTPClient.retryDelay("Thu, 01 Jan 2026 00:02:00 GMT", now: referenceTime) == 120
               && BoundedHTTPClient.retryDelay("Wed, 31 Dec 2025 23:59:59 GMT", now: referenceTime) == 1
               && BoundedHTTPClient.retryDelay(nil, now: referenceTime) == 60,
               "Retry-After supports seconds and HTTP dates with a bounded fallback")
        let rateTrack = TrackIdentity(id: "rate-qa", title: "Rate QA", artist: "QA Artist", album: "QA Album", duration: 120)
        let rateLyrics = LyricsRepository(root: support, client: client)
        let rateArtwork = ArtworkRepository(root: support, client: client)
        let lyricsBeforeLimit = ArtworkFixture.requestCount("/api/get")
        guard case .rateLimited(let lyricsDeadline) = await rateLyrics.load(for: rateTrack, allowNetwork: true),
              case .rateLimited(let repeatedDeadline) = await rateLyrics.load(for: rateTrack, allowNetwork: true) else {
            preconditionFailure("LRCLIB 429 with a large declared body must retain its retry deadline")
        }
        expect(lyricsDeadline == repeatedDeadline && lyricsDeadline > ProcessInfo.processInfo.systemUptime + 30
               && ArtworkFixture.requestCount("/api/get") == lyricsBeforeLimit + 1,
               "LRCLIB returns the existing deadline without sending a second request")
        let appleBeforeLimit = ArtworkFixture.requestCount("/search")
        let fallbackBeforeLimit = ArtworkFixture.requestCount("/rate/100x100bb.png")
        let appleDeadline = try await rateLimit { _ = try await rateArtwork.load(for: rateTrack) }
        let repeatedAppleDeadline = try await rateLimit { _ = try await rateArtwork.load(for: rateTrack) }
        expect(appleDeadline == repeatedAppleDeadline && ArtworkFixture.requestCount("/search") == appleBeforeLimit + 1
               && ArtworkFixture.requestCount("/rate/100x100bb.png") == fallbackBeforeLimit,
               "an Apple image-host 503 with Retry-After stops both fallback and repeated catalog requests")
        let independentCover = try await rateArtwork.loadSpotify("https://i.scdn.co/independent")
        expect(independentCover != nil, "Apple's cooldown does not block Spotify artwork")
        let spotifyBeforeLimit = ArtworkFixture.requestCount("/spotify-limited")
        let spotifyDeadline = try await rateLimit { _ = try await rateArtwork.loadSpotify("https://i.scdn.co/spotify-limited") }
        let repeatedSpotifyDeadline = try await rateLimit { _ = try await rateArtwork.loadSpotify("https://i.scdn.co/spotify-limited") }
        expect(spotifyDeadline == repeatedSpotifyDeadline && ArtworkFixture.requestCount("/spotify-limited") == spotifyBeforeLimit + 1,
               "Spotify respects its own deadline across artwork requests")
        applySpotify("spotify-limited", id: "spotify:track:rate")
        await until { covers.artworkStatus.contains("limitó temporalmente") }
        applySpotify("spotify-limited", id: "spotify:track:rate")
        expect(covers.artworkStatus.contains("limitó temporalmente"), "the model keeps the rate-limit state on the next playback sample")
        print("PASS: \(count) real-model native-widget and surface checks; no extra window or player launched.")
    }

    @MainActor private static func rateLimit(_ operation: () async throws -> Void) async throws -> TimeInterval {
        do { try await operation() }
        catch RemoteError.rateLimited(let deadline) { return deadline }
        preconditionFailure("expected a rate-limit deadline")
    }

    @MainActor private static func until(_ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(8)
        while !(await condition()) {
            precondition(ContinuousClock.now < deadline, "timed out waiting for the media state")
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ArtworkFixture: URLProtocol, @unchecked Sendable {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNQ6LkDAAJYAYnV4HfcAAAAAElFTkSuQmCC")!
    private static let pending = OSAllocatedUnfairLock(initialState: false)
    private static let held = OSAllocatedUnfairLock(initialState: [String: ArtworkFixture]())
    private static let released = OSAllocatedUnfairLock(initialState: Set<String>())
    private static let requests = OSAllocatedUnfairLock(initialState: [String: Int]())
    static var usedPendingRequest: Bool { pending.withLock { $0 } }
    static func isHolding(_ path: String) -> Bool { held.withLock { $0[path] != nil } }
    static func requestCount(_ path: String) -> Int { requests.withLock { $0[path, default: 0] } }
    static func holdNext(_ path: String) { _ = released.withLock { $0.remove(path) } }
    static func release(_ path: String) {
        _ = released.withLock { $0.insert(path) }
        held.withLock { $0.removeValue(forKey: path) }?.reply()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.withLock { $0[url.path, default: 0] += 1 }
        if url.path == "/pending" {
            Self.pending.withLock { $0 = true }
            return
        }
        if ["/api/get", "/600x600bb.png"].contains(url.path), !Self.released.withLock({ $0.contains(url.path) }) {
            Self.held.withLock { $0[url.path] = self }
            return
        }
        reply()
    }
    private func reply() {
        let url = request.url!
        let parameters = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let rateTrack = parameters.contains { $0.value?.hasPrefix("Rate QA") == true }
        let status: Int
        if url.path == "/spotify-limited" || (url.path == "/api/get" && rateTrack) { status = 429 }
        else if url.path == "/rate/600x600bb.png" { status = 503 }
        else { status = 200 }
        let headers = status == 200 ? nil : ["Retry-After": "120", "Content-Length": "9000000"]
        let data: Data
        switch url.path {
        case "/api/get":
            let isInstrumental = parameters.contains(URLQueryItem(name: "track_name", value: "Instrumental QA"))
            let json = isInstrumental
                ? #"{"trackName":"Instrumental QA","artistName":"QA Artist","albumName":"QA Album","duration":120,"instrumental":true}"#
                : #"{"trackName":"Cache QA","artistName":"QA Artist","albumName":"QA Album","duration":120,"syncedLyrics":"[00:00.00]Test lyrics"}"#
            data = Data(json.utf8)
        case "/search":
            let suffix = rateTrack ? "rate/100x100bb.png" : "100x100bb.png"
            let title = rateTrack ? "Rate QA" : "Cache QA"
            data = Data(#"{"results":[{"trackName":"\#(title)","artistName":"QA Artist","collectionName":"QA Album","trackTimeMillis":120000,"artworkUrl100":"https://is1-ssl.mzstatic.com/\#(suffix)"}]}"#.utf8)
        default:
            data = Self.png
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if status == 200 { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
