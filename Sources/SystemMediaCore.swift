// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import Foundation

/// A bounded, complete snapshot from the system's active Now Playing session.
/// No URLs are fetched and no history is persisted by this transport.
struct SystemMediaSnapshot: Equatable, Sendable {
    let id: String
    let bundleID: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let elapsed: Double
    let sampledAt: Double
    let playing: Bool
    let rate: Double
    let artwork: Data?
    let prohibitsSkip: Bool

    init?(payload: [String: Any], uptime: Double, epoch: Double) {
        func text(_ key: String) -> String {
            String((payload[key] as? String ?? "").prefix(4096))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parent = text("parentApplicationBundleIdentifier")
        let bundle = parent.isEmpty ? text("bundleIdentifier") : parent
        guard Self.validBundleID(bundle), payload["playing"] is NSNumber,
              uptime.isFinite, epoch.isFinite else { return nil }
        bundleID = bundle
        let reportedTitle = text("title")
        title = reportedTitle.isEmpty ? "Contenido en reproducción" : reportedTitle
        artist = text("artist"); album = text("album")
        playing = (payload["playing"] as? NSNumber)?.boolValue ?? false
        func seconds(_ key: String) -> Double {
            let value = (payload[key] as? NSNumber)?.doubleValue ?? 0
            return value.isFinite ? max(0, value / 1_000_000) : 0
        }
        duration = min(seconds("durationMicros"), 86_399)
        let reportedRate = (payload["playbackRate"] as? NSNumber)?.doubleValue ?? 1
        rate = reportedRate.isFinite ? min(16, max(0, reportedRate)) : 1
        let timestamp = seconds("timestampEpochMicros")
        // Never extrapolate an unbounded wall-clock delta after clock changes.
        let age = timestamp > 0 ? min(30, max(0, epoch - timestamp)) : 0
        let position = seconds("elapsedTimeMicros") + (playing ? age * rate : 0)
        elapsed = duration > 0 ? min(duration, position) : position
        sampledAt = uptime
        let unique = text("contentItemIdentifier").isEmpty ? text("uniqueIdentifier") : text("contentItemIdentifier")
        // Include metadata even when an app reuses a queue/item identifier.
        let identity = [bundle, unique, title, artist, album].joined(separator: "\u{1f}")
        let hash = identity.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        id = "system:" + String(hash, radix: 16)
        prohibitsSkip = (payload["prohibitsSkip"] as? NSNumber)?.boolValue ?? false
        if let encoded = payload["artworkData"] as? String, encoded.utf8.count <= 11_184_812,
           let decoded = Data(base64Encoded: encoded), decoded.count <= 8 * 1024 * 1024 {
            artwork = decoded
        } else { artwork = nil }
    }
    static func validBundleID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value.contains(".") &&
        value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }
    func dictionary(at uptime: Double) -> [String: Any] {
        let delta = playing ? max(0, uptime - sampledAt) * rate : 0
        let position = duration > 0 ? min(duration, elapsed + delta) : elapsed + delta
        var value: [String: Any] = ["status": "ok", "source": "oruvi.system", "id": id, "title": title,
                "artist": artist, "album": album, "duration": duration,
                "position": position, "sampleUptime": uptime, "playing": playing,
                "systemBundleID": bundleID, "systemProhibitsSkip": prohibitsSkip]
        if let artwork { value["systemArtwork"] = artwork }
        return value
    }
}

/// NDJSON may split anywhere (including within UTF-8 and base64). A whole-frame
/// bound prevents a broken helper from retaining an unlimited byte stream.
struct SystemMediaFrames {
    static let maximumBytes = 12 * 1024 * 1024
    private(set) var buffer = Data()
    enum FrameError: Error { case oversized }
    mutating func append(_ bytes: Data) throws -> [Data] {
        var frames: [Data] = []
        // Do not append an arbitrarily large chunk before checking its size.
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = bytes[start...].firstIndex(of: 10) ?? bytes.endIndex
            guard buffer.count + bytes.distance(from: start, to: end) <= Self.maximumBytes else {
                buffer.removeAll(keepingCapacity: false); throw FrameError.oversized
            }
            buffer.append(contentsOf: bytes[start..<end])
            if end == bytes.endIndex { break }
            if !buffer.isEmpty { frames.append(buffer) }
            buffer.removeAll(keepingCapacity: true)
            start = bytes.index(after: end)
        }
        return frames
    }
}
