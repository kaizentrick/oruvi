# Oruvi

Una presentación ambiental nativa para macOS: reloj editorial, música, letras por línea y un fondo de malla fluida. Apple Silicon; macOS 26 o posterior.

## Versión 0.6.0

El botón de letras distingue apagado, hover y encendido. Al abrir las letras, el reproductor conserva sus dimensiones: en una pantalla amplia se desplaza sin redimensionar portada, tipografía ni controles; en una pantalla compacta, portada y letra se funden dentro del mismo espacio. Los cambios de display usan un fundido en vez de interpolar toda la composición. Se respeta Reducir movimiento.

Tipografía del sistema: SF Pro, SF Pro Rounded, SF Mono, New York y variantes condensada/expandida. Nueve grosores para el reloj. Se conservan las tipografías adicionales que ya estén instaladas. No se distribuyen ni descargan fuentes de Apple.

La actualización incorpora Sparkle 2.9.4, fijado por versión y SHA-256. Los archivos de actualización y el feed usan firmas Ed25519. El origen es un repositorio de GitHub configurado por su propietario, no una URL de ejecución arbitraria.

## Instalar

Abre `dist/Oruvi-0.6.0-arm64.dmg`, cierra la copia anterior y arrastra Oruvi a Applications. La compilación no modifica automáticamente una instalación existente. El menú de la barra superior permite abrir la presentación, cambiar de display, buscar actualizaciones o salir. Esc oculta la presentación; 1/2/3 y las flechas cambian de vista; Espacio reproduce/pausa.

Se conserva el identificador `com.kaizentrick.Oruvi` y la migración única de preferencias de Luma. Los LRC locales permanecen en el directorio de soporte anterior; no se borran durante la actualización.

## Crear el repositorio público

La creación requiere ejecutar GitHub CLI desde una sesión que tenga acceso a tu autorización. El acceso a las credenciales del Mac no está incluido en el código ni en el instalador.

```bash
cd "$HOME/Documents/LumaStandby"
bash scripts/publish-github.sh
```

Por defecto crea `TU_CUENTA_AUTENTICADA/oruvi`. Para una organización o un nombre diferente, pasa explícitamente `propietario/repositorio`. El script se niega a sobrescribir un repositorio existente o un remoto configurado, audita los archivos, realiza el commit, crea el repositorio como público, configura el secreto de firma en Actions y sube main.

No copia claves al código ni al historial. `.private`, `dist`, las compilaciones, fuentes y credenciales están excluidos. La publicación no se da por completada hasta que GitHub confirma el repositorio y el push termina correctamente.

Después de publicar, guarda `propietario/repositorio` en **Oruvi > Ajustes > Actualizaciones**. La compilación local sin repositorio no intenta consultar un destino inexistente. La aplicación ya contiene la clave pública correspondiente; no necesitas cambiarla. Las compilaciones producidas por Actions incorporan automáticamente el repositorio correcto.

## Actualización continua

Un push en main que modifique Sources, Resources, scripts o el workflow inicia una única compilación en macos-26. Los cambios solo de documentación no consumen una compilación de macOS. Los pull requests no reciben la clave de firma y no publican versiones.

El flujo es: verificar código y comportamiento, compilar, firmar componentes, verificar el DMG montado, firmar el DMG con Ed25519, verificarlo con la clave pública incorporada, generar y firmar appcast.xml, subir ambos como una release en borrador y publicar la release completa. Si falla un paso, no se publica el feed de esa compilación.

Cada build recibe un número creciente basado en la hora de construcción. La versión visible, por ejemplo 0.6.0, se cambia en Resources/Info.plist para los hitos del producto. Una modificación a un README o un commit fallido no debe convertirse en una actualización instalable.

Oruvi consulta versiones publicadas al iniciar y aproximadamente cada hora cuando las comprobaciones están habilitadas. Sparkle administra el calendario, la validación, descarga e instalación. Las actualizaciones de fondo se indican en el menú sin robar el foco a una película. La instalación automática al salir está disponible; las operaciones que requieren interacción se muestran cuando el usuario abre el actualizador. No se forza el reinicio durante una reproducción.

