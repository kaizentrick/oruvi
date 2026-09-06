#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
WORK="$(mktemp -d "$ROOT/.build.verify.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
xcrun swiftc -O -whole-module-optimization -warnings-as-errors -swift-version 5 -parse-as-library \
    Sources/Core.swift Sources/PlaybackRecovery.swift Sources/Typography.swift Sources/UpdateConfiguration.swift scripts/verify.swift \
    -framework AppKit -framework SwiftUI -o "$WORK/verify"
"$WORK/verify"
xcrun swiftc -O -whole-module-optimization -warnings-as-errors -swift-version 5 -parse-as-library \
    Sources/NotchLayout.swift Sources/NotchTimerState.swift scripts/verify-notch.swift -o "$WORK/verify-notch"
"$WORK/verify-notch"
for script in scripts/*.sh; do bash -n "$script"; done
python3 scripts/audit-source.py
