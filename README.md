# VEN OBS Utils

[![macOS](https://img.shields.io/badge/macOS-13%2B-black?logo=apple)](https://www.apple.com/macos/)
[![Python](https://img.shields.io/badge/Python-3.x-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![Swift](https://img.shields.io/badge/Swift-native%20menu%20bar-F05138?logo=swift&logoColor=white)](https://www.swift.org/)
[![Latest release](https://img.shields.io/github/v/release/Vencite/ven-obs-utils)](https://github.com/Vencite/ven-obs-utils/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Vibe coded](https://img.shields.io/badge/vibe--coded-yes-8A2BE2)

A small macOS menu-bar utility for gluing together bits of my live-production workflow around OBS and Ontime.

I built this for my own live production setup. It is vibe-coded, it solved a real problem for me, and I figured there was no point letting it rot on my drive if it can save somebody else a bit of time.

Right now the useful part is **Ontime break sync**: when OBS enters a break scene, a local HTTP trigger tells VEN OBS Utils to find the next break event in the active Ontime rundown and jump to it.

This is not an official OBS or Ontime project.

## Why this exists

My rundown can contain normal events, VT cues, milestones and other internal steps between the thing currently on air and the next actual break. Simply calling Ontime's `start/next` is therefore not reliable enough for my workflow.

VEN OBS Utils instead:

1. reads the currently running Ontime event,
2. reads the active rundown,
3. walks forward through the rundown,
4. ignores milestones and skipped events,
5. finds the first event whose CUE matches a configurable regex,
6. starts that exact event by its Ontime event ID.

The default break pattern is:

```text
^BRK_\d+$
```

so cues such as `BRK_1`, `BRK_02` and `BRK_12` are treated as breaks.

If Ontime is unreachable, there is no current event, there is no later matching break, or the current event is already a break, the helper does nothing. I would rather have the automation fail closed than get creative during a live show.

## What is included

- a native Swift menu-bar app,
- a small Python HTTP service using only the standard library,
- Ontime connection and version status,
- LIVE / DRY RUN mode indicator,
- the configured break CUE regex,
- last break-sync action,
- restart service / open config / open logs actions,
- local `/health`, `/status` and `/ontime/break` endpoints.

The app supervises the Python service. The actual Ontime decision logic stays in Python so the menu-bar UI remains a thin wrapper around something easy to test and inspect.

## Requirements

- macOS 13+
- Python 3
- [Ontime](https://www.getontime.no/)
- [OBS Studio](https://obsproject.com/)

If you download a prebuilt release, you do not need Xcode or the Apple Command Line Tools just to run the app.

For automatic triggering from OBS I use [Advanced Scene Switcher](https://github.com/WarmUpTill/SceneSwitcher), but VEN OBS Utils itself only exposes a local HTTP endpoint. Any automation capable of making the request can use it.

Useful upstream docs:

- [Ontime documentation](https://docs.getontime.no/)
- [Ontime HTTP API](https://docs.getontime.no/api/protocols/http/)
- [OBS Knowledge Base](https://obsproject.com/kb)
- [Advanced Scene Switcher](https://github.com/WarmUpTill/SceneSwitcher)

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

## Releases

Releases are built automatically by GitHub Actions.

Pushing a tag matching `v*`, for example:

```bash
git tag v0.1.0
git push origin v0.1.0
```

runs the macOS build, executes the backend tests, packages the app as both `.dmg` and `.zip`, and publishes both files to a GitHub Release.

The release tag is also used as the app version. A tag such as `v0.2.1` produces an app with version `0.2.1`.

There is currently no Developer ID signing or Apple notarization step in this workflow.

## Configuration

The repository contains only an anonymized example config:

```text
config/config.example.json
```

On first launch the app copies that template to your local user config:

```text
~/Library/Application Support/VEN OBS Utils/config.json
```

That local config is where your real Ontime address belongs. It is not part of the repository.

Example:

```json
{
  "ontime": {
    "base_url": "https://your-ontime.example.com",
    "break_cue_regex": "^BRK_\\d+$",
    "request_timeout_seconds": 3
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

Start with `dry_run: true`. In dry-run mode the utility resolves the break it *would* start, but does not change Ontime. Once you have checked it against your own rundown, switch to `false` and restart the service from the menu bar.

## OBS / Advanced Scene Switcher

The local trigger is:

```text
GET http://127.0.0.1:8765/ontime/break
```

For example, multiple OBS break scenes can all call the same endpoint:

```text
BREAK_ADS
BREAK_RANDOM
BREAK_NO_ADS
```

The OBS scene name does not decide which numbered break gets selected. Ontime remains the source of truth for where the show currently is, and the helper chooses the next matching break later in the rundown.

The legacy endpoint below is kept as an alias:

```text
GET http://127.0.0.1:8765/break
```

Other local endpoints:

```text
GET http://127.0.0.1:8765/health
GET http://127.0.0.1:8765/status
```

## Safety notes

This grew out of my own show workflow, not a general-purpose broadcast automation product. Test it against your rundown before using it live.

The current break sync intentionally:

- only searches forward from the current event,
- ignores non-event entries such as milestones,
- ignores events with `skip: true`,
- refuses to advance if the current CUE already matches the break regex,
- does nothing when it cannot confidently resolve the next break,
- debounces repeated triggers,
- binds the helper to `127.0.0.1` by default.

## Tests

```bash
python3 -m unittest discover -s tests -v
```

The tests run against a local fake Ontime server and do not need access to a real Ontime instance.

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
├── app/Sources/main.swift
├── services/ontime_break_sync.py
├── config/config.example.json
├── tests/test_ontime_break_sync.py
├── build_app.sh
├── install.sh
├── LICENSE
└── README.md
```

## License

MIT. See [LICENSE](LICENSE).

## What I actually do

If this happened to be useful and you need live production, video, photography or 3D work, that is what I actually do for a living:

- [VEN.WORKS - English](https://ven.works/en/)
- [VEN.WORKS - Polish](https://ven.works/)
