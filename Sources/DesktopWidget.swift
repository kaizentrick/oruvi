// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Observation

/// A live desktop card owned by Oruvi, not a WidgetKit gallery extension.
@MainActor
final class DesktopWidgetController: NSObject, NSWindowDelegate {
    private let model: StandbyModel
    private var panel: NSPanel?
    private var stopped = false
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var revealTimer: Timer?
    private var revealing = false
    private let frameName = "Oruvi.DesktopMusicWidget"
    var isVisible: Bool { panel?.isVisible ?? false }
    var currentFrame: CGRect? { panel?.frame }
    var isInFront: Bool { panel?.level == .floating }

    init(model: StandbyModel) { self.model = model; super.init() }
    func start() {
        guard !started, !stopped, !LumaEnvironment.isTesting else { return }
        started = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeOnScreen(reset: false) }
        })
        observers.append(center.addObserver(forName: .oruviRevealDesktopWidget, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reveal() }
        })
        observe()
        if DesktopWidgetPolicy.consumeIntroduction(defaults: LumaEnvironment.preferences, enabled: model.desktopWidgetEnabled) {
            reveal()
        }
    }
    private func observe() {
        guard !stopped else { return }
        // Track only visibility preferences, not the SwiftUI view's music reads.
        withObservationTracking {
            _ = model.desktopWidgetEnabled
            _ = model.desktopWidgetAlwaysOnTop
            _ = model.isVisible
            _ = model.screenSleeping
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        reconcile()
    }
    func reconcile() {
        guard !stopped else { return }
        guard DesktopWidgetPolicy.visible(enabled: model.desktopWidgetEnabled, standby: model.isVisible, sleeping: model.screenSleeping) else {
            endReveal(); panel?.orderOut(nil); return
        }
        makePanelIfNeeded()
        applyLevel()
        panel?.orderFrontRegardless()
    }
    private func makePanelIfNeeded() {
        guard panel == nil else { return }
        let card = NSPanel(contentRect: CGRect(origin: .zero, size: DesktopWidgetPolicy.size),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        card.isReleasedWhenClosed = false
        card.isRestorable = false
        card.isOpaque = false
        card.backgroundColor = .clear
        card.appearance = nil // Follow macOS, not the full-screen presentation theme.
        card.hasShadow = true
        card.hidesOnDeactivate = false
        card.isMovable = true
        card.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        card.contentView = FirstClickHostingView(rootView: DesktopMusicWidget(model: model))
        panel = card
        // Tests must never touch a real user's window-frame preferences.
        if !LumaEnvironment.isTesting { _ = card.setFrameUsingName(frameName) }
        placeOnScreen(reset: false)
        card.delegate = self
    }
    private func applyLevel() {
        panel?.level = (model.desktopWidgetAlwaysOnTop || revealing) ? .floating :
            NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }
    /// Reveal on the pointer's display, above normal windows briefly, without
    /// activating the app. A separate explicit setting keeps it permanently in front.
    func reveal() {
        guard !stopped, DesktopWidgetPolicy.visible(enabled: model.desktopWidgetEnabled, standby: model.isVisible, sleeping: model.screenSleeping) else { return }
        makePanelIfNeeded(); placeOnScreen(reset: true)
        revealTimer?.invalidate()
        revealing = true
        reconcile()
        let timer = Timer(timeInterval: 8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.endReveal() }
        }
        timer.tolerance = 0.2
        revealTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    func endReveal() {
        revealTimer?.invalidate(); revealTimer = nil
        revealing = false; applyLevel()
    }
    private func placeOnScreen(reset: Bool) {
        guard let panel else { return }
        let target = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let frame = DesktopWidgetPolicy.frame(saved: panel.frame, screens: NSScreen.screens.map(\.visibleFrame),
                                                    preferred: target?.visibleFrame, reset: reset) else { return }
        panel.setFrame(frame, display: true)
        if !LumaEnvironment.isTesting { panel.saveFrame(usingName: frameName) }
    }
    func windowDidMove(_ notification: Notification) {
        if !LumaEnvironment.isTesting { panel?.saveFrame(usingName: frameName) }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; endReveal()
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        panel?.delegate = nil; panel?.orderOut(nil); panel?.close(); panel = nil
    }
}

/// An explicit drag-only region avoids the shared first-click host's deliberate
/// mouseDownCanMoveWindow=false and never turns a music-button click into a drag.
private struct DesktopWidgetDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> Handle {
        let view = Handle()
        view.toolTip = "Arrastrar widget"
        view.setAccessibilityLabel("Arrastrar widget de escritorio")
        return view
    }
    func updateNSView(_ nsView: Handle, context: Context) {}
    final class Handle: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}

