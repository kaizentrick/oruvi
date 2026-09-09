#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-false}" == true ]] || { echo 'Cross-process check runs only on GitHub CI.'; exit 1; }
WORK="$(mktemp -d)"; export WORK
trap 'rm -rf -- "$WORK"' EXIT
xcrun swiftc -O -warnings-as-errors -swift-version 5 -parse-as-library Sources/WidgetShared/WidgetSnapshot.swift scripts/verify-widget-store-process.swift -o "$WORK/Probe"
python3 - <<'PY'
import os, pathlib, plistlib, shutil, subprocess, uuid
root = pathlib.Path(os.environ['WORK'])
group = 'group.com.kaizentrick.Oruvi.CI' + uuid.uuid4().hex
apps = {}
for name in ['Host', 'Reader']:
    app = root/(name+'.app'); (app/'Contents/MacOS').mkdir(parents=True)
    shutil.copy(root/'Probe',app/'Contents/MacOS/Probe')
    info = {'CFBundleIdentifier':'com.kaizentrick.Oruvi.CI.'+name,'CFBundleName':name,'CFBundleExecutable':'Probe','CFBundlePackageType':'APPL','CFBundleVersion':'1','OruviWidgetAppGroup':group}
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    ent = {'com.apple.security.application-groups':[group]}
    if name == 'Reader': ent['com.apple.security.app-sandbox'] = True
    path = root/(name+'.plist'); path.write_bytes(plistlib.dumps(ent))
    subprocess.run(['codesign','--force','--sign','-','--entitlements',str(path),str(app)],check=True)
    apps[name] = str(app/'Contents/MacOS/Probe')
try:
    subprocess.run([apps['Host'],'write'],check=True,timeout=15)
    subprocess.run([apps['Reader'],'read'],check=True,timeout=15)
finally:
    subprocess.run([apps['Host'],'clear'],check=True,timeout=15)
print('Cross-process serialization validated; CI security policy is not a substitute for user-device App Group authorization.')
PY
