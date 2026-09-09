# Notch 0.11.0 — Presentación, interacción y personalización

Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT

Esta versión integra la primera etapa del estudio de Glance: superficie animada, silueta integrada, avisos breves, háptica opcional y elección de pantalla. No añade cámara, reconocimiento facial, contraseñas, autenticación ni ventanas sobre la pantalla bloqueada.

## Superficie visible y ventana contenedora

El compacto conserva la altura de `safeAreaInsets.top` cuando hay recorte físico. No añade altura debajo de la cámara mientras está en reposo. Sin recorte se mantiene una isla de 30 puntos, separada 5 puntos del borde superior. La forma tiene una unión cóncava al borde en pantallas con cámara y esquinas redondeadas en las demás.

La ventana AppKit es un contenedor acotado al máximo contenido y su sombra. Solo se recoloca/redimensiona al cambiar la geometría de pantalla. Abrir, cerrar, cambiar de pestaña o mostrar un aviso anima únicamente la superficie SwiftUI, no `NSWindow.setFrame`.

`NotchSurfaceAnimator` conserva un único estado de ancho, alto, radios y expansión. La silueta y el límite de entrada usan la misma muestra. El temporizador de animación solo existe durante una transición; se cancela al terminar, ocultar, bloquear, dormir o salir. Una interrupción parte del estado visible, no del destino antiguo. No hay un segundo bucle multimedia ni una animación permanente. Reducir movimiento y bajo consumo evitan esta animación.

Los valores configurados son 35 ms de espera de apertura, 220 ms de expansión, 180 ms de contracción y 220 ms de tolerancia antes de cerrar. No son mediciones de latencia o autonomía en cada Mac. La apertura y el cierre usan curvas distintas, acotadas para no desbordar el contenedor.

Música conserva 360 puntos de ancho base y 158 puntos de contenido bajo la cámara; las otras pestañas usan 240. Los tamaños se acotan a la pantalla. Música mantiene portada, título, artista, selector y controles. Las cuatro pestañas siguen siendo iconos con nombres accesibles. La presentación compacta solo muestra la nota musical mientras hay contenido reproduciéndose.

## Clics, cámara y arrastre

La ventana contenedora NO es el objetivo del puntero. `NotchController.frame` representa la superficie visible. La región de activación conserva el centro físico de la cámara, el borde superior exacto, 12 puntos laterales y 10 inferiores. Se combinan seguimiento nativo y coordenadas globales pasivas; no se observan teclas ni se suprimen o reinyectan eventos.

La transparencia de entrada de `NSWindow` se actualiza por posición del puntero y en cada muestra de animación. Además, `NSHostingView.hitTest` rechaza márgenes y esquinas fuera de la forma. Las comprobaciones de cierre y arrastre no usan el rectángulo completo del contenedor. No se coloca una ventana del tamaño del escritorio ni se capturan clics de otros programas intencionadamente. La verificación geométrica no sustituye una prueba end-to-end de entrega de clics en WindowServer.

El sondeo de posición de 60 ms sigue limitado a la zona cercana a la cámara. El sondeo ya existente durante un gesto de arrastre también recupera la transparencia de entrada cuando AppKit consume eventos de movimiento. Lejos del notch no se consulta música por cada movimiento.

Arrastrar un archivo desde Finder abre Archivos sin esperar la animación. Solo se añaden referencias después de soltar y comprobar que el original está disponible. Cancelar/restaurar pestaña, límites, deduplicación, diálogos y selección de destinatario AirDrop se conservan. Añadir a la bandeja no se presenta como un envío completado. No se lee el portapapeles general ni el contenido de los documentos.

## Avisos y háptica

Más opciones (…) → Personalizar notch permite cambiar estas preferencias:

- **Avisos breves**, activados inicialmente. Se muestran después de añadir referencias reales a la bandeja o al terminar un temporizador. Un aviso dura tres segundos, admite descarte y abre su pestaña correspondiente. Cerrado, el notch añade una franja breve; abierto, reserva espacio para no tapar controles. No cambia automáticamente la pestaña. Un aviso de temporizador no es reemplazado por una importación posterior. No se guardan avisos ni se reproducen eventos ocurridos con el notch oculto.
- **Respuesta háptica**, desactivada inicialmente. Usa el intérprete nativo del dispositivo y las preferencias de accesibilidad de macOS. Se limita a acciones del usuario como abrir o cambiar de pestaña y tiene antirrebote. No vibra por temporizadores, notificaciones ni cada movimiento del puntero. El efecto físico depende del hardware.

