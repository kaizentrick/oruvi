# Oruvi: WidgetKit nativo y reproducción del sistema

## Añadir y recuperar el widget

Instala Oruvi en Aplicaciones y abre la app al menos una vez. Haz clic secundario en el escritorio, abre **Editar widgets** y busca **Oruvi**. El widget **Música y Standby** tiene tamaños pequeño y mediano. macOS gestiona posición, tamaño, estilo y eliminación. La extensión está en `Oruvi.app/Contents/PlugIns/OruviWidgets.appex`.

Desde 0.10.0 no existe la tarjeta AppKit de 0.9.0/0.9.1. Se retiraron Mostrar, Mantener al frente y arrastre propio. Añadir o quitar widgets siempre es decisión del usuario desde macOS.

En 0.10.1, si falta estado, pulsa **Conectar** o la **flecha circular** del widget. También está en **Oruvi → Widgets de macOS → Conectar y actualizar widgets**. La acción conecta la selección actual y espera la lectura antes de terminar el App Intent, pero no reproduce, pausa ni salta contenido. No cambia ningún selector. No es necesario eliminar los widgets para recuperar el estado.

Si macOS pide acceso a datos compartidos, autoriza Oruvi. Ausencia de archivo, caducidad, corrupción y acceso denegado se presentan como estados distintos, no como el mismo mensaje de app cerrada. Ajustes muestra la fecha de la última escritura leída de vuelta correctamente por la app; esto no certifica por sí solo que macOS ya haya mostrado esa instantánea en pantalla.

## Arquitectura

La extensión es un target WidgetKit real, sandboxed, con `NSExtensionPointIdentifier=com.apple.widgetkit-extension`. El pipeline genera un proyecto Xcode determinista en el directorio temporal de compilación. Xcode compila la app y la extensión, genera App Intents metadata en ambos targets y empotra la extensión. Las firmas se realizan desde los componentes internos hasta la app, antes del DMG.

`AudioPlaybackIntent` ejecuta los comandos en la aplicación contenedora, sobre el router y la cola de reproducción existentes. No se incluye ScriptingBridge, MediaRemote Adapter ni Sparkle en el widget. El enlace `oruvi://standby` abre la pantalla completa; los botones de transporte no la abren. Las rutas URL admitidas son solo navegación: no aceptan comandos, archivos ni scripts.

El widget refleja la superficie de reproducción activa de Oruvi. Se conservan las preferencias independientes Notch y Standby y sus selectores Automático/Apple Music/Spotify. Un botón verifica sesión, pista y selección antes de actuar. Si la representación quedó obsoleta, se recupera el estado real antes de pedir otro clic; no se controla una grabación diferente por accidente.

## Sincronización y consumo

La publicación no depende de que WidgetCenter enumere primero el widget: se escribe una única instantánea actual al iniciar y al cambiar reproducción, portada o estado. Una respuesta vacía o retrasada de WidgetCenter no borra esa instantánea.

La extensión no tiene una ventana permanente, bucle por segundo ni consultas musicales. Envía una señal sin metadatos al solicitar un timeline, deja una oportunidad asíncrona acotada de 600 ms para que la app publique y lee el estado. Los previews de la galería no solicitan conexión. Una señal solo mantiene temporalmente elegible el muestreador existente; nunca conecta un reproductor previamente desconectado ni envía un comando.

La app combina la presencia informada por WidgetCenter con una demanda temporal de hasta 20 minutos desde la última solicitud. Un temporizador de mantenimiento de 60 segundos, con tolerancia y suspendido durante reposo, revisa presencia y caducidad. No es otro temporizador de lectura de música. Cuando no hay presencia ni demanda vigente, el widget deja de mantener elegible el muestreador. El notch o Standby pueden seguir necesitándolo por separado.

Las publicaciones se agrupan durante 250 ms, sin cancelar indefinidamente las solicitudes forzadas. Los estados iguales no se reescriben salvo renovación de vigencia cada 10 minutos. Las recargas solicitadas se separan al menos 5 segundos; las señales de timeline no crean un ciclo de recarga. La extensión solicita un nuevo timeline a los 15 minutos y programa un estado seguro al caducar la instantánea. Todas son políticas de solicitud: WidgetKit conserva el presupuesto y puede demorar la actualización visual, especialmente con Oruvi en segundo plano. No se reproduce audio silencioso ni se simula una sesión de audio para eludir ese presupuesto.

