import Foundation

/// ContinuousClock includes machine sleep and is unaffected by wall-clock/time-zone
/// changes. A paused timer stores duration, not a stale wall-clock deadline.
struct NotchTimerState {
    private(set) var totalSeconds = 1500
    private(set) var held: Duration = .seconds(1500)
    private(set) var deadline: ContinuousClock.Instant?
    private(set) var completed = false
    var running: Bool { deadline != nil }
    func remaining(at now: ContinuousClock.Instant = .now) -> Duration {
        max(.zero, deadline.map { now.duration(to: $0) } ?? held)
    }
    func seconds(at now: ContinuousClock.Instant = .now) -> Int {
        let value = remaining(at: now).components
        return max(0, Int(value.seconds) + (value.attoseconds > 0 ? 1 : 0))
    }
    mutating func configure(seconds: Int) {
        totalSeconds = min(10800, max(1, seconds)); reset()
    }
    mutating func start(at now: ContinuousClock.Instant = .now) {
        guard !running else { return }
        if completed || held <= .zero { reset() }
        deadline = now.advanced(by: held); completed = false
    }
    mutating func pause(at now: ContinuousClock.Instant = .now) {
        guard running else { return }
        held = remaining(at: now); deadline = nil
        if held <= .zero { finish() }
    }
    mutating func finish() { held = .zero; deadline = nil; completed = true }
    mutating func reset() { deadline = nil; held = .seconds(totalSeconds); completed = false }
}
