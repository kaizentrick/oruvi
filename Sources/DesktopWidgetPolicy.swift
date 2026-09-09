// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import Foundation

/// Pure preferences and geometry shared by the desktop card and regression tests.
enum DesktopWidgetPolicy {
    static let enabledKey = "desktopWidgetEnabled"
    static let pinnedKey = "desktopWidgetAlwaysOnTop"
    static let introductionKey = "desktopWidgetIntroductionShown"
    static let size = CGSize(width: 344, height: 212)

    /// An absent setting used to hide the new feature. Default to visible once,
    /// but never overwrite an explicit Hide, including choices made on 0.9.0.
    static func initialVisibility(defaults: UserDefaults) -> Bool {
        if defaults.object(forKey: enabledKey) == nil { defaults.set(true, forKey: enabledKey) }
        return defaults.bool(forKey: enabledKey)
    }
    static func consumeIntroduction(defaults: UserDefaults, enabled: Bool) -> Bool {
        guard !defaults.bool(forKey: introductionKey) else { return false }
        defaults.set(true, forKey: introductionKey)
        return enabled
    }
    static func visible(enabled: Bool, standby: Bool, sleeping: Bool) -> Bool {
        enabled && !standby && !sleeping
    }
    private static func valid(_ rect: CGRect) -> Bool {
        [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
    }
    /// Normalize old saved sizes and recover positions left on disconnected screens.
    /// All coordinates remain global, including negative secondary-display origins.
    static func frame(saved: CGRect?, screens: [CGRect], preferred: CGRect?, reset: Bool) -> CGRect? {
        let screens = screens.filter(valid)
        guard let first = screens.first else { return nil }
        let fallback = preferred.flatMap { screens.contains($0) ? $0 : nil } ?? first
        let saved = saved.flatMap { valid($0) ? $0 : nil }
        var area = fallback
        if !reset, let saved {
            var largest: CGFloat = 0
            for screen in screens {
                let overlap = screen.intersection(saved)
                let score = overlap.isNull ? 0 : overlap.width * overlap.height
                if score > largest { largest = score; area = screen }
            }
        }
        let inset = min(16, max(0, min(area.width, area.height) / 8))
        let width = min(size.width, area.width - 2 * inset)
        let height = min(size.height, area.height - 2 * inset)
        let x = !reset ? saved?.minX : nil
        let y = !reset ? saved?.minY : nil
        return CGRect(x: min(max(x ?? area.minX + inset, area.minX + inset), area.maxX - width - inset),
                      y: min(max(y ?? area.maxY - height - inset, area.minY + inset), area.maxY - height - inset),
                      width: width, height: height)
    }
}
