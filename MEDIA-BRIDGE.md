# MPS media outputs — develop

VOS reads MPS telemetry through its existing OBS connection and sends it to Ontime
or TXT. External playlist control uses MPS/obs-websocket directly.

## Setup

In **Settings → Media outputs**:

1. Enable media outputs. Follow the single visible MPS in Program, including
   nested scenes/groups, or choose a fixed source. Preview is ignored; zero or
   multiple candidates make automatic selection unavailable.
2. For TXT, choose a file or a folder (`current-media.txt`). Export is atomic
   UTF-8, filename plus newline, written only on changes. Choose whether inactivity
   clears the file or keeps its last value.
3. For Ontime, choose an auxiliary countdown for the current file or playlist
   pass, or a secondary message. Reserve auxiliary slot 1, 2 or 3 for VOS.
   Media output does not advance the main rundown.
4. Use **Insert variable…** for `{current_file}`, `{remaining_hhmmss}` and
   `{playlist_remaining_hhmmss}`. Preview uses live data or an example.
5. Enable **Show this output in Stage Timer’s secondary area** to select its
   display automatically, or select it manually in Ontime.
6. **Save & Reconnect**. Output status is shown separately from connection status.

Only settings relevant to the enabled output are shown. **Dry run** suppresses
all Ontime changes, including stop/pause and messages, but does not suppress TXT.

## Time and recovery

- Times come from MPS, account for speed and freeze during pause. Playlist means
  the current pass, even with Loop enabled.
- Unknown time is never zero: messages show `--:--`; auxiliary output follows its
  stop/pause inactive policy. Known filenames can still be displayed.
- Source changes/reconnects invalidate old data until a fresh snapshot arrives.
  Lost app heartbeats expire after six seconds.
- Auxiliary state is checked against Ontime; drift above 1500 ms triggers a
  correction. Normal progress does not rewrite duration every second. Messages
  are coalesced to 1 Hz; invalidation clears immediately.

Ontime 4.14 compatibility fixes cover HTTP headers rejected by Cloudflare,
auxiliary display selection and fractional timer readings. Fixtures and read-only
server checks passed; real timer/message output still requires manual confirmation.
Config v2 migrates to v3 with a backup and removes obsolete media HTTP settings.

## Manual checks

- Existing break automation and OBS password still work.
- Automatic/fixed source selection handles nested, hidden, shared and renamed
  sources, Preview, ambiguity and reconnects.
- Output controls collapse correctly; TXT file/folder selection and inactive
  behavior work. All three template variables render correctly.
- With Dry run OFF on a test rundown, auxiliary slots 1–3, messages and Stage
  Timer display selection work; failures appear in output status.
- Verify 100%/200%, pause, paused seek, restart, next/previous, playlist edits and
  unknown/recovery. For 62 seconds of local media, after 3 media seconds the
  remainder is 59 seconds at 100% or about 29.5 seconds at 200%.
- Disconnect/restart OBS, helper and Ontime: no stale running timer or replay.
- Removed public `/media/*` routes remain unavailable; private app/helper
  ingestion requires its per-run secret.

Test builds and automated checks do not imply manual acceptance.

## Pause heartbeat and helper recovery

An unchanged snapshot is no longer resubmitted as new telemetry. Private IPC
heartbeats keep transport liveness separate from playback data. After three
seconds without MPS data, VOS requests `GetPlaylistState` for the selected UUID
(on the existing two-second scheduler, usually every four seconds during pause).
This also covers stopped and unknown states. A successful unchanged response
keeps the paused position frozen and does not rewrite exports or the timer.
OBS disconnection or failed probes invalidate the snapshot; helper silence still
expires after six seconds. Recovery requires authoritative OBS data.

Before the first auxiliary mutation, the helper atomically writes and fsyncs
`config.timer-owner.json` next to `config.json`. It contains the selected slot
and a hash of the Ontime target, without credentials. During telemetry loss,
`keep_last` pauses the owned timer and retains both ownership and the journal.
Repeated unavailable snapshots do not send additional pause commands. Fresh MPS
data resumes or synchronizes that same slot; `stop` stops it and releases ownership.

Normal helper shutdown (including Save & Reconnect) stops its owned auxiliary
timer even with `keep_last`, then releases ownership and removes the journal.
This lets the new helper/configuration start without an abandoned paused slot.
A failed stop retains the journal. SIGKILL skips this cleanup, so the next helper
uses the cautious recovery below, including when media outputs are disabled or
the selected slot/URL changes.

**Ontime 4.14 has no exclusive timer owner identifier or conditional mutation.**
A timer's duration/current value cannot establish who owns it after a crash.
Consequently, a surviving journal blocks new timer/message mutations and reports
`timer_recovery_required` while its recorded slot is running or paused. The
helper polls every two seconds and clears the journal only after that slot is
stopped. It never stops a timer based solely on the journal. An already running
or paused slot without a journal is also not acquired (`aux_timer_in_use`).
Reserve the configured slot exclusively for VOS: Ontime cannot prevent a second
client changing a slot between the poll and a command.

After SIGKILL, inspect `/status` → `media.recovery_timer_index` and stop that
slot **explicitly in Ontime**, after checking it is safe. The error clears and
fresh OBS data can resume synchronization. This is operator-assisted recovery,
not guaranteed unattended cleanup of an active orphan. If the Ontime URL changed,
`timer_recovery_target_changed` blocks actions against the new target. Stop the
old slot and temporarily restore the old URL so the helper can verify it stopped;
then change to the desired URL. A corrupt journal also requires operator review;
with the app stopped, remove it only after explicitly resolving the old timer.
Dry Run never clears an unresolved journal or changes Ontime.

Disabled media settings are retained on disk but their nested values are not
validated or used. Active media settings are validated on both sides; invalid
active values still fail. No config version change is required.

Additional manual regression checks (on a test rundown):

1. Pause MPS for at least 30 seconds and several minutes. Time and TXT remain
   frozen; resume continues normally. Repeat with stopped/unknown states.
2. During pause, disconnect OBS, reconnect, and choose a different MPS source.
   Old data must become unavailable and must not overwrite the new source.
3. Restart the helper normally, then separately SIGKILL it during countdown.
   During telemetry loss keep_last pauses; normal shutdown stops the owned slot.
   Crash recovery must
   show the recorded slot and require the explicit decision above; another
   integration's active slot must remain untouched. Repeat with slot/URL changes.
4. Disconnect/restart Ontime and the helper. Menu and Settings must show current
   failure/unavailability rather than a previous successful output; reconnect
   restores current status. Repeat with Dry Run enabled and verify no mutations.
5. Verify TXT/JSON, secondary messages and auxiliary slots 1/2/3, plus existing
   Program-scene break enter/leave and Preview exclusion.
