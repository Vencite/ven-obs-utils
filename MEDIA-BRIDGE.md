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
