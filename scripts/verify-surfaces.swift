import AppKit

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
        model.automaticLyrics = false; model.automaticArtwork = false
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
        model.desktopWidgetEnabled = true
        expect(model.needsPlayback, "desktop widget keeps the single sampler eligible with notch hidden")
        expect(defaults.bool(forKey: "desktopWidgetEnabled"), "desktop opt-in persists")
        model.screenSleeping = true
        expect(!model.needsPlayback, "sleep suspends desktop playback")
        model.screenSleeping = false
        model.desktopWidgetEnabled = false
        expect(!model.needsPlayback, "no surface needs playback after desktop opt-out")
        model.apply(["status": "ok", "source": "oruvi.system", "id": "system:qa", "title": "QA video", "artist": "", "album": "", "duration": 0, "position": 12, "playing": true, "systemBundleID": "com.example.Player"])
        expect(model.activePlayer == .system && model.hasTrack, "system video enters real model")
        expect(!model.playbackOptionsAvailable, "system cannot invent shuffle/repeat support")
        model.fetchLyrics()
        expect(model.lyricsAvailability == .unavailable, "video metadata never requests music lyrics")
        expect(model.playerPreference == .spotify && model.notchPlayerPreference == .automatic, "system playback preserves independent selectors")
        print("PASS: \(count) real-model surface handoff checks, no GUI or player launched.")
    }
}
