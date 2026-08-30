import json
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import urlopen

from test_ontime_break_sync import FakeOntimeHandler, FakeOntimeServer, make_rundown, break_sync


def make_config(fake, *, dry_run=False):
    return break_sync.Config(
        ontime_base_url=fake.base_url,
        break_cue_regex=r"^BRK_\d+$",
        dry_run=dry_run,
        debounce_seconds=0,
        request_timeout_seconds=1,
    )


class LeaveBreakSyncTests(unittest.TestCase):
    def test_leave_break_starts_first_future_non_skipped_event(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e5"]}
            FakeOntimeHandler.rundown = rundown
            fn = getattr(break_sync, "sync_from_break", None)
            self.assertIsNotNone(fn, "sync_from_break must exist")
            result = fn(make_config(fake))
            self.assertEqual(result["status"], "started")
            self.assertEqual(result["event_id"], "e6")
            self.assertEqual(result["cue"], "004")
            self.assertEqual(FakeOntimeHandler.start_requests, ["/api/start/id/e6"])

    def test_leave_break_skips_milestones_and_skipped_events(self):
        rundown = make_rundown()
        rundown["entries"]["e6"]["skip"] = True
        rundown["entries"]["m2"] = {"id": "m2", "type": "milestone", "title": "Technical marker"}
        rundown["entries"]["e8"] = {"id": "e8", "type": "event", "cue": "005", "title": "After break", "skip": False}
        rundown["flatOrder"] = ["e1", "m1", "e2", "e3", "e4", "e5", "e6", "m2", "e8", "e7"]
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e5"]}
            FakeOntimeHandler.rundown = rundown
            fn = getattr(break_sync, "sync_from_break", None)
            self.assertIsNotNone(fn, "sync_from_break must exist")
            result = fn(make_config(fake))
            self.assertEqual(result["event_id"], "e8")
            self.assertEqual(result["cue"], "005")
            self.assertEqual(FakeOntimeHandler.start_requests, ["/api/start/id/e8"])

    def test_leave_break_ignores_when_current_event_is_not_break(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e4"]}
            FakeOntimeHandler.rundown = rundown
            fn = getattr(break_sync, "sync_from_break", None)
            self.assertIsNotNone(fn, "sync_from_break must exist")
            result = fn(make_config(fake))
            self.assertEqual(result, {
                "status": "ignored",
                "reason": "not_on_break",
                "cue": "003",
                "event_id": "e4",
            })
            self.assertEqual(FakeOntimeHandler.start_requests, [])

    def test_leave_break_fails_closed_without_current_event(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": None}
            FakeOntimeHandler.rundown = rundown
            fn = getattr(break_sync, "sync_from_break", None)
            self.assertIsNotNone(fn, "sync_from_break must exist")
            self.assertEqual(fn(make_config(fake)), {"status": "ignored", "reason": "no_current_event"})
            self.assertEqual(FakeOntimeHandler.start_requests, [])

    def test_leave_break_fails_closed_when_there_is_no_future_event(self):
        rundown = make_rundown()
        rundown["flatOrder"] = ["e1", "m1", "e2", "e3", "e4", "e5"]
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e5"]}
            FakeOntimeHandler.rundown = rundown
            fn = getattr(break_sync, "sync_from_break", None)
            self.assertIsNotNone(fn, "sync_from_break must exist")
            self.assertEqual(fn(make_config(fake)), {"status": "ignored", "reason": "no_next_event"})
            self.assertEqual(FakeOntimeHandler.start_requests, [])

    def test_leave_break_dry_run_never_starts_ontime(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e5"]}
            FakeOntimeHandler.rundown = rundown
            fn = getattr(break_sync, "sync_from_break", None)
            self.assertIsNotNone(fn, "sync_from_break must exist")
            result = fn(make_config(fake, dry_run=True))
            self.assertEqual(result["status"], "dry_run")
            self.assertEqual(result["event_id"], "e6")
            self.assertEqual(FakeOntimeHandler.start_requests, [])


class LeaveBreakEndpointTests(unittest.TestCase):
    def test_namespaced_leave_break_endpoint_runs_sync(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e5"]}
            FakeOntimeHandler.rundown = rundown
            server = break_sync.create_local_server(make_config(fake, dry_run=True), host="127.0.0.1", port=0)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                host, port = server.server_address
                try:
                    with urlopen(f"http://{host}:{port}/ontime/leave-break", timeout=2) as response:
                        status_code = response.status
                        payload = json.loads(response.read().decode("utf-8"))
                except HTTPError as exc:
                    status_code = exc.code
                    payload = json.loads(exc.read().decode("utf-8"))
                self.assertEqual(status_code, 200)
                self.assertEqual(payload["status"], "dry_run")
                self.assertEqual(payload["event_id"], "e6")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_status_includes_current_ontime_event(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e5"]}
            FakeOntimeHandler.rundown = rundown
            server = break_sync.create_local_server(make_config(fake, dry_run=True), host="127.0.0.1", port=0)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                host, port = server.server_address
                with urlopen(f"http://{host}:{port}/status", timeout=2) as response:
                    payload = json.loads(response.read().decode("utf-8"))
                self.assertEqual(payload["ontime_event"], {
                    "id": "e5",
                    "cue": "BRK_2",
                    "title": "Przerwa 2",
                })
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
