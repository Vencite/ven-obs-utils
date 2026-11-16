# Building, testing and local HTTP triggers

[Back to README](../README.md)

## Configuration

Saving validates settings,restarts the helper and reconnects OBS. Configuration
is stored at `~/Library/Application Support/VEN OBS Utils/config.json`; the OBS
password is in macOS Keychain. Updating the app preserves both. Older configs
migrate automatically with a `config.json.backup`, preserving user values and
unknown keys. See [config/config.example.json](../config/config.example.json).

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
is stored in `Info.plist` as `VENBuildCommit` (and `VENDevelopCommit` for develop builds) and logged at startup.
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