private struct DesktopMusicWidget: View {
    @Bindable var model: StandbyModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                PlayerSourcePicker(selection: $model.notchPlayerPreference, surface: .notch,
                                   activePlayer: model.hasTrack ? model.activePlayer : nil)
                    .controlSize(.small)
                Spacer(minLength: 0)
                Image(systemName: "line.3.horizontal").font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 28).overlay { DesktopWidgetDragHandle() }
                    .help("Arrastrar widget")
                Button { model.showWindow() } label: {
                    Image(systemName: "rectangle.inset.filled").frame(width: 28, height: 28)
                }.buttonStyle(.plain).help("Abrir Standby")
                    .accessibilityLabel("Abrir Standby a pantalla completa")
                Button { model.desktopWidgetEnabled = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 24, height: 28)
                }.buttonStyle(.plain).help("Ocultar widget; vuelve a mostrarlo desde el menú de Oruvi")
                    .accessibilityLabel("Ocultar widget de escritorio")
            }
            HStack(spacing: 14) {
                AlbumArtwork(model: model).frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                    .disabled(!model.hasTrack)
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.hasTrack ? model.track.title : "Nada en reproducción")
                        .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(model.hasTrack ? (model.track.artist.isEmpty ? model.activePlayer.name : model.track.artist) : "Reproduce contenido en tu Mac")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if !model.connected {
                        Button("Conectar controles") { model.connectMusic() }
                            .font(.system(size: 12)).buttonStyle(.plain)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 19) {
                Button { model.desktopWidgetAlwaysOnTop.toggle() } label: {
                    Image(systemName: model.desktopWidgetAlwaysOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 12)).frame(width: 28, height: 32)
                }.buttonStyle(.plain)
                    .help(model.desktopWidgetAlwaysOnTop ? "Volver al escritorio" : "Mantener widget al frente")
                    .accessibilityLabel("Mantener widget al frente")
                    .accessibilityValue(model.desktopWidgetAlwaysOnTop ? "Activado" : "Desactivado")
                Spacer(minLength: 0)
                transport("backward.end.fill", "Anterior", "previous")
                transport(model.anchor.playing ? "pause.fill" : "play.fill", model.anchor.playing ? "Pausar" : "Reproducir", "toggle")
                transport("forward.end.fill", "Siguiente", "next")
                Spacer(minLength: 0)
                Color.clear.frame(width: 28, height: 32).accessibilityHidden(true)
            }.font(.system(size: 17, weight: .medium))
        }
        .padding(18)
        .frame(width: DesktopWidgetPolicy.size.width, height: DesktopWidgetPolicy.size.height)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(model.reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
        }
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .contextMenu {
            Button("Mostrar aquí y recuperar posición") { model.revealDesktopWidget() }
            Toggle("Mantener al frente", isOn: $model.desktopWidgetAlwaysOnTop)
            Divider()
            Button("Ocultar widget") { model.desktopWidgetEnabled = false }
        }
    }
    private func transport(_ symbol: String, _ label: String, _ command: String) -> some View {
        Button { model.control(command) } label: { Image(systemName: symbol).frame(width: 32, height: 32) }
            .buttonStyle(.plain).disabled(!model.connected || !model.hasTrack)
            .help(label).accessibilityLabel(label)
    }
}
