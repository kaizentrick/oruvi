import Foundation

@main struct VerifyDesktopWidget {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            count += 1; precondition(value(), label)
        }
        let suite = "com.kaizentrick.Oruvi.widget-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        check(DesktopWidgetPolicy.initialVisibility(defaults: defaults), "Missing setting exposes new widget")
        check(defaults.bool(forKey: DesktopWidgetPolicy.enabledKey), "Initial visibility saved")
        defaults.set(false, forKey: DesktopWidgetPolicy.enabledKey)
        for _ in 0..<3 { check(!DesktopWidgetPolicy.initialVisibility(defaults: defaults), "Explicit hide survives updates") }
        defaults.set(true, forKey: DesktopWidgetPolicy.enabledKey)
        check(DesktopWidgetPolicy.initialVisibility(defaults: defaults), "Explicit show preserved")
        check(DesktopWidgetPolicy.consumeIntroduction(defaults: defaults, enabled: true), "One introduction")
        check(!DesktopWidgetPolicy.consumeIntroduction(defaults: defaults, enabled: true), "No repeated introduction")
        defaults.removeObject(forKey: DesktopWidgetPolicy.introductionKey)
        check(!DesktopWidgetPolicy.consumeIntroduction(defaults: defaults, enabled: false), "No introduction after opt-out")
        check(!DesktopWidgetPolicy.consumeIntroduction(defaults: defaults, enabled: true), "Opt-out respected after restart")
        for enabled in [false, true] { for standby in [false, true] { for sleeping in [false, true] {
            check(DesktopWidgetPolicy.visible(enabled: enabled, standby: standby, sleeping: sleeping) == (enabled && !standby && !sleeping), "Visibility truth table")
        } } }
        let main = CGRect(x: 0, y: 24, width: 1440, height: 850)
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1050)
        let upper = CGRect(x: 0, y: 1200, width: 2560, height: 1440)
        let screens = [main, left, upper]
        for screen in screens {
            let result = DesktopWidgetPolicy.frame(saved: nil, screens: screens, preferred: screen, reset: true)!
            check(screen.contains(result), "Reset contained on chosen display")
            check(result.size == DesktopWidgetPolicy.size, "Known current size")
            check(result.maxY == screen.maxY - 16, "Predictable top placement")
        }
        for origin in [CGPoint(x: -5000, y: 8000), CGPoint(x: 6000, y: -5000), CGPoint(x: 10, y: 30), CGPoint(x: -1800, y: 100), CGPoint(x: 1500, y: 1900)] {
            let result = DesktopWidgetPolicy.frame(saved: CGRect(origin: origin, size: CGSize(width: 344, height: 190)), screens: screens, preferred: main, reset: false)!
            check(screens.contains { $0.contains(result) }, "Off-screen recovery")
            check(result.size == DesktopWidgetPolicy.size, "Old dimensions normalized")
        }
        let old = CGRect(x: -1800, y: 100, width: 344, height: 190)
        check(DesktopWidgetPolicy.frame(saved: old, screens: screens, preferred: main, reset: false)!.minX == old.minX, "Keep existing display")
        check(main.contains(DesktopWidgetPolicy.frame(saved: old, screens: [main], preferred: main, reset: false)!), "Disconnected monitor recovered")
        check(main.contains(DesktopWidgetPolicy.frame(saved: old, screens: screens, preferred: main, reset: true)!), "Explicit reset chooses pointer display")
        check(DesktopWidgetPolicy.frame(saved: old, screens: [], preferred: nil, reset: false) == nil, "No screen is safe")
        let corrupt = CGRect(x: Double.nan, y: 0, width: 344, height: 212)
        check(main.contains(DesktopWidgetPolicy.frame(saved: corrupt, screens: [main], preferred: main, reset: false)!), "Invalid saved coordinates discarded")
        print("PASS: \(count) desktop widget preference, discovery and screen-geometry checks.")
    }
}
