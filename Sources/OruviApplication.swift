import AppKit
import SwiftUI

@main
struct OruviApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = OruviApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class OruviApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: StandbyWindow?
    private var runtime: AmbientRuntime?
    private var notch: NotchController?
    private var desktopWidget: DesktopWidgetController?
    private var status: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !LumaEnvironment.isTesting,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: OruviRelease.bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        installMainMenu()
        let model = StandbyModel.shared
        model.settingsOpen = false
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let viewWindow = StandbyWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        viewWindow.isReleasedWhenClosed = false
        viewWindow.isRestorable = false
        viewWindow.tabbingMode = .disallowed
        viewWindow.hasShadow = false
        viewWindow.backgroundColor = .black
        viewWindow.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        viewWindow.contentView = FirstClickHostingView(rootView: StandbyHost(model: model))
        window = viewWindow
        model.attach(window: viewWindow)
        let controller = AmbientRuntime(model: model, window: viewWindow)
        runtime = controller
        installStatusItem()
        model.start()
        let notchController = NotchController(model: model)
        notch = notchController
        notchController.start()
        let widget = DesktopWidgetController(model: model)
        desktopWidget = widget; widget.start()
        OruviUpdates.shared.startIfConfigured()
        if LumaEnvironment.isTesting {
            controller.activate()
            #if LUMA_QA
            LumaQA.run(model: model, runtime: controller, window: viewWindow)
            #endif
        } else {
            controller.rescheduleIdle() // Desktop notch first; Standby only on demand or inactivity.
        }
    }
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Oruvi")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = OruviRelease.title
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        status = item
        rebuild(menu)
    }
    func menuWillOpen(_ menu: NSMenu) { rebuild(menu) }
    private func rebuild(_ menu: NSMenu) {
        let model = StandbyModel.shared
        menu.removeAllItems()
        @MainActor func item(_ title: String, _ action: Selector?, key: String = "", tag: Int = 0, enabled: Bool = true) -> NSMenuItem {
            let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
            result.target = self; result.tag = tag; result.isEnabled = enabled
            menu.addItem(result)
            return result
        }
        _ = item(OruviRelease.title + " · " + OruviRelease.build, nil, enabled: false)
        _ = item("Mostrar widget de escritorio", #selector(showDesktopWidget))
        _ = item("Ocultar widget de escritorio", #selector(hideDesktopWidget), enabled: model.desktopWidgetEnabled)
        menu.addItem(.separator())
        _ = item("Activar pantalla completa", #selector(showPresentation))
        _ = item("Ocultar presentación", #selector(hidePresentation), enabled: model.isVisible)
        menu.addItem(.separator())
        for (index, mode) in LayoutMode.allCases.enumerated() {
            let entry = item(mode.displayName, #selector(changeLayout(_:)), key: String(index + 1), tag: index)
            entry.state = model.layout == mode ? .on : .off
        }
        menu.addItem(.separator())
        let notchItem = item("Mostrar notch", #selector(toggleNotch))
        notchItem.state = model.notchEnabled ? .on : .off
        let automatic = item("Activación por inactividad", #selector(toggleAutomatic))
        automatic.state = model.idleEnabled ? .on : .off
        _ = item(model.automaticActivationStatus, nil, enabled: false)
        _ = item(model.autoPausedUntil == nil ? "Pausar activación durante 1 hora" : "Reanudar activación", #selector(pauseAutomatic))
        menu.addItem(.separator())
        let updates = OruviUpdates.shared
        _ = item(updates.availableVersion.map { "Actualizar a \($0)…" } ?? "Buscar actualizaciones…", #selector(checkUpdates))
        _ = item("Ajustes…", #selector(showSettings), key: ",")
        _ = item("Salir de Oruvi", #selector(quit), key: "q")
    }
    private func installMainMenu() {
        let main = NSMenu()
        let root = NSMenuItem(); main.addItem(root)
        let application = NSMenu(title: "Oruvi")
        let close = NSMenuItem(title: "Salir de Oruvi", action: #selector(quit), keyEquivalent: "q")
        close.target = self; application.addItem(close); root.submenu = application
        let editRoot = NSMenuItem(); main.addItem(editRoot)
        let edit = NSMenu(title: "Edición")
        for (title, action, key) in [("Cortar", #selector(NSText.cut(_:)), "x"), ("Copiar", #selector(NSText.copy(_:)), "c"), ("Pegar", #selector(NSText.paste(_:)), "v"), ("Seleccionar todo", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editRoot.submenu = edit; NSApp.mainMenu = main
    }
    @objc private func showPresentation() { StandbyModel.shared.showWindow() }
    @objc private func hidePresentation() { StandbyModel.shared.dismissStandby() }
    @objc private func showSettings() { let model = StandbyModel.shared; model.showWindow(); model.settingsOpen = true }
    @objc private func changeLayout(_ sender: NSMenuItem) {
        guard LayoutMode.allCases.indices.contains(sender.tag) else { return }
        StandbyModel.shared.selectLayout(LayoutMode.allCases[sender.tag]); showPresentation()
    }
    @objc private func toggleNotch() { StandbyModel.shared.notchEnabled.toggle() }
    @objc private func showDesktopWidget() { StandbyModel.shared.revealDesktopWidget() }
    @objc private func hideDesktopWidget() { StandbyModel.shared.desktopWidgetEnabled = false }
    @objc private func toggleAutomatic() { StandbyModel.shared.idleEnabled.toggle() }
    @objc private func pauseAutomatic() { runtime?.pauseAutomatic(minutes: StandbyModel.shared.autoPausedUntil == nil ? 60 : nil) }
    @objc private func checkUpdates() { OruviUpdates.shared.checkNow() }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        desktopWidget?.stop()
        StandbyModel.shared.shutdown()
        // Complete child-process cleanup before the application run loop exits.
        SystemMediaBridge.shared.shutdown()
        LumaEnvironment.cleanTestingData()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        runtime?.activate(); return true
    }
}
