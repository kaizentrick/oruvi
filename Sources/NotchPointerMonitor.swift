// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit

/// Native tracking cannot cover the camera housing. Observe mouse movement
/// passively and test screen coordinates, without intercepting clicks or keys.
@MainActor
final class NotchPointerMonitor {
    private weak var controller: NotchController?
    private var global: Any?
    private var local: Any?
    private var nearCameraTimer: Timer?
    private var wasNear = false
    private var cadence = NotchPointerCadence()
    init(controller: NotchController) { self.controller = controller }
    func start() {
        if global == nil && local == nil {
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            global = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            local = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.sample() }
                return event
            }
        }
        sample()
    }
    private func sample() {
        guard let controller, controller.acceptsFileDrop else { stop(); return }
        let point = NSEvent.mouseLocation
        let near = controller.pointerWatchFrame.map { NotchHoverGeometry.contains(point, in: $0) } ?? false
        if near || wasNear || controller.expanded || controller.notice != nil { controller.refreshPointer(at: point) }
        wasNear = near
        let interval = cadence.interval(near: near, at: point, uptime: ProcessInfo.processInfo.systemUptime)
        guard interval != nearCameraTimer?.timeInterval else { return }
        nearCameraTimer?.invalidate(); nearCameraTimer = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = min(0.05, interval / 6)
        nearCameraTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func stop() {
        if let global { NSEvent.removeMonitor(global); self.global = nil }
        if let local { NSEvent.removeMonitor(local); self.local = nil }
        nearCameraTimer?.invalidate(); nearCameraTimer = nil; wasNear = false
        cadence = NotchPointerCadence()
    }
}
