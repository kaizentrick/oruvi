// Copyright (c) 2026 KaizenTrick.
import AppKit
import SwiftUI
import Observation
import QuartzCore

final class OruviNotchPanel: NSPanel {
    var acceptsKeyboard = false
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

extension NotchGeometry {
    @MainActor static func resolve(_ screen: NSScreen) -> NotchGeometry {
        resolve(frame: screen.frame, safeTop: screen.safeAreaInsets.top,
                left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea, scale: screen.backingScaleFactor)
    }
}

/// The native input surface is permanent, including with no player installed.
/// Playback only changes the content; it never enables/disables pointer handling.
@MainActor @Observable
final class NotchController {
    private var input = NotchInteractionState()
    var expanded: Bool { input.expanded }
    var draggingFiles: Bool { input.fileDragActive }
    var tab: NotchTab = .music
    var cameraWidth: CGFloat = 0
    var topInset: CGFloat = 30
    var compactWidth: CGFloat = 150
    @ObservationIgnored let shelf = NotchShelf()
    @ObservationIgnored let agenda = NotchAgenda()
    @ObservationIgnored let countdown = NotchCountdown()
    @ObservationIgnored private let model: StandbyModel
    @ObservationIgnored private var panel: OruviNotchPanel?
    @ObservationIgnored private var geometry: NotchGeometry?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var transition = NotchTransitionGate()
    @ObservationIgnored private var dragMonitor: NotchDragMonitor?
    @ObservationIgnored private var previousDragTab: NotchTab?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var systemSleeping = false
    @ObservationIgnored private var displaySleeping = false
    @ObservationIgnored private var sessionInactive = false
    @ObservationIgnored private var screenLocked = false
    @ObservationIgnored private var presentationHandoff = false
    @ObservationIgnored private var reconcileQueued = false
    @ObservationIgnored private var trackingMenus: Set<ObjectIdentifier> = []
    private var sessionBlocked: Bool { systemSleeping || displaySleeping || sessionInactive || screenLocked }

