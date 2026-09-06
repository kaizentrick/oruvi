import AppKit
import SwiftUI

struct NotchView: View {
    let model: StandbyModel
    let controller: NotchController
    private var shape: UnevenRoundedRectangle {
        let top: CGFloat = controller.cameraWidth > 0 ? 0 : 12
        let bottom: CGFloat = controller.expanded ? 24 : min(12, controller.topInset / 2)
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                      bottomTrailingRadius: bottom, topTrailingRadius: top)
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                shape.fill(.black)
                if controller.expanded {
                    workspace
                        .frame(height: max(0, geometry.size.height - controller.topInset))
                        .padding(.top, controller.topInset)
                        .transition(.opacity)
                } else {
                    compact.frame(width: geometry.size.width, height: controller.topInset)
                        .transition(.opacity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(shape).contentShape(shape)
        }
        .ignoresSafeArea()
        .foregroundStyle(.white).preferredColorScheme(.dark)
        .onHover { controller.hover($0) }
        .onExitCommand { controller.collapse() }
        .animation(model.reduceMotion ? nil : .easeInOut(duration: 0.16), value: controller.expanded)
    }
    private var compact: some View {
        HStack(spacing: 0) {
            Group {
                if model.hasTrack {
                    AlbumArtwork(model: model)
                        .frame(width: min(22, max(1, controller.topInset - 8)), height: min(22, max(1, controller.topInset - 8)))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else { Color.clear.frame(width: 22, height: 22) }
            }.frame(width: 44)
            Spacer(minLength: 0)
            Group {
                if NotchCompactPolicy.showsMusicIndicator(hasTrack: model.hasTrack, playing: model.anchor.playing) {
                    // State, not a fake audio visualizer or an always-visible Standby button.
                    Image(systemName: "music.note").font(.system(size: 14, weight: .medium))
                        .accessibilityLabel("Música en reproducción")
                } else { Color.clear.frame(width: 18, height: 18).accessibilityHidden(true) }
            }.frame(width: 44)
        }
        .contentShape(Rectangle())
        .onTapGesture { controller.openForKeyboard() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.hasTrack ? "Oruvi. \(model.track.title). Abrir widgets." : "Oruvi. Abrir widgets.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { controller.openForKeyboard() }
        .help("Abrir Oruvi: música, archivos, agenda y temporizador")
    }
    private var workspace: some View {
        VStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(NotchTab.allCases) { option in
                    Button { controller.select(option) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: option.symbol)
                            Text(option.title).lineLimit(1).minimumScaleFactor(0.8)
                        }.font(.system(size: 10, weight: .medium))
                            .frame(maxWidth: .infinity).frame(height: 30)
                            .background(.white.opacity(controller.tab == option ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).help(option.title)
                    .accessibilityLabel(option.title).accessibilityValue(controller.tab == option ? "Seleccionado" : "")
                }
            }.frame(height: 30)
            Group {
                switch controller.tab {
                case .music: music
                case .files: NotchShelfView(shelf: controller.shelf, controller: controller)
                case .agenda: NotchAgendaView(agenda: controller.agenda, controller: controller)
                case .timer: NotchTimerView(countdown: controller.countdown)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer.frame(height: 24)
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 16)
    }
    private var music: some View {
        VStack(spacing: 12) {
            if model.hasTrack {
                HStack(spacing: 14) {
                    AlbumArtwork(model: model).frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.track.title).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                        Text(model.track.artist).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 28) {
                    control("backward.fill", command: "previous", label: "Anterior")
                    control(model.anchor.playing ? "pause.fill" : "play.fill", command: "toggle", label: model.anchor.playing ? "Pausar" : "Reproducir")
                    control("forward.fill", command: "next", label: "Siguiente")
                }.frame(maxWidth: .infinity)
            } else {
                Button { controller.collapse(); model.openMusic() } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "music.note").font(.system(size: 30, weight: .light))
                        Text("Abrir reproductor").font(.system(size: 12))
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Menu {
                ForEach(PlayerPreference.allCases) { option in
                    Button { model.playerPreference = option } label: {
                        if model.playerPreference == option { Label(option.name, systemImage: "checkmark") }
                        else { Text(option.name) }
                    }
                }
            } label: { Label(model.activePlayer.name, systemImage: "hifispeaker").font(.system(size: 10)) }
            .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().help("Elegir Apple Music, Spotify o Automático")
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var footer: some View {
        HStack(spacing: 12) {
            Label(model.onBattery ? "Con batería" : "Con corriente", systemImage: model.onBattery ? "battery.75percent" : "powerplug")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            Spacer(minLength: 4)
            Button { controller.collapse(); model.showWindow() } label: {
                Label("Standby", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 11))
            }.buttonStyle(.plain).help("Abrir Standby a pantalla completa")
            Button { controller.collapse(); model.showWindow(); model.settingsOpen = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 28, height: 24)
            }.buttonStyle(.plain).help("Ajustes").accessibilityLabel("Ajustes de Oruvi")
        }
    }
    private func control(_ symbol: String, command: String, label: String) -> some View {
        Button { model.control(command) } label: {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium)).frame(width: 44, height: 32)
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
