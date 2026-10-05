// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import SwiftUI

struct NotchConnectionsView: View {
    @Bindable var model: StandbyModel
    @Bindable var controller: NotchController
    @Bindable private var usage = CodexUsageController.shared
    @Bindable private var widgets = NativeWidgetController.shared
    @State private var codexDetail = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if codexDetail {
                    Button { codexDetail = false } label: {
                        Label("Conexiones", systemImage: "chevron.left").font(.system(size: 11))
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                    CodexConnectionView(usage: usage)
                } else {
                    Text("Conexiones").font(.system(size: 13, weight: .semibold))
                    Button { codexDetail = true } label: {
                        connection("Codex", detail: usage.status, symbol: "chevron.left.forwardslash.chevron.right", ready: usage.fresh)
                    }.buttonStyle(.plain).accessibilityHint("Ver límites de uso y fijarlos al notch")
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
        }.scrollIndicators(.automatic)
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

struct CodexConnectionView: View {
    @Bindable var usage: CodexUsageController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
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
