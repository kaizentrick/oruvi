// Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT
import AppIntents
import Foundation

enum OruviWidgetCommand: String, AppEnum {
    case previous, toggle, next, refresh
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Control de reproducción"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .previous: "Anterior", .toggle: "Reproducir o pausar", .next: "Siguiente", .refresh: "Conectar y actualizar"
    ]
}

/// AudioPlaybackIntent executes in the containing app, including cold launches.
/// Recovery is separate from transport: it does not toggle or start playback.
struct OruviWidgetPlaybackIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource = "Controlar reproducción con Oruvi"
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = false
    @Parameter(title: "Acción") var command: OruviWidgetCommand
    @Parameter(title: "Sesión") var session: String
    @Parameter(title: "Contenido") var trackID: String
    @Parameter(title: "Fuente") var sourceID: String
    @Parameter(title: "Selección") var preference: String
    init() {}
    init(_ command: OruviWidgetCommand, snapshot: WidgetSnapshot) {
        self.command = command; session = snapshot.session; trackID = snapshot.trackID
        sourceID = snapshot.sourceID; preference = snapshot.preference
    }
    @MainActor func perform() async throws -> some IntentResult {
        #if !ORUVI_WIDGET_EXTENSION
        await NativeWidgetController.shared.perform(command: command.rawValue, session: session,
            trackID: trackID, sourceID: sourceID, preference: preference)
        #endif
        return .result()
    }
}
