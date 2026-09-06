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
    static func parse(_ source: String) -> [LyricLine] {
        guard source.utf8.count <= maximumBytes else { return [] }
        let offsetPattern = try! NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        let stamps = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#)
        let words = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{2}(?:\.\d{1,3})?>"#)
        let all = source as NSString
        let offsetMatch = offsetPattern.matches(in: source, range: NSRange(location: 0, length: all.length)).last
        let offset = offsetMatch.flatMap { Double(all.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        guard offset.isFinite else { return [] }
        var entries: [(Double, String, Int)] = []
        for row in source.components(separatedBy: .newlines) {
            let ns = row as NSString
            let matches = stamps.matches(in: row, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let tail = ns.substring(from: NSMaxRange(last.range))
            let text = words.stringByReplacingMatches(in: tail, range: NSRange(location: 0, length: (tail as NSString).length), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
            for match in matches {
                guard let minute = Double(ns.substring(with: match.range(at: 1))),
                      let second = Double(ns.substring(with: match.range(at: 2))), second < 60 else { continue }
                let fractionRange = match.range(at: 3)
                let fraction = fractionRange.location == NSNotFound ? 0 : (Double("0." + ns.substring(with: fractionRange)) ?? 0)
                entries.append((max(0, minute * 60 + second + fraction + offset), text, entries.count))
            }
        }
        entries.sort { $0.0 == $1.0 ? $0.2 < $1.2 : $0.0 < $1.0 }
        var merged: [(Double, String)] = []
        for entry in entries {
            if let last = merged.last, abs(last.0 - entry.0) < 0.00001 {
                if !entry.1.isEmpty && !last.1.components(separatedBy: "\n").contains(entry.1) {
                    merged[merged.count - 1].1 = last.1.isEmpty ? entry.1 : last.1 + "\n" + entry.1
                }
            } else { merged.append((entry.0, entry.1)) }
        }
        return merged.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
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
    func value(at now: Double) -> Double {
        let elapsed = playing ? max(0, now - uptime) : 0
        let value = max(0, position + elapsed)
        return duration > 0 ? min(duration, value) : value
    }
}

struct TrackIdentity: Equatable, Codable, Sendable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var cacheKey: String { "\(id)|\(title)|\(artist)|\(album)|\(Int(duration.rounded()))" }
    static let empty = TrackIdentity(id: "", title: "Tu música, en calma.", artist: "Conecta la app Música de este Mac", album: "", duration: 0)
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
}
