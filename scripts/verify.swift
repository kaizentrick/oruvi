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
        var mediaCheck = IdleMediaCheckState.idle
        check(mediaCheck.begin() && !mediaCheck.begin(), "a Standby media probe runs once until it completes")
        var duplicateProbes = 0
        for _ in 0..<60 {
            mediaCheck.invalidate()
            if mediaCheck.begin() { duplicateProbes += 1 }
        }
        check(duplicateProbes == 0 && mediaCheck.complete() == .waitingToRetry, "foreground changes request one fresh check after the old one finishes")
        check(mediaCheck.begin() && mediaCheck.complete() == .checking, "a fresh probe can finish normally after coalescing")
        check(mediaCheck.begin(), "a new idle period permits another probe")
        mediaCheck.invalidate()
        _ = mediaCheck.begin()
        mediaCheck.invalidate()
        check(mediaCheck.complete() == .invalidated, "disabling, locking or using Standby cancels a deferred recheck")
        let pauseStart = ContinuousClock.now
        let activationPause = IdleActivationPause(duration: .seconds(3600), at: pauseStart)
        check(activationPause.remainingSeconds(at: pauseStart) == 3600, "a one-hour pause supplies its full delay to the timer")
        check(activationPause.remainingSeconds(at: pauseStart + .milliseconds(3_599_750)) == 0.25,
              "rescheduling uses the same deadline even near expiration")
        check(activationPause.remainingSeconds(at: pauseStart + .seconds(3600)) == nil
              && activationPause.remainingSeconds(at: pauseStart + .seconds(4500)) == nil,
              "an expired pause stays expired after a long sleep")
        check(MediaProtection.foregroundProtectionReason(bundleID: "at.studio.AsideBrowser", conservative: true)?.contains("Navegador") == true,
              "a foreground Aside session triggers conservative protection")
        check(MediaProtection.foregroundProtectionReason(bundleID: "at.studio.AsideBrowser", conservative: false) == nil,
              "disabling the conservative rule leaves audio and display checks responsible")
        check(MediaProtection.foregroundProtectionReason(bundleID: "com.apple.QuickTimePlayerX", conservative: true)?.contains("vídeo") == true,
              "a video player blocks Standby before system audio sampling")
        check(MediaProtection.foregroundProtectionReason(bundleID: "com.apple.Music", conservative: true) == nil
              && MediaProtection.foregroundProtectionReason(bundleID: "at.studio.AsideBrowserFake", conservative: true) == nil,
              "the foreground rule excludes music and unrelated bundle prefixes")
        check(!MediaActivitySample().shouldProtect && MediaActivitySample(displayHeld: true).shouldProtect
              && MediaActivitySample(otherAudio: true).shouldProtect
              && MediaActivitySample(assertionsAvailable: false, audioAvailable: false).shouldProtect,
              "system media checks keep protecting audio, display use and unavailable readings")
        let cues = LRCParser.parse("[00:00.00]One\n[00:01.50]Two\n[00:03.00]\n[00:04.00]Three")
        check(cues.count == 4, "timed cue parsing")
        check(LRCParser.index(at: 1.5, in: cues) == 1, "cue boundary")
        check(LRCParser.index(at: -1, in: cues) == nil, "before first cue")
        check(LRCParser.index(at: .nan, in: cues) == nil, "nonfinite time")
        check(cues[2].text.isEmpty, "instrumental gap")
        let literal = LRCParser.parse("\u{FEFF}[00:01.2] [00:02.034] <00:01.20>time [00:12.00] and [offset:5000]\r\n")
        check(literal.map(\.time) == [1.2, 2.034] && literal.allSatisfy { $0.text == "time [00:12.00] and [offset:5000]" },
              "only leading timestamps and standalone offsets are metadata")
        let negative = LRCParser.parse("[offset:-2500]\n[00:01]Old\n[00:02]Current\n[00:02.000]Second\n[00:02.0]Current\n[00:03]Next")
        check(negative.map(\.time) == [0, 0.5] && negative.first?.text == "Current\nSecond",
              "offset preserves only the active pre-start cue and merges distinct simultaneous lines")
        let zero = LRCParser.parse("[OFFSET:-2000]\n[00:01]Previous\n[00:02]\n[00:03]Next")
        check(zero.first?.text.isEmpty == true && zero.first?.time == 0, "an actual cue at zero overrides an earlier cue")
        check(LRCParser.parse("[offset:+200]\n[00:01]One").first?.time == 1.2, "positive offsets retain their timing convention")
        check(LRCParser.parse("Cover art [00:05] must not be a cue\n[00:61]Invalid").isEmpty, "timestamps in prose and invalid seconds are ignored")
        let simultaneous = (0..<4000).map { "[00:01]Line \($0)" }.joined(separator: "\n")
        let merged = LRCParser.parse(simultaneous)
        check(merged.count == 1 && merged.first?.text.components(separatedBy: "\n").count == 4000
              && merged.first?.text.hasSuffix("Line 3999") == true, "many simultaneous lines merge in file order")
        let expanded = (0..<64).map { String(format: "[00:%02d.%03d]", $0 / 2, $0 % 2) }.joined()
            + String(repeating: "x", count: 64_000)
        check(LRCParser.parse(expanded).isEmpty, "repeated stamps cannot expand a bounded input indefinitely")
        let anchor = PlaybackAnchor(position: 10, uptime: 20, duration: 60, playing: true)
        check(anchor.value(at: 25) == 15, "monotonic playback")
        check(anchor.value(at: 100) == 60, "duration clamp")
        let fast = PlaybackAnchor(position: 10, uptime: 20, duration: 60, playing: true, rate: 2)
        check(fast.value(at: 25) == 20 && fast.delay(until: 22, at: 25) == 1, "Lyric cues follow playback speed")
        check(fast.delay(until: 61, at: 25) == nil, "A cue past the end cannot repeatedly wake the timer")
        let paused = PlaybackAnchor(position: 10, uptime: 20, duration: 60, playing: false)
        check(paused.value(at: 25) == 10 && paused.delay(until: 12, at: 25) == nil, "Pause freezes the lyric clock")
        check(PlaybackTime.format(121.9) == "2:01" && PlaybackTime.format(-2) == "0:00", "Playback time rounds down and clamps negative remaining time")
        check(PlaybackTime.format(.greatestFiniteMagnitude) == "—" && PlaybackTime.format(.nan) == "—", "Unknown or out-of-range media time never traps")
        var render = RenderPolicy(visible: true, onBattery: false, lowPower: false, hot: false, reduceMotion: false, mode: .adaptive)
        check(render.framesPerSecond == 24, "standby adapts to 24 fps on AC power")
        render.onBattery = true
        check(render.framesPerSecond == 0, "adaptive standby keeps the mesh static on battery")
        render.mode = .fluid
        check(render.framesPerSecond == 12, "fluid standby budgets 12 fps on battery")
        render.onBattery = false
        check(render.framesPerSecond == 30, "fluid standby budgets 30 fps on AC power")
        let fluid = render
        render.lowPower = true
        check(render.framesPerSecond == 0, "macOS Low Power Mode stops the mesh")
        render = fluid; render.hot = true
        check(render.framesPerSecond == 0, "thermal pressure stops the mesh")
        render = fluid; render.reduceMotion = true
        check(render.framesPerSecond == 0, "Reduce Motion stops the mesh")
        render = fluid; render.mode = .saver
        check(render.framesPerSecond == 0, "Oruvi energy saver stops the mesh")
        render = fluid; render.visible = false
        check(render.framesPerSecond == 0 && render.pollingInterval(playing: true) == nil, "hidden Standby needs neither animation frames nor its fast sampling cadence")
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
