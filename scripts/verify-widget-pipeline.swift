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
        let colorspace = CGColorSpaceCreateDeviceRGB()
        let bitmap = CGContext(data: nil, width: 384, height: 384, bitsPerComponent: 8, bytesPerRow: 0, space: colorspace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 0.4, alpha: 1)); bitmap.fill(CGRect(x:0,y:0,width:384,height:384))
        model.artwork = NSImage(cgImage: bitmap.makeImage()!, size: NSSize(width:384,height:384))
        try await settle()
        let imageData = store.read()?.artwork
        check(imageData != nil, "Late artwork is published without changing the track")
        let image = imageData.flatMap { NSImage(data:$0) }
        check(image != nil && image!.size.width <= 192, "Published cover is decodable and bounded")
        model.apply(["status":"ok", "source":"oruvi.system", "id":"browser-B", "title":"Video B", "artist":"Channel B", "album":"", "duration":100, "position":0, "playing":false])
        try await settle()
        check(store.read()?.title == "Video B" && store.read()?.playing == false, "Track and pause propagate together")
        check(store.read()?.artwork == nil, "New title never inherits old cover")
        model.screenSleeping = true
        try await settle()
        check(store.read()?.state == .sleeping && store.read()?.artwork == nil, "Sleep removes media presentation")
        model.screenSleeping = false
        try await settle()
        check(store.read()?.title == "Video B", "Wake restores current state")
        model.connected = false
        try await settle()
        check(store.read()?.state == .disconnected && store.read()?.canRefresh == true, "Disconnected widget has an actionable recovery")
        check(!model.connected, "Passive demand does not opt a disabled player in")
        check(controller.storageError.isEmpty && controller.lastPublishedAt != nil, "Publication diagnostics reflect successful read-back")
        controller.stop()
        check(store.read() == nil, "Quit clears the shared media")
        try await settle()
        check(store.read() == nil, "No observer can republish after shutdown")
        print("PASS: \(count) actual async widget pipeline checks, including bootstrap, enumeration races, cover, pause, sleep and shutdown.")
    }
}
