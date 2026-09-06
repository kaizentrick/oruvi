# Changelog

## 0.8.0 — Notch ajustado y widgets nativos

### Notch

Se eliminan los cuatro puntos adicionales bajo la franja de la cámara. La geometría usa coordenadas de pantalla y escala de píxeles; AppKit determina el tamaño, sin restricciones intrínsecas ni una segunda zona segura automática de SwiftUI. Las pantallas sin recorte conservan una isla superior. El indicador derecho es una nota musical visible únicamente si hay canción en reproducción; no muestra el icono de Standby al pausar.

El panel ampliado organiza Música, Archivos, Agenda y Temporizador en pestañas de alto estable. Conserva negro, tipografía del sistema, controles de primer clic, etiquetas accesibles y Reducir movimiento. Standby y Ajustes permanecen en el pie. El foco del teclado es explícito, no por hover; Esc cierra el panel. Los diálogos nativos y el arrastre suspenden el cierre automático. Standby automático no cubre el notch en uso.

### Widgets

Bandeja de hasta 20 referencias locales, arrastre desde Finder y hacia otras apps, selección múltiple, selector de archivos y mostrar en Finder. Duplicados acotados, validación fuera del hilo principal y protección frente a respuestas tardías después de vaciar. No se copian, mueven, borran ni persisten los originales.

AirDrop usa NSSharingService y el selector real de macOS. El usuario decide destinatario; el resultado se informa desde el delegado del servicio. Sin APIs privadas, listas de dispositivos inventadas ni cambios de Bluetooth/Wi-Fi.

Agenda opcional con EventKit y consentimiento explícito. macOS solicita acceso completo; Oruvi solo lee. Hasta seis eventos de los próximos siete días, con estados de permiso, carga, vacío y desconexión. Consultas en un actor, actualizaciones limitadas a la pestaña visible y sin persistencia ni envío de eventos a servidores.

Temporizador de 5/15/25 minutos con pausa, repetición y reinicio. ContinuousClock incluye reposo y no depende del reloj civil. Un único vencimiento de fondo; actualización visual cada segundo solo al mostrar el widget. Sonido opcional, apagado por defecto. No modifica Concentración ni la app Reloj.

### Validación y distribución

Nuevas pruebas para escalas y orígenes de pantalla, altura compacta, indicador, políticas de archivo y temporizador. Los PR compilan y verifican la aplicación/DMG en GitHub sin claves de publicación; únicamente main publica el feed firmado. Se conserva el instalador fijo Oruvi.dmg y Sparkle.

No se ha sustituido la validación interactiva de AirDrop, permisos reales de Calendario ni inspección visual en hardware físico por una compilación. No se operó una Mac personal para implementar esta versión. Continúa sin notarización de Apple y sin mediciones nuevas de batería/RAM.

## 0.7.0 — Notch, Spotify y descargas directas

### Interfaz

Panel notch original, persistente y no activante, con ampliación al pasar el puntero, controles de reproducción y acceso al Standby. Soporte de recorte físico y de isla compacta en pantallas sin cámara recortada. Al entrar en Standby se oculta de forma explícita; al salir vuelve sin abrir Ajustes ni quitar el foco al escritorio.

El reproductor sin canción muestra solo un botón musical. Cuando no hay letra disponible, el disco y los controles permanecen centrados. La petición manual muestra un aviso que se cierra solo; los estados de búsqueda, desconexión y letras desactivadas tienen mensajes diferentes.

Nueva malla predeterminada Aurora y selector Aurora / Atardecer / Medianoche. Interpolación explícita de color, aislada del árbol de vistas; la paleta provisional incluye el título de la canción.

### Reproducción

Puente local a Spotify desktop mediante Apple Events, además del de Apple Music. Selección automática o explícita del proveedor; comandos y cachés separados. Conversión de duración de Spotify de milisegundos a segundos. No se instalan reproductores, no se modifican bibliotecas y no se utilizan tokens de cuenta ni MediaRemote privado.

La portada de Spotify se obtiene de la URL proporcionada por su app, con dominios HTTPS acotados y límites de bytes. No se persiste ni se sustituye por otra portada de Apple. Las respuestas de canciones anteriores se descartan.

### Recursos

El notch compacto consulta metadatos a un ritmo menor que Standby y no mantiene animada la malla del escritorio. No busca letras para una superficie de letra oculta. Se evita consultar el segundo reproductor mientras el preferido esté reproduciendo. Se mantienen pausa por sueño/bloqueo, límite de imágenes, reloj monotónico y manejo de respuestas antiguas.

### Distribución

README orientado a instalación, archivo estable Oruvi.dmg por release, instalador numerado idéntico, SHA256SUMS y feed firmado. El feed usa la URL inmutable numerada. La release se publica solo después de subir todos los recursos; un fallo deja un borrador.

Script configure-downloads.sh para actualizar descripción, enlace y temas del repositorio, subir el commit local y verificar la publicación desde el Terminal del mantenedor. No modifica repositorios ajenos ni incorpora credenciales.

### Validación y límites

Verificación con reproducción sintética de cambio de proveedor, letras ausentes, aviso temporal, URL de imágenes, colores y relevo notch/Standby. No se validó reproducción real de Spotify en el Mac de desarrollo porque no está instalado. No se han medido batería ni memoria en una sesión prolongada. La distribución local continúa sin notarización de Apple; Ed25519 no equivale a Developer ID.

## 0.6.0

Actualizaciones con Sparkle y firmas Ed25519, publicación mediante GitHub Actions, geometría estable al alternar letras, estado apagado transparente y tipografías del sistema con pesos configurables.

## 0.5.0

Identidad propia de Oruvi, arranque AppKit explícito, recuperación de reproducción, controles homogéneos, protección multimedia e importación de preferencias de Luma.
