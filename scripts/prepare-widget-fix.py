#!/usr/bin/env python3
"""One-shot integration run exclusively in GitHub on the named feature branch.
Exact-match replacements fail closed if any source changed. Removes itself and
its temporary workflow. Normal PR/release workflows perform all macOS tests.
"""
from pathlib import Path
import plistlib
import subprocess

if subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip() != 'fix/widget-discovery-091':
    raise SystemExit('Unexpected branch; no edits applied.')

def replace(path, old, new):
    p = Path(path)
    value = p.read_text()
    if value.count(old) != 1:
        raise SystemExit(f'Expected one exact target in {path}; refusing to guess.')
    p.write_text(value.replace(old, new))

model = 'Sources/StandbyModel.swift'
replace(model, '    private var activeSystemBundleID = ""', '''    var desktopWidgetAlwaysOnTop = false {
        didSet { prefs.set(desktopWidgetAlwaysOnTop, forKey: DesktopWidgetPolicy.pinnedKey) }
    }
    private var activeSystemBundleID = ""''')
replace(model, '        desktopWidgetEnabled = defaults.bool(forKey: "desktopWidgetEnabled")', '''        desktopWidgetEnabled = DesktopWidgetPolicy.initialVisibility(defaults: defaults)
        desktopWidgetAlwaysOnTop = defaults.bool(forKey: DesktopWidgetPolicy.pinnedKey)''')

app = 'Sources/OruviApplication.swift'
replace(app, '        _ = item(OruviRelease.title, nil, enabled: false)', '''        _ = item(OruviRelease.title + " · " + OruviRelease.build, nil, enabled: false)
        _ = item("Mostrar widget de escritorio", #selector(showDesktopWidget))
        _ = item("Ocultar widget de escritorio", #selector(hideDesktopWidget), enabled: model.desktopWidgetEnabled)
        menu.addItem(.separator())''')
replace(app, '''        let widgetItem = item("Mostrar widget de escritorio", #selector(toggleDesktopWidget))
        widgetItem.state = model.desktopWidgetEnabled ? .on : .off
''', '')
replace(app, '''    @objc private func toggleDesktopWidget() {
        let model = StandbyModel.shared
        model.desktopWidgetEnabled.toggle()
        if model.desktopWidgetEnabled && model.playbackSurface == .notch && !model.connected { model.connectMusic() }
    }''', '''    @objc private func showDesktopWidget() { StandbyModel.shared.revealDesktopWidget() }
    @objc private func hideDesktopWidget() { StandbyModel.shared.desktopWidgetEnabled = false }''')

view = 'Sources/LumaStandbyApp.swift'
replace(view, '                    Text(OruviRelease.title).font(.caption).foregroundStyle(.secondary)', '                    Text(OruviRelease.title + " · Compilación " + OruviRelease.build).font(.caption).foregroundStyle(.secondary)')
replace(view, '                Section("Notch y reproductores") {', '''                Section("Widget de escritorio") {
                    Toggle("Mostrar widget de escritorio", isOn: $model.desktopWidgetEnabled)
                    Toggle("Mantener widget al frente", isOn: $model.desktopWidgetAlwaysOnTop)
                        .disabled(!model.desktopWidgetEnabled)
                    Button("Mostrar ahora y recuperar posición") { model.revealDesktopWidget() }
                    Text("Portada, controles y acceso a Standby. Mostrar ahora cierra esta presentación, coloca la tarjeta en la pantalla del puntero y la muestra al frente brevemente. Activa Mantener al frente para que no quede detrás de otras ventanas.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Es una tarjeta propia de Oruvi: se añade desde aquí o desde el menú de la barra superior, no desde Editar widgets de macOS. Comparte el reproductor del Notch; Standby conserva su selección independiente.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Notch y reproductores") {''')
replace(view, 'Selecciones independientes. Automático sigue Apple Music o Spotify de este Mac; solo se ofrecen las aplicaciones instaladas.', 'Selecciones independientes. Automático sigue Ahora suena de macOS para apps y navegadores compatibles; Apple Music y Spotify permanecen como opciones manuales cuando están instaladas.')

notch = 'Sources/NotchView.swift'
replace(notch, '                    Button("Abrir Standby") { controller.afterMenu { model.showWindow() } }', '''                    Button("Abrir Standby") { controller.afterMenu { model.showWindow() } }
                    Button("Mostrar widget de escritorio") { controller.afterMenu { model.revealDesktopWidget() } }''')
