import Foundation

@main struct VerifyWidgetKit {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1; precondition(value(), message)
        }
        let now = Date()
        var snapshot = WidgetSnapshot(); snapshot.generatedAt = now
        check(snapshot.isValid(at: now), "Empty snapshot is valid")
        check(!snapshot.canControl, "Empty widget cannot control playback")
        snapshot.state = .ready; snapshot.trackID = "test"; snapshot.session = "test-session"
        snapshot.sourceID = "com.apple.Music"; snapshot.playing = true
        check(snapshot.canControl, "Connected content enables playback")
        snapshot.sourceName = "Automático · Apple Music"
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        check(legacy.artworkPalette == nil && legacy.displaySourceName == "Apple Music", "Old snapshots need no palette and still show only the provider")
        snapshot.sourceName = "Apple Music"
        for state in [WidgetPlaybackState.closed, .disconnected, .sleeping, .idle] {
            var value = snapshot; value.state = state
            check(!value.canControl, "Non-ready state disables controls")
        }
        check(!snapshot.isValid(at: now.addingTimeInterval(3601)), "Crash cache expires")
        check(!snapshot.isValid(at: now.addingTimeInterval(-61)), "Future cache is invalid")
        for invalid in ["", "browser", "javascript:alert(1)"] {
            var value = snapshot; value.preference = invalid
            check(!value.isValid(at: now), "Only three actual preferences")
        }
        var value = snapshot; value.title = String(repeating: "a", count: 4097)
        check(!value.isValid(at: now), "Bound metadata length")
        value = snapshot; value.artwork = Data(repeating: 1, count: WidgetSnapshot.maximumArtworkBytes + 1)
        check(!value.isValid(at: now), "Bound artwork memory")
        value = snapshot; value.artworkPalette = [0, 0xFFFFFF]
        check(!value.isValid(at: now), "Require four palette colors")
        value.artworkPalette = [0, 0, 0, 0x1000000]
        check(!value.isValid(at: now), "Reject colors outside 24-bit RGB")
        value = snapshot; value.schema = 2
        check(!value.isValid(at: now), "Reject unknown schema")
        value = snapshot; value.generatedAt = now.addingTimeInterval(10)
        check(snapshot.samePresentation(as: value), "Time alone is not a UI update")
        value.playing = false
        check(!snapshot.samePresentation(as: value), "Pause changes UI")
        var policy = WidgetPublicationPolicy()
        check(policy.needsWrite(snapshot), "First presentation writes")
        policy.record(snapshot, reload: true)
        check(!policy.needsWrite(snapshot), "Repeated poll does not write")
        check(policy.needsWrite(snapshot, force: true), "Explicit request can write")
        check(policy.reloadDelay(at: now) == 5, "Coalesce reload burst")
        check(policy.reloadDelay(at: now.addingTimeInterval(6)) == 0, "Next update eventually proceeds")
        value = snapshot; value.generatedAt = now.addingTimeInterval(601)
        check(policy.needsWrite(value), "Bounded cache renewal uses existing sampler")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("oruvi-widget-test-" + UUID().uuidString)
        let store = WidgetSnapshotStore(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        try store.write(snapshot)
        check(store.read(at: now) == snapshot, "Atomic metadata and cover roundtrip")
        value = snapshot; value.artwork = Data([1,2,3]); value.title = "🎵 Música · 中文"
        value.artworkPalette = [0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFF]
        try store.write(value)
        check(store.read(at: now) == value, "Unicode, artwork and palette roundtrip")
        check(store.read(at: now.addingTimeInterval(3601)) == nil, "Stale cache not exposed")
        try Data("invalid json".utf8).write(to: store.file!)
        check(store.read() == nil, "Corrupt state cannot crash extension")
        try Data(repeating: 0, count: WidgetSnapshot.maximumFileBytes + 1).write(to: store.file!)
        check(store.read() == nil, "Oversized file rejected before decode")
        store.clear(); check(store.read() == nil, "Disconnect removes presentation")
        check(WidgetSnapshotStore(directory: nil).read() == nil, "Unavailable group degrades safely")
        check(OruviWidgetRoute(url: OruviWidgetIdentity.standbyURL) == .standby, "Corner button opens Standby")
        check(OruviWidgetRoute(url: OruviWidgetIdentity.playerURL) == .player, "Widget body opens the player")
        check(OruviWidgetRoute(url: OruviWidgetIdentity.musicURL) == .music, "Widget can open Apple Music directly")
        check(OruviWidgetRoute(url: OruviWidgetIdentity.spotifyURL) == .spotify, "Widget can open Spotify directly")
        check(OruviWidgetRoute(url: OruviWidgetIdentity.settingsURL) == .widgets, "Archived widget links still open settings")
        check(OruviWidgetRoute(url: URL(string: "oruvi://player?command=next")!) == nil, "Widget routes only accept navigation")
        print("PASS: \(count) native widget snapshot, privacy, bounds and publication checks.")
    }
}
