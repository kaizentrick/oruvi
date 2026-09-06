import SwiftUI
import AppKit

// The lifecycle lives in OruviApplication.swift; this file contains views only.
// There is no SwiftUI Settings scene that macOS could restore on launch.
struct StandbyHost: View {
    let model: StandbyModel
    var body: some View { StandbyView(model: model).preferredColorScheme(model.preferredScheme) }
}

struct StandbyView: View {
    @Bindable var model: StandbyModel
    var snapshot = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            let inset = min(64.0, max(28.0, geometry.size.width * 0.046))
            let compact = geometry.size.height < 710
            ZStack {
                FluidMesh(palette: model.meshPalette, fps: snapshot ? 0 : model.policy.framesPerSecond, light: scheme == .light)
                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: compact ? 12 : 26)
                    ZStack {
                        display(size: geometry.size, inset: inset, compact: compact)
                            .id(model.layout)
                            .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .animation(model.reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.layout)
                }
                .padding(.horizontal, inset)
                .padding(.top, max(compact ? 18 : 26, (model.mainWindow?.screen?.safeAreaInsets.top ?? 0) + 12))
                .padding(.bottom, compact ? 22 : 38)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 480, minHeight: 380)
        .ignoresSafeArea(.container, edges: .all)
        .background { if !snapshot { WindowAccessor(model: model).frame(width: 1, height: 1).allowsHitTesting(false) } }
        .sheet(isPresented: $model.settingsOpen) { SettingsPanel(model: model) }
    }
    private func display(size: CGSize, inset: CGFloat, compact: Bool) -> some View {
        VStack(spacing: compact ? 12 : 24) {
            if model.layout == .listening {
                MusicPlayerView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.layout == .clock {
                EditorialClock(model: model, large: true, compact: compact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.hasTrack { compactTrack }
            } else {
                HStack(alignment: .center, spacing: min(70, size.width * 0.05)) {
                    EditorialClock(model: model, compact: compact)
                        .frame(width: (size.width - inset * 2) * 0.43)
                    VStack(alignment: .leading, spacing: compact ? 16 : 26) {
                        TrackHeading(model: model, compact: compact)
                        LyricsStage(model: model, compact: compact)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }.frame(maxWidth: 1240, maxHeight: .infinity)
            }
            if model.layout != .listening {
                if model.hasTrack { TransportBar(model: model).frame(maxWidth: 500) }
                else { connectBar }
            }
        }
    }
    private var topBar: some View {
        HStack(spacing: 10) {
            Spacer()
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    LayoutSelector(model: model).padding(3)
                        .lumaGlass(model: model, radius: 22)
                    GlassIconButton(model: model, symbol: "slider.horizontal.3", label: "Ajustes", identifier: "toolbar.settings") { model.settingsOpen = true }
                    GlassIconButton(model: model, symbol: "xmark", label: "Ocultar (Esc)", identifier: "toolbar.close") { model.dismissStandby() }
                }
            }
        }
    }
    private var connectBar: some View {
        HStack(spacing: 14) {
            Button { model.connectMusic(); model.openMusic() } label: {
                Label("Conectar Música", systemImage: "music.note")
                    .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 8)
            }.buttonStyle(.glassProminent)
            Button("Ver demostración") { model.useDemo() }.buttonStyle(.plain).font(.system(size: 12)).opacity(0.6)
        }
    }
    private var compactTrack: some View {
        HStack(spacing: 14) {
            AlbumArtwork(model: model).frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(model.track.title).font(model.contentTypeface.font(size: 15, emphasized: true)).lineLimit(1)
                    .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                Text(model.track.artist).font(model.contentTypeface.font(size: 12)).opacity(0.6).lineLimit(1)
                    .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            }
        }.padding(14).frame(maxWidth: 330, alignment: .leading).lumaGlass(model: model, radius: 25)
    }
}