Los controles esperan una lectura real y una escritura atómica antes de terminar el App Intent. Una sesión reiniciada invalida los botones antiguos. Los errores de acceso se reintentan de forma espaciada o por acción explícita; una resolución fallida del contenedor no queda memorizada para siempre.

## Datos compartidos y privacidad

App Group: `group.com.kaizentrick.Oruvi`, declarado en entitlements y plists de ambos targets. Se accede por `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`, sin construir rutas a otros contenedores ni usar excepciones de sandbox.

Una única instantánea JSON contiene los metadatos actuales y su miniatura JPEG de hasta 192 píxeles y 256 KiB. Límite total: 512 KiB; escritura atómica, permisos privados, exclusión de copias de seguridad y caducidad de una hora. El archivo puede mantenerse mientras Oruvi está abierta aunque la enumeración de widgets esté vacía: así una respuesta tardía no destruye datos que un widget instalado necesita. No se almacena un historial. Desconexión y reposo reemplazan el contenido por estados sin metadatos privados ni transporte habilitado; cerrar Oruvi elimina el archivo.

WidgetKit conserva representaciones bajo control de macOS. Oruvi no promete borrado o sustitución instantáneos de todas las representaciones ya archivadas por el sistema.

La extensión no tiene red, Apple Events, cámara ni micrófono. No se envían títulos de vídeos o navegadores a LRCLIB ni a catálogos musicales. La reproducción genérica mantiene los límites de MediaRemote: el proveedor debe publicar Ahora suena y aceptar los comandos. No se garantiza control de cada sonido del Mac.

## Firma y autorización del grupo

La distribución continúa firmada ad-hoc, sin Developer ID ni notarización configurados. Ed25519 firma la actualización Sparkle; no autoriza el App Group ni convierte el binario en notarizado. macOS puede solicitar consentimiento para datos compartidos o rechazar el acceso conforme a las políticas del equipo. Ese problema no se puede resolver fingiendo datos ni desactivando seguridad.

La firma ad-hoc no concede autorización permanente al App Group. Para la distribución identificada mediante Developer ID se debe configurar una identidad real del titular y perfiles que autoricen `group.com.kaizentrick.Oruvi` en ambos targets, o utilizar un grupo autorizado por el Team ID real. No se incluyen claves privadas, equipos ficticios ni perfiles fabricados. No se añade acceso completo al disco, servidor localhost, otro contenedor compartido ni cambios a Gatekeeper, SIP o TCC.

## Verificación en GitHub

Se conservan las pruebas de reproducción, preferencias, notch, letras y seguridad. La cobertura nueva comprueba el controlador asíncrono real: observación del modelo → miniatura → archivo atómico → solicitud de recarga. Se prueban bootstrap antes de enumeración, respuestas cero tardías, múltiples widgets, señales repetidas sin recargas infinitas, portada tardía, cambio de canción, pausa, reposo, desconexión y cierre.

Un ensayo separado compila el mismo serializador y resolutor del contenedor usado en producción dentro de dos bundles firmados. Un proceso escribe datos sintéticos y otro, sandboxed, verifica que puede leer el mismo título, bytes de imagen e identidad de transporte. Usa un grupo de CI aislado, no música del usuario.

Se verifican los bundles reales, versión común, arquitectura, entitlements, metadata del App Intent, firmas y copia dentro del DMG. LaunchServices/PlugInKit comprueban el registro temporal de la extensión en el runner; no se invocan en la Mac del usuario ni durante el inicio normal de la app.

Estos ensayos no equivalen a pulsar widgets con reproducción real en todos los Mac. Los runners pueden tener una configuración SIP distinta: leer el grupo en CI no demuestra autorización en una Mac personal. Se deben distinguir la entrega probada con datos sintéticos, el registro de la extensión y las pruebas interactivas de permisos y reproductores reales. No se afirman benchmarks de energía ni latencias medidas en el equipo del usuario.

Referencias primarias:
- https://developer.apple.com/documentation/widgetkit/creating-a-widget-extension
- https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities
- https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date
- https://developer.apple.com/documentation/appintents/audioplaybackintent
- https://developer.apple.com/forums/thread/721701
