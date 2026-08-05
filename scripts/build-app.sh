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

SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Dawson Botsford (7M8FTZA845)}"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$ROOT/dist/RAMGauge-macos.zip"
cd "$ROOT/dist"
ditto -c -k --sequesterRsrc --keepParent RAMGauge.app RAMGauge-macos.zip

# Notarize + staple when credentials are stored (xcrun notarytool store-credentials notary)
if xcrun notarytool history --keychain-profile notary >/dev/null 2>&1; then
  xcrun notarytool submit RAMGauge-macos.zip --keychain-profile notary --wait
  xcrun stapler staple RAMGauge.app
  rm -f RAMGauge-macos.zip
  ditto -c -k --sequesterRsrc --keepParent RAMGauge.app RAMGauge-macos.zip
else
  printf 'Skipping notarization: no "notary" keychain profile found.\n'
fi
printf 'Built %s\n' "$APP"