Se puede desactivar la búsqueda automática o las descargas desde Ajustes. GitHub recibe las solicitudes de red e IP; el actualizador no recibe la canción, letras, biblioteca ni contraseñas de Música. El perfil del sistema está desactivado.

## Clave de firma: conservar, no publicar

`.private/sparkle.key` es la semilla privada que firma las actualizaciones. Se genera localmente, con permisos restrictivos, y no se muestra en logs. **Haz una copia de seguridad cifrada y no la pierdas.** No es un archivo temporal y no se debe eliminar al limpiar compilaciones.

`Resources/UpdatePublicKey.pub` es la clave pública: sí se incluye en el código y la aplicación. El script de publicación configura la semilla privada como el secreto `ORUVI_SPARKLE_PRIVATE_KEY` del nuevo repositorio para que su workflow de main pueda firmar.

No cambies la clave pública de una versión distribuida sin planificar una rotación compatible con Sparkle. El script de generación falla si encuentra una clave pública sin su clave privada: no crea una identidad diferente silenciosamente.

## Compilación y validación

```bash
bash scripts/check.sh
bash scripts/build.sh
```

La primera ejecución de build descarga Sparkle del release oficial y comprueba el checksum fijado antes de ejecutarlo. El resto de dependencias son frameworks del sistema. Los temporales se eliminan al terminar; `KEEP_BUILD_ARTIFACTS=1` los conserva expresamente para depuración. La limpieza no borra claves, preferencias ni LRC importados.

Para un build dirigido a un repositorio ya creado:

```bash
ORUVI_REPOSITORY='propietario/oruvi' bash scripts/build.sh
```

Los instaladores están en dist; no se guardan en el historial Git. Los scripts de validación son herramientas permanentes de la publicación, no se incluyen en Oruvi.app. Los informes y capturas temporales tampoco se publican.

## Distribución y límites

Esta entrega local usa firma ad hoc y no está notarizada. Al incorporar Sparkle, el build ad hoc no activa Hardened Runtime, porque las bibliotecas cargadas necesitan una identidad Developer ID compatible para la validación de bibliotecas. No se desactiva Gatekeeper, SIP ni ninguna preferencia de seguridad global.

Con una identidad Developer ID instalada, `SIGN_IDENTITY` activa Hardened Runtime y el sellado temporal de todos los componentes. `NOTARY_PROFILE` permite notarizar con un perfil propio ya configurado. El workflow inicial no contiene certificados Apple ni asume aprobación de Apple. Las firmas Ed25519 de actualizaciones son distintas de la firma Developer ID.

La comprobación end-to-end desde GitHub necesita una release pública real. Las pruebas locales de interfaz, geometría y firma no prueban por sí solas la instalación de una release remota ni un benchmark de energía.

Música sigue siendo el reproductor, mediante su diccionario público de automatización. LRCLIB es un proveedor opcional de letras por línea, no las letras oficiales de Apple. La búsqueda externa de portadas es opcional. La cobertura y los derechos del contenido se revisan por separado; este repositorio no contiene letras comerciales, portadas de artistas, audio, contraseñas ni archivos de fuentes.

La protección multimedia no analiza audio ni lee pestañas. El modo conservador también espera mientras un navegador esté en primer plano, incluso sin vídeo. No es un detector universal de todas las plataformas.

## Referencias

- Sparkle: https://sparkle-project.org/documentation/
- Publicación y firmas: https://sparkle-project.org/documentation/publishing/
- Fuentes del sistema: https://developer.apple.com/fonts/
- Diseños nativos AppKit: https://developer.apple.com/documentation/appkit/nsfontdescriptor/systemdesign

Oruvi es independiente de Apple. Hacer público el repositorio no certifica disponibilidad de marca ni aprobación en App Store. No se ha asignado una licencia de redistribución al código propio; las dependencias conservan sus licencias.
