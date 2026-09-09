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
        try store.write(value)
        check(store.read(at: now) == value, "Unicode and artwork roundtrip")
        check(store.read(at: now.addingTimeInterval(3601)) == nil, "Stale cache not exposed")
        try Data("invalid json".utf8).write(to: store.file!)
        check(store.read() == nil, "Corrupt state cannot crash extension")
        try Data(repeating: 0, count: WidgetSnapshot.maximumFileBytes + 1).write(to: store.file!)
        check(store.read() == nil, "Oversized file rejected before decode")
        store.clear(); check(store.read() == nil, "Disconnect removes presentation")
        check(WidgetSnapshotStore(directory: nil).read() == nil, "Unavailable group degrades safely")
        check(OruviWidgetIdentity.standbyURL.scheme == "oruvi" && OruviWidgetIdentity.standbyURL.host == "standby", "Standby deep link")
        print("PASS: \(count) native widget snapshot, privacy, bounds and publication checks.")
    }
}
