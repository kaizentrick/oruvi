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

enum WidgetPlaybackState: String, Codable, Sendable {
    case ready, idle, disconnected, sleeping, closed, unavailable, stale
}

/// A single current presentation, never a listening history. Keep schema 1 so
/// an installed 0.10.0 widget can read an existing ready snapshot during update.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    var schema = 1
    var generatedAt = Date()
    var session = ""
    var state: WidgetPlaybackState = .closed
    var trackID = ""
    var sourceID = ""
    var preference = "automatic"
    var title = "Conectar Oruvi"
    var artist = "Pulsa Conectar para actualizar la música."
    var sourceName = "Automático"
    var playing = false
    var canSkip = true
    var artwork: Data?
    var message = ""
    static let maximumArtworkBytes = 256 * 1024
    static let maximumFileBytes = 512 * 1024
    static let maximumAge: TimeInterval = 3600

    var canControl: Bool { state == .ready && !trackID.isEmpty && !session.isEmpty }
    var canRefresh: Bool { state != .sleeping }
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

/// Do not disguise a denied/corrupt/expired read as "the app is closed".
enum WidgetSnapshotRead: Equatable, Sendable {
    case value(WidgetSnapshot), missing, unavailable, invalid, expired
    func presentation(at date: Date = Date()) -> WidgetSnapshot {
        if case .value(let snapshot) = self { return snapshot }
        var value = WidgetSnapshot(); value.generatedAt = date
        switch self {
        case .unavailable:
            value.state = .unavailable; value.title = "Revisa el acceso de Oruvi"
            value.artist = "Abre los ajustes de Oruvi para revisar los datos compartidos."
        case .invalid:
            value.state = .unavailable; value.title = "Actualizar Oruvi"
            value.artist = "No se pudo leer el estado. Pulsa Actualizar."
        case .expired:
            value.state = .stale; value.title = "Actualizar reproducción"
            value.artist = "Pulsa Actualizar para recuperar el contenido actual."
        default: break
        }
        return value
    }
}

struct WidgetSnapshotStore: Sendable {
    let directory: URL?
    init(directory: URL?) { self.directory = directory }
    static func shared() -> Self {
        let group = Bundle.main.object(forInfoDictionaryKey: "OruviWidgetAppGroup") as? String ?? OruviWidgetIdentity.appGroup
        // Use the OS-authorized container only. Never fall back to another app's
        // container, Full Disk Access, a public folder or a localhost web server.
        let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        return Self(directory: root?.appendingPathComponent("Library/Caches/OruviWidget", isDirectory: true))
    }
    var file: URL? { directory?.appendingPathComponent("now-playing.json") }
    func load(at date: Date = Date()) -> WidgetSnapshotRead {
        guard let file else { return .unavailable }
        do {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= WidgetSnapshot.maximumFileBytes else { return .invalid }
            let data = try Data(contentsOf: file)
            guard data.count <= WidgetSnapshot.maximumFileBytes,
                  let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data) else { return .invalid }
            guard snapshot.isValid(at: date) else {
                return snapshot.isValid(at: snapshot.generatedAt) && date.timeIntervalSince(snapshot.generatedAt) > WidgetSnapshot.maximumAge ? .expired : .invalid
            }
            return .value(snapshot)
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return .missing }
            if error.domain == NSPOSIXErrorDomain && error.code == 2 { return .missing }
            return .unavailable
        }
    }
    func read(at date: Date = Date()) -> WidgetSnapshot? {
        if case .value(let value) = load(at: date) { return value }; return nil
    }
    func write(_ snapshot: WidgetSnapshot) throws {
        guard snapshot.isValid(at: Date()), let directory, let file else { throw StoreError.unavailable }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= WidgetSnapshot.maximumFileBytes else { throw StoreError.oversized }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw StoreError.unavailable }
        if let previous = try? file.resourceValues(forKeys: [.isSymbolicLinkKey]), previous.isSymbolicLink == true { throw StoreError.unavailable }
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var excluded = URLResourceValues(); excluded.isExcludedFromBackup = true
        var target = directory; try? target.setResourceValues(excluded)
    }
    func clear() { if let file { try? FileManager.default.removeItem(at: file) } }
    enum StoreError: Error { case unavailable, oversized }
}

struct WidgetPublicationPolicy {
    private(set) var previous: WidgetSnapshot?
    private(set) var lastWrite: Date?
    private(set) var lastReload: Date?
    mutating func record(_ value: WidgetSnapshot, reload: Bool) {
        previous = value; lastWrite = value.generatedAt
        if reload { lastReload = value.generatedAt }
    }
    mutating func recordReload(at now: Date) { lastReload = now }
    func needsWrite(_ value: WidgetSnapshot, force: Bool = false) -> Bool {
        force || (previous.map { !value.samePresentation(as: $0) } ?? true) ||
        value.generatedAt.timeIntervalSince(lastWrite ?? .distantPast) >= 600
    }
    func reloadDelay(at now: Date) -> TimeInterval { max(0, 5 - now.timeIntervalSince(lastReload ?? .distantPast)) }
}

/// WidgetCenter enumeration can lag behind getTimeline. A metadata-free demand
/// hint keeps an existing connection eligible, but NEVER connects a disabled
/// player. Gallery previews do not send demand. No permanent placement flag.
struct WidgetPresencePolicy {
    static let lease: TimeInterval = 20 * 60
    private(set) var count = 0
    private(set) var requestedAt: Date?
    mutating func receivedRequest(at date: Date) { requestedAt = date }
    mutating func receivedCount(_ value: Int) { count = max(0, value) }
    func active(at now: Date) -> Bool {
        count > 0 || requestedAt.map { (0...Self.lease).contains(now.timeIntervalSince($0)) } == true
    }
}
