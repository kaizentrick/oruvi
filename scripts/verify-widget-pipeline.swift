import AppKit

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
        let controller = NativeWidgetController(model: model)
        defer {
            controller.stop(); model.shutdown(); LumaEnvironment.cleanTestingData()
            try? FileManager.default.removeItem(at: root)
        }
        model.connected = true
        model.apply(["status":"ok", "source":"oruvi.system", "id":"browser-A", "title":"Video A", "artist":"Channel A", "album":"", "duration":100, "position":12, "playing":true])
        controller.startForVerification(store: store) { reloads += 1 }
        try await settle()
        check(store.read()?.title == "Video A", "Bootstrap writes before WidgetCenter reports any widgets")
        check(store.read()?.displaySourceName == "Ahora suena", "The widget source label omits the automatic selection mode")
        check(store.read()?.playing == true, "Playback state crosses actual async pipeline")
        check(reloads == 1, "First reload occurs only after verified write")
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
        model.apply(["status":"ok", "source":"oruvi.system", "id":"browser-B", "title":"Video B", "artist":"Channel B", "album":"", "duration":100, "position":0, "playing":false])
        try await settle()
        check(store.read()?.title == "Video B" && store.read()?.playing == false, "Track and pause propagate together")
        check(store.read()?.artwork == nil, "New title never inherits old cover")
        check(store.read()?.artworkPalette == nil, "New title never inherits old cover colors")
        model.screenSleeping = true
        try await settle()
        check(store.read()?.state == .sleeping && store.read()?.artwork == nil && store.read()?.artworkPalette == nil, "Sleep removes media presentation")
        model.screenSleeping = false
        try await settle()
        check(store.read()?.title == "Video B", "Wake restores current state")
        for source in ["com.apple.Music", "com.spotify.client"] {
            model.track = TrackIdentity(id: source, title: "Song", artist: "Artist", album: "Album", duration: 100, sourceID: source)
            model.activePlayer = PlayerSource(rawValue: source)!
            model.anchor.playing = true
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
        print("PASS: \(count) actual async widget pipeline checks, including bootstrap, enumeration races, cover, pause, sleep and shutdown.")
    }
}
