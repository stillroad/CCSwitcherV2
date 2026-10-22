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
  CODE_SIGNING_ALLOWED=NO build

app_path="$PWD/build/DerivedData/Build/Products/Release/CCSwitcher.app"
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$PWD/build/CCSwitcher-Personal.zip"
echo "App: $app_path"
echo "ZIP: $PWD/build/CCSwitcher-Personal.zip"
