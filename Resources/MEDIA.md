# Ahora suena y widget de escritorio — 0.9.1

## Añadir y recuperar la tarjeta

En la barra superior: icono de Oruvi → **Mostrar widget de escritorio**.

También: **Ajustes → Widget de escritorio → Mostrar ahora y recuperar posición**, o menú de tres puntos del notch → Mostrar widget de escritorio.

Mostrar es idempotente: no oculta un widget ya activo. Sale de Standby y recoloca la tarjeta en la pantalla del puntero. La eleva durante 8 segundos sin activar otra app ni iniciar reproducción. La chincheta o Mantener widget al frente permite fijarla sobre las ventanas normales. Desfijada, vuelve al nivel del escritorio. Arrastra el asa de tres líneas; la X oculta la tarjeta.

La tarjeta aparece inicialmente cuando no hay decisión guardada. Respeta un false explícito guardado por el usuario, incluso en 0.9.0. La introducción se consume una sola vez; no es una ventana de bienvenida repetitiva ni altera los permisos musicales.

**No es una extensión WidgetKit ni aparece en Editar widgets de macOS.** Esta implementación es un panel AppKit/SwiftUI propio de Oruvi. Requiere que Oruvi esté abierto. El repositorio no anuncia registro en una galería a la que no aporta una extensión.

## Música y privacidad

Automático sigue la sesión Ahora suena de macOS; cada proveedor debe publicarla y aceptar los comandos. No se promete controlar cualquier sonido o todas las webs. MediaRemote Adapter utiliza API privada que puede cambiar. Apple Music y Spotify manuales mantienen sus puentes Apple Events.

Notch y tarjeta comparten selección y un único muestreador. Standby guarda una preferencia independiente y oculta la tarjeta al presentarse. Reposo y bloqueo también la ocultan aun cuando esté fijada; salir detiene temporizadores y auxiliares.

Mostrar no conecta un reproductor desactivado. El botón Conectar controles conserva ese paso explícito. No se graba audio, pantalla ni historial de pestañas. Títulos de vídeos no se envían a servicios musicales externos; portadas genéricas permanecen en memoria y solo se aceptan las publicadas por la fuente.

El adaptador está fijado a `73f14ab1568371e6e3c44063f21c34c5e2712c4d`, compilado en CI y empaquetado con licencia BSD-3-Clause. No se descarga código al ejecutar la app ni se modifica la seguridad de macOS. Los procesos y datos tienen límites de tiempo y tamaño.

## Comprobaciones

`scripts/verify-desktop-widget.swift` prueba migración, opt-out persistente, introducción única, visibilidad, monitores negativos/desconectados, recuperación de posición y normalización de tamaño.

`scripts/verify-surfaces.swift` usa el modelo real y una ventana AppKit en el runner de GitHub: mostrar, mostrar repetidamente, ocultar, pin, retorno al escritorio, reposo, Standby y cierre. Las preferencias están aisladas; no inicia el modelo completo ni abre reproductores, cuentas o solicitudes de permisos. Las pruebas anteriores de playback, selección, notch, portadas y metadatos se conservan.

CI compila la app completa con warnings-as-errors, verifica firmas y monta/verifica el DMG. La publicación en main verifica además el feed de actualización firmado y las descargas anónimas. Esto no sustituye pruebas interactivas con Music, Spotify, Safari/Chrome, Stage Manager, permisos reales o todos los modelos de pantalla. No se afirman realizadas esas pruebas manuales.
