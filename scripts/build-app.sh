#!/bin/bash
# Builds build/Mirra.app (release, ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN=$(swift build -c release --show-bin-path)
APP=build/Mirra.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Mirra" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/scrcpy-server Resources/LICENSE-scrcpy "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# Icon: the .icns works everywhere; the Icon Composer document adds the macOS 26
# Liquid Glass version when Xcode's actool is available.
cp design/icon/AppIcon.icns "$APP/Contents/Resources/"
XCODE_DEV=/Applications/Xcode.app/Contents/Developer
if [ -d "$XCODE_DEV" ] && DEVELOPER_DIR="$XCODE_DEV" xcrun actool --version >/dev/null 2>&1; then
  DEVELOPER_DIR="$XCODE_DEV" xcrun actool design/icon/AppIcon.icon \
    --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon --output-partial-info-plist build/icon-partial.plist \
    --output-format human-readable-text >/dev/null && echo "Liquid Glass icon compiled"
else
  echo "note: actool unavailable (accept the Xcode license with 'sudo xcodebuild -license accept'); using AppIcon.icns only"
fi

# Ad-hoc signature for the app and everything inside it (Sparkle's helpers included).
codesign --force --deep --sign - "$APP"
echo "Built $APP"
