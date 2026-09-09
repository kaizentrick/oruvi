// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The visible surface and its input boundary share one presentation value.
/// The AppKit window is only a stable, bounded envelope, not the hover target.
struct NotchSurfaceState: Equatable {
    var width: CGFloat
    var height: CGFloat
    var flare: CGFloat
    var radius: CGFloat
    var expansion: CGFloat
    static let initial = NotchSurfaceState(width: 150, height: 30, flare: 0, radius: 15, expansion: 0)
}

enum NotchPresentation {
    static let noticeHeight: CGFloat = 32
    static let shadowMargin: CGFloat = 12
    static let openingDuration: TimeInterval = 0.22
    static let closingDuration: TimeInterval = 0.18

    static func envelope(_ geometry: NotchGeometry) -> CGRect {
        let largest = geometry.frame(expanded: true, tab: .files)
        let width = min(geometry.screenFrame.width, largest.width + shadowMargin * 2)
        let height = min(geometry.screenFrame.height - (geometry.screenFrame.maxY - geometry.top),
                         largest.height + noticeHeight + shadowMargin)
        let x = min(max(geometry.screenFrame.minX, largest.midX - width / 2), geometry.screenFrame.maxX - width)
        return CGRect(x: x, y: geometry.top - height, width: width, height: height)
    }
    static func target(_ geometry: NotchGeometry, expanded: Bool, tab: NotchTab, notice: Bool) -> NotchSurfaceState {
        let base = geometry.frame(expanded: expanded, tab: tab)
        let envelope = envelope(geometry)
        let availableWidth = max(1, envelope.width - shadowMargin * 2)
        let width = !expanded && notice ? min(max(320, base.width), availableWidth) : min(base.width, availableWidth)
        let height = max(1, min(base.height + (notice ? noticeHeight : 0), envelope.height - shadowMargin))
        return NotchSurfaceState(width: width, height: height, flare: geometry.hasCutout ? 6 : 0,
                                 radius: expanded || notice ? 22 : min(12, geometry.topInset / 2),
                                 expansion: expanded ? 1 : 0)
    }
    static func frame(_ state: NotchSurfaceState, in envelope: CGRect) -> CGRect {
        CGRect(x: envelope.midX - state.width / 2, y: envelope.maxY - state.height,
               width: state.width, height: state.height)
    }
    /// Bounded, asymmetric easing. Retargeting begins at the displayed state.
    static func interpolate(from: NotchSurfaceState, to: NotchSurfaceState, progress: Double, opening: Bool) -> NotchSurfaceState {
        let t = CGFloat(min(1, max(0, progress.isFinite ? progress : 1)))
        let amount = opening ? 1 - pow(1 - t, 3) : t * t * (3 - 2 * t)
        func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * amount }
        return NotchSurfaceState(width: blend(from.width, to.width), height: blend(from.height, to.height),
                                 flare: blend(from.flare, to.flare), radius: blend(from.radius, to.radius),
                                 expansion: blend(from.expansion, to.expansion))
    }
}

enum NotchNotice: Equatable {
    case filesAdded(Int)
    case timerFinished
    var title: String {
        switch self {
        case .filesAdded(let count): return count == 1 ? "Archivo añadido a la bandeja" : "\(count) archivos añadidos a la bandeja"
        case .timerFinished: return "Temporizador terminado"
        }
    }
    var symbol: String {
        switch self { case .filesAdded: return "tray.and.arrow.down"; case .timerFinished: return "timer" }
    }
    var tab: NotchTab {
        switch self { case .filesAdded: return .files; case .timerFinished: return .timer }
    }
}

struct NotchHapticGate {
    private var last: TimeInterval?
    mutating func accept(enabled: Bool, now: TimeInterval) -> Bool {
        guard enabled, now.isFinite, last.map({ now - $0 >= 0.25 }) ?? true else { return false }
        last = now
        return true
    }
}

struct NotchDisplayOption: Equatable, Identifiable {
    let id: String
    let name: String
    let hasCutout: Bool
}

enum NotchDisplayPolicy {
    static func select(options: [NotchDisplayOption], preference: String, main: String?) -> String? {
        if preference != "automatic", options.contains(where: { $0.id == preference }) { return preference }
        return options.first(where: { $0.hasCutout })?.id
            ?? options.first(where: { $0.id == main })?.id ?? options.first?.id
    }
}
