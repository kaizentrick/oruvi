# Oruvi

Un compañero de música en el notch. Un Standby de pantalla completa cuando dejas de usar tu Mac.

## Descargar e instalar

### [Descargar Oruvi para Mac — Oruvi.dmg](https://github.com/kaizentrick/oruvi/releases/latest/download/Oruvi.dmg)

[Ver la última versión y sus notas](https://github.com/kaizentrick/oruvi/releases/latest)

**Requiere macOS 26 o posterior y un Mac con Apple Silicon — M1 o posterior.** Esta distribución no incluye soporte Intel. Funciona con las aplicaciones de escritorio **Apple Music y Spotify**. No necesitas Xcode, Terminal, Homebrew ni descargar el código fuente para instalar la app.

Abre **Oruvi.dmg**, arrastra **Oruvi.app** a **Applications** y ábrela desde Aplicaciones. El notch aparece en el escritorio; al pasar el puntero se amplía. Para escuchar música abre tu reproductor y concede el permiso específico de **Automatización** que macOS solicite. Oruvi no reproduce otro audio encima del reproductor.

**Aviso de seguridad:** la distribución actual está firmada localmente, pero no está notarizada por Apple. macOS puede advertirlo o bloquear el primer inicio. Comprueba el origen y, únicamente si confías en esta copia, autoriza esa aplicación desde **Ajustes del Sistema → Privacidad y seguridad → Abrir igualmente**. No desactives Gatekeeper ni SIP. Un Mac administrado puede impedir esta excepción. La firma de actualizaciones Ed25519 no sustituye Developer ID ni la notarización.

El enlace directo requiere una release con el archivo **Oruvi.dmg**. El workflow publica ese nombre fijo además del DMG numerado; las releases antiguas pueden tener únicamente el archivo numerado. Ambos contienen exactamente la misma app. Los ZIP «Source code» que GitHub agrega son para desarrolladores, no son el instalador.

## Dos modos, una sola aplicación

**Notch compacto:** panel negro integrado alrededor de la cámara, sin icono en el Dock. Su alto se limita a la franja que macOS informa mediante `NSScreen.safeAreaInsets.top`, alineada a píxeles: no añade cuatro puntos decorativos debajo. En pantallas sin recorte físico utiliza una pequeña isla superior. La portada queda a la izquierda cuando hay canción; a la derecha solo aparece una nota musical cuando está reproduciéndose. Al pausar o detener, el lado derecho queda vacío. No es un visualizador de audio y no hay un botón de pantalla completa permanente en el compacto.

**Notch ampliado:** al pasar el puntero aparecen Música, Archivos, Agenda y Temporizador en una superficie negra común, con tipografía y controles del sistema. Las pestañas mantienen el mismo alto para evitar saltos. Pasar el puntero no activa la app ni captura el teclado; hacer clic en el compacto permite navegar el panel con teclado y cerrarlo con Esc. Los controles de Standby y Ajustes están en el pie del panel ampliado. Durante una selección de archivos, un envío de AirDrop o un permiso de Agenda no se cierra automáticamente al retirar el puntero. La activación automática de Standby espera mientras el notch está en uso.

**Standby:** reloj editorial, reproductor centrado o reloj con música a pantalla completa. Oculta el notch, el Dock y la barra de menús mientras está activo. Al salir con **Esc**, vuelve el notch y se restaura la interfaz del sistema. No reemplaza la pantalla de bloqueo ni se dibuja encima de las pantallas protegidas del sistema.

Oruvi inicia como complemento del escritorio. Standby se activa desde el notch, desde su menú o al cumplirse el intervalo de inactividad configurado. Ajustes no se abre automáticamente. El notch se puede desactivar desde la barra de menús o Ajustes. Esta es una implementación propia: no incluye código ni recursos de Boring Notch.

## Widgets nativos del notch

### Archivos y AirDrop

Arrastra archivos o carpetas desde Finder hacia el notch: se abre la pestaña Archivos. También puedes usar **Elegir archivos**. La bandeja conserva hasta **20 referencias temporales**, evita rutas duplicadas y permite arrastrar los elementos a otras aplicaciones, seleccionarlos para AirDrop o mostrarlos en Finder. «Retirar» y «Vaciar» solo quitan referencias de Oruvi: **no borran, mueven ni copian los originales**. La bandeja se vacía al cerrar la app y no se guarda en disco ni se sincroniza.

**AirDrop** abre el servicio nativo `NSSharingService.sendViaAirDrop`. Tú eliges el destinatario en el diálogo de macOS. Oruvi no envía archivos automáticamente, no inventa una lista de dispositivos ni cambia Bluetooth, Wi-Fi o la visibilidad de AirDrop. Si no seleccionas elementos, se ofrece la bandeja completa; si marcas algunos, solo esos. El resultado de la transferencia proviene del servicio del sistema, no de una simulación.

La bandeja acepta URLs de archivos locales explícitamente entregadas por el usuario. No lee continuamente el portapapeles, no descarga enlaces, no recibe promesas de archivos desde todas las apps y no hace búsquedas recursivas en carpetas. Un archivo movido o eliminado después de añadirlo puede dejar de estar disponible; el original debe seguir existiendo al utilizarlo.

### Agenda

Está **desconectada por defecto**. En Agenda, pulsa **Conectar Calendario** para autorizar EventKit. macOS requiere permiso completo para consultar eventos; la implementación de Oruvi es **de solo lectura**: no crea, edita ni elimina eventos. Muestra hasta seis próximos eventos dentro de los siguientes siete días, con fecha, hora y calendario de origen; los eventos de todo el día se identifican por separado. **Abrir Calendario** abre la aplicación de Apple, sin usar enlaces privados a eventos.

Las consultas solo se realizan con Agenda conectada y visible. Se actualiza ante cambios de EventKit y, mientras está abierta, como máximo con una comprobación periódica por minuto, además de la actualización de apertura. Al salir de la pestaña o cerrar el panel se detienen los temporizadores y se retiran los datos visibles. Los registros no se guardan en disco ni se envían a servidores. **Desconectar** detiene la función dentro de Oruvi; para revocar el permiso del sistema utiliza Privacidad y seguridad → Calendarios.

### Temporizador

Intervalos de **5, 15 y 25 minutos**, con iniciar, pausar, repetir y reiniciar. Utiliza `ContinuousClock`: incluye el reposo del equipo y no depende de cambios de fecha, hora o zona horaria. Mantiene un solo vencimiento pendiente, no un bucle de fondo cada segundo; el contador visual se actualiza únicamente mientras su pestaña está abierta. El sonido final es opcional y está apagado inicialmente. No crea alarmas en Reloj, notificaciones push ni sesiones de Concentración; al salir de Oruvi se cancela.

Se mantiene el estado real de alimentación en el pie del panel. No se añaden widgets de tiempo meteorológico, recordatorios ni controles de Concentración en esta versión: requerirían más permisos, fuentes de datos o interacciones. Ningún acceso se presenta como una integración funcional si solo es una maqueta.

## Apple Music y Spotify

En **Ajustes → Notch y reproductor** elige Automático, Apple Music o Spotify. Automático conserva el reproductor preferido mientras siga reproduciendo; si está pausado y el otro reproduce, utiliza el otro. Cuando ambos suenan, puedes elegir explícitamente uno. Los controles se envían únicamente al reproductor seleccionado.

La integración utiliza Apple Events / ScriptingBridge de las aplicaciones de este Mac. No pide contraseñas, no usa tokens de Spotify Web API ni APIs privadas de MediaRemote. No controla directamente un reproductor web ni una sesión que exista únicamente en un teléfono. Spotify requiere su aplicación de escritorio. Su interfaz de automatización ofrece repetición activada/desactivada; Oruvi no simula un control de «repetir una» que ese puente no proporciona.

Cada proveedor tiene identidad de pista y caché diferenciadas. Al cambiar de reproductor o de canción se descartan las letras anteriores. La portada de Spotify se obtiene desde la URL que proporciona su app, únicamente en dominios de imágenes permitidos. No se sustituye por otra portada del catálogo Apple, no se persiste en la caché de Oruvi y se conserva su proporción original.

## Letras sin espacios vacíos

Con letra disponible, el botón de comillas abre el panel y muestra su estado seleccionado. Sin letra, la portada, la información y los controles permanecen centrados. Pulsar el botón muestra **«Esta canción no tiene letra sincronizada disponible»** y el aviso desaparece solo, aproximadamente a los tres segundos.

Una búsqueda en curso, una desconexión del proveedor y las letras desactivadas tienen mensajes diferentes. No se afirma que una canción carezca de letra cuando solo falló la red. No hay un panel vacío reservado para contenido ausente. Las letras recuperadas son de **LRCLIB** o de tus archivos **LRC**, no las letras oficiales de Apple o Spotify; se sincronizan por línea, no por palabra. La cobertura y los tiempos dependen de cada grabación.

Cuando no hay una canción, el estado vacío del reproductor muestra un botón musical para abrir la app elegida. No incluye «Ver demostración» ni eslóganes de relleno.

## Malla, fuentes y movimiento

La malla predeterminada **Aurora** combina azules, índigos y tonos verde azulado. También están disponibles Atardecer y Medianoche. La adaptación a portada interpola los componentes de color en una capa independiente de la interfaz; no vuelve a animar el reloj o los controles completos. Mientras llega una imagen, una paleta provisional cambia también según el título de la canción. Una respuesta antigua de portada no puede recolorear la canción nueva.

Se utilizan las tipografías nativas del sistema: SF Pro, SF Pro Rounded, monoespaciada, serif y otros estilos instalados. Reloj y contenido se configuran por separado. No se incluyen ni se descargan archivos de fuentes. Los controles siguen siendo accesibles y admiten el primer clic. Se respeta Reducir movimiento y Reducir transparencia.

## Energía y privacidad

El notch no captura pantalla, cámara, micrófono, muestras de audio, historial ni pestañas. No ejecuta una animación continua ni un visualizador de audio. La nota musical es un estado visual, no un analizador de ritmo. La ampliación se anima solamente durante la interacción.

Fuera de Standby, solo se consultan metadatos musicales para el notch: aproximadamente cada **3 segundos con corriente y 5 en batería** mientras hay reproducción, con mayor espera al pausar. Las notificaciones de reproductor son pistas de mejor esfuerzo para actualizar antes. No se solicitan letras en segundo plano para el panel compacto. Al desactivar ambas superficies se detienen las consultas periódicas. El reposo y bloqueo ocultan el panel y suspenden el trabajo de reproducción y Agenda; un temporizador iniciado explícitamente conserva su vencimiento.

En Standby, Automático limita la malla a 24 fps con corriente y la deja estática en batería. Fluido permite hasta 30/12 fps; Ahorro, bajo consumo, calor y Reducir movimiento detienen su animación. Las portadas se decodifican fuera del hilo principal, con tamaño acotado. La sincronía usa reloj monotónico y temporizadores de cambio de línea, no consultas por fotograma.

La protección multimedia impide la activación automática cuando otras aplicaciones mantienen la pantalla despierta o tienen salida de audio activa; Apple Music y Spotify por sí solos están exceptuados. La protección conservadora adicional también espera mientras un navegador o reproductor de vídeo reconocido esté al frente, incluso pausado. Se puede desactivar. No se garantiza detección universal de todos los vídeos silenciosos.

Las búsquedas externas opcionales envían los metadatos necesarios a LRCLIB o al catálogo Apple; la descarga de portada de Spotify contacta su servicio de imágenes. Esos servicios reciben la IP. No hay telemetría propia, Electron, servidor de audio ni WebView integrado. Las políticas de ahorro son decisiones de implementación, no cifras medidas de autonomía o RAM.

## Actualizaciones y descargas de GitHub

**Buscar actualizaciones** está en el menú superior y en Ajustes. Sparkle verifica el feed y el archivo con Ed25519. Las descargas automáticas se configuran por separado; instalar no equivale a ejecutar código arbitrario desde un commit.

El workflow valida los cambios de código en `main`, compila, firma el DMG y el feed, sube todos los archivos a una release en borrador y solo entonces la publica como Latest. Cambios exclusivamente en la documentación no consumen una compilación de macOS. El enlace humano fijo es:

```text
https://github.com/kaizentrick/oruvi/releases/latest/download/Oruvi.dmg
```

Sparkle utiliza el archivo **numerado e inmutable** de cada release, no el alias fijo. `SHA256SUMS.txt` permite comprobar que el alias y el instalador numerado son idénticos. No borres releases publicadas que aún puedan ser necesarias para una actualización.

### Publicar desde el Terminal del mantenedor

Con el código revisado y guardado en un commit de `main`:

```bash
bash scripts/configure-downloads.sh
```

El script utiliza la sesión normal de `gh`, comprueba el remoto y el secreto de firma, configura descripción/enlace/temas del repositorio, hace el push y espera el workflow. No cambia la visibilidad de otros repositorios ni publica claves privadas. Si la sesión de herramientas no puede acceder a la configuración de GitHub CLI, este paso debe ejecutarse desde el Terminal del mantenedor. No se eluden restricciones de acceso.

### Compilar y validar

```bash
bash scripts/check.sh
bash scripts/build.sh
```

Requiere herramientas con SDK macOS 26. El resultado es `dist/Oruvi-0.8.0-arm64.dmg`. El proyecto conserva un nombre de carpeta histórico y datos en `~/Library/Application Support/LumaStandby`; el producto y bundle son **Oruvi** / **com.kaizentrick.Oruvi**.

Los pull requests ejecutan `Validate Oruvi` en un runner de GitHub: pruebas de regresión, compilación completa y verificación del DMG, sin utilizar una Mac personal ni abrir la interfaz. Utilizan `ORUVI_REPOSITORY=''` para crear únicamente una compilación de validación, **sin feed, clave privada ni publicación**. El flujo de `main` conserva la firma obligatoria y es el único que publica actualizaciones.

**Conserva una copia cifrada de `.private/sparkle.key`.** Nunca se sube a Git; solo la clave pública se incorpora a la app. En CI de publicación se utiliza `ORUVI_SPARKLE_PRIVATE_KEY`. Una distribución sin advertencias por falta de notarización requiere un certificado propio Developer ID y credenciales de notarización; `SIGN_IDENTITY` y `NOTARY_PROFILE` están previstos en la compilación local. No se debe marcar una release como notarizada sin haber completado esa validación.

## Verificación y límites

Las comprobaciones automáticas del notch cubren geometría con diferentes escalas y orígenes de pantalla, límite inferior del panel compacto, estado del indicador musical, URLs permitidas, duplicados y capacidad de la bandeja, así como inicio, pausa, repetición y vencimiento del temporizador. La compilación valida las integraciones con AppKit y EventKit. Estas comprobaciones **no equivalen** a una inspección visual en todos los modelos de Mac, una transferencia real de AirDrop o una sesión real con permisos y cuentas de Calendario. Esas pruebas interactivas siguen siendo necesarias antes de afirmar compatibilidad completa con todos los entornos.

También se conserva la verificación existente de lógica de reproducción y preferencias. La ausencia de Spotify se maneja sin abrir ni instalar otra app. Los tests sintéticos no equivalen a una prueba con una cuenta real de Spotify ni a un benchmark de batería.

Referencias de implementación: [NSScreen safeAreaInsets](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets), [NSHostingView sizingOptions](https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions), [NSSharingService](https://developer.apple.com/documentation/appkit/nssharingservice), [AirDrop](https://developer.apple.com/documentation/appkit/nssharingservice/name/sendviaairdrop), [acceso a Calendario](https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui).

Apple y Spotify son marcas de sus titulares; Oruvi es independiente. La publicación de código no otorga derechos sobre letras, carátulas o tipografías de terceros. Consulta `THIRD_PARTY_NOTICES.md` y `SECURITY.md`.
