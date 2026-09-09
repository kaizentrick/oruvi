#!/usr/bin/env python3
"""One-time exact integration; only the named feature branch, entirely in GitHub."""
from pathlib import Path
import plistlib
import subprocess
assert subprocess.check_output(['git','branch','--show-current'],text=True).strip() == 'fix/widget-playback-0101'
def replace(path, old, new):
    p=Path(path); s=p.read_text()
    if s.count(old) != 1: raise SystemExit(path+': source anchor count differs from one')
    p.write_text(s.replace(old,new))
model='Sources/StandbyModel.swift'
replace(model, '    func fetchLyrics() {', '''    /// Explicit widget recovery awaits a fresh read before WidgetKit reloads.
    /// No transport command is sent here and neither source selector is edited.
    func synchronizeNativeWidget(connectIfNeeded: Bool) async -> String {
        guard !LumaEnvironment.isTesting, !screenSleeping else { return "Oruvi está en reposo." }
        if !connected || demoMode {
            guard connectIfNeeded else { return "Pulsa Conectar en el widget." }
            connectMusic()
        }
        guard connected, !demoMode else { return "Conecta el reproductor en Oruvi." }
        // Reject outstanding older callbacks without creating a second sampler.
        generation += 1
        let session = generation, selection = effectivePlayerPreference, source = activePlayer
        let snapshot: [String: Any] = await withCheckedContinuation { continuation in
            musicQueue.async { [playerRouter] in
                continuation.resume(returning: playerRouter.snapshot(preference: selection, preferred: source, refreshSystem: true))
            }
        }
        guard session == generation, connected, !screenSleeping else { return "La sesión cambió. Actualiza el widget." }
        apply(snapshot)
        schedulePoll()
        return snapshot["status"] as? String == "ok" ? "" : connectionStatus
    }
    func fetchLyrics() {''')
replace(model, '''            refreshPlayback(); return "El contenido cambió. Vuelve a pulsar el control."''', '''            _ = await synchronizeNativeWidget(connectIfNeeded: false)
            return "El contenido cambió. Vuelve a pulsar el control."''')
replace('scripts/build.sh', 'DYLD_FRAMEWORK_PATH="$DEPS" "$BUILD/verify-surfaces" --smoke-test >&3', '''DYLD_FRAMEWORK_PATH="$DEPS" "$BUILD/verify-surfaces" --smoke-test >&3
xcrun swiftc "${BASE[@]}" -Onone -whole-module-optimization -D LUMA_QA "${MODEL_TEST[@]}" scripts/verify-widget-pipeline.swift "$BUILD/libOruviPlayers.a" "${FRAMEWORKS[@]}" -o "$BUILD/verify-widget-pipeline"
DYLD_FRAMEWORK_PATH="$DEPS" "$BUILD/verify-widget-pipeline" --smoke-test >&3
if [[ "${GITHUB_ACTIONS:-false}" == true ]]; then bash scripts/verify-widget-sharing.sh >&3; fi''')
replace('scripts/check.sh', '"$WORK/verify-widgetkit"\n', '''"$WORK/verify-widgetkit"
xcrun swiftc -O -whole-module-optimization -warnings-as-errors -swift-version 5 -parse-as-library \\
    Sources/WidgetShared/WidgetSnapshot.swift scripts/verify-widget-recovery.swift -o "$WORK/verify-widget-recovery"
"$WORK/verify-widget-recovery"
''')
p=Path('Resources/Info.plist'); info=plistlib.loads(p.read_bytes())
assert info['CFBundleShortVersionString']=='0.10.0'
info['CFBundleShortVersionString']='0.10.1'; info['CFBundleVersion']='13'
p.write_bytes(plistlib.dumps(info,sort_keys=False))
replace('Sources/Release.swift', '?? "0.10.0"', '?? "0.10.1"')
p=Path('CHANGELOG.md'); s=p.read_text(); p.write_text(s.replace('# Changelog\n', '''# Changelog

## 0.10.1 — Sincronización y recuperación de widgets

- Publica el estado al iniciar sin esperar a la enumeración de WidgetCenter; un resultado vacío no borra la música.
- Botón Conectar/Actualizar utilizable sin metadatos, con lectura real completada antes de recargar.
- Portada y pausa mediante un único snapshot atómico; errores de acceso, caducidad y datos corruptos distinguibles.
- Recuperación tras actualizar Oruvi, reposo o cambios de contenido; selectores independientes conservados.
- Pruebas del pipeline asíncrono real y lectura desde otro proceso sandboxed, además del registro de la extensión.

''',1))
p=Path('Resources/MEDIA.md'); p.write_text(p.read_text()+'''
## Corrección de sincronización 0.10.1

La publicación ya no depende de que WidgetCenter enumere primero el widget: se escribe una sola instantánea actual al iniciar y al cambiar reproducción, portada o estado. Una respuesta vacía o retrasada no borra la instantánea. Los avisos del proveedor no envían metadatos ni acciones; mantienen temporalmente elegible el muestreador existente. La revisión de presencia es de baja frecuencia; no hay otro bucle de lectura musical. Los cambios se agrupan y las recargas se limitan; macOS conserva su presupuesto de actualización.

Si falta estado, el widget ofrece **Conectar** en lugar de tres botones bloqueados. Esa acción conecta la selección actual y espera la lectura antes de terminar el App Intent, pero no reproduce/pausa/salta contenido. La flecha circular permite recuperar datos sin quitar los widgets. Un clic de transporte con una sesión obsoleta actualiza primero la representación; no actúa sobre otra canción.

Se muestran errores distintos para ausencia, caducidad, corrupción y acceso al contenedor. Ajustes → Widgets nativos de macOS presenta la última escritura verificada. La miniatura y el título comparten un archivo atómico de acceso privado; cierre, desconexión y reposo eliminan el contenido reproducible.

### Permisos de distribución

La build sigue firmada ad-hoc. Los App Groups no quedan autorizados permanentemente por esa firma. macOS puede pedir consentimiento para la app/extensión; una denegación no se puede resolver fingiendo un resultado ni desactivando seguridad. Para distribución sin estas solicitudes se requiere Developer ID y el perfil que autorice `group.com.kaizentrick.Oruvi` en ambos targets, o un grupo autorizado por Team ID. No se añade Full Disk Access, excepciones de sandbox, lectura de otro contenedor, servidor local ni cambios de SIP/Gatekeeper.

El runner valida datos sintéticos entre procesos firmados y sandbox, pero puede tener una política SIP distinta. El éxito de CI no se presenta como una prueba del consentimiento o de música real en todos los Mac.

Referencias primarias:
- https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date
- https://developer.apple.com/forums/thread/721701
''')
p=Path('README.md'); p.write_text(p.read_text()+'''
### Recuperación de widgets (0.10.1)

Si el widget no recibe datos, pulsa **Conectar** o la **flecha circular**: recupera la selección actual sin iniciar reproducción. También está en **Oruvi → Widgets de macOS → Conectar y actualizar widgets**. No es necesario eliminar y volver a añadir los widgets. Si aparece un aviso de datos compartidos, autoriza Oruvi; una denegación se informa, no se oculta como si la app estuviera cerrada. La firma ad-hoc conserva las limitaciones de autorización de App Groups descritas en `Resources/MEDIA.md`.
''')
Path('.github/workflows/prepare-widget-sync.yml').unlink()
Path(__file__).unlink()
print('Widget integration applied; no release or main ref modified.')
