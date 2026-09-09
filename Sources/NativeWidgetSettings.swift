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
            Text("Conectar y actualizar recupera el estado del reproductor seleccionado sin iniciar ni pausar contenido. También puedes usar la flecha circular del widget. Si macOS solicita acceso a datos compartidos, autorízalo para que la app y la extensión puedan leer el mismo estado.")
                .font(.caption).foregroundStyle(.secondary)
            Text("La distribución actual utiliza firma ad-hoc: el acceso a App Groups puede requerir autorización de macOS. No necesitas acceso completo al disco ni desactivar protecciones. Una firma Developer ID y un perfil que autorice el grupo son necesarios para eliminar esa dependencia de consentimiento.")
                .font(.caption).foregroundStyle(.secondary)
            Text("El widget usa el reproductor activo de Oruvi y conserva los selectores independientes del Notch y Standby. macOS administra posición, tamaño, apariencia y frecuencia de actualización. Se comparte una sola instantánea con una miniatura, sin historial ni otra ventana o bucle musical.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

@MainActor extension StandbyModel {
    func showNativeWidgetSettings() { showWindow(); settingsOpen = true }
}
