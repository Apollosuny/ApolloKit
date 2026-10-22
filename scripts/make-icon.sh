#!/bin/zsh
# Builds Support/AppIcon.icns from the PNG renders in Support/Icon.
# Sizes the designer delivered are used as-is; 256 px is downscaled from 512.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Support/Icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

cp "$SOURCE/AppIcon-16.png" "$ICONSET/icon_16x16.png"
cp "$SOURCE/AppIcon-32.png" "$ICONSET/icon_16x16@2x.png"
cp "$SOURCE/AppIcon-32.png" "$ICONSET/icon_32x32.png"
cp "$SOURCE/AppIcon-64.png" "$ICONSET/icon_32x32@2x.png"
cp "$SOURCE/AppIcon-128.png" "$ICONSET/icon_128x128.png"
sips -z 256 256 "$SOURCE/AppIcon-512.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
cp "$ICONSET/icon_128x128@2x.png" "$ICONSET/icon_256x256.png"
cp "$SOURCE/AppIcon-512.png" "$ICONSET/icon_256x256@2x.png"
cp "$SOURCE/AppIcon-512.png" "$ICONSET/icon_512x512.png"
cp "$SOURCE/AppIcon-1024.png" "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ROOT/Support/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"
echo "Wrote $ROOT/Support/AppIcon.icns"
