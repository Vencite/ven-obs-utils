#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="VEN OBS Utils"
EXECUTABLE="VENOBSUtils"
BUNDLE_ID="works.ven.obs-utils"
VERSION="${VERSION:-0.1.0}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "ERROR: xcrun not found. Install Apple Command Line Tools: xcode-select --install" >&2
  exit 1
fi

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/services"

xcrun --sdk macosx swiftc \
  -O \
  -sdk "$SDK_PATH" \
  -framework AppKit \
  -framework Foundation \
  "$ROOT/app/Sources/main.swift" \
  -o "$CONTENTS/MacOS/$EXECUTABLE"

cp "$ROOT/services/ontime_break_sync.py" "$CONTENTS/Resources/services/ontime_break_sync.py"
cp "$ROOT/config/config.example.json" "$CONTENTS/Resources/default-config.json"

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Ad-hoc signing keeps the assembled bundle internally consistent.
# Public releases are intentionally not Developer ID signed or notarized.
codesign --force --deep --sign - "$APP" >/dev/null

echo "Built: $APP"
echo "Version: $VERSION"
echo "Run:   open '$APP'"
