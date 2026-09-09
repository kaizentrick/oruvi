#!/usr/bin/env python3
"""One-shot, fail-closed source migration on the isolated feature branch.
This script and its preparation workflow remove themselves before the commit.
No credentials, personal machine, release assets or main ref are modified.
"""
from pathlib import Path
import subprocess

EXPECTED = 'feat/system-media-desktop-widget'
branch = subprocess.check_output(['git', 'branch', '--show-current'], text=True).strip()
if branch != EXPECTED:
    raise SystemExit('This migration only runs on its isolated feature branch.')

def replace(path, old, new):
    p = Path(path)
    text = p.read_text()
    if text.count(old) != 1:
        raise SystemExit(f'{path}: expected one exact replacement; source has changed.')
    p.write_text(text.replace(old, new))

replace('Sources/PlaybackSelection.swift',
'''    case music = "com.apple.Music", spotify = "com.spotify.client"
    var id: String { rawValue }
    var name: String { self == .music ? "Apple Music" : "Spotify" }
    var symbol: String { self == .music ? "music.note" : "waveform" }''',
'''    case music = "com.apple.Music", spotify = "com.spotify.client", system = "oruvi.system"
    var id: String { rawValue }
    var name: String { self == .system ? "Ahora suena" : (self == .music ? "Apple Music" : "Spotify") }
    var symbol: String { self == .system ? "play.rectangle" : (self == .music ? "music.note" : "waveform") }''')

model = 'Sources/StandbyModel.swift'
replace(model, '    var notchVisible = false', '''    var desktopWidgetEnabled = false {
        didSet {
            prefs.set(desktopWidgetEnabled, forKey: "desktopWidgetEnabled")
            if started { policyChanged() }
        }
    }
    private var activeSystemBundleID = ""
    @ObservationIgnored private var systemArtworkData: Data?
    var notchVisible = false''')
replace(model, '(isVisible || notchVisible) && !screenSleeping', '(isVisible || notchVisible || desktopWidgetEnabled) && !screenSleeping')
replace(model, '    var screenSleeping = false', '''    var screenSleeping = false {
        didSet { if started && oldValue != screenSleeping { policyChanged() } }
    }''')
replace(model, '        notchEnabled = defaults.bool(forKey: "notchEnabled")', '''        notchEnabled = defaults.bool(forKey: "notchEnabled")
        desktopWidgetEnabled = defaults.bool(forKey: "desktopWidgetEnabled")''')
replace(model, '        let workspace = NSWorkspace.shared.notificationCenter, standard = NotificationCenter.default', '''        let workspace = NSWorkspace.shared.notificationCenter, standard = NotificationCenter.default
        observe(standard, .oruviSystemMediaChanged) { [weak self] in
            guard let self, self.connected, self.needsPlayback, !self.demoMode,
                  self.effectivePlayerPreference == .automatic else { return }
            if self.reading { self.pendingMusicHint = true } else { self.readMusic() }
        }''')
replace(model, '''    private func policyChanged() {
        updatePlaybackSurface()''', '''    private func policyChanged() {
        updatePlaybackSurface()
        SystemMediaBridge.shared.setEnabled(connected && needsPlayback && !demoMode && !LumaEnvironment.isTesting && effectivePlayerPreference == .automatic)''')
replace(model, '''        guard connected, !demoMode, needsPlayback else { return }
        generation += 1''', '''        guard connected, !demoMode, needsPlayback else { return }
        SystemMediaBridge.shared.setEnabled(!LumaEnvironment.isTesting && effectivePlayerPreference == .automatic)
        generation += 1''')
replace(model, '''        musicQueue.async { [playerRouter] in playerRouter.reset() }; refreshPlayback()''', '''        musicQueue.async { [playerRouter] in playerRouter.reset() }
        refreshPlayback()
        if !LumaEnvironment.isTesting { SystemMediaBridge.shared.reconnect() }''')
