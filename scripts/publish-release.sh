#!/bin/bash
# Run inside GitHub Actions after scripts/build.sh. Uses the job's GITHUB_TOKEN.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
REPO="${ORUVI_REPOSITORY:?Repository is required}"
BUILD="${ORUVI_BUILD_NUMBER:?Build number is required}"
[[ "$REPO" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ && "$BUILD" =~ ^[0-9]{1,10}$ ]] || { echo 'Invalid repository or build number.'; exit 1; }
VERSION="$(python3 -c 'import plistlib; print(plistlib.load(open("Resources/Info.plist", "rb"))["CFBundleShortVersionString"])')"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version.'; exit 1; }
TAG="v$VERSION-b$BUILD"; NAME="Oruvi-$VERSION-arm64.dmg"; DMG="$ROOT/dist/$NAME"
[[ -s "$DMG" && -s dist/appcast.xml ]] || { echo 'Faltan el DMG o el feed firmado.'; exit 1; }
# Never edit the signed XML or point Sparkle to a mutable download alias.
python3 - "$REPO" "$TAG" "$BUILD" "$VERSION" "$DMG" <<'PY'
import base64, pathlib, sys, xml.etree.ElementTree as E
repo, tag, build, version, archive = sys.argv[1:]
p = pathlib.Path(archive)
root = E.parse('dist/appcast.xml').getroot()
item = root.find('./channel/item')
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
assert item is not None, 'Feed has no release item'
e = item.find('enclosure')
assert e is not None, 'Feed has no installer'
assert e.get('url') == f'https://github.com/{repo}/releases/download/{tag}/{p.name}', 'Wrong update URL'
assert item.findtext(ns + 'version') == build, 'Wrong update build'
assert item.findtext(ns + 'shortVersionString') == version, 'Wrong update version'
assert int(e.get('length', '-1')) == p.stat().st_size, 'Installer size differs from signed feed'
assert len(base64.b64decode(e.get(ns + 'edSignature', ''), validate=True)) == 64, 'Missing update signature'
PY
[[ "$(gh api "repos/$REPO" --jq '.private')" == false ]] || { echo 'This distribution requires a public repository.'; exit 1; }
WORK="$(mktemp -d "$ROOT/.build.publish.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
cp "$DMG" "$WORK/Oruvi.dmg"; cmp -s "$DMG" "$WORK/Oruvi.dmg"
DIGEST="$(shasum -a 256 "$DMG" | awk '{print $1}')"
printf '%s  %s\n%s  Oruvi.dmg\n' "$DIGEST" "$NAME" "$DIGEST" > "$WORK/SHA256SUMS.txt"
{
  printf '## Descargar Oruvi\n\n'
  printf '**[Descargar Oruvi.dmg](https://github.com/%s/releases/download/%s/Oruvi.dmg)**\n\n' "$REPO" "$TAG"
  printf 'Apple Silicon (M1 o posterior) y macOS 26 o posterior. No necesitas Git, Xcode ni una cuenta de GitHub para descargarla.\n\n'
  printf '1. Abre Oruvi.dmg y arrastra Oruvi.app a Applications.\n'
  printf '2. Expulsa el DMG y abre Oruvi desde Aplicaciones.\n'
  printf '3. Autoriza Automatización para el reproductor que utilices en este Mac.\n'
  printf '4. En Ajustes → Actualizaciones, deja activada la búsqueda automática. Las nuevas releases se verifican e instalan desde la propia app.\n\n'
  printf 'Incluye notch, Standby a pantalla completa, Apple Music, Spotify y letras sincronizadas cuando estén disponibles.\n\n'
  if [[ "${ORUVI_NOTARIZED:-0}" == 1 ]]; then
    printf 'Distribución firmada con Developer ID y notarizada.\n\n'
  else
    printf '**Sin notarización de Apple:** macOS puede bloquear el primer inicio. Revisa el origen y utiliza Privacidad y seguridad → Abrir igualmente solo si confías en esta app. No desactives Gatekeeper ni SIP.\n\n'
  fi
  printf 'Ed25519 verifica las actualizaciones; no sustituye la notarización. Para instalar utiliza Oruvi.dmg, no los archivos Source code.\n\n'
  printf 'Versión %s · compilación %s.\n' "$VERSION" "$BUILD"
} > "$WORK/NOTES.md"

# gh release view resolves drafts. GET /releases/tags/TAG only resolves published
# releases and was the cause of the previous failure after successful uploads.
if ! gh release view "$TAG" --repo "$REPO" --json databaseId,isDraft,tagName,targetCommitish > "$WORK/lookup.json" 2> "$WORK/lookup.err"; then
  if ! grep -Eiq 'not found|HTTP 404|release not found' "$WORK/lookup.err"; then
    cat "$WORK/lookup.err" >&2; exit 1
  fi
  gh release create "$TAG" --repo "$REPO" --target "${GITHUB_SHA:-main}" --draft \
    --title "Oruvi $VERSION" --notes-file "$WORK/NOTES.md"
  gh release view "$TAG" --repo "$REPO" --json databaseId,isDraft,tagName,targetCommitish > "$WORK/lookup.json"
