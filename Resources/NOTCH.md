# Notch 0.9.0 — Diseño e interacción

Copyright (c) 2026 KaizenTrick. SPDX-License-Identifier: MIT

## Superficie compacta y ampliada

La altura compacta sigue limitada a safeAreaInsets.top. No se agregan píxeles debajo de la cámara. La ampliación base es de 360 puntos de ancho: Música reserva 158 puntos de contenido bajo la franja de cámara; Archivos, Agenda y Temporizador reservan 240. El tamaño se acota a la pantalla. La música tiene portada de 48 puntos, título, artista y una fila con selector visible y transporte. Las cuatro pestañas siguen siendo iconos con nombres accesibles. Standby, Ajustes y Cerrar se agrupan en un menú, sin barra inferior de iconos dispersos.

## Cámara y velocidad de apertura

El seguimiento nativo se mantiene, pero ya no es la única fuente de entrada. NotchPointerMonitor observa mouseMoved local y global sin modificar eventos y evalúa NSEvent.mouseLocation en coordenadas AppKit. No hay global key monitoring ni event taps.

NotchHoverGeometry incluye el centro físico de la cámara, el borde superior exacto, 12 puntos laterales y 10 inferiores. La comprobación de límites es inclusiva: CGRect.contains por sí solo excluye el borde superior/derecho. La zona está recortada a la pantalla elegida. No se crea una ventana invisible que capture clics fuera del notch.

La espera para abrir se configura en 35 ms; la animación, en 160 ms; el cierre tolera 220 ms. Son valores configurados, no latencias medidas. Mover el puntero dentro no rearma la espera. Antes de completar la transición se consulta su posición actual. Cerca del notch hay un sondeo temporal de 60 ms para cubrir eventos de seguimiento ausentes en la cámara; lejos de esa zona no hay sondeo ni mutaciones de estado de la interfaz por cada movimiento.

Se elimina el monitor y su sondeo durante Standby, reposo, bloqueo y al salir. Al volver del reposo/cambiar de Space se recuperan geometría y posición tras los demás observadores. Los estados no dependen de título, portada ni reproductor conectado. Esc/clic fuera/Cerrar suprimen reapertura hasta salir y volver a entrar.

## Arrastre

Se conserva la anticipación de archivos: gesto nuevo y cambio del portapapeles de arrastre, cerca de la zona de 84 puntos bajo el compacto. La pestaña Archivos se activa sin esperar una animación y el destino AppKit permanente recibe el drop. Sin drop no se añade nada; retirar/cancelar restaura la pestaña anterior. La bandeja es temporal y de referencias, sin copiar, mover ni borrar originales. No se lee el portapapeles general ni el contenido de documentos.

## Reproductores

Notch usa notchPlayerPreference; Standby conserva playerPreference. Se migra la preferencia antigua una sola vez; no se sobrescriben elecciones posteriores. Las conexiones también conservan claves independientes. Ajustes y todos los modos de Standby permiten acceder a sus selectores. Solo se ofrecen aplicaciones detectadas; Automático no desaparece aunque haya una sola.

El muestreador sigue siendo único y serializado. La superficie visible decide qué preferencia se consulta; el relevo cancela letras/portadas pendientes y descarta respuestas antiguas. La apertura del reproductor captura el destino antes de cerrar Standby. Automático consulta ambos proveedores compatibles que estén en ejecución, no solo el primero; prioriza una nueva reproducción observada y mantiene un desempate estable si ambas siguen sonando. Los controles resuelven otra vez al pulsar. No hay control universal de navegadores ni de todas las apps de audio.

## Verificación y límites

verify-player-hover.swift utiliza las mismas políticas de selección, preferencias y geometría del producto. verify-surfaces.swift ejecuta cambios de superficie sobre StandbyModel real, con preferencias aisladas y sin start(), ventanas, cuentas, permisos o red. Las comprobaciones previas de arrastre, archivos, temporizador, fuentes y actualizaciones se conservan.

La compilación y las pruebas se realizan en GitHub; no equivalen a una prueba visual/operativa en cada recorte físico, con AirDrop real o todos los permisos de usuario. La licencia MIT se valida y se empaqueta con la app/DMG. La notarización de Apple sigue siendo un proceso independiente.

Referencias: https://developer.apple.com/documentation/appkit/nsevent/mouselocation ; https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html ; https://developer.apple.com/documentation/appkit/nsworkspace/urlforapplication(withbundleidentifier:) ; https://opensource.org/license/mit
