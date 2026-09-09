#!/bin/bash
set -euo pipefail
# A disposable GitHub runner only. Never invoke registry tools on the user's Mac.
[[ "${GITHUB_ACTIONS:-false}" == true ]] || { echo 'Registry verification is CI-only.'; exit 1; }
APP="${1:?application bundle}"
EXTENSION="$APP/Contents/PlugIns/OruviWidgets.appex"
LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
"$LSREGISTER" -f "$APP"
/usr/bin/pluginkit -a "$EXTENSION"
REGISTERED=0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if /usr/bin/pluginkit -m -A -D -v -i com.kaizentrick.Oruvi.Widgets | grep -F "$EXTENSION"; then REGISTERED=1; break; fi
    sleep 1
done
/usr/bin/pluginkit -r "$EXTENSION" || true
[[ "$REGISTERED" == 1 ]] || { echo 'Widget extension was not registered by macOS.'; exit 1; }
echo 'PASS: macOS PlugInKit recognizes the embedded WidgetKit extension in this runner.'
echo 'Registration is not a claim of interactive gallery verification on every Mac.'
