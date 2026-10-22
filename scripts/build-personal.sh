#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
elif [ -x /opt/homebrew/bin/xcodegen ]; then
  /opt/homebrew/bin/xcodegen generate
else
  echo "Install XcodeGen first: brew install xcodegen" >&2
  exit 1
fi

xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher \
  -configuration Release -derivedDataPath build/DerivedData \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build

app_path="$PWD/build/DerivedData/Build/Products/Release/CCSwitcher.app"
# Sign inside out. The widget needs its sandbox/group entitlements preserved;
# applying --deep only to the outer app silently omits them on an unsigned build.
codesign --force --deep --sign - "$app_path/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --entitlements CCSwitcherWidget/Resources/CCSwitcherWidget.entitlements \
  "$app_path/Contents/Extensions/CCSwitcherWidgetExtension.appex"
codesign --force --sign - --entitlements CCSwitcher/Resources/CCSwitcher.entitlements "$app_path"
codesign --verify --deep --strict "$app_path"
for binary in "$app_path/Contents/MacOS/CCSwitcher" \
  "$app_path/Contents/Extensions/CCSwitcherWidgetExtension.appex/Contents/MacOS/CCSwitcherWidgetExtension"; do
  architectures=$(lipo -archs "$binary")
  for architecture in arm64 x86_64; do
    case " $architectures " in
      *" $architecture "*) ;;
      *) echo "Missing $architecture in $binary" >&2; exit 1 ;;
    esac
  done
done
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$PWD/build/CCSwitcher-Personal.zip"
echo "App: $app_path"
echo "ZIP: $PWD/build/CCSwitcher-Personal.zip"
