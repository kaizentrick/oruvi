// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI
import WidgetKit
import AppIntents

struct OruviWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}
struct OruviWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> OruviWidgetEntry {
        OruviWidgetEntry(date: Date(), snapshot: .placeholder())
    }
    func getSnapshot(in context: Context, completion: @escaping (OruviWidgetEntry) -> Void) {
        let now = Date()
        completion(OruviWidgetEntry(date: now, snapshot: context.isPreview ? .placeholder(at: now) : current(at: now)))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<OruviWidgetEntry>) -> Void) {
        if context.isPreview {
            completion(Timeline(entries: [placeholder(in: context)], policy: .never)); return
        }
        // Hint is metadata-free and never sends a playback command or opts in.
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(OruviWidgetIdentity.requested), object: nil, userInfo: nil, deliverImmediately: true)
        // Give the running host one bounded, asynchronous opportunity to publish.
        // Reading before the hint used to archive the empty state for 15 minutes.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.6) {
            let now = Date(), value = current()
            let expiry = max(now.addingTimeInterval(300), value.generatedAt.addingTimeInterval(WidgetSnapshot.maximumAge))
            let expired = WidgetSnapshotRead.expired.presentation(at: expiry)
            let entries = [OruviWidgetEntry(date: now, snapshot: value), OruviWidgetEntry(date: expiry, snapshot: expired)]
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(900))))
        }
    }
    private func current(at date: Date = Date()) -> WidgetSnapshot {
        WidgetSnapshotStore.shared().load(at: date).presentation(at: date)
    }
}

@main
struct OruviNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: OruviWidgetIdentity.kind, provider: OruviWidgetProvider()) { entry in
            OruviWidgetView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Música y Standby")
        .description("Controla lo que se reproduce en tu Mac y abre Standby desde el escritorio.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OruviWidgetView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family
    private var small: Bool { family == .systemSmall }
    var body: some View {
        Group { if small { compact } else { regular } }
            .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
            .widgetURL(snapshot.canControl ? OruviWidgetIdentity.standbyURL : OruviWidgetIdentity.settingsURL)
    }
    private var compact: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                cover.frame(width: 46, height: 46)
                Spacer(minLength: 4)
                refreshButton
                standbyLink
            }
            heading
            Spacer(minLength: 0)
            transport
        }
    }
    private var regular: some View {
        HStack(spacing: 15) {
            cover.frame(width: 94, height: 94)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Text(snapshot.sourceName).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    refreshButton
                    standbyLink
                }
                heading
                Spacer(minLength: 0)
                transport
            }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.title).font(.system(size: small ? 13 : 15, weight: .semibold))
                .lineLimit(small ? 1 : 2).minimumScaleFactor(0.85)
            Text(snapshot.message.isEmpty ? snapshot.artist : snapshot.message)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .privacySensitive(snapshot.state == .ready)
        .invalidatableContent()
    }
    private var cover: some View {
        Group {
            if let data = snapshot.artwork, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.06))
                    .overlay { Image(systemName: "music.note").font(.system(size: small ? 23 : 35, weight: .light)).foregroundStyle(.secondary) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Portada de " + snapshot.title)
        .privacySensitive(snapshot.state == .ready)
    }
    private var refreshButton: some View {
        Button(intent: OruviWidgetPlaybackIntent(.refresh, snapshot: snapshot)) {
            Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)).frame(width: 24, height: 28)
        }.buttonStyle(.plain).disabled(!snapshot.canRefresh)
            .accessibilityLabel("Conectar y actualizar reproducción sin reproducir ni pausar")
    }
    private var standbyLink: some View {
        Link(destination: OruviWidgetIdentity.standbyURL) {
            Image(systemName: "rectangle.inset.filled").font(.system(size: 14, weight: .medium)).frame(width: 24, height: 28)
        }.buttonStyle(.plain).accessibilityLabel("Abrir Standby")
    }
    @ViewBuilder private var transport: some View {
        if snapshot.canControl {
            HStack(spacing: small ? 9 : 14) {
                control(.previous, symbol: "backward.end.fill", title: "Anterior")
                control(.toggle, symbol: snapshot.playing ? "pause.fill" : "play.fill", title: snapshot.playing ? "Pausar" : "Reproducir")
                control(.next, symbol: "forward.end.fill", title: "Siguiente")
            }.frame(maxWidth: .infinity)
        } else {
            Button(intent: OruviWidgetPlaybackIntent(.refresh, snapshot: snapshot)) {
                Label(snapshot.state == .closed || snapshot.state == .disconnected ? "Conectar" : "Actualizar", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, minHeight: 30)
            }.buttonStyle(.bordered).disabled(!snapshot.canRefresh)
                .accessibilityLabel("Conectar y actualizar Oruvi")
        }
    }
    private func control(_ action: OruviWidgetCommand, symbol: String, title: String) -> some View {
        Button(intent: OruviWidgetPlaybackIntent(action, snapshot: snapshot)) {
            Image(systemName: symbol).font(.system(size: action == .toggle ? 17 : 13, weight: .semibold))
                .frame(width: 30, height: 30)
                .background(.primary.opacity(action == .toggle ? 0.07 : 0), in: Circle())
        }.buttonStyle(.plain)
            .disabled(!snapshot.canControl || (action != .toggle && !snapshot.canSkip))
            .accessibilityLabel(title).invalidatableContent()
    }
}
