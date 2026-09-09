// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Observation

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

@MainActor @Observable
final class NotchController {
    private var input = NotchInteractionState()
    var expanded: Bool { input.expanded }
    var draggingFiles: Bool { input.fileDragActive }
    var tab: NotchTab = .music
    var cameraWidth: CGFloat = 0
    var topInset: CGFloat = 30
    var compactWidth: CGFloat = 150
    private(set) var notice: NotchNotice?
    private(set) var displayChoices: [NotchDisplayOption] = []
    var hapticsEnabled = UserDefaults.standard.bool(forKey: "notchHapticsEnabled") {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "notchHapticsEnabled") }
    }
    var noticesEnabled = (UserDefaults.standard.object(forKey: "notchNoticesEnabled") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(noticesEnabled, forKey: "notchNoticesEnabled")
            if !noticesEnabled { dismissNotice() }
        }
    }
    private(set) var selectedDisplayID = UserDefaults.standard.string(forKey: "notchDisplayID") ?? "automatic"
    @ObservationIgnored let surface = NotchSurfaceAnimator()
    @ObservationIgnored let shelf = NotchShelf()
    @ObservationIgnored let agenda = NotchAgenda()
    @ObservationIgnored let countdown = NotchCountdown()
    @ObservationIgnored private let model: StandbyModel
    @ObservationIgnored private var panel: OruviNotchPanel?
    @ObservationIgnored private var geometry: NotchGeometry?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var transition = NotchTransitionGate()
    @ObservationIgnored private var hapticGate = NotchHapticGate()
    @ObservationIgnored private var observedFileCount = 0
    @ObservationIgnored private var observedTimerCompleted = false
    @ObservationIgnored private var dragMonitor: NotchDragMonitor?
    @ObservationIgnored private var pointerMonitor: NotchPointerMonitor?
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
    @ObservationIgnored private var pendingMenuAction: (() -> Void)?
    private var sessionBlocked: Bool { systemSleeping || displaySleeping || sessionInactive || screenLocked }
    private var allowsAnimation: Bool {
        !model.reduceMotion && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    var preventsAutomaticStandby: Bool { input.preventsAutomaticStandby }
    var acceptsFileDrop: Bool { input.visible && isShown && !sessionBlocked }
    var approachFrame: CGRect? {
        guard input.visible, let geometry else { return nil }
        return NotchApproachGeometry.region(compact: geometry.frame(expanded: false), screen: geometry.screenFrame)
    }
    var pointerWatchFrame: CGRect? {
        guard input.visible, let geometry else { return nil }
        return NotchHoverGeometry.watchRegion(compact: geometry.frame(expanded: false), screen: geometry.screenFrame)
    }
    var dragRetentionFrame: CGRect { (approachFrame ?? frame).union(frame.insetBy(dx: -18, dy: -18)) }
    init(model: StandbyModel) { self.model = model; model.notch = self }
    func start() {
        guard panel == nil, !stopped else { return }
        let p = OruviNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = true; p.acceptsMouseMovedEvents = true
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
        panel = p
        surface.onStep = { [weak self] in self?.updateInputTransparency() }
        dragMonitor = NotchDragMonitor(controller: self); pointerMonitor = NotchPointerMonitor(controller: self)
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.reconcileNextTurn() }
        let keyToken = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.input.keyboardPinned = false; self?.refreshPointer() }
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
                    self.refreshPointer(); self.runMenuActionIfReady()
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
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in self?.updateFrame(animated: false) }
        observe(NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange) { [weak self] in self?.updateFrame(animated: false) }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.screenLocked = true; self?.reconcile() }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.screenLocked = false; self?.reconcileNextTurn() }
        observeActivity()
        reconcile()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        observers.append((center, token))
    }
    private func observeActivity() {
        guard !stopped else { return }
        withObservationTracking {
            _ = shelf.items.count; _ = countdown.state.completed; _ = model.reduceMotion
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                let added = self.shelf.items.count - self.observedFileCount
                let finished = self.countdown.state.completed && !self.observedTimerCompleted
                self.observedFileCount = self.shelf.items.count
                self.observedTimerCompleted = self.countdown.state.completed
                self.observeActivity()
                if !self.allowsAnimation { self.surface.move(to: self.surface.target, animated: false) }
                if finished { self.presentNotice(.timerFinished) }
                else if added > 0 { self.presentNotice(.filesAdded(added)) }
            }
        }
    }
    private func reconcileNextTurn() {
        guard !reconcileQueued, !stopped else { return }; reconcileQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.reconcileQueued = false; self.reconcile()
        }
    }
    func reconcile() {
        guard let panel else { return }
        let show = !stopped && !presentationHandoff && model.notchEnabled && !model.isVisible && !model.screenSleeping && !sessionBlocked && !(model.runtime?.isBlocked ?? false)
        guard show else {
            cancelHover(); input.suspend(); surface.stop(); dismissNotice()
            previousDragTab = nil; trackingMenus.removeAll(); pendingMenuAction = nil
            panel.acceptsKeyboard = false; panel.ignoresMouseEvents = true
            agenda.setActive(false); dragMonitor?.stop(); pointerMonitor?.stop()
            if sessionBlocked || stopped { shelf.cancelChooser() }
            panel.orderOut(nil); model.notchExpanded = false; model.setNotchVisible(false); return
        }
        let screens = NSScreen.screens
        let options = NotchDisplays.options(screens)
        if options != displayChoices { displayChoices = options }
        let chosen = NotchDisplayPolicy.select(options: options, preference: selectedDisplayID, main: NSScreen.main.map { NotchDisplays.identifier($0) })
        guard let screen = screens.first(where: { NotchDisplays.identifier($0) == chosen }) else {
            surface.stop(); panel.ignoresMouseEvents = true; panel.orderOut(nil)
            input.suspend(); model.notchExpanded = false; model.setNotchVisible(false)
            agenda.setActive(false); dragMonitor?.stop(); pointerMonitor?.stop(); dismissNotice(); return
        }
        let wasVisible = input.visible
        geometry = NotchGeometry.resolve(screen)
        if let geometry { cameraWidth = geometry.cameraWidth; topInset = geometry.topInset; compactWidth = geometry.compactWidth }
        input.visible = true
        updateFrame(animated: wasVisible)
        panel.orderFrontRegardless()
        model.setNotchVisible(true); dragMonitor?.start(); pointerMonitor?.start()
        refreshPointer()
    }
    func chooseDisplay(_ identifier: String) {
        guard identifier == "automatic" || displayChoices.contains(where: { $0.id == identifier }) else { return }
        selectedDisplayID = identifier
        UserDefaults.standard.set(identifier, forKey: "notchDisplayID")
        reconcileNextTurn()
    }
    func hideForPresentation() { presentationHandoff = true; reconcile() }
    func resumeDesktop() { presentationHandoff = false; reconcile() }
    func refreshPointer() {
        updateInputTransparency()
        guard input.visible, let geometry else { return }
        let activation = NotchHoverGeometry.activation(compact: geometry.frame(expanded: false), screen: geometry.screenFrame)
        // Keep the full camera band and exact top edge; never substitute the envelope.
        let visible = frame.insetBy(dx: -8, dy: -8)
        let destination = NotchPresentation.frame(surface.target, in: panel?.frame ?? .zero)
        let region = expanded ? activation.union(visible).union(destination.insetBy(dx: -8, dy: -8)) : (notice == nil ? activation : activation.union(visible))
        hover(NotchHoverGeometry.contains(NSEvent.mouseLocation, in: region))
    }
    func containsSurface(_ point: CGPoint) -> Bool {
        input.visible && !sessionBlocked && NotchSurfaceShape.contains(screenPoint: point, frame: frame, state: surface.state)
    }
    private func updateInputTransparency() {
        // Recomputed on pointer movement AND each animation sample, including a
        // stationary pointer during collapse. Invisible margins never become a target.
        panel?.ignoresMouseEvents = !containsSurface(NSEvent.mouseLocation)
    }
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
            do { try await Task.sleep(nanoseconds: target ? NotchHoverGeometry.openingDelay : NotchHoverGeometry.closingDelay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.refreshPointer()
            guard !Task.isCancelled, self.transition.pending == target, self.input.targetExpanded == target else { return }
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
        cancelHover(); input.pointerInside = false; input.keyboardPinned = false; input.suppressHoverUntilExit = true
        input.fileDragActive = false; previousDragTab = nil; dragMonitor?.stopWatchingDrag()
        dismissNotice(); setExpanded(false)
    }
    func clickedOutside() {
        guard expanded, !containsSurface(NSEvent.mouseLocation) else { return }; collapse()
    }
    func afterMenu(_ action: @escaping () -> Void) {
        pendingMenuAction = action; runMenuActionIfReady()
    }
    private func runMenuActionIfReady() {
        guard !input.menuTracking, let action = pendingMenuAction else { return }
        pendingMenuAction = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, !self.sessionBlocked else { return }; action()
        }
    }
    func select(_ value: NotchTab) {
        guard tab != value else { return }
        tab = value; agenda.setActive(expanded && value == .agenda)
        userHaptic(); updateFrame(animated: !draggingFiles)
    }
    func setExpanded(_ value: Bool, animated: Bool = true) {
        guard (!value || input.visible), expanded != value else { return }
        input.expanded = value; model.notchExpanded = value
        if !value { input.keyboardPinned = false; panel?.acceptsKeyboard = false; panel?.resignKey() }
        agenda.setActive(value && tab == .agenda)
        updateFrame(animated: animated)
        if value {
            if input.pointerInside || input.keyboardPinned || input.fileDragActive { userHaptic() }
            InstalledPlayers.shared.refresh(); model.refreshPlayback()
        }
        model.runtime?.rescheduleIdle()
    }
    private func userHaptic() {
        guard hapticGate.accept(enabled: hapticsEnabled && input.visible && !sessionBlocked, now: ProcessInfo.processInfo.systemUptime) else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
    private func presentNotice(_ value: NotchNotice) {
        guard noticesEnabled, input.visible, isShown, !sessionBlocked, !presentationHandoff else { return }
        if notice == .timerFinished, value != .timerFinished { return }
        noticeTask?.cancel(); notice = value
        updateFrame(animated: !draggingFiles)
        // One expiry task, no notification poller; hidden/locked events are not replayed.
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled else { return }; self?.dismissNotice()
        }
    }
    func dismissNotice() {
        noticeTask?.cancel(); noticeTask = nil
        guard notice != nil else { return }; notice = nil
        if input.visible { updateFrame(animated: !draggingFiles) }
    }
    func openNotice() {
        guard let target = notice?.tab else { return }
        dismissNotice(); select(target); openForKeyboard()
    }
    func showGuide() {
        beginInteraction()
        let alert = NSAlert()
        alert.messageText = "Oruvi, desde el notch"
        alert.informativeText = "Acerca el puntero, incluso sobre la cámara, para abrir el panel.\n\nMúsica: Automático sigue Ahora suena; Apple Music y Spotify mantienen sus controles. Notch y Standby conservan selecciones separadas.\n\nArchivos: arrastra desde Finder. AirDrop siempre te pide elegir destinatario.\n\nAgenda solicita permiso solo al conectarla. Temporizador avisa al terminar.\n\nEn Más opciones puedes elegir pantalla, háptica y avisos. Para añadir un widget real: clic secundario en el escritorio → Editar widgets → Oruvi.\n\nEsc o un clic fuera cierran el panel. Standby y el bloqueo lo ocultan. Oruvi no usa la cámara ni almacena contraseñas."
        alert.addButton(withTitle: "Entendido")
        NSApp.activate(); alert.runModal(); endInteraction()
    }
    func beginInteraction() { input.interactionDepth += 1; cancelHover() }
    func endInteraction() { input.interactionDepth = max(0, input.interactionDepth - 1); refreshPointer() }
    func beginFileDrag() {
        guard acceptsFileDrop else { return }
        if !draggingFiles { previousDragTab = tab }
        input.suppressHoverUntilExit = false; input.fileDragActive = true; cancelHover(); select(.files)
        setExpanded(true, animated: false); updateFrame(animated: false); dragMonitor?.watchDrag()
    }
    func fileDragExited() {
        guard !dragRetentionFrame.contains(NSEvent.mouseLocation) else { return }; endFileDrag(accepted: false)
    }
    func endFileDrag(accepted: Bool = false) {
        guard draggingFiles else { return }
        input.fileDragActive = false; dragMonitor?.stopWatchingDrag()
        if !accepted, let previousDragTab { select(previousDragTab) }
        previousDragTab = nil; refreshPointer()
    }
    private func updateFrame(animated: Bool) {
        guard let panel, let geometry, input.visible else { return }
        let envelope = NotchPresentation.envelope(geometry)
        let relocated = panel.frame != envelope
        // Only a display/geometry change may resize the AppKit window.
        if relocated { surface.stop(); panel.setFrame(envelope, display: true) }
        let target = NotchPresentation.target(geometry, expanded: expanded, tab: tab, notice: notice != nil)
        surface.move(to: target, animated: animated && !relocated && allowsAnimation)
        updateInputTransparency()
    }
    func stop() {
        stopped = true; cancelHover(); input.suspend(); surface.stop(); surface.onStep = nil; dismissNotice()
        dragMonitor?.stop(); pointerMonitor?.stop(); panel?.ignoresMouseEvents = true; panel?.orderOut(nil)
        agenda.stop(); countdown.stop(); shelf.cancelChooser(); shelf.clear()
        model.notchExpanded = false; model.setNotchVisible(false)
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
        trackingMenus.removeAll(); pendingMenuAction = nil; panel = nil
    }
    #if LUMA_QA
    func captureQA(to url: URL) {
        guard let content = panel?.contentView else { return }
        surface.move(to: surface.target, animated: false)
        content.layoutSubtreeIfNeeded()
        guard let image = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: image)
        try? image.representation(using: .png, properties: [:])?.write(to: url)
    }
    var qaWindowFrame: CGRect { panel?.frame ?? .zero }
    var qaIgnoresMouseEvents: Bool { panel?.ignoresMouseEvents ?? true }
    #endif
    var isShown: Bool { panel?.isVisible == true }
    var frame: NSRect { NotchPresentation.frame(surface.state, in: panel?.frame ?? .zero) }
}

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
        let local = convert(point, from: superview)
        guard bounds.contains(local), let window,
              controller?.containsSurface(window.convertPoint(toScreen: convert(local, to: nil))) == true else { return nil }
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
        controller?.acceptsFileDrop == true && controller?.containsSurface(NSEvent.mouseLocation) == true && sender.draggingSourceOperationMask.contains(.copy) && !urls(sender).isEmpty
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }; controller?.beginFileDrag(); return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }; controller?.beginFileDrag(); return .copy
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
