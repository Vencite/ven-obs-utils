# RC follow-up: journal, unapplied GUI state, slow Ontime and installers

Requested audit reference: `8f41670d03ed4eae687941f48f39e41649ba0d79`.
Actual starting develop/origin HEAD: `c5b0d0abd0073a9b488cd3e8dd17cf5b1cd1a744`;
it already includes subsequent shutdown and new-item/pause fixes. Fetch confirmed
synchronization. Only pre-existing untracked `.codemap/` and `.opencode/` were
present and remain uncommitted. MPS is unchanged.

## Confirmed defects and fixes

**Journal transaction.** Before the fix, new deterministic tests reproduced three
failures: an Aux2 intent was in `_journal_slots` even when replace/file-fsync
failed, and uncertain directory durability was incorrectly called confirmed.

- `_journal_slots` now tracks successfully committed intent records; actual timer
  control remains in the independent per-slot `owned` state.
- `_save_ownership` computes a candidate without modifying confirmed state. A
  write/file-fsync/replace failure before replacement sends no first mutation
  and adds no Aux2 record. Aux1 can then be released and the journal removed;
  restarting does not invent an Aux2 orphan.
- Successful replacement followed by directory fsync/open/close failure raises
  JournalDurabilityUnknown. New intent indices are retained separately in
  `_journal_uncertain` and exposed as `journal_uncertain_indices`. Neither a
  successful mutation nor rollback is assumed. First mutation is still blocked.
- Subsequent durable updates preserve the union of confirmed/unresolved records.
  Releasing Aux1 cannot unlink a remaining uncertain Aux2. Restart treats any
  retained record conservatively, including old single `index` journals. An active
  foreign/unknown timer is never stopped; operator-assisted recovery remains.
- `_atomic_write` clears its temporary-file reference immediately after rename,
  so post-rename cleanup does not masquerade as a pre-commit write failure.
- The existing uncertain-write regression still asserts the same union of slot
  records, but now injects the actual directory fsync phase instead of an
  undifferentiated exception after the whole persistence method.

**GUI status.** Previously lookup used the currently edited slot, so Aux1→Aux2
could borrow Aux2's historical success. Every row now remembers its normalized
applied value when the dialog opens. Slot/source/policy/enabled edits and new
rows display **Not applied yet**, without copying a different slot's status or
error. Reverting restores actual current status. Cancel invokes no save callback;
Save & Reconnect creates the new applied configuration and normal connection
status flow. Layout and the three-row limit remain. AppKit tests cover Aux1→Aux2,
time source, policy, revert, Cancel, Save and unavailable→pending→synced.

## Slow Ontime: no worker architecture change

Five deterministic tests use Event gates and a controlled clock, not multi-second
sleeps. They cover several logical 2-second commands, a production-transport
3-second timeout on Aux1 while Aux2 succeeds, newer telemetry during a blocked
first-slot command, a new OBS session during poll, and close during an accepted
start. Status and ingest remain independent of the output HTTP lock. Superseded
batches do not send later stale commands; already accepted HTTP actions cannot be
rolled back, and shutdown cleans the owned timer after completion. One bounded
worker and the shared poll remain; no per-slot OBS connection/worker was added.

Every production HTTP call still receives request_timeout_seconds. A serial
batch can delay later slots by the earlier requests/timeouts. This is a socket
operation timeout, not an absolute wall-clock guarantee against pathological
DNS resolution or a peer that trickles bytes indefinitely. The controlled
normal/slow/timeout cases passed; no real production endpoint was invoked.

## Build and publication safety

- build_app.sh explicitly compiles arm64 and x86_64 for macOS 13.0, combines the
  real slices, and keeps Bundle ID `works.ven.obs-utils`, existing config paths,
  numeric Apple version fields and ad-hoc signing. Full SHA is in VENBuildCommit
  for both develop and RC; the menu/log retain the appropriate build label.
- package_app.sh checks actual architectures with lipo, each deployment target
  with vtool, plist/SHA, codesign strict verification and Signature=adhoc. It then
  checks ZIP CRC/executable/helpers and hdiutil checksum, mounts the DMG read-only,
  compares executable/plist with the built bundle and verifies the mounted app's
  signature. BUILD-INFO.json and SHA256SUMS accompany the installers.