    var preventsAutomaticStandby: Bool { input.preventsAutomaticStandby }
    var acceptsFileDrop: Bool { input.visible && isShown && !sessionBlocked }
    var approachFrame: CGRect? {
        guard input.visible, let geometry else { return nil }
        return NotchApproachGeometry.region(compact: geometry.frame(expanded: false), screen: geometry.screenFrame)
    }
    var dragRetentionFrame: CGRect {
        (approachFrame ?? frame).union(frame.insetBy(dx: -18, dy: -18))
    }
    init(model: StandbyModel) { self.model = model; model.notch = self }
    func start() {
        guard panel == nil, !stopped else { return }
        let p = OruviNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = false; p.acceptsMouseMovedEvents = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovable = false; p.isMovableByWindowBackground = false
        let hosting = NotchDropHostingView(rootView: NotchView(model: model, controller: self))
        hosting.controller = self
        hosting.sizingOptions = []; hosting.safeAreaRegions = []
        hosting.wantsLayer = true; hosting.layer?.masksToBounds = true
        hosting.registerForDraggedTypes([.fileURL])
        p.contentView = hosting
        p.onEscape = { [weak self] in self?.collapse() }
        p.identifier = NSUserInterfaceItemIdentifier("oruvi.notch")
        p.appearance = NSAppearance(named: .darkAqua)
        panel = p; dragMonitor = NotchDragMonitor(controller: self)
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.reconcileNextTurn() }
        let keyToken = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.input.keyboardPinned = false; self?.refreshPointer()
            }
        }
        observers.append((NotificationCenter.default, keyToken))
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let menu = notification.object as? NSMenu else { return }
                    let identity = ObjectIdentifier(menu)
                    if notification.name == NSMenu.didBeginTrackingNotification {
                        guard self.expanded else { return }; self.trackingMenus.insert(identity)
                    } else { self.trackingMenus.remove(identity) }
                    self.input.menuTracking = !self.trackingMenus.isEmpty
                    self.refreshPointer()
                }
            }
            observers.append((NotificationCenter.default, token))
        }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in self?.systemSleeping = true; self?.reconcile() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { [weak self] in self?.displaySleeping = true; self?.reconcile() }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.sessionInactive = true; self?.reconcile() }
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in self?.systemSleeping = false; self?.reconcileNextTurn() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { [weak self] in self?.displaySleeping = false; self?.reconcileNextTurn() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.sessionInactive = false; self?.reconcileNextTurn() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in self?.reconcileNextTurn() }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] in self?.reconcileNextTurn() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.screenLocked = true; self?.reconcile() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.screenLocked = false; self?.reconcileNextTurn() }
        reconcile()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        observers.append((center, token))
    }
    private func reconcileNextTurn() {
        guard !reconcileQueued, !stopped else { return }; reconcileQueued = true
        // Let StandbyModel and AmbientRuntime process the same wake/Space notification first.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.reconcileQueued = false; self.reconcile()
        }
    }
    func reconcile() {
        guard let panel else { return }
        let show = !stopped && !presentationHandoff && model.notchEnabled && !model.isVisible && !model.screenSleeping && !sessionBlocked && !(model.runtime?.isBlocked ?? false)
        guard show else {
            cancelHover(); input.suspend(); previousDragTab = nil; trackingMenus.removeAll()
            panel.acceptsKeyboard = false; agenda.setActive(false); dragMonitor?.stop()
            if sessionBlocked || stopped { shelf.cancelChooser() }
            panel.orderOut(nil); model.notchExpanded = false; model.setNotchVisible(false); return
        }
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        geometry = NotchGeometry.resolve(screen)
        if let geometry { cameraWidth = geometry.cameraWidth; topInset = geometry.topInset; compactWidth = geometry.compactWidth }
        input.visible = true
        updateFrame(animated: false)
        panel.ignoresMouseEvents = false; panel.orderFrontRegardless()
        model.setNotchVisible(true); dragMonitor?.start()
        // A stationary pointer may already be inside after wake or a screen change.
        refreshPointer()
    }
    func hideForPresentation() { presentationHandoff = true; reconcile() }
    func resumeDesktop() { presentationHandoff = false; reconcile() }
    private var pointerFrame: CGRect { geometry?.frame(expanded: expanded) ?? frame }
    func refreshPointer() { hover(input.visible && pointerFrame.contains(NSEvent.mouseLocation)) }
    func hover(_ inside: Bool) {
        guard input.visible else { return }
        if !inside { input.suppressHoverUntilExit = false }
        if input.pointerInside != inside { input.pointerInside = inside }
        scheduleExpansion()
    }
    private func cancelHover() { hoverTask?.cancel(); hoverTask = nil; transition.cancel() }
    private func scheduleExpansion() {
        let target = input.targetExpanded
        guard target != expanded else { cancelHover(); return }
        guard transition.arm(target: target, current: expanded) else { return }
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: target ? 120_000_000 : 380_000_000) } catch { return }
            guard !Task.isCancelled, let self, self.transition.pending == target, self.input.targetExpanded == target else { return }
            self.hoverTask = nil; self.transition.cancel(); self.setExpanded(target)
        }
    }
    func openForKeyboard() {
        guard input.visible else { return }
        cancelHover(); input.suppressHoverUntilExit = false; input.keyboardPinned = true; setExpanded(true)
        panel?.acceptsKeyboard = true; panel?.makeKey()
    }
    func collapse() {
        guard input.interactionDepth == 0, !input.menuTracking else { return }
        cancelHover(); input.pointerInside = false; input.keyboardPinned = false
        input.suppressHoverUntilExit = true
        input.fileDragActive = false; previousDragTab = nil; dragMonitor?.stopWatchingDrag()
        setExpanded(false)
    }
    func clickedOutside() {
        guard expanded, !frame.contains(NSEvent.mouseLocation) else { return }
        collapse()
    }
    func select(_ value: NotchTab) {
        guard tab != value else { return }
        tab = value; agenda.setActive(expanded && value == .agenda)
    }
    func setExpanded(_ value: Bool, animated: Bool = true) {
        guard (!value || input.visible), expanded != value else { return }
        input.expanded = value; model.notchExpanded = value
        if !value { input.keyboardPinned = false; panel?.acceptsKeyboard = false; panel?.resignKey() }
        agenda.setActive(value && tab == .agenda)
        updateFrame(animated: animated && !model.reduceMotion)
        model.runtime?.rescheduleIdle()
    }
    func beginInteraction() { input.interactionDepth += 1; cancelHover() }
    func endInteraction() { input.interactionDepth = max(0, input.interactionDepth - 1); refreshPointer() }
    func beginFileDrag() {
        guard acceptsFileDrop else { return }
        if !draggingFiles { previousDragTab = tab }
        input.suppressHoverUntilExit = false; input.fileDragActive = true; cancelHover(); select(.files)
        // Open immediately so a quick drop never lands on a still-collapsed window.
        setExpanded(true, animated: false); dragMonitor?.watchDrag()
    }
    func fileDragExited() {
        guard !dragRetentionFrame.contains(NSEvent.mouseLocation) else { return }
        endFileDrag(accepted: false)
    }
    func endFileDrag(accepted: Bool = false) {
        guard draggingFiles else { return }
        input.fileDragActive = false; dragMonitor?.stopWatchingDrag()
        if !accepted, let previousDragTab { select(previousDragTab) }
        previousDragTab = nil; refreshPointer()
    }
    private func updateFrame(animated: Bool) {
        guard let panel, let geometry else { return }
        let rect = geometry.frame(expanded: expanded)
        guard panel.frame != rect else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(rect, display: true)
            }
        } else { panel.setFrame(rect, display: true) }
    }
    func stop() {
        stopped = true; cancelHover(); input.suspend(); dragMonitor?.stop(); panel?.orderOut(nil)
        agenda.stop(); countdown.stop(); shelf.cancelChooser(); shelf.clear()
        model.notchExpanded = false; model.setNotchVisible(false)
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
        trackingMenus.removeAll(); panel = nil
    }
    #if LUMA_QA
    func captureQA(to url: URL) {
        guard let content = panel?.contentView else { return }
        content.layoutSubtreeIfNeeded()
        guard let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?.write(to: url)
    }
    #endif
    var isShown: Bool { panel?.isVisible == true }
    var frame: NSRect { panel?.frame ?? .zero }
}

