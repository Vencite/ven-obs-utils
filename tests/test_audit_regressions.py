"""Deterministic audit regressions; no live OBS/Ontime actions."""
import copy
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from test_media_bridge import FakeOntime, snapshot
from media_bridge import MediaBridge, unavailable


class AuditMediaTests(unittest.TestCase):
    def test_disabled_invalid_nested_settings_do_not_block_helper(self):
        for section in ({"timer": {"media_timer_source": "invalid", "aux_timer_index": True}},
                        {"txt": "invalid"}, {"json": {"enabled": "invalid"}}):
            bridge = MediaBridge({"enabled": False, **section}, False, FakeOntime())
            self.assertEqual(bridge.status()["output_status"], "disabled")
            with self.assertRaises(ValueError):
                MediaBridge({"enabled": True, **section}, False, FakeOntime())

    def test_long_pause_heartbeat_freezes_data_without_output_work(self):
        clock = [100.0]
        fake = FakeOntime()
        with patch("media_bridge.time.monotonic", side_effect=lambda: clock[0]):
            bridge = MediaBridge({"enabled": True, "timer": {"media_timer_source": "playlist"}}, False, fake)
            bridge.reset_session("s")
            bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot(state="paused")})
            bridge.process_outputs()
            fake.calls.clear()
            for second in range(1, 301):
                clock[0] = 100 + second
                bridge.heartbeat({"session": "s", "sequence": second + 1})
                bridge.process_outputs()
                self.assertTrue(bridge.status()["available"])
                self.assertEqual(bridge.status()["playlist_remaining_ms"], 9000)
            self.assertEqual(fake.calls, [])
            bridge.ingest({"session": "s", "sequence": 302, "snapshot": snapshot(snapshot_revision=2)})
            bridge.process_outputs()
            self.assertEqual(fake.calls, ["/api/poll", "/api/auxtimer/1/start"])
            clock[0] += 7
            with self.assertRaises(ValueError):
                bridge.heartbeat({"session": "s", "sequence": 303})
            bridge.process_outputs()
            self.assertFalse(bridge.status()["available"])
            self.assertEqual(fake.calls[-1], "/api/auxtimer/1/stop")

    def test_foreign_running_timer_is_not_acquired(self):
        fake = FakeOntime()
        fake.timer.update(playback="start", duration=123000, current=100000)
        bridge = MediaBridge({"enabled": True, "timer": {"media_timer_source": "playlist"}}, False, fake)
        bridge.reset_session("s")
        bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot()})
        bridge.process_outputs()
        self.assertEqual(fake.calls, ["/api/poll"])
        self.assertEqual(bridge.status()["output_error"], "aux_timer_in_use")

    def test_crash_journal_blocks_ambiguous_timer_and_clears_after_operator_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "owner.json"
            fake = FakeOntime()
            config = {"enabled": True, "timer": {"media_timer_source": "playlist"}}
            first = MediaBridge(config, False, fake, ownership_path=path, target_id="host-a")
            first.reset_session("s")
            first.ingest({"session": "s", "sequence": 1, "snapshot": snapshot()})
            first.process_outputs()
            self.assertTrue(path.exists())
            fake.calls.clear()
            # Simulate SIGKILL: no close(), same Ontime runtime.
            second = MediaBridge(config, False, fake, ownership_path=path, target_id="host-a")
            second.process_outputs()
            self.assertEqual(fake.calls, ["/api/poll"])
            self.assertEqual(second.status()["output_error"], "timer_recovery_required")
            self.assertTrue(path.exists())
            fake.timer["playback"] = "stop"  # explicit operator decision in Ontime
            second._recovery_due = 0  # advance the recovery deadline without sleeping
            second.process_outputs()
            self.assertFalse(path.exists())
            second.reset_session("new")
            second.ingest({"session": "new", "sequence": 1, "snapshot": snapshot()})
            second.process_outputs()
            self.assertEqual(fake.timer["playback"], "start")
            second.close()
            self.assertEqual(fake.timer["playback"], "stop")
            self.assertFalse(path.exists())

    def test_changed_host_never_sends_recovery_to_new_host(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "owner.json"
            path.write_text(json.dumps({"target": "old", "index": 2}))
            fake = FakeOntime()
            bridge = MediaBridge({"enabled": False}, False, fake, ownership_path=path, target_id="new")
            bridge.process_outputs()
            self.assertEqual(fake.calls, [])
            self.assertEqual(bridge.status()["output_error"], "timer_recovery_target_changed")
            self.assertTrue(path.exists())

    def test_changed_slot_does_not_hide_previous_active_slot(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "owner.json"
            path.write_text(json.dumps({"target": "host", "index": 1}))
            fake = FakeOntime()
            fake.timer["playback"] = "start"
            config = {"enabled": True, "timer": {"media_timer_source": "playlist", "aux_timer_index": 2}}
            bridge = MediaBridge(config, False, fake, ownership_path=path, target_id="host")
            bridge.reset_session("s")
            bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot()})
            bridge.process_outputs()
            self.assertEqual(fake.calls, ["/api/poll"])
            self.assertEqual(bridge.status()["recovery_timer_index"], 1)
            self.assertEqual(bridge.status()["output_error"], "timer_recovery_required")

    def test_disabled_bridge_still_reports_crash_recovery(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "owner.json"
            path.write_text(json.dumps({"target": "host", "index": 1}))
            fake = FakeOntime()
            fake.timer["playback"] = "pause"
            bridge = MediaBridge({"enabled": False, "timer": "bad"}, False, fake,
                                 ownership_path=path, target_id="host")
            bridge.process_outputs()
            self.assertEqual(bridge.status()["output_status"], "error")
            self.assertEqual(fake.calls, ["/api/poll"])
            fake.timer["playback"] = "stop"
            bridge._recovery_due = 0
            bridge.process_outputs()
            self.assertEqual(bridge.status()["output_status"], "disabled")

    def test_corrupt_journal_and_dry_run_never_mutate_ontime(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "owner.json"
            for text, dry_run in [("{broken", False), (json.dumps({"target": "host", "index": 1}), True)]:
                path.write_text(text)
                fake = FakeOntime()
                bridge = MediaBridge({"enabled": True}, dry_run, fake, ownership_path=path, target_id="host")
                bridge.process_outputs()
                self.assertEqual(fake.calls, [])
                self.assertEqual(bridge.status()["output_status"], "error")
                self.assertEqual(path.read_text(), text)

    def test_journal_failure_prevents_first_timer_action(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = FakeOntime()
            path = Path(directory) / "owner.json"
            bridge = MediaBridge({"enabled": True, "timer": {"media_timer_source": "playlist"}}, False,
                                 fake, ownership_path=path, target_id="host")
            bridge.reset_session("s")
            bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot()})
            with patch("media_bridge._atomic_write", side_effect=OSError("disk full")):
                bridge.process_outputs()
            self.assertEqual(fake.calls, ["/api/poll"])
            self.assertEqual(bridge.status()["output_status"], "error")

    def test_session_change_during_poll_cancels_old_timer_mutations(self):
        fake = FakeOntime()
        bridge = None
        def get(path):
            result = fake(path)
            if path == "/api/poll":
                bridge.reset_session("new-session")
            return result
        bridge = MediaBridge({"enabled": True, "timer": {"media_timer_source": "playlist"}}, False, get)
        bridge.reset_session("old-session")
        bridge.ingest({"session": "old-session", "sequence": 1, "snapshot": snapshot()})
        bridge.process_outputs()
        self.assertEqual(fake.calls, ["/api/poll"])
        self.assertFalse(bridge.status()["available"])
        with self.assertRaises(ValueError):
            bridge.heartbeat({"session": "old-session", "sequence": 2})

    def test_heartbeat_retries_failed_output_without_changing_paused_time(self):
        fake = FakeOntime()
        fake.fail = "/api/poll"
        bridge = MediaBridge({"enabled": True, "timer": {"media_timer_source": "playlist"}}, False, fake)
        bridge.reset_session("s")
        bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot(state="paused")})
        bridge.process_outputs()
        self.assertEqual(bridge.status()["output_status"], "error")
        fake.fail = None
        bridge.heartbeat({"session": "s", "sequence": 2})
        bridge.process_outputs()
        self.assertEqual(fake.timer["playback"], "pause")
        self.assertEqual(bridge.status()["output_status"], "synced")

    def test_ontime_loss_clears_historical_success_and_reconnect_resends_message(self):
        fake = FakeOntime()
        bridge = MediaBridge({"enabled": True, "timer": {"media_timer_source": "playlist",
            "ontime_output": "secondary_message", "change_stage_timer_secondary_source": True}}, False, fake)
        bridge.reset_session("s")
        bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot(state="paused")})
        bridge.process_outputs()
        self.assertEqual(bridge.status()["output_status"], "synced")
        bridge.ontime_unavailable()
        self.assertEqual(bridge.status()["output_status"], "error")
        fake.calls.clear()
        bridge._message_sent_at = float("-inf")
        bridge.heartbeat({"session": "s", "sequence": 2})
        bridge.process_outputs()
        self.assertEqual(len(fake.calls), 2)
        self.assertEqual(bridge.status()["output_status"], "synced")

    def test_paused_heartbeat_does_not_rewrite_txt_or_json(self):
        import media_bridge
        clock = [100.0]
        with tempfile.TemporaryDirectory() as directory, \
             patch("media_bridge.time.monotonic", side_effect=lambda: clock[0]), \
             patch("media_bridge._atomic_write", wraps=media_bridge._atomic_write) as write:
            txt = Path(directory) / "media.txt"
            export = Path(directory) / "media.json"
            bridge = MediaBridge({"enabled": True, "txt": {"enabled": True, "path": str(txt)},
                "json": {"enabled": True, "path": str(export)}}, False, FakeOntime())
            bridge.reset_session("s")
            bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot(state="paused")})
            bridge.process_outputs()
            self.assertEqual(write.call_count, 2)
            for second in range(1, 301):
                clock[0] += 1
                bridge.heartbeat({"session": "s", "sequence": second + 1})
                bridge.process_outputs()
            self.assertEqual(write.call_count, 2)
            self.assertEqual(txt.read_text(), "żółć.mp4\n")
            self.assertEqual(json.loads(export.read_text())["state"], "paused")

    def test_active_missing_fields_use_compatible_defaults(self):
        bridge = MediaBridge({"enabled": True}, False, FakeOntime())
        self.assertEqual(bridge.status()["output_status"], "off")
        for field in ({"source_mode": []}, {"source_mode": "explicit"}, {"source_uuid": 1}):
            with self.assertRaises(ValueError):
                MediaBridge({"enabled": True, **field}, False, FakeOntime())


if __name__ == "__main__":
    unittest.main()
