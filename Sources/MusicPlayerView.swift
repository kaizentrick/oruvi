import SwiftUI

struct EmptyPlayerButton: View {
    let model: StandbyModel
    var body: some View {
        Button { model.openInstalledPlayer() } label: {
            Image(systemName: "music.note").font(.system(size: 23, weight: .medium)).frame(width: 58, height: 58)
        }
        .buttonStyle(.plain).lumaGlass(model: model, radius: 30)
        .help("Abrir " + (model.playerPreference.source ?? model.activePlayer).name)
        .accessibilityLabel("Abrir reproductor de música")
    }
}

/// A stable player layer: missing or loading lyrics never reserve an empty sidebar.
struct MusicPlayerView: View {
    @Bindable var model: StandbyModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            if model.hasTrack {
                let metrics = MusicLayoutMetrics(size: geometry.size, lyrics: model.visibleLyrics)
                ZStack {
                    player(metrics: metrics)
                        .frame(width: metrics.playerWidth)
                        .offset(x: metrics.split ? metrics.playerShift : 0)
                        .animation(model.reduceMotion ? nil : .smooth(duration: 0.32, extraBounce: 0), value: model.visibleLyrics)
                    if metrics.supportsSidebar {
                        LyricsStage(model: model, compact: metrics.compact)
                            .frame(width: metrics.lyricsWidth)
                            .offset(x: metrics.lyricsShift + (model.visibleLyrics ? 0 : 14))
                            .opacity(model.visibleLyrics ? 1 : 0)
                            .allowsHitTesting(model.visibleLyrics).accessibilityHidden(!model.visibleLyrics)
                            .animation(model.reduceMotion ? nil : .easeInOut(duration: 0.24), value: model.visibleLyrics)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 18) {
                    EmptyPlayerButton(model: model)
                    PlayerSourcePicker(selection: $model.playerPreference, surface: .standby, activePlayer: nil)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
        .onAppear { InstalledPlayers.shared.refresh() }
    }
    private func player(metrics: MusicLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing) {
            ZStack {
                AlbumArtwork(model: model)
                    .frame(width: metrics.cover, height: metrics.cover)
                    .clipShape(RoundedRectangle(cornerRadius: metrics.compact ? 20 : 26, style: .continuous))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.08), radius: 14, x: 0, y: 10)
                    .opacity(model.visibleLyrics && !metrics.supportsSidebar ? 0 : 1)
                    .allowsHitTesting(!model.visibleLyrics || metrics.supportsSidebar)
                    .accessibilityHidden(model.visibleLyrics && !metrics.supportsSidebar)
                if !metrics.supportsSidebar {
                    LyricsStage(model: model, compact: metrics.compact)
                        .frame(width: max(0, metrics.playerWidth - 8), height: metrics.cover)
                        .opacity(model.visibleLyrics ? 1 : 0)
                        .allowsHitTesting(model.visibleLyrics).accessibilityHidden(!model.visibleLyrics)
                }
            }
            .frame(width: metrics.playerWidth, height: metrics.cover)
            .animation(model.reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.visibleLyrics)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.track.title).font(model.contentTypeface.font(size: metrics.compact ? 22 : 27, emphasized: true))
                        .lineLimit(1).minimumScaleFactor(0.72)
                    Text([model.track.artist, model.track.album].filter { !$0.isEmpty }.joined(separator: " — "))
                        .font(model.contentTypeface.font(size: metrics.compact ? 14 : 16)).opacity(0.66).lineLimit(2)
                    PlayerSourcePicker(selection: $model.playerPreference, surface: .standby, activePlayer: model.activePlayer)
                        .opacity(0.7)
                }.frame(maxWidth: .infinity, alignment: .leading)
                LyricsVisibilityButton(model: model)
                Menu {
                    Button("Volver a " + model.activePlayer.name) { model.openMusic() }
                    Menu("Reproductor de Standby") {
                        PlayerSourceMenuItems(selection: $model.playerPreference, surface: .standby, activePlayer: model.activePlayer)
                    }
                    Button("Actualizar sincronización") { model.refreshPlayback() }.disabled(!model.connected)
                    Button("Importar letra LRC…") { model.importLRC() }
                    if !model.lyricSource.isEmpty { Text(model.lyricSource) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 16, weight: .medium)).frame(width: 32, height: 34) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Opciones de reproducción")
            }
            TrackProgress(model: model, prominent: true)
            playbackControls(compact: metrics.compact)
        }
    }
    private func playbackControls(compact: Bool) -> some View {
        HStack(spacing: 0) {
            playbackButton("shuffle", label: "Reproducción aleatoria", command: "shuffle", size: 19, selected: model.shuffleEnabled).disabled(!model.playbackOptionsAvailable)
            Spacer(minLength: 18)
            playbackButton("backward.fill", label: "Anterior", command: "previous", size: compact ? 25 : 29)
            Spacer(minLength: 18)
            playbackButton(model.anchor.playing ? "pause.fill" : "play.fill", label: model.anchor.playing ? "Pausar" : "Reproducir", command: "toggle", size: compact ? 32 : 38)
            Spacer(minLength: 18)
            playbackButton("forward.fill", label: "Siguiente", command: "next", size: compact ? 25 : 29)
            Spacer(minLength: 18)
            playbackButton(model.repeatMode == 2 ? "repeat.1" : "repeat", label: ["Repetición desactivada", "Repetir todas", "Repetir una"][model.repeatMode], command: "repeat", size: 19, selected: model.repeatMode > 0).disabled(!model.playbackOptionsAvailable)
        }.frame(height: compact ? 42 : 48)
    }
    private func playbackButton(_ symbol: String, label: String, command: String, size: CGFloat, selected: Bool = false) -> some View {
        Button { model.control(command) } label: {
            Image(systemName: symbol).font(.system(size: size, weight: .regular))
                .frame(width: command == "toggle" ? 58 : 42, height: 44)
                .background(selected ? Color.primary.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 13))
                .opacity((command == "shuffle" || command == "repeat") && !selected ? 0.62 : 1)
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
