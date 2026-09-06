# Componentes y contenido de terceros

## Sparkle 2.9.4

Oruvi incorpora el framework de actualización Sparkle. Su archivo LICENSE completo se copia desde la distribución oficial a `Oruvi.app/Contents/Resources/Sparkle-LICENSE.txt`. El framework mantiene sus componentes y avisos de licencia.

Origen: https://github.com/sparkle-project/Sparkle/releases/tag/2.9.4

Archivo: Sparkle-2.9.4.tar.xz

SHA-256 fijado: `ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9`.

## Apple

La aplicación usa frameworks del sistema, SF Symbols y los diseños tipográficos que macOS expone mediante sus API. El repositorio no incluye archivos SF Pro, SF Compact, SF Mono, New York ni otras fuentes de Apple. Los nombres se utilizan para describir compatibilidad y opciones de tipografía, no afiliación.

## Panel notch

Boring Notch (`https://github.com/TheBoredTeam/boring.notch`) se consultó como referencia funcional. Ese proyecto está publicado bajo GPL-3.0. Oruvi no incorpora ni adapta su código, recursos, iconos o bibliotecas: `NotchController.swift` es una implementación propia sobre AppKit/SwiftUI. No se presenta como una versión o derivado de Boring Notch ni se atribuye su funcionalidad completa.

## Spotify

La integración local utiliza el diccionario de automatización de Spotify desktop. No incorpora Spotify Web API, Spotify SDK, credenciales ni un reproductor de audio alternativo. El nombre identifica la aplicación controlada, no afiliación. Se mantiene una identificación del proveedor y acceso al reproductor en la interfaz.

Las carátulas se descargan solo de URLs de imágenes entregadas por la app y validadas mediante una lista de dominios. No se cambian por resultados de otro catálogo, se muestran sin recortar ni oscurecer y no se guardan en la caché persistente de Oruvi. No se distribuyen esas imágenes dentro del código ni del DMG. Esto no constituye una autorización de Spotify ni reemplaza la revisión de los derechos y condiciones aplicables antes de distribución comercial.

Referencia de diseño: https://developer.spotify.com/documentation/design

## Letras y portadas

El código puede consultar LRCLIB y, opcionalmente, el catálogo de Apple. Esto no transfiere derechos sobre letras, música ni imágenes. No se incluye contenido comercial de estos proveedores en el repositorio. La demostración utiliza texto original y un gráfico de sustitución creado por la aplicación.

La disponibilidad, las condiciones de uso y la autorización necesaria para distribuir contenido deben revisarse por separado antes de una explotación pública/comercial del producto.
