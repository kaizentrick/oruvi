// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Observation
import ColorSync

/// Independently implemented concave attachment/capsule. No third-party assets,
/// facial models, lock-screen overlays or private APIs are involved.
struct NotchSurfaceShape: Shape {
    let flare: CGFloat
    let radius: CGFloat
    func path(in rect: CGRect) -> Path { Path(Self.outline(in: rect, flare: flare, radius: radius)) }
    static func outline(in rect: CGRect, flare: CGFloat, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let f = min(max(0, flare), min(rect.width / 4, rect.height / 2))
        let r = min(max(0, radius), min((rect.width - 2 * f) / 2, rect.height / 2))
        guard f > 0 else {
            path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
            return path
        }
        let left = rect.minX + f, right = rect.maxX - f, top = rect.minY, bottom = rect.maxY
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + f), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: right - r, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: left + r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - r), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: top + f))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: top), control: CGPoint(x: left, y: top))
        path.closeSubpath()
        return path
    }
    static func contains(screenPoint: CGPoint, frame: CGRect, state: NotchSurfaceState) -> Bool {
        guard frame.contains(screenPoint) else { return false }
        let local = CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
        return outline(in: CGRect(origin: .zero, size: frame.size), flare: state.flare, radius: state.radius).contains(local)
    }
}

/// A short-lived main-run-loop animation keeps drawing and input on the same
/// sample. No window resizing and no animation timer at rest or when hidden.
@MainActor @Observable
final class NotchSurfaceAnimator {
    private(set) var state = NotchSurfaceState.initial
    private(set) var target = NotchSurfaceState.initial
    @ObservationIgnored var onStep: (() -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var origin = NotchSurfaceState.initial
    @ObservationIgnored private var started: TimeInterval = 0
    @ObservationIgnored private var duration: TimeInterval = 0
    @ObservationIgnored private var opening = false
    var isAnimating: Bool { timer != nil }

    func move(to value: NotchSurfaceState, animated: Bool) {
        if value == target && timer != nil && animated { return }
        stop()
        target = value
        guard animated, state != value else { state = value; onStep?(); return }
        origin = state
        opening = value.height > state.height || value.expansion > state.expansion
        duration = opening ? NotchPresentation.openingDuration : NotchPresentation.closingDuration
        started = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        timer.tolerance = 0.002
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    private func step() {
        let progress = (ProcessInfo.processInfo.systemUptime - started) / duration
        state = NotchPresentation.interpolate(from: origin, to: target, progress: progress, opening: opening)
        if progress >= 1 { state = target; stop() }
        onStep?()
    }
    func stop() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
}

enum NotchDisplays {
    @MainActor static func identifier(_ screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return "name:\(screen.localizedName)"
        }
        if let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuid) as String
        }
        return "display:\(number.uint32Value)"
    }
    @MainActor static func options(_ screens: [NSScreen]) -> [NotchDisplayOption] {
        screens.enumerated().map { index, screen in
            NotchDisplayOption(id: identifier(screen), name: "\(index + 1). \(screen.localizedName)", hasCutout: screen.safeAreaInsets.top > 0)
        }
    }
}
