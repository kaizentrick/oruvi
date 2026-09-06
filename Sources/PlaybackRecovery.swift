import Foundation

/// Recovery is independent of play/pause: a timeout is not a pause command.
struct PlaybackRecovery {
    private(set) var waiting = true
    private(set) var failures = 0
    private(set) var stoppedSamples = 0
    private(set) var lastSuccess: Double?
    mutating func invalidate() { waiting = true; failures = 0; stoppedSamples = 0 }
    mutating func succeed(at uptime: Double) { waiting = false; failures = 0; stoppedSamples = 0; lastSuccess = uptime }
    mutating func fail() { waiting = true; failures = min(10, failures + 1); stoppedSamples = 0 }
    mutating func observeStopped() -> Bool {
        waiting = true; stoppedSamples += 1
        // Music briefly reports stopped while replacing the queue or switching albums.
        return stoppedSamples >= 2
    }
    var retryInterval: Double {
        if stoppedSamples == 1 { return 0.35 }
        switch failures { case 0: return 0.25; case 1: return 0.5; case 2: return 1; case 3...5: return 2; default: return 5 }
    }
    static func sameRecording(_ a: TrackIdentity, _ b: TrackIdentity) -> Bool {
        a.id == b.id && a.title == b.title && a.artist == b.artist && a.album == b.album && abs(a.duration - b.duration) <= 0.5
    }
    static func reconciledPosition(_ position: Double, sampleUptime: Double, previous: PlaybackAnchor, playing: Bool) -> Double {
        let predicted = previous.value(at: sampleUptime)
        // Ignore sub-60 ms sampling noise, but apply seeks, pauses and real drift immediately.
        return previous.playing == playing && abs(predicted - position) < 0.06 ? predicted : position
    }
}
