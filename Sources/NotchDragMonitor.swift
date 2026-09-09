// Copyright (c) 2026 KaizenTrick.
import AppKit

/// Passive mouse-only proximity detection. No keyboard monitor, event tap,
/// general clipboard reads, file-content reads, event suppression or saved history.
@MainActor
final class NotchDragMonitor {
    private weak var controller: NotchController?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var gestureTimer: Timer?
    private var releaseTask: Task<Void, Never>?
    private var freshness = NotchDragFreshness()
    private var lastSample = -Double.greatestFiniteMagnitude
    private var startedInShelf = false
    private let pasteboard = NSPasteboard(name: .drag)

    init(controller: NotchController) { self.controller = controller }
    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        freshness.end(changeCount: pasteboard.changeCount)
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }
    private func handle(_ event: NSEvent) {
        guard let controller, controller.acceptsFileDrop else { return }
        switch event.type {
        case .leftMouseDown:
            releaseTask?.cancel(); releaseTask = nil
            freshness.end(changeCount: pasteboard.changeCount); controller.endFileDrag()
            freshness.begin(changeCount: pasteboard.changeCount)
            startedInShelf = controller.expanded && controller.tab == .files && controller.containsSurface(NSEvent.mouseLocation)
            controller.clickedOutside(); watchDrag()
        case .leftMouseDragged: sampleGesture()
        case .leftMouseUp: finishGestureAfterDrop()
        default: break
        }
    }
    private func sampleGesture() {
        guard let controller, controller.acceptsFileDrop else { stop(); return }
        // Native drag loops may swallow movement events. Reuse this existing,
        // gesture-scoped probe to recover input targeting without another timer.
        controller.refreshPointer()
        guard NSEvent.pressedMouseButtons & 1 != 0 else { finishGestureAfterDrop(); return }
        if controller.draggingFiles {
            if !controller.dragRetentionFrame.contains(NSEvent.mouseLocation) { controller.endFileDrag() }
            return
        }
        guard !startedInShelf, let approach = controller.approachFrame,
              approach.contains(NSEvent.mouseLocation) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSample >= 0.04 else { return }; lastSample = now
        let count = pasteboard.changeCount
        guard freshness.accepts(changeCount: count, advertisesFiles: pasteboard.availableType(from: [.fileURL]) != nil) else { return }
        controller.beginFileDrag()
    }
    func watchDrag() {
        guard gestureTimer == nil else { return }
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleGesture() }
        }
        timer.tolerance = 0.02; gestureTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func finishGestureAfterDrop() {
        freshness.end(changeCount: pasteboard.changeCount)
        gestureTimer?.invalidate(); gestureTimer = nil
        guard controller?.draggingFiles == true, releaseTask == nil else { return }
        releaseTask = Task { [weak self] in
            // Let AppKit deliver performDragOperation before cancelled-drag cleanup.
            do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.controller?.endFileDrag(); self.releaseTask = nil
        }
    }
    func stopWatchingDrag() {
        releaseTask?.cancel(); releaseTask = nil
        if !freshness.pressed { gestureTimer?.invalidate(); gestureTimer = nil }
    }
    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        gestureTimer?.invalidate(); gestureTimer = nil
        releaseTask?.cancel(); releaseTask = nil
        freshness.end(changeCount: pasteboard.changeCount); startedInShelf = false
    }
}
