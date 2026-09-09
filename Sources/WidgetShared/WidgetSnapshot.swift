// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import Foundation

enum OruviWidgetIdentity {
    static let kind = "com.kaizentrick.Oruvi.NowPlaying"
    static let extensionID = "com.kaizentrick.Oruvi.Widgets"
    static let appGroup = "group.com.kaizentrick.Oruvi"
    static let requested = "com.kaizentrick.Oruvi.widget.requested"
    static let standbyURL = URL(string: "oruvi://standby")!
    static let settingsURL = URL(string: "oruvi://widgets")!
}

enum WidgetPlaybackState: String, Codable, Sendable { case ready, idle, disconnected, sleeping, closed }

/// One current presentation, not a listening history. Artwork and metadata are
/// in the same atomic file so a new title can never get the previous cover.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    var schema = 1
    var generatedAt = Date()
    var session = ""
    var state: WidgetPlaybackState = .closed
    var trackID = ""
    var sourceID = ""
    var preference = "automatic"
    var title = "Oruvi"
    var artist = "Abre Oruvi para conectar la música"
    var sourceName = "Automático"
    var playing = false
    var canSkip = true
    var artwork: Data?
    var message = ""
    static let maximumArtworkBytes = 256 * 1024
    static let maximumFileBytes = 512 * 1024
    static let maximumAge: TimeInterval = 3600

    var canControl: Bool { state == .ready && !trackID.isEmpty && !session.isEmpty }
    func isValid(at now: Date) -> Bool {
        schema == 1 && generatedAt.timeIntervalSince1970.isFinite &&
        now.timeIntervalSince(generatedAt) >= -60 && now.timeIntervalSince(generatedAt) <= Self.maximumAge &&
        ["automatic", "music", "spotify"].contains(preference) &&
        [session, trackID, sourceID, title, artist, sourceName, message].allSatisfy { $0.utf8.count <= 4096 } &&
        (artwork?.count ?? 0) <= Self.maximumArtworkBytes
    }
    func samePresentation(as other: Self) -> Bool {
        var lhs = self, rhs = other
        lhs.generatedAt = .distantPast; rhs.generatedAt = .distantPast
        return lhs == rhs
    }
    static func placeholder(at date: Date = Date()) -> Self {
        var value = Self(); value.generatedAt = date; value.title = "Tu música"; value.artist = "Portada y controles"; value.sourceName = "Oruvi"
        return value
    }
}

struct WidgetSnapshotStore: Sendable {
    let directory: URL?
    init(directory: URL?) { self.directory = directory }
    static func shared() -> Self {
        let group = Bundle.main.object(forInfoDictionaryKey: "OruviWidgetAppGroup") as? String ?? OruviWidgetIdentity.appGroup
        // No manual Library/Group Containers path and no fallback outside sandbox.
        let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        return Self(directory: root?.appendingPathComponent("Library/Caches/OruviWidget", isDirectory: true))
    }
    var file: URL? { directory?.appendingPathComponent("now-playing.json") }
    func read(at date: Date = Date()) -> WidgetSnapshot? {
        guard let file,
              let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= WidgetSnapshot.maximumFileBytes,
              let data = try? Data(contentsOf: file), data.count <= WidgetSnapshot.maximumFileBytes,
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data), snapshot.isValid(at: date) else { return nil }
        return snapshot
    }
    func write(_ snapshot: WidgetSnapshot) throws {
        guard snapshot.isValid(at: Date()), let directory, let file else { throw StoreError.unavailable }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= WidgetSnapshot.maximumFileBytes else { throw StoreError.oversized }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw StoreError.unavailable }
        // Reject a replaced destination rather than following links across containers.
        if let previous = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]), previous.isSymbolicLink == true { throw StoreError.unavailable }
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var target = directory; try? target.setResourceValues(excluded)
    }
    func clear() { if let file { try? FileManager.default.removeItem(at: file) } }
    enum StoreError: Error { case unavailable, oversized }
}

/// A bounded policy shared by the host and its tests. No polling timer is needed
/// by the widget; only changed presentations request reloads, coalesced at 5 s.
struct WidgetPublicationPolicy {
    private(set) var previous: WidgetSnapshot?
    private(set) var lastWrite: Date?
    private(set) var lastReload: Date?
    mutating func record(_ value: WidgetSnapshot, reload: Bool) {
        previous = value; lastWrite = value.generatedAt
        if reload { lastReload = value.generatedAt }
    }
    func needsWrite(_ value: WidgetSnapshot, force: Bool = false) -> Bool {
        force || (previous.map { !value.samePresentation(as: $0) } ?? true) ||
        value.generatedAt.timeIntervalSince(lastWrite ?? .distantPast) >= 600
    }
    func reloadDelay(at now: Date) -> TimeInterval {
        max(0, 5 - now.timeIntervalSince(lastReload ?? .distantPast))
    }
}
