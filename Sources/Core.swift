import Foundation

struct LyricLine: Identifiable, Codable, Equatable, Sendable {
    let id: Int
    let time: TimeInterval
    let text: String
}

/// A bounded LRC parser. Blank timed lines are retained as instrumental breaks.
/// Enhanced-LRC word tags are removed: this version synchronizes by LINE, not word.
enum LRCParser {
    static let maximumBytes = 512_000
    static let cacheVersion = 2
    private static let offsetPattern = try! NSRegularExpression(
        pattern: #"^[ \t\uFEFF]*\[offset:([+-]?[0-9]+)\][ \t]*$"#,
        options: [.caseInsensitive, .anchorsMatchLines])
    private static let stampPattern = #"\[([0-9]{1,3}):([0-5][0-9])(?:\.([0-9]{1,3}))?\]"#
    private static let stamps = try! NSRegularExpression(pattern: stampPattern)
    private static let stampPrefix = try! NSRegularExpression(pattern: #"^[ \t\uFEFF]*(?:"# + stampPattern + #"[ \t]*)+"#)
    private static let words = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{2}(?:\.\d{1,3})?>"#)

    private struct CueGroup {
        var lines: [String] = []
        private var seen: Set<String> = []

        mutating func append(_ text: String, bytes: Int) -> Int {
            guard !text.isEmpty, seen.insert(text).inserted else { return 0 }
            lines.append(text)
            return bytes + 1
        }
    }

    static func parse(_ source: String) -> [LyricLine] {
        guard source.utf8.count <= maximumBytes else { return [] }
        let all = source as NSString
        let offsetMatch = offsetPattern.matches(in: source, range: NSRange(location: 0, length: all.length)).last
        let offset = offsetMatch.flatMap { Int(all.substring(with: $0.range(at: 1))) } ?? 0
        var groups: [Int: CueGroup] = [:]
        var bytes = 0
        for row in source.components(separatedBy: .newlines) {
            let ns = row as NSString
            guard let prefix = stampPrefix.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)) else { continue }
            let tail = ns.substring(from: NSMaxRange(prefix.range))
            let text = words.stringByReplacingMatches(in: tail, range: NSRange(location: 0, length: (tail as NSString).length), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let textBytes = text.utf8.count
            var rowTimes: Set<Int> = []
            for match in stamps.matches(in: row, range: prefix.range) {
                guard let minute = Int(ns.substring(with: match.range(at: 1))),
                      let second = Int(ns.substring(with: match.range(at: 2))) else { continue }
                let fractionRange = match.range(at: 3)
                let fraction = fractionRange.location == NSNotFound ? 0 : (Int(ns.substring(with: fractionRange)) ?? 0)
                let fractionScale = fractionRange.length == 1 ? 100 : (fractionRange.length == 2 ? 10 : 1)
                let (time, overflow) = offset.addingReportingOverflow((minute * 60 + second) * 1000 + fraction * fractionScale)
                guard !overflow, rowTimes.insert(time).inserted else { continue }
                bytes += groups[time, default: CueGroup()].append(text, bytes: textBytes)
                // Repeated stamps must not expand a short input into an unbounded lyric payload.
                guard bytes <= maximumBytes * 4 else { return [] }
            }
        }
        // If the offset places several cues before playback, only the last one can be active at zero.
        if groups[0] == nil, let previous = groups.keys.filter({ $0 < 0 }).max() {
            groups[0] = groups[previous]
        }
        return groups.keys.filter { $0 >= 0 }.sorted().enumerated().map { index, time in
            LyricLine(id: index, time: Double(time) / 1000, text: groups[time]?.lines.joined(separator: "\n") ?? "")
        }
    }
    /// Returns nil before the first cue; O(log n) even for long files.
    static func index(at position: Double, in lines: [LyricLine]) -> Int? {
        guard position.isFinite, !lines.isEmpty, position >= lines[0].time else { return nil }
        var low = 0, high = lines.count
        while low < high {
            let mid = low + (high - low) / 2
            if lines[mid].time <= position { low = mid + 1 } else { high = mid }
        }
        return low - 1
    }
}

/// Monotonic interpolation avoids clock changes and does not ask Music for every UI frame.
struct PlaybackAnchor: Equatable, Sendable {
    var position: Double = 0
    var uptime: Double = 0
    var duration: Double = 0
    var playing = false
    var rate: Double = 1
    func value(at now: Double) -> Double {
        let elapsed = playing ? max(0, now - uptime) * rate : 0
        let value = max(0, position + elapsed)
        return duration > 0 ? min(duration, value) : value
    }
    func delay(until position: Double, at now: Double) -> TimeInterval? {
        guard playing, rate > 0, duration <= 0 || position <= duration else { return nil }
        let delay = (position - value(at: now)) / rate
        return delay.isFinite ? max(0.012, delay) : nil
    }
}

enum PlaybackTime {
    static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, let value = Int64(exactly: max(0, seconds).rounded(.down)) else { return "—" }
        return String(format: "%lld:%02lld", value / 60, value % 60)
    }
}

struct TrackIdentity: Equatable, Codable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var sourceID: String = "com.apple.Music"
    var cacheKey: String {
        let base = "\(id)|\(title)|\(artist)|\(album)|\(Int(duration.rounded()))"
        return sourceID == "com.apple.Music" ? base : sourceID + "|" + base
    }
    static let empty = TrackIdentity(id: "", title: "Tu música, en calma.", artist: "Conecta la app Música de este Mac", album: "", duration: 0)
}

enum PlaybackScrub {
    case idle, dragging(TrackIdentity, Double), invalidated

    func preview(on track: TrackIdentity) -> Double? {
        guard case .dragging(let original, let fraction) = self, original == track else { return nil }
        return fraction
    }

    mutating func update(fraction: Double, on track: TrackIdentity) {
        if case .idle = self { self = .dragging(track, fraction) }
        else if preview(on: track) != nil { self = .dragging(track, fraction) }
        else { self = .invalidated }
    }

    mutating func invalidate() {
        if case .dragging = self { self = .invalidated }
    }

    mutating func finish(fraction: Double, on track: TrackIdentity, duration: Double) -> Double? {
        defer { self = .idle }
        guard preview(on: track) != nil else { return nil }
        return fraction * duration
    }
}

enum EnergyMode: String, CaseIterable, Identifiable {
    case adaptive = "Automático", saver = "Ahorro", fluid = "Fluido"
    var id: String { rawValue }
}
struct RenderPolicy: Equatable {
    var visible: Bool
    var onBattery: Bool
    var lowPower: Bool
    var hot: Bool
    var reduceMotion: Bool
    var mode: EnergyMode
    var framesPerSecond: Double {
        guard visible, !lowPower, !hot, !reduceMotion, mode != .saver else { return 0 }
        if onBattery { return mode == .fluid ? 12 : 0 }
        return mode == .fluid ? 30 : 24
    }
    func pollingInterval(playing: Bool) -> Double? {
        guard visible else { return nil }
        if !playing { return 5 }
        return (onBattery || lowPower || hot || mode == .saver) ? 2 : 1
    }
}

struct LyricsPayload: Codable, Sendable {
    var lines: [LyricLine]
    var source: String
    var savedAt: Date
    var parserVersion: Int?
}