replace(model, '''    func disconnectMusic() {
        generation += 1''', '''    func disconnectMusic() {
        SystemMediaBridge.shared.setEnabled(false)
        generation += 1''')
replace(model, '''        playerArtworkURL = ""; lyricsAvailability = .idle; toastMessage = nil''', '''        playerArtworkURL = ""; activeSystemBundleID = ""; systemArtworkData = nil
        lyricsAvailability = .idle; toastMessage = nil''')
replace(model, '            connectionStatus = "Abre Apple Music o Spotify en este Mac"; return', '            connectionStatus = effectivePlayerPreference == .automatic ? "Reproduce contenido compatible con Ahora suena en este Mac" : "Abre " + activePlayer.name + " en este Mac"; return')
replace(model, '''        if let shuffle = snapshot["shuffle"] as? NSNumber, let repeated = snapshot["repeatMode"] as? NSNumber {''', '''        activeSystemBundleID = snapshot["systemBundleID"] as? String ?? ""
        let nextSystemArtwork = snapshot["systemArtwork"] as? Data
        if source == .system && systemArtworkData != nextSystemArtwork {
            artworkTask?.cancel(); artworkTask = nil; artwork = nil; artworkRetryAt = 0
        }
        systemArtworkData = nextSystemArtwork
        if let shuffle = snapshot["shuffle"] as? NSNumber, let repeated = snapshot["repeatMode"] as? NSNumber {''')
replace(model, '''    func fetchLyrics() {
        lyricsTask?.cancel(); lyricsTask = nil''', '''    func fetchLyrics() {
        lyricsTask?.cancel(); lyricsTask = nil
        // Browser/video titles must never be sent to a music-lyrics service.
        guard activePlayer != .system else {
            lyricsAvailability = .unavailable; lyricsRetryAt = .greatestFiniteMagnitude
            lyricStatus = "Letras automáticas no disponibles para esta fuente."; return
        }''')
replace(model, '''        let identity = track, source = activePlayer, artworkURL = playerArtworkURL, allowNetwork = automaticArtwork''', '''        if activePlayer == .system {
            let identity = track
            artworkRetryAt = ProcessInfo.processInfo.systemUptime + 60
            guard let data = systemArtworkData else { artworkStatus = "Esta app no publica portada"; return }
            artworkTask = Task { [weak self] in
                let decoded = await Task.detached(priority: .utility) { Self.decodeArtwork(data) }.value
                guard !Task.isCancelled, let self, self.track == identity, self.needsPlayback else { return }
                if let decoded { self.artwork = decoded.0; self.setPalette(decoded.1); self.artworkStatus = "Portada del reproductor" }
                self.artworkTask = nil
            }
            return
        }
        let identity = track, source = activePlayer, artworkURL = playerArtworkURL, allowNetwork = automaticArtwork''')
replace(model, '''        let source = effectivePlayerPreference.source ?? activePlayer
        if !connected && !demoMode { connectMusic() }''', '''        let source = effectivePlayerPreference.source ?? activePlayer
        let bundleID = source == .system ? activeSystemBundleID : source.rawValue
        if !connected && !demoMode { connectMusic() }''')
replace(model, 'NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.rawValue)', 'NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)')
replace(model, '''    func useDemo() {
        generation += 1''', '''    func useDemo() {
        SystemMediaBridge.shared.setEnabled(false)
        generation += 1''')
replace(model, '''    func shutdown() {
        generation += 1''', '''    func shutdown() {
        SystemMediaBridge.shared.setEnabled(false)
        generation += 1''')

app = 'Sources/OruviApplication.swift'
replace(app, '    private var notch: NotchController?', '    private var notch: NotchController?\n    private var desktopWidget: DesktopWidgetController?')
replace(app, '        notchController.start()', '''        notchController.start()
        let widget = DesktopWidgetController(model: model)
        desktopWidget = widget; widget.start()''')
