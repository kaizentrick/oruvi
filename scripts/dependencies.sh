#!/bin/bash
set -euo pipefail
# Pinned upstream release, never "latest"; verified before unpacking or running any tools.
VERSION=2.9.4
SHA256=ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9
DEST="${1:?Usage: bash scripts/dependencies.sh BUILD_DIRECTORY}"
mkdir -p "$DEST"
ARCHIVE="$DEST/Sparkle-$VERSION.tar.xz"
if [[ ! -s "$ARCHIVE" ]]; then
  curl --fail --location --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 20 --max-time 180 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$ARCHIVE"
fi
ACTUAL="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
[[ "$ACTUAL" == "$SHA256" ]] || { echo 'Sparkle checksum mismatch; build stopped.' >&2; exit 1; }
if [[ ! -d "$DEST/Sparkle.framework" ]]; then tar -xJf "$ARCHIVE" -C "$DEST"; fi
[[ -d "$DEST/Sparkle.framework" && -x "$DEST/bin/sign_update" && -x "$DEST/bin/generate_appcast" ]]
printf '%s\n' "$DEST"
