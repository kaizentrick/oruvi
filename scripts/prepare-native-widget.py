#!/usr/bin/env python3
"""One-shot integration on the isolated feature branch; removes itself.
Never runs on main or a personal Mac. Exact replacements stop on source drift.
"""
from pathlib import Path
import plistlib
import subprocess

assert subprocess.check_output(['git','branch','--show-current'], text=True).strip() == 'feat/native-widgetkit'
def replace(path, old, new):
    file = Path(path); text = file.read_text()
    if text.count(old) != 1: raise SystemExit(f'{path}: expected exactly one source anchor')
    file.write_text(text.replace(old,new))
def section(path, begin, end, replacement):
    file = Path(path); text=file.read_text()
    assert text.count(begin)==1 and text.count(end)==1, path
    a=text.index(begin); b=text.index(end,a)
    file.write_text(text[:a]+replacement+text[b:])

model='Sources/StandbyModel.swift'
section(model, '    var desktopWidgetEnabled = false {', '    private var activeSystemBundleID = ""', '''    private(set) var nativeWidgetInUse = false
    var systemProhibitsSkip = false
    func setNativeWidgetPresence(_ present: Bool) {
        guard nativeWidgetInUse != present else { return }
        nativeWidgetInUse = present
        if started { policyChanged() }
    }
''')
replace(model, '(isVisible || notchVisible || desktopWidgetEnabled) && !screenSleeping', '(isVisible || notchVisible || nativeWidgetInUse) && !screenSleeping')
replace(model, '''        desktopWidgetEnabled = DesktopWidgetPolicy.initialVisibility(defaults: defaults)
        desktopWidgetAlwaysOnTop = defaults.bool(forKey: DesktopWidgetPolicy.pinnedKey)
''', '')
replace(model, '        playerArtworkURL = ""; activeSystemBundleID = ""; systemArtworkData = nil', '        playerArtworkURL = ""; activeSystemBundleID = ""; systemArtworkData = nil; systemProhibitsSkip = false')
replace(model, '        activeSystemBundleID = snapshot["systemBundleID"] as? String ?? ""', '''        activeSystemBundleID = snapshot["systemBundleID"] as? String ?? ""
        systemProhibitsSkip = source == .system && ((snapshot["systemProhibitsSkip"] as? NSNumber)?.boolValue ?? false)''')
replace(model, '    func fetchLyrics() {', '''    /// Native widget buttons execute inside the containing app. Validate the
    /// displayed session before dispatch and finish reading the real state before
    /// the App Intent's automatic timeline reload. Never change either selector.
    func controlFromNativeWidget(_ command: String, expectedTrackID: String,
                                 sourceID: String, preference: String) async -> String {
        guard ["previous", "toggle", "next"].contains(command), !LumaEnvironment.isTesting,
              connected, !demoMode, !screenSleeping else { return "Conecta los controles en Oruvi." }
        guard expectedTrackID == track.id, sourceID == activePlayer.rawValue,
              preference == effectivePlayerPreference.rawValue else {
            refreshPlayback(); return "El contenido cambió. Vuelve a pulsar el control."
        }
        let session = generation, source = activePlayer, selection = effectivePlayerPreference
        let result: ([String: Any], [String: Any]) = await withCheckedContinuation { continuation in
            musicQueue.async { [playerRouter] in
                let commandResult = playerRouter.command(command, position: 0, source: source,
                    preference: selection, expectedTrackID: expectedTrackID, requireSameTrack: true)
                if commandResult["status"] as? String == "ok" { Thread.sleep(forTimeInterval: 0.15) }
                let value = playerRouter.snapshot(preference: selection, preferred: source, refreshSystem: true)
                continuation.resume(returning: (commandResult, value))
            }
        }
        guard session == generation, connected, !screenSleeping else { return "La sesión de Oruvi cambió." }
        apply(result.1)
        if result.0["status"] as? String != "ok" {
            return result.0["message"] as? String ?? "El reproductor no aceptó el control."
        }
        return ""
    }
    func fetchLyrics() {''')
