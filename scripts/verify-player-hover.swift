import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

@main
struct VerifyPlayerHover {
    static func main() {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            count += 1
            precondition(condition(), message)
        }
        for legacy in PlayerPreference.allCases {
            let name = "com.kaizentrick.Oruvi.selection-test." + UUID().uuidString
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(legacy.rawValue, forKey: "playerPreference")
            defaults.set(true, forKey: "musicEnabled")
            var preferences = SurfacePlaybackPreferences(defaults: defaults)
            expect(preferences.notch == legacy && preferences.standby == legacy, "migrate legacy once")
            expect(defaults.bool(forKey: "notchMusicEnabled"), "migrate opt-in")
            preferences.set(.spotify, for: .notch, defaults: defaults)
            expect(preferences.standby == legacy, "notch cannot change standby")
            expect(defaults.string(forKey: "playerPreference") == legacy.rawValue, "preserve old standby key")
            preferences.set(.music, for: .standby, defaults: defaults)
            expect(preferences.notch == .spotify, "standby cannot change notch")
            preferences = SurfacePlaybackPreferences(defaults: defaults)
            expect(preferences.preference(for: .notch) == .spotify, "persist notch")
            expect(preferences.preference(for: .standby) == .music, "persist standby")
            defaults.set(false, forKey: "notchMusicEnabled")
            _ = SurfacePlaybackPreferences(defaults: defaults)
            expect(!defaults.bool(forKey: "notchMusicEnabled") && defaults.bool(forKey: "musicEnabled"), "never overwrite a later opt-out")
        }
        for installed: Set<PlayerSource> in [[], [.music], [.spotify], [.music, .spotify]] {
            let options = PlayerSelectionPolicy.options(installed: installed)
            expect(options.first == .automatic, "Automatic stays available")
            expect(options.count == installed.count + 1, "only installed explicit options")
            expect(options.dropFirst().allSatisfy { $0.source.map(installed.contains) ?? false }, "no unavailable option")
        }
        let music = PlayerCandidate(source: .music, status: "ok", playing: true)
        let spotify = PlayerCandidate(source: .spotify, status: "ok", playing: true)
        for preferred in PlayerSource.allCases {
            for firstState in ["ok", "notRunning", "stopped", "denied", "error", "transition"] {
                for secondState in ["ok", "notRunning", "stopped", "denied", "error", "transition"] {
                    let candidates = [PlayerCandidate(source: .music, status: firstState, playing: firstState == "ok"),
                                      PlayerCandidate(source: .spotify, status: secondState, playing: secondState == "ok")]
                    let choice = PlayerSelectionPolicy.choose(candidates, preference: .automatic, preferred: preferred, previouslyPlaying: [.music, .spotify])
                    let playing = candidates.filter { $0.status == "ok" }
                    expect(choice == (playing.first(where: { $0.source == preferred })?.source ?? playing.first?.source), "playing provider beats absent/denied/transition")
                    for explicit: PlayerPreference in [.music, .spotify] {
                        expect(PlayerSelectionPolicy.choose(candidates, preference: explicit, preferred: preferred, previouslyPlaying: []) == explicit.source, "explicit never switches provider")
                    }
                }
            }
        }
        expect(PlayerSelectionPolicy.choose([music, spotify], preference: .automatic, preferred: .music, previouslyPlaying: [.music]) == .spotify, "newly playing Spotify wins")
        expect(PlayerSelectionPolicy.choose([music, spotify], preference: .automatic, preferred: .spotify, previouslyPlaying: [.spotify]) == .music, "newly playing Music wins")
        expect(PlayerSelectionPolicy.choose([PlayerCandidate(source: .music, status: "ok", playing: false), spotify], preference: .automatic, preferred: .music, previouslyPlaying: []) == .spotify, "paused cannot mask playing")
        expect(PlayerSelectionPolicy.choose([], preference: .automatic, preferred: .music, previouslyPlaying: []) == nil, "no invented player")
        for x: CGFloat in [0, -1512, 1920] {
            for y: CGFloat in [0, -982, 1080] {
                let screen = CGRect(x: x, y: y, width: 1512, height: 982)
                let left = CGRect(x: x, y: screen.maxY - 32, width: 656, height: 32)
                let right = CGRect(x: x + 856, y: screen.maxY - 32, width: 656, height: 32)
                let geometry = NotchGeometry.resolve(frame: screen, safeTop: 32, left: left, right: right, scale: 2)
                let compact = geometry.frame(expanded: false)
                let activation = NotchHoverGeometry.activation(compact: compact, screen: screen)
                let center = CGPoint(x: compact.midX, y: screen.maxY)
                expect(NotchHoverGeometry.contains(center, in: activation), "exact camera/top edge is included")
                expect(NotchHoverGeometry.contains(CGPoint(x: compact.midX, y: screen.maxY - 16), in: activation), "camera center")
                expect(NotchHoverGeometry.contains(CGPoint(x: compact.midX, y: compact.minY - 10), in: activation), "lower activation boundary")
                expect(!NotchHoverGeometry.contains(CGPoint(x: compact.midX, y: compact.minY - 10.01), in: activation), "do not open far below")
                expect(!NotchHoverGeometry.contains(CGPoint(x: compact.midX, y: screen.maxY + 1), in: activation), "do not capture other screen")
                expect(screen.contains(activation), "activation stays on selected display")
                expect(NotchHoverGeometry.contains(center, in: NotchHoverGeometry.watchRegion(compact: compact, screen: screen)), "missing-event recovery includes camera")
                let expanded = geometry.frame(expanded: true, tab: .music)
                expect(expanded.height == 190 && expanded.width == 360, "smaller music surface")
                expect(expanded.maxY == compact.maxY, "top edge never moves")
                for tab in NotchTab.allCases where tab != .music {
                    expect(geometry.frame(expanded: true, tab: tab).height == 272, "functional room for widgets")
                }
            }
        }
        expect(!NotchHoverGeometry.contains(CGPoint(x: CGFloat.nan, y: 0), in: CGRect(x: 0, y: 0, width: 10, height: 10)), "reject invalid pointer")
        expect(NotchHoverGeometry.openingDelay == 35_000_000, "35 ms dwell configuration")
        expect(NotchHoverGeometry.animationDuration == 0.16, "160 ms transition configuration")
        print("PASS: \(count) player-selection and camera-hover checks.")
    }
}
