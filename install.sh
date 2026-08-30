#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/VEN OBS Utils.app"

if [[ ! -d "$APP" ]]; then
  "$ROOT/build_app.sh"
fi

echo "Installing to /Applications/VEN OBS Utils.app"
rm -rf "/Applications/VEN OBS Utils.app"
cp -R "$APP" "/Applications/VEN OBS Utils.app"
open "/Applications/VEN OBS Utils.app"
echo "Installed and launched."
