import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@main
struct VerifyNotchInteraction {
    static func main() {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            precondition(value(), message)
        }
        // The very same input policy used by the controller, for every player state.
        for playerState in ["not installed", "disconnected", "no track", "paused", "playing", "permission denied"] {
            var state = NotchInteractionState()
            expect(!state.targetExpanded, "hidden: \(playerState)")
            state.visible = true
            expect(!state.targetExpanded, "idle: \(playerState)")
            state.pointerInside = true
            expect(state.targetExpanded, "hover opens: \(playerState)")
            state.expanded = true; state.pointerInside = false
            expect(!state.targetExpanded, "exit closes: \(playerState)")
            state.fileDragActive = true
            expect(state.targetExpanded && state.preventsAutomaticStandby, "drag opens: \(playerState)")
            state.fileDragActive = false; state.keyboardPinned = true
            expect(state.targetExpanded, "keyboard keeps panel: \(playerState)")
            state.keyboardPinned = false; state.interactionDepth = 1
            expect(state.targetExpanded, "native dialog keeps panel: \(playerState)")
            state.interactionDepth = 0; state.menuTracking = true
            expect(state.targetExpanded, "menu keeps panel: \(playerState)")
            state.suspend()
            expect(!state.targetExpanded && !state.expanded && !state.menuTracking && !state.fileDragActive, "suspend clears transient input")
            state.visible = true; state.pointerInside = true
            expect(state.targetExpanded, "wake and hover recover")
        }
        var closed = NotchInteractionState()
        closed.visible = true; closed.pointerInside = true; closed.suppressHoverUntilExit = true
        expect(!closed.targetExpanded, "explicit close does not bounce open under stationary pointer")
        closed.fileDragActive = true
        expect(closed.targetExpanded, "fresh file drag still opens after explicit close")
        closed.suspend()
        expect(!closed.suppressHoverUntilExit, "wake does not retain hover suppression")
        var gate = NotchTransitionGate()
        expect(gate.arm(target: true, current: false), "initial hover schedules opening")
        for _ in 0..<100 {
            expect(!gate.arm(target: true, current: false) && gate.pending == true, "mouse movement does not starve opening")
        }
        expect(!gate.arm(target: false, current: false) && gate.pending == nil, "exit before deadline cancels opening")
        expect(gate.arm(target: true, current: false), "re-entry schedules again")
        gate.cancel()
        expect(gate.arm(target: false, current: true), "exit schedules closing")
        expect(!gate.arm(target: false, current: true), "duplicate exits do not restart closing")
        expect(!gate.arm(target: true, current: true) && gate.pending == nil, "re-entry cancels closing")
        var cadence = NotchPointerCadence()
        let hoverPoint = CGPoint(x: 700, y: 1000)
        let movedPoint = CGPoint(x: 710, y: 1000)
        expect(cadence.interval(near: false, at: hoverPoint, uptime: 1) == nil, "no safety timer away from the notch")
        expect(cadence.interval(near: true, at: hoverPoint, uptime: 2) == 0.06, "entering the camera region samples quickly")
        expect(cadence.interval(near: true, at: hoverPoint, uptime: 2.4) == 0.06, "keep the fast window during hover settlement")
        expect(cadence.interval(near: true, at: hoverPoint, uptime: 2.5) == 0.5, "a parked pointer backs off to two samples per second")
        expect(cadence.interval(near: true, at: hoverPoint, uptime: 9) == 0.5, "events at the same position do not extend fast sampling")
        expect(cadence.interval(near: true, at: movedPoint, uptime: 9.1) == 0.06, "observed motion immediately restores fast sampling")
        expect(cadence.interval(near: false, at: movedPoint, uptime: 9.2) == nil, "leaving the camera region stops polling")
        expect(cadence.interval(near: true, at: movedPoint, uptime: 10) == 0.06, "re-entry starts fresh even at the same position")
        var drag = NotchDragFreshness()
        expect(!drag.accepts(changeCount: 1, advertisesFiles: true), "no gesture, no activation")
        drag.begin(changeCount: 10)
        expect(!drag.accepts(changeCount: 10, advertisesFiles: true), "stale files from old drag rejected")
        expect(!drag.accepts(changeCount: 11, advertisesFiles: false), "text and web links rejected")
        expect(drag.accepts(changeCount: 11, advertisesFiles: true), "fresh file gesture accepted")
        drag.end(changeCount: 11)
        expect(!drag.accepts(changeCount: 12, advertisesFiles: true), "mouse release ends gesture")
        drag.begin(changeCount: 11)
        expect(!drag.accepts(changeCount: 11, advertisesFiles: true), "window movement after file drag rejected")
        expect(drag.accepts(changeCount: 12, advertisesFiles: true), "second file gesture accepted")
        for origin: CGFloat in [-1920, 0, 1512] {
            let screen = CGRect(x: origin, y: 100, width: 1512, height: 982)
            let compact = CGRect(x: origin + 612, y: 1050, width: 288, height: 32)
            let region = NotchApproachGeometry.region(compact: compact, screen: screen)
            expect(screen.contains(region), "approach stays on selected display")
            expect(region.contains(CGPoint(x: compact.midX, y: compact.minY - 60)), "approach before physical notch")
            expect(!region.contains(CGPoint(x: compact.midX, y: compact.minY - 120)), "distant document does not open panel")
            expect(region.maxY == compact.maxY, "approach pinned to same top")
            expect(region.height == 116 && compact.height == 32, "approach does not enlarge visible compact window")
        }
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
        expect(tiny.contains(NotchApproachGeometry.region(compact: CGRect(x: 80, y: 170, width: 140, height: 30), screen: tiny)), "bounded small display")
        print("PASS: \(checks) notch input checks (player-independent hover, deadlines, fresh drag, proximity, recovery).")
    }
}
