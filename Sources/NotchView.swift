// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

struct NotchView: View {
    @Bindable var model: StandbyModel
    @Bindable var controller: NotchController
    @Bindable private var usage = CodexUsageController.shared
    var body: some View {
        GeometryReader { geometry in
            let state = controller.surface.state
            let shape = NotchSurfaceShape(flare: state.flare, radius: state.radius)
            let expandedWidth = min(max(360, controller.compactWidth), max(1, geometry.size.width - NotchPresentation.shadowMargin * 2))
            let expandedHeight = min(controller.tab.contentHeight + (controller.notice == nil ? 0 : NotchPresentation.noticeHeight),
                                     max(0, geometry.size.height - controller.topInset - NotchPresentation.shadowMargin))
            ZStack(alignment: .top) {
                shape.fill(.black)
                    .shadow(color: .black.opacity(Double(state.expansion) * 0.22), radius: 6, y: 3)
                ZStack(alignment: .top) {
                    if controller.expanded || state.expansion > 0 {
                        workspace.frame(width: max(1, expandedWidth - state.flare * 2), height: expandedHeight)
                            .padding(.top, controller.topInset)
                            .opacity(Double(state.expansion))
                            .allowsHitTesting(controller.expanded && state.expansion > 0.95)
                            .accessibilityHidden(!controller.expanded)
                    }
                    VStack(spacing: 0) {
                        compact.frame(height: controller.topInset)
                        if let notice = controller.notice {
                            noticeRow(notice).padding(.horizontal, 14).frame(height: NotchPresentation.noticeHeight)
                        }
                    }.frame(width: max(1, state.width - state.flare * 2))
                        .opacity(Double(1 - state.expansion))
                        .allowsHitTesting(!controller.expanded)
                        .accessibilityHidden(controller.expanded)
                }.frame(width: state.width, height: state.height, alignment: .top).clipShape(shape)
            }.frame(width: state.width, height: state.height, alignment: .top)
                .contentShape(shape)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .ignoresSafeArea().foregroundStyle(.white).preferredColorScheme(.dark)
        .onExitCommand { controller.collapse() }
        // Surface geometry is animated once by NotchSurfaceAnimator. Do not add
        // another implicit size animation: the input outline must use the same sample.
    }
    private var compactMode: NotchCompactMode {
        NotchCompactPolicy.resolve(
            tab: controller.tab,
            musicActive: NotchCompactPolicy.showsMusicIndicator(hasTrack: model.hasTrack, playing: model.playbackIsPlaying),
            timerActive: controller.countdown.state.running,
            codexActive: usage.enabled && usage.pinned
        )
    }
    @ViewBuilder private var compact: some View {
        let mode = compactMode
        if mode == .timer && !controller.expanded {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                compactRow(mode, timerText: controller.countdown.text)
            }
        } else {
            compactRow(mode, timerText: mode == .timer ? controller.countdown.text : "")
        }
    }
    private func compactRow(_ mode: NotchCompactMode, timerText: String) -> some View {
        HStack(spacing: 0) {
            Group {
                switch mode {
                case .codex:
                    CodexVectorIcon(size: 14).foregroundStyle(.white.opacity(0.92))
                case .music:
                    AlbumArtwork(model: model)
                        .frame(width: min(22, max(1, controller.topInset - 8)), height: min(22, max(1, controller.topInset - 8)))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                case .timer:
                    Image(systemName: "timer").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                case .none:
                    Color.clear.frame(width: 22, height: 22)
                }
            }.frame(width: 44)
            Spacer(minLength: 0)
            Group {
                switch mode {
                case .codex:
                    Text(usage.compactText).font(.system(size: 11, weight: .medium)).monospacedDigit()
                case .timer:
                    Text(timerText).font(.system(size: 10, weight: .semibold, design: .rounded)).monospacedDigit()
                case .music:
                    Image(systemName: "music.note").font(.system(size: 14, weight: .medium))
                case .none:
                    Color.clear.frame(width: 18, height: 18)
                }
            }.frame(width: 44)
        }.contentShape(Rectangle()).onTapGesture { openCompact() }
            .help(compactHelp(mode, timerText: timerText))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(compactAccessibilityLabel(mode))
            .accessibilityValue(mode == .timer ? timerText : "")
            .accessibilityAddTraits(.isButton).accessibilityAction { openCompact() }
    }
    private func compactHelp(_ mode: NotchCompactMode, timerText: String) -> String {
        switch mode {
        case .codex: return usage.compactHelp
        case .timer: return "Temporizador · \(timerText)"
        case .music: return "\(model.track.title) · \(model.track.artist)"
        case .none: return "Abrir Oruvi"
        }
    }
    private func compactAccessibilityLabel(_ mode: NotchCompactMode) -> String {
        switch mode {
        case .codex: return usage.compactHelp
        case .timer: return "Oruvi. Temporizador. Abrir widgets."
        case .music: return "Oruvi. \(model.track.title). Abrir widgets."
        case .none: return "Oruvi. Abrir widgets."
        }
    }
    private func openCompact() {
        switch compactMode {
        case .codex: controller.select(.connections)
        case .timer: controller.select(.timer)
        case .music: controller.select(.music)
        case .none: break
        }
        controller.openForKeyboard()
    }
    private func noticeRow(_ notice: NotchNotice) -> some View {
        HStack(spacing: 6) {
            Button { controller.openNotice() } label: {
                Label(notice.title, systemImage: notice.symbol).font(.system(size: 11, weight: .medium))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help(notice.title).accessibilityLabel(notice.title)
            Button { controller.dismissNotice() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .medium)).frame(width: 24, height: 24)
            }.buttonStyle(.plain).help("Descartar aviso").accessibilityLabel("Descartar aviso")
        }
    }
    private var workspace: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(NotchTab.allCases) { option in
                    Button { controller.select(option) } label: {
                        Image(systemName: option.symbol).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(controller.tab == option ? 1 : 0.55))
                            .frame(width: 40, height: 32)
                            .background(.white.opacity(controller.tab == option ? 0.12 : 0), in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).help(option.title).accessibilityLabel(option.title)
                        .accessibilityValue(controller.tab == option ? "Seleccionado" : "")
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Abrir Standby") { controller.afterMenu { model.showWindow() } }
                    Button("Widgets de macOS…") { controller.afterMenu { model.showNativeWidgetSettings() } }
                    Button("Ajustes…") { controller.afterMenu { model.showWindow(); model.settingsOpen = true } }
                    Divider()
                    Menu("Personalizar notch") {
                        Toggle("Respuesta háptica", isOn: $controller.hapticsEnabled)
                        Toggle("Avisos breves", isOn: $controller.noticesEnabled)
                        Menu("Pantalla del notch") {
                            displayOption("Automática · preferir cámara", id: "automatic")
                            ForEach(controller.displayChoices) { option in
                                displayOption(option.name, id: option.id)
                            }
                            if controller.selectedDisplayID != "automatic" && !controller.displayChoices.contains(where: { $0.id == controller.selectedDisplayID }) {
                                Text("Pantalla guardada no disponible · usando alternativa")
                            }
                        }
                    }
                    Button("Guía del notch…") { controller.afterMenu { controller.showGuide() } }
                    Divider()
                    Button("Cerrar panel") { controller.afterMenu { controller.collapse() } }
                } label: { Image(systemName: "ellipsis").font(.system(size: 15)).frame(width: 32, height: 32) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Standby, widgets, personalización y ajustes").accessibilityLabel("Más opciones del notch")
            }.frame(height: 32)
            Group {
                switch controller.tab {
                case .music: music
                case .files: NotchShelfView(shelf: controller.shelf, controller: controller)
                case .agenda: NotchAgendaView(agenda: controller.agenda, controller: controller)
                case .timer: NotchTimerView(countdown: controller.countdown)
                case .connections: NotchConnectionsView(model: model, controller: controller)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if controller.draggingFiles {
                        RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.96))
                            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])) }
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "tray.and.arrow.down").font(.system(size: 25, weight: .light))
                                    Text(controller.shelf.isFull ? "Bandeja llena" : "Suelta para añadir")
                                        .font(.system(size: 13, weight: .medium))
                                }
                            }.allowsHitTesting(false)
                    }
                }
            if let notice = controller.notice { noticeRow(notice).frame(height: 22) }
        }.padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 12)
    }
    private func displayOption(_ title: String, id: String) -> some View {
        Button {
            controller.afterMenu { controller.chooseDisplay(id) }
        } label: {
            if controller.selectedDisplayID == id { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }
    private var music: some View {
        VStack(spacing: 6) {
            HStack(spacing: 12) {
                if model.hasTrack {
                    AlbumArtwork(model: model).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "music.note").font(.system(size: 21, weight: .light))
                        .frame(width: 44, height: 44).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.hasTrack ? model.track.title : (model.connected ? "Nada en reproducción" : "Conecta tu música"))
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .help(model.hasTrack ? model.track.title : model.connectionStatus)
                    if let message = model.toastMessage {
                        Text(message).font(.system(size: 11)).foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1).help(message)
                    } else {
                        Text(model.hasTrack ? model.track.artist : (model.connected ? model.connectionStatus : "Ahora suena · Music · Spotify"))
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                    }
                    if let lyric = model.currentLyricText {
                        Text("♪ " + lyric)
                            .font(LyricTypography.font(model.lyricTypeface, baseSize: 10, sizePercent: model.lyricSizePercent)
                                .weight(.medium).italic())
                            .foregroundStyle(.white.opacity(0.82)).lineLimit(1)
                            .contentTransition(.opacity)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 46)
            if model.hasTrack && model.anchor.duration > 0 {
                NotchTrackProgress(model: model, active: controller.expanded && controller.tab == .music)
                    .frame(height: 16)
            }
            HStack(spacing: 6) {
                PlayerSourcePicker(selection: $model.notchPlayerPreference, surface: .notch,
                                   activePlayer: model.hasTrack ? model.activePlayer : nil)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 8)
                if model.hasTrack {
                    control("backward.fill", command: "previous", label: "Anterior").disabled(!model.canSkip)
                    control(model.playbackIsPlaying ? "pause.fill" : "play.fill", command: "toggle", label: model.playbackIsPlaying ? "Pausar" : "Reproducir")
                    control("forward.fill", command: "next", label: "Siguiente").disabled(!model.canSkip)
                } else if !model.connected {
                    Button("Conectar") { model.connectMusic() }.font(.system(size: 11, weight: .medium)).buttonStyle(.plain)
                } else {
                    Button("Abrir reproductor") { model.openInstalledPlayer() }.font(.system(size: 11)).buttonStyle(.plain)
                }
            }.frame(height: 30)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func control(_ symbol: String, command: String, label: String) -> some View {
        Button { model.control(command) } label: {
            Image(systemName: symbol).font(.system(size: command == "toggle" ? 18 : 16, weight: .medium)).frame(width: 30, height: 30)
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

private struct NotchTrackProgress: View {
    let model: StandbyModel
    let active: Bool
    @State private var scrub = PlaybackScrub.idle
    var body: some View {
        Group {
            if model.playbackIsPlaying && active && !model.isResynchronizing {
                let interval = model.anchor.duration > 0 && !model.onBattery ? 0.5 : 1.0
                TimelineView(.periodic(from: .now, by: interval)) { _ in bar }
            } else { bar }
        }
    }
    private var bar: some View {
        let position = model.anchor.value(at: ProcessInfo.processInfo.systemUptime)
        let duration = model.anchor.duration
        let hasDuration = duration > 0
        let shown = model.canSeek ? (scrub.preview(on: model.track).map { $0 * duration } ?? position) : position
        return HStack(spacing: 8) {
            Text(PlaybackTime.format(shown)).fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 28, alignment: .leading)
            if hasDuration {
                PlaybackScrubber(model: model, position: position, thickness: 3,
                                 trackColor: .white.opacity(0.16), fillColor: .white.opacity(0.82), scrub: $scrub)
                    .frame(height: 12)
                Text("−" + PlaybackTime.format(duration - shown)).fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 34, alignment: .trailing)
            } else {
                Spacer(minLength: 0)
            }
        }.font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.5))
    }
}
