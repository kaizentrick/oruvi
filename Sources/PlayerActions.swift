// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit

@MainActor
extension StandbyModel {
    func openInstalledPlayer() {
        // Automatic must still be useful when only one supported app is installed.
        // Do not silently substitute another provider for an explicit preference.
        if effectivePlayerPreference == .automatic && !hasTrack {
            let installed = PlayerSource.allCases.filter {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.rawValue) != nil
            }
            if !installed.contains(activePlayer), let first = installed.first { activePlayer = first }
        }
        openMusic()
    }
}
