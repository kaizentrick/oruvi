import Foundation
import AppKit

/// Serialized on the existing playback queue. Only the visible surface is sampled;
/// Notch and Standby persist independent preferences. No account tokens or web API.
final class PlayerRouter: @unchecked Sendable {
    private var denied: Set<PlayerSource> = []
    private var previouslyPlaying: Set<PlayerSource> = []
    private var lastAutomaticSource: PlayerSource?
    func reset() {
        denied.removeAll(); previouslyPlaying.removeAll(); lastAutomaticSource = nil
        LumaResetMusicBridge(); OruviResetSpotifyBridge()
    }
    func snapshot(preference: PlayerPreference, preferred: PlayerSource) -> [String: Any] {
        let preferred = preference == .automatic ? (lastAutomaticSource ?? preferred) : preferred
        let sources = preference.source.map { [$0] } ?? [preferred, preferred == .music ? .spotify : .music]
        var results: [(PlayerSource, [String: Any])] = []
        for source in sources {
            guard !denied.contains(source) else {
                results.append((source, ["status": "denied", "source": source.rawValue])); continue
            }
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: source.rawValue).isEmpty else {
                results.append((source, ["status": "notRunning", "source": source.rawValue])); continue
            }
            var value = source == .music ? LumaReadMusicSnapshot() : OruviReadSpotifySnapshot()
            value["source"] = source.rawValue
            if value["status"] as? String == "denied" { denied.insert(source) }
            results.append((source, value))
        }
        let candidates = results.map { PlayerCandidate(source: $0.0, status: $0.1["status"] as? String ?? "error",
                                                       playing: ($0.1["playing"] as? NSNumber)?.boolValue ?? false) }
        let chosen = PlayerSelectionPolicy.choose(candidates, preference: preference, preferred: preferred, previouslyPlaying: previouslyPlaying)
        if preference == .automatic {
            // A freshly resolved button target must remain the tie-breaker for the
            // next UI sample, even if both players are still playing after Next.
            if let chosen { lastAutomaticSource = chosen }
            for candidate in candidates {
                if candidate.status == "ok" {
                    if candidate.playing { previouslyPlaying.insert(candidate.source) }
                    else { previouslyPlaying.remove(candidate.source) }
                } else if ["stopped", "notRunning", "denied"].contains(candidate.status) {
                    previouslyPlaying.remove(candidate.source)
                }
            }
        }
        if let chosen, let result = results.first(where: { $0.0 == chosen }) { return result.1 }
        for state in ["transition", "error", "stopped"] {
            if let result = results.first(where: { $0.1["status"] as? String == state }) { return result.1 }
        }
        if preference != .automatic, !denied.isEmpty {
            return ["status": "denied", "message": "Autoriza el reproductor en Privacidad y seguridad > Automatización y pulsa Reconectar."]
        }
        // One denied provider never disables Automatic for the other provider.
        return ["status": "notRunning"]
    }
    func command(_ command: String, position: Double, source: PlayerSource,
                 preference: PlayerPreference, expectedTrackID: String) -> [String: Any] {
        // Resolve at click time, rather than using an old 3–8 second UI sample.
        let current = snapshot(preference: preference, preferred: source)
        guard current["status"] as? String == "ok",
              let target = PlayerSource(rawValue: current["source"] as? String ?? "") else { return current }
        if command == "seek" && (target != source || current["id"] as? String != expectedTrackID) {
            return ["status": "transition", "message": "La canción cambió; vuelve a ajustar su posición."]
        }
        return self.command(command, position: position, source: target)
    }
    func command(_ command: String, position: Double, source: PlayerSource) -> [String: Any] {
        source == .music ? LumaMusicCommand(command, position) : OruviSpotifyCommand(command, position)
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
