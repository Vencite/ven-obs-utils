# VEN OBS Utils

[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Python](https://img.shields.io/badge/Python-3.x-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![Swift](https://img.shields.io/badge/Swift-native%20menu%20bar-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Latest release](https://img.shields.io/github/v/release/Vencite/ven-obs-utils)](https://github.com/Vencite/ven-obs-utils/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Vibe coded](https://img.shields.io/badge/vibe--coded-yes-8A2BE2)

A small macOS menu-bar utility for gluing together bits of my live-production workflow around OBS and Ontime.

I built this for my own live setup. It is vibe-coded, it solved a real problem for me, and I figured there was no point letting it rot on my drive if it can save somebody else a bit of time.

The main feature is **OBS <-> Ontime break sync**. VEN OBS Utils connects directly to OBS WebSocket, watches the **Program** scene, and keeps Ontime in step with break scene transitions.

This is not an official OBS or Ontime project.

## What it does

You define two regexes:

```text
OBS break scenes: ^BREAK_.*$
Ontime break CUEs: ^BRK_\d+$
```

Then the app handles two transitions:

```text
normal scene -> BREAK_*
```

VEN OBS Utils asks Ontime for the current event, walks forward through the active rundown, skips milestones and skipped events, finds the next matching `BRK_x` event and starts that exact event by ID.

And on the way back:

```text
BREAK_* -> normal scene
```

VEN OBS Utils first checks that Ontime is **currently** on a break CUE. Only then does it start the first later non-skipped event.

So if the rundown contains:

```text
BRK_1
milestone
event skip=true
CUE 11
```

leaving the OBS break scene advances Ontime to `CUE 11`.

Switching between two normal OBS scenes does nothing. Switching between two break scenes also does nothing.

## Why not just `start/next`?

My rundowns can contain normal events, VT cues, milestones and other internal steps between the thing currently on air and the next actual break. Blindly calling Ontime's `start/next` is therefore not reliable enough for my workflow.

VEN OBS Utils resolves the target from the actual rundown and starts it by unique event ID.

If OBS or Ontime is unavailable, there is no current event, a regex is invalid, no valid future target exists, or the current Ontime state does not match the requested transition, the automation fails closed and does nothing.

I would rather have automation stop than get creative during a live show.

## OBS integration

OBS WebSocket is built into OBS Studio 28 and newer. VEN OBS Utils connects to it directly, so **Advanced Scene Switcher is not required** for normal use.

Default OBS connection:

```text
Host: 127.0.0.1
Port: 4455
```

The host is editable, so a remote OBS instance can be used as well.

Only **Program** scene changes are used. In Studio Mode you can prepare a break scene in Preview without triggering anything. The Ontime action happens only when that scene actually becomes Program.

On initial connection or reconnect, the app reads the current Program scene and treats it as a fresh baseline. It never replays or guesses scene changes that may have happened while OBS was disconnected.

If OBS WebSocket requires a password, the password is stored in **macOS Keychain**, not in the JSON config.

## Menu-bar app

The menu shows the live state of both systems, for example:

```text
VEN OBS Utils

OBS: connected
Ontime: connected (4.x.x)
Mode: LIVE
Program: CAMERAS_LIVE
Ontime event: 011 - Panel
Last action: left BRK_1 -> started 011
```

The menu-bar icon is also a status indicator:

- broadcast icon - OBS and Ontime connected,
- warning icon - one of the connections is unavailable,
- activity icon - an Ontime request is in progress,
- green flash - Ontime was successfully changed,
- red flash - an automation request failed.

A safely ignored request does not produce a success or error flash.

## Settings

Use **Settings…** from the menu bar. You normally do not need to edit JSON by hand.

The Settings window contains:

- OBS host and port,
- OBS WebSocket password,
- OBS break scene regex,
- Ontime URL,
- Ontime break CUE regex,
- enter-break automation toggle,
- leave-break automation toggle,
- dry-run toggle,
- local helper port,
- OBS reconnect interval.

Saving validates the fields first, writes the config atomically, stores the OBS password in Keychain, restarts the local helper and reconnects OBS.

User configuration lives outside the application bundle:

```text
~/Library/Application Support/VEN OBS Utils/config.json
```

Replacing or updating `/Applications/VEN OBS Utils.app` does **not** overwrite that file or the Keychain password. New config fields are loaded with defaults when upgrading from an older config.

## Requirements

- macOS 13+
- Python 3
- [Ontime](https://www.getontime.no/)
- [OBS Studio](https://obsproject.com/)

If you download a prebuilt release, you do not need Xcode or the Apple Command Line Tools just to run the app.

Useful upstream docs:

- [Ontime documentation](https://docs.getontime.no/)
- [Ontime HTTP API](https://docs.getontime.no/api/protocols/http/)
- [OBS Knowledge Base](https://obsproject.com/kb)
- [obs-websocket](https://github.com/obsproject/obs-websocket)

## Download and install

For most people, the easiest option is the latest GitHub Release:

**[Download the latest release](https://github.com/Vencite/ven-obs-utils/releases/latest)**

Download the `.dmg`, open it and drag **VEN OBS Utils** to Applications.

The release builds are ad-hoc signed, but they are **not Developer ID signed or notarized by Apple**. macOS may therefore warn you when you open the app for the first time. Depending on your macOS version, you may need to use **Open** from the app's context menu or allow it in **System Settings -> Privacy & Security**.

A `.zip` containing the same `.app` is also attached to each release.

## Build from source

Building from source additionally requires the Apple Command Line Tools / Xcode toolchain.

```bash
git clone https://github.com/Vencite/ven-obs-utils.git
cd ven-obs-utils
./build_app.sh
./install.sh
```

The build script explicitly selects the active macOS SDK through `xcrun`, which avoids Swift standard-library lookup problems seen with some newer macOS/Xcode combinations.

`install.sh` copies the app to:

```text
/Applications/VEN OBS Utils.app
```

and opens it.

Before starting the app, stop any older manually running copy of the helper if it is already using port `8765`.

## Configuration file

The repository contains only an anonymized example:

```text
config/config.example.json
```

Example:

```json
{
  "ontime": {
    "base_url": "https://your-ontime.example.com",
    "break_cue_regex": "^BRK_\\d+$",
    "request_timeout_seconds": 3
  },
  "obs": {
    "host": "127.0.0.1",
    "port": 4455,
    "break_scene_regex": "^BREAK_.*$",
    "reconnect_seconds": 5
  },
  "automation": {
    "enter_break": true,
    "leave_break": true
  },
  "server": {
    "host": "127.0.0.1",
    "port": 8765
  },
  "safety": {
    "dry_run": true,
    "debounce_seconds": 2
  }
}
```

Start with `dry_run: true`. In dry-run mode the helper resolves the event it *would* start, but does not change Ontime.

## Manual / legacy HTTP triggers

Direct OBS WebSocket integration is the normal workflow, but the local helper endpoints remain available for debugging or external automation.

Enter a break:

```text
GET http://127.0.0.1:8765/ontime/break
```

Leave a break:

```text
GET http://127.0.0.1:8765/ontime/leave-break
```

Legacy alias:

```text
GET http://127.0.0.1:8765/break
```

Status endpoints:

```text
GET http://127.0.0.1:8765/health
GET http://127.0.0.1:8765/status
```

If you prefer to build your own trigger setup with something such as [Advanced Scene Switcher](https://github.com/WarmUpTill/SceneSwitcher), these endpoints are still there. It is just no longer a required part of VEN OBS Utils.

## Safety notes

The automation intentionally:

- listens only to OBS Program scene changes,
- establishes a fresh baseline after OBS reconnect and never replays missed transitions,
- only searches forward from the current Ontime event,
- ignores non-event entries such as milestones,
- ignores events with `skip: true`,
- refuses enter-break when Ontime is already on a break CUE,
- refuses leave-break unless Ontime is currently on a break CUE,
- does nothing on break -> break and normal -> normal OBS transitions,
- does nothing when it cannot confidently resolve a target,
- debounces repeated helper triggers,
- never blindly retries an ambiguous Ontime start request,
- binds the local helper to `127.0.0.1` by default.

Test it against your rundown before using it live.

## Tests

Backend tests:

```bash
python3 -m unittest discover -s tests -v
```

GitHub Actions also runs the Swift state, protocol, configuration, Keychain and routing tests and builds the complete macOS application.

The Python tests run against a local fake Ontime server and do not require access to a real Ontime instance.

## Releases

Releases are built automatically by GitHub Actions.

Pushing a tag matching `v*`, for example:

```bash
git tag v0.2.0
git push origin v0.2.0
```

runs the tests, builds the macOS app, packages it as both `.dmg` and `.zip`, and publishes both files to a GitHub Release.

The tag is used as the app version. There is currently no Developer ID signing or Apple notarization step.

## Vibe-coding disclaimer

Yes, this repo is vibe-coded.

I described the workflow and failure cases, iterated on the implementation with AI, and tested it against my actual setup. I am publishing it because it is useful to me, not because I want to pretend it is a mature software product.

Read the code, test it with `dry_run`, and do not trust live automation just because a README says it works.

Issues and sensible PRs are welcome.

## Repository layout

```text
ven-obs-utils/
├── .github/workflows/
│   ├── release.yml
│   └── test.yml
├── app/
│   ├── Sources/
│   │   ├── ApplicationMain.swift
│   │   ├── AppConfig.swift
│   │   ├── KeychainStore.swift
│   │   ├── OBSProtocol.swift
│   │   ├── OBSConnectionState.swift
│   │   ├── OBSWebSocketClient.swift
│   │   ├── SceneAutomation.swift
│   │   ├── SettingsDraft.swift
│   │   ├── SettingsWindowController.swift
│   │   └── StatusPresentation.swift
│   └── Tests/
├── services/ontime_break_sync.py
├── config/config.example.json
├── tests/
├── build_app.sh
├── install.sh
├── LICENSE
└── README.md
```

Internal planning/spec files are intentionally ignored and are not part of the public repository tree.

## License

MIT. See [LICENSE](LICENSE).

## What I actually do

If this happened to be useful and you need live production, video, photography or 3D work, that is what I actually do for a living:

- [VEN.WORKS - English](https://ven.works/en/)
- [VEN.WORKS - Polish](https://ven.works/)
