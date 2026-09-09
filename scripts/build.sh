#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo 'Requiere macOS y Apple Silicon.'; exit 1; }
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
[[ "${SDK_VERSION%%.*}" -ge 26 ]] || { echo 'Requiere SDK macOS 26.'; exit 1; }
LOCK="$ROOT/.build.lock"
if [[ "${1:-}" == --clean ]]; then
    [[ ! -d "$LOCK" ]] || { echo 'Hay una compilación activa.'; exit 1; }
    CURRENT="$ROOT/dist/Oruvi-$VERSION-arm64.dmg"; [[ -s "$CURRENT" ]]
    hdiutil verify "$CURRENT"
    shopt -s nullglob
    for path in "$ROOT"/.build.*; do [[ -d "$path" && ! -L "$path" && "$path" != "$LOCK" ]] && rm -rf -- "$path"; done
    for file in "$ROOT/dist"/Oruvi-*.dmg "$ROOT/dist"/Luma-*.dmg "$ROOT/dist"/*.zip; do [[ "$file" == "$CURRENT" ]] || rm -f -- "$file"; done
    rm -f Sources/LumaQA.swift .DS_Store dist/.DS_Store
    echo 'Temporales eliminados; claves privadas, código y DMG vigente conservados.'; exit 0
fi
mkdir "$LOCK" 2>/dev/null || { echo 'Hay otra compilación o un bloqueo pendiente.'; exit 1; }
BUILD="${BUILD_DIRECTORY:-$(mktemp -d "$ROOT/.build.XXXXXX")}"
[[ "$BUILD" == "$ROOT"/.build.* && "$BUILD" != "$LOCK" && -d "$BUILD" && ! -L "$BUILD" ]] || { rmdir "$LOCK"; exit 1; }
exec 3>&1
cleanup() {
    result=$?
    if mount | grep -F " on $BUILD/mount " >/dev/null; then hdiutil detach "$BUILD/mount" || true; fi
    if [[ $result -ne 0 ]]; then printf '\nERROR %s. No se reemplazó el DMG anterior.\n' "$result" >&3; tail -90 "$BUILD/build.log" >&3 || true; fi
    if [[ "${KEEP_BUILD_ARTIFACTS:-0}" == 1 ]]; then printf 'Diagnóstico: %s\n' "$BUILD" >&3; else rm -rf -- "$BUILD"; fi
    rmdir "$LOCK" 2>/dev/null || true
    exit "$result"
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
printf 'Compilación Oruvi %s: %s\n' "$VERSION" "$BUILD" >&3
exec > "$BUILD/build.log" 2>&1
mkdir -p "$BUILD/tmp" "$ROOT/dist"; export TMPDIR="$BUILD/tmp/"
export ORUVI_BUILD_NUMBER="${ORUVI_BUILD_NUMBER:-$(date +%s)}"
[[ "$ORUVI_BUILD_NUMBER" =~ ^[0-9]{1,10}$ ]] || { echo 'Número de compilación no válido.'; exit 1; }
# An explicitly empty repository is for secret-free CI validation, never publication.
REPOSITORY="${ORUVI_REPOSITORY-kaizentrick/oruvi}"
if [[ -n "$REPOSITORY" ]]; then [[ "$REPOSITORY" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$ && "$REPOSITORY" != */.. && "$REPOSITORY" != */. ]] || exit 1; fi
[[ -s Resources/UpdatePublicKey.pub && -s Resources/OruviIcon.icns && -s LICENSE ]]
# Fail before expensive compilation if an upload is truncated, renamed or not the approved art.
python3 scripts/verify-icon.py --self-test >&3
xcrun swiftc -warnings-as-errors -swift-version 5 -parse-as-library Sources/ApplicationIcon.swift scripts/verify-icon.swift -framework AppKit -framework ImageIO -o "$BUILD/verify-icon"
iconutil -c iconset -o "$BUILD/source.iconset" Resources/OruviIcon.icns
"$BUILD/verify-icon" Resources/OruviIcon.png Resources/OruviIcon.icns "$BUILD/source.iconset" >&3
PUBLIC_KEY="$(tr -d '\r\n' < Resources/UpdatePublicKey.pub)"
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] || { echo 'Clave pública no válida.'; exit 1; }
DEPS="$BUILD/deps"; bash scripts/dependencies.sh "$DEPS"
bash scripts/system-media.sh "$DEPS"
SIGN_OPTIONS=(--timestamp=none)
if [[ "${SIGN_IDENTITY:--}" != - ]]; then SIGN_OPTIONS=(--options runtime --timestamp); fi
# Ad-hoc builds are not hardened. No system security setting is changed.
FRAMEWORKS=(-framework SwiftUI -framework AppKit -framework ScriptingBridge -framework IOKit -framework ImageIO -framework CoreText -framework CoreAudio -framework EventKit -framework Sparkle -framework WidgetKit -framework AppIntents)
BASE=(-j 1 -disable-bridging-pch -warnings-as-errors -swift-version 5 -parse-as-library -sdk "$SDK" -target arm64-apple-macos26.0 -import-objc-header Sources/MusicBridge.h -F "$DEPS" -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
printf '\n[1/5] Puente Apple Events\n'
xcrun clang -fobjc-arc -fmodules -O2 -arch arm64 -isysroot "$SDK" -mmacosx-version-min=26.0 -c Sources/MusicBridge.m -o "$BUILD/MusicBridge.o"
[[ -s "$BUILD/MusicBridge.o" ]]
xcrun clang -fobjc-arc -fmodules -O2 -arch arm64 -isysroot "$SDK" -mmacosx-version-min=26.0 -c Sources/SpotifyBridge.m -o "$BUILD/SpotifyBridge.o"
[[ -s "$BUILD/SpotifyBridge.o" ]]
xcrun libtool -static -o "$BUILD/libOruviPlayers.a" "$BUILD/MusicBridge.o" "$BUILD/SpotifyBridge.o"
[[ -s "$BUILD/libOruviPlayers.a" ]]
prepare_app() {
    local app="$1"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
    python3 - "$app/Contents/Info.plist" <<'PLIST'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
info = plistlib.loads(path.read_bytes()) if path.exists() else {}
info.update(plistlib.loads(pathlib.Path('Resources/Info.plist').read_bytes()))
path.write_bytes(plistlib.dumps(info, sort_keys=False))
PLIST
    cp Resources/OruviIcon.icns "$app/Contents/Resources/OruviIcon.icns"
    cp Resources/OruviIcon.json "$app/Contents/Resources/OruviIcon.json"
    cp LICENSE "$app/Contents/Resources/LICENSE.txt"
    cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/THIRD_PARTY_NOTICES.md"
    cp "$DEPS/LICENSE" "$app/Contents/Resources/Sparkle-LICENSE.txt"
    cp "$DEPS/mediaremote-adapter.pl" "$app/Contents/Resources/mediaremote-adapter.pl"
    cp "$DEPS/MediaRemoteAdapter-LICENSE.txt" "$app/Contents/Resources/MediaRemoteAdapter-LICENSE.txt"
    ditto "$DEPS/MediaRemoteAdapter.framework" "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
    codesign --force "${SIGN_OPTIONS[@]}" --sign "${SIGN_IDENTITY:--}" "$app/Contents/Frameworks/MediaRemoteAdapter.framework"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ORUVI_BUILD_NUMBER" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$app/Contents/Info.plist"
    if [[ -n "$REPOSITORY" ]]; then
        /usr/libexec/PlistBuddy -c "Add :OruviUpdateRepository string $REPOSITORY" "$app/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/$REPOSITORY/releases/latest/download/appcast.xml" "$app/Contents/Info.plist"
    fi
    ditto "$DEPS/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
    local framework="$app/Contents/Frameworks/Sparkle.framework"
    for helper in XPCServices/Downloader.xpc XPCServices/Installer.xpc Autoupdate Updater.app; do
        [[ ! -e "$framework/Versions/B/$helper" ]] || codesign --force --preserve-metadata=entitlements "${SIGN_OPTIONS[@]}" --sign "${SIGN_IDENTITY:--}" "$framework/Versions/B/$helper"
    done
    codesign --force "${SIGN_OPTIONS[@]}" --sign "${SIGN_IDENTITY:--}" "$framework"
}
ALL=(); RELEASE=(); MODEL_TEST=()
for source in Sources/*.swift Sources/WidgetShared/*.swift; do
    ALL+=("$source")
    if [[ "$source" != Sources/LumaQA.swift ]]; then
        RELEASE+=("$source")
        [[ "$source" == Sources/OruviApplication.swift ]] || MODEL_TEST+=("$source")
    fi
 done
printf '\n[2/5] Modelo de reproducción aislado\n'
xcrun swiftc "${BASE[@]}" -Onone -whole-module-optimization -D LUMA_QA "${MODEL_TEST[@]}" scripts/verify-surfaces.swift "$BUILD/libOruviPlayers.a" "${FRAMEWORKS[@]}" -o "$BUILD/verify-surfaces"
DYLD_FRAMEWORK_PATH="$DEPS" "$BUILD/verify-surfaces" --smoke-test >&3
if [[ -f Sources/LumaQA.swift && "${SKIP_VERIFICATION:-0}" != 1 ]]; then
    QA_APP="$BUILD/qa-app/Oruvi.app"; prepare_app "$QA_APP"
    xcrun swiftc "${BASE[@]}" -Onone -whole-module-optimization -D LUMA_QA "${ALL[@]}" "$BUILD/libOruviPlayers.a" "${FRAMEWORKS[@]}" -o "$QA_APP/Contents/MacOS/Oruvi"
    codesign --force "${SIGN_OPTIONS[@]}" --entitlements Resources/Entitlements.plist --sign "${SIGN_IDENTITY:--}" "$QA_APP"
    "$QA_APP/Contents/MacOS/Oruvi" --smoke-test --qa-output "$BUILD/qa"
fi
if [[ "${QA_ONLY:-0}" == 1 ]]; then echo 'Verificación terminada.' >&3; exit 0; fi
printf '\n[3/5] Aplicación optimizada\n'
bash scripts/build-native-targets.sh "$BUILD" "$DEPS" "$VERSION" "$ORUVI_BUILD_NUMBER"
APP="$BUILD/stage/Oruvi.app"; prepare_app "$APP"
EXTENSION="$APP/Contents/PlugIns/OruviWidgets.appex"
codesign --force "${SIGN_OPTIONS[@]}" --entitlements Resources/Widgets/Entitlements.plist --sign "${SIGN_IDENTITY:--}" "$EXTENSION"
[[ -s "$APP/Contents/MacOS/Oruvi" ]]
plutil -lint "$APP/Contents/Info.plist"
python3 scripts/verify-icon.py --app "$APP" >&3
codesign --force "${SIGN_OPTIONS[@]}" --entitlements Resources/Entitlements.plist --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
python3 scripts/verify-native-bundle.py "$APP" >&3
if [[ "${GITHUB_ACTIONS:-false}" == true ]]; then bash scripts/verify-widget-registration.sh "$APP" >&3; fi
printf '\n[4/5] DMG\n'
ln -sfn /Applications "$BUILD/stage/Applications"; cp Resources/LEEME.txt "$BUILD/stage/LEEME.txt"
cp LICENSE "$BUILD/stage/LICENSE.txt"
NAME="Oruvi-$VERSION-arm64.dmg"
DMG_VERIFIED=0
for attempt in 1 2 3; do
    if hdiutil create -volname "Oruvi $VERSION" -srcfolder "$BUILD/stage" -fs HFS+ -format UDZO -ov "$BUILD/$NAME"; then
        sync
        if hdiutil verify "$BUILD/$NAME"; then DMG_VERIFIED=1; break; fi
    fi
    printf 'DMG verification failed (attempt %s/3). Rebuilding the image.\n' "$attempt" >&3
    ls -lh "$BUILD/$NAME" || true
    file "$BUILD/$NAME" || true
    hdiutil imageinfo "$BUILD/$NAME" || true
    if [[ "$attempt" -lt 3 ]]; then sleep 2; fi
 done
[[ "$DMG_VERIFIED" == 1 ]] || { echo 'DMG verification failed. No artifact will be published.'; exit 1; }
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ "${SIGN_IDENTITY:--}" != - ]] || { echo 'Notarización requiere Developer ID.'; exit 1; }
    xcrun notarytool submit "$BUILD/$NAME" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$BUILD/$NAME"; xcrun stapler validate "$BUILD/$NAME"
fi
mkdir -p "$BUILD/mount"
hdiutil attach -readonly -nobrowse -mountpoint "$BUILD/mount" "$BUILD/$NAME"
codesign --verify --deep --strict "$BUILD/mount/Oruvi.app"
python3 scripts/verify-native-bundle.py "$BUILD/mount/Oruvi.app" >&3
cmp -s "$APP/Contents/MacOS/Oruvi" "$BUILD/mount/Oruvi.app/Contents/MacOS/Oruvi"
cmp -s LICENSE "$BUILD/mount/Oruvi.app/Contents/Resources/LICENSE.txt"
cmp -s LICENSE "$BUILD/mount/LICENSE.txt"
cmp -s "$DEPS/mediaremote-adapter.pl" "$BUILD/mount/Oruvi.app/Contents/Resources/mediaremote-adapter.pl"
[[ -s "$BUILD/mount/Oruvi.app/Contents/Resources/MediaRemoteAdapter-LICENSE.txt" ]]
codesign --verify --strict "$BUILD/mount/Oruvi.app/Contents/Frameworks/MediaRemoteAdapter.framework"
# Verify the actual read-only installer, not just a source preview or a nonempty file.
python3 scripts/verify-icon.py --app "$BUILD/mount/Oruvi.app" >&3
iconutil -c iconset -o "$BUILD/installer.iconset" "$BUILD/mount/Oruvi.app/Contents/Resources/OruviIcon.icns"
"$BUILD/verify-icon" Resources/OruviIcon.png "$BUILD/mount/Oruvi.app/Contents/Resources/OruviIcon.icns" "$BUILD/installer.iconset" "$BUILD/mount/Oruvi.app" >&3
hdiutil detach "$BUILD/mount"
# Updates require the maintainer key. Never publish a feed for an unsigned archive.
KEY_FILE="${ORUVI_KEY_FILE:-$ROOT/.private/sparkle.key}"
if [[ -n "${ORUVI_SPARKLE_PRIVATE_KEY:-}" ]]; then
    umask 077; KEY_FILE="$BUILD/signing.key"; printf '%s' "$ORUVI_SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
fi
if [[ -f "$KEY_FILE" ]]; then
    SIGNATURE="$("$DEPS/bin/sign_update" --ed-key-file "$KEY_FILE" -p "$BUILD/$NAME")"
    "$DEPS/bin/sign_update" --ed-key-file "$KEY_FILE" --verify "$BUILD/$NAME" "$SIGNATURE"
    xcrun swift scripts/verify-signature.swift Resources/UpdatePublicKey.pub "$BUILD/$NAME" "$SIGNATURE"
    if [[ -n "$REPOSITORY" ]]; then
        python3 scripts/appcast.py "$BUILD/$NAME" "$VERSION" "$ORUVI_BUILD_NUMBER" "$REPOSITORY" "$SIGNATURE" "$BUILD/appcast.xml"
        "$DEPS/bin/sign_update" --ed-key-file "$KEY_FILE" "$BUILD/appcast.xml"
        "$DEPS/bin/sign_update" --ed-key-file "$KEY_FILE" --verify "$BUILD/appcast.xml"
        cp "$BUILD/appcast.xml" "$ROOT/dist/appcast.xml"
    fi
elif [[ -n "$REPOSITORY" ]]; then echo 'Falta la clave de firma. No se publica esta compilación.'; exit 1; fi
mv -f "$BUILD/$NAME" "$ROOT/dist/$NAME"
printf '\n[5/5] Integridad\n'
shasum -a 256 "$ROOT/dist/$NAME"
printf 'DMG comprobado: %s/dist/%s\n' "$ROOT" "$NAME" >&3
printf 'Build: %s. La publicación en GitHub es un paso separado.\n' "$ORUVI_BUILD_NUMBER" >&3
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
        printf '## Icono de Oruvi verificado dentro del instalador\n\n'
        printf 'Versión %s · compilación %s. Diez representaciones nativas/Retina decodificadas, transparencia y píxeles del maestro comprobados. El cargador real resuelve el recurso del bundle montado.\n\n' "$VERSION" "$ORUVI_BUILD_NUMBER"
        printf 'ICNS SHA-256: `%s`\n' "$(shasum -a 256 Resources/OruviIcon.icns | awk '{print $1}')"
    } >> "$GITHUB_STEP_SUMMARY"
fi
