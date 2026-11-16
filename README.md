# VEN OBS Utils

[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Python](https://img.shields.io/badge/Python-3.x-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![Swift](https://img.shields.io/badge/Swift-native%20menu%20bar-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Latest release](https://img.shields.io/github/v/release/Vencite/ven-obs-utils)](https://github.com/Vencite/ven-obs-utils/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Vibe coded](https://img.shields.io/badge/vibe--coded-yes-8A2BE2)

A small macOS menu-bar utility for OBS and Ontime break automation, MPS media
countdowns, and filename export. Built for my own live-production setup with
AI-assisted coding. This is not an official OBS or Ontime project.

## Break automation

Define your OBS break-scene and Ontime break-CUE patterns, for example
`^BREAK_.*$` and `^BRK_\d+$`.

- **Normal → break scene:** start the next matching break event in Ontime.
- **Break → normal scene:** if Ontime is currently on a break CUE, start the next
  non-skipped event.
- Normal → normal and break → break do nothing.

The app searches forward through the rundown, skips milestones and skipped events,
and starts the target by unique ID. It does nothing when connections, patterns or
current state do not allow a safe choice, and never blindly retries an uncertain start.
Only **Program** changes count; Preview is ignored. Reconnect establishes a fresh
baseline without replaying missed transitions.

## Media outputs (develop)

Follow a Media Playlist Source in Program or select a fixed source. Send its
current-file and playlist time to up to three independent Ontime auxiliary timers,
compose a secondary message alongside them, or
export the current filename to TXT. Outputs are optional and disabled by default.
See [media setup and testing](MEDIA-BRIDGE.md).

## Download and install

Requires **macOS 13+**, **Python 3**, [OBS Studio](https://obsproject.com/) and
[Ontime](https://www.getontime.no/). OBS WebSocket is built into OBS 28+;
Advanced Scene Switcher is not required.

[Download the latest release](https://github.com/Vencite/ven-obs-utils/releases/latest),
open the DMG and drag **VEN OBS Utils** to Applications. A ZIP is also available.
Prebuilt apps do not require Xcode.

Builds are ad-hoc signed, without Apple notarization. If macOS blocks the app,
allow it in **System Settings → Privacy & Security**.

## Settings and status

Open **Settings…** from the menu bar:

- **Connections:** OBS address, port and password; Ontime URL. OBS defaults to
  `127.0.0.1:4455`; remote hosts are supported.
- **Media outputs:** source selection, TXT export and Ontime timers/messages.
- **Break automation:** scene/CUE patterns, enter/leave switches and Dry run.

Start with **Dry run**: targets are resolved without changing Ontime. TXT export
still writes files. Test against your rundown before enabling live automation.
The menu shows connection state, Program scene, current Ontime event, media
output status and the last action. The icon indicates connection problems,
requests in progress, successful changes or failures.

Saving validates settings, restarts the helper and reconnects OBS. Configuration
is stored at `~/Library/Application Support/VEN OBS Utils/config.json`; the OBS
password is in macOS Keychain. Updating the app preserves both. Older configs
migrate automatically with a `config.json.backup`, preserving user values and
unknown keys. See [config/config.example.json](config/config.example.json).

## Build and test

Building requires Apple Command Line Tools / Xcode:

```bash
git clone https://github.com/Vencite/ven-obs-utils.git
cd ven-obs-utils
./build_app.sh
./install.sh
```

The installer copies the app to `/Applications` and opens it. Stop any older
manually running helper using port `8765` first.

```bash
python3 -m unittest discover -s tests -v
```

Backend tests use a local fake Ontime server. On macOS, `./test.sh` runs the full
Python and Swift/AppKit suite. Both Tests (push/pull_request) and Release DMG use
this same required suite before building; a failure prevents publication.
Automated checks do not replace live setup testing.

Develop builds show `0.2.0 (develop <short SHA>)` in the menu and log. The base
version comes from `.github/RELEASE_VERSION` (still `v0.2.0`); the complete commit
is stored in `Info.plist` as `VENDevelopCommit` and logged at startup.
`CFBundleShortVersionString` stays numeric, and `CFBundleVersion` remains `1`.
`VERSION=1.2.3 ./build_app.sh` still builds that production version; a semver
prerelease suffix is shown in the label while the Apple short version uses its
numeric core. Local default builds on develop identify the current HEAD; CI
explicitly stamps its tested SHA. Uncommitted local edits are not represented by
HEAD, so use CI artifacts when identifying a tested build.

## Manual HTTP triggers

The helper binds to `127.0.0.1:8765` by default:

| Method and path | Purpose |
| --- | --- |
| `POST /ontime/break` | Enter break (`/break` is a legacy alias) |
| `POST /ontime/leave-break` | Leave break |
| `GET /health`, `GET /status` | Connection and runtime status |

State-changing routes require `Authorization: Bearer <token>` and a loopback
client. The app supplies its existing random per-run IPC secret automatically;
a standalone helper must receive `VEN_MEDIA_IPC_TOKEN` in its environment.
Without that secret the automation endpoints are denied. The helper now refuses
LAN binds even when media outputs are disabled. Repeated triggers are debounced.
There is no public media-control API.

Migration for external callers (including Companion HTTP actions): the repository
contains no external caller configuration, but these documented paths may have
been used externally. Preserve the path, change GET to POST, and set the Bearer
header. `/break` remains an authenticated POST alias. GET returns 405 and never
executes an action; there is no insecure compatibility switch. For standalone
use, generate a secret (for example `python3 -c 'import secrets; print(secrets.token_urlsafe(32))'`),
provide it to the helper via `VEN_MEDIA_IPC_TOKEN`, and configure the same secret
in the local caller. Do not put it in the URL or commit it. The GUI app rotates
its private token at launch; external clients cannot depend on a stable GUI token.
If a caller cannot send POST with headers, migrate it before using this build.
Normal Program-scene automation is updated automatically.

## Releases

Update `.github/RELEASE_VERSION` to a new semver and push to `main`, or push a
`v*` tag. GitHub Actions tests, builds and publishes DMG/ZIP packages. There is
no Developer ID signing or notarization step. Develop artifacts are test builds.

## License and contact

MIT. See [LICENSE](LICENSE). Issues and sensible PRs are welcome.

For live production, video, photography or 3D work:
[VEN.WORKS — English](https://ven.works/en/) · [Polish](https://ven.works/).