private struct FluidMesh: View {
    let palette: [RGB]
    let fps: Double
    let light: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: fps > 0 ? 1 / fps : 1, paused: fps == 0)) { context in
            let t = fps > 0 ? context.date.timeIntervalSinceReferenceDate * 0.12 : 0.65
            let points: [SIMD2<Float>] = [
                [0, 0], [Float(0.50 + 0.12 * sin(t)), 0], [1, 0],
                [0, Float(0.50 + 0.16 * cos(t * 0.83))],
                [Float(0.48 + 0.18 * sin(t * 0.73)), Float(0.50 + 0.17 * cos(t * 0.64))],
                [1, Float(0.50 + 0.15 * sin(t * 0.58))],
                [0, 1], [Float(0.50 + 0.12 * cos(t * 0.79)), 1], [1, 1]
            ]
            let colors = palette.count >= 4 ? palette : RGB.dusk
            MeshGradient(width: 3, height: 3, points: points,
                         colors: [colors[0].color, colors[1].color, colors[0].color, colors[3].color, colors[2].color, colors[1].color, colors[0].color, colors[3].color, colors[0].color], smoothsColors: true)
                .overlay(light ? Color.white.opacity(0.72) : Color.black.opacity(0.42))
                .overlay(LinearGradient(colors: [.black.opacity(light ? 0 : 0.10), .clear, .black.opacity(light ? 0.04 : 0.30)], startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

private struct EditorialClock: View {
    let model: StandbyModel
    var large = false
    var compact = false
    var body: some View {
        Group {
            if model.policy.visible { TimelineView(.periodic(from: Date().startOfMinute, by: 60)) { context in face(context.date) } }
            else { face(Date()) }
        }
    }
    private func face(_ date: Date) -> some View {
        VStack(alignment: large ? .center : .leading, spacing: compact ? 10 : 16) {
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "es_MX"))).uppercased())
                .font(.system(size: large ? 17 : 12, weight: .medium)).tracking(2.5).opacity(0.65)
                .lineLimit(2).padding(.horizontal, large ? 0 : 12)
            EditorialTime(text: model.qaClockText ?? Self.format(date, twentyFour: model.twentyFourHour),
                          maximumSize: large ? (compact ? 205 : 290) : (compact ? 155 : 185), centered: large, typeface: model.clockTypeface, weight: model.clockWeight)
                .frame(height: large ? (compact ? 195 : 310) : (compact ? 155 : 215))
            if !model.twentyFourHour {
                Text(Calendar.current.component(.hour, from: date) >= 12 ? "P. M." : "A. M.")
                    .font(.system(size: 12, weight: .medium)).tracking(3).opacity(0.6)
            }
            if model.showPhrases {
                HStack(spacing: 12) {
                    Rectangle().frame(width: 24, height: 1).opacity(0.35)
                    Text(model.currentPhrase)
                        .font(model.contentTypeface.font(size: large ? 18 : 14)).italic()
                        .opacity(0.62).lineLimit(2).multilineTextAlignment(large ? .center : .leading)
                        .id(model.phraseIndex).transition(.opacity)
                }
                .padding(.horizontal, 12).frame(maxWidth: large ? 660 : .infinity, minHeight: 46, alignment: large ? .center : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: large ? .center : .leading)
    }
    private static let hour24: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = .autoupdatingCurrent; return f }()
    private static let hour12: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm"; f.timeZone = .autoupdatingCurrent; return f }()
    private static func format(_ date: Date, twentyFour: Bool) -> String { (twentyFour ? hour24 : hour12).string(from: date) }
}
private extension Date {
    var startOfMinute: Date { Calendar.current.dateInterval(of: .minute, for: self)?.start ?? self }
}

