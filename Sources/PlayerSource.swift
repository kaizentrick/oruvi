import Foundation
import AppKit

/// Serialized on the existing playback queue. Explicit selections still use the
/// public Apple Events bridges; Automatic follows macOS's active media session.
final class PlayerRouter: @unchecked Sendable {
    private var denials: [PlayerSource: [String: Any]] = [:]
    private var previouslyPlaying: Set<PlayerSource> = []
    private var lastAutomaticSource: PlayerSource?
    private var snapshotSequence: UInt64 = 0
    private let isRunning: (PlayerSource) -> Bool
    private let readNative: (PlayerSource) -> [String: Any]

    init(isRunning: @escaping (PlayerSource) -> Bool = {
        NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).contains { !$0.isTerminated }
    }, readNative: @escaping (PlayerSource) -> [String: Any] = {
        $0 == .music ? LumaReadMusicSnapshot() : OruviReadSpotifySnapshot()
    }) {
        self.isRunning = isRunning
        self.readNative = readNative
    }
    func reset() {
        denials.removeAll(); previouslyPlaying.removeAll(); lastAutomaticSource = nil
        LumaResetMusicBridge(); OruviResetSpotifyBridge()
    }
    private func native(_ source: PlayerSource) -> [String: Any] {
        guard source != .system else { return ["status": "notRunning"] }
        guard isRunning(source) else {
            return ["status": "notRunning", "source": source.rawValue]
        }
        if let denial = denials[source] { return denial }
        var value = readNative(source)
        value["source"] = source.rawValue
        if value["status"] as? String == "denied" { denials[source] = value }
        return value
    }
    func snapshot(preference: PlayerPreference, preferred: PlayerSource, refreshSystem: Bool = false) -> [String: Any] {
        let system = refreshSystem && preference == .automatic ? SystemMediaBridge.shared.readNow() : SystemMediaBridge.shared.current
        var snapshot = resolve(preference: preference, preferred: preferred, system: system)
        // Widget intents and timer reads return through different MainActor entry points.
        // Order every result on the playback queue, including errors and stopped states.
        snapshotSequence += 1
        snapshot["playbackSequence"] = snapshotSequence
        return snapshot
    }
    func resolve(preference: PlayerPreference, preferred: PlayerSource,
                 system: SystemMediaSnapshot?) -> [String: Any] {
        if let explicit = preference.source { return native(explicit) }
        // Follow the same session as Control Center, not the frontmost window.
        var inactiveSession: (source: PlayerSource, snapshot: [String: Any])?
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
                // Now Playing may still report a recording after its player stopped or quit.
                // Keep the native result and check the other player before displaying anything.
                switch value["status"] as? String {
                case "stopped", "notRunning": inactiveSession = (source, value)
                default: break
                }
            }
            if inactiveSession == nil { return system.dictionary(at: ProcessInfo.processInfo.systemUptime) }
        }
        // A missing/private API must never remove the existing native integrations.
        let tie = lastAutomaticSource ?? preferred
        let preferred: PlayerSource = tie == .system ? .music : tie
        let sources: [PlayerSource] = [preferred, preferred == .music ? .spotify : .music]
        let results = sources.map { source in
            (source, inactiveSession.flatMap { $0.source == source ? $0.snapshot : nil } ?? native(source))
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
        if displayed.canSendDirectly(command, preference: preference, requireSameTrack: requireSameTrack) {
            return sendNative(command, position: position, to: source, checkPlayerState: true)
        }
        let system = preference == .automatic ? SystemMediaBridge.shared.readNow(includeArtwork: false) : nil
        let current = resolve(preference: preference, preferred: source, system: system)
        guard current["status"] as? String == "ok",
              let target = PlayerSource(rawValue: current["source"] as? String ?? "") else { return current }
        guard displayed.matches(source: target, trackID: current["id"] as? String,
                                requireSameTrack: command == "seek" || requireSameTrack) else {
            return ["status": "transition", "message": "El contenido cambió. Vuelve a pulsar el control."]
        }
        return sendNative(command, position: position, to: target)
    }
    private func sendNative(_ command: String, position: Double, to source: PlayerSource, checkPlayerState: Bool = false) -> [String: Any] {
        guard source != .system else { return ["status": "notRunning"] }
        if let denial = denials[source] { return denial }
        var result = source == .music
            ? LumaMusicCommand(command, position, checkPlayerState)
            : OruviSpotifyCommand(command, position, checkPlayerState)
        result["source"] = source.rawValue
        if result["status"] as? String == "denied" { denials[source] = result }
        return result
    }
}

enum LyricsAvailability: Equatable {
    case idle, loading, ready, unavailable, offline, disabled
}
