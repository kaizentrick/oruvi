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
    init(controller: NotchController) { self.controller = controller }
    func start() {
        if global == nil && local == nil {
            let mask: NSEvent.EventTypeMask = [.mouseMoved]
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
        let near = controller.pointerWatchFrame.map { NotchHoverGeometry.contains(NSEvent.mouseLocation, in: $0) } ?? false
        // Far-away pointer movement does not mutate observable UI state.
        if near || wasNear || controller.expanded { controller.refreshPointer() }
        wasNear = near
        if near && nearCameraTimer == nil {
            // This local probe recovers missing/stationary events behind the camera.
            // It exists only near the notch, never as an idle-wide polling loop.
            let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            timer.tolerance = 0.01; nearCameraTimer = timer; RunLoop.main.add(timer, forMode: .common)
        } else if !near {
            nearCameraTimer?.invalidate(); nearCameraTimer = nil
        }
    }
    func stop() {
        if let global { NSEvent.removeMonitor(global); self.global = nil }
        if let local { NSEvent.removeMonitor(local); self.local = nil }
        nearCameraTimer?.invalidate(); nearCameraTimer = nil; wasNear = false
    }
}
