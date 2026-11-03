# MPS media bridge (develop test builds)

This opt-in feature follows the versioned Media Playlist Source Vendor API. It
uses the app's existing OBS connection. It never reads private input settings,
calculates a shuffle order, decodes media or advances the Ontime main rundown.
Existing Program break automation remains separate.

Prerequisite: the Vencite MPS develop implementation of schema v1, currently
`45bcb9e` or later, with obs-websocket enabled. This is not a claim that MPS #4
has been released. This integration was started explicitly against test builds.
The complete OBS + macOS + Ontime + Companion workflow still needs manual testing.

## Setup

1. Back up your app config and start with **Dry run** enabled. Saving/migration
   retains existing break settings and OBS password; config v1 migrates to v2
   with the existing `.backup` mechanism. Media defaults to disabled.
2. In Settings, enable **MPS media bridge**. Follow Program requires exactly one
   visible MPS, including inside nested scenes/groups. Hidden sources and Preview
   are excluded; shared references count once. Zero/multiple candidates are
   reported unavailable. Alternatively turn Follow Program off and enter the
   exact source UUID (preferred; survives rename), or its exact name if UUID is
   empty. An invalid configured UUID is not silently rescued by a name.
3. Check **Media** in the menu for source, filename and current/playlist remaining.
   Unknown is `--:--`. These are MPS's real times to end at the effective speed;
   they are not media-clock durations. Loop shows the current pass only.
4. To export a filename, enable TXT and choose an absolute path, such as
   `/Users/you/Show/current-media.txt`. Writes are atomic UTF-8, filename plus
   newline, only when changed. Default inactive policy clears it; Keep last is
   explicit. Disabling export leaves the file alone. Optional config-only JSON
   export uses `media_bridge.json.enabled/path`; clock progress alone does not
   rewrite this file, so it is a snapshot, not a live countdown.
5. To use Ontime, select `current_item` or `playlist` (default `off`) and reserve
   auxiliary slot 1–3 exclusively for this bridge. Default output is the auxiliary
   timer. Secondary message is an alternative; supported placeholders are
   `{current_file}`, `{remaining_hhmmss}`, `{playlist_remaining_hhmmss}`.
   Stage Timer display is changed only with its separate checkbox.
6. Test in Dry run before allowing real Ontime actions. Dry run suppresses every
   media-related Ontime write, including pause/stop/message changes. It does not
   suppress TXT or explicitly enabled OBS media controls.

An unknown playlist duration does not mean zero and does not identify its cause.
The API cannot distinguish pending discovery from an unsupported or unreadable
file. The bridge displays unknown and stops the selected countdown by default;
current-item mode can still work when only that remainder is known. Keep last
pauses an owned auxiliary timer rather than leaving a misleading countdown running.

## Sync and recovery

Snapshots and VendorEvent payloads use the same strict schema v1 validation:
all three `*_known` booleans are required; false requires absence of the value,
true requires a non-negative integer. Known zero remains zero. Unsupported
schemas, inconsistent fields and placeholders fail closed.

Swift selects the source, rejects older revisions and sends ordered snapshots
through authenticated loopback IPC. OBS disconnect/reselection and helper restart
invalidate state before a fresh baseline/snapshot. A playing source that stops
publishing is rechecked; no elapsed time is invented between snapshots. Frozen
paused values remain authoritative. The helper expires lost app heartbeats after
six seconds and stops/pauses its owned timer.

Ontime uses `/api/poll` to validate the chosen auxiliary slot and compare its
actual current value. Current `start` and historical `play` runtime states are
accepted. Rebasing uses stop → direction → duration → start (then pause if
needed); pause on an already stopped timer does not establish a paused countdown.
Continuous updates do not reset duration each second. A discrepancy above
1500 ms permits correction. Ambiguous failed non-idempotent actions are not
blindly retried. Secondary text is deduplicated and coalesced to at most 1 Hz.

The implementation was checked against the official Ontime auxiliary service,
utils and types on 2026-11-03. Actual installed Ontime timing semantics and
versions must still be recorded during the manual test.

## Local HTTP / Companion

