import AppKit
import SwiftUI
import Observation
import QuartzCore

final class OruviNotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

struct NotchGeometry {
    let centerX: CGFloat
    let top: CGFloat
    let cameraWidth: CGFloat
    let topInset: CGFloat
    let compactWidth: CGFloat
    @MainActor static func resolve(_ screen: NSScreen) -> NotchGeometry {
        let left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea
        let width = (left != nil && right != nil) ? max(0, right!.minX - left!.maxX) : 0
        let cutout = width > 0 && screen.safeAreaInsets.top > 0
        return NotchGeometry(centerX: cutout ? (left!.maxX + right!.minX) / 2 : screen.frame.midX,
                             top: screen.frame.maxY - (cutout ? 0 : 5), cameraWidth: cutout ? width : 0,
                             topInset: cutout ? screen.safeAreaInsets.top : 30,
                             compactWidth: cutout ? width + 88 : 150)
    }
}

/// Original implementation. No Boring Notch source, private display API or global input capture.
/// One non-activating panel; it never raises the main app, blocks typing or duplicates audio.
@MainActor @Observable
final class NotchController {
    var expanded = false
    var cameraWidth: CGFloat = 0
    var topInset: CGFloat = 30
    var compactWidth: CGFloat = 150
    @ObservationIgnored private let model: StandbyModel
    @ObservationIgnored private var panel: OruviNotchPanel?
    @ObservationIgnored private var geometry: NotchGeometry?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var sessionBlocked = false
    @ObservationIgnored private var presentationHandoff = false

    init(model: StandbyModel) { self.model = model; model.notch = self }
    func start() {
        let p = OruviNotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.hidesOnDeactivate = false; p.isReleasedWhenClosed = false
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isMovable = false; p.isMovableByWindowBackground = false
        p.contentView = FirstClickHostingView(rootView: NotchView(model: model, controller: self))
        p.identifier = NSUserInterfaceItemIdentifier("oruvi.notch")
        p.appearance = NSAppearance(named: .darkAqua)
        panel = p
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.reconcile() }
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
            hoverTask?.cancel(); expanded = false; hovering = false; model.notchExpanded = false
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
        hoverTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: inside ? 140_000_000 : 320_000_000) } catch { return }
            guard !Task.isCancelled, let self, self.hovering == inside, self.model.notchVisible else { return }
            self.setExpanded(inside)
        }
    }
    func collapse() { hoverTask?.cancel(); hovering = false; setExpanded(false) }
    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value; model.notchExpanded = value
        updateFrame(animated: !model.reduceMotion)
    }
    private func updateFrame(animated: Bool) {
        guard let panel, let geometry else { return }
        let width = expanded ? max(392, compactWidth) : compactWidth
        let height = expanded ? topInset + 184 : topInset + 4
        let rect = NSRect(x: geometry.centerX - width / 2, y: geometry.top - height, width: width, height: height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(rect, display: true)
            }
        } else { panel.setFrame(rect, display: true) }
    }
    func stop() {
        stopped = true; hoverTask?.cancel(); panel?.orderOut(nil)
        model.setNotchVisible(false)
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
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

private struct NotchView: View {
    let model: StandbyModel
    let controller: NotchController
    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: controller.expanded ? 26 : 16,
                                   bottomTrailingRadius: controller.expanded ? 26 : 16, topTrailingRadius: 0)
                .fill(.black)
            if controller.expanded { expanded.padding(.top, controller.topInset + 8).padding(.horizontal, 22).transition(.opacity) }
            else { compact.frame(height: controller.topInset).padding(.horizontal, 10).transition(.opacity) }
        }
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .contentShape(Rectangle())
        .onHover { controller.hover($0) }
        .animation(model.reduceMotion ? nil : .easeInOut(duration: 0.16), value: controller.expanded)
    }
    private var compact: some View {
        HStack(spacing: 0) {
            if model.hasTrack {
                AlbumArtwork(model: model).frame(width: 22, height: 22).clipShape(RoundedRectangle(cornerRadius: 5))
            } else { playerButton(size: 18).frame(width: 26, height: 26) }
            Spacer(minLength: max(20, controller.cameraWidth))
            Button { model.showWindow() } label: {
                Image(systemName: model.anchor.playing ? "waveform" : "rectangle.expand.vertical")
                    .font(.system(size: 15, weight: .medium)).frame(width: 26, height: 26)
            }.buttonStyle(.plain).help("Abrir Standby").accessibilityLabel("Abrir Oruvi a pantalla completa")
        }
    }
    private var expanded: some View {
        VStack(spacing: 14) {
            if model.hasTrack {
                HStack(spacing: 14) {
                    AlbumArtwork(model: model).frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.track.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                        Text(model.track.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                        Text(model.activePlayer.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.46))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { controller.collapse(); model.showWindow() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 30, height: 30) }
                        .buttonStyle(.plain).help("Standby").accessibilityLabel("Abrir Standby")
                }
                HStack(spacing: 28) {
                    control("backward.fill", command: "previous", label: "Anterior")
                    control(model.anchor.playing ? "pause.fill" : "play.fill", command: "toggle", label: model.anchor.playing ? "Pausar" : "Reproducir")
                    control("forward.fill", command: "next", label: "Siguiente")
                }.frame(maxWidth: .infinity).padding(.vertical, 6)
            } else { playerButton(size: 30).frame(height: 100).frame(maxWidth: .infinity) }
            HStack {
                Menu {
                    ForEach(PlayerPreference.allCases) { option in
                        Button(option.name) { model.playerPreference = option }
                    }
                } label: { Image(systemName: "hifispeaker").frame(width: 28, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Reproductor")
                Spacer()
                Image(systemName: model.onBattery ? "battery.75percent" : "powerplug")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                Button { controller.collapse(); model.showWindow(); model.settingsOpen = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 24) }
                    .buttonStyle(.plain).accessibilityLabel("Ajustes")
            }
        }
    }
    private func playerButton(size: CGFloat) -> some View {
        Button { controller.collapse(); model.openMusic() } label: { Image(systemName: "music.note").font(.system(size: size, weight: .regular)).frame(minWidth: 28, minHeight: 28) }
            .buttonStyle(.plain).accessibilityLabel("Abrir reproductor")
    }
    private func control(_ symbol: String, command: String, label: String) -> some View {
        Button { model.control(command) } label: { Image(systemName: symbol).font(.system(size: 20, weight: .medium)).frame(width: 44, height: 32) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }
}
