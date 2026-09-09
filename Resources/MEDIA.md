# Oruvi: WidgetKit nativo y reproducción del sistema

## Añadir el widget

Instala Oruvi en Aplicaciones y abre la app al menos una vez. Haz clic secundario en el escritorio, abre **Editar widgets** y busca **Oruvi**. El widget **Música y Standby** tiene tamaños pequeño y mediano. macOS gestiona posición, tamaño, estilo y eliminación. La extensión está en `Oruvi.app/Contents/PlugIns/OruviWidgets.appex`.

Desde 0.10.0 se elimina la tarjeta AppKit de 0.9.0/0.9.1. Sus opciones Mostrar, Mantener al frente y arrastre propio dejan de existir. No se intenta convertir la posición anterior en una colocación del sistema: añadir o quitar widgets siempre es decisión del usuario desde macOS.

## Arquitectura

La extensión es un target WidgetKit real, sandboxed, con `NSExtensionPointIdentifier=com.apple.widgetkit-extension`. El pipeline genera un proyecto Xcode determinista en el directorio temporal de compilación. Xcode compila la app y la extensión, genera App Intents metadata en ambos targets y empotra la extensión. Las firmas se realizan desde los componentes internos hasta la app, antes del DMG.

`AudioPlaybackIntent` ejecuta los comandos en la aplicación contenedora, sobre el router y la cola de reproducción existentes. No se incluye ScriptingBridge, MediaRemote Adapter ni Sparkle en el widget. El enlace `oruvi://standby` abre la pantalla completa, mientras que los botones de transporte no la abren. Las rutas admitidas son solo navegación; no se aceptan comandos, rutas de archivos ni scripts desde URLs.

El widget refleja la superficie de reproducción activa de Oruvi. Se conservan las preferencias independientes Notch y Standby y sus selectores Automático/Apple Music/Spotify. Un botón verifica sesión, pista y selección antes de actuar; un widget atrasado pide otro clic después de actualizar en vez de controlar contenido diferente por accidente.

## Optimización y ciclo de vida

WidgetKit renderiza representaciones, no una ventana permanente de Oruvi. No hay `NSPanel`, animación de fondo, bucle por segundo ni consultas musicales en el proceso del widget. La app comprueba los widgets realmente añadidos mediante `WidgetCenter` y solo mantiene demanda de reproducción adicional mientras existe uno. La extensión lee una instantánea acotada; no arranca reproductores ni solicita autorización de Automatización.

La app agrupa cambios durante 250 ms, evita reescribir estados iguales y separa recargas solicitadas al sistema al menos 5 segundos. Esas son políticas, no una garantía de latencia. WidgetKit conserva el control del presupuesto y puede demorar portadas, sobre todo cuando la app no está al frente. No se reproduce audio silencioso ni se simula una sesión de audio para evadir ese presupuesto.

Los controles interactivos esperan a escribir el nuevo estado observado antes de terminar el App Intent, tras lo cual WidgetKit solicita su propia actualización. Una sesión reiniciada invalida los botones antiguos. Bloqueo, reposo y desconexión producen estados sin contenido privado y sin transporte habilitado.

## Datos compartidos y privacidad

App Group: `group.com.kaizentrick.Oruvi`, declarado en los entitlements y plists de los dos targets. Se accede por `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`, nunca construyendo una ruta a otros contenedores ni usando excepciones de sandbox.

Una sola instantánea JSON contiene los metadatos actuales y su miniatura JPEG (hasta 192 píxeles, 256 KiB). Límite de archivo: 512 KiB. Escritura atómica, permisos privados, exclusión de copias de seguridad, caducidad de una hora y eliminación al cerrar Oruvi o detectar que se retiró el último widget. No hay historial. WidgetKit conserva sus propias representaciones del widget bajo control del sistema, por lo que Oruvi no puede prometer borrado instantáneo de cada representación mostrada.

La extensión no tiene acceso de red, Apple Events, cámara o micrófono. No se envían títulos de vídeos/navegadores a LRCLIB o catálogos de música. Los controles y la reproducción genérica conservan los límites documentados de MediaRemote: el proveedor debe publicar Ahora suena y aceptar comandos. No se garantiza control de cada sonido del Mac.

## Firma y distribución

El repositorio conserva la distribución ad-hoc existente, sin Developer ID ni notarización configurados. Ed25519 firma la actualización de Sparkle, no convierte el binario en notarizado ni registra un equipo de Apple. macOS puede solicitar permiso para datos compartidos o rechazar componentes conforme a las políticas del equipo. No se modifica Gatekeeper, SIP, TCC ni la validación de bibliotecas.

Para distribución identificada de producción se debe usar una identidad Developer ID real del titular y configurar el App Group y perfiles correspondientes en Apple Developer. No se incluyen claves privadas, equipos ficticios ni perfiles fabricados. El pipeline admite la identidad de firma existente; cualquier incorporación de perfiles debe conservar los identificadores de app y extensión.

## Verificación

Se comprueban contenido nativo del bundle, versión común, arquitectura, entitlements, metadata del App Intent en ambos targets, firma y copia dentro del DMG. En el runner de GitHub se registra temporalmente la extensión con LaunchServices/PlugInKit y se comprueba que el sistema la reconozca. Estas herramientas NO se invocan en la Mac del usuario ni forman parte del inicio normal de Oruvi.

Se mantienen las pruebas de reproducción, preferencias, notch, letras y seguridad existentes; se sustituyen las pruebas de la tarjeta retirada por instantáneas, límites, persistencia atómica, caducidad y demanda del widget nativo. Los ensayos de grupo y registro en GitHub no demuestran una sesión interactiva en cada Mac: los runners pueden tener configuraciones de seguridad distintas de un equipo personal. Se debe verificar instalación/reapertura, galería, permisos y botones con reproductores reales. No se afirman benchmarks de energía ni latencias medidas.

Referencias primarias:
- https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension
- https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date
- https://developer.apple.com/documentation/appintents/audioplaybackintent

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