- Develop CI uploads DMG and ZIP before any publication attempt. RC publication
  independently repeats the complete suite/build/package validation and uploads
  fallback installers before its release step.
- Strict `vMAJOR.MINOR.PATCH-rc.N` tag detection produces prerelease=true. The
  release uses **--prerelease --latest=false --verify-tag**; it requires successful
  develop CI for exactly the tagged SHA and refuses an existing release. There
  is no --clobber or force tag update. Unknown version suffixes fail closed.
- `.github/RELEASE_VERSION` stays `v0.2.0`; no main merge or stable release is
  performed. v0.2.0's tag/release/assets are checked before and after publication.
  The selected unused candidate is `v0.2.1-rc.1`, created only after final CI.
- Native runtime tests run on the macOS CI runner, not on physical M1 and Intel
  machines. Two verified slices are evidence of a Universal build, not manual
  live acceptance on both platforms. The app is **not notarized**.

## Verification evidence

- Local Python: **127/127 OK**, 15.324 s; targeted journal, slow transport and
  build safety tests also pass. py_compile, bash -n all three scripts, workflow
  YAML/order checks and git diff --check: OK.
- [Implementation CI 43871098912](https://github.com/Vencite/ven-obs-utils/actions/runs/43871098912)
  for `8d61925d067c05b6e1fc7af43616a9bf8c7c1528`: SUCCESS, job 3m12s; 127 Python
  OK (51.230 s), all 15 Swift suites PASS, native AppKit, both architecture builds,
  installer verification/upload OK. Downloaded files independently passed checksum,
  ZIP CRC and Mach-O CPU-type inspection (arm64+x86_64).
- This report is committed separately; final develop CI is checked again before
  creating the tag, then the tag workflow repeats full verification before RC.
  Current runs: [Tests](https://github.com/Vencite/ven-obs-utils/actions/workflows/test.yml?query=branch%3Adevelop),
  [Release DMG](https://github.com/Vencite/ven-obs-utils/actions/workflows/release.yml).
  Final run IDs, exact SHA, release URL and direct assets are supplied to the user.

Implementation commits:
- `4f050ccae207e911cad4787d159a899ea96584d9`
- `2c545682ba983fed3828d6a9864be59425b91ad5`
- `8d61925d067c05b6e1fc7af43616a9bf8c7c1528`

## Changed files

services/media_bridge.py; tests/test_journal_transactions.py;
tests/test_slow_ontime.py; tests/test_multi_timers.py;
app/Sources/SettingsWindowController.swift; app/Tests/SettingsWindowLayoutTests.swift;
app/Sources/ApplicationMain.swift; build_app.sh; package_app.sh;
tests/test_build_pipeline.py; .github/workflows/test.yml;
.github/workflows/release.yml; .github/RC-NOTES.md; README.md; MEDIA-BRIDGE.md;
RC-AUDIT.md. No existing suite was removed or weakened to obtain green CI.

## Manual acceptance and installation

See the [release notes](.github/RC-NOTES.md) for safe installation: quit all copies,
back up `~/Library/Application Support/VEN OBS Utils/`, preserve unresolved journals,
and **enable Dry Run in the existing config before first RC launch**. Otherwise
existing enabled media outputs could immediately act on the configured Ontime.
Copy the app from DMG/ZIP; configuration and Keychain identity are unchanged.
Open Anyway may be required for the ad-hoc, non-notarized build; do not disable
Gatekeeper globally. Python 3 is still required.

Outside production, test Aux1=current/Aux2=playlist, pause/resume/seek/next,
shuffle/loop/speed/unknown, stop/keep_last, normal restart and separate SIGKILL,
Secondary Message/Stage display, TXT/JSON, POST auth and break enter/leave.
Verify Not applied yet while editing and no changes after Cancel. Start in Dry
Run, then use a safe test rundown only. Physical M1/Intel runtime and real
OBS/MPS/Ontime tests remain pending; no live acceptance is inferred from CI.
