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
            StandbyModel.shared.settingsSection = .updates
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
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        availableVersion = nil
        if let result = Self.noUpdateStatus(for: error) {
            lastChecked = Date()
            status = result
        } else {
            status = Self.failureStatus(for: error)
        }
    }

    static func failureStatus(for error: Error) -> String {
        var underlying: NSError? = error as NSError
        var status: String?
        // Sparkle wraps signature failures inside appcast or installation errors.
        for _ in 0..<4 {
            guard let cause = underlying else { break }
            if cause.domain == SUSparkleErrorDomain, let code = SUError(rawValue: Int32(clamping: cause.code)) {
                switch code {
                case .signatureError, .validationError, .notValidUpdateError:
                    return "No se pudo verificar la firma o la integridad de la actualización."
                case .downloadError:
                    status = status ?? "No se pudo descargar la actualización. Vuelve a intentarlo."
                case .installationCanceledError, .installationAuthorizeLaterError:
                    status = status ?? "Instalación pendiente. Puedes volver a buscar la actualización."
                case .installationWriteNoPermissionError:
                    return "No se pudo instalar la actualización. Revisa los permisos de Aplicaciones."
                case .installationError, .fileCopyFailure:
                    status = status ?? "No se pudo instalar la actualización. Vuelve a intentarlo."
                default: break
                }
            }
            underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return status ?? "No se pudo comprobar el catálogo de actualizaciones. Revisa la conexión y el repositorio."
    }

    static func noUpdateStatus(for error: Error) -> String? {
        let detail = error as NSError
        guard detail.domain == SUSparkleErrorDomain, detail.code == Int(SUError.noUpdateError.rawValue) else {
            return nil
        }
        let reason = (detail.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
            .flatMap { SPUNoUpdateFoundReason(rawValue: $0.int32Value) }
        switch reason {
        case .onLatestVersion: return "Oruvi está al día."
        case .onNewerThanLatestVersion: return "Esta compilación es más reciente que la versión publicada."
        case .systemIsTooOld, .systemIsTooNew: return "No hay una actualización compatible con esta versión de macOS."
        default: return "No hay actualizaciones disponibles."
        }
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
    @Binding var draft: String
    var body: some View {
        Section {
            Text(updates.status).font(.callout)
            LabeledContent("Repositorio público") {
                TextField("Repositorio público", text: $draft, prompt: Text("propietario/oruvi"))
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 220)
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
    }
}