struct AlbumArtwork: View {
    let model: StandbyModel
    @State private var hovered = false
    var body: some View {
        Button { model.openMusic() } label: {
        GeometryReader { geometry in
            if let image = model.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).frame(width: geometry.size.width, height: geometry.size.height).clipped()
            } else {
                ZStack {
                    LinearGradient(colors: model.palette.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().stroke(.white.opacity(0.18), lineWidth: 1).padding(geometry.size.width * 0.15)
                    Circle().stroke(.white.opacity(0.13), lineWidth: 1).padding(geometry.size.width * 0.25)
                    Image(systemName: "music.note").font(.system(size: geometry.size.width * 0.29, weight: .ultraLight)).foregroundStyle(.white.opacity(0.86))
                }
            }
        }
        .overlay(Color.black.opacity(hovered ? 0.22 : 0))
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
        .help("Volver a Música")
        .accessibilityLabel("Volver a Música. Portada de " + model.track.title)
    }
}
private struct TrackHeading: View {
    let model: StandbyModel
    var compact = false
    var body: some View {
        HStack(spacing: 18) {
            AlbumArtwork(model: model).frame(width: compact ? 56 : 76, height: compact ? 56 : 76).clipShape(RoundedRectangle(cornerRadius: compact ? 13 : 17))
            VStack(alignment: .leading, spacing: 7) {
                Text(model.track.title).font(model.contentTypeface.font(size: 23, emphasized: true)).tracking(-0.6).lineLimit(2)
                Text(model.track.artist).font(model.contentTypeface.font(size: 13)).opacity(0.55).lineLimit(1)
            }
        }
    }
}
private struct ListeningCover: View {
    let model: StandbyModel
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            AlbumArtwork(model: model).aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 26)).shadow(color: .black.opacity(0.15), radius: 20, y: 10)
            VStack(alignment: .leading, spacing: 8) {
                Text(model.track.title).font(.system(size: 27, weight: .semibold)).tracking(-0.6).lineLimit(2)
                Text(model.track.artist).font(.system(size: 15)).opacity(0.65).lineLimit(1)
                Text(model.track.album).font(.system(size: 12)).opacity(0.4).lineLimit(1)
            }
        }
    }
}

struct LyricsStage: View {
    let model: StandbyModel
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 19) {
            if model.isResynchronizing && !model.demoMode && model.hasTrack {
                ProgressView().controlSize(.small).accessibilityLabel("Sincronizando canción")
                    .frame(height: compact ? 180 : 230)
            } else if model.lines.isEmpty {
                Text(model.hasTrack ? model.lyricStatus : "Abre Música para empezar.")
                    .font(.system(size: 14)).lineSpacing(5).opacity(0.72).fixedSize(horizontal: false, vertical: true)
                if model.hasTrack && !model.demoMode {
                    HStack(spacing: 15) {
                        if !model.automaticLyrics {
                            Button("Activar letras") { model.settingsOpen = true }.buttonStyle(.glass)
                        }
                        Button("Importar .lrc") { model.importLRC() }.buttonStyle(.plain).opacity(0.65)
                    }.padding(.top, 8)
                }
            } else {
                let index = model.activeLine ?? -1
                if !compact {
                    cue(index - 1, prominence: 0.48, size: 19)
                        .frame(height: 45, alignment: .bottomLeading)
                }
                Text(index >= 0 && index < model.lines.count && !model.lines[index].text.isEmpty ? model.lines[index].text : "♪")
                .font(model.contentTypeface.font(size: compact ? 29 : (model.layout == .listening ? 39 : 36), emphasized: true))
                .tracking(-0.6).lineSpacing(3).lineLimit(4).minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: compact ? 100 : 144, alignment: .leading)
                .contentTransition(.opacity)
                .animation(model.reduceMotion ? nil : .easeOut(duration: 0.16), value: model.activeLine)
                cue(index + 1, prominence: 0.55, size: compact ? 18 : 21)
                    .frame(height: compact ? 50 : 55, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Stable row heights prevent adjacent cues from shifting the entire player.
    }
    @ViewBuilder private func cue(_ index: Int, prominence: Double, size: Double) -> some View {
        if index >= 0 && index < model.lines.count {
            Button { model.control("seek", position: max(0, model.lines[index].time - model.lyricOffset)) } label: {
                Text(model.lines[index].text.isEmpty ? "♪" : model.lines[index].text)
                    .font(model.contentTypeface.font(size: size)).lineLimit(2).multilineTextAlignment(.leading).opacity(prominence)
            }.buttonStyle(.plain).help("Ir a este momento de la canción")
        } else { Text(" ").font(.system(size: size)) }
    }
}

