import AppKit
import SwiftUI
import Sparkle

@MainActor
final class OruviUpdates: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    static let shared = OruviUpdates()
    @Published private(set) var repository = ""
    @Published private(set) var status = "Pendiente de publicar el repositorio"
    @Published private(set) var availableVersion: String?
    @Published private(set) var lastChecked: Date?
    private var controller: SPUStandardUpdaterController!
    private var started = false

    override private init() {
        super.init()
        repository = LumaEnvironment.preferences.string(forKey: "updatesRepository")
            ?? (Bundle.main.object(forInfoDictionaryKey: "OruviUpdateRepository") as? String ?? "")
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }
    var configured: Bool { UpdateConfiguration.repository(repository) != nil && UpdateConfiguration.hasEmbeddedKey }
    var canCheck: Bool { configured && (controller.updater.canCheckForUpdates || availableVersion != nil) }
    var automaticChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
    var automaticDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }
    func startIfConfigured() {
        guard !started, !LumaEnvironment.isTesting else { return }
        guard configured else { status = "Pendiente de configurar un repositorio con versiones firmadas"; return }
        controller.startUpdater()
        started = true
        status = "Actualizaciones desde \(repository)"
        // Sparkle owns the timer. No extra poller, no requests on music/lyric ticks.
        if automaticChecks { controller.updater.checkForUpdatesInBackground() }
    }
    func configure(repository value: String) {
        guard let validated = UpdateConfiguration.repository(value) else {
            status = "Escribe el repositorio como propietario/nombre"; return
        }
        repository = validated
        LumaEnvironment.preferences.set(validated, forKey: "updatesRepository")
        availableVersion = nil
        status = "Repositorio configurado: \(validated)"
        if started { controller.updater.resetUpdateCycleAfterShortDelay() }
        else { startIfConfigured() }
    }
    func checkNow() {
        guard configured else {
            StandbyModel.shared.showWindow()
            StandbyModel.shared.settingsOpen = true
            status = "Primero configura el repositorio publicado"; return
        }
        startIfConfigured()
        StandbyModel.shared.dismissStandby()
        controller.checkForUpdates(nil)
    }
    func feedURLString(for updater: SPUUpdater) -> String? { UpdateConfiguration.feed(for: repository)?.absoluteString }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        lastChecked = Date()
        status = "Nueva versión disponible: \(item.displayVersionString)"
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil; lastChecked = Date(); status = "Esta instalación está actualizada"
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        status = "No se pudo comprobar el feed. Verifica conexión y publicación de appcast.xml."
    }
    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // Never steal focus over a film or an ambient presentation.
        false
    }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        if state.userInitiated { StandbyModel.shared.dismissStandby() }
    }
    func standardUserDriverWillShowModalAlert() { StandbyModel.shared.dismissStandby() }
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) { availableVersion = nil }
}

struct UpdatesSettings: View {
    @ObservedObject private var updates = OruviUpdates.shared
    @State private var draft = ""
    var body: some View {
        Section("Actualizaciones") {
            Text(updates.status).font(.callout)
            LabeledContent("Repositorio público") {
                TextField("propietario/oruvi", text: $draft).textFieldStyle(.roundedBorder).frame(width: 220)
            }
            HStack {
                Button("Guardar repositorio") { updates.configure(repository: draft) }
                    .disabled(UpdateConfiguration.repository(draft) == nil)
                Button("Buscar actualizaciones…") { updates.checkNow() }.disabled(!updates.configured)
            }
            Toggle("Buscar versiones nuevas automáticamente", isOn: Binding(get: { updates.automaticChecks }, set: { updates.automaticChecks = $0 }))
                .disabled(!updates.configured)
            Toggle("Descargar e instalar al salir cuando sea posible", isOn: Binding(get: { updates.automaticDownloads }, set: { updates.automaticDownloads = $0 }))
                .disabled(!updates.configured)
            Text("Se comprueban versiones publicadas, no commits sueltos. Sparkle verifica la firma del feed y del instalador antes de instalar. Las comprobaciones usan GitHub y no envían datos de Música. No se fuerza el reinicio durante una reproducción.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { draft = updates.repository }
    }
}
