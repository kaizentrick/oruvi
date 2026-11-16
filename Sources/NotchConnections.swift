// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppKit
import SwiftUI

struct CodexVectorIcon: View {
    var size: CGFloat = 14
    private static let vectorImage: NSImage = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
        <path fill="#000000" d="M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"/>
        </svg>
        """
        let image = NSImage(data: Data(svg.utf8)) ?? NSImage()
        image.isTemplate = true
        return image
    }()
    var body: some View {
        Image(nsImage: Self.vectorImage)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct NotchConnectionsView: View {
    @Bindable var model: StandbyModel
    @Bindable var controller: NotchController
    @Bindable private var usage = CodexUsageController.shared
    @Bindable private var widgets = NativeWidgetController.shared
    @State private var cursor = CursorConnection.shared
    @State private var detail: UsageDetail?

    private enum UsageDetail { case codex, cursor }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let detail {
                    Button { self.detail = nil } label: {
                        Label("Conexiones", systemImage: "chevron.left").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                    switch detail {
                    case .codex: CodexConnectionView(usage: usage)
                    case .cursor: cursorDetail
                    }
                } else {
                    Text("Conexiones").font(.system(size: 13, weight: .semibold))
                    Button { detail = .codex } label: {
                        HStack(spacing: 10) {
                            CodexVectorIcon(size: 15).frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Codex").font(.system(size: 12, weight: .medium))
                                Text(usage.status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: usage.hasCurrentQuota ? "checkmark" : "chevron.right")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }.frame(minHeight: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("Ver límites de uso y fijarlos al notch")
                    Button { detail = .cursor } label: {
                        connection("Cursor", detail: cursor.summary, symbol: "gauge.with.dots.needle.33percent",
                                   ready: cursor.currentSnapshot != nil)
                    }.buttonStyle(.plain)
                    Divider().overlay(.white.opacity(0.08))
                    Button { controller.select(.music) } label: {
                        connection("Reproducción", detail: model.connected ? model.connectionStatus : "Conectar Apple Music, Spotify o Ahora suena", symbol: "music.note", ready: model.connected)
                    }.buttonStyle(.plain)
                    Button { controller.select(.agenda) } label: {
                        connection("Calendario", detail: controller.agenda.enabled ? "Revisar agenda y permisos" : "Sin conectar · solo lectura", symbol: "calendar", ready: controller.agenda.enabled && controller.agenda.access == .fullAccess)
                    }.buttonStyle(.plain)
                    Button { controller.afterMenu { model.showNativeWidgetSettings() } } label: {
                        connection("Widgets de macOS", detail: widgets.storageError.isEmpty ? (widgets.installedCount > 0 ? "\(widgets.installedCount) añadidos" : "Añadir al escritorio") : "Revisar acceso a datos", symbol: "square.grid.2x2", ready: widgets.installedCount > 0 && widgets.storageError.isEmpty)
                    }.buttonStyle(.plain)
                }
            }.padding(.vertical, 2).padding(.trailing, 4)
        }
        .scrollIndicators(.automatic)
        .task(id: cursor.refreshID) { await cursor.poll() }
    }

    private var cursorDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "gauge.with.dots.needle.33percent").accessibilityHidden(true)
                Text("Cursor").font(.system(size: 14, weight: .semibold))
                Spacer()
                if cursor.refreshing { ProgressView().controlSize(.mini).accessibilityLabel("Consultando Grok") }
                if cursor.enabled {
                    Button { cursor.refresh() } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
                    }.buttonStyle(.plain).disabled(cursor.refreshing).help("Actualizar uso de Cursor")
                        .accessibilityLabel("Actualizar uso de Cursor")
                }
            }
            if let snapshot = cursor.currentSnapshot {
                Text("≈\(snapshot.remainingPercent)% restante").font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                ProgressView(value: Double(snapshot.remainingPercent), total: 100)
                    .tint(snapshot.remainingPercent <= 10 ? .orange : .white)
                    .accessibilityLabel("Cuota semanal restante")
                Text("Reinicio: \(snapshot.resetLabel)").font(.system(size: 11))
                Text("Última consulta: " + snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            } else if cursor.enabled {
                Text(cursor.summary).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            }
            Text("Cuota semanal incluida que comparten Cursor y Grok. Se actualiza al abrir Conexiones mediante tu sesión de Grok en Aside.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if cursor.enabled {
                Button("Desconectar") { cursor.setEnabled(false) }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Button("Conectar Cursor") { cursor.setEnabled(true) }.controlSize(.small)
            }
        }
    }
    private func connection(_ title: String, detail: String, symbol: String, ready: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .medium))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: ready ? "checkmark" : "chevron.right")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }.frame(minHeight: 32).contentShape(Rectangle())
    }
}

@MainActor @Observable
private final class CursorConnection {
    static let shared = CursorConnection()
    private(set) var enabled = LumaEnvironment.preferences.bool(forKey: "cursorUsageEnabled")
    private(set) var refreshID = UUID()
    private var snapshot: CursorUsageSnapshot?
    private(set) var refreshing = false
    private var error: CursorUsageError?
    @ObservationIgnored private var activeRequest: UUID?

    var currentSnapshot: CursorUsageSnapshot? {
        guard enabled, snapshot?.isFresh(at: Date()) == true else { return nil }
        return snapshot
    }
    var summary: String {
        if !enabled { return "Sin conectar" }
        if let snapshot = currentSnapshot { return "≈\(snapshot.remainingPercent)% restante · Reinicio: \(snapshot.resetLabel)" }
        if let error { return error.message }
        return "Consultando Grok…"
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        LumaEnvironment.preferences.set(enabled, forKey: "cursorUsageEnabled")
        refresh()
    }

    func refresh() {
        snapshot = nil
        error = nil
        refreshID = UUID()
    }

    func poll() async {
        guard enabled, !LumaEnvironment.isTesting else { return }
        let interval = CursorUsageSnapshot.maximumAge
        while !Task.isCancelled {
            if let snapshot = currentSnapshot {
                let wait = snapshot.fetchedAt.addingTimeInterval(interval).timeIntervalSinceNow
                if wait > 0 && wait <= interval {
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                }
            }
            snapshot = nil
            let id = UUID()
            activeRequest = id
            refreshing = true
            let result: Result<CursorUsageSnapshot, Error>
            do { result = .success(try await CursorUsageRequest().read()) }
            catch { result = .failure(error) }
            guard activeRequest == id else { return }
            activeRequest = nil
            refreshing = false
            guard !Task.isCancelled, enabled else { return }
            switch result {
            case .success(let reading):
                snapshot = reading
                error = nil
            case .failure(let failure):
                snapshot = nil
                error = failure as? CursorUsageError ?? .unavailable
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }
}

struct CodexConnectionView: View {
    @Bindable var usage: CodexUsageController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                CodexVectorIcon(size: 14)
                Text("Codex").font(.system(size: 14, weight: .semibold))
                Spacer()
                if usage.refreshing { ProgressView().controlSize(.mini).accessibilityLabel("Consultando uso") }
                if usage.enabled {
                    Button { usage.refresh() } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).disabled(usage.refreshing).help("Actualizar uso").accessibilityLabel("Actualizar uso de Codex")
                }
            }
            if usage.enabled {
                Text(usage.status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let snapshot = usage.snapshot {
                    if snapshot.buckets.count > 1 {
                        Picker("Límite", selection: Binding(get: { usage.selectedBucket?.id ?? usage.selectedBucketID }, set: { usage.selectedBucketID = $0 })) {
                            ForEach(snapshot.buckets) { Text($0.title).tag($0.id) }
                        }.controlSize(.small)
                    }
                    if let bucket = usage.selectedBucket {
                        ForEach(Array(bucket.windows.enumerated()), id: \.offset) { _, window in
                            CodexUsageWindowView(window: window, current: usage.fresh && window.isCurrent(at: usage.now))
                        }
                    }
                    Text("Última consulta: " + snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Toggle("Uso visible en el notch", isOn: $usage.pinned).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                Text("El compacto muestra el menor porcentaje restante de los límites vigentes. Se consulta cada minuto mientras tu Mac está activa.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Abrir Codex") { openCodex() }.controlSize(.small)
                    Spacer()
                    Button("Desconectar") { usage.disconnect() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("Tus límites y reinicios, a un vistazo. Puedes dejar el porcentaje restante visible en el notch.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Button("Conectar Codex") { usage.connect() }.controlSize(.small)
                Text("Usa la sesión de ChatGPT de Codex en esta Mac. Oruvi solo consulta el uso: no inicia tareas ni guarda credenciales. Las cuentas con API key pueden no informar de estos límites.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func openCodex() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex")!); return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct CodexUsageWindowView: View {
    let window: CodexUsageWindow
    let current: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(window.title)
                Spacer()
                Text(current ? "\(window.remainingPercent)% restante" : "Pendiente de actualizar").monospacedDigit()
            }.font(.system(size: 11, weight: .medium))
            if current {
                ProgressView(value: Double(window.remainingPercent), total: 100)
                    .tint(window.remainingPercent <= 10 ? .orange : .white)
                    .accessibilityLabel("\(window.title), porcentaje restante")
                    .accessibilityValue("\(window.remainingPercent) por ciento")
            }
            if let reset = window.resetDate {
                Text("Reinicio: " + reset.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