router='Sources/PlayerSource.swift'
replace(router, '''    func snapshot(preference: PlayerPreference, preferred: PlayerSource) -> [String: Any] {
        resolve(preference: preference, preferred: preferred, system: SystemMediaBridge.shared.current)
    }''', '''    func snapshot(preference: PlayerPreference, preferred: PlayerSource, refreshSystem: Bool = false) -> [String: Any] {
        let system = refreshSystem && preference == .automatic ? SystemMediaBridge.shared.readNow() : SystemMediaBridge.shared.current
        return resolve(preference: preference, preferred: preferred, system: system)
    }''')
replace(router, '                 preference: PlayerPreference, expectedTrackID: String) -> [String: Any] {', '                 preference: PlayerPreference, expectedTrackID: String, requireSameTrack: Bool = false) -> [String: Any] {')
replace(router, '        if command == "seek" && (target != source || current["id"] as? String != expectedTrackID) {', '        if (command == "seek" || requireSameTrack) && (target != source || current["id"] as? String != expectedTrackID) {')

app='Sources/OruviApplication.swift'
replace(app, '    private var desktopWidget: DesktopWidgetController?', '''    private var didFinishLaunching = false
    private var pendingWidgetRoute: OruviWidgetRoute?''')
replace(app, '''        let widget = DesktopWidgetController(model: model)
        desktopWidget = widget; widget.start()''', '''        NativeWidgetController.shared.start()
        didFinishLaunching = true
        if let route = pendingWidgetRoute { pendingWidgetRoute = nil; openWidgetRoute(route) }''')
replace(app, '''        _ = item("Mostrar widget de escritorio", #selector(showDesktopWidget))
        _ = item("Ocultar widget de escritorio", #selector(hideDesktopWidget), enabled: model.desktopWidgetEnabled)''', '''        _ = item("Widgets de macOS…", #selector(showNativeWidgets))''')
replace(app, '''    @objc private func showDesktopWidget() { StandbyModel.shared.revealDesktopWidget() }
    @objc private func hideDesktopWidget() { StandbyModel.shared.desktopWidgetEnabled = false }''', '''    @objc private func showNativeWidgets() { StandbyModel.shared.showNativeWidgetSettings() }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let route = urls.compactMap(OruviWidgetRoute.init(url:)).last else { return }
        guard didFinishLaunching else { pendingWidgetRoute = route; return }
        openWidgetRoute(route)
    }
    private func openWidgetRoute(_ route: OruviWidgetRoute) {
        guard !LumaEnvironment.isTesting else { return }
        switch route {
        case .standby: StandbyModel.shared.showWindow()
        case .widgets: StandbyModel.shared.showNativeWidgetSettings()
        }
    }''')
replace(app, '        desktopWidget?.stop()', '        NativeWidgetController.shared.stop()')
settings='Sources/LumaStandbyApp.swift'
section(settings, '                Section("Widget de escritorio") {', '                Section("Notch y reproductores") {', '                NativeWidgetSettings()\n')
replace('Sources/NotchView.swift', 'Button("Mostrar widget de escritorio") { controller.afterMenu { model.revealDesktopWidget() } }', 'Button("Widgets de macOS…") { controller.afterMenu { model.showNativeWidgetSettings() } }')
replace('Sources/NotchView.swift', 'Standby, widget de escritorio, ajustes y cerrar', 'Standby, widgets de macOS, ajustes y cerrar')
replace('Sources/Release.swift', '?? "0.9.1"', '?? "0.10.0"')
replace('Sources/Release.swift', '?? "10"', '?? "11"')
info=Path('Resources/Info.plist'); p=plistlib.loads(info.read_bytes())
p['CFBundleShortVersionString']='0.10.0'; p['CFBundleVersion']='11'
p['OruviWidgetAppGroup']='group.com.kaizentrick.Oruvi'
p['CFBundleURLTypes']=[{'CFBundleURLName':'com.kaizentrick.Oruvi.widget-links','CFBundleTypeRole':'Viewer','CFBundleURLSchemes':['oruvi']}]
info.write_bytes(plistlib.dumps(p,sort_keys=False))
ent=Path('Resources/Entitlements.plist'); p=plistlib.loads(ent.read_bytes())
p['com.apple.security.application-groups']=['group.com.kaizentrick.Oruvi']; ent.write_bytes(plistlib.dumps(p,sort_keys=False))

