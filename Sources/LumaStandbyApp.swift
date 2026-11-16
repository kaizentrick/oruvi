import SwiftUI
import AppKit
import Observation
import ServiceManagement

@MainActor @Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()
    private(set) var enabled = false
    var message = ""
    private init() { refresh() }
    func refresh() {
        guard !LumaEnvironment.isTesting else { enabled = false; return }
        enabled = SMAppService.mainApp.status == .enabled
    }
    func setEnabled(_ value: Bool) {
        guard !LumaEnvironment.isTesting else { return }
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            message = ""
        } catch {
            message = "Gestiona el inicio automático en Ajustes del Sistema → General → Ítems de inicio."
        }
        refresh()
    }
}

// The lifecycle lives in OruviApplication.swift; this file contains views only.
// There is no SwiftUI Settings scene that macOS could restore on launch.
struct StandbyHost: View {
    let model: StandbyModel
    var body: some View { StandbyView(model: model).preferredColorScheme(model.preferredScheme) }
}

struct StandbyView: View {
    @Bindable var model: StandbyModel
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        GeometryReader { geometry in
            let inset = min(64.0, max(28.0, geometry.size.width * 0.046))
            let compact = geometry.size.height < 710
            ZStack {
                SmoothMesh(palette: model.meshPalette, framesPerSecond: model.policy.framesPerSecond, light: scheme == .light)
                    .animation(model.policy.framesPerSecond > 0 ? .easeOut(duration: 0.28) : nil, value: model.meshPalette)
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
        .background { WindowAccessor(model: model).frame(width: 1, height: 1).allowsHitTesting(false) }
        .sheet(isPresented: $model.settingsOpen) { SettingsPanel(model: model) }
        .overlay(alignment: .top) {
            if let message = model.toastMessage {
                Text(message).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
                    .padding(.horizontal, 20).padding(.vertical, 13).frame(maxWidth: 440)
                    .lumaGlass(model: model, radius: 22).padding(.top, 90)
                    .transition(.opacity).allowsHitTesting(false).accessibilityLabel(message)
            }
        }
        .animation(model.reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.toastMessage)
    }
    private func display(size: CGSize, inset: CGFloat, compact: Bool) -> some View {
        VStack(spacing: compact ? 12 : 24) {
            if model.layout == .listening {
                MusicPlayerView(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.layout == .clock {
                EditorialClock(model: model, large: true, compact: compact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.hasTrack {
                    compactTrack
                    TransportBar(model: model).frame(maxWidth: 500)
                } else { connectBar }
            } else {
                HStack(alignment: .center, spacing: min(70, size.width * 0.05)) {
                    EditorialClock(model: model, compact: compact)
                        .frame(width: (size.width - inset * 2) * 0.43)
                    VStack(alignment: .leading, spacing: compact ? 16 : 26) {
                        if model.hasTrack {
                            TrackHeading(model: model, compact: compact)
                            TransportBar(model: model).frame(maxWidth: 500)
                            LyricsVisibilityButton(model: model)
                            if model.visibleLyrics { LyricsStage(model: model, compact: compact) }
                        } else { connectBar }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }.frame(maxWidth: 1240, maxHeight: .infinity)
            }
        }
    }
    private var topBar: some View {
        HStack(spacing: 10) {
            if model.layout != .listening {
                PlayerSourcePicker(selection: $model.playerPreference, surface: .standby,
                                   activePlayer: model.hasTrack ? model.activePlayer : nil)
                    .padding(.horizontal, 14).padding(.vertical, 10).lumaGlass(model: model, radius: 20)
            }
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
    private var connectBar: some View { EmptyPlayerButton(model: model) }
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
            EditorialTime(text: Self.format(date, twentyFour: model.twentyFourHour),
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
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                ZStack {
                    LinearGradient(colors: model.palette.map(\.color), startPoint: .topLeading, endPoint: .bottomTrailing)
                    Circle().stroke(.white.opacity(0.18), lineWidth: 1).padding(geometry.size.width * 0.15)
                    Circle().stroke(.white.opacity(0.13), lineWidth: 1).padding(geometry.size.width * 0.25)
                    Image(systemName: "music.note").font(.system(size: geometry.size.width * 0.29, weight: .ultraLight)).foregroundStyle(.white.opacity(0.86))
                }
            }
        }
        .overlay(Color.black.opacity(hovered && model.activePlayer != .spotify ? 0.22 : 0))
        .overlay(Rectangle().strokeBorder(.white.opacity(hovered && model.activePlayer == .spotify ? 0.35 : 0), lineWidth: 1.5))
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
        .help("Volver a " + model.activePlayer.name)
        .accessibilityLabel("Volver a " + model.activePlayer.name + ". Portada de " + model.track.title)
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

struct LyricsStage: View {
    let model: StandbyModel
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 19) {
            if model.isResynchronizing && !model.demoMode {
                ProgressView("Sincronizando canción…").controlSize(.small)
                    .frame(height: compact ? 180 : 230)
            } else {
                let index = model.activeLine ?? -1
                if !compact {
                    cue(index - 1, prominence: 0.48, size: 19)
                        .frame(height: 45, alignment: .bottomLeading)
                }
                Text(model.currentLyricText ?? "♪")
                .font(LyricTypography.font(model.lyricTypeface, baseSize: compact ? 29 : (model.layout == .listening ? 39 : 36),
                                           sizePercent: model.lyricSizePercent, emphasized: true))
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
                    .font(LyricTypography.font(model.lyricTypeface, baseSize: size, sizePercent: model.lyricSizePercent))
                    .lineLimit(2).multilineTextAlignment(.leading).opacity(prominence)
            }.buttonStyle(.plain).help("Ir a este momento de la canción")
                .disabled(!model.canSeek)
        } else { Text(" ").font(.system(size: size)) }
    }
}

private struct TransportBar: View {
    let model: StandbyModel
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 22) {
                buttons
                Rectangle().fill(.primary.opacity(0.15)).frame(width: 1, height: 24)
                TrackProgress(model: model)
            }
            VStack(spacing: 8) {
                buttons
                TrackProgress(model: model)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 15)
        .lumaGlass(model: model, radius: 36)
    }
    private var buttons: some View {
        HStack(spacing: 22) {
            control("backward.end.fill", name: "Anterior", command: "previous", size: 16).disabled(!model.canSkip)
            control(model.anchor.playing ? "pause.fill" : "play.fill", name: model.anchor.playing ? "Pausar" : "Reproducir", command: "toggle", size: 22)
            control("forward.end.fill", name: "Siguiente", command: "next", size: 16).disabled(!model.canSkip)
        }
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
    var body: some View {
        Group {
            if model.anchor.playing && model.policy.visible && !model.isResynchronizing {
                let interval = model.track.duration <= 0 ? 1 : (model.onBattery ? 0.5 : 0.25)
                TimelineView(.periodic(from: .now, by: interval)) { _ in progress }
            } else { progress }
        }
    }
    private var progress: some View {
        let position = model.anchor.value(at: ProcessInfo.processInfo.systemUptime)
        let duration = model.track.duration
        let shownPosition = model.canSeek ? (dragProgress.map { $0 * duration } ?? position) : position
        return VStack(spacing: 7) {
            if duration > 0 {
                PlaybackScrubber(model: model, position: position, thickness: prominent ? 5 : 3,
                                 trackColor: .primary.opacity(0.14), fillColor: .primary.opacity(0.75), dragProgress: $dragProgress)
                    .frame(height: prominent ? 20 : 12)
            }
            HStack {
                Text(PlaybackTime.format(shownPosition))
                    .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                Spacer()
                if duration > 0 {
                    Text("−" + PlaybackTime.format(duration - shownPosition))
                        .foregroundStyle(scheme == .dark ? Color.white : Color.black)
                }
            }.font(.system(size: 10, weight: .medium, design: .monospaced)).opacity(0.5)
        }
        .frame(minWidth: 120)
    }
}

struct PlaybackScrubber: View {
    let model: StandbyModel
    let position: Double
    let thickness: CGFloat
    let trackColor: Color
    let fillColor: Color
    @Binding var dragProgress: Double?
    @State private var draggedTrack: TrackIdentity?

    var body: some View {
        GeometryReader { geometry in
            let duration = model.track.duration
            let width = geometry.size.width
            let fraction = (model.canSeek ? dragProgress : nil) ?? unit(position / duration)
            let positionDescription = PlaybackTime.format(position) + " de " + PlaybackTime.format(duration)
            let bar = Capsule().fill(trackColor)
                .overlay(alignment: .leading) {
                    Capsule().fill(fillColor).frame(width: max(0, width * fraction))
                }
                .frame(height: thickness).frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            if model.canSeek {
                bar.gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if draggedTrack == nil { draggedTrack = model.track }
                        dragProgress = unit(value.location.x / max(1, width))
                    }
                    .onEnded { value in
                        if draggedTrack == model.track {
                            model.control("seek", position: unit(value.location.x / max(1, width)) * duration)
                        }
                        resetDrag()
                    })
                    .accessibilityRepresentation {
                        Slider(value: Binding(get: { duration * unit(position / duration) },
                                              set: { model.control("seek", position: $0) }),
                               in: 0...duration, step: min(5, duration)) {
                            Text("Posición de reproducción")
                        }.accessibilityValue(positionDescription)
                    }
            } else {
                bar.accessibilityRepresentation { Text("Posición de reproducción, \(positionDescription)") }
            }
        }
        .onChange(of: model.track) { _, _ in resetDrag() }
        .onChange(of: model.canSeek) { _, _ in resetDrag() }
        .onDisappear { resetDrag() }
    }
    private func unit(_ value: Double) -> Double { min(1, max(0, value)) }
    private func resetDrag() { dragProgress = nil; draggedTrack = nil }
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
