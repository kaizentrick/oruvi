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
xcrun swiftc -O -whole-module-optimization -warnings-as-errors -swift-version 5 -parse-as-library \
    Sources/NotchInteraction.swift scripts/verify-notch-interaction.swift -o "$WORK/verify-notch-input"
"$WORK/verify-notch-input"
python3 - <<'PY'
import pathlib
import plistlib
info = plistlib.loads(pathlib.Path('Resources/Info.plist').read_bytes())
entitlements = plistlib.loads(pathlib.Path('Resources/Entitlements.plist').read_bytes())
if not info.get('NSCalendarsFullAccessUsageDescription', '').strip():
    raise SystemExit('Calendar access requires a visible purpose string.')
if entitlements.get('com.apple.security.personal-information.calendars') is not True:
    raise SystemExit('Calendar resource entitlement missing for hardened builds.')
print('Calendar privacy configuration passed: purpose string and resource entitlement.')
PY
for script in scripts/*.sh; do bash -n "$script"; done
python3 scripts/audit-source.py
