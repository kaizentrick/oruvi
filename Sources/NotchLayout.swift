import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

struct NotchGeometry {
    let screenFrame: CGRect
    let centerX: CGFloat
    let top: CGFloat
    let cameraWidth: CGFloat
    let topInset: CGFloat
    let compactWidth: CGFloat
    let scale: CGFloat
    var hasCutout: Bool { cameraWidth > 0 }
    var compactHeight: CGFloat { topInset }
    static func resolve(frame: CGRect, safeTop: CGFloat, left: CGRect?, right: CGRect?, scale: CGFloat) -> NotchGeometry {
        let density = scale.isFinite && scale > 0 ? scale : 1
        let gap = (left != nil && right != nil) ? max(0, right!.minX - left!.maxX) : 0
        let cutout = safeTop.isFinite && safeTop > 0 && gap > 0 && gap < frame.width
        let height = cutout ? floor(safeTop * density) / density : 30
        let center = cutout ? (left!.maxX + right!.minX) / 2 : frame.midX
        return NotchGeometry(screenFrame: frame, centerX: center,
                             top: frame.maxY, cameraWidth: cutout ? gap : 0,
                             topInset: height, compactWidth: cutout ? gap + 88 : 150, scale: density)
    }
    func frame(expanded: Bool, tab: NotchTab = .music) -> CGRect {
        let width = min(max(1, screenFrame.width - 16), expanded ? max(360, compactWidth) : compactWidth)
        let height = expanded ? min(topInset + tab.contentHeight, max(topInset, screenFrame.height - 24)) : compactHeight
        let x = min(max(screenFrame.minX + 8, centerX - width / 2), screenFrame.maxX - width - 8)
        return CGRect(x: (x * scale).rounded() / scale, y: top - height, width: width, height: height)
    }
}

enum NotchTab: String, CaseIterable, Identifiable {
    case music, files, agenda, timer, connections
    var id: String { rawValue }
    var contentHeight: CGFloat { self == .music ? 158 : (self == .connections ? 280 : 240) }
    var title: String {
        switch self { case .music: return "Música"; case .files: return "Archivos"; case .agenda: return "Agenda"; case .timer: return "Temporizador"; case .connections: return "Conexiones" }
    }
    var symbol: String {
        switch self { case .music: return "music.note"; case .files: return "tray"; case .agenda: return "calendar"; case .timer: return "timer"; case .connections: return "point.3.connected.trianglepath.dotted" }
    }
}

enum NotchCompactMode: Equatable {
    case none, music, timer, codex
}

enum NotchCompactPolicy {
    static func showsMusicIndicator(hasTrack: Bool, playing: Bool) -> Bool { hasTrack && playing }
    static func resolve(tab: NotchTab, musicActive: Bool, timerActive: Bool, codexActive: Bool) -> NotchCompactMode {
        switch tab {
        case .music where musicActive: return .music
        case .timer where timerActive: return .timer
        case .connections where codexActive: return .codex
        default:
            if timerActive { return .timer }
            if musicActive { return .music }
            if codexActive { return .codex }
            return .none
        }
    }
}

enum NotchFilePolicy {
    static let limit = 20
    static func candidates(_ urls: [URL], existing: [URL]) -> [URL] {
        var seen = Set(existing.map { $0.standardizedFileURL })
        var result: [URL] = []
        for url in urls {
            guard result.count + existing.count < limit else { break }
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { continue }
            let normalized = url.standardizedFileURL
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
    static func isSafeFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]),
              values.isSymbolicLink != true,
              values.isRegularFile == true || values.isDirectory == true else { return false }
        return true
    }
}

enum NotchMeetingDetector {
    private static let linkPattern = try! NSRegularExpression(pattern: #"https://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#, options: [.caseInsensitive])
    static func isAllowedMeetingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host == "meet.google.com" || host == "teams.microsoft.com" || host == "teams.live.com" || host == "facetime.apple.com" {
            return true
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") || host == "webex.com" || host.hasSuffix(".webex.com") {
            return true
        }
        return false
    }
    static func extractURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isAllowedMeetingURL(url) { return url }
        for field in [location, notes] {
            guard let text = field, !text.isEmpty else { continue }
            let bounded = String(text.prefix(8192))
            let range = NSRange(bounded.startIndex..<bounded.endIndex, in: bounded)
            for match in linkPattern.matches(in: bounded, range: range) {
                guard let swiftRange = Range(match.range, in: bounded) else { continue }
                let raw = String(bounded[swiftRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)>]\"'"))
                if let candidate = URL(string: raw), isAllowedMeetingURL(candidate) { return candidate }
            }
        }
        return nil
    }
}
