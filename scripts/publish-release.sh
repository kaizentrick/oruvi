#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
REPO="${ORUVI_REPOSITORY:?Repository is required}"
BUILD="${ORUVI_BUILD_NUMBER:?Build number is required}"
[[ "$REPO" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ && "$BUILD" =~ ^[0-9]{1,10}$ ]]
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION-b$BUILD"
DMG="dist/Oruvi-$VERSION-arm64.dmg"
[[ -s "$DMG" && -s dist/appcast.xml ]] || { echo 'Faltan el DMG o el feed firmado.'; exit 1; }
# Only complete, signed builds reach this script. A draft prevents clients seeing partial uploads.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then echo 'La versión ya existe; no se sobrescribe.'; exit 1; fi
gh release create "$TAG" --repo "$REPO" --target "${GITHUB_SHA:-main}" --draft \
    --title "Oruvi $VERSION · compilación $BUILD" \
    --notes "Compilación de main para Apple Silicon y macOS 26. Actualización verificada con Ed25519. La firma Developer ID y notarización dependen de la configuración del mantenedor."
gh release upload "$TAG" "$DMG" dist/appcast.xml --repo "$REPO"
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
printf 'Versión publicada y completa: %s\n' "$TAG"
