// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import Foundation

enum PlayerSource: String, CaseIterable, Identifiable, Sendable {
    case music = "com.apple.Music", spotify = "com.spotify.client", system = "oruvi.system"
    var id: String { rawValue }
    var name: String { self == .system ? "Ahora suena" : (self == .music ? "Apple Music" : "Spotify") }
    var symbol: String { self == .system ? "play.rectangle" : (self == .music ? "music.note" : "waveform") }
}
enum PlayerPreference: String, CaseIterable, Identifiable, Sendable {
    case automatic, music, spotify
    var id: String { rawValue }
    var name: String { self == .automatic ? "Automático" : (self == .music ? "Apple Music" : "Spotify") }
    var source: PlayerSource? { self == .automatic ? nil : (self == .music ? .music : .spotify) }
}
enum PlaybackSurface: String, CaseIterable, Sendable {
    case notch, standby
    var title: String { self == .notch ? "Notch" : "Standby" }
    // Retain the existing Standby key so old settings and updates remain compatible.
    var preferenceKey: String { self == .notch ? "notchPlayerPreference" : "playerPreference" }
    var enabledKey: String { self == .notch ? "notchMusicEnabled" : "musicEnabled" }
}
struct SurfacePlaybackPreferences {
    private(set) var notch: PlayerPreference
    private(set) var standby: PlayerPreference
    init(defaults: UserDefaults) {
        let legacy = PlayerPreference(rawValue: defaults.string(forKey: "playerPreference") ?? "") ?? .automatic
        if defaults.object(forKey: PlaybackSurface.notch.preferenceKey) == nil {
            defaults.set(legacy.rawValue, forKey: PlaybackSurface.notch.preferenceKey)
        }
        if defaults.object(forKey: PlaybackSurface.notch.enabledKey) == nil {
            defaults.set(defaults.bool(forKey: PlaybackSurface.standby.enabledKey), forKey: PlaybackSurface.notch.enabledKey)
        }
        notch = PlayerPreference(rawValue: defaults.string(forKey: PlaybackSurface.notch.preferenceKey) ?? "") ?? .automatic
        standby = legacy
    }
    func preference(for surface: PlaybackSurface) -> PlayerPreference { surface == .notch ? notch : standby }
    mutating func set(_ value: PlayerPreference, for surface: PlaybackSurface, defaults: UserDefaults) {
        if surface == .notch { notch = value } else { standby = value }
        defaults.set(value.rawValue, forKey: surface.preferenceKey)
    }
}
struct PlayerCandidate: Equatable {
    let source: PlayerSource
    let status: String
    let playing: Bool
}
enum PlayerSelectionPolicy {
    static func options(installed: Set<PlayerSource>) -> [PlayerPreference] {
        [.automatic] + PlayerPreference.allCases.filter { $0.source.map(installed.contains) ?? false }
    }
    /// A newly playing provider wins; otherwise keep a stable tie-breaker when both
    /// really play. A paused application must never mask a playing one.
    static func choose(_ candidates: [PlayerCandidate], preference: PlayerPreference,
                       preferred: PlayerSource, previouslyPlaying: Set<PlayerSource>) -> PlayerSource? {
        if let explicit = preference.source { return candidates.first { $0.source == explicit }?.source }
        let playing = candidates.filter { $0.status == "ok" && $0.playing }
        let newlyPlaying = playing.filter { !previouslyPlaying.contains($0.source) }
        for group in [newlyPlaying, playing, candidates.filter({ $0.status == "ok" })] where !group.isEmpty {
            return group.first(where: { $0.source == preferred })?.source ?? group[0].source
        }
        return nil
    }
}