replace(app, '''        notchItem.state = model.notchEnabled ? .on : .off''', '''        notchItem.state = model.notchEnabled ? .on : .off
        let widgetItem = item("Mostrar widget de escritorio", #selector(toggleDesktopWidget))
        widgetItem.state = model.desktopWidgetEnabled ? .on : .off''')
replace(app, '    @objc private func toggleAutomatic()', '''    @objc private func toggleDesktopWidget() {
        let model = StandbyModel.shared
        model.desktopWidgetEnabled.toggle()
        if model.desktopWidgetEnabled && model.playbackSurface == .notch && !model.connected { model.connectMusic() }
    }
    @objc private func toggleAutomatic()''')
replace(app, '''        StandbyModel.shared.shutdown(); LumaEnvironment.cleanTestingData()''', '''        desktopWidget?.stop()
        StandbyModel.shared.shutdown(); LumaEnvironment.cleanTestingData()''')

build = 'scripts/build.sh'
replace(build, 'DEPS="$BUILD/deps"; bash scripts/dependencies.sh "$DEPS"', 'DEPS="$BUILD/deps"; bash scripts/dependencies.sh "$DEPS"\nbash scripts/system-media.sh "$DEPS"')
replace(build, '''    cp "$DEPS/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"''', '''    cp "$DEPS/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
    cp "$DEPS/mediaremote-adapter.pl" "$app/Contents/Resources/mediaremote-adapter.pl"
    cp "$DEPS/MediaRemoteAdapter-LICENSE.txt" "$app/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"
    ditto "$DEPS/MediaRemoteAdapter.framework" "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
    codesign --force "${SIGN_OPTIONS[@]}" --sign "${SIGN_IDENTITY:--}" "$app/Contents/Frameworks/MediaRemoteAdapter.framework"''')
replace(build, '''cmp -s LICENSE "$BUILD/mount/LICENSE.txt"''', '''cmp -s LICENSE "$BUILD/mount/LICENSE.txt"
cmp -s "$DEPS/mediaremote-adapter.pl" "$BUILD/mount/Oruvi.app/Contents/Resources/mediaremote-adapter.pl"
[[ -s "$BUILD/mount/Oruvi.app/Contents/Resources/MediaRemoteAdapter-LICENSE.txt" ]]
codesign --verify --strict "$BUILD/mount/Oruvi.app/Contents/Frameworks/MediaRemoteAdapter.framework"''')
replace('scripts/check.sh', '''python3 - <<'PY'\n''', '''xcrun swiftc -O -whole-module-optimization -warnings-as-errors -swift-version 5 -parse-as-library \\
    Sources/SystemMediaCore.swift scripts/verify-system-media.swift -o "$WORK/verify-system-media"
"$WORK/verify-system-media"
python3 - <<'PY'
''')
replace('scripts/verify-surfaces.swift', '        print("PASS:', '''        model.desktopWidgetEnabled = true
        expect(model.needsPlayback, "desktop widget keeps the single sampler eligible with notch hidden")
        expect(defaults.bool(forKey: "desktopWidgetEnabled"), "desktop opt-in persists")
        model.screenSleeping = true
        expect(!model.needsPlayback, "sleep suspends desktop playback")
        model.screenSleeping = false
        model.desktopWidgetEnabled = false
        expect(!model.needsPlayback, "no surface needs playback after desktop opt-out")
        model.apply(["status": "ok", "source": "oruvi.system", "id": "system:qa", "title": "QA video", "artist": "", "album": "", "duration": 0, "position": 12, "playing": true, "systemBundleID": "com.example.Player"])
        expect(model.activePlayer == .system && model.hasTrack, "system video enters real model")
        expect(!model.playbackOptionsAvailable, "system cannot invent shuffle/repeat support")
        model.fetchLyrics()
        expect(model.lyricsAvailability == .unavailable, "video metadata never requests music lyrics")
        expect(model.playerPreference == .spotify && model.notchPlayerPreference == .automatic, "system playback preserves independent selectors")
        print("PASS:''')

