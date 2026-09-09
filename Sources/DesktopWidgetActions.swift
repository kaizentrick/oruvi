// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit

extension Notification.Name {
    static let oruviRevealDesktopWidget = Notification.Name("com.kaizentrick.Oruvi.revealDesktopWidget")
}

@MainActor
extension StandbyModel {
    /// Explicit Show is idempotent, unlike the former checked toggle. It never
    /// starts playback, changes a provider, or overrides a music opt-out.
    func revealDesktopWidget() {
        guard !screenSleeping else { return }
        desktopWidgetEnabled = true
        settingsOpen = false
        notch?.collapse()
        dismissStandby()
        NotificationCenter.default.post(name: .oruviRevealDesktopWidget, object: nil)
    }
}
