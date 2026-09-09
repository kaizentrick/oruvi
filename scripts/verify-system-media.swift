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
        check(sample.dictionary(at: 1000)["position"] as? Double == 120, "Finite duration clamp")
        check(sample.id == SystemMediaSnapshot(payload: base, uptime: 999, epoch: 1002)!.id, "Identity independent of time")
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
        print("System media: \(assertions) assertions passed.")
    }
}
