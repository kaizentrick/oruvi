import AppKit
import Observation
import os

/// Tests the actual async observer -> thumbnail -> atomic write -> reload path.
/// Does not start the app delegate, playback router, a real player or networking.
@main struct VerifyWidgetPipeline {
    @MainActor static func main() async throws {
        precondition(LumaEnvironment.isTesting)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OruviPipeline-" + UUID().uuidString)
        let store = WidgetSnapshotStore(directory: root)
        let model = StandbyModel.shared
        model.automaticLyrics = false; model.automaticArtwork = false
        var count = 0, reloads = 0
        func check(_ value: @autoclosure () -> Bool, _ text: String) { count += 1; precondition(value(), text) }
        func settle() async throws { try await Task.sleep(nanoseconds: 800_000_000) }
        let controller = NativeWidgetController(model: model, resolveStore: { store })
        defer {
            controller.stop(); model.shutdown(); LumaEnvironment.cleanTestingData()
            try? FileManager.default.removeItem(at: root)
        }
        model.connected = true
        model.apply(["status":"ok", "source":"oruvi.system", "id":"browser-A", "title":"Video A", "artist":"Channel A", "album":"", "duration":100, "position":12, "playing":true])
        controller.startForVerification { reloads += 1 }
        controller.acceptConfigurationCount(0)
        check(!controller.sharingVerified && controller.status.contains("Comprobando") &&
              controller.connectionSummary.contains("Comprobando"),
              "An early WidgetCenter count cannot report a successful publication before read-back")
        try await settle()
        check(store.read()?.title == "Video A", "Bootstrap writes before WidgetCenter reports any widgets")
        check(controller.sharingVerified && controller.connectionSummary == "Añadir al escritorio",
              "Verified sharing and widget placement remain separate signals")
        check(store.read()?.displaySourceName == "Ahora suena", "The widget source label omits the automatic selection mode")
        check(store.read()?.playing == true, "Playback state crosses actual async pipeline")
        check(reloads == 1, "First reload occurs only after verified write")
        let playingChange = DispatchSemaphore(value: 0)
        withObservationTracking { _ = model.playbackIsPlaying } onChange: { playingChange.signal() }
        model.anchor = PlaybackAnchor(position: 20, uptime: ProcessInfo.processInfo.systemUptime, duration: 100, playing: true)
        check(playingChange.wait(timeout: .now()) == .timedOut, "Position-only samples do not wake the widget observer")
        model.anchor.playing = false
        check(playingChange.wait(timeout: .now()) == .success, "Play and pause still wake the widget observer")
        model.anchor.playing = true
        controller.acceptConfigurationCount(0)
        try await settle()
        check(store.read()?.title == "Video A", "Late empty enumeration cannot erase real music")
        controller.receiveDemand()
        controller.acceptConfigurationCount(0)
        try await settle()
        check(model.nativeWidgetInUse, "Timeline demand survives delayed WidgetCenter membership")
        check(store.read()?.trackID == "browser-A", "Two widgets do not clear one another")
        let current = store.read()
        for _ in 0..<20 { controller.receiveDemand() }
        try await settle()
        check(store.read()?.generatedAt == current?.generatedAt, "Repeated timeline hints deduplicate writes")
        check(reloads == 1, "Repeated timeline hints cannot form a reload loop")
        controller.renewForVerification()
        try await Task.sleep(for: .seconds(6))
        check(reloads == 2, "Unchanged heartbeat renews the visible timeline before its expiry")
        let colorspace = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGContext(data: nil, width: 384, height: 384, bitsPerComponent: 8, bytesPerRow: 0, space: colorspace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 0.4, alpha: 1)); bitmap.fill(CGRect(x:0,y:0,width:384,height:384))
        model.artwork = NSImage(cgImage: bitmap.makeImage()!, size: NSSize(width:384,height:384))
        model.palette = Array(repeating: RGB(r: 0.4, g: 0.4, b: 0.4), count: 4)
        try await settle()
        let imageData = store.read()?.artwork
        check(imageData != nil, "Late artwork is published without changing the track")
        let image = imageData.flatMap { NSImage(data:$0) }
        check(image != nil && image!.size.width <= 192, "Published cover is decodable and bounded")
        check(store.read()?.artworkPalette == Array(repeating: 0x666666, count: 4), "The cover palette is published with late artwork")
        model.palette = Array(repeating: RGB(r: 0.2, g: 0.2, b: 0.2), count: 4)
        try await settle()
        check(store.read()?.artwork == imageData && store.read()?.artworkPalette == Array(repeating: 0x333333, count: 4),
              "Palette-only changes reach the widget without rebuilding the thumbnail")
        bitmap.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 384, height: 384))
        let correctedCover = NSBitmapImageRep(cgImage: bitmap.makeImage()!).representation(using: .png, properties: [:])!
        model.apply(["status": "ok", "source": "oruvi.system", "id": "browser-A", "title": "Video A",
                     "artist": "Channel A", "duration": 100, "position": 12, "playing": true, "systemArtwork": correctedCover])
        try await settle()
        let corrected = store.read()
        check(corrected?.title == "Video A" && corrected?.artwork != nil && corrected?.artwork != imageData,
              "A later verified cover replaces the provisional image for the same recording")
        check(corrected?.artworkPalette != Array(repeating: 0x666666, count: 4), "Replacement cover updates the widget palette")
        let verifiedCover = model.artwork
        bitmap.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.8, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 384, height: 384))
        let supersededCover = NSBitmapImageRep(cgImage: bitmap.makeImage()!).representation(using: .png, properties: [:])!
        let playback: [String: Any] = ["status": "ok", "source": "oruvi.system", "id": "browser-A",
                                       "title": "Video A", "artist": "Channel A", "duration": 100,
                                       "position": 12, "playing": true]
        model.apply(playback.merging(["systemArtwork": supersededCover]) { _, new in new })
        model.apply(playback.merging(["systemArtwork": correctedCover]) { _, new in new })
        let artworkChange = DispatchSemaphore(value: 0)
        withObservationTracking { _ = model.artwork } onChange: { artworkChange.signal() }
        try await settle()
        check(artworkChange.wait(timeout: .now()) == .timedOut && model.artwork === verifiedCover &&
              store.read()?.artwork == corrected?.artwork && model.artworkStatus == "Portada del reproductor",
              "Reverting to the already displayed cover cancels a superseded decode without publishing it")
        let missingTrack = model.apply(["status": "ok", "source": "oruvi.system"])
        let invalidPosition = model.apply(playback.merging(["position": Double.nan]) { _, new in new })
        check(missingTrack == "Sincronizando canción…" && invalidPosition == missingTrack,
              "A nominally successful provider reply reports pending synchronization if its metadata is invalid")
        try await settle()
        let synchronizing = store.read()
        check(synchronizing?.title == "Video A" && synchronizing?.artwork == corrected?.artwork &&
              synchronizing?.message == "Sincronizando canción…" && synchronizing?.canControl == false,
              "An invalid sample withdraws controls without discarding the title or cover")
        model.apply(playback)
        try await settle()
        check(store.read()?.trackID == "browser-A" && store.read()?.canControl == true && store.read()?.message.isEmpty == true,
              "Confirming the same track restores widget controls without requiring a metadata change")
        let synchronizationChange = DispatchSemaphore(value: 0)
        withObservationTracking { _ = model.isResynchronizing } onChange: { synchronizationChange.signal() }
        model.apply(playback)
        check(synchronizationChange.wait(timeout: .now()) == .timedOut,
              "Unchanged playback samples do not wake the widget through synchronization state")
        model.apply(["status":"ok", "source":"oruvi.system", "id":"browser-B", "title":"Video B", "artist":"Channel B", "album":"", "duration":100, "position":0, "playing":false])
        try await settle()
        check(store.read()?.title == "Video B" && store.read()?.playing == false, "Track and pause propagate together")
        check(store.read()?.artwork == nil, "New title never inherits old cover")
        check(store.read()?.artworkPalette == nil, "New title never inherits old cover colors")
        model.setSuspended(true, source: .system)
        model.setSuspended(true, source: .display)
        try await settle()
        check(store.read()?.state == .sleeping && store.read()?.artwork == nil && store.read()?.artworkPalette == nil, "Sleep removes media presentation")
        model.setSuspended(false, source: .display)
        try await settle()
        check(store.read()?.state == .sleeping, "Partial wake keeps the published widget asleep")
        model.setSuspended(false, source: .system)
        try await settle()
        check(store.read()?.title == "Video B" && store.read()?.canControl == false,
              "Wake keeps the last known presentation while awaiting a fresh sample")
        model.setSuspended(true, source: .locked)
        try await settle()
        check(store.read()?.state == .sleeping && store.read()?.trackID.isEmpty == true &&
              store.read()?.canControl == false, "Lock alone clears media and controls from the published widget")
        model.setSuspended(true, source: .inactive)
        model.setSuspended(false, source: .locked)
        try await settle()
        check(store.read()?.state == .sleeping && !model.needsPlayback,
              "Unlocking before session activation cannot resume playback or republish the track")
        model.setSuspended(false, source: .inactive)
        try await settle()
        check(store.read()?.title == "Video B" && model.needsPlayback, "Active session restores widget playback demand")
        for source in ["com.apple.Music", "com.spotify.client"] {
            model.apply(["status": "ok", "source": source, "id": source, "title": "Song",
                         "artist": "Artist", "album": "Album", "duration": 100, "playing": true])
            model.artwork = NSImage(cgImage: bitmap.makeImage()!, size: NSSize(width:384,height:384))
            model.palette = Array(repeating: RGB(r: 0.4, g: 0.4, b: 0.4), count: 4)
            try await settle()
            let beforeStop = store.read()
            check(beforeStop?.artwork != nil && beforeStop?.canControl == true, "Active music publishes artwork and controls")
            model.apply(["status": "stopped"]); model.apply(["status": "stopped"])
            try await settle()
            let idle = store.read()
            check(idle?.state == .idle && idle?.canControl == false && idle?.trackID.isEmpty == true, "Stopped music hides the previous track and disables playback")
            check(idle?.artwork == beforeStop?.artwork && idle?.artworkPalette == beforeStop?.artworkPalette, "Stopped music retains the last cover and palette")
            check(idle.flatMap { WidgetTimelinePolicy.expiry(of: $0, at: Date()) } != nil, "Retained cover expires without the app")
        }
        model.connected = false
        try await settle()
        check(store.read()?.state == .disconnected && store.read()?.canControl == false, "Disconnected widget hides playback controls")
        check(store.read()?.artwork == nil && store.read()?.artworkPalette == nil, "Disconnect discards the retained cover")
        check(!model.connected, "Passive demand does not opt a disabled player in")
        check(controller.storageError.isEmpty && controller.lastPublishedAt != nil, "Publication diagnostics reflect successful read-back")
        controller.stop()
        check(store.read() == nil, "Quit clears the shared media")
        try await settle()
        check(store.read() == nil, "No observer can republish after shutdown")
        let interrupted = FirstWidgetWrite()
        let stopStarted = DispatchSemaphore(value: 0)
        model.connected = true
        model.apply(["status": "ok", "source": "oruvi.system", "id": "first-write", "title": "Private media",
                     "duration": 120, "position": 1, "playing": true])
        let firstWrite = NativeWidgetController(model: model, resolveStore: {
            DispatchQueue.main.async {
                interrupted.stop()
                stopStarted.signal()
            }
            precondition(stopStarted.wait(timeout: .now() + 3) == .success)
            return store
        })
        interrupted.controller = firstWrite
        firstWrite.startForVerification {}
        try await settle()
        check(interrupted.didStop, "Shutdown overlapped first lookup of the cache container")
        check(store.read() == nil, "Shutdown removes a write even before its result reaches the main actor")

        let blockedPath = root.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: blockedPath)
        let resolutions = OSAllocatedUnfairLock(initialState: 0)
        let recovery = NativeWidgetController(model: model, resolveStore: {
            let attempt = resolutions.withLock { count in count += 1; return count }
            switch attempt {
            case 1: return WidgetSnapshotStore(directory: nil)
            case 2: return WidgetSnapshotStore(directory: blockedPath)
            default: return store
            }
        })
        defer { recovery.stop() }
        recovery.startForVerification {}
        try await settle()
        check(recovery.storageError.contains("no puso a disposición") && recovery.lastPublishedAt == nil,
              "A missing container has its own diagnostic")
        recovery.republishForVerification()
        try await settle()
        check(recovery.storageError.contains("guardar o verificar") && recovery.lastPublishedAt == nil,
              "A failed write is distinct from a missing container or denied access")
        recovery.republishForVerification()
        try await settle()
        check(resolutions.withLock { $0 } == 3 && recovery.storageError.isEmpty && recovery.lastPublishedAt != nil,
              "The next attempt resolves the container again after a write failure")
        check(store.read()?.trackID == "first-write", "Recovery writes the current media to the usable store")
        model.track = TrackIdentity(id: String(repeating: "a", count: 4097), title: "Invalid", artist: "", album: "", duration: 120)
        try await settle()
        check(recovery.storageError.contains("estado válido") && resolutions.withLock { $0 } == 3,
              "Invalid data is not diagnosed as denied access or a stale container")
        check(!recovery.sharingVerified && recovery.lastPublishedAt != nil &&
              recovery.connectionSummary == "Revisar sincronización",
              "An earlier successful publication cannot make a current synchronization failure look healthy")
        print("PASS: \(count) actual async widget pipeline checks, including bootstrap, enumeration races, cover, pause, sleep and shutdown.")
    }
}

@MainActor private final class FirstWidgetWrite {
    weak var controller: NativeWidgetController?
    private(set) var didStop = false

    func stop() {
        controller?.stop()
        didStop = true
    }
}