## Pantallas y ayuda

Más opciones (…) → Personalizar notch → Pantalla del notch ofrece Automática y las pantallas detectadas. Automática prefiere un recorte físico, después la pantalla principal y finalmente otra disponible. Una selección explícita usa el identificador UUID público de la pantalla cuando está disponible. Si se desconecta, se usa una alternativa sin borrar la preferencia, para recuperarla cuando vuelva. Esto no mueve la selección de pantalla de Standby ni cambia sus reproductores.

La Guía del notch se abre a petición desde el menú; no aparece automáticamente al iniciar. Explica música, archivos, Agenda, Temporizador y la instalación de widgets nativos. Los permisos se siguen solicitando cuando una función los necesita, no en bloque.

## Funciones y privacidad conservadas

Notch y Standby conservan selecciones independientes: Automático, Apple Music y Spotify. Las opciones manuales se filtran por aplicaciones instaladas. Automático sigue la sesión Ahora suena que publica el sistema mediante la integración existente; no garantiza compatibilidad con todo sonido o sitio web. Los controles y la recuperación de metadatos de la versión 0.10.1 no se sustituyen.

La extensión WidgetKit real, su instantánea atómica y sus controles permanecen independientes de este contenedor. No se vuelve a introducir una tarjeta flotante como sustituto del widget. La transición a Standby oculta el notch; el bloqueo/reposo lo suspende junto con los monitores, la animación y los avisos. Se mantienen icono aprobado, identidad del bundle, permisos actuales y actualizaciones Sparkle verificadas.

No se usa SkyLight para mostrar ventanas en la pantalla protegida. No se importan modelos ArcFace/InsightFace ni los assets de Glance. No se añade ningún permiso de cámara, Accesibilidad para introducir contraseñas, micrófono o captura de pantalla. La firma ad-hoc y la ausencia de notarización de la distribución actual no cambian con esta función.

## Verificación

`verify-notch-presentation.swift` comprueba geometría en pantallas con y sin recorte, escalas, coordenadas negativas y pantallas desplazadas; márgenes transparentes y esquinas; interpolación acotada; elección/restauración de pantalla; antirrebote háptico; retargeting del animador real y cancelación de su temporizador. `scripts/check.sh` lo compila con AppKit y SwiftUI en macOS 26, además de todas las regresiones previas.

La compilación completa sigue verificando el modelo multimedia real, la recuperación del widget, extensión WidgetKit, firma, icono y DMG. Estas pruebas no demuestran por sí solas fluidez percibida, sensación del trackpad, autorización de widgets en otra cuenta o un arrastre real desde Finder. La matriz manual pendiente incluye movimiento rápido por la cámara, clics en todos los márgenes durante la animación, drag/drop cancelado y aceptado, menús, VoiceOver, pantallas conectadas/desconectadas y reposo/bloqueo/Standby.

## Referencias y autoría

Implementación propia de Oruvi inspirada en la separación entre ventana fija y superficie visible y en la presentación notch/isla de [Glance, revisión 2958301](https://github.com/jonnyoo/glance/tree/295830146e334ec36e2b578aecde511672ab3c31), de Jonathan Zhou, publicado bajo MIT. No se han copiado sus modelos, imágenes, animaciones de video ni código de credenciales. Las atribuciones de las dependencias existentes permanecen en `THIRD_PARTY_NOTICES.md`.

API públicas consultadas: [NSWindow.ignoresMouseEvents](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents), [NSView.hitTest](https://developer.apple.com/documentation/appkit/nsview/hittest(_:)), [NSHapticFeedbackManager](https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager), [CGDisplayCreateUUIDFromDisplayID](https://developer.apple.com/documentation/colorsync/cgdisplaycreateuuidfromdisplayid(_:)).