/// A persistent tracking area covers the whole window, not just artwork/text.
/// Native drag callbacks own acceptance; proximity NEVER imports files itself.
final class NotchDropHostingView: NSHostingView<NotchView> {
    weak var controller: NotchController?
    private var pointerArea: NSTrackingArea?
    private var cachedSequence = -1
    private var cachedChangeCount = -1
    private var cachedURLs: [URL] = []
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerArea { removeTrackingArea(pointerArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        addTrackingArea(area); pointerArea = area
    }
    override func mouseEntered(with event: NSEvent) { controller?.refreshPointer() }
    override func mouseExited(with event: NSEvent) { controller?.refreshPointer() }
    override func mouseMoved(with event: NSEvent) { controller?.refreshPointer() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        // Route an active file drag to the permanent native drop target, across all tabs.
        if controller?.draggingFiles == true { return self }
        return super.hitTest(point) ?? self
    }
    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        let pasteboard = sender.draggingPasteboard
        if cachedSequence != sender.draggingSequenceNumber || cachedChangeCount != pasteboard.changeCount {
            cachedSequence = sender.draggingSequenceNumber; cachedChangeCount = pasteboard.changeCount
            let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
            let urls = objects.prefix(NotchFilePolicy.limit).compactMap { ($0 as? NSURL).map { $0 as URL } }
            cachedURLs = NotchFilePolicy.candidates(urls, existing: [])
        }
        return cachedURLs
    }
    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        controller?.acceptsFileDrop == true && sender.draggingSourceOperationMask.contains(.copy) && !urls(sender).isEmpty
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        controller?.beginFileDrag(); return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        controller?.beginFileDrag(); return .copy
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.fileDragExited() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender), let controller else { return false }
        controller.shelf.add(urls(sender)); controller.endFileDrag(accepted: true); clearDragCache(); return true
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        controller?.endFileDrag(accepted: false); clearDragCache()
    }
    private func clearDragCache() { cachedSequence = -1; cachedChangeCount = -1; cachedURLs.removeAll() }
}
