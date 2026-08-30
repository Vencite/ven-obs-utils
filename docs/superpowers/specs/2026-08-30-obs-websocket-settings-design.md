# VEN OBS Utils - OBS WebSocket and Settings Design

Date: 2026-08-30

## Goal

Replace Advanced Scene Switcher as the required OBS integration. VEN OBS Utils should listen directly to OBS Program scene changes through OBS WebSocket, classify break transitions, and call the existing local Ontime helper safely.

The update also adds a normal macOS settings window, a live-production style menu-bar icon with transient action feedback, and preserves user configuration across application updates.

## Architecture

Keep responsibilities split:

- Swift macOS app: menu-bar UI, settings window, OBS WebSocket connection, Program scene tracking, scene-transition classification, Keychain access, status icon feedback.
- Python helper: Ontime API access, fail-closed break selection, leave-break logic, local HTTP endpoints, logging.

Do not rewrite the tested Ontime decision logic in Swift.

Data flow:

```text
OBS Program scene changed
        -> Swift OBS listener
        -> classify previous/current scene
        -> /ontime/break or /ontime/leave-break
        -> Python helper
        -> Ontime
```

Existing local HTTP endpoints remain available for compatibility and debugging.

## OBS integration

Use OBS WebSocket directly. Advanced Scene Switcher is no longer required.

Default connection settings:

- host: `127.0.0.1`
- port: `4455`
- password: stored in macOS Keychain, not in JSON
- reconnect interval: 5 seconds

The host must remain editable so remote OBS instances are supported.

Only Program scene changes trigger automation. Preview changes in Studio Mode must never trigger Ontime actions.

On initial connect or reconnect:

1. read the current Program scene,
2. store it as the baseline,
3. do not infer or replay any missed scene changes,
4. wait for the next real Program scene change.

If OBS disconnects, no Ontime action is attempted. The app enters a warning state and retries the OBS connection automatically.

## Break scene classification

The OBS break-scene pattern is configurable in the GUI.

Default example:

```text
^PRZERWA_.*$
```

Given previous and current Program scene names:

- non-break -> break = `enterBreak`
- break -> non-break = `leaveBreak`
- break -> break = ignore
- non-break -> non-break = ignore

A scene change alone is never enough to advance Ontime. The Python helper performs additional state validation before every Ontime change.

## Entering a break

On `enterBreak`, Swift calls:

```text
GET /ontime/break
```

Python then:

1. reads Ontime `eventNow`,
2. fails closed if no valid current event exists,
3. ignores the request if the current CUE already matches the break CUE regex,
4. reads the active rundown,
5. searches only forward from the current event,
6. considers only entries with `type == "event"`,
7. skips entries with `skip == true`,
8. finds the first later event whose CUE matches the configured break regex,
9. starts the resolved event by unique event ID.

Default Ontime break CUE regex:

```text
^BRK_\d+$
```

## Leaving a break

Add:

```text
GET /ontime/leave-break
```

This endpoint is only allowed to advance Ontime when the current `eventNow.cue` still matches the configured break CUE regex.

If Ontime is not currently on a break CUE, return `ignored` and do nothing.

When Ontime is currently on a break, search forward from the current event and start the first subsequent non-skipped event entry. Milestones and other non-event entries are ignored.

Example:

```text
BRK_1
milestone
event skip=true
CUE 11
```

Leaving the OBS break scene starts `CUE 11`.

Repeated or stale leave-break requests must be harmless because the helper re-checks current Ontime state before advancing.

## Fail-closed rules

Automation must do nothing when it cannot confidently determine the correct action.

Ignore or fail safely when:

- OBS is disconnected,
- Ontime is unreachable,
- there is no valid `eventNow`,
- the current event cannot be located in the active rundown,
- no future matching break exists,
- no future event exists when leaving a break,
- a regex is invalid,
- entering a break while Ontime is already on a break CUE,
- leaving a break while Ontime is not on a break CUE,
- switching between two break scenes,
- switching between two non-break scenes.

Do not blindly retry ambiguous Ontime start requests.

## Settings UI

Add a native macOS settings window.

Suggested layout:

