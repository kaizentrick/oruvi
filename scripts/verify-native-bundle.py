#!/usr/bin/env python3
"""Inspect the real app and embedded extension, both before and inside the DMG."""
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
extension = app/'Contents/PlugIns/OruviWidgets.appex'
def info(bundle): return plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
host, widget = info(app), info(extension)
assert host['CFBundleIdentifier'] == 'com.kaizentrick.Oruvi'
assert widget['CFBundleIdentifier'] == 'com.kaizentrick.Oruvi.Widgets'
assert widget['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
assert widget['CFBundlePackageType'] == 'XPC!'
assert 'NSExtensionPrincipalClass' not in widget['NSExtension']
assert host['CFBundleVersion'] == widget['CFBundleVersion']
assert host['CFBundleShortVersionString'] == widget['CFBundleShortVersionString']
assert any('oruvi' in entry.get('CFBundleURLSchemes',[]) for entry in host['CFBundleURLTypes'])
assert host['OruviWidgetAppGroup'] == widget['OruviWidgetAppGroup']
for bundle, executable in [(app,'Oruvi'),(extension,'OruviWidgets')]:
    binary = bundle/'Contents/MacOS'/executable
    assert binary.is_file() and binary.stat().st_size > 0
    arches = subprocess.check_output(['lipo','-archs',str(binary)],text=True).strip()
    assert arches == 'arm64', 'Unexpected architecture: '+arches
    metadata = bundle/'Contents/Resources/Metadata.appintents/extract.actionsdata'
    assert metadata.is_file() and metadata.stat().st_size > 0, 'Missing App Intents metadata'
    assert b'OruviWidgetPlaybackIntent' in metadata.read_bytes(), 'Playback intent not indexed'
    subprocess.run(['codesign','--verify','--strict',str(bundle)],check=True)
    raw = subprocess.check_output(['codesign','-d','--entitlements',':-',str(bundle)],stderr=subprocess.DEVNULL)
    ent = plistlib.loads(raw)
    assert 'group.com.kaizentrick.Oruvi' in ent['com.apple.security.application-groups']
    if bundle == extension:
        assert ent['com.apple.security.app-sandbox'] is True
        for disallowed in ['com.apple.security.network.client','com.apple.security.network.server','com.apple.security.automation.apple-events','com.apple.security.device.camera','com.apple.security.device.audio-input']:
            assert not ent.get(disallowed), 'Unneeded extension privilege: '+disallowed
        linked = subprocess.check_output(['otool','-L',str(binary)],text=True)
        assert 'Sparkle' not in linked and 'MediaRemoteAdapter' not in linked and 'ScriptingBridge' not in linked
print('PASS: native WidgetKit bundle, shared entitlements, App Intents, versions, arm64 and signatures.')
