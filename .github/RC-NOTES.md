## Test candidate — not a production release

- Configure up to three independent Auxiliary Timers (for example Aux1 = Current file, Aux2 = Whole playlist), with separate status, stop/keep_last policies and conservative crash recovery.
- Journal transactions distinguish confirmed persistence from failed writes and uncertain directory fsync. No first Ontime mutation is sent without confirmed durability.
- Edited timer rows show **Not applied yet** until saved. Cancel does not apply changes.
- Deterministic tests cover slow endpoints, per-slot timeouts, stale telemetry/session cancellation and shutdown during in-flight HTTP.
- Existing break automation, MPS schema v1, Secondary Message, TXT/JSON, POST/Bearer and Dry Run remain covered by regression tests.

## Platform and signing

Universal executable: **arm64 (Apple Silicon, including M1) and x86_64 (Intel)**, minimum **macOS 13.0**. The packaging workflow verifies both Mach-O slices and their deployment targets, the bundle metadata, ZIP CRC and mounted DMG contents. Native CI tests run on the GitHub macOS runner; this is not a claim of manual runtime acceptance on both kinds of Mac.

The application is **ad-hoc signed, not Developer ID signed, and not notarized by Apple**. Gatekeeper can require System Settings → Privacy & Security → Open Anyway. Do not disable Gatekeeper globally. Python 3 must be available, as in previous builds.

## Install safely

1. Test outside a live production. Quit every running VEN OBS Utils copy.
2. Back up `~/Library/Application Support/VEN OBS Utils/`, including `config.json` and any timer-owner journal. Do not discard an unresolved journal.
3. **Before the first RC launch**, set `safety.dry_run` to `true` in the existing config (or set `dry_run: true` in a legacy flat config). Prefer a separate test Ontime rundown/server. A fresh installation already defaults to Dry Run with media outputs disabled.
4. Open the DMG and copy the app to Applications, or unzip the ZIP and copy its app. Keep a copy of the previous application for rollback. Bundle ID and config location are unchanged; Keychain settings are retained.
5. Verify the RC version and commit in the log. Test Aux1/2, pause/resume/seek/next, unknown playlist duration, keep_last/stop, reconnect, message/display selection and OBS break enter/leave in Dry Run first. Enable live commands only against a safe test rundown after reviewing configuration.

## Known limits

No production Ontime mutations or manual OBS/MPS/Ontime acceptance were performed by the agent. Ontime 4.14 has no exclusive ownership/CAS: reserve slots for VOS. An active timer of uncertain ownership after SIGKILL requires operator review; it is never automatically stopped. One bounded worker uses finite per-request timeouts; a slow request can delay the next slot temporarily. Unsaved rows deliberately do not show historical success. The stable v0.2.0 release is unchanged.

See `RC-AUDIT.md`, `MEDIA-BRIDGE.md` and `MULTI-TIMERS-AUDIT.md` in the tagged source for detailed test evidence and manual checks. `BUILD-INFO.json` records the verified architectures/version/commit; `SHA256SUMS` records installer checksums.
