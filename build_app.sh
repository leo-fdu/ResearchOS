#!/bin/zsh
set -eu
cd "$(dirname "$0")"
ROOT="$PWD"
BUILD_ROOT="${RESEARCHOS_BUILD_ROOT:-$ROOT/.build-work}"
mkdir -p "$BUILD_ROOT/cache" "$BUILD_ROOT/modules"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/modules"
export SWIFT_MODULECACHE_PATH="$BUILD_ROOT/modules"
if [[ -d /Applications/Xcode.app ]]; then export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; fi
ARCH="$(uname -m)"
swift build --disable-sandbox --cache-path "$BUILD_ROOT/cache" --scratch-path "$BUILD_ROOT/spm" -c release --triple "$ARCH-apple-macosx14.0"
BIN="$(swift build --disable-sandbox --cache-path "$BUILD_ROOT/cache" --scratch-path "$BUILD_ROOT/spm" -c release --triple "$ARCH-apple-macosx14.0" --show-bin-path)"
APP="${RESEARCHOS_APP_OUTPUT:-$ROOT/../Research OS 2.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns/ResearchWidget.appex/Contents/MacOS"
cp "$BIN/PDFChat" "$APP/Contents/MacOS/ResearchOS"
cp -R "$BIN/PDFChat_PDFChat.bundle" "$APP/Contents/Resources/"
cp -R service "$APP/Contents/Resources/"
cp Resources/ResearchOSBlue.icns "$APP/Contents/Resources/ResearchOSBlue.icns"
python3 - "$APP" <<'PY'
import plistlib,sys,pathlib,shutil
p=pathlib.Path(sys.argv[1])
for cache in (p/'Contents/Resources/service').rglob('__pycache__'):shutil.rmtree(cache)
base={'CFBundleName':'Research OS','CFBundleIdentifier':'com.niqi.researchos','CFBundleVersion':'217','CFBundleShortVersionString':'2.0.17','CFBundlePackageType':'APPL','CFBundleExecutable':'ResearchOS','CFBundleIconFile':'ResearchOSBlue','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en'],'LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True},'CFBundleURLTypes':[{'CFBundleURLName':'Research OS','CFBundleURLSchemes':['researchos']}],'CFBundleDocumentTypes':[{'CFBundleTypeName':'PDF','CFBundleTypeRole':'Viewer','LSHandlerRank':'Alternate','LSItemContentTypes':['com.adobe.pdf']} ]}
(p/'Contents/Info.plist').write_bytes(plistlib.dumps(base))
w={'CFBundleName':'ResearchWidget','CFBundleDisplayName':'Research OS','CFBundleIdentifier':'com.niqi.researchos.widget','CFBundleVersion':'217','CFBundleShortVersionString':'2.0.17','CFBundlePackageType':'XPC!','CFBundleExecutable':'ResearchWidget','LSMinimumSystemVersion':'14.0','NSExtension':{'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}}
(p/'Contents/PlugIns/ResearchWidget.appex/Contents/Info.plist').write_bytes(plistlib.dumps(w))
PY
xcrun swiftc -parse-as-library -application-extension -target "$ARCH-apple-macosx14.0" Widget/ResearchWidget.swift -o "$APP/Contents/PlugIns/ResearchWidget.appex/Contents/MacOS/ResearchWidget" -framework SwiftUI -framework WidgetKit
codesign --force --sign - --entitlements Widget/Widget.entitlements "$APP/Contents/PlugIns/ResearchWidget.appex"
codesign --force --sign - --entitlements Widget/App.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
