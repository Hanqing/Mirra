#!/bin/bash
# Renders the icon artwork with headless Chrome, then builds AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")"
python3 make_icon.py
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for v in full legacy; do
  "$CHROME" --headless --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size=1024,1024 \
    --screenshot="$PWD/preview_$v.png" "file://$PWD/preview_$v.html" >/dev/null 2>&1
done
SET=AppIcon.iconset
rm -rf "$SET"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s preview_legacy.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) preview_legacy.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$SET"
echo "Built AppIcon.icns"
cp layers/*.svg AppIcon.icon/Assets/
