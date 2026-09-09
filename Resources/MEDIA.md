# Reproducción del sistema y widget de escritorio

## Uso

1. En el selector del notch elige Automático y conecta los controles.
2. Reproduce contenido en una app que publique Ahora suena de macOS.
3. En el menú de Oruvi activa Mostrar widget de escritorio. Arrastra el fondo de la tarjeta para colocarla. El icono de pantalla abre StandBy; la X oculta la tarjeta.

La tarjeta es una ventana de escritorio propia de Oruvi, no un widget de la galería de WidgetKit. Comparte la selección del notch. StandBy mantiene su selector independiente. No hay cambio de reproducción al añadirla: los comandos solo se envían al pulsar controles.

## Arquitectura y límites

- Un solo modelo y muestreador de reproducción alimenta notch, escritorio y StandBy.
- Un único stream de eventos del adaptador observa la sesión seleccionada por macOS. No se observa la app que tenga foco ni se recorren pestañas.
- Automático consulta Ahora suena. Las opciones Music y Spotify fuerzan únicamente la app elegida por sus puentes públicos Apple Events.
- MediaRemote es privado: puede cambiar o dejar de estar disponible. La ausencia de datos recupera los puentes nativos; nunca se modifica la seguridad de macOS.
- Los procesos auxiliares tienen límites de tiempo, tamaño, terminación y memoria. Un stream fallido no entra en un bucle de reinicio. Reconectar o una nueva sesión de visibilidad permite reintentarlo.
- El clic consulta el destino actual. Seek requiere la misma grabación y duración finita; streams en directo o proveedores que prohíben saltar no admiten seek. No se inventa shuffle/repeat para fuentes genéricas.
- No hay promesa de que cada app soporte anterior/siguiente: los comandos se entregan al sistema; el estado mostrado siempre vuelve de la fuente.
- Solo se procesa la portada entregada por la app, con límite de 8 MiB y miniatura de 960 píxeles. No se descarga otra portada para vídeos. No se guardan metadatos, letras de vídeos ni imágenes del sistema en disco.
- La tarjeta usa material nativo, sigue claro/oscuro de macOS y respeta Reducir transparencia. Vive por debajo de ventanas normales; no es una superposición siempre visible.
- El cierre, desconexión, bloqueo, reposo y ausencia de superficies detienen la observación; StandBy oculta la tarjeta. Oruvi debe seguir abierto para usarla.

## Dependencia fijada

MediaRemote Adapter: 73f14ab1568371e6e3c44063f21c34c5e2712c4d (BSD-3-Clause). Se compila en CI; no se descarga código al ejecutarse la app. El binario, script y licencia se empaquetan y verifican dentro del DMG. El cliente de pruebas del proveedor no se ejecuta.

## Verificación

Automatizadas: metadatos Unicode, posición/pausa, duración ausente, valores no finitos, identidad entre fuentes, portada inválida, framing NDJSON fragmentado y acotado; modelo real con preferencias aisladas, opt-in del widget, reposo, fuente genérica sin letras de red y selectores independientes. CI compila toda la app con warnings-as-errors y verifica firmas, dependencias y DMG.

Pendiente de sesión interactiva antes de considerar una release lista: probar Music, Spotify, Safari y Chrome con vídeo/podcast compatible; cambiar de fuente y de pista durante un clic; permisos denegados; falta de portada; añadir/mover/ocultar la tarjeta; varios Spaces y monitores; suspensión/bloqueo; StandBy; instalación limpia y actualización. No se afirma compatibilidad universal ni se presentan esas pruebas manuales como realizadas por CI.
