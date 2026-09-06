import Foundation

/// Screen coordinates are points, not physical pixels. The compact window must never
/// extend below the safe-area band; display scaling is applied exactly once here.
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
        // Round inward, never add decorative pixels below the physical camera band.
        let height = cutout ? floor(safeTop * density) / density : 30
        let center = cutout ? (left!.maxX + right!.minX) / 2 : frame.midX
        return NotchGeometry(screenFrame: frame, centerX: center,
                             top: frame.maxY - (cutout ? 0 : 5), cameraWidth: cutout ? gap : 0,
                             topInset: height, compactWidth: cutout ? gap + 88 : 150, scale: density)
    }
    func frame(expanded: Bool) -> CGRect {
        let width = min(max(1, screenFrame.width - 16), expanded ? max(420, compactWidth) : compactWidth)
        let height = expanded ? min(topInset + 260, max(topInset, screenFrame.height - 24)) : compactHeight
        let x = min(max(screenFrame.minX + 8, centerX - width / 2), screenFrame.maxX - width - 8)
        return CGRect(x: (x * scale).rounded() / scale, y: top - height, width: width, height: height)
    }
}

enum NotchTab: String, CaseIterable, Identifiable {
    case music, files, agenda, timer
    var id: String { rawValue }
    var title: String {
        switch self { case .music: return "Música"; case .files: return "Archivos"; case .agenda: return "Agenda"; case .timer: return "Temporizador" }
    }
    var symbol: String {
        switch self { case .music: return "music.note"; case .files: return "tray"; case .agenda: return "calendar"; case .timer: return "timer" }
    }
}

enum NotchCompactPolicy {
    static func showsMusicIndicator(hasTrack: Bool, playing: Bool) -> Bool { hasTrack && playing }
}

enum NotchFilePolicy {
    static let limit = 20
    /// Only actual local file URLs supplied by a user gesture. No remote URL downloads,
    /// clipboard scanning, file promises, recursive traversal or automatic file execution.
    static func candidates(_ urls: [URL], existing: [URL]) -> [URL] {
        var seen = Set(existing.map { $0.standardizedFileURL })
        var result: [URL] = []
        for url in urls where result.count + existing.count < limit {
            guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { continue }
            let normalized = url.standardizedFileURL
            guard seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
}
