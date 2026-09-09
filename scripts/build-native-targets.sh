#!/bin/bash
set -euo pipefail
BUILD="${1:?build directory}"; DEPS="${2:?dependencies}"; VERSION="${3:?version}"; NUMBER="${4:?build number}"
PROJECT="$(python3 scripts/generate-native-project.py "$BUILD" "$DEPS" "$VERSION" "$NUMBER")"
xcodebuild -project "$PROJECT" -target Oruvi -configuration Release -sdk macosx \
  -jobs 2 SYMROOT="$BUILD/xcode-products" OBJROOT="$BUILD/xcode-intermediates" \
  CODE_SIGNING_ALLOWED=NO build
NATIVE="$BUILD/xcode-products/Release/Oruvi.app"
[[ -s "$NATIVE/Contents/MacOS/Oruvi" ]]
[[ -s "$NATIVE/Contents/PlugIns/OruviWidgets.appex/Contents/MacOS/OruviWidgets" ]]
# Both targets must include generated intent metadata; otherwise buttons cannot
# dispatch to the host even though SwiftUI compiles and the preview renders.
[[ -s "$NATIVE/Contents/Resources/Metadata.appintents/extract.actionsdata" ]]
[[ -s "$NATIVE/Contents/PlugIns/OruviWidgets.appex/Contents/Resources/Metadata.appintents/extract.actionsdata" ]]
ditto "$NATIVE" "$BUILD/stage/Oruvi.app"
