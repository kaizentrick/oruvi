# Contribuir a Oruvi

Puedes ayudar probando la app, reportando un problema, mejorando las instrucciones o enviando un cambio. Si propones un cambio grande de comportamiento o diseño, abre un issue para acordar el alcance antes de implementarlo.

## Reportar un problema

[Abre un issue](https://github.com/kaizentrick/oruvi/issues/new) e incluye la versión de Oruvi, la versión de macOS, el modelo de Mac, los pasos para reproducir el problema y lo que esperabas ver. Si ocurre con música, indica qué reproductor usabas y si pasó en Notch, Standby o el widget. Si adjuntas capturas, usa datos de demostración o elimina datos personales. Para vulnerabilidades, sigue el [proceso de seguridad](../SECURITY.md).

## Abrir un pull request

1. [Crea un fork](https://github.com/kaizentrick/oruvi/fork) y clónalo en una Mac con Apple silicon, macOS 26 o posterior, Xcode con el SDK de macOS 26 o posterior y CMake.
2. Crea una rama, haz el cambio y ejecuta las comprobaciones locales.

   ```bash
   git switch -c mi-cambio
   bash scripts/check.sh
   ORUVI_REPOSITORY='' bash scripts/build.sh
   ```

   El DMG de prueba queda en `dist/`. El canal firmado de publicación pertenece al repo principal.

3. Sube la rama a tu fork y abre un PR hacia `main` en `kaizentrick/oruvi`. Describe el cambio y cómo lo probaste. Para cambios visuales, adjunta una captura del estado anterior y del nuevo.

El [código de Oruvi usa la licencia MIT](../LICENSE). Conserva los avisos de copyright y licencia al compartir tu copia. Los [componentes de terceros](../THIRD_PARTY_NOTICES.md) mantienen sus propios avisos.
