// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import WidgetKit
import Observation
import ImageIO
import UniformTypeIdentifiers

private enum WidgetPublicationError: Error {
    case containerUnavailable, accessDenied, invalidSnapshot, storageFailure

    var message: String {
        switch self {
        case .containerUnavailable:
            return "macOS no puso a disposición los datos compartidos de Oruvi. Si solicita acceso, autorízalo y pulsa Conectar y actualizar widgets."
        case .accessDenied:
            return "macOS denegó el acceso a los datos compartidos. Si solicita acceso, autorízalo y pulsa Conectar y actualizar widgets."
        case .invalidSnapshot:
            return "Oruvi no pudo preparar un estado válido para el widget. Cambia de pista o pulsa Conectar y actualizar widgets."
        case .storageFailure:
            return "Oruvi no pudo guardar o verificar el estado del widget. Pulsa Conectar y actualizar widgets para reintentarlo."
        }
    }
}

/// Lookup stays off the main actor and outside the lock because macOS may ask
/// for access. Closing is serialized with writes, even before their callbacks.
private final class WidgetPublicationStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var store: WidgetSnapshotStore?
    private var needsResolution = true
    private var closed = false
    private let resolve: @Sendable () -> WidgetSnapshotStore

    init(resolve: @escaping @Sendable () -> WidgetSnapshotStore) { self.resolve = resolve }

    func writeVerified(_ snapshot: WidgetSnapshot, isCurrent: () -> Bool) -> WidgetPublicationError? {
        let (closed, cached) = lock.withLock { (self.closed, needsResolution ? nil : store) }
        guard !closed else { return .storageFailure }
        guard isCurrent() else { return nil }
        let target = cached ?? resolve()
        return lock.withLock {
            guard !self.closed else { return .storageFailure }
            guard isCurrent() else { return nil }
            guard target.directory != nil else {
                needsResolution = true
                return .containerUnavailable
            }
            if let store, store.directory != target.directory { store.clear() }
            store = target
            do {
                try target.write(snapshot)
                guard isCurrent() else { target.clear(); return nil }
                guard target.read() == snapshot else {
                    needsResolution = true
                    return .storageFailure
                }
                needsResolution = false
                return nil
            } catch WidgetSnapshotStore.StoreError.invalidSnapshot, WidgetSnapshotStore.StoreError.oversized {
                return .invalidSnapshot
            } catch {
                needsResolution = true
                let failure = error as NSError
                if (failure.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(failure.code)) ||
                    (failure.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(failure.code)) {
                    return .accessDenied
                }
                return .storageFailure
            }
        }
    }

    func close() {
        lock.withLock {
            closed = true
            store?.clear()
            store = nil
        }
    }
}

/// The app owns media reads and writes a single atomic presentation. WidgetCenter
/// membership is an energy hint, not a prerequisite for publishing current data.
@MainActor @Observable
final class NativeWidgetController {
    static let shared = NativeWidgetController(model: .shared)
    private(set) var installedCount = 0
    private(set) var lastPublishedAt: Date?
    private(set) var storageError = ""
    private var configurationStatus = "Comprobando widgets de macOS…"
    var sharingVerified: Bool { lastPublishedAt != nil && storageError.isEmpty }
    var status: String {
        if !storageError.isEmpty { return storageError }
        if !sharingVerified { return "Comprobando los datos compartidos de Oruvi…" }
        return configurationStatus
    }
    var connectionSummary: String {
        if !storageError.isEmpty { return "Revisar sincronización" }
        if !sharingVerified { return "Comprobando sincronización…" }
        return installedCount > 0 ? "\(installedCount) añadidos" : "Añadir al escritorio"
    }
    private let model: StandbyModel
    let session = UUID().uuidString
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var publishing: Task<Void, Never>?
    @ObservationIgnored private var reloading: Task<Void, Never>?
    @ObservationIgnored private var maintenance: Timer?
    @ObservationIgnored private var policy = WidgetPublicationPolicy()
    @ObservationIgnored private var presence = WidgetPresencePolicy()
    @ObservationIgnored private let storage: WidgetPublicationStorage
    @ObservationIgnored private var lastImage: NSImage?
    @ObservationIgnored private var thumbnail: Data?
    @ObservationIgnored private var lastMusicCover: (artwork: Data, palette: [UInt32]?)?
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var pendingForce = false
    @ObservationIgnored private var performing = false
    @ObservationIgnored private var lastQuery = Date.distantPast
    @ObservationIgnored private var querying = false
    @ObservationIgnored private var retryWriteAt = Date.distantPast
    @ObservationIgnored private var lastObservedSuspension = false
    @ObservationIgnored private var lastDistributedDemand = Date.distantPast
    @ObservationIgnored private let io = DispatchQueue(label: "com.kaizentrick.Oruvi.widget-cache", qos: .utility)
    #if LUMA_QA
    @ObservationIgnored private var verificationReload: (() -> Void)?
    #endif

