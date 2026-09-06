// Copyright (c) 2026 KaizenTrick.
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Input policy deliberately has no player, track, artwork or network dependency.
struct NotchInteractionState {
    var visible = false
    var pointerInside = false
    var suppressHoverUntilExit = false
    var fileDragActive = false
    var keyboardPinned = false
    var expanded = false
    var interactionDepth = 0
    var menuTracking = false

    var targetExpanded: Bool {
        visible && ((pointerInside && !suppressHoverUntilExit) || fileDragActive || keyboardPinned || interactionDepth > 0 || menuTracking)
    }
    var preventsAutomaticStandby: Bool { expanded || fileDragActive || interactionDepth > 0 || menuTracking }
    mutating func suspend() {
        visible = false; pointerInside = false; suppressHoverUntilExit = false; fileDragActive = false
        keyboardPinned = false; expanded = false; menuTracking = false
        // Real native dialogs retain their own lifetime until their completion callback.
    }
}

/// Repeated mouseMoved/tracking-area rebuilds must NOT restart the hover deadline.
struct NotchTransitionGate {
    private(set) var pending: Bool?
    mutating func arm(target: Bool, current: Bool) -> Bool {
        guard target != current else { pending = nil; return false }
        guard pending != target else { return false }
        pending = target; return true
    }
    mutating func cancel() { pending = nil }
}

/// A previous drag leaves data on NSPasteboard.Name.drag. Require a fresh gesture
/// and a changed pasteboard before considering proximity; a window move is not a file.
struct NotchDragFreshness {
    private(set) var baseline = 0
    private(set) var pressed = false
    mutating func begin(changeCount: Int) { baseline = changeCount; pressed = true }
    mutating func end(changeCount: Int) { baseline = changeCount; pressed = false }
    func accepts(changeCount: Int, advertisesFiles: Bool) -> Bool {
        pressed && changeCount != baseline && advertisesFiles
    }
}

enum NotchApproachGeometry {
    static func region(compact: CGRect, screen: CGRect) -> CGRect {
        // A narrow local approach zone, not an invisible window covering the desktop.
        let width = min(screen.width, max(420, compact.width + 80))
        let x = min(max(screen.minX, compact.midX - width / 2), screen.maxX - width)
        return CGRect(x: x, y: max(screen.minY, compact.minY - 84),
                      width: width, height: min(screen.height, compact.height + 84))
            .intersection(screen)
    }
}
