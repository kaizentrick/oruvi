// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum NotchHoverGeometry {
    static let openingDelay: UInt64 = 35_000_000
    static let closingDelay: UInt64 = 220_000_000
    static let animationDuration = 0.16
    /// Full camera band, 12 pt to either side and 10 pt underneath. No overlay
    /// window, no click interception and no dependence on native cutout hit tests.
    static func activation(compact: CGRect, screen: CGRect) -> CGRect {
        CGRect(x: compact.minX - 12, y: compact.minY - 10,
               width: compact.width + 24, height: screen.maxY - compact.minY + 10).intersection(screen)
    }
    static func watchRegion(compact: CGRect, screen: CGRect) -> CGRect {
        CGRect(x: compact.minX - 64, y: compact.minY - 96,
               width: compact.width + 128, height: screen.maxY - compact.minY + 96).intersection(screen)
    }
    /// CGRect.contains excludes the upper/right edge. A cursor at exactly maxY
    /// (including behind the camera) must count as inside, not as a hover exit.
    static func contains(_ point: CGPoint, in rect: CGRect) -> Bool {
        !rect.isNull && !rect.isEmpty && point.x.isFinite && point.y.isFinite &&
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
}