# Share the model and intent types with tests, but not the extension @main.
build='scripts/build.sh'
replace(build, '-framework EventKit -framework Sparkle)', '-framework EventKit -framework Sparkle -framework WidgetKit -framework AppIntents)')
replace(build, 'for source in Sources/*.swift; do', 'for source in Sources/*.swift Sources/WidgetShared/*.swift; do')
replace(build, '''APP="$BUILD/stage/Oruvi.app"; prepare_app "$APP"
xcrun swiftc "${BASE[@]}" -O -whole-module-optimization "${RELEASE[@]}" "$BUILD/libOruviPlayers.a" "${FRAMEWORKS[@]}" -o "$APP/Contents/MacOS/Oruvi"''', '''bash scripts/build-native-targets.sh "$BUILD" "$DEPS" "$VERSION" "$ORUVI_BUILD_NUMBER"
APP="$BUILD/stage/Oruvi.app"; prepare_app "$APP"
EXTENSION="$APP/Contents/PlugIns/OruviWidgets.appex"
codesign --force "${SIGN_OPTIONS[@]}" --entitlements Resources/Widgets/Entitlements.plist --sign "${SIGN_IDENTITY:--}" "$EXTENSION"''')
# Preserve DT platform metadata and other Info keys emitted by Xcode.
replace(build, '    cp Resources/Info.plist "$app/Contents/Info.plist"', '''    python3 - "$app/Contents/Info.plist" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
info = plistlib.loads(path.read_bytes()) if path.exists() else {}
info.update(plistlib.loads(pathlib.Path('Resources/Info.plist').read_bytes()))
path.write_bytes(plistlib.dumps(info, sort_keys=False))
PY''')
replace(build, '''codesign --verify --deep --strict --verbose=2 "$APP"
printf '\\n[4/5] DMG\\n' ''', '''codesign --verify --deep --strict --verbose=2 "$APP"
printf '\\n[4/5] DMG\\n' ''') if False else None
replace(build, 'codesign --verify --deep --strict --verbose=2 "$APP"', '''codesign --verify --deep --strict --verbose=2 "$APP"
python3 scripts/verify-native-bundle.py "$APP" >&3
if [[ "${GITHUB_ACTIONS:-false}" == true ]]; then bash scripts/verify-widget-registration.sh "$APP" >&3; fi''')
replace(build, 'codesign --verify --deep --strict "$BUILD/mount/Oruvi.app"', '''codesign --verify --deep --strict "$BUILD/mount/Oruvi.app"
python3 scripts/verify-native-bundle.py "$BUILD/mount/Oruvi.app" >&3''')
replace('scripts/check.sh', '''    Sources/DesktopWidgetPolicy.swift scripts/verify-desktop-widget.swift -o "$WORK/verify-desktop-widget"
"$WORK/verify-desktop-widget"''', '''    Sources/WidgetShared/WidgetSnapshot.swift scripts/verify-widgetkit.swift -o "$WORK/verify-widgetkit"
"$WORK/verify-widgetkit"''')

# Avoid a timeline -> hint -> forced reload loop, and bound membership hints.
controller='Sources/NativeWidgetController.swift'
replace(controller, '''            self.refreshConfigurations(force: true)
            self.requestPublication(force: true)''', '''            self.refreshConfigurations(force: true)
            self.requestPublication()''')
replace(controller, '        guard started, !stopped, !querying, force || Date().timeIntervalSince(lastQuery) >= 15 else { return }', '        guard started, !stopped, !querying, Date().timeIntervalSince(lastQuery) >= (force ? 1 : 15) else { return }')
replace(controller, '''                    self.installedCount = count''', '''                    let changed = self.installedCount != count
                    self.installedCount = count''')
replace(controller, '                    if count > 0 { self.requestPublication(force: true) }', '                    if count > 0 { self.requestPublication(force: changed) }')
replace(controller, '                lastImage = image\n', '')
replace(controller, '                thumbnail = await Task.detached(priority: .utility) { cgImage.flatMap(Self.jpegThumbnail) }.value', '''                let decoded = await Task.detached(priority: .utility) { cgImage.flatMap(Self.jpegThumbnail) }.value
                guard !Task.isCancelled, !stopped, work == serial else { return }
                lastImage = image; thumbnail = decoded''')
