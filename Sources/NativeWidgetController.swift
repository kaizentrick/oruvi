// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import WidgetKit
import Observation
import ImageIO
import UniformTypeIdentifiers

/// Shares the existing player's current presentation with WidgetKit. No NSPanel,
/// overlay, render loop, second music sampler or player process in the extension.
@MainActor @Observable
final class NativeWidgetController {
    static let shared = NativeWidgetController(model: .shared)
    private(set) var installedCount = 0
    private(set) var status = "Añade Oruvi desde Editar widgets de macOS."
    private let model: StandbyModel
    let session = UUID().uuidString
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var publishing: Task<Void, Never>?
    @ObservationIgnored private var reloading: Task<Void, Never>?
    @ObservationIgnored private var policy = WidgetPublicationPolicy()
    @ObservationIgnored private var store: WidgetSnapshotStore?
    @ObservationIgnored private var lastImage: NSImage?
    @ObservationIgnored private var thumbnail: Data?
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var lastQuery = Date.distantPast
    @ObservationIgnored private var querying = false
    @ObservationIgnored private let io = DispatchQueue(label: "com.kaizentrick.Oruvi.widget-cache", qos: .utility)

    init(model: StandbyModel) { self.model = model }
    func start() {
        guard !started, !stopped, !LumaEnvironment.isTesting else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            observe(workspace, name) { [weak self] in self?.refreshConfigurations() }
        }
        observe(DistributedNotificationCenter.default(), Notification.Name(OruviWidgetIdentity.requested)) { [weak self] in
            guard let self else { return }
            self.refreshConfigurations(force: true)
            self.requestPublication(force: true)
        }
        refreshConfigurations(force: true)
        trackChanges()
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        observers.append((center, token))
    }
    private func trackChanges() {
        guard !stopped else { return }
        withObservationTracking {
            _ = model.track; _ = model.artwork; _ = model.anchor.playing
            _ = model.connected; _ = model.screenSleeping; _ = model.demoMode
            _ = model.effectivePlayerPreference; _ = model.playbackSurface; _ = model.activePlayer
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackChanges() }
        }
        requestPublication()
    }
    func refreshConfigurations(force: Bool = false) {
        guard started, !stopped, !querying, force || Date().timeIntervalSince(lastQuery) >= 15 else { return }
        querying = true; lastQuery = Date()
        WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.querying = false
                if case .success(let widgets) = result {
                    let count = widgets.filter { $0.kind == OruviWidgetIdentity.kind }.count
                    self.installedCount = count
                    self.model.setNativeWidgetPresence(count > 0)
                    self.status = count > 0 ? "Widget nativo añadido · \(count)" : "Clic secundario en el escritorio → Editar widgets → Oruvi."
                    if count > 0 { self.requestPublication(force: true) }
                    else { self.clearSharedPresentation() }
                } else { self.status = "macOS aún no ha informado de los widgets. Abre Editar widgets y busca Oruvi." }
            }
        }
    }
    func refreshNow() {
        refreshConfigurations(force: true)
        requestPublication(force: true)
    }
    private func requestPublication(force: Bool = false) {
        guard started, !stopped, installedCount > 0 || force else { return }
        publishing?.cancel()
        publishing = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.publishNow(force: force)
        }
    }
    func makeSnapshot(at now: Date = Date()) -> WidgetSnapshot {
        var value = WidgetSnapshot(); value.generatedAt = now; value.session = session
        value.preference = model.effectivePlayerPreference.rawValue
        value.sourceName = model.effectivePlayerPreference == .automatic ? "Automático · " + model.activePlayer.name : model.activePlayer.name
        if model.screenSleeping {
            value.state = .sleeping; value.title = "Oruvi en reposo"; value.artist = "La reproducción se actualizará al volver."
        } else if !model.connected || model.demoMode {
            value.state = .disconnected; value.title = "Conecta tu reproductor"; value.artist = "Abre Oruvi para conectar los controles."
        } else if !model.hasTrack {
            value.state = .idle; value.title = "Nada en reproducción"; value.artist = "Reproduce contenido en tu Mac."
        } else {
            value.state = .ready; value.trackID = model.track.id; value.sourceID = model.activePlayer.rawValue
            value.title = String(model.track.title.prefix(512))
            value.artist = String((model.track.artist.isEmpty ? model.activePlayer.name : model.track.artist).prefix(512))
            value.playing = model.anchor.playing; value.canSkip = !model.systemProhibitsSkip
        }
        return value
    }
    private func publishNow(force: Bool = false, reload: Bool = true, message: String = "") async {
        guard started, !stopped else { return }
        serial += 1; let work = serial
        var value = makeSnapshot(); value.message = message
        if value.state == .ready, let image = model.artwork {
            if lastImage !== image {
                lastImage = image
                var rect = NSRect(origin: .zero, size: image.size)
                let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                thumbnail = await Task.detached(priority: .utility) { cgImage.flatMap(Self.jpegThumbnail) }.value
            }
            value.artwork = thumbnail
        } else { lastImage = nil; thumbnail = nil }
        guard !stopped, !Task.isCancelled, work == serial, policy.needsWrite(value, force: force) else { return }
        if store == nil { store = .shared() }
        guard let store else { return }
        let saved = await withCheckedContinuation { continuation in
            io.async {
                do { try store.write(value); continuation.resume(returning: true) }
                catch { continuation.resume(returning: false) }
            }
        }
        guard !stopped, work == serial else { return }
        guard saved else {
            status = "No se pudo compartir el estado con el widget. Revisa el permiso de datos de aplicaciones de Oruvi en Privacidad y seguridad."
            return
        }
        let changed = policy.previous.map { !value.samePresentation(as: $0) } ?? true
        policy.record(value, reload: false)
        if reload && (changed || force) { requestReload() }
    }
    private func requestReload() {
        guard reloading == nil else { return }
        let delay = policy.reloadDelay(at: Date())
        reloading = Task { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            }
            guard let self, !self.stopped, !Task.isCancelled else { return }
            WidgetCenter.shared.reloadTimelines(ofKind: OruviWidgetIdentity.kind)
            if var value = self.policy.previous { value.generatedAt = Date(); self.policy.record(value, reload: true) }
            self.reloading = nil
        }
    }
    func perform(command: String, session: String, trackID: String, sourceID: String, preference: String) async {
        guard !LumaEnvironment.isTesting else { return }
        // Wait briefly for the normal application delegate on a cold App Intent launch.
        for _ in 0..<20 where !started {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard started, !stopped, !model.screenSleeping else { return }
        publishing?.cancel(); publishing = nil
        var message = ""
        if session != self.session {
            model.refreshPlayback()
            message = "Sesión actualizada. Vuelve a pulsar el control."
        } else {
            message = await model.controlFromNativeWidget(command, expectedTrackID: trackID, sourceID: sourceID, preference: preference)
        }
        // Apple reloads after perform returns. Finish the atomic write FIRST.
        await publishNow(force: true, reload: false, message: message)
    }
    private func clearSharedPresentation() {
        publishing?.cancel(); publishing = nil; serial += 1
        if let store { io.async { store.clear() } }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; serial += 1
        publishing?.cancel(); reloading?.cancel()
        publishing = nil; reloading = nil
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
        if let store { io.sync { store.clear() } }
        if installedCount > 0 { WidgetCenter.shared.reloadTimelines(ofKind: OruviWidgetIdentity.kind) }
    }
    nonisolated static func jpegThumbnail(_ image: CGImage) -> Data? {
        let scale = min(1, 192.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, resized, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= WidgetSnapshot.maximumArtworkBytes else { return nil }
        return data as Data
    }
}
