#!/usr/bin/env python3
"""Create deterministic Xcode targets in the ephemeral build directory.
Xcode, not a hand-built executable, owns extension linking and App Intents metadata.
No Xcode project/user state is written to the checkout or to a personal machine.
"""
import hashlib
import pathlib
import plistlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
build = pathlib.Path(sys.argv[1]).resolve()
deps = pathlib.Path(sys.argv[2]).resolve()
version, number = sys.argv[3:5]
objects = {}
def oid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def obj(name, **values):
    key = oid(name); objects[key] = values; return key

def source(path):
    return obj('file:' + path, isa='PBXFileReference', lastKnownFileType='sourcecode.swift' if path.endswith('.swift') else 'sourcecode.c.objc', path=str(root/path), sourceTree='<absolute>')
def phase(name, files):
    entries = [obj(name+':'+p, isa='PBXBuildFile', fileRef=source(p)) for p in files]
    return obj(name, isa='PBXSourcesBuildPhase', buildActionMask=2147483647, files=entries, runOnlyForDeploymentPostprocessing=0)

host = sorted(str(p.relative_to(root)) for p in (root/'Sources').glob('*.swift') if p.name != 'LumaQA.swift')
shared = sorted(str(p.relative_to(root)) for p in (root/'Sources/WidgetShared').glob('*.swift'))
widget = sorted(str(p.relative_to(root)) for p in (root/'Sources/Widgets').glob('*.swift')) + shared
host += shared + ['Sources/MusicBridge.m', 'Sources/SpotifyBridge.m']
common = dict(SDKROOT='macosx', MACOSX_DEPLOYMENT_TARGET='26.0', ARCHS='arm64', ONLY_ACTIVE_ARCH='YES', SWIFT_VERSION='5.0', SWIFT_COMPILATION_MODE='wholemodule', SWIFT_OPTIMIZATION_LEVEL='-O', SWIFT_TREAT_WARNINGS_AS_ERRORS='YES', CLANG_ENABLE_MODULES='YES', CLANG_ENABLE_OBJC_ARC='YES', CODE_SIGNING_ALLOWED='NO', GENERATE_INFOPLIST_FILE='NO', CURRENT_PROJECT_VERSION=number, MARKETING_VERSION=version, SWIFT_EMIT_LOC_STRINGS='YES', ENABLE_HARDENED_RUNTIME='NO', ENABLE_USER_SCRIPT_SANDBOXING='YES', DEBUG_INFORMATION_FORMAT='dwarf-with-dsym', DEAD_CODE_STRIPPING='YES')

def config(name, **extra):
    values = dict(common); values.update(extra)
    release = obj(name+':release', isa='XCBuildConfiguration', name='Release', buildSettings=values)
    return obj(name+':configs', isa='XCConfigurationList', buildConfigurations=[release], defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

app_product = obj('app-product', isa='PBXFileReference', explicitFileType='wrapper.application', path='Oruvi.app', sourceTree='BUILT_PRODUCTS_DIR')
widget_product = obj('widget-product', isa='PBXFileReference', explicitFileType='wrapper.app-extension', path='OruviWidgets.appex', sourceTree='BUILT_PRODUCTS_DIR')
widget_target = obj('widget-target', isa='PBXNativeTarget', name='OruviWidgets', productName='OruviWidgets', productType='com.apple.product-type.app-extension', productReference=widget_product,
    buildConfigurationList=config('widget', PRODUCT_BUNDLE_IDENTIFIER='com.kaizentrick.Oruvi.Widgets', PRODUCT_NAME='OruviWidgets', PRODUCT_MODULE_NAME='OruviWidgets', INFOPLIST_FILE=str(root/'Resources/Widgets/Info.plist'), APPLICATION_EXTENSION_API_ONLY='YES', SKIP_INSTALL='YES', SWIFT_ACTIVE_COMPILATION_CONDITIONS='ORUVI_WIDGET_EXTENSION', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks', '@executable_path/../../../../Frameworks']), buildPhases=[phase('widget-sources', widget)], buildRules=[], dependencies=[])
embed_file = obj('embed-widget-file', isa='PBXBuildFile', fileRef=widget_product, settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
embed_phase = obj('embed-widget', isa='PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='', dstSubfolderSpec=13, name='Embed App Extensions', files=[embed_file], runOnlyForDeploymentPostprocessing=0)
proxy = obj('widget-proxy', isa='PBXContainerItemProxy', containerPortal=oid('project'), proxyType=1, remoteGlobalIDString=widget_target, remoteInfo='OruviWidgets')
dependency = obj('widget-dependency', isa='PBXTargetDependency', target=widget_target, targetProxy=proxy)
frameworks = ['SwiftUI','AppKit','ScriptingBridge','IOKit','ImageIO','CoreText','CoreAudio','EventKit','Sparkle','WidgetKit','AppIntents']
ldflags = [flag for name in frameworks for flag in ['-framework', name]]
app_target = obj('app-target', isa='PBXNativeTarget', name='Oruvi', productName='Oruvi', productType='com.apple.product-type.application', productReference=app_product,
    buildConfigurationList=config('app', PRODUCT_BUNDLE_IDENTIFIER='com.kaizentrick.Oruvi', PRODUCT_NAME='Oruvi', PRODUCT_MODULE_NAME='Oruvi', INFOPLIST_FILE=str(root/'Resources/Info.plist'), SWIFT_OBJC_BRIDGING_HEADER=str(root/'Sources/MusicBridge.h'), FRAMEWORK_SEARCH_PATHS=[str(deps)], OTHER_LDFLAGS=ldflags, LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks']), buildPhases=[phase('app-sources', host), embed_phase], buildRules=[], dependencies=[dependency])
products = obj('products', isa='PBXGroup', name='Products', children=[app_product,widget_product], sourceTree='<group>')
files = [key for key,value in objects.items() if value.get('isa')=='PBXFileReference' and key not in [app_product,widget_product]]
group = obj('root-group', isa='PBXGroup', children=files+[products], sourceTree='<group>')
project = obj('project', isa='PBXProject', attributes={'LastUpgradeCheck':'2600'}, buildConfigurationList=config('project'), compatibilityVersion='Xcode 14.0', developmentRegion='es', knownRegions=['es','en','Base'], mainGroup=group, productRefGroup=products, projectDirPath='', projectRoot='', targets=[app_target,widget_target])
output = build/'OruviNative.xcodeproj'; output.mkdir(parents=True, exist_ok=True)
(output/'project.pbxproj').write_bytes(plistlib.dumps({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project},sort_keys=False))
print(output)
