// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import Foundation

/// Deep links are navigation only, never a transport command or a script runner.
enum OruviWidgetRoute {
    case standby, widgets, player, music, spotify
    init?(url: URL) {
        guard url.scheme == "oruvi", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        if url.host == "player" {
            switch url.path {
            case "", "/": self = .player
            case "/music": self = .music
            case "/spotify": self = .spotify
            default: return nil
            }
            return
        }
        guard url.path.isEmpty || url.path == "/" else { return nil }
        switch url.host {
        case "standby": self = .standby
        case "widgets": self = .widgets
        default: return nil
        }
    }
}
