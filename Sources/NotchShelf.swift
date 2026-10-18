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
                    guard NotchFilePolicy.isSafeFile(url),
                          FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
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
    func open(_ url: URL, controller: NotchController) {
        guard NotchFilePolicy.isSafeFile(url) else {
            message = "Este archivo ya no es válido o no se puede abrir."
            return
        }
        NSWorkspace.shared.open(url)
        controller.collapse()
    }
    func copyFiles() {
        let urls = sharingURLs.filter(NotchFilePolicy.isSafeFile)
        guard !urls.isEmpty else { message = "No hay archivos válidos para copiar."; return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        message = urls.count == 1 ? "Archivo copiado · pégalo con ⌘V." : "\(urls.count) archivos copiados · pégalos con ⌘V."
    }
    func copyPaths() {
        let urls = sharingURLs.filter(NotchFilePolicy.isSafeFile)
        guard !urls.isEmpty else { message = "No hay rutas válidas para copiar."; return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        message = urls.count == 1 ? "Ruta copiada al portapapeles." : "\(urls.count) rutas copiadas al portapapeles."
    }
    func share(via serviceName: NSSharingService.Name, label: String, controller: NotchController) {
        let urls = sharingURLs.filter(NotchFilePolicy.isSafeFile)
        guard !urls.isEmpty, !sharing else { return }
        guard let native = NSSharingService(named: serviceName), native.canPerform(withItems: urls) else {
            message = "\(label) no está disponible para esta selección en este Mac."; return
        }
        controller.beginInteraction(); sharingOwner = controller
        sharing = true; service = native; native.delegate = self
        message = "Compartiendo con \(label)…"
        NSApp.activate()
        native.perform(withItems: urls)
    }
    func airDrop(controller: NotchController) {
        share(via: .sendViaAirDrop, label: "AirDrop", controller: controller)
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        Task { @MainActor [weak self] in self?.finishSharing("Compartido correctamente.") }
    }
    nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let failure = error as NSError
        let cancelled = failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError
        Task { @MainActor [weak self] in self?.finishSharing(cancelled ? "Envío cancelado." : "No se completó el envío. Inténtalo de nuevo.") }
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
                            HStack(spacing: 6) {
                                Button { shelf.toggle(item.url) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: shelf.selected.contains(item.url) ? "checkmark.circle.fill" : (item.isDirectory ? "folder" : "doc"))
                                            .frame(width: 18)
                                        Text(item.name).lineLimit(1).truncationMode(.middle)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Seleccionar para compartir")
                                .accessibilityValue(shelf.selected.contains(item.url) ? "Seleccionado" : "No seleccionado")
                                .onDrag { NSItemProvider(object: item.url as NSURL) }
                                Button { shelf.open(item.url, controller: controller) } label: {
                                    Image(systemName: "arrow.up.forward.app").frame(width: 24, height: 28)
                                }.buttonStyle(.plain).help("Abrir archivo").accessibilityLabel("Abrir \(item.name)")
                                Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]); controller.collapse() } label: {
                                    Image(systemName: "magnifyingglass").frame(width: 24, height: 28)
                                }.buttonStyle(.plain).help("Mostrar en Finder").accessibilityLabel("Mostrar \(item.name) en Finder")
                                Button { shelf.remove(item.url) } label: {
                                    Image(systemName: "xmark").frame(width: 24, height: 28)
                                }.buttonStyle(.plain).help("Retirar de la bandeja; no elimina el original")
                                .accessibilityLabel("Retirar \(item.name) de la bandeja")
                            }.font(.system(size: 12)).padding(.horizontal, 8)
                                .background(.white.opacity(shelf.selected.contains(item.url) ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button { shelf.chooseFiles(controller: controller) } label: { Image(systemName: "plus").frame(width: 24, height: 24) }
                        .buttonStyle(.plain).help("Añadir archivos").accessibilityLabel("Añadir archivos")
                    Button("Vaciar") { shelf.clear() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        Button {
                            controller.afterMenu { shelf.copyFiles() }
                        } label: {
                            Label("Copiar archivo para pegar (⌘V)", systemImage: "doc.on.doc")
                        }
                        Button {
                            controller.afterMenu { shelf.copyPaths() }
                        } label: {
                            Label("Copiar ruta", systemImage: "link")
                        }
                        Divider()
                        Button {
                            controller.afterMenu { shelf.airDrop(controller: controller) }
                        } label: {
                            Label("AirDrop…", systemImage: "airplayaudio")
                        }
                        Button {
                            controller.afterMenu { shelf.share(via: .composeEmail, label: "Correo", controller: controller) }
                        } label: {
                            Label("Enviar por Correo…", systemImage: "envelope")
                        }
                        Button {
                            controller.afterMenu { shelf.share(via: .composeMessage, label: "Mensajes", controller: controller) }
                        } label: {
                            Label("Enviar por Mensajes…", systemImage: "message")
                        }
                        Divider()
                        Button {
                            controller.afterMenu {
                                NSWorkspace.shared.activateFileViewerSelecting(shelf.sharingURLs)
                                controller.collapse()
                            }
                        } label: {
                            Label("Mostrar en Finder", systemImage: "folder")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.system(size: 13)).frame(width: 26, height: 22)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .disabled(shelf.sharing || shelf.importing)
                    .help("Copiar o compartir con otras apps").accessibilityLabel("Más opciones para compartir")
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
