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

/// Original AppKit/SwiftUI implementation. Hover never activates the app. Keyboard
/// focus is opt-in on click; sharing and permission dialogs keep the panel open.
@MainActor @Observable
final class NotchController {
    var expanded = false
    var tab: NotchTab = .music
    var cameraWidth: CGFloat = 0
    var topInset: CGFloat = 30
    var compactWidth: CGFloat = 150
    var draggingFiles = false
    @ObservationIgnored let shelf = NotchShelf()
    @ObservationIgnored let agenda = NotchAgenda()
    @ObservationIgnored let countdown = NotchCountdown()
    @ObservationIgnored private let model: StandbyModel
    @ObservationIgnored private var panel: OruviNotchPanel?
    @ObservationIgnored private var geometry: NotchGeometry?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var sessionBlocked = false
    @ObservationIgnored private var presentationHandoff = false
    @ObservationIgnored private var interactionCount = 0
    @ObservationIgnored private var trackingMenus: Set<ObjectIdentifier> = []

    var preventsAutomaticStandby: Bool { expanded || interactionCount > 0 || draggingFiles }
    init(model: StandbyModel) { self.model = model; model.notch = self }
    func start() {
        let p = OruviNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovable = false; p.isMovableByWindowBackground = false
        let hosting = NotchDropHostingView(rootView: NotchView(model: model, controller: self))
        hosting.controller = self
        // AppKit owns the window size. Do not let intrinsic SwiftUI sizing or a
        // second automatic safe-area inset enlarge the compact camera band.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.wantsLayer = true; hosting.layer?.masksToBounds = true
        hosting.registerForDraggedTypes([.fileURL])
        p.contentView = hosting
        p.onEscape = { [weak self] in self?.collapse() }
        p.identifier = NSUserInterfaceItemIdentifier("oruvi.notch")
        p.appearance = NSAppearance(named: .darkAqua)
        panel = p
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.reconcile() }
        observe(NotificationCenter.default, NSWindow.didResignKeyNotification) { [weak self] in
            guard let self, self.panel?.isKeyWindow == false, !self.hovering else { return }
            self.hover(false)
        }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let menu = notification.object as? NSMenu else { return }
                    let identity = ObjectIdentifier(menu)
                    if notification.name == NSMenu.didBeginTrackingNotification {
                        guard self.expanded, self.trackingMenus.insert(identity).inserted else { return }
                        self.beginInteraction()
                    } else if self.trackingMenus.remove(identity) != nil { self.endInteraction() }
                }
            }
            observers.append((NotificationCenter.default, token))
        }
        for event in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observe(workspace, event) { [weak self] in self?.sessionBlocked = true; self?.reconcile() }
        }
        for event in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, event) { [weak self] in self?.sessionBlocked = false; self?.reconcile() }
        }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.sessionBlocked = true; self?.reconcile() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.sessionBlocked = false; self?.reconcile() }
        reconcile()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        observers.append((center, token))
    }
    func reconcile() {
        guard let panel else { return }
        let show = !stopped && !presentationHandoff && model.notchEnabled && !model.isVisible && !model.screenSleeping && !sessionBlocked && !(model.runtime?.isBlocked ?? false)
        guard show else {
            hoverTask?.cancel(); expanded = false; hovering = false; draggingFiles = false; model.notchExpanded = false
            panel.acceptsKeyboard = false
            agenda.setActive(false)
            if sessionBlocked || stopped { shelf.cancelChooser() }
            panel.orderOut(nil); model.setNotchVisible(false); return
        }
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        geometry = NotchGeometry.resolve(screen)
        if let geometry { cameraWidth = geometry.cameraWidth; topInset = geometry.topInset; compactWidth = geometry.compactWidth }
        updateFrame(animated: false)
        panel.orderFrontRegardless()
        model.setNotchVisible(true)
    }
    func hideForPresentation() { presentationHandoff = true; reconcile() }
    func resumeDesktop() { presentationHandoff = false; reconcile() }
    func hover(_ inside: Bool) {
        hovering = inside; hoverTask?.cancel()
        guard inside || (interactionCount == 0 && !draggingFiles && panel?.isKeyWindow != true) else { return }
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: inside ? 160_000_000 : 380_000_000) } catch { return }
            guard !Task.isCancelled, let self, self.hovering == inside, self.model.notchVisible else { return }
            if !inside && (self.interactionCount > 0 || self.draggingFiles || self.panel?.isKeyWindow == true) { return }
            self.setExpanded(inside)
        }
    }
    func openForKeyboard() {
        hoverTask?.cancel(); setExpanded(true)
        panel?.acceptsKeyboard = true; panel?.makeKey()
    }
    func collapse() {
        guard interactionCount == 0 else { return }
        hoverTask?.cancel(); hovering = false; draggingFiles = false
        setExpanded(false)
    }
    func select(_ value: NotchTab) {
        tab = value
        agenda.setActive(expanded && value == .agenda)
    }
    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value; model.notchExpanded = value
        if !value { panel?.acceptsKeyboard = false; panel?.resignKey() }
        agenda.setActive(value && tab == .agenda)
        updateFrame(animated: !model.reduceMotion)
        model.runtime?.rescheduleIdle()
    }
    func beginInteraction() { interactionCount += 1; hoverTask?.cancel() }
    func endInteraction() {
        interactionCount = max(0, interactionCount - 1)
        if !hovering { hover(false) }
    }
    func beginFileDrag() {
        hoverTask?.cancel(); draggingFiles = true; select(.files); setExpanded(true)
    }
    func endFileDrag() {
        draggingFiles = false
        hovering = panel?.frame.contains(NSEvent.mouseLocation) == true
        hover(hovering)
    }
    private func updateFrame(animated: Bool) {
        guard let panel, let geometry else { return }
        let rect = geometry.frame(expanded: expanded)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(rect, display: true)
            }
        } else { panel.setFrame(rect, display: true) }
    }
    func stop() {
        stopped = true; hoverTask?.cancel(); panel?.orderOut(nil)
        agenda.stop(); countdown.stop(); shelf.cancelChooser(); shelf.clear()
        model.setNotchVisible(false)
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
        trackingMenus.removeAll(); interactionCount = 0
        panel = nil
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

/// AppKit handles Finder drags without polling the clipboard or requesting accessibility.
final class NotchDropHostingView: NSHostingView<NotchView> {
    weak var controller: NotchController?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(sender).isEmpty else { return [] }
        controller?.beginFileDrag(); return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { urls(sender).isEmpty ? [] : .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.endFileDrag() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let files = urls(sender)
        guard !files.isEmpty, let controller else { return false }
        controller.shelf.add(files); controller.endFileDrag(); return true
    }
}