    init(model: StandbyModel, resolveStore: @escaping @Sendable () -> WidgetSnapshotStore = { WidgetSnapshotStore.shared() }) {
        self.model = model
        storage = WidgetPublicationStorage(resolve: resolveStore)
    }
    func start() {
        guard !started, !stopped, !LumaEnvironment.isTesting else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification] {
            observe(workspace, name) { [weak self] in self?.refreshConfigurations() }
        }
        observe(DistributedNotificationCenter.default(), Notification.Name(OruviWidgetIdentity.requested)) { [weak self] in
            guard let self, Date().timeIntervalSince(self.lastDistributedDemand) >= 2 else { return }
            self.lastDistributedDemand = Date()
            self.receiveDemand()
        }
        // Bootstrap BEFORE the asynchronous enumeration. A zero/error response
        // must never erase a valid song and leave the widget permanently empty.
        trackChanges()
        requestPublication(force: true)
        refreshConfigurations(force: true)
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, !self.model.sessionSuspended else { return }
                self.model.setNativeWidgetPresence(self.presence.active(at: Date()))
                self.refreshConfigurations()
                self.requestPublication() // Refresh validity; unchanged data writes at most every 10 min.
            }
        }
        timer.tolerance = 10; maintenance = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        observers.append((center, token))
    }
    private func trackChanges() {
        guard !stopped else { return }
        withObservationTracking {
            _ = model.track; _ = model.artwork; _ = model.playbackIsPlaying
            _ = model.connected; _ = model.sessionSuspended; _ = model.demoMode
            _ = model.isResynchronizing
            _ = model.effectivePlayerPreference; _ = model.playbackSurface; _ = model.activePlayer
            _ = model.systemProhibitsSkip; _ = model.activeSystemBundleID; _ = model.palette
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.trackChanges() }
        }
        let suspended = model.sessionSuspended
        let enteringSuspension = suspended && !lastObservedSuspension
        lastObservedSuspension = suspended
        requestPublication(force: enteringSuspension)
    }
    func receiveDemand(at date: Date = Date()) {
        guard started, !stopped else { return }
        presence.receivedRequest(at: date)
        model.setNativeWidgetPresence(true)
        refreshConfigurations()
        // Requesting a timeline is NOT a request for another reload. Publishing
        // unchanged data below is deduplicated, so two widgets cannot ping-pong.
        requestPublication()
    }
    func acceptConfigurationCount(_ count: Int, at date: Date = Date()) {
        guard started, !stopped else { return }
        let changed = installedCount != count
        installedCount = max(0, count); presence.receivedCount(count)
        model.setNativeWidgetPresence(presence.active(at: date))
        configurationStatus = count > 0 ? "Widget nativo añadido · \(count)" : "Añade Oruvi desde Editar widgets."
        // A stale zero from WidgetCenter is not proof that all widgets vanished.
        // Keep one bounded snapshot; clear private media on disconnect/sleep/quit.
        requestPublication(force: changed && count > 0)
    }
    func refreshConfigurations(force: Bool = false) {
        guard !LumaEnvironment.isTesting, started, !stopped, !querying,
              Date().timeIntervalSince(lastQuery) >= (force ? 1 : 30) else { return }
        querying = true; lastQuery = Date()
        WidgetCenter.shared.getCurrentConfigurations { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.querying = false
                switch result {
                case .success(let widgets): self.acceptConfigurationCount(widgets.filter { $0.kind == OruviWidgetIdentity.kind }.count)
                case .failure:
                    self.configurationStatus = "macOS aún no informa de los widgets añadidos."
                    self.requestPublication()
                }
            }
        }
    }
    func refreshNow() {
        refreshConfigurations(force: true)
        Task { [weak self] in
            guard let self else { return }
            await self.perform(command: "refresh", session: "", trackID: "", sourceID: "", preference: "", reload: true)
        }
    }
    private func requestPublication(force: Bool = false) {
        guard started, !stopped else { return }
        dirty = true; pendingForce = pendingForce || force
        guard publishing == nil, !performing else { return }
        publishing = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self else { return }
            while self.dirty && !self.stopped && !Task.isCancelled && !self.performing {
                self.dirty = false
                let force = self.pendingForce; self.pendingForce = false
                await self.publishNow(force: force)
                if self.dirty { try? await Task.sleep(nanoseconds: 250_000_000) }
            }
            self.publishing = nil
        }
    }
    func makeSnapshot(at now: Date = Date()) -> WidgetSnapshot {
        var value = WidgetSnapshot(); value.generatedAt = now; value.session = session
        value.preference = model.effectivePlayerPreference.rawValue
        if model.sessionSuspended {
            value.state = .sleeping; value.title = "Oruvi en reposo"; value.artist = "La reproducción se actualizará al volver."
        } else if !model.connected || model.demoMode {
            value.state = .disconnected; value.title = "Reproductor desconectado"; value.artist = "Conéctalo en los ajustes de Oruvi."
        } else if !model.hasTrack {
            value.state = .idle; value.title = "Nada en reproducción"; value.artist = "Elige una canción en tu reproductor."
        } else {
            value.state = .ready; value.sourceID = model.activePlayer.rawValue
            let source = model.activePlayer
            let systemApp = source == .system ? NSRunningApplication.runningApplications(withBundleIdentifier: model.activeSystemBundleID).first : nil
            value.sourceName = String((systemApp?.localizedName ?? source.name).prefix(512))
            value.title = String(model.track.title.prefix(512))
            value.artist = String((model.track.artist.isEmpty ? model.activePlayer.name : model.track.artist).prefix(512))
            value.playing = model.playbackIsPlaying
            if model.isResynchronizing {
                // An empty command identity disables transport in older widgets too.
                value.message = "Sincronizando canción…"
                value.canSkip = false
            } else {
                value.trackID = model.track.id
                value.canSkip = model.canSkip
            }
        }
        return value
    }
    private func publishNow(force: Bool = false, reload: Bool = true, message: String = "") async {
        guard started, !stopped, force || Date() >= retryWriteAt else { return }
        serial += 1; let work = serial
        let suspension = model.sessionSuspensionGeneration
        let generation = suspension.withLock { $0 }
        var value = makeSnapshot()
        if !message.isEmpty { value.message = message }
        if value.state == .ready, let image = model.artwork {
            let palette = model.palette
            let artworkSource = model.activePlayer == .system ? model.activeSystemBundleID : value.sourceID
            if palette.count == 4 {
                value.artworkPalette = palette.map { color in
                    let red = UInt32((color.r * 255).rounded())
                    let green = UInt32((color.g * 255).rounded())
                    let blue = UInt32((color.b * 255).rounded())
                    return (red << 16) | (green << 8) | blue
                }
            }
            if lastImage !== image {
                var rect = NSRect(origin: .zero, size: image.size)
                let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                let decoded = await Task.detached(priority: .utility) { cgImage.flatMap(Self.jpegThumbnail) }.value
                guard !Task.isCancelled, !stopped, work == serial else { return }
                lastImage = image; thumbnail = decoded
            }
            value.artwork = thumbnail
            if let thumbnail, artworkSource == PlayerSource.music.rawValue || artworkSource == PlayerSource.spotify.rawValue {
                lastMusicCover = (thumbnail, value.artworkPalette)
            }
        } else {
            lastImage = nil; thumbnail = nil
            if value.state == .idle {
                value.artwork = lastMusicCover?.artwork
                value.artworkPalette = lastMusicCover?.palette
            } else if value.state == .disconnected {
                lastMusicCover = nil
            }
        }
        guard !stopped, !Task.isCancelled, work == serial,
              suspension.withLock({ $0 == generation }), policy.needsWrite(value, force: force) else { return }
        let failure = await withCheckedContinuation { continuation in
            io.async { [storage, value] in
                // Container lookup may ask for access. Do not block the UI, and
                // never keep a failed nil-container result forever after consent.
                continuation.resume(returning: storage.writeVerified(value) { suspension.withLock { $0 == generation } })
            }
        }
        guard !stopped, work == serial, suspension.withLock({ $0 == generation }) else { return }
        if let failure {
            retryWriteAt = Date().addingTimeInterval(60)
            storageError = failure.message
            return
        }
        retryWriteAt = .distantPast; storageError = ""; lastPublishedAt = value.generatedAt
        policy.record(value, reload: false)
        // Renew the timeline's expiry as well as the file's freshness. Otherwise
        // a paused track can turn stale on screen despite healthy heartbeat writes.
        if reload { requestReload() }
    }
    private func requestReload() {
        guard reloading == nil else { return }
        let delay = policy.reloadDelay(at: Date())
        reloading = Task { [weak self] in
            if delay > 0 { do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return } }
            guard let self, !self.stopped, !Task.isCancelled else { return }
            #if LUMA_QA
            if let callback = self.verificationReload { callback() }
            else { WidgetCenter.shared.reloadTimelines(ofKind: OruviWidgetIdentity.kind) }
            #else
            WidgetCenter.shared.reloadTimelines(ofKind: OruviWidgetIdentity.kind)
            #endif
            // Reload time must not falsify when the snapshot was actually written.
            self.policy.recordReload(at: Date())
            self.reloading = nil
        }
    }
    func perform(command: String, session: String, trackID: String, sourceID: String, preference: String, reload: Bool = false) async {
        guard !LumaEnvironment.isTesting, ["refresh", "previous", "toggle", "next"].contains(command) else { return }
        for _ in 0..<40 where !started { try? await Task.sleep(nanoseconds: 50_000_000) }
        guard started, !stopped, !model.sessionSuspended, !performing else { return }
        performing = true
        publishing?.cancel(); publishing = nil; dirty = false; pendingForce = false; serial += 1
        presence.receivedRequest(at: Date()); model.setNativeWidgetPresence(true)
        var message: String
        if command == "refresh" {
            // Explicit recovery connects the selected player but NEVER sends a
            // play/pause/next command. Merely adding the widget does not opt in.
            message = await model.synchronizeNativeWidget(connectIfNeeded: true)
        } else if session != self.session {
            message = await model.synchronizeNativeWidget(connectIfNeeded: false)
            if message.isEmpty { message = "Sesión actualizada. Vuelve a pulsar el control." }
        } else {
            message = await model.controlFromNativeWidget(command, expectedTrackID: trackID, sourceID: sourceID, preference: preference)
        }
        // App Intents already trigger a reload; actions from the app must request one.
        await publishNow(force: true, reload: reload, message: message)
        performing = false
        if dirty { requestPublication() }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true; serial += 1
        maintenance?.invalidate(); maintenance = nil
        publishing?.cancel(); reloading?.cancel(); publishing = nil; reloading = nil
        for (center, token) in observers { center.removeObserver(token) }; observers.removeAll()
        storage.close()
        #if LUMA_QA
        if let callback = verificationReload { callback(); return }
        #endif
        if presence.active(at: Date()) { WidgetCenter.shared.reloadTimelines(ofKind: OruviWidgetIdentity.kind) }
    }
    #if LUMA_QA
    /// Only compiled in CI's isolated executable; never in the distributed app.
    func startForVerification(reload: @escaping () -> Void) {
        precondition(LumaEnvironment.isTesting && !started)
        verificationReload = reload; started = true
        trackChanges(); requestPublication(force: true)
    }
    func renewForVerification() {
        precondition(LumaEnvironment.isTesting)
        guard var previous = policy.previous else { return }
        previous.generatedAt = Date().addingTimeInterval(-601)
        policy.record(previous, reload: false)
        requestPublication()
    }
    func republishForVerification() {
        precondition(LumaEnvironment.isTesting)
        requestPublication(force: true)
    }
    #endif
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
