import Foundation

enum ArtworkURLPolicy {
    static func spotify(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(),
              host == "i.scdn.co" || host == "mosaic.scdn.co" || host.hasSuffix(".spotifycdn.com") else { return nil }
        return url
    }
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return host == "lrclib.net" || host == "itunes.apple.com" || host.hasSuffix(".mzstatic.com") || spotify(url.absoluteString) != nil
    }
    static func redirect(from original: URL, to target: URL) -> Bool {
        guard allowed(original), allowed(target), let a = original.host?.lowercased(), let b = target.host?.lowercased() else { return false }
        return a == b || (a.hasSuffix(".mzstatic.com") && b.hasSuffix(".mzstatic.com")) || (spotify(original.absoluteString) != nil && spotify(target.absoluteString) != nil)
    }
}
