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
    func snapshot(preference: PlayerPreference, preferred: PlayerSource) -> [String: Any] {
        resolve(preference: preference, preferred: preferred, system: SystemMediaBridge.shared.current)
    }
    private func resolve(preference: PlayerPreference, preferred: PlayerSource,
                         system: SystemMediaSnapshot?) -> [String: Any] {
        if let explicit = preference.source { return native(explicit) }
        // Follow the same session as Control Center, not the frontmost window.
        if let system {
            if let source = PlayerSource(rawValue: system.bundleID), source != .system {
                let value = native(source)
                if value["status"] as? String == "ok" { return value }
            }
            return system.dictionary(at: ProcessInfo.processInfo.systemUptime)
        }
        // A missing/private API must never remove the existing native integrations.
        let tie = lastAutomaticSource ?? preferred
        let preferred: PlayerSource = tie == .system ? .music : tie
        let sources: [PlayerSource] = [preferred, preferred == .music ? .spotify : .music]
        let results = sources.map { ($0, native($0)) }
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
                 preference: PlayerPreference, expectedTrackID: String) -> [String: Any] {
        let system = preference == .automatic ? SystemMediaBridge.shared.readNow() : nil
        // If a visible system session cannot be revalidated, fail rather than
        // accidentally pausing Music/Spotify behind a browser video.
        if preference == .automatic, source == .system, system == nil {
            return ["status": "transition", "message": "El sistema está actualizando el contenido. Vuelve a intentarlo."]
        }
        let current = resolve(preference: preference, preferred: source, system: system)
        guard current["status"] as? String == "ok",
              let target = PlayerSource(rawValue: current["source"] as? String ?? "") else { return current }
        if command == "seek" && (target != source || current["id"] as? String != expectedTrackID) {
            return ["status": "transition", "message": "El contenido cambió; vuelve a ajustar su posición."]
        }
        if target == .system, let system {
            return SystemMediaBridge.shared.send(command, position: position, expected: system)
        }
        return self.command(command, position: position, source: target)
    }
    func command(_ command: String, position: Double, source: PlayerSource) -> [String: Any] {
        switch source {
        case .music: return LumaMusicCommand(command, position)
        case .spotify: return OruviSpotifyCommand(command, position)
        case .system:
            guard let current = SystemMediaBridge.shared.readNow() else { return ["status": "notRunning"] }
            return SystemMediaBridge.shared.send(command, position: position, expected: current)
        }
    }
}

enum LyricsAvailability: Equatable {
    case idle, loading, ready, unavailable, offline, disabled
    var notification: String {
        switch self {
        case .ready: return ""
        case .loading, .idle: return "Buscando la letra de esta canción…"
        case .offline: return "No se pudo consultar la letra. Se reintentará automáticamente."
        case .disabled: return "Activa las letras automáticas en Ajustes o importa un archivo LRC."
        case .unavailable: return "Esta canción no tiene letra sincronizada disponible."
        }
    }
}
