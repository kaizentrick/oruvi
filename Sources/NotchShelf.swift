import AppKit
import SwiftUI
import Observation

struct NotchShelfItem: Identifiable, Sendable {
    let url: URL
    let isDirectory: Bool
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@MainActor @Observable
final class NotchShelf: NSObject, NSSharingServiceDelegate {
    private(set) var items: [NotchShelfItem] = []
    var selected: Set<URL> = []
    var message = "Los originales no se mueven ni se copian."
    private(set) var importing = false
    private(set) var sharing = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var imports = 0
    @ObservationIgnored private var chooser: NSOpenPanel?
    @ObservationIgnored private var service: NSSharingService?
    @ObservationIgnored private weak var sharingOwner: NotchController?

    var sharingURLs: [URL] {
        items.filter { selected.isEmpty || selected.contains($0.url) }.map(\.url)
    }
    func add(_ urls: [URL]) {
        // Bound work before touching the filesystem. Validation never opens file contents.
        let candidates = NotchFilePolicy.candidates(urls, existing: [])
        guard !candidates.isEmpty else { message = "Arrastra archivos locales desde Finder."; return }
        let serial = generation
        imports += 1; importing = true
        Task { [weak self] in
            let available: [NotchShelfItem] = await Task.detached(priority: .utility) {
                candidates.compactMap { url in
                    var directory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
                          FileManager.default.isReadableFile(atPath: url.path) else { return nil }
                    return NotchShelfItem(url: url, isDirectory: directory.boolValue)
                }
            }.value
            guard let self, self.generation == serial else { return }
            self.imports = max(0, self.imports - 1); self.importing = self.imports > 0
            let accepted = Set(NotchFilePolicy.candidates(available.map(\.url), existing: self.items.map(\.url)))
            self.items.append(contentsOf: available.filter { accepted.contains($0.url) })
            if available.count < candidates.count {
                self.message = "Algunos archivos ya no existen o no se pueden leer."
            } else if accepted.isEmpty {
                self.message = self.items.count >= NotchFilePolicy.limit ? "Límite de 20 archivos. Retira alguno para añadir más." : "Estos archivos ya están en la bandeja."
            } else {
                self.message = self.items.count == NotchFilePolicy.limit ? "20 archivos · bandeja completa." : "Solo referencias temporales · hasta 20 archivos."
            }
        }
    }
    func remove(_ url: URL) { items.removeAll { $0.url == url }; selected.remove(url) }
    func clear() {
        generation += 1; imports = 0; importing = false
        items.removeAll(); selected.removeAll(); message = "Los originales no se mueven ni se copian."
    }
    func toggle(_ url: URL) {
        if selected.contains(url) { selected.remove(url) } else { selected.insert(url) }
    }
    func chooseFiles(controller: NotchController) {
        guard chooser == nil, !sharing else { return }
        controller.beginInteraction()
        let panel = NSOpenPanel()
        panel.title = "Añadir archivos a Oruvi"; panel.prompt = "Añadir"
        panel.allowsMultipleSelection = true; panel.canChooseFiles = true; panel.canChooseDirectories = true
        chooser = panel
        NSApp.activate()
        panel.begin { [weak self, weak controller] response in
            Task { @MainActor in
                if response == .OK { self?.add(panel.urls) }
                self?.chooser = nil; controller?.endInteraction()
            }
        }
    }
    func cancelChooser() { chooser?.cancel(nil) }
    func airDrop(controller: NotchController) {
        let urls = sharingURLs
        guard !urls.isEmpty, !sharing else { return }
        guard let native = NSSharingService(named: .sendViaAirDrop), native.canPerform(withItems: urls) else {
            message = "AirDrop no está disponible para esta selección en este Mac."; return
        }
        // macOS owns discovery, recipient selection and transport. No Bluetooth/Wi-Fi
        // toggles, private AirDrop APIs, automatic recipients or automatic transfers.
        controller.beginInteraction(); sharingOwner = controller
        sharing = true; service = native; native.delegate = self
        message = "Elige el destinatario en AirDrop."
        NSApp.activate()
        native.perform(withItems: urls)
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor [weak self] in self?.finishSharing("Enviado con AirDrop.") }
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let failure = error as NSError
        let cancelled = failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError
        Task { @MainActor [weak self] in self?.finishSharing(cancelled ? "Envío cancelado." : "No se completó el envío. Revisa AirDrop e inténtalo de nuevo.") }
    }
    private func finishSharing(_ text: String) {
        message = text; sharing = false; service?.delegate = nil; service = nil
        sharingOwner?.endInteraction(); sharingOwner = nil
    }
}

struct NotchShelfView: View {
    let shelf: NotchShelf
    let controller: NotchController
    var body: some View {
        VStack(spacing: 8) {
            if shelf.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: controller.draggingFiles ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                        .font(.system(size: 26, weight: .light))
                    Text(controller.draggingFiles ? "Suelta para añadir" : "Arrastra archivos al notch")
                        .font(.system(size: 13, weight: .medium))
                    Button("Elegir archivos…") { shelf.chooseFiles(controller: controller) }
                        .buttonStyle(.bordered).controlSize(.small)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(shelf.items) { item in
                            HStack(spacing: 8) {
                                Button { shelf.toggle(item.url) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: shelf.selected.contains(item.url) ? "checkmark.circle.fill" : (item.isDirectory ? "folder" : "doc"))
                                            .frame(width: 18)
                                        Text(item.name).lineLimit(1).truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Seleccionar para AirDrop")
                                .accessibilityValue(shelf.selected.contains(item.url) ? "Seleccionado" : "No seleccionado")
                                .onDrag { NSItemProvider(object: item.url as NSURL) }
                                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]); controller.collapse() } label: {
                                    Image(systemName: "magnifyingglass").frame(width: 26, height: 28)
                                }.buttonStyle(.plain).help("Mostrar en Finder").accessibilityLabel("Mostrar \(item.name) en Finder")
                                Button { shelf.remove(item.url) } label: {
                                    Image(systemName: "xmark").frame(width: 26, height: 28)
                                }.buttonStyle(.plain).help("Retirar de la bandeja; no elimina el original")
                                .accessibilityLabel("Retirar \(item.name) de la bandeja")
                            }.font(.system(size: 12)).padding(.horizontal, 8)
                                .background(.white.opacity(shelf.selected.contains(item.url) ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                HStack(spacing: 10) {
                    Button { shelf.chooseFiles(controller: controller) } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("Añadir archivos").accessibilityLabel("Añadir archivos")
                    Button("Vaciar") { shelf.clear() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    Button { shelf.airDrop(controller: controller) } label: {
                        Label(shelf.sharing ? "Enviando…" : "AirDrop (\(shelf.sharingURLs.count))", systemImage: "square.and.arrow.up")
                    }.buttonStyle(.bordered).controlSize(.small).disabled(shelf.sharing || shelf.importing)
                }.font(.system(size: 11))
            }
            Text(shelf.importing ? "Comprobando archivos…" : shelf.message)
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