readme = Path('README.md')
s = readme.read_text()
s = s.replace('Funciona con las aplicaciones de escritorio Apple Music y Spotify.', 'En Automático sigue la sesión Ahora suena que publica macOS; mantiene controles directos para Apple Music y Spotify de escritorio.')
start = s.index('**Automático** consulta')
end = s.index('Solo existe un muestreador de reproducción:', start)
s = s[:start] + '''**Automático** sigue la sesión activa de «Ahora suena» de macOS, no la ventana que tenga el foco. Puede mostrar y controlar música, vídeo, podcasts y contenido de navegadores cuando el reproductor publique una sesión compatible. Apple Music y Spotify conservan sus puentes nativos, portadas y opciones propias. Sin datos del sistema se recupera la selección nativa anterior. Las opciones manuales siguen limitándose a aplicaciones instaladas y no cambian la preferencia de la otra superficie.

**Alcance y dependencia:** no significa controlar literalmente todo sonido ni garantiza compatibilidad con todos los sitios o versiones de macOS. Se integra MediaRemote Adapter, compilado de una revisión fija con licencia BSD-3-Clause. Usa una API privada que Apple puede cambiar; si falla, las integraciones nativas siguen disponibles. No se desactiva SIP, Gatekeeper ni la validación de bibliotecas. No hay captura de audio, pantalla, micrófono, historial o pestañas. Los controles vuelven a consultar el destino antes de actuar y se rechaza un cambio de posición si el contenido cambió. La portada depende de los datos publicados por cada app; no se inventa cuando falta.

''' + s[end:]
s = s.replace('## Widgets\n', '''## Widget de escritorio

Desde el icono de Oruvi en la barra de menús activa **Mostrar widget de escritorio**. La tarjeta incluye portada, título, artista, anterior/reproducir-pausar/siguiente y un icono para abrir StandBy. Arrástrala desde el fondo para colocarla; su posición se conserva. Puedes ocultarla con la X o desde el mismo menú.

Es una **tarjeta de escritorio de Oruvi**, no una extensión de la galería «Editar widgets» de macOS. Está debajo de las ventanas normales, comparte el selector del Notch y no añade otro muestreador. Permanece disponible aunque ocultes el notch; se oculta durante StandBy, bloqueo y reposo. Requiere que Oruvi siga abierto. Las selecciones Notch/escritorio y StandBy permanecen independientes.

No se guardan títulos o portadas del sistema en disco ni se envían los títulos de vídeos/navegadores a LRCLIB o al catálogo de Apple. Detalles y matriz de pruebas en [Resources/MEDIA.md](Resources/MEDIA.md).

## Widgets del notch
''')
readme.write_text(s)
notices = Path('THIRD_PARTY_NOTICES.md')
notices.write_text(notices.read_text() + '''
## MediaRemote Adapter

Origen: https://github.com/ungive/mediaremote-adapter

Revisión fijada: `73f14ab1568371e6e3c44063f21c34c5e2712c4d`.

Licencia BSD-3-Clause. Se compila el framework desde esa revisión; el script Perl y la licencia completa se copian a `Oruvi.app/Contents/Resources/`. El aviso completo queda en `MediaRemoteAdapter-LICENSE.txt`. No se incorpora el reproductor de pruebas. Esta integración utiliza MediaRemote privado y no implica respaldo de Apple ni garantía de compatibilidad futura.
''')
# Keep changelog history and distribution version untouched until release review.
changelog = Path('CHANGELOG.md')
changelog.write_text(changelog.read_text().replace('# Changelog', '# Changelog\n\n## Unreleased — reproducción del sistema y escritorio\n\n- Automático sigue Ahora suena; Apple Music y Spotify manuales se conservan.\n- Tarjeta propia de escritorio con portada, controles y acceso a StandBy.\n- Procesos acotados, portada local sin historial, suspensión y pruebas de regresión.\n', 1))
Path('.github/workflows/prepare-media-upgrade.yml').unlink()
Path(__file__).unlink()
print('Source migration complete; preparation files removed. No release published.')
