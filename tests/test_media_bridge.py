import copy
import json
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from urllib.parse import unquote

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services"))
from media_bridge import MediaBridge, unavailable, validate_snapshot


def snapshot(**changes):
    result = {"schema_version": 1, "available": True, "stale": False,
              "source_uuid": "source-1", "source_name": "MPS", "snapshot_revision": 1,
              "state": "playing", "current_item_id": "entry-1", "current_file": "żółć.mp4",
              "current_path": "/private/media/żółć.mp4", "speed_percent": 100,
              "remaining_known": True, "remaining_ms": 3000,
              "playlist_remaining_known": True, "playlist_remaining_ms": 9000,
              "items_remaining_known": True, "items_remaining": 2}
    result.update(changes)
    return result


class FakeOntime:
    def __init__(self):
        self.calls = []
        self.timer = {"current": 0, "duration": 0, "playback": "stop", "direction": "count-down"}
        self.message = None
        self.fail = None

    def __call__(self, path):
        self.calls.append(path)
        if path == self.fail:
            raise OSError("request_failed")
        if path == "/api/poll":
            return {"payload": {"auxtimer1": copy.deepcopy(self.timer)}}
        if path.startswith("/api/message/secondary/"):
            self.message = unquote(path.removeprefix("/api/message/secondary/"))
        elif path.startswith("/api/auxtimer/1/"):
            action = path.removeprefix("/api/auxtimer/1/")
            if action.startswith("duration/"):
                self.timer["duration"] = self.timer["current"] = int(action.split("/")[1])
            elif action.startswith("direction/"):
                self.timer["direction"] = action.split("/")[1]
            elif action in {"start", "pause", "stop"}:
                if action != "pause" or self.timer["playback"] == "start":
                    self.timer["playback"] = {"start": "start", "pause": "pause", "stop": "stop"}[action]
        return {"payload": "success"}


