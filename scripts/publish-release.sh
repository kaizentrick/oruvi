#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
REPO="${ORUVI_REPOSITORY:?Repository is required}"
BUILD="${ORUVI_BUILD_NUMBER:?Build number is required}"
[[ "$REPO" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ && "$BUILD" =~ ^[0-9]{1,10}$ ]]
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION-b$BUILD"; NAME="Oruvi-$VERSION-arm64.dmg"; DMG="$ROOT/dist/$NAME"
[[ -s "$DMG" && -s dist/appcast.xml ]] || { echo 'Faltan el DMG o el feed firmado.'; exit 1; }
# The signed feed MUST retain the immutable, versioned URL. The stable alias is
# exclusively a convenient download for people; Sparkle never trusts the alias.
python3 -c 'import sys,xml.etree.ElementTree as E; r=E.parse(sys.argv[1]); e=r.find("./channel/item/enclosure"); assert e is not None and e.attrib["url"].endswith("/"+sys.argv[2])' dist/appcast.xml "$NAME"
WORK="$(mktemp -d "$ROOT/.build.publish.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
cp "$DMG" "$WORK/Oruvi.dmg"
cmp -s "$DMG" "$WORK/Oruvi.dmg"
DIGEST="$(shasum -a 256 "$DMG" | awk '{print $1}')"
printf '%s  %s\n%s  Oruvi.dmg\n' "$DIGEST" "$NAME" "$DIGEST" > "$WORK/SHA256SUMS.txt"
{
  printf '## Descargar Oruvi\n\n'
  printf '**[Descargar Oruvi.dmg](https://github.com/%s/releases/download/%s/Oruvi.dmg)**\n\n' "$REPO" "$TAG"
  printf 'Apple Silicon (M1 o posterior) · macOS 26 o posterior. No requiere Xcode ni descargar el código fuente.\n\n'
  printf '1. Abre **Oruvi.dmg** y arrastra **Oruvi.app** a **Applications**.\n'
  printf '2. Abre Oruvi desde Aplicaciones. El panel notch aparece en el escritorio.\n'
  printf '3. Abre Apple Music o Spotify en este Mac y permite la Automatización solicitada.\n'
  printf '4. Activa Standby desde el notch o deja transcurrir el intervalo de inactividad.\n\n'
  printf '### En esta versión\nNotch persistente, Apple Music y Spotify, nueva malla Aurora y transición de colores por canción. Cuando falta la letra, el disco permanece centrado y el botón muestra un aviso temporal.\n\n'
  if [[ "${ORUVI_NOTARIZED:-0}" == 1 ]]; then
    printf 'Distribución firmada con Developer ID y notarizada.\n\n'
  else
    printf '**Compilación sin notarización de Apple.** macOS puede bloquear el primer inicio. Revisa el origen y autoriza únicamente esta app desde Ajustes del Sistema → Privacidad y seguridad → Abrir igualmente. No desactives Gatekeeper ni SIP.\n\n'
  fi
  printf 'La firma Ed25519 protege las actualizaciones; no sustituye la notarización de Apple. Las letras son de LRCLIB o archivos locales, no están disponibles para todas las canciones.\n\n'
  printf 'Los archivos «Source code» que añade GitHub son para desarrolladores. Para instalar usa **Oruvi.dmg**. La imagen con número de versión contiene exactamente la misma app.\n\n'
  printf 'Versión %s · compilación %s.\n' "$VERSION" "$BUILD"
} > "$WORK/NOTES.md"
# A draft prevents the stable download and update feed from exposing a partial release.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then echo 'Esta versión ya existe; no se sobrescribe.'; exit 1; fi
gh release create "$TAG" --repo "$REPO" --target "${GITHUB_SHA:-main}" --draft \
    --title "Oruvi $VERSION" --notes-file "$WORK/NOTES.md"
gh release upload "$TAG" "$DMG" "$WORK/Oruvi.dmg" "$WORK/SHA256SUMS.txt" dist/appcast.xml --repo "$REPO"
# Refuse to mark Latest unless all four assets are uploaded.
COUNT="$(gh api "repos/$REPO/releases/tags/$TAG" --jq '[.assets[] | select(.state == "uploaded")] | length')"
[[ "$COUNT" == 4 ]] || { echo 'La release permanece en borrador: faltan archivos completos.'; exit 1; }
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
printf 'Descarga estable: https://github.com/%s/releases/latest/download/Oruvi.dmg\n' "$REPO"
