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
        defaults.set(false, forKey: "desktopWidgetEnabled")
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
        // Exercise the real AppKit card on the CI runner, not just a mock state.
        // No application delegate/model.start(), permissions, playback or network.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let widget = DesktopWidgetController(model: model)
        defer { widget.stop() }
        model.isVisible = false; model.screenSleeping = false
        model.desktopWidgetEnabled = false; model.desktopWidgetAlwaysOnTop = false
        widget.reconcile()
        expect(!widget.isVisible, "hidden card creates no visible window")
        model.desktopWidgetEnabled = true; widget.reconcile()
        expect(widget.isVisible, "enabled card actually orders a panel on screen")
        expect(widget.currentFrame?.size == DesktopWidgetPolicy.size, "real panel has current dimensions")
        expect(!widget.isInFront, "desktop mode stays below normal windows")
        model.isVisible = true; widget.reconcile()
        expect(!widget.isVisible, "Standby hides the real panel")
        model.isVisible = false; widget.reconcile()
        expect(widget.isVisible, "return from Standby restores real panel")
        model.screenSleeping = true; widget.reconcile()
        expect(!widget.isVisible, "sleep hides real panel")
        model.desktopWidgetEnabled = false; model.revealDesktopWidget()
        expect(!model.desktopWidgetEnabled, "reveal cannot show UI while locked/asleep")
        model.screenSleeping = false
        let savedNotch = model.notchPlayerPreference, savedStandby = model.playerPreference
        model.revealDesktopWidget(); model.revealDesktopWidget(); widget.reveal()
        expect(model.desktopWidgetEnabled && widget.isVisible, "repeated Show never toggles the widget off")
        expect(widget.isInFront, "explicit reveal is visible above normal windows")
        expect(!model.connected, "Show does not silently connect playback")
        expect(model.notchPlayerPreference == savedNotch && model.playerPreference == savedStandby, "Show preserves independent players")
        widget.endReveal()
        expect(!widget.isInFront, "temporary reveal returns to desktop level")
        model.desktopWidgetAlwaysOnTop = true; widget.reconcile()
        expect(widget.isInFront, "explicit pin keeps card in front")
        expect(defaults.bool(forKey: DesktopWidgetPolicy.pinnedKey), "pin preference persists")
        model.desktopWidgetAlwaysOnTop = false; widget.reconcile()
        expect(!widget.isInFront, "unpin returns to desktop")
        model.desktopWidgetEnabled = false; widget.reconcile()
        expect(!widget.isVisible, "Hide really hides the panel")
        widget.stop(); widget.stop(); widget.reveal()
        expect(!widget.isVisible && widget.currentFrame == nil, "shutdown is idempotent and cannot reopen")
        print("PASS: \(count) real-model surface/widget checks; AppKit panel exercised, no player launched.")
    }
}
