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
        guard enabled, !visible, !blocked, idle.isFinite, idle >= 0 else { return false }
        let threshold = max(15, delay.isFinite ? delay : 300)
        return idle >= threshold && now - lastDismissed >= threshold && now - lastWake >= threshold
    }
    func nextCheck(idle: Double) -> Double {
        guard idle.isFinite else { return 30 }
        return min(30, max(1, max(15, delay) - idle))
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
    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    static func primaryArtist(_ value: String) -> String {
        let pattern = #"\s+(?:&|feat\.?|ft\.?|featuring|with|x)\s+|,\s+"#
        let range = value.range(of: pattern, options: [.regularExpression, .caseInsensitive])
        return range.map { String(value[..<$0.lowerBound]) } ?? value
    }
    static func title(_ value: String) -> String {
        // Remove a featured-credit suffix, never live/remix/remastered version labels.
        let stripped = value.replacingOccurrences(of: #"\s*[\(\[]\s*(?:feat\.?|ft\.?|featuring)\s+[^\)\]]+[\)\]]"#, with: "", options: [.regularExpression, .caseInsensitive])
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
