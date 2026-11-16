import Foundation

@main struct VerifySystemMedia {
    static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            guard condition() else { fatalError(message) }
        }
        let base: [String: Any] = ["bundleIdentifier": "com.apple.Safari", "title": "Vídeo 🎵", "artist": "Canal", "playing": true,
                                  "durationMicros": 120_000_000, "elapsedTimeMicros": 10_000_000, "timestampEpochMicros": 1_000_000_000]
        let sample = SystemMediaSnapshot(payload: base, uptime: 20, epoch: 1002)!
        check(sample.bundleID == "com.apple.Safari", "Browser identity")
        check(sample.title == "Vídeo 🎵", "Unicode")
        check(sample.elapsed == 12, "Timestamp compensation")
        check(sample.dictionary(at: 23)["position"] as? Double == 15, "Uptime extrapolation")
        check(sample.dictionary(at: 23)["sampleUptime"] as? Double == 23, "Consumers must not extrapolate the same interval twice")
        var faster = base; faster["playbackRate"] = 1.5
        let fast = SystemMediaSnapshot(payload: faster, uptime: 20, epoch: 1002)!.dictionary(at: 22)
        check(fast["position"] as? Double == 16 && fast["playbackRate"] as? Double == 1.5, "System rate reaches the lyric clock")
        check(sample.dictionary(at: 1000)["position"] as? Double == 120, "Finite duration clamp")
        check(sample.id == SystemMediaSnapshot(payload: base, uptime: 999, epoch: 1002)!.id, "Identity independent of time")
        func tick(position: Double, uptime: Double, overrides: [String: Any] = [:]) -> SystemMediaSnapshot {
            var payload = base
            payload["timestampEpochMicros"] = nil
            payload["elapsedTimeMicros"] = position * 1_000_000
            payload.merge(overrides) { _, replacement in replacement }
            return SystemMediaSnapshot(payload: payload, uptime: uptime, epoch: 1002)!
        }
        var updates = SystemMediaUpdates()
        check(updates.update(tick(position: 10, uptime: 100)), "Initial Now Playing session is announced")
        let ordinaryTicks = (1...100).filter { frame in
            let elapsed = Double(frame) / 10
            return updates.update(tick(position: 10 + elapsed, uptime: 100 + elapsed))
        }
        check(ordinaryTicks.isEmpty && updates.latest?.sampledAt == 110, "Routine samples stay fresh without waking the player")
        check(!updates.update(tick(position: 20.12, uptime: 110)), "A small correction does not trigger an extra read")
        check(updates.update(tick(position: 20.28, uptime: 110)), "Accumulated drift is detected against the announced position")
        check(updates.update(tick(position: 8, uptime: 111)), "A backward seek is announced immediately")
        check(updates.update(tick(position: 8, uptime: 111, overrides: ["playing": false])), "Pausing is announced at the same position")
        check(updates.update(tick(position: 8, uptime: 111, overrides: ["playing": false, "artworkData": "YQ=="])), "A new cover is announced")
        check(updates.update(nil) && !updates.update(nil), "Disappearance is announced once")
        var changed = base; changed["title"] = "Otro vídeo"
        check(sample.id != SystemMediaSnapshot(payload: changed, uptime: 20, epoch: 1002)!.id, "Changed content invalidates identity")
        changed = base; changed["parentApplicationBundleIdentifier"] = "com.google.Chrome"
        check(SystemMediaSnapshot(payload: changed, uptime: 20, epoch: 1002)!.bundleID == "com.google.Chrome", "Browser parent wins")
        changed = base; changed["playing"] = false
        check(SystemMediaSnapshot(payload: changed, uptime: 20, epoch: 1002)!.elapsed == 10, "Paused time remains still")
        changed = base; changed["title"] = NSNull(); changed["durationMicros"] = 0
        check(SystemMediaSnapshot(payload: changed, uptime: 20, epoch: 1002) != nil, "Untitled live content remains controllable")
        changed = base; changed["durationMicros"] = Double.nan; changed["elapsedTimeMicros"] = Double.infinity
        check(SystemMediaSnapshot(payload: changed, uptime: 20, epoch: 1002)!.duration == 0, "Nonfinite input sanitized")
        changed = base; changed["artworkData"] = Data([1, 2, 3]).base64EncodedString()
        check(SystemMediaSnapshot(payload: changed, uptime: 20, epoch: 1002)!.artwork == Data([1, 2, 3]), "Embedded artwork")
        changed["artworkData"] = "not base64"
        check(SystemMediaSnapshot(payload: changed, uptime: 20, epoch: 1002)!.artwork == nil, "Corrupt artwork rejected")
        check(SystemMediaSnapshot(payload: [:], uptime: 20, epoch: 1002) == nil, "Empty session clears content")
        for invalid in ["", "../../file", "https://example.com", "app\ncommand", "no-dot"] {
            check(!SystemMediaSnapshot.validBundleID(invalid), "Invalid bundle ID rejected")
        }
        let raw = try JSONSerialization.data(withJSONObject: ["type": "data", "diff": false, "payload": base]) + Data([10])
        var parser = SystemMediaFrames(); var frames: [Data] = []
        for byte in raw { frames += try parser.append(Data([byte])) }
        check(frames.count == 1 && frames[0] == raw.dropLast(), "Byte-by-byte framing")
        check(parser.buffer.isEmpty, "No residual buffer")
        frames = try parser.append(raw + raw)
        check(frames.count == 2, "Multiple complete frames")
        do { _ = try parser.append(Data(repeating: 65, count: SystemMediaFrames.maximumBytes + 1)); fatalError("Missing size limit") }
        catch SystemMediaFrames.FrameError.oversized { check(parser.buffer.isEmpty, "Oversized frame clears buffer") }

        var retry = SystemMediaRestartPolicy()
        let rapidFailures = (0..<8).map { _ in retry.delay(afterRunningFor: 0.1) }
        check(rapidFailures == [1, 2, 4, 8, 16, 30, 30, 30], "Rapid failures use capped exponential backoff")
        check(retry.delay(afterRunningFor: 60) == 1, "A sustained run restores quick recovery")

        func child(_ script: String) -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.standardInput = FileHandle.nullDevice
            return process
        }
        let firstAttempt = DispatchSemaphore(value: 0), secondAttempt = DispatchSemaphore(value: 0)
        var launches = 0
        let bridge = SystemMediaBridge {
            launches += 1
            if launches == 1 {
                firstAttempt.signal()
                return child("exit 1")
            }
            secondAttempt.signal()
            return child(#"""
            printf '%s\n' 'malformed frame' \
            '{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.example.Player","title":"Starting","playing":true}}' \
            '{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.example.Player","title":"Recovered","playing":true}}'
            exec /bin/sleep 10
            """#)
        }
        defer { bridge.shutdown() }
        let notification = DispatchSemaphore(value: 0)
        let token = NotificationCenter.default.addObserver(forName: .oruviSystemMediaChanged, object: nil, queue: nil) { _ in
            notification.signal()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        bridge.setEnabled(true)
        check(firstAttempt.wait(timeout: .now() + 3) == .success, "The first stream helper starts")
        check(secondAttempt.wait(timeout: .now() + 0.3) == .timedOut, "A failed helper is not restarted in a tight loop")
        check(secondAttempt.wait(timeout: .now() + 5) == .success, "An unexpected helper exit restarts the stream")
        let until = ContinuousClock.now + .seconds(3)
        while bridge.current?.title != "Recovered" && ContinuousClock.now < until { Thread.sleep(forTimeInterval: 0.01) }
        check(bridge.current?.title == "Recovered", "A valid event survives a preceding malformed frame")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        check(notification.wait(timeout: .now()) == .success && notification.wait(timeout: .now()) == .timedOut,
              "A burst of meaningful events queues only one main-thread notification")
        bridge.shutdown()
        check(bridge.current == nil, "Shutdown clears the cached system session")

        let stoppedAttempts = DispatchSemaphore(value: 0)
        let stopped = SystemMediaBridge {
            stoppedAttempts.signal()
            return child("exit 1")
        }
        defer { stopped.shutdown() }
        stopped.setEnabled(true)
        check(stoppedAttempts.wait(timeout: .now() + 3) == .success, "The second stream helper starts")
        Thread.sleep(forTimeInterval: 0.2)
        stopped.setEnabled(false)
        check(stoppedAttempts.wait(timeout: .now() + 1.4) == .timedOut, "Disabling a stream cancels a pending restart")
        print("System media: \(assertions) assertions passed.")
    }
}