fi
RELEASE_ID="$(jq -er '.databaseId' "$WORK/lookup.json")"
[[ "$RELEASE_ID" =~ ^[0-9]+$ ]] || { echo 'Missing numeric release ID.'; exit 1; }
WAS_DRAFT="$(jq -er '.isDraft | tostring' "$WORK/lookup.json")"
[[ "$(jq -r '.tagName' "$WORK/lookup.json")" == "$TAG" ]] || exit 1
if [[ -n "${GITHUB_SHA:-}" ]]; then
  [[ "$(jq -r '.targetCommitish' "$WORK/lookup.json")" == "$GITHUB_SHA" ]] || { echo 'Release belongs to another commit; not modified.'; exit 1; }
fi
if [[ "$WAS_DRAFT" == true ]]; then
  gh release upload "$TAG" "$DMG" "$WORK/Oruvi.dmg" "$WORK/SHA256SUMS.txt" dist/appcast.xml --repo "$REPO" --clobber
fi

verify_assets() {
  python3 - "$WORK/release.json" "$DMG" "$WORK/Oruvi.dmg" "$WORK/SHA256SUMS.txt" "$ROOT/dist/appcast.xml" <<'PY'
import hashlib, json, pathlib, sys
release = json.loads(pathlib.Path(sys.argv[1]).read_text())
for name in sys.argv[2:]:
    path = pathlib.Path(name)
    assets = [a for a in release.get('assets', []) if a.get('name') == path.name]
    assert len(assets) == 1, f'Missing or duplicate asset: {path.name}'
    asset = assets[0]
    assert asset.get('state') == 'uploaded', f'Incomplete asset: {path.name}'
    assert asset.get('size') == path.stat().st_size, f'Wrong size: {path.name}'
    digest = asset.get('digest')
    if digest:
        assert digest == 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest(), f'Wrong digest: {path.name}'
print('All four release assets verified by name, state, size and available SHA-256.')
PY
}
ASSETS_OK=0
for attempt in 1 2 3 4 5; do
  if gh api "repos/$REPO/releases/$RELEASE_ID" > "$WORK/release.json" && verify_assets; then ASSETS_OK=1; break; fi
  if [[ "$attempt" != 5 ]]; then sleep 2; fi
done
[[ "$ASSETS_OK" == 1 ]] || { echo 'Assets did not validate. Draft remains unpublished; previous Latest is untouched.'; exit 1; }
if [[ "$WAS_DRAFT" == true ]]; then
  gh api --method PATCH "repos/$REPO/releases/$RELEASE_ID" -F draft=false -F prerelease=false -f make_latest=true > "$WORK/published.json"
  jq -e '.draft == false and .prerelease == false' "$WORK/published.json" >/dev/null
else
  echo 'This release was already published; its immutable assets were not overwritten.'
fi

# Download as an anonymous user. curl --disable ignores any local curl credentials.
# Compare bytes, not just HEAD status, including the SIGNED feed used by Sparkle.
verify_public_file() {
  local url="$1" expected="$2"
  curl --disable --fail --silent --show-error --location --retry 5 --retry-delay 2 \
    --retry-all-errors --connect-timeout 15 --max-time 120 --proto '=https' --proto-redir '=https' \
    --output "$WORK/public-download" "$url"
  cmp -s "$expected" "$WORK/public-download" || { echo "Public download differs: $url"; return 1; }
}
for file in "$DMG" "$WORK/Oruvi.dmg" "$WORK/SHA256SUMS.txt" "$ROOT/dist/appcast.xml"; do
  verify_public_file "https://github.com/$REPO/releases/download/$TAG/$(basename "$file")" "$file"
done
LATEST="$(gh api "repos/$REPO/releases/latest" --jq '.id')"
if [[ "$LATEST" == "$RELEASE_ID" ]]; then
  verify_public_file "https://github.com/$REPO/releases/latest/download/Oruvi.dmg" "$DMG"
  verify_public_file "https://github.com/$REPO/releases/latest/download/appcast.xml" "$ROOT/dist/appcast.xml"
else
  echo 'A newer release is Latest. This verified older release was not promoted again.'
fi
printf '\nPublicación y descargas verificadas: https://github.com/%s/releases/tag/%s\n' "$REPO" "$TAG"
printf 'Descarga estable: https://github.com/%s/releases/latest/download/Oruvi.dmg\n' "$REPO"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    printf '## Oruvi %s publicada\n\n' "$VERSION"
    printf '[Descargar Oruvi.dmg](https://github.com/%s/releases/latest/download/Oruvi.dmg)\n\n' "$REPO"
    printf 'Se verificaron los cuatro assets y su descarga pública sin credenciales. El feed firmado y el DMG numerado conservan sus bytes originales.\n\n'
    printf 'SHA-256 del instalador: `%s`\n' "$DIGEST"
  } >> "$GITHUB_STEP_SUMMARY"
fi
