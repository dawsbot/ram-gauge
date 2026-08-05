#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/RAMGauge.app"
BINARY="$ROOT/.build/release/RAMGauge"

cd "$ROOT"
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BINARY" "$APP/Contents/MacOS/RAMGauge"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
rm -f "$ROOT/dist/RAMGauge-macos.zip"
cd "$ROOT/dist"
ditto -c -k --sequesterRsrc --keepParent RAMGauge.app RAMGauge-macos.zip
printf 'Built %s\n' "$APP"
