import Foundation

/// Pure rules: background checks never capture keys, clicks, audio or screen contents.
struct IdleActivationPolicy {
    var enabled: Bool
    var delay: Double
    var visible: Bool
    var blocked: Bool
    var now: Double
    var lastDismissed: Double
    var lastWake: Double
    func shouldActivate(idle: Double) -> Bool {
        guard enabled, !visible, !blocked, let remaining = remainingUntilEligible(idle: idle) else { return false }
        return remaining <= 0
    }
    func nextCheck(idle: Double) -> Double {
        // Input can only postpone eligibility. Checking sooner cannot activate Standby.
        max(1, remainingUntilEligible(idle: idle) ?? 30)
    }
    private func remainingUntilEligible(idle: Double) -> Double? {
        guard idle.isFinite, idle >= 0, now.isFinite, lastDismissed.isFinite, lastWake.isFinite else { return nil }
        let threshold = max(15, delay.isFinite ? delay : 300)
        let freshestActivity = min(idle, now - max(lastDismissed, lastWake))
        let remaining = threshold - freshestActivity
        return remaining.isFinite ? remaining : nil
    }
}

struct IdleActivationPause {
    let deadline: ContinuousClock.Instant

    init(duration: Duration, at now: ContinuousClock.Instant = .now) {
        deadline = now + duration
    }

    func remainingSeconds(at now: ContinuousClock.Instant = .now) -> TimeInterval? {
        guard now < deadline else { return nil }
        let remaining = now.duration(to: deadline).components
        return Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
    }
}

/// Tracks a synchronous system probe that cannot be interrupted once launched.
enum IdleMediaCheckState: Equatable {
    case idle, checking, invalidated, waitingToRetry

    mutating func begin() -> Bool {
        if self == .idle {
            self = .checking
            return true
        }
        if self == .invalidated { self = .waitingToRetry }
        return false
    }

    mutating func invalidate() {
        if self != .idle { self = .invalidated }
    }

    mutating func complete() -> Self {
        defer { self = .idle }
        return self
    }
}

enum MotivationalPhrases {
    // Original short copy. No invented attribution to real people.
    static let all = [
        "Haz espacio para lo que importa.",
        "Un paso pequeño también cambia el rumbo.",
        "Tu atención construye tu futuro.",
        "No necesitas hacerlo todo. Empieza por algo.",
        "La constancia también puede sentirse ligera.",
        "Descansar también es avanzar.",
        "Menos ruido. Más intención.",
        "Lo extraordinario se practica en lo cotidiano.",
        "No te apresures. No te detengas.",
        "Hazlo posible, después hazlo mejor.",
        "Hoy puedes elegir un rumbo distinto.",
        "Dale tiempo a lo que estás construyendo.",
        "Que tus hábitos cuiden tus sueños.",
        "No todo progreso hace ruido.",
        "La siguiente decisión puede ser un comienzo.",
        "Vuelve a lo esencial. Desde ahí, avanza.",
        "Tu ritmo también merece respeto.",
        "Haz más de lo que te acerca a ti.",
        "Empieza donde estás. Usa lo que tienes.",
        "Un día con intención vale más que uno con prisa.",
        "La claridad llega cuando haces espacio.",
        "Lo que repites transforma lo que puedes.",
        "No subestimes una buena pausa.",
        "Construye una vida que también puedas disfrutar."
    ]
    static func next(after current: Int, random: Int) -> Int {
        let count = all.count
        guard count > 1 else { return 0 }
        let offset = 1 + Int(UInt(bitPattern: random) % UInt(count - 1))
        return (max(0, current) % count + offset) % count
    }
}

enum RecordingMatcher {
    private static let primaryArtistRegex = try! NSRegularExpression(pattern: #"\s+(?:&|feat\.?|ft\.?|featuring|with|x)\s+|,\s+"#, options: .caseInsensitive)
    private static let featuredSuffixRegex = try! NSRegularExpression(pattern: #"\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+[^\)\]]+[\)\]]"#, options: .caseInsensitive)
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func primaryArtist(_ value: String) -> String {
        let ns = value as NSString
        let match = primaryArtistRegex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length))
        return match.map { ns.substring(to: $0.range.location) } ?? value
    }
    static func title(_ value: String) -> String {
        // Remove a featured-credit suffix, never live/remix/remastered version labels.
        let ns = value as NSString
        let stripped = featuredSuffixRegex.stringByReplacingMatches(in: value, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return normalized(stripped)
    }
    static func matches(track: TrackIdentity, title candidateTitle: String, artist: String, duration: Double, tolerance: Double = 2.1) -> Bool {
        guard duration.isFinite, track.duration.isFinite, duration > 0, track.duration > 0,
              abs(duration - track.duration) <= tolerance,
              !title(track.title).isEmpty, title(track.title) == title(candidateTitle) else { return false }
        let sourceArtist = normalized(track.artist), candidateArtist = normalized(artist)
        guard !sourceArtist.isEmpty, !candidateArtist.isEmpty else { return false }
        return sourceArtist == candidateArtist || normalized(primaryArtist(track.artist)) == normalized(primaryArtist(artist))
    }
    static func appleArtworkURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), host.hasSuffix(".mzstatic.com") else { return nil }
        return url
    }
}
