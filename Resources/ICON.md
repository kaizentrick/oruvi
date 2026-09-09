# Icono de Oruvi — 0.9.2

La actualización 0.9.2 corrige un recurso ICNS truncado que se había subido como `Luma.icns`. Que el archivo existiera y el instalador compilara no demostraba que macOS pudiera interpretarlo.

## Recursos de producción

- `OruviIcon.png`: imagen maestra RGBA de 1024 × 1024 del diseño aprobado «Frosted Window», con interior opaco y exterior transparente.
- `OruviIcon.icns`: generado con `iconutil` en un runner macOS de GitHub; incluye 16, 32, 128, 256 y 512 puntos a 1x/2x.
- `OruviIcon.json`: huellas SHA-256 de los recursos aprobados. Una modificación posterior exige revisar el arte y actualizar el manifiesto, no omitir la validación.

`CFBundleIconFile` apunta a `OruviIcon.icns`, el mismo nombre que se copia a `Contents/Resources`. La aplicación carga ese recurso firmado directamente para su icono en ejecución. No escribe atributos de Finder ni modifica su propio bundle, no borra cachés y no reinicia el Dock.

## Pruebas que bloquean la publicación

La compilación valida cabeceras, tamaños declarados, límites y tipos de bloques ICNS, CRC de PNG y huellas SHA-256. Diez casos de regresión rechazan binarios incompletos, alteraciones y referencias al nombre antiguo. `iconutil` descompone el ICNS y AppKit/ImageIO decodifican las diez representaciones. Se comprueban dimensiones, esquinas transparentes, interior opaco y equivalencia de píxeles entre el PNG maestro y la representación de 1024 píxeles.

Las pruebas se repiten sobre **Oruvi.app dentro del DMG montado en solo lectura**, incluyendo el cargador usado por la app, versión y número de compilación. La publicación existente verifica firma de actualización, assets y descarga pública byte a byte. Un fallo impide publicar esa compilación.

## Actualización

Se mantiene el identificador `com.kaizentrick.Oruvi`, la clave pública de Sparkle y el feed de releases. La versión pasa a 0.9.2 y GitHub asigna un número de compilación nuevo. Las mejoras del widget de 0.9.1 se conservan.

El icono de aplicación es distinto del símbolo monocromo de la barra de menús. Oruvi sigue siendo una aplicación accesoria: este cambio no fija una entrada en el Dock ni altera las preferencias del usuario. Las pruebas se ejecutan en GitHub, no en la Mac personal; no constituyen una observación de la caché de Finder de cada equipo.
