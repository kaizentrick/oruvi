import SwiftUI

/// OFF is genuinely transparent; hover is transient; ON has a solid contrasting surface.
/// The state denotes whether the pane is visible, not whether lyrics exist for this recording.
struct LyricsVisibilityButton: View {
    let model: StandbyModel
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    var body: some View {
        let selected = model.musicShowsLyrics
        let foreground: Color = selected ? (scheme == .dark ? .black : .white) : (scheme == .dark ? .white : .black)
        Button { model.musicShowsLyrics.toggle() } label: {
            Image(systemName: "text.quote")
                .font(.system(size: 16, weight: selected ? .semibold : .regular))
                .foregroundStyle(foreground.opacity(selected ? 1 : 0.72))
                .frame(width: 36, height: 36)
                .background {
                    Circle().fill(selected ? Color.primary.opacity(0.92) : Color.primary.opacity(hovering ? 0.09 : 0))
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.hasTrack)
        .onHover { hovering = $0 }
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .accessibilityIdentifier("player.lyrics")
        .accessibilityLabel("Letras")
        .accessibilityValue(selected ? "Activadas" : "Desactivadas")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(selected ? "Ocultar letras" : "Mostrar letras")
    }
}