replace(notch, '.help("Standby, ajustes y cerrar")', '.help("Standby, widget de escritorio, ajustes y cerrar")')
replace(notch, 'Text(model.hasTrack ? model.track.artist : "Apple Music o Spotify")', 'Text(model.hasTrack ? model.track.artist : "Ahora suena · Music · Spotify")')

replace('scripts/check.sh', '''python3 - <<'PY'\n''', '''xcrun swiftc -O -whole-module-optimization -warnings-as-errors -swift-version 5 -parse-as-library \\
    Sources/DesktopWidgetPolicy.swift scripts/verify-desktop-widget.swift -o "$WORK/verify-desktop-widget"
"$WORK/verify-desktop-widget"
python3 - <<'PY'
''')

tests = 'scripts/verify-surfaces.swift'
replace(tests, '        defaults.set(false, forKey: "notchMusicEnabled")', '''        defaults.set(false, forKey: "notchMusicEnabled")
        defaults.set(false, forKey: "desktopWidgetEnabled")''')
replace(tests, '        print("PASS:', '''        // Exercise the real AppKit card on the CI runner, not just a mock state.
        // No application delegate/model.start(), permissions, playback or network.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let widget = DesktopWidgetController(model: model)
        defer { widget.stop() }
        model.isVisible = false; model.screenSleeping = false
        model.desktopWidgetEnabled = false; model.desktopWidgetAlwaysOnTop = false
        widget.reconcile()
        expect(!widget.isVisible, "hidden card creates no visible window")
        model.desktopWidgetEnabled = true; widget.reconcile()
        expect(widget.isVisible, "enabled card actually orders a panel on screen")
        expect(widget.currentFrame?.size == DesktopWidgetPolicy.size, "real panel has current dimensions")
        expect(!widget.isInFront, "desktop mode stays below normal windows")
        model.isVisible = true; widget.reconcile()
        expect(!widget.isVisible, "Standby hides the real panel")
        model.isVisible = false; widget.reconcile()
        expect(widget.isVisible, "return from Standby restores real panel")
        model.screenSleeping = true; widget.reconcile()
        expect(!widget.isVisible, "sleep hides real panel")
        model.desktopWidgetEnabled = false; model.revealDesktopWidget()
        expect(!model.desktopWidgetEnabled, "reveal cannot show UI while locked/asleep")
        model.screenSleeping = false
        let savedNotch = model.notchPlayerPreference, savedStandby = model.playerPreference
        model.revealDesktopWidget(); model.revealDesktopWidget(); widget.reveal()
        expect(model.desktopWidgetEnabled && widget.isVisible, "repeated Show never toggles the widget off")
        expect(widget.isInFront, "explicit reveal is visible above normal windows")
        expect(!model.connected, "Show does not silently connect playback")
        expect(model.notchPlayerPreference == savedNotch && model.playerPreference == savedStandby, "Show preserves independent players")
        widget.endReveal()
        expect(!widget.isInFront, "temporary reveal returns to desktop level")
        model.desktopWidgetAlwaysOnTop = true; widget.reconcile()
        expect(widget.isInFront, "explicit pin keeps card in front")
        expect(defaults.bool(forKey: DesktopWidgetPolicy.pinnedKey), "pin preference persists")
        model.desktopWidgetAlwaysOnTop = false; widget.reconcile()
        expect(!widget.isInFront, "unpin returns to desktop")
        model.desktopWidgetEnabled = false; widget.reconcile()
        expect(!widget.isVisible, "Hide really hides the panel")
        widget.stop(); widget.stop(); widget.reveal()
        expect(!widget.isVisible && widget.currentFrame == nil, "shutdown is idempotent and cannot reopen")
        print("PASS:''')
replace(tests, 'real-model surface handoff checks, no GUI or player launched.', 'real-model surface/widget checks; AppKit panel exercised, no player launched.')

info = Path('Resources/Info.plist')
values = plistlib.loads(info.read_bytes())
assert values['CFBundleShortVersionString'] == '0.9.0'
values['CFBundleShortVersionString'] = '0.9.1'
values['CFBundleVersion'] = '10'
info.write_bytes(plistlib.dumps(values, sort_keys=False))
replace('Sources/Release.swift', '?? "0.9.0"', '?? "0.9.1"')
replace('Sources/Release.swift', '?? "9"', '?? "10"')

