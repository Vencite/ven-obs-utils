# Changelog

## 0.3.0 — Media time, in sync

VOS now brings your OBS playlists into Ontime: follow what's on Program, see
what's playing, and keep independent media countdowns alongside your rundown.

### New

- **Up to three independent auxiliary timers.** Show the current video's
  remaining time on Aux 1 and the whole playlist on Aux 2, for example.
  Each output has its own slot, time source and stop/keep-last policy.
- **Media Playlist Source integration.** Automatically follow a visible MPS
  source in Program or select a fixed source. Preview is ignored.
  Requires [Media Playlist Source](https://github.com/Vencite/media-playlist-source).
- **Secondary messages.** Combine filenames, current-file time, playlist time
  and your own text in a message, independently of auxiliary timers.
- **Filename export.** Write the current filename to TXT for an OBS text source
  or another application, with an optional JSON snapshot.
- **Stage Timer display selection.** Choose one secondary-area source, or leave
  the selection in Ontime unchanged.

### Improved

- **A clearer Settings window.** Connections, media outputs and break automation
  have their own tabs. Add or remove timer rows, preview messages and see each
  output's status. Unsaved edits show **Not applied yet**.
- **Playback that stays in sync.** Long pauses preserve valid telemetry;
  resume, seek, file changes and playback-speed changes update the appropriate
  counters without restarting countdowns every second.
- **Predictable Loop behaviour.** Loop hides playlist remaining time in VOS
  and applies the playlist timer's inactive policy, with **Playlist is looping**
  shown as its status. Current-file timers keep working. Shuffle without Loop
  still shows playlist time. Unknown durations remain unknown, never zero.
- **Easier setup documentation**, screenshots and a separate developer guide.
- **Verified Universal builds** for Apple Silicon and Intel, with commit metadata
  and checked DMG/ZIP installers.

### Fixed

- Timer ownership is tracked separately per slot and journalled before the first
  mutation. Failed and uncertain disk writes are handled conservatively.
- Keep-last pauses retain ownership, allowing synchronisation to resume.
  Normal shutdown cleans up owned slots; uncertain ownership after a crash
  requires operator review instead of taking over another integration's timer.
- Helper loss no longer leaves a historical success looking current in the UI.
- OBS disconnects discard queued, outdated break transitions. Reconnect starts
  from a fresh baseline, without replaying missed changes.
- Slow or failing requests to one auxiliary timer do not permanently block the
  other. Superseded telemetry and old OBS sessions cannot continue a stale batch.
- Configuration validation and migration preserve existing settings while
  keeping invalid, disabled media options from blocking break automation.
- All release builds now run the complete Python and Swift/AppKit test suite.

### Before updating

- Requires **macOS 13+ and Python 3**. The app is ad-hoc signed and **not notarized
  by Apple**; macOS may require **Privacy & Security → Open Anyway**.
- Settings and the OBS password are retained. Back up
  `~/Library/Application Support/VEN OBS Utils/` before updating, including any
  timer-ownership journal. Start with **Dry run**, then test your own rundown.
  Dry run suppresses Ontime commands; TXT export still writes files.
- Media outputs are optional and disabled by default. Reserve their Ontime slots
  for VOS; do not share them with another integration.
- **External HTTP callers must use authenticated POST requests on localhost.**
  State-changing GET requests are rejected. The GUI token changes at launch;
  external integrations cannot rely on it as a permanent credential.
  See [HTTP setup and migration](docs/DEVELOPMENT.md#manual-http-triggers).
- User-reported manual testing: **Ontime 4.15.1**. This release does not claim
  separate manual verification on 4.14.0 or every Mac/OBS/MPS combination.

[Compare 0.2.0 → 0.3.0](https://github.com/Vencite/ven-obs-utils/compare/v0.2.0...v0.3.0)
