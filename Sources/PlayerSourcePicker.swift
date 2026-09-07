// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class InstalledPlayers {
    static let shared = InstalledPlayers()
    private(set) var sources: Set<PlayerSource> = []
    private(set) var checked = false
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var lastCheck = -Double.greatestFiniteMagnitude
    func refresh() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !checking, now - lastCheck > 2 else { return }
        checking = true; lastCheck = now
        Task {
            let detected = await Task.detached(priority: .utility) {
                Set(PlayerSource.allCases.filter {
                    NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.rawValue) != nil ||
                    !NSRunningApplication.runningApplications(withBundleIdentifier: $0.rawValue).isEmpty
                })
            }.value
            sources = detected; checked = true; checking = false
        }
    }
}

struct PlayerSourceMenuItems: View {
    @Binding var selection: PlayerPreference
    let surface: PlaybackSurface
    let activePlayer: PlayerSource?
    private var inventory: InstalledPlayers { .shared }
    var body: some View {
        Text(surface.title + (activePlayer.map { " · " + $0.name } ?? ""))
        ForEach(PlayerSelectionPolicy.options(installed: inventory.sources)) { option in
            Button { selection = option } label: {
                if selection == option { Label(option.name, systemImage: "checkmark") }
                else { Text(option.name) }
            }
        }
        if let source = selection.source, inventory.checked, !inventory.sources.contains(source) {
            Text(source.name + " · no instalado")
        }
        if inventory.checked && inventory.sources.isEmpty { Text("Instala Apple Music o Spotify para reproducir.") }
        Divider()
        Text("Solo cambia " + surface.title)
    }
}

struct PlayerSourcePicker: View {
    @Binding var selection: PlayerPreference
    let surface: PlaybackSurface
    let activePlayer: PlayerSource?
    var body: some View {
        Menu {
            PlayerSourceMenuItems(selection: $selection, surface: surface, activePlayer: activePlayer)
        } label: {
            Text(selection.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .help("Reproductor de \(surface.title): \(selection.name)" + (activePlayer.map { ". Controlando " + $0.name } ?? ""))
        .accessibilityLabel("Reproductor de " + surface.title)
        .accessibilityValue(selection.name)
        .onAppear { InstalledPlayers.shared.refresh() }
        .onHover { if $0 { InstalledPlayers.shared.refresh() } }
    }
}
