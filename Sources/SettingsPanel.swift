// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case typography, appearance, playback, standby, notch, widgets, updates

    var id: Self { self }

    var title: String {
        switch self {
        case .typography: return "Tipografía"
        case .appearance: return "Apariencia"
        case .playback: return "Reproducción"
        case .standby: return "Standby"
        case .notch: return "Notch"
        case .widgets: return "Widgets"
        case .updates: return "Actualizaciones"
        }
    }

    var symbol: String {
        switch self {
        case .typography: return "textformat"
        case .appearance: return "paintpalette"
        case .playback: return "play.circle"
        case .standby: return "moon"
        case .notch: return "menubar.rectangle"
        case .widgets: return "square.grid.2x2"
        case .updates: return "arrow.down.circle"
        }
    }
}

struct SettingsPanel: View {
    @Bindable var model: StandbyModel
    @Environment(\.dismiss) private var dismiss
    @State private var repositoryDraft = OruviUpdates.shared.repository

    var body: some View {
        let screen = model.mainWindow?.screen ?? NSScreen.main
        let size = screen?.visibleFrame.size ?? CGSize(width: 1000, height: 820)
        VStack(spacing: 0) {
            HStack {
                Text("Ajustes").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Listo") { dismiss() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.done")
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.settingsSection.title)
                        .font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
                    if model.settingsSection == .typography {
                        TypographySettings(model: model)
                    } else {
                        Form { sectionBody }
                            .formStyle(.grouped)
                            .id(model.settingsSection)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: min(880, max(520, size.width - 36)), height: min(738, max(390, size.height - 56)))
    }

    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 3) {
                ForEach(SettingsSection.allCases) { section in
                    let selected = section == model.settingsSection
                    Button { model.settingsSection = section } label: {
                        Label(section.title, systemImage: section.symbol)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .labelStyle(.titleAndIcon)
                            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                            .padding(.horizontal, 10)
                            .background(selected ? Color.accentColor.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                    .accessibilityIdentifier("settings.section." + section.rawValue)
                }
            }
            .padding(12)
        }
        .frame(width: 180)
        .background(.primary.opacity(0.035))
    }

    @ViewBuilder private var sectionBody: some View {
        switch model.settingsSection {
        case .typography: EmptyView()
        case .appearance: appearance
        case .playback: playback
        case .standby: standby
        case .notch: notch
        case .widgets: NativeWidgetSettings()
        case .updates:
            UpdatesSettings(draft: $repositoryDraft)
            about
        }
    }

    @ViewBuilder private var appearance: some View {
        Section("Fondo") {
            Picker("Malla predeterminada", selection: $model.meshTheme) {
                ForEach(MeshTheme.allCases) { Text($0.name).tag($0) }
            }
            Toggle("Adaptar los colores a la portada", isOn: $model.meshFollowsMusic)
            Text("Transición de colores al cambiar de canción. No escucha ni graba audio; no es un visualizador de ritmo. Si aún no hay portada, usa una paleta provisional por artista y álbum.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Apariencia", selection: $model.appearance) { ForEach(["Sistema", "Oscuro", "Claro"], id: \.self) { Text($0).tag($0) } }
        }
        Section("Reloj y frases") {
            Toggle("Reloj de 24 horas", isOn: $model.twentyFourHour)
            Toggle("Mostrar frases motivacionales", isOn: $model.showPhrases)
            Picker("Cambiar cada", selection: $model.phraseInterval) {
                Text("15 segundos").tag(15.0)
                Text("30 segundos").tag(30.0)
                Text("1 minuto").tag(60.0)
                Text("2 minutos").tag(120.0)
                Text("5 minutos").tag(300.0)
                Text("10 minutos").tag(600.0)
            }.disabled(!model.showPhrases)
            Text("24 frases originales, sin repetir la anterior. El temporizador se detiene cuando Oruvi está oculta o las frases están apagadas.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var playback: some View {
        Section("Reproducción de Standby") {
            LabeledContent("Reproductor de Standby") {
                PlayerSourcePicker(selection: $model.playerPreference, surface: .standby,
                                   activePlayer: model.hasTrack ? model.activePlayer : nil)
            }
            Text(model.connectionStatus).font(.callout)
            HStack {
                Button(model.connected ? "Reconectar Standby" : "Conectar Standby") { model.connectMusic() }
                Button("Abrir reproductor") { model.openInstalledPlayer() }
                if model.connected || model.demoMode { Button("Desconectar Standby") { model.disconnectMusic() } }
            }
            Text("Requiere permiso de Automatización. La conexión del Notch se activa desde su propio reproductor. No lee contraseñas, no modifica tu biblioteca y no detecta música reproducida únicamente en el iPhone o Apple TV.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Portada y letras automáticas") {
            Toggle("Recuperar portada del catálogo Apple cuando falte", isOn: $model.automaticArtwork)
            Text("Se intenta primero la portada de Música y se reintenta si aún no está lista. Si falta, la búsqueda envía título y artista a Apple. La portada solo se asigna si coinciden la canción, el artista y la duración.")
                .font(.caption).foregroundStyle(.secondary)
            if !model.artworkStatus.isEmpty { caption(model.artworkStatus) }
            if !model.lyricSource.isEmpty { caption(model.lyricSource) }
            Toggle("Buscar letras sincronizadas en LRCLIB", isOn: $model.automaticLyrics)
            Text("LRCLIB recibe el título, artista, álbum, duración y tu IP para buscar una letra sincronizada.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Vaciar caché de letras y portadas") { model.clearLyricsCache() }
            HStack {
                Text("Ajuste de sincronía")
                Slider(value: $model.lyricOffset, in: -2...2, step: 0.05).accessibilityLabel("Ajuste de sincronía")
                Text(String(format: "%+.2f s", model.lyricOffset)).monospacedDigit().frame(width: 65)
            }
            Text("Un valor positivo adelanta la letra. Ajusta también la latencia de Bluetooth o AirPlay; no se puede garantizar desfase cero.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var standby: some View {
        Section("Activación automática") {
            Toggle("Activar después de un tiempo sin actividad", isOn: $model.idleEnabled)
            LabeledContent("Tiempo sin actividad") {
                HStack(spacing: 8) {
                    TextField("Minutos", value: $model.idleMinutes, format: .number.precision(.fractionLength(0)))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing).frame(width: 62)
                        .accessibilityLabel("Minutos sin actividad, de 1 a 120")
                    Text("min").fixedSize().foregroundStyle(.secondary)
                    Stepper("Minutos", value: $model.idleMinutes, in: 1...120, step: 1).labelsHidden()
                }.fixedSize()
            }.disabled(!model.idleEnabled)
            Text("Entre 1 y 120 minutos. Oruvi permanece solo en la barra superior y se abre siempre a pantalla completa en la pantalla donde esté el puntero. Pulsa Esc para volver. No impide que macOS bloquee o duerma la pantalla: elige un tiempo menor que el reposo del sistema.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("No interrumpir contenido") {
            Toggle("Pausar activación durante reproducción", isOn: $model.avoidMedia)
            Toggle("Protección conservadora en navegadores y reproductores", isOn: $model.protectBrowsers).disabled(!model.avoidMedia)
            Text("Comprueba bloqueos de reposo y procesos con salida de audio, sin grabar ni leer pestañas. Música por sí sola no bloquea Oruvi. El modo conservador también espera mientras un navegador o reproductor de vídeo esté al frente, incluso si está pausado: protege vídeos silenciosos que no anuncien su estado.")
                .font(.caption).foregroundStyle(.secondary)
            Text(model.automaticActivationStatus).font(.caption).foregroundStyle(.secondary)
        }
        Section("Energía") {
            Picker("Renderizado", selection: $model.energyMode) { ForEach(EnergyMode.allCases) { Text($0.rawValue).tag($0) } }
            Toggle("Mantener pantalla encendida, solo con corriente", isOn: $model.keepAwake)
            Text("Automático: malla a 24 fps con corriente, estática en batería. Fluido: hasta 30 fps con corriente y 12 en batería. Ahorro, baja energía, calor o Reducir movimiento detienen la malla. Mantener la pantalla encendida consume energía y está desactivado inicialmente.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Estado", value: model.energyLabel)
            LabeledContent("Lectura reciente de Música", value: String(format: "%.0f ms (no es latencia de audio)", model.syncRoundTrip * 1000))
        }
    }

    @ViewBuilder private var notch: some View {
        Section("Notch en el escritorio") {
            Toggle("Abrir Oruvi al iniciar sesión", isOn: Binding(
                get: { LaunchAtLogin.shared.enabled },
                set: { LaunchAtLogin.shared.setEnabled($0) }
            ))
            if !LaunchAtLogin.shared.message.isEmpty {
                Text(LaunchAtLogin.shared.message).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Mostrar notch en el escritorio", isOn: $model.notchEnabled)
            LabeledContent("Reproductor del Notch") {
                PlayerSourcePicker(selection: $model.notchPlayerPreference, surface: .notch, activePlayer: nil)
            }
            Text("El notch sigue su propia selección de reproductor. Acerca el puntero al borde superior de la pantalla para abrirlo.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Codex") { CodexConnectionView(usage: .shared) }
    }

    @ViewBuilder private var about: some View {
        Section("Acerca de esta versión") {
            LabeledContent("Versión", value: "\(OruviRelease.version) · Compilación \(OruviRelease.build)")
            Text("Oruvi · reloj, música y ambiente. Aplicación independiente de Apple, nativa SwiftUI / AppKit, sin navegador integrado ni telemetría. Pantalla completa sin bordes; no sustituye la pantalla de bloqueo. Conserva los ajustes de las versiones anteriores de Luma.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Copyright © 2026 KaizenTrick · Licencia MIT").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}
