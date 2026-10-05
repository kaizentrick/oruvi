// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import SwiftUI

struct NativeWidgetSettings: View {
    @Bindable private var widgets = NativeWidgetController.shared
    var body: some View {
        Section("Widgets nativos de macOS") {
            Label("Oruvi · Música y Standby", systemImage: "square.grid.2x2")
            Text("Clic secundario en el escritorio → Editar widgets → busca Oruvi. Elige el tamaño pequeño o mediano.").font(.callout)
            Text(widgets.status).font(.caption).foregroundStyle(.secondary)
            if let date = widgets.lastPublishedAt {
                LabeledContent("Último estado compartido", value: date.formatted(date: .omitted, time: .standard)).font(.caption)
            }
            Button("Conectar y actualizar widgets") { widgets.refreshNow() }
            Text("Si el widget no responde, pulsa Conectar y actualizar. Recupera la música sin iniciar ni pausar contenido; no necesitas quitar el widget. Si macOS pide acceso a datos compartidos de Oruvi, autorízalo.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Abre Oruvi desde Aplicaciones al menos una vez para que macOS pueda encontrar sus widgets. macOS decide cuándo refrescarlos; el notch muestra el estado mientras usas la app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor extension StandbyModel {
    func showNativeWidgetSettings() { showWindow(); settingsOpen = true }
}