replace('Sources/WidgetShared/WidgetSnapshot.swift', 'force || previous.map { !value.samePresentation(as: $0) } ?? true ||', 'force || (previous.map { !value.samePresentation(as: $0) } ?? true) ||')

# Retain surface/permission/metadata regressions; replace obsolete window tests.
tests='scripts/verify-surfaces.swift'
replace(tests, '        defaults.set(false, forKey: "desktopWidgetEnabled")\n', '')
replace(tests, '        model.desktopWidgetEnabled = true', '        model.setNativeWidgetPresence(true)')
replace(tests, '        expect(defaults.bool(forKey: "desktopWidgetEnabled"), "desktop opt-in persists")', '        expect(defaults.object(forKey: "nativeWidgetInUse") == nil, "placement belongs to macOS, not a saved app flag")')
replace(tests, '        model.desktopWidgetEnabled = false', '        model.setNativeWidgetPresence(false)') if Path(tests).read_text().count('        model.desktopWidgetEnabled = false')==1 else None
text=Path(tests).read_text(); begin=text.index('        // Exercise the real AppKit card')
text=text[:begin]+'''        let widgets = NativeWidgetController(model: model)
        model.connected = true
        let ready = widgets.makeSnapshot()
        expect(ready.state == .ready && ready.canControl, "native snapshot has real content")
        expect(ready.trackID == model.track.id && ready.sourceID == "oruvi.system", "snapshot preserves active identity")
        expect(ready.preference == "automatic", "native widget preserves automatic selection")
        model.systemProhibitsSkip = true
        expect(!widgets.makeSnapshot().canSkip, "native widget disables prohibited skips")
        model.screenSleeping = true
        let asleep = widgets.makeSnapshot()
        expect(asleep.state == .sleeping && !asleep.canControl && asleep.artwork == nil, "sleep snapshot removes private media")
        model.screenSleeping = false; model.connected = false
        expect(widgets.makeSnapshot().state == .disconnected, "disconnect cannot show playable media")
        model.connected = true; model.track = .empty
        expect(widgets.makeSnapshot().state == .idle, "empty session is not fabricated playback")
        expect(model.playerPreference == .spotify && model.notchPlayerPreference == .automatic, "widget never rewrites independent selectors")
        expect(!model.nativeWidgetInUse, "removing widget releases its sampler demand")
        print("PASS: \\(count) real-model native-widget and surface checks; no extra window or player launched.")
    }
}
'''
text=text.replace('        model.desktopWidgetEnabled = false', '        model.setNativeWidgetPresence(false)')
Path(tests).write_text(text)

