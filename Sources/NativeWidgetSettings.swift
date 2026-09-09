// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import SwiftUI

struct NativeWidgetSettings: View {
    @Bindable private var widgets = NativeWidgetController.shared
    var body: some View {
        Section("Widgets nativos de macOS") {
            Label("Oruvi · Música y Standby", systemImage: "square.grid.2x2")
            Text("Clic secundario en el escritorio → Editar widgets → busca Oruvi. Elige el tamaño pequeño o mediano y arrástralo al escritorio.")
                .font(.callout)
            Text("macOS administra su posición, tamaño y apariencia. La tarjeta flotante anterior se ha retirado; no se añade ninguna ventana al escritorio.")
                .font(.caption).foregroundStyle(.secondary)
            Text(widgets.status).font(.caption).foregroundStyle(.secondary)
            Button("Actualizar estado de widgets") { widgets.refreshNow() }
            Text("El widget muestra el reproductor activo de Oruvi y conserva los selectores del Notch y Standby. macOS decide cuándo refrescar la portada; los botones comprueban el contenido antes de actuar. Oruvi comparte solo el estado actual y una miniatura local, sin historial.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor extension StandbyModel {
    func showNativeWidgetSettings() { showWindow(); settingsOpen = true }
}
