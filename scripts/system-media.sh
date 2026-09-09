#!/bin/bash
set -euo pipefail
# Compile a reviewed, immutable upstream revision. No runtime dependency download.
PIN=73f14ab1568371e6e3c44063f21c34c5e2712c4d
DEST="${1:?Usage: bash scripts/system-media.sh BUILD_DEPS}"
SOURCE="$DEST/mediaremote-source"
mkdir -p "$DEST"
git init -q "$SOURCE"
git -C "$SOURCE" remote add origin https://github.com/ungive/mediaremote-adapter.git
git -C "$SOURCE" -c credential.helper= -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 fetch --depth 1 origin "$PIN"
git -C "$SOURCE" -c advice.detachedHead=false checkout -q --detach FETCH_HEAD
[[ "$(git -C "$SOURCE" rev-parse HEAD)" == "$PIN" ]] || { echo 'MediaRemote source revision mismatch.' >&2; exit 1; }
cmake -S "$SOURCE" -B "$DEST/mediaremote-build" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
cmake --build "$DEST/mediaremote-build" --config Release --target MediaRemoteAdapter --parallel 2
# The upstream test player is intentionally neither built nor executed.
ditto "$DEST/mediaremote-build/MediaRemoteAdapter.framework" "$DEST/MediaRemoteAdapter.framework"
cp "$SOURCE/bin/mediaremote-adapter.pl" "$DEST/mediaremote-adapter.pl"
cp "$SOURCE/LICENSE" "$DEST/MediaRemoteAdapter-LICENSE.txt"
[[ -s "$DEST/MediaRemoteAdapter.framework/MediaRemoteAdapter" && -s "$DEST/mediaremote-adapter.pl" && -s "$DEST/MediaRemoteAdapter-LICENSE.txt" ]]