The existing helper serves these additional endpoints on its normal port
(default `127.0.0.1:8765`). Media requires an IPv4 loopback helper bind. LAN
binding is not supported for this feature; use Companion on the same Mac or an
explicitly configured authenticated tunnel. No change exposes the legacy break
endpoints to the LAN. No CORS access is enabled.

| Request | Result |
| --- | --- |
| `GET /media/status` | Normalized state, explicit availability/reason, last output/control result; no full media path |
| `GET /media/current-file` | UTF-8 filename + newline, empty when inactive |
| `POST /media/play`, `/pause`, `/next`, `/previous`, `/restart`, `/stop` | Opt-in OBS control, dedicated bearer token required |

Control paths are under `/media/` (e.g. `/media/next`), never GET side effects.
Enable controls separately in Settings. A blank token is generated on save;
reopen Settings to copy it. It is stored in Keychain, not JSON config. Public
control tokens cannot impersonate telemetry: app/helper IPC has a separate
per-app-run secret passed only via the managed process environment. Private
`/media/_*` endpoints are not Companion APIs. Requests have body/time limits.

POST responds `202 {"status":"queued","id":"..."}` when accepted. This is not
proof OBS executed it: check `/media/status.last_control` for success/error/ignored
with that ID. A stale/disconnected/ambiguous target is refused. Commands are
bounded, dequeued once, serialized through Swift and never automatically retried.
Use separate play/pause actions rather than a toggle.

```sh
curl http://127.0.0.1:8765/media/status
curl -X POST -H "Authorization: Bearer $MPS_CONTROL_TOKEN" \
  http://127.0.0.1:8765/media/next
```

Companion Generic HTTP setup:

1. Add a Generic HTTP connection with base URL `http://127.0.0.1:8765`.
2. Create custom variable `mps`. Add a GET action for `/media/status`, store its
   response in `mps`, and turn **JSON Stringify Result off** to keep a JSON object.
3. Run that action from a **Time interval trigger every 1000 ms**. A GET endpoint
   alone does not supply live variables. Disable the trigger when not needed.
4. In button text expression mode, use the stored object's `current_file` and
   independently test `playlist_remaining_known` before displaying
   `playlist_remaining_ms`. Do not substitute zero for an absent field. Check
   the expression syntax for your installed Companion version; the engine changed
   in Companion 5.0. First verify the object contents in Custom Variables.
5. For Next, add a POST `/media/next` action with header JSON
   `{"Authorization":"Bearer <your dedicated token>"}` and an empty JSON body.
   No Digest or Basic authentication is used. Protect Companion config exports
   containing a manually entered bearer header.

This recipe follows the upstream module's response-variable options; a visible
live button and end-to-end control have **not yet been verified** on the user's
Companion installation. Record that result before claiming the acceptance test.

## Manual regression

Use a test rundown and a spare auxiliary slot, never a production feed:

- Confirm existing Program break enter/leave and Preview-only behavior unchanged.
- Explicit UUID + rename; nested/shared/hidden MPS; 0 and 2 candidates; reconnect.
- A/B/C = 62 s at 100%; at media position 3 s in A: 59 s remaining. With all
  local files at 200%: approximately 29.5 s. Check actual payloads and menu/Ontime.
- Pause/resume, paused seek, restart, next/previous, edit, speed and item changes.
- Missing/corrupt files: unknown aggregate, no invented zero; regain known state.
- Restart helper, disconnect OBS and Ontime; no stale running timer or action replay.
- TXT Unicode, clear/keep-last, unchanged filename and unwritable path.
- Companion status refresh/button, controls, wrong token, wrong method, queued
  result vs executed result. Paused status remains valid without Vendor spam.
- Verify app packaging includes both helper Python files and starts on macOS.

References: [MPS schema](https://github.com/Vencite/media-playlist-source/blob/develop/docs/playlist-telemetry.md),
[Ontime HTTP](https://docs.getontime.no/api/protocols/http/),
[Ontime auxiliary implementation](https://github.com/cpvalente/ontime/tree/master/apps/server/src/services/aux-timer-service),
[Generic HTTP](https://github.com/bitfocus/companion-module-generic-http/blob/master/companion/HELP.md),
[Companion expressions](https://companion.free/user-guide/v4.2/expressions/).
