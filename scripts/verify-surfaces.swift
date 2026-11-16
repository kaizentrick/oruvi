import AppKit
import Sparkle

/// Uses the real model, but never starts it, opens a window, prompts for access,
/// launches a player or enables network artwork/lyrics. Preferences are isolated.
@main
struct VerifySurfaces {
    @MainActor static func main() {
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
        model.apply(["status": "denied"])
        expect(model.notchPlayerPreference == .automatic, "denial cannot change other surface selection")
        expect(!model.connected, "denial suspends current connection")
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
        model.systemProhibitsSkip = true
        expect(!widgets.makeSnapshot().canSkip, "native widget disables prohibited skips")
        model.screenSleeping = true
        let asleep = widgets.makeSnapshot()
        expect(asleep.state == .sleeping && !asleep.canControl && asleep.artwork == nil, "sleep snapshot removes private media")
        model.screenSleeping = false; model.connected = false
        expect(widgets.makeSnapshot().state == .disconnected, "disconnect cannot show playable media")
        model.connected = true; model.track = .empty
        expect(widgets.makeSnapshot().state == .idle, "empty session is not fabricated playback")
        expect(model.playerPreference == .spotify && model.notchPlayerPreference == .automatic, "widget never rewrites independent selectors")
        expect(!model.nativeWidgetInUse, "removing widget releases its sampler demand")
        print("PASS: \(count) real-model native-widget and surface checks; no extra window or player launched.")
    }
}
