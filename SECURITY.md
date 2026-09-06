# Seguridad de la publicación

La clave privada de actualizaciones permanece en `.private/sparkle.key` y en el secreto de Actions `ORUVI_SPARKLE_PRIVATE_KEY` cuando el propietario ejecuta el script de publicación. No se añade al código, al DMG, a los logs ni a un asset de la release.

La clave pública de confianza está incorporada en la aplicación. El repositorio no puede sustituirla durante una consulta. Sparkle verifica el feed firmado y el archivo de actualización antes de extraerlo. El build comprueba además que la clave pública del producto valida la firma del DMG.

Solo un push en main o una ejecución manual de su workflow publica. No se deben habilitar secretos en workflows de pull requests ni usar pull_request_target para ejecutar código propuesto por terceros. Revisa cambios en scripts y workflows antes de fusionarlos. Limita quién puede escribir en main y quién puede administrar Actions/secrets.

Las dependencias binarias se descargan desde un release oficial fijo y se comprueba su SHA-256 antes de extraerlas. Las actualizaciones se suben como borrador y no se marcan públicas hasta que ambos archivos estén disponibles.

La firma Ed25519 no equivale a una notarización Apple. Configura Developer ID y notarización antes de presentar una distribución como verificada por Apple. La variante ad hoc es una compilación de desarrollo y no modifica la seguridad global de macOS.

No publiques reportes que contengan claves privadas, credenciales, archivos de preferencias personales o letras comerciales. Ante una sospecha de exposición de la clave, detén el workflow y planifica la rotación con las reglas de Sparkle; no reemplaces únicamente la clave pública.
