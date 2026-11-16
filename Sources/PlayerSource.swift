import Foundation
import AppKit

/// Serialized on the existing playback queue. Explicit selections still use the
/// public Apple Events bridges; Automatic follows macOS's active media session.
final class PlayerRouter: @unchecked Sendable {
    private var denied: Set<PlayerSource> = []
    private var previouslyPlaying: Set<PlayerSource> = []
    private var lastAutomaticSource: PlayerSource?
    func reset() {
        denied.removeAll(); previouslyPlaying.removeAll(); lastAutomaticSource = nil
        LumaResetMusicBridge(); OruviResetSpotifyBridge()
    }
    private func native(_ source: PlayerSource) -> [String: Any] {
        guard source != .system else { return ["status": "notRunning"] }
        guard !denied.contains(source) else { return ["status": "denied", "source": source.rawValue] }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: source.rawValue).isEmpty else {
            return ["status": "notRunning", "source": source.rawValue]
        }
        var value = source == .music ? LumaReadMusicSnapshot() : OruviReadSpotifySnapshot()
        value["source"] = source.rawValue
        if value["status"] as? String == "denied" { denied.insert(source) }
        return value
    }
    func snapshot(preference: PlayerPreference, preferred: PlayerSource, refreshSystem: Bool = false) -> [String: Any] {
        let system = refreshSystem && preference == .automatic ? SystemMediaBridge.shared.readNow() : SystemMediaBridge.shared.current
        return resolve(preference: preference, preferred: preferred, system: system)
    }
    private func resolve(preference: PlayerPreference, preferred: PlayerSource,
                         system: SystemMediaSnapshot?) -> [String: Any] {
        if let explicit = preference.source { return native(explicit) }
        // Follow the same session as Control Center, not the frontmost window.
        var stoppedSession: PlayerSource?
        if let system {
            if let source = PlayerSource(rawValue: system.bundleID), source != .system {
                var value = native(source)
                if value["status"] as? String == "ok" {
                    let duration = (value["duration"] as? NSNumber)?.doubleValue ?? 0
                    if let artwork = system.artwork,
                       RecordingMatcher.normalized(value["title"] as? String ?? "") == RecordingMatcher.normalized(system.title),
                       RecordingMatcher.normalized(value["artist"] as? String ?? "") == RecordingMatcher.normalized(system.artist),
                       RecordingMatcher.normalized(value["album"] as? String ?? "") == RecordingMatcher.normalized(system.album),
                       abs(duration - system.duration) <= 2.1 {
                        value["systemArtwork"] = artwork
                    }
                    return value
                }
                // A stopped player can remain in the system cache during a queue transition.
                // Keep checking the other player instead of publishing the cached song again.
                if value["status"] as? String == "stopped" { stoppedSession = source }
            }
            if stoppedSession == nil { return system.dictionary(at: ProcessInfo.processInfo.systemUptime) }
        }
        // A missing/private API must never remove the existing native integrations.
        let tie = lastAutomaticSource ?? preferred
        let preferred: PlayerSource = tie == .system ? .music : tie
        let sources: [PlayerSource] = [preferred, preferred == .music ? .spotify : .music]
        let results = sources.map { source in
            (source, source == stoppedSession ? ["status": "stopped"] : native(source))
        }
        let candidates = results.map { PlayerCandidate(source: $0.0, status: $0.1["status"] as? String ?? "error",
                                                       playing: ($0.1["playing"] as? NSNumber)?.boolValue ?? false) }
        let chosen = PlayerSelectionPolicy.choose(candidates, preference: .automatic, preferred: preferred, previouslyPlaying: previouslyPlaying)
        if let chosen { lastAutomaticSource = chosen }
        for candidate in candidates {
            if candidate.status == "ok" {
                if candidate.playing { previouslyPlaying.insert(candidate.source) }
                else { previouslyPlaying.remove(candidate.source) }
            } else if ["stopped", "notRunning", "denied"].contains(candidate.status) {
                previouslyPlaying.remove(candidate.source)
            }
        }
        if let chosen, let result = results.first(where: { $0.0 == chosen }) { return result.1 }
        for state in ["transition", "error", "stopped"] {
            if let result = results.first(where: { $0.1["status"] as? String == state }) { return result.1 }
        }
        return ["status": "notRunning"]
    }
    func command(_ command: String, position: Double, source: PlayerSource,
                 preference: PlayerPreference, expectedTrackID: String, requireSameTrack: Bool = false) -> [String: Any] {
        let displayed = PlaybackCommandTarget(source: source, trackID: expectedTrackID)
        if source == .system, preference == .automatic {
            // Now Playing commands are global. Validate the displayed item immediately
            // before dispatch, even when another tab uses the same browser.
            return SystemMediaBridge.shared.send(command, position: position, target: displayed)
        }
        let system = preference == .automatic ? SystemMediaBridge.shared.readNow() : nil
        let current = resolve(preference: preference, preferred: source, system: system)
        guard current["status"] as? String == "ok",
              let target = PlayerSource(rawValue: current["source"] as? String ?? "") else { return current }
        guard displayed.matches(source: target, trackID: current["id"] as? String,
                                requireSameTrack: command == "seek" || requireSameTrack) else {
            return ["status": "transition", "message": "El contenido cambió. Vuelve a pulsar el control."]
        }
        switch target {
        case .music: return LumaMusicCommand(command, position)
        case .spotify: return OruviSpotifyCommand(command, position)
        case .system: return ["status": "notRunning"]
        }
    }
}

enum LyricsAvailability: Equatable {
    case idle, loading, ready, unavailable, offline, disabled
}
