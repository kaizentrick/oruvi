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
        model.musicShowsLyrics = true
        model.lines = [LyricLine(id: 0, time: 0, text: "Current"), LyricLine(id: 1, time: 42, text: "Next")]
        var cueSample: [String: Any] = ["status": "ok", "source": "com.spotify.client", "id": "spotify:qa",
                                        "title": "QA song", "duration": 120, "position": 12, "playing": true,
                                        "sampleUptime": ProcessInfo.processInfo.systemUptime]
        model.apply(cueSample)
        guard let firstCue = model.scheduledLyricCue else { preconditionFailure("visible playback should schedule a cue") }
        let firstDeadline = firstCue.fireDate
        for _ in 0..<20 { model.apply(cueSample) }
        expect(model.scheduledLyricCue === firstCue && firstCue.isValid, "consistent samples keep the real cue timer armed")
        cueSample["playbackRate"] = 2
        model.apply(cueSample)
        expect(model.scheduledLyricCue !== firstCue && !firstCue.isValid
               && (model.scheduledLyricCue?.fireDate ?? .distantFuture) < firstDeadline,
               "a new playback speed moves the real cue deadline")
        cueSample["playing"] = false
        model.apply(cueSample)
        expect(model.scheduledLyricCue == nil && model.currentLyricText == "Current", "pausing cancels the timer and keeps the current lyric")
        model.lines = [LyricLine(id: 0, time: 0, text: "Current"), LyricLine(id: 1, time: 12.15, text: "Next")]
        cueSample["playing"] = true
        cueSample["sampleUptime"] = ProcessInfo.processInfo.systemUptime
        model.apply(cueSample)
        await until { model.currentLyricText == "Next" }
        expect(model.scheduledLyricCue == nil, "the one-shot timer advances the lyric and clears its own deadline")
        model.lines = [LyricLine(id: 0, time: 0, text: "Current"), LyricLine(id: 1, time: 121, text: "Unreachable")]
        cueSample["position"] = 120
        model.apply(cueSample)
        expect(model.scheduledLyricCue == nil, "a line past the known end of the track never schedules a wake")
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
        model.setSleeping(true, source: .display)
        model.setSleeping(true, source: .system)
        expect(!model.needsPlayback, "sleep suspends desktop playback")
        model.setSleeping(false, source: .system)
        expect(model.screenSleeping && !model.needsPlayback, "a Mac wake does not resume playback while its display sleeps")
        model.setSleeping(false, source: .display)
        expect(model.needsPlayback, "desktop sampling resumes after both sources wake")
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
        var followup: [String: Any] = ["status": "ok", "source": "oruvi.system", "id": "system:qa", "title": "QA video",
                                       "artist": "", "album": "", "duration": 0.25, "position": 0.1, "playing": true,
                                       "systemBundleID": "com.example.Player"]
        model.apply(followup)
        expect(model.canSkip && model.canSeek && model.track.duration == 0 && model.anchor.duration == 0.25,
               "a newly known duration enables seeking without altering the track identity")
        followup["duration"] = 120
        model.apply(followup)
        let originalTrack = model.track
        model.lines = [LyricLine(id: 0, time: 0, text: "Stable lyric")]
        followup["duration"] = 120.4
        followup["position"] = 120.2
        model.apply(followup)
        expect(model.track == originalTrack && model.anchor.duration == 120.4
               && model.anchor.position == 120.2 && model.hasLyrics,
               "timing corrections reach the progress controls and preserve the loaded track resources")
        model.systemProhibitsSkip = true
        expect(!model.canSkip && !model.canSeek && !widgets.makeSnapshot().canSkip,
               "notch, Standby and native widget share system restrictions")
        model.setSleeping(true, source: .system)
        let asleep = widgets.makeSnapshot()
        expect(asleep.state == .sleeping && !asleep.canControl && asleep.artwork == nil, "sleep snapshot removes private media")
        model.setSleeping(false, source: .display)
        expect(widgets.makeSnapshot().state == .sleeping, "a display wake cannot resume a still-sleeping Mac")
        model.setSleeping(false, source: .system)
        model.connected = false
        expect(widgets.makeSnapshot().state == .disconnected, "disconnect cannot show playable media")
        model.connected = true; model.track = .empty
        expect(widgets.makeSnapshot().state == .idle, "empty session is not fabricated playback")
        expect(!model.handlePlaybackShortcut(isRepeat: false), "without a track, Space stays available to other controls")
        expect(model.playerPreference == .spotify && model.notchPlayerPreference == .automatic, "widget never rewrites independent selectors")
        expect(!model.nativeWidgetInUse, "removing widget releases its sampler demand")
        model.useDemo()
        expect(model.canSkip && model.canSeek, "demo clears restrictions inherited from the last video")
        func space(repeatKey: Bool) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                             context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: repeatKey,
                             keyCode: 49)!
        }
        expect(model.handlePlaybackShortcut(isRepeat: space(repeatKey: false).isARepeat) && !model.anchor.playing,
               "an initial Space event pauses playback")
        let repeatedSpace = space(repeatKey: true)
        let pausedAnchor = model.anchor
        let holdsWereConsumed = (0..<20).allSatisfy { _ in
            model.handlePlaybackShortcut(isRepeat: repeatedSpace.isARepeat) && model.anchor == pausedAnchor
        }
        expect(holdsWereConsumed, "repeat Space events are consumed and leave playback paused")
        expect(model.handlePlaybackShortcut(isRepeat: space(repeatKey: false).isARepeat) && model.anchor.playing,
               "another discrete press resumes playback")
        model.anchor.duration = 210
        model.control("seek", position: 220)
        expect(model.anchor.position == 210 && model.track.duration == 214,
               "seek clamps to the current transport duration even when track metadata differs")
        let displayedRecording = model.track
        let displayedLyric = model.lines[1]
        model.lyricOffset = 1.5
        expect(model.lyricSeekPosition(at: 0) == 0, "a lyric before playback begins seeks to zero")
        model.seekToLyric(displayedLyric, at: 1, on: displayedRecording)
        expect(model.anchor.position == displayedLyric.time - 1.5, "a current lyric jump uses the latest synchronization offset")
        let afterLyricSeek = model.anchor
        model.lines.removeAll()
        model.seekToLyric(displayedLyric, at: 1, on: displayedRecording)
        expect(model.anchor == afterLyricSeek, "an already-rendered lyric action is safe after the lyrics are removed")
        model.lines = [displayedLyric, LyricLine(id: 1, time: 215, text: "Replacement")]
        model.seekToLyric(displayedLyric, at: 1, on: displayedRecording)
        expect(model.lyricSeekPosition(at: 1) == nil && model.anchor == afterLyricSeek,
               "a replaced cue outside the current duration cannot jump to the end")
        model.track.id = "different-demo-recording"
        model.seekToLyric(displayedLyric, at: 0, on: displayedRecording)
        expect(model.anchor == afterLyricSeek, "lyrics from an old recording cannot seek the next recording")
        model.lyricOffset = 0
        model.systemProhibitsSkip = true
        let protected = model.anchor
        model.control("next")
        model.control("seek", position: 100)
        expect(model.anchor == protected, "model rejects restricted controls even if a gesture already started")
        var completionSounds = 0
        let countdown = NotchCountdown { completionSounds += 1 }
        countdown.sound = true
        countdown.configure(minutes: 1)
        countdown.toggle()
        guard let countdownDeadline = countdown.state.deadline else { preconditionFailure("the countdown must be running") }
        expect(!countdown.finishIfDue(at: countdownDeadline - .milliseconds(1)) && countdown.state.running,
               "reconciling the timer before its deadline keeps it running")
        expect(countdown.finishIfDue(at: countdownDeadline + .seconds(10)) && countdown.state.completed && completionSounds == 1,
               "an overdue timer completes and plays the selected sound as soon as it is reconciled")
        expect(!countdown.finishIfDue(at: countdownDeadline + .seconds(11)) && completionSounds == 1,
               "a second reconciliation cannot replay the completion sound")
        countdown.toggle()
        expect(countdown.state.running && !countdown.state.completed, "a completed timer can start a new interval")
        countdown.stop()
        countdown.sound = false
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
        let legacyLyrics = LyricsPayload(lines: [LyricLine(id: 0, time: 0, text: "Old parse")],
                                         source: "Legacy", savedAt: Date(), parserVersion: nil)
        try JSONEncoder().encode(legacyLyrics).write(to: lyricFile)
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
        try JSONEncoder().encode(legacyLyrics).write(to: importedFile)
        let importedResult = await lyricRepository.load(for: track, allowNetwork: false)
        guard case .available(let importedLyrics) = importedResult else { preconditionFailure("legacy imported lyrics must remain readable") }
        expect(importedLyrics.lines == legacyLyrics.lines && lyrics.lines != legacyLyrics.lines,
               "refresh downloaded lyrics from the old parser while retaining imported lyrics")
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
        let closedMusic = SystemMediaSnapshot(payload: ["bundleIdentifier": PlayerSource.music.rawValue,
                                                        "title": "Previous song", "playing": true], uptime: 100, epoch: 100)!
        var running: Set<PlayerSource> = [.spotify]
        var lastMusicStatus = "stopped"
        var inspected: [PlayerSource] = []
        let router = PlayerRouter(isRunning: { running.contains($0) }, readNative: { source in
            inspected.append(source)
            if source == .music { return ["status": lastMusicStatus] }
            return ["status": "ok", "id": "spotify:track:continuing", "playing": true]
        })
        func automaticSnapshot() -> [String: Any] {
            router.resolve(preference: .automatic, preferred: .music, system: closedMusic)
        }
        expect(automaticSnapshot()["source"] as? String == PlayerSource.spotify.rawValue && inspected == [.spotify],
               "a closed Music process cannot mask the active Spotify session or receive Apple Events")
        running = [.music, .spotify]
        inspected.removeAll()
        expect(automaticSnapshot()["source"] as? String == PlayerSource.spotify.rawValue
               && inspected.filter { $0 == .music }.count == 1,
               "a stopped native session falls back without another query to that same player")
        lastMusicStatus = "error"
        expect(automaticSnapshot()["source"] as? String == PlayerSource.system.rawValue,
               "a temporary native failure still permits a valid Now Playing session")
        lastMusicStatus = "denied"
        expect(automaticSnapshot()["source"] as? String == PlayerSource.system.rawValue,
               "Now Playing remains available when a running app denies Apple Events")
        running = []
        expect(automaticSnapshot()["status"] as? String == "notRunning",
               "the last native session disappears when the app quits, even after permission was denied")
        let closed = router.snapshot(preference: .spotify, preferred: .spotify)
        running = [.spotify]
        var olderTrack = router.snapshot(preference: .spotify, preferred: .spotify)
        olderTrack["id"] = "spotify:track:previous"
        var latestTrack = router.snapshot(preference: .spotify, preferred: .spotify)
        expect((closed["playbackSequence"] as? UInt64) == 1 && (latestTrack["playbackSequence"] as? UInt64) == 3,
               "the playback queue orders both terminal and successful snapshots")
        expect(closed["playbackReadDuration"] == nil && latestTrack["playbackReadDuration"] != nil,
               "the router measures successful reads and does not attach a time to a closed player")
        latestTrack["playbackReadDuration"] = 0.027
        covers.apply(latestTrack)
        covers.apply(olderTrack)
        covers.apply(closed)
        var oldDenial = closed
        oldDenial["status"] = "denied"
        covers.apply(oldDenial)
        expect(covers.connected && covers.track.id == "spotify:track:continuing",
               "late replies cannot restore a previous track, clear the newest state, or disconnect playback")
        expect(covers.playbackReadMilliseconds == 27, "a late reply cannot overwrite the new playback timing")
        running = []
        covers.apply(router.snapshot(preference: .spotify, preferred: .spotify))
        covers.apply(latestTrack)
        expect(!covers.hasTrack, "a fresh no-player reply clears playback and rejects a late successful sample")
        expect(covers.playbackReadMilliseconds == nil, "a stopped source cannot leave a stale reading in Settings")
        let timingRouter = PlayerRouter(isRunning: { _ in true }, readNative: { _ in
            Thread.sleep(forTimeInterval: 0.025)
            return ["status": "ok", "id": "timed"]
        })
        let timed = timingRouter.snapshot(preference: .music, preferred: .music)
        expect((timed["playbackReadDuration"] as? Double ?? 0) >= 0.02,
               "timing includes the native metadata read, not just a position round trip")
        var cached: [String: Any] = ["status": "ok", "source": PlayerSource.system.rawValue, "id": "system:cached"]
        cached["playbackReadDuration"] = Double.infinity
        covers.apply(cached)
        expect(covers.playbackReadMilliseconds == nil, "invalid diagnostic durations are hidden")
        var commandSession = 1
        var commandReads = 0
        var deliveredCommands = 0
        let commandRouter = PlayerRouter(isRunning: { _ in true }, readNative: { _ in
            commandReads += 1
            commandSession += 1
            return ["status": "ok", "id": "track"]
        }, dispatchNative: { _, _, _, _ in
            deliveredCommands += 1
            return ["status": "ok"]
        })
        let staleToggle = commandRouter.command("toggle", position: 0, source: .music,
                                                preference: .music, expectedTrackID: "track") { commandSession == 0 }
        expect(staleToggle["status"] as? String == "transition" && commandReads == 0 && deliveredCommands == 0,
               "a queued control is skipped before any player interaction when its session has changed")
        let staleSeek = commandRouter.command("seek", position: 30, source: .music,
                                              preference: .music, expectedTrackID: "track") { commandSession == 1 }
        expect(staleSeek["status"] as? String == "transition" && commandReads == 1 && deliveredCommands == 0,
               "a control invalidated during its native track lookup is not delivered")
        let currentToggle = commandRouter.command("toggle", position: 0, source: .music,
                                                  preference: .music, expectedTrackID: "track") { commandSession == 2 }
        expect(currentToggle["status"] as? String == "ok" && commandReads == 1 && deliveredCommands == 1,
               "a current native control keeps the direct dispatch path")
        let lockFile = support.appendingPathComponent("verification.instance")
        do {
            let owner = try ApplicationInstanceLock.acquire(at: lockFile)
            let duplicate = try ApplicationInstanceLock.acquire(at: lockFile)
            expect(owner != nil && duplicate == nil, "a duplicate launch cannot acquire the active runtime lock")
            withExtendedLifetime(owner) {}
        }
        let reopened = try ApplicationInstanceLock.acquire(at: lockFile)
        expect(reopened != nil, "a new launch can start after the previous owner exits")
        withExtendedLifetime(reopened) {}

        let cursor = CursorConnection()
        cursor.setEnabled(true)
        let oldPollID = cursor.refreshID
        var completeOldRequest: CheckedContinuation<CursorUsageSnapshot, Never>?
        let oldPoll = Task {
            await cursor.poll(id: oldPollID) {
                await withCheckedContinuation { completeOldRequest = $0 }
            }
        }
        await until { completeOldRequest != nil }
        cursor.refresh()
        let replacementID = cursor.refreshID
        let oldReading = CursorUsageSnapshot(remainingPercent: 30, resetLabel: "Nov 21", fetchedAt: Date())
        completeOldRequest?.resume(returning: oldReading)
        await oldPoll.value
        expect(cursor.currentSnapshot == nil && !cursor.refreshing, "a superseded Cursor response cannot reappear before a new poll")
        await cursor.poll(id: oldPollID) { preconditionFailure("an obsolete poll started a browser request") }
        let newReading = CursorUsageSnapshot(remainingPercent: 70, resetLabel: "Nov 22", fetchedAt: Date())
        let newPoll = Task { await cursor.poll(id: replacementID) { newReading } }
        await until { cursor.currentSnapshot != nil }
        expect(cursor.summary.contains("70%") && cursor.summary.contains("Nov 22"),
               "the latest request reports its own quota and reset date")
        newPoll.cancel()
        await newPoll.value
        expect(cursor.currentSnapshot != nil && !cursor.refreshing,
               "closing Conexiones keeps its cached quota without continuing to poll")
        cursor.setEnabled(false)
        expect(cursor.currentSnapshot == nil && cursor.summary == "Sin conectar", "disconnecting clears the displayed Cursor quota")

        var codexAttempts = 0
        let codex = CodexUsageController(locateExecutable: { codexAttempts += 1; return nil })
        codex.connect()
        codex.start()
        defer { codex.disconnect(); codex.stop() }
        expect(codexAttempts == 1 && codex.error == .missingCLI, "Codex tries promptly when first connected")
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.post(name: NSWorkspace.willSleepNotification, object: nil)
        workspaceNotifications.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspaceNotifications.post(name: NSWorkspace.didWakeNotification, object: nil)
        expect(codex.status.contains("En pausa") && codexAttempts == 1,
               "waking the Mac does not start a Codex read while its display sleeps")
        workspaceNotifications.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        expect(codexAttempts == 1, "waking again within five seconds does not bypass the query cooldown")
        await until { codexAttempts == 2 }
        expect(codex.error == .missingCLI && !codex.refreshing,
               "after a quick wake, Codex rechecks when the cooldown ends instead of waiting for a full polling interval")
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
