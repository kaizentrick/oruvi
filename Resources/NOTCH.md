# Notch 0.8.1 — Interacción

Copyright (c) 2026 KaizenTrick. Oruvi es un proyecto de KaizenTrick.

## Abrir sin música

La superficie de entrada ahora es nativa y permanente: NSTrackingArea con activeAlways, inVisibleRect y seguimiento de entrada, salida y movimiento. No depende de una portada, canción, permiso de Automatización ni conexión a un reproductor. La interfaz SwiftUI ya no controla el hover. El área lógica incluye la superficie completa, incluso cuando ambos laterales están vacíos.

La apertura se programa una sola vez, con 120 ms de espera; mover el cursor dentro del área no reinicia ese plazo. Salir antes lo cancela. El cierre conserva 380 ms de tolerancia. Los cambios de contenido no sustituyen la zona de entrada. Al volver del reposo, cambiar de Space o recuperar una pantalla, se reconcilian geometría y posición actual del cursor después de los demás observadores de la app.

Esc, clic fuera o el chevron inferior cierran el panel. El cierre explícito no vuelve a abrirlo bajo un cursor inmóvil: vuelve a habilitarse al salir y entrar. La interacción de teclado sigue siendo explícita, no se activa por hover. Standby, bloqueo y reposo continúan ocultando el notch intencionadamente.

## Acercar y soltar archivos

Arrastra un archivo local desde Finder hacia la zona superior del notch. La zona de acercamiento alcanza hasta 84 puntos por debajo del compacto y un margen horizontal limitado. No aumenta el alto visible ni crea una ventana transparente que intercepte los clics del escritorio.

Al reconocer un arrastre nuevo de archivos se abre Archivos sin cambiar de pestaña manualmente y sin esperar una animación de tamaño. Se muestra «Suelta para añadir» tanto con la bandeja vacía como con archivos existentes. El archivo solo se añade cuando AppKit entrega la operación real de soltar. Si retiras el archivo o cancelas antes de soltar, se restaura la pestaña anterior y se libera el estado de arrastre.

Se distinguen los datos de un arrastre nuevo de los que hayan quedado en el portapapeles de arrastre anterior; mover una ventana después de arrastrar un archivo no debería abrir Archivos por datos antiguos. No se reciben promesas de archivos ni URLs de páginas web como documentos locales.

## Solo iconos

Las cuatro pestañas usan símbolos nativos, sin nombres visibles, con un estado seleccionado común y áreas de 44 × 32 puntos. Música, Archivos, Agenda y Temporizador conservan sus etiquetas para VoiceOver y sus ayudas al detener el puntero. El selector de reproductor, energía, Standby, Ajustes y cierre también usan iconos; los nombres de archivos, canciones, eventos y acciones dentro del contenido se mantienen legibles.

## Privacidad y recursos

La anticipación utiliza monitores pasivos de botón izquierdo/arrastre/soltar mientras el notch está visible. No escucha teclas, no cambia ni cancela eventos del usuario, no usa un event tap y no conserva un historial del cursor. Un sondeo temporal de 120 ms existe únicamente mientras el botón permanece pulsado para soportar fuentes que consumen eventos durante su arrastre. Se detiene al soltar, ocultar el notch, entrar en Standby, bloquear, dormir o salir de la app.

Solo cerca del notch, durante el gesto, se consultan el cambio y los tipos anunciados por NSPasteboard.Name.drag. No se lee NSPasteboard.general ni el contenido de los documentos. Las URLs se obtienen en el destino nativo del arrastre. La bandeja sigue siendo de referencias: no copia, mueve ni elimina originales ni sube archivos automáticamente. AirDrop conserva su selector nativo de destinatarios.

## Verificación

scripts/check.sh conserva las comprobaciones existentes y añade scripts/verify-notch-interaction.swift sobre las mismas políticas que utiliza el controlador: apertura independiente del reproductor, estabilidad del plazo, salida/reentrada, suspensión, cierre explícito, datos antiguos de arrastre, gesto nuevo y geometría de acercamiento en distintas posiciones de pantalla. También se comprueban el texto de propósito y el entitlement de Calendario, incluido ahora para compilaciones con Hardened Runtime.

La compilación completa y la verificación del DMG se ejecutan en GitHub. Las pruebas de política y compilación no equivalen a una sesión interactiva con Finder, todos los modelos de pantalla, AirDrop y cuentas reales de Calendario. No se opera la Mac personal para este desarrollo.

Referencias técnicas: https://developer.apple.com/documentation/appkit/nstrackingarea ; https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html ; https://developer.apple.com/documentation/appkit/nspasteboard/name-swift.struct/drag
