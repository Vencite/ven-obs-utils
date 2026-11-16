#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
LABEL="${1:?Provide an artifact label (develop or release tag)}"
if [[ ! "$LABEL" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  echo "Invalid artifact label" >&2
  exit 1
fi
APP="$ROOT/build/VEN OBS Utils.app"
DIST="$ROOT/build/dist"
rm -rf "$DIST"
mkdir -p "$DIST/dmg-root"
export VEN_PACKAGE_APP="$APP" VEN_PACKAGE_DIST="$DIST"
python3 - <<'PY'
import json, os, pathlib, plistlib, re, subprocess
app = pathlib.Path(os.environ['VEN_PACKAGE_APP'])
dist = pathlib.Path(os.environ['VEN_PACKAGE_DIST'])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleIdentifier'] == 'works.ven.obs-utils'
assert info['LSMinimumSystemVersion'] == '13.0'
assert re.fullmatch(r'\d+\.\d+\.\d+', info['CFBundleShortVersionString'])
assert re.fullmatch(r'\d+(?:\.\d+){0,2}', info['CFBundleVersion'])
assert re.fullmatch(r'[0-9a-f]{40}', info['VENBuildCommit'])
if os.environ.get('GITHUB_SHA'):
    assert info['VENBuildCommit'] == os.environ['GITHUB_SHA']
if os.environ.get('VERSION'):
    assert info['CFBundleGetInfoString'] == os.environ['VERSION']
    assert info['CFBundleShortVersionString'] == re.split(r'[-+]', os.environ['VERSION'])[0]
exe = app / 'Contents/MacOS/VENOBSUtils'
archs = subprocess.check_output(['xcrun', 'lipo', '-archs', str(exe)], text=True).split()
assert set(archs) == {'arm64', 'x86_64'}, archs
for arch in archs:
    build = subprocess.check_output(['xcrun', 'vtool', '-arch', arch, '-show-build', str(exe)], text=True)
    minimum = re.findall(r'\bminos\s+([0-9.]+)', build)
    assert minimum and all(tuple(map(int, v.split('.')))[:2] == (13, 0) for v in minimum), build
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
signature = subprocess.run(['codesign', '-dv', str(app)], text=True, capture_output=True, check=True).stderr
assert 'Signature=adhoc' in signature, signature
manifest = {key: info[key] for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion', 'CFBundleGetInfoString', 'VENBuildCommit', 'LSMinimumSystemVersion')}
manifest.update(architectures=sorted(archs), signature='ad-hoc', notarized=False)
(dist / 'BUILD-INFO.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
PY

ditto "$APP" "$DIST/dmg-root/VEN OBS Utils.app"
ln -s /Applications "$DIST/dmg-root/Applications"
ZIP="$DIST/VEN-OBS-Utils-$LABEL.zip"
DMG="$DIST/VEN-OBS-Utils-$LABEL.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
hdiutil create -volname "VEN OBS Utils" -srcfolder "$DIST/dmg-root" -ov -format UDZO "$DMG"
hdiutil verify "$DMG"
python3 - "$ZIP" "$APP" <<'PY'
import hashlib, pathlib, plistlib, sys, zipfile
app = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(sys.argv[1]) as archive:
    assert archive.testzip() is None
    for name in ('Contents/Info.plist', 'Contents/MacOS/VENOBSUtils', 'Contents/Resources/services/media_bridge.py', 'Contents/Resources/services/ontime_break_sync.py'):
        assert archive.read('VEN OBS Utils.app/' + name) == (app / name).read_bytes(), name
print('ZIP CRC and bundled executable/metadata/helpers: OK')
PY
VERIFY_MOUNT="$DIST/verify-mount"
mkdir -p "$VERIFY_MOUNT"
trap 'hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || true' EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$VERIFY_MOUNT" "$DMG"
cmp "$APP/Contents/Info.plist" "$VERIFY_MOUNT/VEN OBS Utils.app/Contents/Info.plist"
cmp "$APP/Contents/MacOS/VENOBSUtils" "$VERIFY_MOUNT/VEN OBS Utils.app/Contents/MacOS/VENOBSUtils"
codesign --verify --deep --strict "$VERIFY_MOUNT/VEN OBS Utils.app"
hdiutil detach "$VERIFY_MOUNT"
trap - EXIT
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS)
