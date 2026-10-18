#!/bin/bash
set -euo pipefail
# Compile a reviewed, immutable upstream revision. No runtime dependency download.
PIN=73f14ab1568371e6e3c44063f21c34c5e2712c4d
DEST="${1:?Usage: bash scripts/system-media.sh BUILD_DEPS}"
SOURCE="$DEST/mediaremote-source"
mkdir -p "$DEST"
if [[ "$(git -C "$SOURCE" rev-parse HEAD 2>/dev/null || true)" != "$PIN" ]]; then
    rm -rf -- "$SOURCE"
    git init -q "$SOURCE"
    git -C "$SOURCE" remote add origin https://github.com/ungive/mediaremote-adapter.git
    git -C "$SOURCE" -c credential.helper= -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 fetch --depth 1 origin "$PIN"
    git -C "$SOURCE" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
fi
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$PIN" ]] || { echo 'MediaRemote source revision mismatch.' >&2; exit 1; }
SDK="$(xcrun --sdk macosx --show-sdk-path)"
if command -v cmake >/dev/null 2>&1; then
    cmake -S "$SOURCE" -B "$DEST/mediaremote-build" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
    cmake --build "$DEST/mediaremote-build" --config Release --target MediaRemoteAdapter --parallel 2
    # The upstream test player is intentionally neither built nor executed.
    ditto "$DEST/mediaremote-build/MediaRemoteAdapter.framework" "$DEST/MediaRemoteAdapter.framework"
else
    FMWK="$DEST/MediaRemoteAdapter.framework"
    rm -rf -- "$FMWK"
    mkdir -p "$FMWK/Versions/A/Headers" "$FMWK/Versions/A/Resources"
    xcrun clang -dynamiclib -fobjc-arc -fvisibility=default -O2 -arch arm64 -arch x86_64 \
        -isysroot "$SDK" -mmacosx-version-min=26.0 \
        -I "$SOURCE/include" -I "$SOURCE/src" \
        "$SOURCE"/src/adapter/*.m "$SOURCE"/src/private/*.m "$SOURCE"/src/utility/*.m \
        -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
        -install_name "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter" \
        -o "$FMWK/Versions/A/MediaRemoteAdapter"
    cp "$SOURCE/include/MediaRemoteAdapter.h" "$FMWK/Versions/A/Headers/MediaRemoteAdapter.h"
    cat > "$FMWK/Versions/A/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>English</string>
	<key>CFBundleExecutable</key>
	<string>MediaRemoteAdapter</string>
	<key>CFBundleIconFile</key>
	<string></string>
	<key>CFBundleIdentifier</key>
	<string>com.vandenbe.MediaRemoteAdapter</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>MediaRemoteAdapter</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleSignature</key>
	<string>????</string>
	<key>CFBundleVersion</key>
	<string>0.1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CSResourcesFileMapped</key>
	<true/>
</dict>
</plist>
PLIST
    ln -s A "$FMWK/Versions/Current"
    ln -s Versions/Current/Headers "$FMWK/Headers"
    ln -s Versions/Current/Resources "$FMWK/Resources"
    ln -s Versions/Current/MediaRemoteAdapter "$FMWK/MediaRemoteAdapter"
    codesign --force --deep --sign - "$FMWK"
fi
cp "$SOURCE/bin/mediaremote-adapter.pl" "$DEST/mediaremote-adapter.pl"
cp "$SOURCE/LICENSE" "$DEST/MediaRemoteAdapter-LICENSE.txt"
[[ -s "$DEST/MediaRemoteAdapter.framework/MediaRemoteAdapter" && -s "$DEST/mediaremote-adapter.pl" && -s "$DEST/MediaRemoteAdapter-LICENSE.txt" ]]
