# VOS media outputs — develop test builds

VOS follows the Media Playlist Source Vendor API through its existing OBS
connection. It sends that state to Ontime and optional filename exports.
External playlist control belongs to MPS/obs-websocket; VOS has no public
Companion/media-control API. Its authenticated app/helper communication remains private.

## Settings

Settings are divided into **Connections**, **Media outputs** and **Break automation**.
Existing OBS credentials, break patterns and automation are retained. Config v2
migrates to v3 with a backup and removes the obsolete media HTTP configuration.

In Media outputs:

1. Enable media outputs. Automatically follow Program selects the single visible
   MPS, including nested scenes/groups, and ignores Preview. Zero or multiple
   candidates produce a clear unavailable state. To choose a fixed source,
   select it from the OBS source list; its UUID is stored internally.
2. Enable filename export if needed. **Choose file…** selects an exact TXT path;
   **Choose folder…** uses `current-media.txt` in that folder. Writes are atomic
   UTF-8, filename plus newline, only when changed. Inactive behavior can clear
   the text or keep the last filename.
3. Enable Ontime output if needed. An auxiliary countdown can follow the current
   file or the current playlist pass. Reserve slot 1, 2 or 3 for VOS. The main
   rundown is not advanced by media playback. Slot controls appear only for an
   auxiliary timer; text-message controls appear only for a message.
4. A secondary message can mix **Current filename**, **Time remaining in current
   file** and **Time remaining in playlist** using **Insert variable…**. The
   preview uses live values when available, otherwise an example. Unknown time
   appears as `--:--`; a known filename need not disappear because time is unknown.
5. **Show this output in Stage Timer’s secondary area** changes Ontime's selected
   display source. Otherwise choose the same slot/message in Ontime manually.
6. Save & Reconnect applies the settings. The menu and settings show the actual
   media-output result separately from the general Ontime connection status.

Dry run suppresses all Ontime changes, including timer stop/pause and message
updates. It does not suppress TXT. Start with Dry run for setup and use an isolated
rundown/spare auxiliary slot for real output tests.

## Ontime 4.14.0 compatibility

The user reported Ontime **4.14.0**. Compatibility is tested against its documented
wire behavior using local fixtures, not against the user's live production server.
The following defects were reproduced and fixed:

- The media requests used Python’s default User-Agent, which Cloudflare rejected
  with HTTP403 while health checks using `VEN-OBS-Utils/1.0` succeeded. Both now
  share the same headers. A local HTTP gate reproduces Connected + failed media
  before the fix and successful output afterwards.
- Stage Timer auxiliary selection requires `secondarySource=aux1`, `aux2` or
  `aux3`. The old `aux` value was rejected/coerced to no source in 4.14.0.
- Auxiliary runtime values may be finite fractional milliseconds. They are valid
  clock readings, not evidence that the selected auxiliary slot is unavailable.

The existing auxiliary and secondary-message HTTP paths match 4.14.0. The new output status reports HTTP failures and unavailable/unknown states.
Read-only requests to the user’s server confirmed403 with Python’s default agent
and successful version/poll with the VOS agent. No state-changing calls were
made to that server; actual auxiliary/message output still needs a user test.

## Time and recovery

The current-file and playlist remaining values come directly from MPS and already
account for playback speed. Playlist means the current pass, including with Loop.
Unknown is never replaced with zero. Unknown auxiliary time stops/pauses the owned
timer according to the inactive policy; a text message can show known fields and
`--:--` for unknown fields.

VOS validates schema v1's three known flags and absent/known values, preserves
known zero and rejects older revisions. Source changes and reconnects invalidate
state until fresh OBS data arrives. Lost app heartbeats expire after six seconds.
Paused snapshots remain frozen and authoritative.

Ontime actual auxiliary state is compared through `/api/poll`; normal progress
does not rewrite duration every second. Rebase is stop → direction → duration →
start (then pause if required), with correction above 1500 ms drift. Secondary
messages are deduplicated/coalesced to 1 Hz; invalidation clears immediately.

## Manual regression for this build

- Confirm original Program break enter/leave automation and OBS password still work.
- Check automatic Program selection, nested/shared/hidden sources, Preview,
  missing/ambiguous source and fixed-source rename/reconnect.
- Toggle each output: unrelated fields should collapse. Auxiliary slot must not
  appear for a message. Choose both a file and folder for TXT and check actual output.
- Insert all three variables, mix literal text, verify preview and actual message.
- With Dry run OFF on a test rundown, verify auxiliary 1/2/3 and message output,
  Stage Timer source selection and separate output status/errors.
- Complete MPS tests 12/13: 100%/200%, pause, paused seek, restart, next/previous,
  list edit and unknown/recovery. A+B+C=62s: after 3s media in A, 59s at100%,
  approximately29.5s at200% for all local files.
- Disconnect/restart OBS/helper/Ontime; no stale running timer or replay.
- The removed `/media/status`, `/media/current-file` and control routes must not work;
  private ingestion requires its independent per-app-run secret.

Test builds are not releases. Automated fixtures and UI screenshots do not replace
confirmation on the user's macOS/OBS/Ontime installation.
