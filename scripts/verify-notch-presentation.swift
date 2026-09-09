// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

@main
struct VerifyNotchPresentation {
    @MainActor static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(condition(), "Notch presentation: \(message)")
        }
        for x in [-2560.0, 0, 2200] {
            for y in [-900.0, 0, 600] {
                for width in [640.0, 1024, 1512, 2560] {
                    for scale in [1.0, 2] {
                        for cutout in [false, true] {
                            let screen = CGRect(x: x, y: y, width: width, height: 982)
                            let left = CGRect(x: x, y: screen.maxY - 32, width: width / 2 - 100, height: 32)
                            let right = CGRect(x: x + width / 2 + 100, y: screen.maxY - 32, width: width / 2 - 100, height: 32)
                            let geometry = NotchGeometry.resolve(frame: screen, safeTop: cutout ? 32 : 0,
                                                                 left: cutout ? left : nil, right: cutout ? right : nil, scale: scale)
                            let envelope = NotchPresentation.envelope(geometry)
                            let compact = NotchPresentation.target(geometry, expanded: false, tab: .music, notice: false)
                            expect(compact.height == geometry.topInset, "compact never adds height beneath camera")
                            expect(screen.contains(envelope), "bounded envelope remains on its selected display")
                            expect(envelope.maxY == geometry.top, "top edge stays anchored")
                            for tab in NotchTab.allCases {
                                for expanded in [false, true] {
                                    for notice in [false, true] {
                                        let target = NotchPresentation.target(geometry, expanded: expanded, tab: tab, notice: notice)
                                        expect(envelope == NotchPresentation.envelope(geometry), "tab/notice does not resize window")
                                        for step in 0...20 {
                                            let state = NotchPresentation.interpolate(from: compact, to: target, progress: Double(step) / 20, opening: expanded || notice)
                                            let frame = NotchPresentation.frame(state, in: envelope)
                                            expect(envelope.contains(frame), "every animated sample stays inside envelope")
                                            expect(frame.maxY == envelope.maxY, "interpolation grows downwards")
                                            expect(state.width.isFinite && state.height.isFinite, "finite dimensions")
                                            let center = CGPoint(x: frame.midX, y: frame.midY)
                                            expect(NotchSurfaceShape.contains(screenPoint: center, frame: frame, state: state), "visible center accepts input")
                                            let margin = CGPoint(x: envelope.minX + 1, y: frame.midY)
                                            expect(!NotchSurfaceShape.contains(screenPoint: margin, frame: frame, state: state), "transparent side margin rejects input")
                                            let below = CGPoint(x: envelope.midX, y: envelope.minY + 1)
                                            expect(!NotchSurfaceShape.contains(screenPoint: below, frame: frame, state: state), "transparent lower margin rejects input")
                                            let corner = CGPoint(x: frame.minX + 0.1, y: frame.minY + 0.1)
                                            expect(!NotchSurfaceShape.contains(screenPoint: corner, frame: frame, state: state), "rounded corner rejects input")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        let noNotch = NotchDisplayOption(id: "external", name: "External", hasCutout: false)
        let notch = NotchDisplayOption(id: "internal", name: "Internal", hasCutout: true)
        expect(NotchDisplayPolicy.select(options: [noNotch, notch], preference: "automatic", main: "external") == "internal", "automatic prefers physical cutout")
        expect(NotchDisplayPolicy.select(options: [notch, noNotch], preference: "external", main: "internal") == "external", "explicit display takes precedence")
        expect(NotchDisplayPolicy.select(options: [notch], preference: "external", main: nil) == "internal", "unplugged display has a fallback")
        expect(NotchDisplayPolicy.select(options: [notch, noNotch], preference: "external", main: nil) == "external", "reconnected saved display is restored")
        expect(NotchDisplayPolicy.select(options: [], preference: "automatic", main: nil) == nil, "no screen is handled")
        var haptics = NotchHapticGate()
        expect(!haptics.accept(enabled: false, now: 0), "haptics opt-out")
        expect(haptics.accept(enabled: true, now: 1), "first action may provide feedback")
        expect(!haptics.accept(enabled: true, now: 1.1), "debounce repeated actions")
        expect(haptics.accept(enabled: true, now: 1.3), "later action is allowed")
        expect(!haptics.accept(enabled: true, now: .nan), "invalid clock cannot trigger feedback")
        expect(NotchNotice.filesAdded(2).tab == .files && NotchNotice.timerFinished.tab == .timer, "notices open their own destination")

        let animator = NotchSurfaceAnimator()
        let compact = NotchSurfaceState.initial
        let expanded = NotchSurfaceState(width: 360, height: 270, flare: 6, radius: 22, expansion: 1)
        animator.move(to: compact, animated: false)
        expect(!animator.isAnimating, "initial placement is timer-free")
        animator.move(to: expanded, animated: true)
        expect(animator.isAnimating && animator.state == compact, "opening starts at current sample")
        pump(for: 0.07)
        let midway = animator.state
        expect(midway.height > compact.height && midway.height < expanded.height, "real run-loop animation advances")
        animator.move(to: compact, animated: true)
        expect(animator.state == midway, "interrupted opening retargets without a jump")
        pump(for: 0.4)
        expect(animator.state == compact && !animator.isAnimating, "collapse finishes and destroys timer")
        animator.move(to: expanded, animated: true)
        animator.move(to: expanded, animated: false)
        expect(animator.state == expanded && !animator.isAnimating, "Reduce Motion snaps and stops animation")
        animator.move(to: compact, animated: true)
        animator.stop()
        let stopped = animator.state
        pump(for: 0.08)
        expect(!animator.isAnimating && animator.state == stopped, "suspend/stop prevents later animation writes")
        print("PASS: \(checks) notch presentation, input-outline, display, feedback and real run-loop animation checks.")
        print("These checks do not claim physical trackpad, human-perceived latency or Finder-to-app end-to-end validation.")
    }
    @MainActor private static func pump(for duration: TimeInterval) {
        let end = Date().addingTimeInterval(duration)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) }
    }
}
