#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/dist/RAMGauge.app"

if [[ ! -d "$APP" ]]; then
  "$ROOT/scripts/build-app.sh"
fi

rm -rf /Applications/RAMGauge.app
cp -R "$APP" /Applications/RAMGauge.app
open /Applications/RAMGauge.app
printf 'Installed and launched RAM Gauge. Look for the percentage in the menu bar.\n'
