import Foundation
import AppKit

@main
struct ReleaseVerification {
    @MainActor static func main() {
        var count = 0
        func check(_ value: Bool, _ name: String) {
            count += 1
            guard value else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        }
        let cues = LRCParser.parse("[00:00.00]One\n[00:01.50]Two\n[00:03.00]\n[00:04.00]Three")
        check(cues.count == 4, "timed cue parsing")
        check(LRCParser.index(at: 1.5, in: cues) == 1, "cue boundary")
        check(LRCParser.index(at: -1, in: cues) == nil, "before first cue")
        check(LRCParser.index(at: .nan, in: cues) == nil, "nonfinite time")
        check(cues[2].text.isEmpty, "instrumental gap")
        let anchor = PlaybackAnchor(position: 10, uptime: 20, duration: 60, playing: true)
        check(anchor.value(at: 25) == 15, "monotonic playback")
        check(anchor.value(at: 100) == 60, "duration clamp")
        var recovery = PlaybackRecovery()
        recovery.succeed(at: 10); recovery.fail()
        check(recovery.waiting && recovery.retryInterval <= 1, "quick failure recovery")
        recovery.succeed(at: 20)
        check(!recovery.waiting, "valid sample restores state")
        for width in stride(from: 480.0, through: 2560.0, by: 160) {
            for height in stride(from: 320.0, through: 1200.0, by: 80) {
                let size = CGSize(width: width, height: height)
                let off = MusicLayoutMetrics(size: size, lyrics: false), on = MusicLayoutMetrics(size: size, lyrics: true)
                check(off.cover == on.cover && off.playerWidth == on.playerWidth && off.spacing == on.spacing, "toggle must not resize text or artwork")
                check(on.cover >= 0 && on.cover.isFinite, "finite geometry")
                if on.supportsSidebar { check(on.playerWidth + on.gap + on.lyricsWidth <= width + 1, "sidebar fits viewport") }
            }
        }
        for text in ["account/oruvi", "brand-team/Oruvi.app", "org/my_repo"] {
            check(UpdateConfiguration.feed(for: text)?.scheme == "https", "secure release feed")
        }
        for text in ["a/..", "a/.", "https://evil.test/a", "a/b/c", "a/b?x", "a/b#x", "a/b\nfoo", "/a", "a/"] {
            check(UpdateConfiguration.feed(for: text) == nil, "invalid release target")
        }
        check(AmbientTypeface.rounded.name == "SF Pro Rounded", "native rounded typeface")
        check(AmbientTypeface.allCases.filter(\.isAppleSystem).count == 6, "six system typography options")
        check(ClockWeight.allCases.count == 9, "nine system weights")
        for font in AmbientTypeface.allCases.filter(\.installed) {
            check(font.native(size: 30).pointSize == 30, "native font resolves without downloading")
        }
        print("PASS: \(count) release checks. Geometry, lyrics, recovery, typography and update target validation.")
    }
}
