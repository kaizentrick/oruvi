import Foundation

enum OruviRelease {
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.2"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "11"
    static let bundleID = "com.kaizentrick.Oruvi"
    static let legacyBundleID = "com.kaizentrick.LumaStandby"
    static let title = "Oruvi \(version)"

    /// Copy only Oruvi preferences, without overwriting newer choices or deleting legacy data.
    static func migratePreferences(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: "oruviIdentityMigrated") else { return }
        let keys = ["settingsSchema", "musicEnabled", "layout", "musicShowsLyrics", "clockTypeface", "clockWeight", "contentTypeface",
                    "avoidMedia", "protectBrowsers", "automaticLyrics", "automaticArtwork", "meshFollowsMusic", "idleEnabled",
                    "idleMinutes", "showPhrases", "phraseInterval", "keepAwake", "twentyFourHour", "lyricOffset", "appearance", "energyMode"]
        if let previous = defaults.persistentDomain(forName: legacyBundleID) {
            for key in keys where defaults.object(forKey: key) == nil {
                if let value = previous[key] { defaults.set(value, forKey: key) }
            }
        }
        defaults.set(true, forKey: "oruviIdentityMigrated")
    }
}