private struct TransportBar: View {
    let model: StandbyModel
    var body: some View {
        HStack(spacing: 22) {
            HStack(spacing: 22) {
                control("backward.end.fill", name: "Anterior", command: "previous", size: 16)
                control(model.anchor.playing ? "pause.fill" : "play.fill", name: model.anchor.playing ? "Pausar" : "Reproducir", command: "toggle", size: 22)
                control("forward.end.fill", name: "Siguiente", command: "next", size: 16)
            }
            Rectangle().fill(.primary.opacity(0.15)).frame(width: 1, height: 24)
            TrackProgress(model: model)
        }
        .padding(.horizontal, 24).padding(.vertical, 15)
        .lumaGlass(model: model, radius: 36)
    }
    private func control(_ symbol: String, name: String, command: String, size: Double) -> some View {
        Button { model.control(command) } label: {
            Image(systemName: symbol).font(.system(size: size, weight: .medium)).frame(width: 24, height: 28)
        }.buttonStyle(.plain).accessibilityLabel(name).help(name)
    }
}
struct TrackProgress: View {
    let model: StandbyModel
    var prominent = false
    @Environment(\.colorScheme) private var scheme
    @State private var dragProgress: Double?
    @State private var draggedTrackKey: String?
    var body: some View {
        Group {
            if model.anchor.playing && model.policy.visible && !model.isResynchronizing {
                TimelineView(.periodic(from: .now, by: model.onBattery ? 0.5 : 0.25)) { _ in progress }
            } else { progress }
        }
    }
    private var progress: some View {
        let position = model.anchor.value(at: ProcessInfo.processInfo.systemUptime)
        let duration = max(model.track.duration, 1)
        let fraction = dragProgress ?? min(1, max(0, position / duration))
        let shownPosition = dragProgress.map { $0 * duration } ?? position
        return VStack(spacing: 7) {
            GeometryReader { geometry in
                Capsule().fill(.primary.opacity(0.14))
                    .overlay(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.75)).frame(width: max(0, geometry.size.width * fraction))
                    }
                    .frame(height: prominent ? 5 : 3).frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if draggedTrackKey == nil { draggedTrackKey = model.track.cacheKey }
                            dragProgress = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                        }
                        .onEnded { value in
                            let target = min(1, max(0, value.location.x / max(1, geometry.size.width)))
                            if draggedTrackKey == model.track.cacheKey { model.control("seek", position: target * duration) }
                            dragProgress = nil; draggedTrackKey = nil
                        })
                    .accessibilityLabel("Posición de reproducción")
                    .accessibilityValue(Self.time(position) + " de " + Self.time(duration))
                    .accessibilityAdjustableAction { direction in model.control("seek", position: position + (direction == .increment ? 5 : -5)) }
            }.frame(height: prominent ? 20 : 12)
            HStack {
                Text(Self.time(shownPosition))
                    .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                Spacer()
                Text("−" + Self.time(max(0, duration - shownPosition)))
                    .foregroundStyle(scheme == .dark ? Color.white : Color.black)
            }.font(.system(size: 10, weight: .medium, design: .monospaced)).opacity(0.5)
        }
        .frame(minWidth: 120)
        .disabled(!model.hasTrack || model.track.duration <= 0 || model.isResynchronizing)
        .onChange(of: model.track.cacheKey) { _, _ in dragProgress = nil; draggedTrackKey = nil }
    }
    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = Int(max(0, seconds)); return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private struct SettingsPanel: View {
    @Bindable var model: StandbyModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ajustes").font(.system(size: 26, weight: .semibold))
                    Text(OruviRelease.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Listo") { dismiss() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }.padding(26)
            Form {
                UpdatesSettings()
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
                Section("Tipografías") {
                    Picker("Reloj", selection: $model.clockTypeface) {
                        ForEach(AmbientTypeface.allCases.filter(\.installed)) { Text($0.name).tag($0) }
                    }
                    EditorialTime(text: "13:36", maximumSize: 68, centered: true, typeface: model.clockTypeface, weight: model.clockWeight).frame(height: 82)
                    Picker("Grosor del reloj", selection: $model.clockWeight) {
                        ForEach(ClockWeight.allCases) { Text($0.name).tag($0) }
                    }
                    Picker("Canción, letras y frases", selection: $model.contentTypeface) {
                        ForEach(AmbientTypeface.allCases.filter(\.installed)) { Text($0.name).tag($0) }
                    }
                    Text("Aa · Música, tiempo y calma").font(model.contentTypeface.font(size: 23)).padding(.vertical, 6)
                    Text("SF Pro, SF Pro Rounded, SF Mono y New York usan las fuentes del sistema. Las variantes condensada y expandida también se resuelven de forma nativa. No se descargan ni distribuyen archivos de fuentes.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Frases") {
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
                Section("Música de este Mac") {
                    Text(model.connectionStatus).font(.callout)
                    HStack {
                        Button(model.connected ? "Reconectar Música" : "Conectar Música") { model.connectMusic() }
                        Button("Abrir Música") { model.openMusic() }
                        if model.connected || model.demoMode { Button("Desconectar") { model.disconnectMusic() } }
                    }
                    Text("Requiere permiso de Automatización. No lee contraseñas, no modifica tu biblioteca y no detecta música reproducida únicamente en el iPhone o Apple TV.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Portada y letras automáticas") {
                    Toggle("Recuperar portada del catálogo Apple cuando falte", isOn: $model.automaticArtwork)
                    Text("Se intenta primero la portada de Música y se reintenta si aún no está lista. Si falta, la búsqueda envía título y artista a Apple. La portada solo se asigna si coinciden la canción, el artista y la duración.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(model.artworkStatus).font(.caption).foregroundStyle(.secondary)
                    Text(model.lyricSource).font(.caption).foregroundStyle(.secondary)
                    Toggle("Buscar letras sincronizadas en LRCLIB", isOn: $model.automaticLyrics)
                    Text("La recuperación automática viene activa en esta actualización y se puede desactivar. Para las letras se envían título, artista, álbum y duración a lrclib.net; cada proveedor recibe tu IP. No son las letras oficiales de Apple. Se sincronizan por línea y su disponibilidad depende de la grabación.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Importar .lrc local…") { model.importLRC() }.disabled(!model.hasTrack)
                        Button("Vaciar caché de letras y portadas") { model.clearLyricsCache() }
                    }
                    HStack {
                        Text("Ajuste de sincronía")
                        Slider(value: $model.lyricOffset, in: -2...2, step: 0.05)
                        Text(String(format: "%+.2f s", model.lyricOffset)).monospacedDigit().frame(width: 65)
                    }
                    Text("Un valor positivo adelanta la letra. Ajusta también la latencia de Bluetooth o AirPlay; no se puede garantizar desfase cero.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Diseño y energía") {
                    Toggle("Adaptar fluid mesh a la portada de la canción", isOn: $model.meshFollowsMusic)
                    Text("Transición de colores al cambiar de canción. No escucha ni graba audio; no es un visualizador de ritmo. Si aún no hay portada, usa una paleta provisional por artista y álbum.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Apariencia", selection: $model.appearance) { ForEach(["Sistema", "Oscuro", "Claro"], id: \.self) { Text($0).tag($0) } }
                    Picker("Renderizado", selection: $model.energyMode) { ForEach(EnergyMode.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("Reloj de 24 horas", isOn: $model.twentyFourHour)
                    Toggle("Mantener pantalla encendida, solo con corriente", isOn: $model.keepAwake)
                    Text("Automático: malla a 24 fps con corriente, estática en batería. Fluido: hasta 30 fps con corriente y 12 en batería. Ahorro, baja energía, calor o Reducir movimiento detienen la malla. Mantener la pantalla encendida consume energía y está desactivado inicialmente.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Estado", value: model.energyLabel)
                    LabeledContent("Lectura reciente de Música", value: String(format: "%.0f ms (no es latencia de audio)", model.syncRoundTrip * 1000))
                }
                Section("Acerca de esta versión") {
                    Text("Oruvi · reloj, música y ambiente. Aplicación independiente de Apple, nativa SwiftUI / AppKit, sin navegador integrado ni telemetría. Pantalla completa sin bordes; no sustituye la pantalla de bloqueo. Conserva los ajustes de las versiones anteriores de Luma.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Ver demostración sin conectar cuentas") { model.useDemo(); dismiss() }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 610, height: min(740, (NSScreen.main?.visibleFrame.height ?? 820) - 70))
    }
}

private struct WindowAccessor: NSViewRepresentable {
    let model: StandbyModel
    func makeNSView(context: Context) -> NSView { AccessView(model: model) }
    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window { DispatchQueue.main.async { model.attach(window: window) } }
    }
    final class AccessView: NSView {
        let model: StandbyModel
        init(model: StandbyModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { self.model.attach(window: window) } }
        }
    }
}
extension View {
    @ViewBuilder func lumaGlass(model: StandbyModel, radius: Double) -> some View {
        if model.reduceTransparency {
            self.background(.background, in: RoundedRectangle(cornerRadius: radius))
        } else {
            self
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        }
    }
}
