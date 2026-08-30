import json
import threading
import time
import unittest
from urllib.request import urlopen

import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services"))
import ontime_break_sync as break_sync


class ActionSerializationTests(unittest.TestCase):
    def test_enter_and_leave_requests_do_not_execute_concurrently(self):
        config = break_sync.Config(
            ontime_base_url="http://unused.invalid",
            break_cue_regex=r"^BRK_\d+$",
            dry_run=False,
            debounce_seconds=0,
            request_timeout_seconds=1,
        )

        enter_started = threading.Event()
        allow_enter_to_finish = threading.Event()
        leave_started = threading.Event()
        calls = []
        calls_lock = threading.Lock()

        original_enter = break_sync.sync_to_next_break
        original_leave = break_sync.sync_from_break

        def slow_enter(_config):
            with calls_lock:
                calls.append("enter-start")
            enter_started.set()
            allow_enter_to_finish.wait(timeout=3)
            with calls_lock:
                calls.append("enter-end")
            return {"status": "started", "cue": "BRK_1", "event_id": "break-1"}

        def leave(_config):
            leave_started.set()
            with calls_lock:
                calls.append("leave")
            return {"status": "started", "cue": "011", "event_id": "event-11"}

        break_sync.sync_to_next_break = slow_enter
        break_sync.sync_from_break = leave

        server = break_sync.create_local_server(config, host="127.0.0.1", port=0)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        host, port = server.server_address

        responses = {}

        def request(name, path):
            with urlopen(f"http://{host}:{port}{path}", timeout=5) as response:
                responses[name] = json.loads(response.read().decode("utf-8"))

        enter_thread = threading.Thread(target=request, args=("enter", "/ontime/break"))
        leave_thread = threading.Thread(target=request, args=("leave", "/ontime/leave-break"))

        try:
            enter_thread.start()
            self.assertTrue(enter_started.wait(timeout=2), "enter request did not start")

            leave_thread.start()
            self.assertFalse(
                leave_started.wait(timeout=0.5),
                "leave action started while enter action was still executing",
            )

            allow_enter_to_finish.set()
            enter_thread.join(timeout=3)
            leave_thread.join(timeout=3)

            self.assertFalse(enter_thread.is_alive())
            self.assertFalse(leave_thread.is_alive())
            self.assertTrue(leave_started.is_set())
            self.assertEqual(calls, ["enter-start", "enter-end", "leave"])
            self.assertEqual(responses["enter"]["status"], "started")
            self.assertEqual(responses["leave"]["status"], "started")
        finally:
            allow_enter_to_finish.set()
            enter_thread.join(timeout=1)
            leave_thread.join(timeout=1)
            server.shutdown()
            server.server_close()
            server_thread.join(timeout=2)
            break_sync.sync_to_next_break = original_enter
            break_sync.sync_from_break = original_leave


if __name__ == "__main__":
    unittest.main()