# User-visible docs accurately distinguish the new extension from the removed card.
readme='README.md'
section(readme, '## Widget de escritorio', '## Widgets del notch', '''## Widgets nativos de macOS

Oruvi incorpora una extensión **WidgetKit** real, `OruviWidgets.appex`, dentro de la app. Se elimina la tarjeta flotante de 0.9.1: no hay otra ventana, chincheta ni temporizador gráfico de escritorio.

Instala la versión 0.10.0 o posterior en Aplicaciones y abre Oruvi al menos una vez. Después: **clic secundario en el escritorio → Editar widgets → busca Oruvi → Música y Standby**. Puedes elegir tamaño pequeño o mediano y colocarlo como cualquier widget del sistema. macOS administra posición, tamaño, apariencia y eliminación.

Incluye portada, título, artista, anterior/reproducir-pausar/siguiente y un icono para abrir Standby. Los controles utilizan App Intents en el proceso de Oruvi y no abren otra pantalla. El icono de Standby usa un enlace específico. El widget refleja el reproductor activo de Oruvi; las selecciones Notch y Standby siguen siendo independientes, con Automático, Apple Music y Spotify.

El widget no está ejecutándose continuamente: WidgetKit representa instantáneas y decide sus refrescos. Oruvi solicita actualización al cambiar el contenido, agrupa ráfagas y no escribe por cada segundo de progreso. No se garantiza portada instantánea en cada cambio; los controles validan sesión, pista y selección antes de actuar sobre un estado atrasado.

Para compartir datos entre procesos se conserva **una instantánea local**, sin historial, en la caché del App Group: estado, metadatos actuales y miniatura JPEG de hasta 192 píxeles. Se sobrescribe de forma atómica, se elimina al cerrar Oruvi o retirar el último widget y tiene caducidad. WidgetKit también administra sus propias representaciones. No se envían los títulos de vídeos/navegadores a catálogos de música ni servicios de letras. La extensión no tiene permisos de red, Apple Events, cámara o micrófono.

En **Ajustes → Widgets nativos de macOS** se muestran instrucciones y detección de widgets añadidos. La distribución actual sigue siendo ad-hoc, no notarizada: macOS puede solicitar acceso a datos compartidos o bloquear componentes según sus políticas. La validación del runner no reemplaza comprobar la galería en una instalación normal. No desactives SIP o Gatekeeper. Detalles de firma y diagnóstico en [Resources/MEDIA.md](Resources/MEDIA.md).

''')
# Keep existing icon/build and unrelated documentation intact.
path=Path(readme); text=path.read_text().replace('Oruvi-0.9.1-arm64.dmg','Oruvi-0.10.0-arm64.dmg').replace('Oruvi-0.9.0-arm64.dmg','Oruvi-0.10.0-arm64.dmg'); path.write_text(text)
changelog=Path('CHANGELOG.md'); text=changelog.read_text()
changelog.write_text(text.replace('# Changelog\n', '''# Changelog

## 0.10.0 — WidgetKit nativo

- Extensión de la galería de macOS, tamaños pequeño y mediano, portada, transporte y enlace a Standby.
- Se retira la tarjeta AppKit y sus controles de posición/pin; macOS administra el widget.
- Dos targets Xcode con App Intents metadata, extensión sandboxed y App Group compartido.
- Actualizaciones por cambios, instantánea acotada/atómica y validación de comandos contra contenido atrasado.
- El pipeline verifica que la extensión real, las firmas, las versiones y los metadatos estén dentro del DMG.

''',1))
publish='scripts/publish-release.sh'
file=Path(publish); text=file.read_text()
a=text.index("  printf '### Widget de escritorio")
b=text.index('  if [[ "${ORUVI_NOTARIZED:-0}"',a)
text=text[:a]+'''  printf '### Widget nativo de macOS\\n\\n'
  printf 'Abre Oruvi desde Aplicaciones al menos una vez. Después: **clic secundario en el escritorio → Editar widgets → Oruvi → Música y Standby**. Elige pequeño o mediano. Incluye portada, controles interactivos y enlace a Standby.\\n\\n'
  printf 'La tarjeta flotante anterior se ha retirado. WidgetKit gestiona colocación y refrescos; no se simula un widget con otra ventana. Si tenías la build de prueba sin feed, reemplázala por este DMG público.\\n\\n'
''' + text[b:]; file.write_text(text)
workflow=Path('.github/workflows/validate.yml'); text=workflow.read_text()
text=text.replace('Para el widget: menu de Oruvi > Mostrar widget de escritorio.', 'Para el widget: abre Oruvi una vez > clic secundario en escritorio > Editar widgets > Oruvi.')
text=text.replace('El widget es una tarjeta propia de Oruvi, no aparece en Editar widgets de macOS.', 'Incluye extension WidgetKit nativa; macOS administra colocacion y refrescos.')
workflow.write_text(text)
leeme=Path('Resources/LEEME.txt'); leeme.write_text(leeme.read_text()+'''\nWIDGET NATIVO (0.10.0+)\nAbre Oruvi desde Aplicaciones al menos una vez. Clic secundario en el escritorio > Editar widgets > Oruvi > Musica y Standby. Elige pequeno o mediano. La tarjeta flotante antigua ya no existe. macOS administra actualizaciones y puede solicitar acceso a datos compartidos; no desactives protecciones del sistema.\n''')
Path('.github/workflows/prepare-native-widget.yml').unlink()
Path(__file__).unlink()
print('Native WidgetKit integration applied; temporary preparation files removed.')