```text
VEN OBS Utils - Settings

OBS
Host                  [ 127.0.0.1              ]
Port                  [ 4455                   ]
Password              [ •••••••••••••••        ]
Break scene regex     [ ^PRZERWA_.*$           ]

Ontime
URL                   [ https://...            ]
Break CUE regex       [ ^BRK_\d+$              ]

Automation
[x] Jump to next break when entering break scene
[x] Advance when leaving break scene
[ ] Dry run

Advanced
Local service port    [ 8765                   ]
Reconnect OBS every   [ 5 ] seconds

                    [ Save & Restart ]
```

On `Save & Restart`:

1. validate both regexes,
2. validate numeric ports and reconnect interval,
3. if validation fails, show the error next to the relevant field and do not write partial settings,
4. write non-secret settings atomically,
5. save/update the OBS password in Keychain,
6. restart the Python helper,
7. reconnect OBS using the new settings.

Keep an advanced action to open the raw config file, but remove `Open Config` from the primary menu workflow.

## Persistent configuration and updates

Non-secret settings remain in:

```text
~/Library/Application Support/VEN OBS Utils/config.json
```

OBS password is stored in macOS Keychain.

Replacing `/Applications/VEN OBS Utils.app` during an update must not overwrite either location.

The bundled default config is copied only when no user config exists.

New settings introduced in later app versions must be handled with defaults when absent from an existing user config rather than replacing the file.

## Menu-bar UI and status feedback

Replace the textual `VEN ✓` status item with a live-production style broadcast/antenna icon.

States:

- neutral: connected/idle broadcast icon,
- OBS disconnected: warning state,
- Ontime disconnected: warning state,
- request in progress: brief pulse/activity state,
- successful Ontime change: green flash for about 1.5 seconds, then return to neutral,
- failed action: red/error flash for about 2 seconds, then return to the persistent connectivity state,
- safely ignored request: no success/error flash.

Menu content:

```text
VEN OBS Utils

OBS: connected
Ontime: connected
Mode: LIVE

Program: KAMERY_LIVE
Ontime: CUE 11

Last action:
Left BRK_1 -> started CUE 11

Settings...
Restart Service
Open Logs
Quit
```

The icon must reflect persistent connection problems after any transient flash ends.

## Status and logging

Expand `/status` so the Swift UI can display:

- Ontime connection status and version,
- current Ontime event/CUE when available,
- configured mode,
- last action,
- break CUE regex.

Swift tracks and displays:

- OBS connection state,
- current Program scene,
- previous Program scene used for the last classification.

Log automation decisions with enough context to diagnose live behavior:

- previous OBS Program scene,
- current OBS Program scene,
- classified action (`enterBreak`, `leaveBreak`, `ignore`),
- Ontime eventNow ID/CUE when available,
- resolved target event ID/CUE when applicable,
- final result (`started`, `dry_run`, `ignored`, `error`),
- reason for ignored/error results.

Do not log the OBS WebSocket password.

## Compatibility

Retain:

```text
GET /break
GET /ontime/break
GET /health
GET /status
```

Add:

```text
GET /ontime/leave-break
```

`/break` remains an alias for `/ontime/break`.

Advanced Scene Switcher documentation should be moved from the primary setup instructions to a legacy/manual-trigger note, because it is no longer required for normal operation.

## Testing

Python tests must cover at minimum:

- leave-break advances to the first later non-skipped event,
- leave-break skips milestones/non-events,
- leave-break skips `skip=true` events,
- leave-break ignores when current Ontime event is not a break,
- leave-break fails closed with no current event,
- leave-break fails closed with no next event,
- existing enter-break behavior remains unchanged,
- HTTP `/ontime/leave-break` behavior,
- status includes newly required Ontime state where available.

Swift logic should isolate scene classification into a deterministic testable unit covering:

- non-break -> break = enter,
- break -> non-break = leave,
- break -> break = ignore,
- non-break -> non-break = ignore,
- invalid regex is rejected by settings validation.

OBS connection behavior must also preserve these invariants:

- Preview scene changes do not trigger automation,
- reconnect establishes a baseline without firing an action,
- no missed scene transitions are replayed after reconnect.

GitHub Actions should continue running Python tests and Swift checks. The release workflow should continue producing `.dmg` and `.zip` assets from version tags.

## Out of scope for this iteration

- rewriting the Ontime helper entirely in Swift,
- automatic application self-update,
- Apple Developer ID signing/notarization,
- replaying OBS events missed during disconnect,
- mapping specific OBS break scenes to specific numbered Ontime breaks,
- automatically controlling OBS scenes from Ontime.