readme = Path('README.md')
s = readme.read_text()
start = s.index('## Widget de escritorio\n')
end = s.index('## Widgets del notch\n', start)
s = s[:start] + '''## Widget de escritorio

**Oruvi 0.9.1:** el widget aparece por defecto cuando todavía no has elegido mostrarlo u ocultarlo. Una decisión de ocultarlo se conserva, también al actualizar. Al descubrirlo por primera vez se muestra brevemente al frente sin iniciar reproducción ni cambiar tu reproductor.

Para recuperarlo, abre el icono de Oruvi en la barra superior y pulsa **Mostrar widget de escritorio**. Esta acción siempre muestra la tarjeta, incluso si ya estaba activada: sale de Standby, la coloca en la pantalla del puntero y la eleva durante 8 segundos. **Ajustes → Widget de escritorio → Mostrar ahora y recuperar posición** y el menú de tres puntos del notch hacen lo mismo.

La tarjeta incluye portada, título, artista, anterior/reproducir-pausar/siguiente y un icono para abrir Standby. Arrastra el asa de tres líneas para moverla. El botón de chincheta o **Mantener widget al frente** permite dejarla sobre las ventanas normales; desactivado, permanece en el escritorio. La X y **Ocultar widget de escritorio** la ocultan. Las posiciones de monitores desconectados y tamaños antiguos se corrigen.

Es una **tarjeta propia de Oruvi**, no una extensión de WidgetKit: **no aparece en Editar widgets de macOS**. Oruvi debe seguir abierto. Comparte el selector del Notch y un único muestreador; Standby conserva su selección independiente. Bloqueo, reposo y Standby la ocultan, incluso cuando está fijada al frente. Mostrarla no concede permisos ni reproduce música: utiliza **Conectar controles** cuando corresponda.

No se guardan títulos o portadas del sistema en disco ni se envían títulos de vídeos/navegadores a LRCLIB o al catálogo de Apple. [Detalles y pruebas](Resources/MEDIA.md).

''' + s[end:]
s = s.replace('dist/Oruvi-0.9.0-arm64.dmg', 'dist/Oruvi-0.9.1-arm64.dmg')
readme.write_text(s)
replace('CHANGELOG.md', '## Unreleased — reproducción del sistema y escritorio', '''## 0.9.1 — widget visible y recuperable

- El widget aparece inicialmente si no hay preferencia guardada; respeta ocultaciones explícitas.
- Mostrar es una acción idempotente disponible en menú, Ajustes y notch; recupera posición y se eleva temporalmente.
- Fijación opcional al frente y asa real de arrastre sin interceptar los controles.
- Posiciones y tamaños antiguos se normalizan; reposo, bloqueo y Standby conservan su prioridad.
- Número de versión diferenciado, compilación visible, pruebas de preferencias/geometría y ventana AppKit real en CI.
- Sigue siendo una tarjeta propia de Oruvi, no un widget de la galería WidgetKit.

Reproducción del sistema incorporada desde el PR #4:''')
replace('scripts/publish-release.sh', "  printf 'Incluye notch, Standby a pantalla completa, Apple Music, Spotify y letras sincronizadas cuando estén disponibles.\\n\\n'", "  printf 'Incluye notch, Standby, Automático con Ahora suena, Apple Music y Spotify.\\n\\n'\n  printf '### Widget de escritorio\\n\\nEn el menú de Oruvi pulsa **Mostrar widget de escritorio**, o abre **Ajustes → Widget de escritorio → Mostrar ahora y recuperar posición**. La tarjeta tiene portada, controles, asa de arrastre, chincheta para mantenerla al frente y acceso a Standby. Mostrar siempre recupera la tarjeta; no la oculta si ya estaba activa.\\n\\nEs una tarjeta propia de Oruvi: **no aparece en Editar widgets de macOS**. Se muestra inicialmente si no hay preferencia guardada; una ocultación explícita se conserva. Automático depende de que la app publique una sesión compatible.\\n\\n'")
Path('.github/workflows/prepare-widget-fix.yml').unlink()
Path(__file__).unlink()
print('Widget integration prepared on feature branch. No main or release mutation performed.')
