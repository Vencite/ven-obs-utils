"""Ownership lifecycle regressions using the real journal and a fake Ontime."""
import tempfile
import unittest
from pathlib import Path

from test_media_bridge import FakeOntime, snapshot
from media_bridge import MediaBridge, unavailable


class KeepLastTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "owner.json"
        self.ontime = FakeOntime()
        self.config = {"enabled": True, "timer": {"media_timer_source": "playlist", "inactive_policy": "keep_last"}}
        self.bridge = self.new_bridge()
        self.bridge.reset_session("s")
        self.sequence = 0

    def new_bridge(self, config=None):
        return MediaBridge(config if config is not None else self.config, False, self.ontime,
                           ownership_path=self.path, target_id="host")

    def send(self, value):
        self.sequence += 1
        self.bridge.ingest({"session": "s", "sequence": self.sequence, "snapshot": value})
        self.bridge.process_outputs()

    def keep_last(self):
        self.send(snapshot())
        self.ontime.timer["current"] = 8000
        self.ontime.calls.clear()
        self.send(unavailable("stale_telemetry"))
        self.assertEqual(self.ontime.calls, ["/api/auxtimer/1/pause"])
        self.assertEqual(self.ontime.timer["playback"], "pause")
        self.assertEqual(self.ontime.timer["current"], 8000)

    def test_keep_last_preserves_ownership_and_journal(self):
        self.keep_last()
        self.assertTrue(self.bridge._timer_owned)
        self.assertTrue(self.path.exists())
        self.ontime.calls.clear()
        self.send(unavailable("disconnected"))
        self.assertEqual(self.ontime.calls, [], "Already paused ownership needs no further pause")

    def test_recovered_playing_resumes_same_timer_without_rebase(self):
        self.keep_last()
        self.ontime.calls.clear()
        self.send(snapshot(playlist_remaining_ms=8000, snapshot_revision=2))
        self.assertEqual(self.ontime.calls, ["/api/poll", "/api/auxtimer/1/start"])
        self.assertEqual(self.bridge.status()["output_status"], "synced")
        self.assertTrue(self.path.exists())

    def test_recovered_paused_preserves_value_then_playing_resumes(self):
        self.keep_last()
        self.ontime.calls.clear()
        self.send(snapshot(state="paused", playlist_remaining_ms=8000, snapshot_revision=2))
        self.assertEqual(self.ontime.calls, ["/api/poll"])
        self.send(snapshot(playlist_remaining_ms=8000, snapshot_revision=3))
        self.assertEqual(self.ontime.calls[-1], "/api/auxtimer/1/start")
        self.assertNotIn("output_error", self.bridge.status())

    def test_stop_policy_releases_ownership(self):
        self.config["timer"]["inactive_policy"] = "stop"
        self.bridge = self.new_bridge()
        self.bridge.reset_session("s")
        self.send(snapshot())
        self.ontime.calls.clear()
        self.send(unavailable("disconnected"))
        self.assertEqual(self.ontime.calls, ["/api/auxtimer/1/stop"])
        self.assertFalse(self.bridge._timer_owned)
        self.assertFalse(self.path.exists())

    def test_normal_close_stops_keep_last_and_allows_restart(self):
        self.keep_last()
        self.ontime.calls.clear()
        self.bridge.close()
        self.assertEqual(self.ontime.calls, ["/api/auxtimer/1/stop"])
        self.assertFalse(self.path.exists())
        restarted = self.new_bridge()
        restarted.reset_session("new")
        restarted.ingest({"session": "new", "sequence": 1, "snapshot": snapshot()})
        restarted.process_outputs()
        self.assertEqual(restarted.status()["output_status"], "synced")
        restarted.close()

    def test_failed_close_retains_journal_for_cautious_recovery(self):
        self.keep_last()
        self.ontime.fail = "/api/auxtimer/1/stop"
        self.bridge.close()
        self.assertTrue(self.path.exists())
        self.assertEqual(self.bridge.status()["output_status"], "error")

    def test_simulated_sigkill_keeps_paused_timer_quarantined(self):
        self.keep_last()
        for config in (self.config, {"enabled": False},
                       {"enabled": True, "timer": {"media_timer_source": "playlist", "aux_timer_index": 2}}):
            self.ontime.calls.clear()
            restarted = self.new_bridge(config)
            restarted.process_outputs()
            self.assertEqual(self.ontime.calls, ["/api/poll"])
            self.assertEqual(restarted.status()["output_error"], "timer_recovery_required")
            self.assertEqual(restarted.status()["recovery_timer_index"], 1)
            self.assertTrue(self.path.exists())

    def test_normal_config_change_cleans_old_slot_before_new_config(self):
        self.keep_last()
        self.bridge.close()
        self.assertEqual(self.ontime.timer["playback"], "stop")
        self.assertFalse(self.path.exists())
        self.ontime.calls.clear()
        changed = self.new_bridge({"enabled": False})
        changed.process_outputs()
        self.assertEqual(self.ontime.calls, [])
        self.assertEqual(changed.status()["output_status"], "disabled")

    def test_foreign_paused_or_running_timer_never_acquired_or_stopped(self):
        for playback in ("pause", "start"):
            self.ontime.timer["playback"] = playback
            self.ontime.calls.clear()
            bridge = self.new_bridge()
            bridge.reset_session("s")
            bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot()})
            bridge.process_outputs()
            bridge.close()
            self.assertEqual(self.ontime.calls, ["/api/poll"])
            self.assertEqual(self.ontime.timer["playback"], playback)
            self.assertFalse(self.path.exists())
