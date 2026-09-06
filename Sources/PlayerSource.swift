import Foundation
import AppKit

enum PlayerSource: String, CaseIterable, Identifiable, Sendable {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"
    var id: String { rawValue }
    var name: String { self == .music ? "Apple Music" : "Spotify" }
    var symbol: String { self == .music ? "music.note" : "waveform" }
}
enum PlayerPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic, music, spotify
    var id: String { rawValue }
    var name: String { self == .automatic ? "Automático" : (self == .music ? "Apple Music" : "Spotify") }
    var source: PlayerSource? { self == .automatic ? nil : (self == .music ? .music : .spotify) }
}

/// Serialized on the existing playback queue. A provider that denies Automation is not
/// asked repeatedly; an explicit reconnect clears the denial. No account tokens or web API.
final class PlayerRouter: @unchecked Sendable {
    private var denied: Set<PlayerSource> = []
    func reset() { denied.removeAll(); LumaResetMusicBridge(); OruviResetSpotifyBridge() }
    func snapshot(preference: PlayerPreference, preferred: PlayerSource) -> [String: Any] {
        let sources = preference.source.map { [$0] } ?? [preferred, preferred == .music ? .spotify : .music]
        var results: [(PlayerSource, [String: Any])] = []
        for source in sources {
            guard !denied.contains(source) else { continue }
            var value = source == .music ? LumaReadMusicSnapshot() : OruviReadSpotifySnapshot()
            value["source"] = source.rawValue
            if value["status"] as? String == "denied" { denied.insert(source) }
            results.append((source, value))
            if value["status"] as? String == "ok", (value["playing"] as? NSNumber)?.boolValue == true {
                return value // Do not query the second player while the preferred one is playing.
            }
        }
        // The preferred source wins only while playing. A paused player cannot hide
        // playback from the other provider. No player is started by these reads.
        if let result = results.first(where: { $0.1["status"] as? String == "ok" && ($0.1["playing"] as? NSNumber)?.boolValue == true }) { return result.1 }
        if let result = results.first(where: { $0.1["status"] as? String == "ok" }) { return result.1 }
        if let result = results.first(where: { let status = $0.1["status"] as? String; return status == "transition" || status == "error" }) { return result.1 }
        if let result = results.first(where: { $0.1["status"] as? String == "stopped" }) { return result.1 }
        if !denied.isEmpty && results.allSatisfy({ ["notRunning", "denied"].contains($0.1["status"] as? String ?? "") }) {
            return ["status": "denied", "message": "Autoriza el reproductor en Privacidad y seguridad > Automatización y pulsa Reconectar."]
        }
        return ["status": "notRunning"]
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
