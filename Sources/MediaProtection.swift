import Foundation
import AppKit
import CoreAudio
import IOKit.pwr_mgt

/// Only process state and power assertions are inspected. No audio tap, sample buffer,
/// microphone, window capture, browser script, URL or browsing-history access.
struct MediaActivitySample: Sendable {
    var displayHeld = false
    var otherAudio = false
    var foregroundBrowser = false
    var foregroundPlayer = false
    var assertionsAvailable = true
    var audioAvailable = true
    var reason: String {
        if displayHeld { return "Una app está manteniendo la pantalla activa" }
        if otherAudio { return "Hay reproducción de audio fuera de Música" }
        if foregroundPlayer { return "Reproductor de vídeo en primer plano" }
        if foregroundBrowser { return "Navegador en primer plano · protección conservadora" }
        return "No se pudo comprobar la reproducción"
    }
    func shouldProtect(enabled: Bool, conservativeBrowsers: Bool) -> Bool {
        guard enabled else { return false }
        return displayHeld || otherAudio || (conservativeBrowsers && (foregroundBrowser || foregroundPlayer)) || (!assertionsAvailable && !audioAvailable)
    }
}

enum MediaProtection {
    static func isBrowser(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return ["com.apple.safari", "com.google.chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.browser", "com.operasoftware.opera", "company.thebrowser.browser", "company.thebrowser.dia", "com.vivaldi.vivaldi", "app.zen-browser.zen", "com.kagi.kagimacOS".lowercased(), "com.openai.atlas"].contains { id == $0 || id.hasPrefix($0 + ".") }
    }
    static func isVideoPlayer(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return ["com.apple.tv", "com.apple.quicktimeplayerx", "org.videolan.vlc", "com.colliderli.iina", "tv.plex.desktop", "com.hbo.hbonow", "com.wbd.stream", "com.burbn.instagram"].contains { id == $0 || id.hasPrefix($0 + ".") }
    }
    static func ignoredAudio(_ bundleID: String, pid: Int32, ownPID: Int32) -> Bool {
        let id = bundleID.lowercased()
        return pid == ownPID || (id == "com.apple.music" || id.hasPrefix("com.apple.music.")) || id == "com.apple.controlcenter" || id == "com.apple.systemuiserver" || id == "com.apple.speech.speechsynthesisd"
    }
    static func needsFreshIdlePeriod(idle: Double, now: Double, lastProtected: Double) -> Bool {
        // Do not add a second full interval when the person has already used input since playback.
        idle > max(0, now - lastProtected) + 1
    }
    static func sample(frontmostBundleID: String, ownPID: Int32) -> MediaActivitySample {
        var result = MediaActivitySample()
        result.foregroundBrowser = isBrowser(frontmostBundleID)
        result.foregroundPlayer = isVideoPlayer(frontmostBundleID)
        var assertions: Unmanaged<CFDictionary>?
        let status = IOPMCopyAssertionsByProcess(&assertions)
        result.assertionsAvailable = status == kIOReturnSuccess
        if let raw = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]] {
            for (pid, entries) in raw where pid.int32Value != ownPID {
                for entry in entries {
                    let type = entry[kIOPMAssertionTypeKey] as? String ?? ""
                    let level = (entry[kIOPMAssertionLevelKey] as? NSNumber)?.intValue ?? 0
                    if level > 0 && (type == kIOPMAssertionTypePreventUserIdleDisplaySleep || type == "NoDisplaySleepAssertion") {
                        result.displayHeld = true
                        break
                    }
                }
                if result.displayHeld { break }
            }
        }
        // Audio process state is public on the macOS version required by this app.
        // Listening to Apple Music alone must not disable a music-oriented standby.
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &bytes) == noErr, bytes <= 65536 else {
            result.audioAvailable = false; return result
        }
        var processes = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        guard !processes.isEmpty else { return result }
        let read = processes.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(system, &address, 0, nil, &bytes, buffer.baseAddress!)
        }
        guard read == noErr else { result.audioAvailable = false; return result }
        for object in processes.prefix(Int(bytes) / MemoryLayout<AudioObjectID>.size) {
            guard uintProperty(object, kAudioProcessPropertyIsRunningOutput) == 1 else { continue }
            let pid = Int32(bitPattern: uintProperty(object, kAudioProcessPropertyPID) ?? 0)
            let bundle = stringProperty(object, kAudioProcessPropertyBundleID) ?? ""
            if !ignoredAudio(bundle, pid: pid, ownPID: ownPID) { result.otherAudio = true; break }
        }
        return result
    }
    private static func uintProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }
    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// Shared by live settings and tests. Invalid input never reaches Int(), timers or geometry.
enum SafePreference {
    static func number(_ value: Double, range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
}
