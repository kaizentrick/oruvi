import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@main
struct VerifyNotch {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard value() else { fatalError("Notch regression: \(message)") }
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0001 }
        for density: CGFloat in [1, 2, 1.5] {
            for origin: CGFloat in [0, -1728, 1512] {
                for safeTop: CGFloat in [32, 37, 32.25] {
                    let screen = CGRect(x: origin, y: 90, width: 1512, height: 982)
                    let left = CGRect(x: origin, y: 1040, width: 656, height: 32)
                    let right = CGRect(x: origin + 856, y: 1040, width: 656, height: 32)
                    let geometry = NotchGeometry.resolve(frame: screen, safeTop: safeTop, left: left, right: right, scale: density)
                    let compact = geometry.frame(expanded: false)
                    let expanded = geometry.frame(expanded: true)
                    expect(geometry.cameraWidth == 200, "physical camera gap")
                    expect(near(compact.maxY, screen.maxY), "compact top remains pinned")
                    expect(compact.minY >= screen.maxY - safeTop - 0.0001, "no pixels below safe-area band")
                    expect(near(compact.height, floor(safeTop * density) / density), "no extra four points")
                    expect(near(expanded.maxY, compact.maxY), "expansion keeps top edge")
                    expect(near(compact.minX * density, (compact.minX * density).rounded()), "pixel-aligned origin")
                    expect(screen.contains(compact) && screen.contains(expanded), "multi-display bounds")
                }
            }
        }
        let external = NotchGeometry.resolve(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080), safeTop: 0, left: nil, right: nil, scale: 1)
        expect(!external.hasCutout, "external display has no fake camera")
        expect(external.compactHeight == 30, "external mini-island height")
        expect(external.frame(expanded: false).maxY == 1080, "external display attaches to the top edge")
        let missingAreas = NotchGeometry.resolve(frame: CGRect(x: 0, y: 0, width: 1440, height: 900), safeTop: 32, left: nil, right: nil, scale: 0)
        expect(!missingAreas.hasCutout && missingAreas.scale == 1, "safe fallback for missing geometry")
        for hasTrack in [false, true] {
            for playing in [false, true] {
                expect(NotchCompactPolicy.showsMusicIndicator(hasTrack: hasTrack, playing: playing) == (hasTrack && playing), "indicator only during playback with a track")
            }
        }
        expect(NotchCompactPolicy.resolve(tab: .timer, musicActive: true, timerActive: true, codexActive: true) == .timer, "keep timer in compact notch when timer tab is selected and running")
        expect(NotchCompactPolicy.resolve(tab: .music, musicActive: true, timerActive: true, codexActive: true) == .music, "keep music in compact notch when music tab is selected and playing")
        expect(NotchCompactPolicy.resolve(tab: .connections, musicActive: true, timerActive: true, codexActive: true) == .codex, "keep codex in compact notch when connections tab is selected and connected")
        expect(NotchCompactPolicy.resolve(tab: .timer, musicActive: false, timerActive: false, codexActive: true) == .codex, "fall back to active codex when selected timer tab is idle")
        expect(NotchCompactPolicy.resolve(tab: .connections, musicActive: false, timerActive: true, codexActive: false) == .timer, "fall back to running timer when codex is disconnected")
        expect(NotchCompactPolicy.resolve(tab: .files, musicActive: false, timerActive: false, codexActive: false) == .none, "show nothing in compact notch when no source is active")
        let a = URL(fileURLWithPath: "/tmp/oruvi-test/a.pdf")
        let b = URL(fileURLWithPath: "/tmp/oruvi-test/b.png")
        let remote = URL(string: "https://example.com/file.pdf")!
        let remoteFile = URL(string: "file://other-host/private/file.pdf")!
        expect(NotchFilePolicy.candidates([a, a, b], existing: []) == [a, b], "deduplicate files")
        expect(NotchFilePolicy.candidates([a, b], existing: [a]) == [b], "deduplicate against shelf")
        expect(NotchFilePolicy.candidates([remote, remoteFile], existing: []).isEmpty, "reject network URLs")
        let many = (0..<100).map { URL(fileURLWithPath: "/tmp/oruvi-test/\($0).txt") }
        expect(NotchFilePolicy.candidates(many, existing: []).count == 20, "bounded shelf")
        expect(NotchFilePolicy.candidates(many, existing: Array(many.prefix(19))).count == 1, "remaining capacity")
        expect(NotchFilePolicy.candidates(many, existing: Array(many.prefix(20))).isEmpty, "full shelf")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("oruvi-shelf-" + UUID().uuidString, isDirectory: true)
        let realFile = tempDir.appendingPathComponent("doc.txt")
        let linkFile = tempDir.appendingPathComponent("link.txt")
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? Data("ok".utf8).write(to: realFile)
        try? FileManager.default.createSymbolicLink(at: linkFile, withDestinationURL: realFile)
        expect(NotchFilePolicy.isSafeFile(realFile) && NotchFilePolicy.isSafeFile(tempDir), "accept regular files and directories")
        expect(!NotchFilePolicy.isSafeFile(linkFile), "reject symlinks in shelf")
        let now = ContinuousClock.now
        var timer = NotchTimerState()
        timer.configure(seconds: 60)
        expect(timer.seconds(at: now) == 60 && !timer.running, "configured countdown")
        timer.start(at: now)
        expect(timer.running && timer.seconds(at: now) == 60, "start countdown")
        expect(timer.seconds(at: now.advanced(by: .milliseconds(10200))) == 50, "ceil partial seconds")
        timer.start(at: now.advanced(by: .seconds(20)))
        expect(timer.seconds(at: now.advanced(by: .seconds(20))) == 40, "start is idempotent while running")
        timer.pause(at: now.advanced(by: .seconds(30)))
        expect(!timer.running && timer.seconds(at: now.advanced(by: .seconds(400))) == 30, "pause preserves remaining time")
        timer.start(at: now.advanced(by: .seconds(400)))
        expect(timer.seconds(at: now.advanced(by: .seconds(425))) == 5, "resume uses remaining time")
        expect(timer.seconds(at: now.advanced(by: .seconds(500))) == 0, "sleep/late wake never negative")
        timer.finish()
        expect(timer.completed && !timer.running && timer.seconds() == 0, "completion state")
        timer.start(at: now)
        expect(!timer.completed && timer.seconds(at: now) == 60, "repeat completed timer")
        timer.reset()
        expect(!timer.running && timer.seconds(at: now) == 60, "reset cancels countdown")
        timer.configure(seconds: 0)
        expect(timer.totalSeconds == 1, "lower duration bound")
        timer.configure(seconds: Int.max)
        expect(timer.totalSeconds == 10800, "upper duration bound")
        timer.configure(seconds: 300)
        timer.adjust(secondsDelta: 60)
        expect(timer.totalSeconds == 360 && timer.seconds(at: now) == 360, "adjust adds 1 minute")
        timer.adjust(secondsDelta: -600)
        expect(timer.totalSeconds == 60, "adjust clamps to 1 minute minimum")
        let meetURL = NotchMeetingDetector.extractURL(url: nil, location: "Sala B · https://meet.google.com/abc-defg-hij", notes: nil)
        expect(meetURL?.absoluteString == "https://meet.google.com/abc-defg-hij", "extract Google Meet URL from location")
        let zoomURL = NotchMeetingDetector.extractURL(url: nil, location: nil, notes: "Join Zoom: https://us02web.zoom.us/j/123456789).")
        expect(zoomURL?.absoluteString == "https://us02web.zoom.us/j/123456789", "extract Zoom URL and strip trailing punctuation")
        let teamsURL = NotchMeetingDetector.extractURL(url: URL(string: "https://teams.microsoft.com/l/meetup-join/19"), location: nil, notes: nil)
        expect(teamsURL?.host == "teams.microsoft.com", "accept direct Teams event URL")
        let untrusted = NotchMeetingDetector.extractURL(url: URL(string: "https://evil.example.com/meet"), location: "http://meet.google.com/insecure", notes: "https://user:pass@meet.google.com/abc")
        expect(untrusted == nil, "reject untrusted host, non-https, or credentials in meeting URL")
        print("Notch verification passed: \(checks) checks (geometry, indicator, file policy, countdown, meeting detector).")
    }
}
