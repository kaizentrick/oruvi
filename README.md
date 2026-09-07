# Oruvi

Un compañero de música en el notch. Un Standby de pantalla completa cuando dejas de usar tu Mac.

Copyright © 2026 KaizenTrick · [Licencia MIT](LICENSE)

## Descargar e instalar

### [Descargar Oruvi para Mac — Oruvi.dmg](https://github.com/kaizentrick/oruvi/releases/latest/download/Oruvi.dmg)

[Última versión y notas](https://github.com/kaizentrick/oruvi/releases/latest)

**Requiere Apple Silicon (M1 o posterior) y macOS 26 o posterior.** No incluye soporte Intel. Funciona con las aplicaciones de escritorio Apple Music y Spotify. No necesitas Xcode, Terminal, Homebrew, el código fuente ni una cuenta de GitHub para instalarla.

Abre el DMG, arrastra **Oruvi.app** a **Applications**, expulsa el disco y abre Oruvi desde Aplicaciones. Autoriza Automatización para el reproductor que utilices. No se reproduce otro audio encima del reproductor.

**Sin notarización de Apple:** esta distribución está firmada localmente. macOS puede bloquear el primer inicio. Comprueba el origen y, únicamente si confías en esta copia, autoriza esa app desde **Ajustes del Sistema → Privacidad y seguridad → Abrir igualmente**. No desactives Gatekeeper ni SIP. Un Mac administrado puede impedir esta excepción. Ed25519 verifica las actualizaciones, pero no sustituye Developer ID ni notarización.

Usa `Oruvi.dmg`, no los ZIP «Source code». Cada release publica ese alias junto a un DMG numerado de contenido idéntico y `SHA256SUMS.txt`.

## Notch más ligero

El compacto conserva exactamente la franja superior que macOS informa para la cámara, sin añadir altura debajo. Muestra portada a la izquierda cuando hay canción y una nota musical a la derecha solo mientras reproduce. En pausa, ese lado queda vacío. En monitores sin recorte aparece una pequeña isla superior.

El panel ampliado tiene cuatro pestañas **solo con iconos**: Música, Archivos, Agenda y Temporizador. Las ayudas al detener el puntero y las etiquetas de VoiceOver conservan sus nombres. En Música se muestran una portada de 48 puntos, título, artista, selector de reproductor y anterior/pausa/siguiente. Se elimina la fila inferior de iconos sueltos: **Standby, Ajustes y Cerrar** se agrupan en el menú de tres puntos.

El ancho ampliado base pasa a 360 puntos. Música utiliza 158 puntos de contenido bajo la cámara; los otros widgets disponen de 240. Se adapta dentro de los límites de la pantalla y conserva el borde superior al cambiar de vista. Los cambios de altura son suaves y respetan Reducir movimiento. El compacto no aumenta de tamaño por estos cambios.

### Apertura, también sobre la cámara

La zona de activación incluye toda la banda del notch, **12 puntos a cada lado y 10 debajo**, además del centro de la cámara y el borde superior exacto. Se comprueban coordenadas globales del puntero, sin depender exclusivamente de que una vista reciba un evento sobre píxeles visibles. Esto complementa el seguimiento nativo permanente y no depende de música, portada o conexión al reproductor.

La espera configurada para abrir es de **35 ms**, la transición de **160 ms** y la tolerancia de cierre de **220 ms**. Son parámetros de implementación, no mediciones de latencia en todos los equipos. Moverse dentro no reinicia el plazo. El clic habilita teclado; Esc, clic fuera o Cerrar cierran sin reabrir inmediatamente bajo un cursor inmóvil.

No hay una ventana transparente sobre el escritorio ni interceptación de clics ajenos. Los monitores de movimiento son pasivos; una comprobación de posición cada 60 ms se mantiene únicamente cerca del notch para recuperar eventos ausentes detrás de la cámara. Se detiene lejos de la zona, durante Standby, bloqueo, reposo y al salir. No se observan teclas globales ni se guarda historial del puntero. Detalles en [Resources/NOTCH.md](Resources/NOTCH.md).

## Reproductores independientes

**Notch y Standby guardan selecciones separadas:** Automático, Apple Music o Spotify. Puedes usar, por ejemplo, Automático en el Notch y Apple Music en Standby. Cambiar uno no cambia el otro, ni siquiera desde Ajustes. Al actualizar, la preferencia anterior se copia una sola vez a ambos; las decisiones posteriores se conservan por separado.

El selector permanece visible incluso sin canción. Detecta aplicaciones mediante las API de macOS y solo ofrece opciones explícitas instaladas; **Automático siempre permanece disponible**. No instala ni inicia aplicaciones para detectarlas. Una preferencia guardada para una aplicación retirada se informa como no instalada, sin sustituirla silenciosamente. Las opciones se refrescan al abrir o acercarse al selector.

**Automático** consulta las aplicaciones compatibles que están ejecutándose. Una aplicación pausada no oculta a otra que reproduce. Cuando se observa que otra empieza a reproducir, la prioriza; si ambas ya reproducen y no puede determinar un comienzo nuevo, mantiene una elección estable. Al pulsar un control vuelve a resolver el reproductor antes de enviar la acción, en vez de fiarse de metadatos anteriores. Un gesto de posición no se aplica a una grabación distinta de la mostrada.

**Alcance:** Automático controla Apple Music y Spotify de escritorio mediante sus diccionarios públicos Apple Events/ScriptingBridge. No significa control universal de YouTube, navegadores o todas las apps de audio. No utiliza MediaRemote privado, Spotify Web API, contraseñas ni tokens de cuenta; no controla una sesión que solo exista en el teléfono. Spotify ofrece repetición activada/desactivada en este puente, no se simula «repetir una».

Solo existe un muestreador de reproducción: al entrar o salir de Standby usa la preferencia de la superficie visible, cancela contenido pendiente y descarta respuestas antiguas. No se añaden dos bucles permanentes de consulta. El permiso o la desconexión de una superficie no modifica la selección guardada de la otra.

## Widgets

**Archivos y AirDrop.** Arrastra un archivo local desde Finder hacia el notch. La zona de acercamiento abre Archivos automáticamente y muestra «Suelta para añadir», incluso con elementos en la bandeja. Solo se añade al soltarlo; cancelar o retirarlo restaura la vista anterior. También hay selector de archivos, selección múltiple, arrastre hacia otras apps y Mostrar en Finder. Hasta 20 referencias temporales, sin duplicados. Vaciar o retirar **no borra, mueve ni copia los originales**. La bandeja se vacía al cerrar Oruvi y no se guarda en disco.

AirDrop utiliza el selector nativo de macOS mediante `NSSharingService.sendViaAirDrop`: tú eliges el destinatario. Sin selección se ofrece la bandeja completa; con elementos marcados solo esos. El resultado procede del sistema. Oruvi no simula dispositivos ni cambia Wi-Fi/Bluetooth ni envía archivos sin intervención. Se aceptan archivos locales, no promesas de archivos de cualquier app ni enlaces web; el original debe seguir existiendo. No se inspeccionan contenidos, carpetas recursivas ni el portapapeles general. La anticipación solo consulta tipos anunciados en el portapapeles de arrastre durante el gesto y cerca del notch.

**Agenda.** Está desconectada inicialmente. Conectar Calendario solicita autorización EventKit. macOS exige acceso completo para consultar eventos; Oruvi solo lee y no crea, edita ni elimina. Muestra hasta seis próximos eventos dentro de siete días. Las consultas se limitan a la pestaña visible, con cambios de EventKit y refresco periódico de un minuto. Al salir de Agenda se detienen los temporizadores y se retiran los datos visibles. No se persisten ni se envían a servidores. Desconectar detiene la función en Oruvi; para revocar el permiso del sistema usa Privacidad y seguridad → Calendarios.

**Temporizador.** Intervalos de 5, 15 y 25 minutos con pausa, reinicio y repetición. `ContinuousClock` incluye reposo y no depende de cambios de fecha/zona horaria. Hay un vencimiento de fondo, no un bucle por segundo; el contador visual solo se actualiza con su vista abierta. Sonido opcional, desactivado inicialmente. No crea alarmas en Reloj ni cambia Concentración y se cancela al cerrar Oruvi.

El cierre automático y Standby por inactividad esperan mientras se usan diálogos nativos o un arrastre.

## Standby, letras y malla

Standby conserva Reloj, Música y Reloj + música a pantalla completa. Oculta el notch, Dock y menú durante la presentación y los restaura al salir con Esc. No sustituye la pantalla de bloqueo ni se muestra sobre pantallas protegidas. Ajustes no se abre automáticamente al iniciar.

El selector de Standby está en Música y en la barra superior de las otras dos vistas; Ajustes permite cambiar ambos selectores. La portada abre el reproductor mostrado: el destino se captura antes de abandonar la presentación y volver a la preferencia del notch.

Las letras proceden de **LRCLIB o tus archivos LRC**, no son las letras oficiales de Apple o Spotify. Se sincronizan por línea; la disponibilidad depende de la grabación. Sin letra no se reserva un panel vacío y el botón informa del estado temporalmente. Carga, desconexión y letras desactivadas tienen estados distintos.

La malla Aurora tiene alternativas Atardecer y Medianoche, con adaptación a la portada e interpolación de color independiente de los controles. Una respuesta de portada antigua no cambia la canción nueva. Las imágenes de Spotify se descargan únicamente desde dominios permitidos de la URL suministrada por la app, sin sustituirlas por otro catálogo ni guardarlas en la caché persistente.

Se emplean fuentes nativas del sistema; no se incluyen ni descargan archivos de fuentes. Se respetan Reducir movimiento y Reducir transparencia.

## Energía y privacidad

No hay captura de pantalla, cámara, micrófono, audio, historial o pestañas; tampoco telemetría propia, Electron ni WebView. La nota musical es un estado, no un visualizador. Las letras no se consultan para el notch compacto.

Fuera de Standby, las consultas musicales se espacian aproximadamente 3 segundos con corriente y 5 en batería mientras reproduce, y más al pausar; las notificaciones pueden anticipar actualizaciones. En Automático se comprueban ambos proveedores en ejecución, a diferencia de las versiones anteriores que se detenían en el primero. La detección del puntero no ejecuta consultas de reproducción por movimiento.

En Standby, Automático limita la malla a 24 fps con corriente y la deja estática en batería. Fluido permite hasta 30/12 fps; Ahorro, bajo consumo, calor y Reducir movimiento detienen la animación. El reposo y bloqueo suspenden reproducción y Agenda; un temporizador iniciado conserva su vencimiento. Son políticas de implementación, no cifras medidas de autonomía o memoria.

La protección multimedia y la opción conservadora de navegadores se mantienen. No se garantiza detección universal de vídeos silenciosos. Las búsquedas externas de letras y portada envían los metadatos necesarios a LRCLIB/Apple/servidores de imágenes de Spotify; esos servicios reciben la IP. No se envían documentos o eventos de Agenda a servidores propios.

## Actualizaciones y desarrollo

Usa **Buscar actualizaciones** en Oruvi. Sparkle comprueba el feed y el archivo con Ed25519. El enlace humano fijo descarga `Oruvi.dmg`; el feed usa el DMG numerado de una release concreta, no ese alias. No borres releases publicadas que puedan necesitar versiones anteriores.

Los PR ejecutan comprobaciones y compilación completa en GitHub con `ORUVI_REPOSITORY=''`, sin secretos ni publicación. Solo `main` publica: valida, compila, verifica, firma y sube todos los recursos antes de hacer Latest. Un fallo no sustituye el instalador anterior. Los cambios de documentación no empaquetada no consumen una compilación.

Para desarrollar con SDK macOS 26:

```bash
bash scripts/check.sh
bash scripts/build.sh
```

Resultado: `dist/Oruvi-0.9.0-arm64.dmg`. El bundle sigue siendo `com.kaizentrick.Oruvi`; los datos históricos permanecen en `~/Library/Application Support/LumaStandby`.

`bash scripts/configure-downloads.sh` permite publicar desde el Terminal del mantenedor usando su sesión normal de GitHub CLI. No evade restricciones de acceso ni cambia otros repositorios.

**Conserva una copia cifrada de `.private/sparkle.key`.** Nunca se sube a Git; la app solo contiene la clave pública y CI utiliza `ORUVI_SPARKLE_PRIVATE_KEY`. Developer ID y las credenciales de notarización son independientes: la compilación local admite `SIGN_IDENTITY` y `NOTARY_PROFILE`. No marques una release como notarizada sin verificarlo.

## Verificación

Se conservan las pruebas de lógica existentes y se añaden matrices de selección automática, aplicaciones instaladas, preferencias separadas, migración, cámara/bordes y pantallas múltiples. La compilación ejecuta además pruebas sobre el modelo real de Oruvi con preferencias aisladas, sin arrancar la interfaz, abrir reproductores, solicitar permisos ni hacer búsquedas externas. El DMG se monta y se verifican firma, binario y copia de la licencia.

Estas pruebas **no equivalen a una sesión interactiva en todos los modelos de Mac**, una transferencia real de AirDrop ni pruebas con permisos/cuentas reales de Calendario o Spotify. No se ha utilizado la Mac personal para desarrollar esta actualización y no se afirman benchmarks nuevos.

## Licencia y atribución

El código de Oruvi se distribuye bajo la **MIT estándar**, con copyright de KaizenTrick. Permite usar, copiar, modificar y redistribuir, incluso comercialmente, conservando el aviso de copyright y la licencia en copias o porciones sustanciales. No es una prohibición de reutilización del código. El archivo completo se incluye en el repositorio, dentro de la app y en el DMG.

La licencia propia no transfiere derechos sobre letras, música, imágenes, tipografías o componentes de terceros. Consulta [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) y [SECURITY.md](SECURITY.md). Oruvi es independiente de Apple y Spotify y no incorpora código ni recursos de Boring Notch.
