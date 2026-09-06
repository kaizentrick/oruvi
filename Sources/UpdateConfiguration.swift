import Foundation

/// The signing key is embedded in the app, never obtained from the repository being checked.
enum UpdateConfiguration {
    static func repository(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"#
        guard text.range(of: pattern, options: .regularExpression) != nil,
              let name = text.split(separator: "/").last, name != ".", name != ".." else { return nil }
        return text
    }
    static func feed(for repository: String) -> URL? {
        guard let safe = self.repository(repository) else { return nil }
        return URL(string: "https://github.com/\(safe)/releases/latest/download/appcast.xml")
    }
    static var hasEmbeddedKey: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let data = Data(base64Encoded: value) else { return false }
        return data.count == 32
    }
}