class MediaBridgeTests(unittest.TestCase):
    def setUp(self):
        self.ontime = FakeOntime()
        self.config = {"enabled": True, "timer": {"media_timer_source": "playlist"},
                       "http": {"media_enabled": True}}
        self.bridge = MediaBridge(self.config, False, self.ontime)
        self.bridge.reset_session("first")
        self.sequence = 0

    def ingest(self, value=None, process=True):
        self.sequence += 1
        result = self.bridge.ingest({"session": "first", "sequence": self.sequence,
                                     "snapshot": value if value is not None else snapshot()})
        if process:
            self.bridge.process_outputs()
        return result

    def test_strict_known_flags_and_zero(self):
        for flag, field in (("remaining_known", "remaining_ms"),
                            ("playlist_remaining_known", "playlist_remaining_ms"),
                            ("items_remaining_known", "items_remaining")):
            value = snapshot(**{field: 0})
            self.assertEqual(validate_snapshot(value)[field], 0)
            for invalid in (None, {}, "0", -1, True, 0.0, 2**63):
                with self.subTest(field=field, invalid=invalid), self.assertRaises(ValueError):
                    validate_snapshot(snapshot(**{field: invalid}))
            with self.assertRaises(ValueError):
                validate_snapshot(snapshot(**{flag: False}))
            value = snapshot(**{flag: False})
            del value[field]
            self.assertNotIn(field, validate_snapshot(value))
            del value[flag]
            with self.assertRaises(ValueError):
                validate_snapshot(value)

    def test_schema_identity_and_optional_types(self):
        for changes in ({"schema_version": True}, {"snapshot_revision": False},
                        {"source_uuid": ""}, {"source_name": None}, {"elapsed_media_ms": -1},
                        {"state": "buffering"}, {"speed_percent": 0}, {"has_next": 1}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_snapshot(snapshot(**changes))

    def test_session_sequence_and_revision_reject_old_data(self):
        self.ingest(snapshot(snapshot_revision=10))
        self.assertEqual(self.ingest(snapshot(snapshot_revision=9))["reason"], "older_revision")
        with self.assertRaises(ValueError):
            self.bridge.ingest({"session": "other", "sequence": 99, "snapshot": snapshot()})
        result = self.bridge.ingest({"session": "first", "sequence": 1, "snapshot": snapshot()})
        self.assertEqual(result["reason"], "older_sequence")
        self.bridge.reset_session("second")
        self.assertFalse(self.bridge.status()["available"])
        with self.assertRaises(ValueError):
            self.bridge.reset_session("first")

    def test_status_private_path_and_current_filename(self):
        self.ingest()
        self.assertNotIn("current_path", self.bridge.status())
        self.assertIn("current_path", self.bridge.status(private=True))
        self.assertEqual(self.bridge.current_file(), "żółć.mp4")
        self.ingest(unavailable("ambiguous"))
        self.assertEqual(self.bridge.current_file(), "")
        self.assertFalse(self.bridge.status()["playlist_remaining_known"])

    def test_aux_rebase_then_stable_progress_does_not_rewrite_duration(self):
        self.ingest()
        self.assertEqual(self.ontime.calls, ["/api/poll", "/api/auxtimer/1/stop",
                         "/api/auxtimer/1/direction/count-down", "/api/auxtimer/1/duration/9000",
                         "/api/auxtimer/1/start"])
        self.ontime.calls.clear()
        self.ontime.timer["current"] = 8000
        self.ingest(snapshot(playlist_remaining_ms=8000))
        self.assertEqual(self.ontime.calls, ["/api/poll"])

    def test_pause_and_resume_do_not_rebase_aligned_timer(self):
        self.ingest()
        self.ontime.calls.clear()
        self.ingest(snapshot(state="paused", snapshot_revision=2))
        self.assertEqual(self.ontime.calls, ["/api/poll", "/api/auxtimer/1/pause"])
        self.ontime.calls.clear()
        self.ingest(snapshot(state="playing", snapshot_revision=3))
        self.assertEqual(self.ontime.calls, ["/api/poll", "/api/auxtimer/1/start"])

    def test_seek_and_real_drift_rebase(self):
        self.ingest()
        self.ontime.calls.clear()
        self.ingest(snapshot(snapshot_revision=2, playlist_remaining_ms=7000))
        self.assertIn("/api/auxtimer/1/duration/7000", self.ontime.calls)
        self.ontime.calls.clear()
        self.ontime.timer["current"] = 3000
        self.ingest(snapshot(snapshot_revision=2, playlist_remaining_ms=7000))
        self.assertIn("/api/auxtimer/1/duration/7000", self.ontime.calls)

    def test_unknown_stops_without_inventing_duration(self):
        self.ingest()
        value = snapshot(playlist_remaining_known=False)
        del value["playlist_remaining_ms"]
        self.ontime.calls.clear()
        self.ingest(value)
        self.assertEqual(self.ontime.calls, ["/api/auxtimer/1/stop"])
        self.ontime.calls.clear()
        self.ingest(value)
        self.assertEqual(self.ontime.calls, [])

    def test_current_item_mode_can_run_when_playlist_unknown(self):
        self.config["timer"]["media_timer_source"] = "current_item"
        bridge = MediaBridge(self.config, False, self.ontime)
        bridge.reset_session("s")
        value = snapshot(playlist_remaining_known=False)
        del value["playlist_remaining_ms"]
        bridge.ingest({"session": "s", "sequence": 1, "snapshot": value})
        bridge.process_outputs()
        self.assertIn("/api/auxtimer/1/duration/3000", self.ontime.calls)

    def test_inactive_keep_last_pauses_running_timer(self):
        self.bridge.config["timer"]["inactive_policy"] = "keep_last"
        self.ingest()
        self.ontime.calls.clear()
        self.ingest(unavailable("disconnected"))
        self.assertEqual(self.ontime.calls, ["/api/auxtimer/1/pause"])

    def test_stale_state_invalidates_controls_and_stops_timer(self):
        self.ingest()
        self.bridge.request_control("next")
        self.bridge._received = time.monotonic() - 7
        self.assertEqual(self.bridge.status()["reason"], "stale_telemetry")
        self.assertEqual(self.bridge.take_controls(), [])
        self.bridge.process_outputs()
        self.assertEqual(self.ontime.calls[-1], "/api/auxtimer/1/stop")

    def test_missing_aux_slot_does_not_mutate_ontime(self):
        calls = []
        bridge = MediaBridge(self.config, False, lambda path: calls.append(path) or {"payload": {}})
        bridge.reset_session("s")
        bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot()})
        bridge.process_outputs()
        self.assertEqual(calls, ["/api/poll"])
        self.assertEqual(bridge.status()["output_error"], "aux_timer_unavailable")

    def test_dry_run_covers_every_ontime_action(self):
        bridge = MediaBridge(self.config, True, self.ontime)
        bridge.reset_session("s")
        bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot()})
        bridge.process_outputs()
        self.assertEqual(bridge.status()["last_ontime_action"]["status"], "dry_run")
        bridge.close()
        self.assertEqual(self.ontime.calls, [])

    def test_controls_are_opt_in_bounded_and_not_replayed(self):
        self.assertEqual(self.bridge.request_control("next")["reason"], "source_unavailable")
        self.ingest()
        result = self.bridge.request_control("next")
        commands = self.bridge.take_controls()
        self.assertEqual(commands[0]["id"], result["id"])
        self.assertEqual(commands[0]["source_uuid"], "source-1")
        self.assertEqual(self.bridge.take_controls(), [])
        self.assertEqual(self.bridge.complete_control(result["id"], {"status": "success"})["status"], "success")
        for _ in range(16):
            self.assertEqual(self.bridge.request_control("pause")["status"], "queued")
        self.assertEqual(self.bridge.request_control("pause")["reason"], "control_queue_full")
        with self.assertRaises(ValueError):
            self.bridge.request_control("toggle")
        self.bridge.config["http"]["media_enabled"] = False
        self.assertEqual(self.bridge.request_control("play")["reason"], "controls_disabled")

    def test_source_change_cancels_queued_controls(self):
        self.ingest()
        self.bridge.request_control("next")
        self.ingest(snapshot(source_uuid="source-2"))
        self.assertEqual(self.bridge.take_controls(), [])

    def test_txt_atomic_unicode_dedup_and_clear(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "new" / "current.txt"
            self.bridge.config["txt"] = {"enabled": True, "path": str(path)}
            self.ingest()
            self.assertEqual(path.read_bytes(), "żółć.mp4\n".encode())
            stat = path.stat()
            self.ingest(snapshot(playlist_remaining_ms=8900))
            self.assertEqual(path.stat().st_mtime_ns, stat.st_mtime_ns)
            self.ingest(unavailable("disconnected"))
            self.assertEqual(path.read_bytes(), b"")
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_txt_keep_last_and_invalid_path_does_not_block_timer(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "current.txt"
            self.bridge.config["txt"] = {"enabled": True, "path": str(path), "clear_policy": "keep_last"}
            self.ingest()
            self.ingest(unavailable("disconnected"))
            self.assertEqual(path.read_text(), "żółć.mp4\n")
            self.bridge.config["txt"]["path"] = "relative.txt"
            self.ingest(snapshot(current_file="next.mp4", snapshot_revision=2))
            self.assertIn("export_path_must_be_absolute", self.bridge.status()["output_error"])
            self.assertEqual(self.ontime.timer["playback"], "start")

    def test_json_export_ignores_clock_only_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status.json"
            self.bridge.config["json"] = {"enabled": True, "path": str(path)}
            self.ingest()
            previous = path.stat().st_mtime_ns
            self.ingest(snapshot(elapsed_media_ms=100, playlist_remaining_ms=8900))
            self.assertEqual(previous, path.stat().st_mtime_ns)
            self.ingest(snapshot(snapshot_revision=2))
            self.assertEqual(json.loads(path.read_text())["snapshot_revision"], 2)

    def test_secondary_message_encodes_strings_and_rejects_template_access(self):
        self.bridge.config["timer"].update({"ontime_output": "secondary_message",
                                           "secondary_message_template": "{current_file} / {remaining_hhmmss}"})
        self.ingest()
        self.assertEqual(self.ontime.message, "żółć.mp4 / 00:00:03")
        self.assertIn("%2F", self.ontime.calls[-1])
        self.ontime.calls.clear()
        self.ingest()
        self.assertEqual(self.ontime.calls, [])
        self.bridge.config["timer"]["secondary_message_template"] = "{current_file.__class__}"
        self.ingest()
        self.assertEqual(self.bridge.status()["output_error"], "invalid_secondary_template")

    def test_ontime_failure_does_not_break_status_or_txt(self):
        self.ontime.fail = "/api/poll"
        self.ingest()
        self.assertTrue(self.bridge.status()["available"])
        self.assertEqual(self.bridge.current_file(), "żółć.mp4")
        self.assertEqual(self.bridge.status()["output_error"], "ontime_request_failed")

    def test_new_state_supersedes_inflight_poll_without_sending_old_actions(self):
        entered, release = threading.Event(), threading.Event()
        calls = []

        def blocked_poll(path):
            calls.append(path)
            if path == "/api/poll":
                entered.set()
                self.assertTrue(release.wait(2))
                return {"auxtimer1": copy.deepcopy(self.ontime.timer)}
            return {}

        bridge = MediaBridge(self.config, False, blocked_poll)
        bridge.reset_session("s")
        bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot()})
        worker = threading.Thread(target=bridge.process_outputs)
        worker.start()
        self.assertTrue(entered.wait(2))
        bridge.ingest({"session": "s", "sequence": 2, "snapshot": unavailable("disconnected")})
        self.assertFalse(bridge.status()["available"])
        release.set()
        worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(calls, ["/api/poll"])
        bridge.process_outputs()
        self.assertEqual(calls[-1], "/api/auxtimer/1/stop")

    def test_worker_shutdown_stops_reserved_timer(self):
        started = threading.Event()

        def getter(path):
            result = self.ontime(path)
            if path.endswith("/start"):
                started.set()
            return result

        bridge = MediaBridge(self.config, False, getter)
        bridge.reset_session("s")
        bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot()})
        bridge.start()
        self.assertTrue(started.wait(2))
        bridge.close()
        self.assertEqual(self.ontime.calls[-1], "/api/auxtimer/1/stop")
        self.assertFalse(bridge.status()["available"])

    def test_malformed_config_cannot_enable_any_outputs(self):
        for value in (None, [], "yes", {"enabled": "false"}, {"enabled": 1},
                      {"enabled": True, "timer": []}, {"enabled": True, "txt": "yes"},
                      {"http": {"media_enabled": "false"}}, {"json": {"enabled": 1}},
                      {"timer": {"aux_timer_index": True}},
                      {"timer": {"media_timer_source": "guessed"}},
                      {"txt": {"enabled": True, "path": "relative"}}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                MediaBridge(value, False, self.ontime)
        with self.assertRaises(ValueError):
            MediaBridge({}, "false", self.ontime)

    def test_disabled_bridge_never_writes_txt_even_if_nested_export_enabled(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "untouched.txt"
            path.write_text("previous\n")
            bridge = MediaBridge({"enabled": False, "txt": {"enabled": True, "path": str(path)}},
                                 False, self.ontime)
            bridge.reset_session("s")
            bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot()})
            bridge.process_outputs()
            bridge.close()
            self.assertEqual(path.read_text(), "previous\n")
            self.assertEqual(self.ontime.calls, [])

    def test_first_paused_snapshot_actually_pauses_aux_timer(self):
        self.ingest(snapshot(state="paused"))
        self.assertEqual(self.ontime.timer["playback"], "pause")
        self.assertEqual(self.ontime.timer["current"], 9000)
        self.assertEqual(self.ontime.calls[-2:], ["/api/auxtimer/1/start", "/api/auxtimer/1/pause"])
        self.ontime.calls.clear()
        self.ingest(snapshot(state="paused"))
        self.assertEqual(self.ontime.calls, ["/api/poll"])

    def test_heartbeat_does_not_interrupt_same_generation_output_batch(self):
        entered, release = threading.Event(), threading.Event()

        def blocked(path):
            if path == "/api/poll":
                entered.set()
                self.assertTrue(release.wait(2))
            return self.ontime(path)

        bridge = MediaBridge(self.config, False, blocked)
        bridge.reset_session("s")
        bridge.ingest({"session": "s", "sequence": 1, "snapshot": snapshot()})
        worker = threading.Thread(target=bridge.process_outputs)
        worker.start()
        self.assertTrue(entered.wait(2))
        bridge.ingest({"session": "s", "sequence": 2,
                       "snapshot": snapshot(playlist_remaining_ms=8900)})
        release.set()
        worker.join(2)
        self.assertFalse(worker.is_alive())
        self.assertEqual(self.ontime.timer["playback"], "start")
        self.ontime.calls.clear()
        bridge.process_outputs()
        self.assertEqual(self.ontime.calls, ["/api/poll"])

    def test_failed_stop_remains_error_and_retries_only_idempotent_stop(self):
        self.ingest()
        self.ontime.fail = "/api/auxtimer/1/stop"
        self.ingest(unavailable("disconnected"))
        state = self.bridge.status()
        self.assertEqual(state["output_error"], "ontime_request_failed")
        self.assertEqual(state["last_ontime_action"]["path"], "/api/auxtimer/1/start")
        self.assertEqual(self.ontime.timer["playback"], "start")
        self.ontime.fail = None
        self.ontime.calls.clear()
        self.ingest(unavailable("disconnected"))
        self.assertEqual(self.ontime.calls, ["/api/auxtimer/1/stop"])
        self.assertEqual(self.ontime.timer["playback"], "stop")

    def test_secondary_messages_coalesce_to_at_most_one_per_second(self):
        self.bridge.config["timer"].update({"ontime_output": "secondary_message",
                                          "secondary_message_template": "{current_file}"})
        self.ingest()
        self.assertEqual(self.ontime.message, "żółć.mp4")
        self.ontime.calls.clear()
        self.ingest(snapshot(current_file="second.mp4", snapshot_revision=2))
        self.ingest(snapshot(current_file="latest.mp4", snapshot_revision=3))
        self.assertEqual(self.ontime.calls, [])
        self.bridge._message_sent_at -= 2
        self.bridge._message_due = time.monotonic() - 1
        self.bridge.process_outputs()
        self.assertEqual(self.ontime.message, "latest.mp4")
        self.assertEqual(len(self.ontime.calls), 1)

    def test_current_and_historical_ontime_running_playback_names(self):
        self.ingest()
        self.assertEqual(self.ontime.timer["playback"], "start")
        self.ontime.calls.clear()
        self.ingest()
        self.assertEqual(self.ontime.calls, ["/api/poll"])
        self.ontime.timer["playback"] = "play"
        self.ontime.calls.clear()
        self.ingest()
        self.assertEqual(self.ontime.calls, ["/api/poll"])

    def test_failed_txt_clear_cannot_prevent_stale_timer_stop(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "current.txt"
            self.bridge.config["txt"] = {"enabled": True, "path": str(path)}
            self.ingest()
            self.assertEqual(self.ontime.timer["playback"], "start")
            path.unlink()
            path.mkdir()
            self.ontime.calls.clear()
            self.ingest(unavailable("disconnected"))
            self.assertEqual(self.bridge.status()["output_error"], "export_failed")
            self.assertEqual(self.ontime.calls, ["/api/auxtimer/1/stop"])
            self.assertEqual(self.ontime.timer["playback"], "stop")
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def test_unchanged_heartbeat_recovers_after_ontime_request_failure(self):
        self.ontime.fail = "/api/poll"
        self.ingest()
        self.assertEqual(self.bridge.status()["output_error"], "ontime_request_failed")
        self.ontime.fail = None
        self.ontime.calls.clear()
        self.ingest()
        self.assertNotIn("output_error", self.bridge.status())
        self.assertEqual(self.ontime.timer["playback"], "start")
        self.assertIn("/api/auxtimer/1/duration/9000", self.ontime.calls)
        self.ontime.calls.clear()
        self.ingest()
        self.assertEqual(self.ontime.calls, ["/api/poll"])

    def test_disabled_bridge_does_nothing(self):
        bridge = MediaBridge({"enabled": False}, False, self.ontime)
        self.assertEqual(bridge.ingest({})["reason"], "disabled")
        bridge.start()
        bridge.close()
        self.assertEqual(self.ontime.calls, [])


if __name__ == "__main__":
    unittest.main()
