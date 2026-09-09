import Foundation

@main struct VerifyWidgetRecovery {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OruviRecovery-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let store = WidgetSnapshotStore(directory: root)
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ text: String) { count += 1; precondition(value(),text) }
        let now = Date()
        check(store.load() == .missing, "Missing file is distinguishable")
        check(WidgetSnapshotStore(directory:nil).load() == .unavailable, "Container failure is not a closed app")
        for result in [WidgetSnapshotRead.missing, .unavailable, .invalid, .expired] {
            let value = result.presentation(at:now)
            check(value.canRefresh && !value.canControl, "Every failed read has safe recovery, never fictitious transport")
            check(value.artwork == nil && value.trackID.isEmpty, "Failed reads do not leak stale artwork or identities")
        }
        check(WidgetSnapshotRead.unavailable.presentation().state == .unavailable, "Permission failures exposed")
        var value = WidgetSnapshot(); value.state = .sleeping
        check(!value.canRefresh, "No widget command during sleep")
        value = WidgetSnapshot(); value.state = .ready; value.session = "test"; value.trackID = "test"
        try store.write(value)
        check(store.load() == .value(value), "Atomic writer/reader round trip")
        check(store.load(at:now.addingTimeInterval(3700)) == .expired, "Expired current state identified")
        try Data("bad json".utf8).write(to:store.file!)
        check(store.load() == .invalid, "Corrupt data does not pretend app is closed")
        try store.write(value)
        check(store.load() == .value(value), "Recover after corrupt file")
        var policy = WidgetPublicationPolicy()
        policy.record(value,reload:false)
        let written = policy.lastWrite
        policy.recordReload(at:now.addingTimeInterval(30))
        check(policy.lastWrite == written, "Timeline reload cannot fake a successful disk write")
        check(!policy.needsWrite(value), "Identical content does not consume another write")
        check(policy.needsWrite(value,force:true), "Explicit refresh survives deduplication")
        value.generatedAt = now.addingTimeInterval(601)
        check(policy.needsWrite(value), "Long paused playback still renews expiry")
        var presence = WidgetPresencePolicy()
        check(!presence.active(at:now), "No imaginary widget on launch")
        presence.receivedRequest(at:now)
        presence.receivedCount(0)
        check(presence.active(at:now.addingTimeInterval(1)), "Late zero does not negate timeline demand")
        check(!presence.active(at:now.addingTimeInterval(1201)), "Demand expires rather than polling music forever")
        presence.receivedCount(2)
        check(presence.active(at:now.addingTimeInterval(1300)), "Two actual widget instances keep sampler eligible")
        presence.receivedCount(0)
        check(!presence.active(at:now.addingTimeInterval(1300)), "Widget removal releases demand")
        print("PASS: \(count) native widget recovery, storage-error and lifecycle checks.")
    }
}
