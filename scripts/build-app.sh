#!/bin/bash
# Builds build/DisplayCam.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/DisplayCam.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DisplayCam "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/scrcpy-server Resources/LICENSE-scrcpy "$APP/Contents/Resources/"

# Icon: the .icns works everywhere; the Icon Composer document adds the macOS 26
# Liquid Glass version when Xcode's actool is available.
cp design/icon/AppIcon.icns "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
XCODE_DEV=/Applications/Xcode.app/Contents/Developer
if [ -d "$XCODE_DEV" ] && DEVELOPER_DIR="$XCODE_DEV" xcrun actool --version >/dev/null 2>&1; then
  DEVELOPER_DIR="$XCODE_DEV" xcrun actool design/icon/AppIcon.icon \
    --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon --output-partial-info-plist build/icon-partial.plist \
    --output-format human-readable-text >/dev/null && echo "Liquid Glass icon compiled"
else
  echo "note: actool unavailable (accept the Xcode license with 'sudo xcodebuild -license accept'); using AppIcon.icns only"
fi

codesign --force --sign - "$APP"
echo "Built $APP"
