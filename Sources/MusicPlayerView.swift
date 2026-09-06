import SwiftUI

/// A complete player, not a cover beside disconnected controls. On a wide display the
/// optional lyric pane sits alongside; on a narrow display it replaces the cover only.
struct MusicPlayerView: View {
    @Bindable var model: StandbyModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            let metrics = MusicLayoutMetrics(size: geometry.size, lyrics: model.musicShowsLyrics)
            ZStack {
                player(metrics: metrics)
                    .frame(width: metrics.playerWidth)
                    .offset(x: metrics.split ? metrics.playerShift : 0)
                    .animation(model.reduceMotion ? nil : .smooth(duration: 0.32, extraBounce: 0), value: model.musicShowsLyrics)
                if metrics.supportsSidebar {
                    LyricsStage(model: model, compact: metrics.compact)
                        .frame(width: metrics.lyricsWidth)
                        .offset(x: metrics.lyricsShift + (model.musicShowsLyrics ? 0 : 16))
                        .opacity(model.musicShowsLyrics ? 1 : 0)
                        .allowsHitTesting(model.musicShowsLyrics)
                        .accessibilityHidden(!model.musicShowsLyrics)
                        .animation(model.reduceMotion ? nil : .easeInOut(duration: 0.24), value: model.musicShowsLyrics)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
    }
    private func player(metrics: MusicLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.spacing) {
            ZStack {
                AlbumArtwork(model: model)
                    .frame(width: metrics.cover, height: metrics.cover)
                    .clipShape(RoundedRectangle(cornerRadius: metrics.compact ? 20 : 26, style: .continuous))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.08), radius: 14, x: 0, y: 10)
                    .opacity(model.musicShowsLyrics && !metrics.supportsSidebar ? 0 : 1)
                    .allowsHitTesting(!model.musicShowsLyrics || metrics.supportsSidebar)
                    .accessibilityHidden(model.musicShowsLyrics && !metrics.supportsSidebar)
                if !metrics.supportsSidebar {
                    LyricsStage(model: model, compact: metrics.compact)
                        .frame(width: max(0, metrics.playerWidth - 8), height: metrics.cover)
                        .opacity(model.musicShowsLyrics ? 1 : 0)
                        .allowsHitTesting(model.musicShowsLyrics)
                        .accessibilityHidden(!model.musicShowsLyrics)
                }
            }
            .frame(width: metrics.playerWidth, height: metrics.cover)
            .animation(model.reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.musicShowsLyrics)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.hasTrack ? model.track.title : "Sin reproducción")
                        .font(model.contentTypeface.font(size: metrics.compact ? 22 : 27, emphasized: true))
                        .lineLimit(1).minimumScaleFactor(0.72)
                    Text(model.hasTrack ? [model.track.artist, model.track.album].filter { !$0.isEmpty }.joined(separator: " — ") : "Música de este Mac")
                        .font(model.contentTypeface.font(size: metrics.compact ? 14 : 16))
                        .opacity(0.66).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                LyricsVisibilityButton(model: model)
                Menu {
                    Button("Volver a Música") { model.openMusic() }
                    Button("Actualizar canción y sincronización") { model.refreshPlayback() }.disabled(!model.connected)
                    Button("Importar letra LRC…") { model.importLRC() }.disabled(!model.hasTrack)
                    if !model.lyricSource.isEmpty { Text(model.lyricSource) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 16, weight: .medium))
                        .frame(width: 32, height: 34)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Opciones de reproducción")
            }
            if model.hasTrack {
                TrackProgress(model: model, prominent: true)
                playbackControls(compact: metrics.compact)
            } else {
                Button { model.connectMusic(); model.openMusic() } label: {
                    Label("Conectar Música", systemImage: "music.note")
                        .padding(.horizontal, 16).padding(.vertical, 9)
                }.buttonStyle(.glassProminent).frame(maxWidth: .infinity)
            }
        }
    }
    private func playbackControls(compact: Bool) -> some View {
        HStack(spacing: 0) {
            playbackButton("shuffle", label: "Reproducción aleatoria", command: "shuffle", size: 19, selected: model.shuffleEnabled)
                .disabled(!model.playbackOptionsAvailable)
            Spacer(minLength: 18)
            playbackButton("backward.fill", label: "Anterior", command: "previous", size: compact ? 25 : 29)
            Spacer(minLength: 18)
            playbackButton(model.anchor.playing ? "pause.fill" : "play.fill", label: model.anchor.playing ? "Pausar" : "Reproducir", command: "toggle", size: compact ? 32 : 38)
            Spacer(minLength: 18)
            playbackButton("forward.fill", label: "Siguiente", command: "next", size: compact ? 25 : 29)
            Spacer(minLength: 18)
            playbackButton(model.repeatMode == 2 ? "repeat.1" : "repeat", label: ["Repetición desactivada", "Repetir todas", "Repetir una"][model.repeatMode], command: "repeat", size: 19, selected: model.repeatMode > 0)
                .disabled(!model.playbackOptionsAvailable)
        }
        .frame(height: compact ? 42 : 48)
        .disabled(!model.hasTrack)
    }
    private func playbackButton(_ symbol: String, label: String, command: String, size: CGFloat, selected: Bool = false) -> some View {
        Button { model.control(command) } label: {
            Image(systemName: symbol).font(.system(size: size, weight: .regular))
                .frame(width: command == "toggle" ? 58 : 42, height: 44)
                .background(selected ? Color.primary.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 13))
                .opacity((command == "shuffle" || command == "repeat") && !selected ? 0.62 : 1)
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
