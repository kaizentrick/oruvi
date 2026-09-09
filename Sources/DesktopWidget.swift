// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Observation

/// An Oruvi-owned desktop card, deliberately not advertised as a WidgetKit
/// gallery extension. Its live controls reuse the notch sampler and preference.
@MainActor
final class DesktopWidgetController: NSObject, NSWindowDelegate {
    private let model: StandbyModel
    private var panel: NSPanel?
    private var stopped = false
    private var displayObserver: NSObjectProtocol?
    init(model: StandbyModel) {
        self.model = model
        super.init()
    }
    func start() {
        guard !LumaEnvironment.isTesting else { return }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeOnScreen() }
        }
        observe()
    }
    private func observe() {
        guard !stopped else { return }
        withObservationTracking {
            let visible = model.desktopWidgetEnabled && !model.isVisible && !model.screenSleeping
            if visible { show() } else { panel?.orderOut(nil) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }
    private func show() {
        if panel == nil {
            let card = NSPanel(contentRect: NSRect(x: 36, y: 100, width: 344, height: 190),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            card.isReleasedWhenClosed = false
            card.isRestorable = false
            card.isOpaque = false
            card.backgroundColor = .clear
            card.hasShadow = true
            card.hidesOnDeactivate = false
            card.isMovableByWindowBackground = true
            card.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            card.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            card.delegate = self
            card.contentView = FirstClickHostingView(rootView: DesktopMusicWidget(model: model))
            // Frame autosave includes only the position/size, never music metadata.
            _ = card.setFrameAutosaveName("Oruvi.DesktopMusicWidget")
            _ = card.setFrameUsingName("Oruvi.DesktopMusicWidget")
            panel = card
            placeOnScreen()
        }
        panel?.orderFrontRegardless()
    }
    private func placeOnScreen() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(panel.frame) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let x = min(max(panel.frame.minX, area.minX + 12), max(area.minX + 12, area.maxX - 356))
        let y = min(max(panel.frame.minY, area.minY + 12), max(area.minY + 12, area.maxY - 202))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    func windowDidMove(_ notification: Notification) { panel?.saveFrame(usingName: "Oruvi.DesktopMusicWidget") }
    func stop() {
        stopped = true
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
        panel?.orderOut(nil); panel?.close(); panel = nil
    }
}

private struct DesktopMusicWidget: View {
    @Bindable var model: StandbyModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PlayerSourcePicker(selection: $model.notchPlayerPreference, surface: .notch,
                                   activePlayer: model.hasTrack ? model.activePlayer : nil)
                    .controlSize(.small)
                Spacer(minLength: 8)
                Button { model.showWindow() } label: {
                    Image(systemName: "rectangle.inset.filled").frame(width: 27, height: 27)
                }
                .buttonStyle(.plain).help("Abrir StandBy")
                .accessibilityLabel("Abrir StandBy a pantalla completa")
                Button { model.desktopWidgetEnabled = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).frame(width: 22, height: 27)
                }
                .buttonStyle(.plain).help("Ocultar widget de escritorio")
                .accessibilityLabel("Ocultar widget de escritorio")
            }
            HStack(spacing: 14) {
                Group {
                    if let image = model.artwork {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 13).fill(.primary.opacity(0.06))
                            Image(systemName: model.activePlayer.symbol).font(.system(size: 27, weight: .light)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .accessibilityLabel(model.hasTrack ? "Portada de " + model.track.title : "Sin portada")
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.hasTrack ? model.track.title : "Nada en reproducción")
                        .font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text(model.hasTrack ? (model.track.artist.isEmpty ? model.activePlayer.name : model.track.artist) : "Reproduce contenido en tu Mac")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    if !model.connected {
                        Button("Conectar controles") { model.connectMusic() }.font(.system(size: 12))
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 25) {
                Spacer()
                transport("backward.end.fill", "Anterior", "previous")
                transport(model.anchor.playing ? "pause.fill" : "play.fill", model.anchor.playing ? "Pausar" : "Reproducir", "toggle")
                transport("forward.end.fill", "Siguiente", "next")
                Spacer()
            }
            .font(.system(size: 17, weight: .medium))
        }
        .padding(18)
        .frame(width: 344, height: 190)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(model.reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)) : AnyShapeStyle(.regularMaterial))
        }
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        // The desktop card follows macOS light/dark mode, independently of StandBy.
    }
    private func transport(_ symbol: String, _ label: String, _ command: String) -> some View {
        Button { model.control(command) } label: { Image(systemName: symbol).frame(width: 36, height: 26) }
            .buttonStyle(.plain).disabled(!model.connected || !model.hasTrack)
            .help(label).accessibilityLabel(label)
    }
}
