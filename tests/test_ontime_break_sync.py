import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import tempfile

import sys
from pathlib import Path as _Path
sys.path.insert(0, str(_Path(__file__).resolve().parents[1] / "services"))
import ontime_break_sync as break_sync


class FakeOntimeHandler(BaseHTTPRequestHandler):
    runtime = {}
    rundown = {}
    start_requests = []

    def do_GET(self):
        if self.path == "/api/version":
            self._json(200, {"payload": "4.8.0"})
            return
        if self.path == "/api/poll":
            self._json(200, {"payload": self.runtime})
            return
        if self.path == "/data/rundowns/current":
            self._json(200, self.rundown)
            return
        if self.path.startswith("/api/start/id/"):
            self.start_requests.append(self.path)
            self._json(200, {"payload": "success"})
            return
        self._json(404, {"error": "not found"})

    def log_message(self, format, *args):
        pass

    def _json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class FakeOntimeServer:
    def __enter__(self):
        FakeOntimeHandler.start_requests = []
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), FakeOntimeHandler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        host, port = self.server.server_address
        self.base_url = f"http://{host}:{port}"
        return self

    def __exit__(self, exc_type, exc, tb):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def make_rundown():
    entries = {
        "e1": {"id": "e1", "type": "event", "cue": "001", "title": "Powitanie", "skip": False},
        "m1": {"id": "m1", "type": "milestone", "title": "VT"},
        "e2": {"id": "e2", "type": "event", "cue": "002", "title": "VT Mango", "skip": False},
        "e3": {"id": "e3", "type": "event", "cue": "BRK_1", "title": "Przerwa 1", "skip": True},
        "e4": {"id": "e4", "type": "event", "cue": "003", "title": "Dalsza część", "skip": False},
        "e5": {"id": "e5", "type": "event", "cue": "BRK_2", "title": "Przerwa 2", "skip": False},
        "e6": {"id": "e6", "type": "event", "cue": "004", "title": "Panel", "skip": False},
        "e7": {"id": "e7", "type": "event", "cue": "BRK_3", "title": "Przerwa 3", "skip": False},
    }
    return {
        "id": "r1",
        "title": "Main",
        "order": list(entries),
        "flatOrder": list(entries),
        "entries": entries,
        "revision": 1,
    }


class BreakSyncTests(unittest.TestCase):
    def test_finds_next_non_skipped_break_after_current_event(self):
        rundown = make_rundown()
        found = break_sync.find_next_break(rundown, "e2", r"^BRK_\d+$")
        self.assertEqual(found["id"], "e5")
        self.assertEqual(found["cue"], "BRK_2")

    def test_current_break_is_detected_and_does_not_advance(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e5"]}
            FakeOntimeHandler.rundown = rundown
            config = break_sync.Config(
                ontime_base_url=fake.base_url,
                break_cue_regex=r"^BRK_\d+$",
                dry_run=False,
                debounce_seconds=0,
                request_timeout_seconds=1,
            )
            result = break_sync.sync_to_next_break(config)
            self.assertEqual(result["status"], "ignored")
            self.assertEqual(result["reason"], "already_on_break")
            self.assertEqual(FakeOntimeHandler.start_requests, [])

    def test_live_mode_starts_next_break_by_event_id(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e2"]}
            FakeOntimeHandler.rundown = rundown
            config = break_sync.Config(
                ontime_base_url=fake.base_url,
                break_cue_regex=r"^BRK_\d+$",
                dry_run=False,
                debounce_seconds=0,
                request_timeout_seconds=1,
            )
            result = break_sync.sync_to_next_break(config)
            self.assertEqual(result["status"], "started")
            self.assertEqual(result["cue"], "BRK_2")
            self.assertEqual(FakeOntimeHandler.start_requests, ["/api/start/id/e5"])

    def test_dry_run_never_starts_ontime(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e2"]}
            FakeOntimeHandler.rundown = rundown
            config = break_sync.Config(
                ontime_base_url=fake.base_url,
                break_cue_regex=r"^BRK_\d+$",
                dry_run=True,
                debounce_seconds=0,
                request_timeout_seconds=1,
            )
            result = break_sync.sync_to_next_break(config)
            self.assertEqual(result["status"], "dry_run")
            self.assertEqual(result["cue"], "BRK_2")
            self.assertEqual(FakeOntimeHandler.start_requests, [])

    def test_custom_regex_can_define_different_break_cues(self):
        rundown = make_rundown()
        rundown["entries"]["e5"]["cue"] = "PAUZA-02"
        found = break_sync.find_next_break(rundown, "e2", r"^PAUZA-\d+$")
        self.assertEqual(found["id"], "e5")

    def test_missing_current_event_fails_closed(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": None}
            FakeOntimeHandler.rundown = rundown
            config = break_sync.Config(
                ontime_base_url=fake.base_url,
                break_cue_regex=r"^BRK_\d+$",
                dry_run=False,
                debounce_seconds=0,
                request_timeout_seconds=1,
            )
            result = break_sync.sync_to_next_break(config)
            self.assertEqual(result["status"], "ignored")
            self.assertEqual(result["reason"], "no_current_event")
            self.assertEqual(FakeOntimeHandler.start_requests, [])

    def test_config_defaults_match_brk_number_format(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "config.json"
            path.write_text(json.dumps({"ontime_base_url": "https://ontime.example.com"}), encoding="utf-8")
            config = break_sync.load_config(path)
            self.assertEqual(config.break_cue_regex, r"^BRK_\d+$")
            self.assertTrue(config.dry_run)
            self.assertEqual(config.debounce_seconds, 2.0)


class LocalHelperServerTests(unittest.TestCase):
    def test_break_endpoint_runs_sync_and_returns_json(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e2"]}
            FakeOntimeHandler.rundown = rundown
            config = break_sync.Config(
                ontime_base_url=fake.base_url,
                break_cue_regex=r"^BRK_\d+$",
                dry_run=True,
                debounce_seconds=0,
                request_timeout_seconds=1,
            )
            server = break_sync.create_local_server(config, host="127.0.0.1", port=0)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                host, port = server.server_address
                from urllib.request import urlopen
                with urlopen(f"http://{host}:{port}/break", timeout=2) as response:
                    payload = json.loads(response.read().decode("utf-8"))
                self.assertEqual(payload["status"], "dry_run")
                self.assertEqual(payload["cue"], "BRK_2")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_second_break_trigger_inside_debounce_window_is_ignored(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e2"]}
            FakeOntimeHandler.rundown = rundown
            config = break_sync.Config(
                ontime_base_url=fake.base_url,
                break_cue_regex=r"^BRK_\d+$",
                dry_run=True,
                debounce_seconds=10,
                request_timeout_seconds=1,
            )
            server = break_sync.create_local_server(config, host="127.0.0.1", port=0)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                host, port = server.server_address
                from urllib.request import urlopen
                with urlopen(f"http://{host}:{port}/break", timeout=2) as response:
                    first = json.loads(response.read().decode("utf-8"))
                with urlopen(f"http://{host}:{port}/break", timeout=2) as response:
                    second = json.loads(response.read().decode("utf-8"))
                self.assertEqual(first["status"], "dry_run")
                self.assertEqual(second, {"status": "ignored", "reason": "debounce"})
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)

    def test_health_endpoint_checks_ontime_version(self):
        with FakeOntimeServer() as fake:
            config = break_sync.Config(
                ontime_base_url=fake.base_url,
                break_cue_regex=r"^BRK_\d+$",
                dry_run=True,
                debounce_seconds=0,
                request_timeout_seconds=1,
            )
            server = break_sync.create_local_server(config, host="127.0.0.1", port=0)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                host, port = server.server_address
                from urllib.request import urlopen
                with urlopen(f"http://{host}:{port}/health", timeout=2) as response:
                    payload = json.loads(response.read().decode("utf-8"))
                self.assertEqual(payload["status"], "ok")
                self.assertEqual(payload["ontime_version"], "4.8.0")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


class VenObsUtilsConfigTests(unittest.TestCase):
    def test_nested_config_schema_is_supported(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "config.json"
            path.write_text(json.dumps({
                "ontime": {
                    "base_url": "https://ontime.example.com/",
                    "break_cue_regex": r"^PAUZA_\d+$",
                    "request_timeout_seconds": 4
                },
                "server": {"host": "127.0.0.1", "port": 9876},
                "safety": {"dry_run": False, "debounce_seconds": 1.5}
            }), encoding="utf-8")
            config = break_sync.load_config(path)
            self.assertEqual(config.ontime_base_url, "https://ontime.example.com")
            self.assertEqual(config.break_cue_regex, r"^PAUZA_\d+$")
            self.assertFalse(config.dry_run)
            self.assertEqual(config.debounce_seconds, 1.5)
            self.assertEqual(config.request_timeout_seconds, 4)
            self.assertEqual(config.server_host, "127.0.0.1")
            self.assertEqual(config.server_port, 9876)


class VenObsUtilsStatusTests(unittest.TestCase):
    def test_namespaced_break_endpoint_is_supported_and_status_reports_last_action(self):
        rundown = make_rundown()
        with FakeOntimeServer() as fake:
            FakeOntimeHandler.runtime = {"eventNow": rundown["entries"]["e2"]}
            FakeOntimeHandler.rundown = rundown
            config = break_sync.Config(
                ontime_base_url=fake.base_url,
                break_cue_regex=r"^BRK_\d+$",
                dry_run=True,
                debounce_seconds=0,
                request_timeout_seconds=1,
            )
            server = break_sync.create_local_server(config, host="127.0.0.1", port=0)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                host, port = server.server_address
                from urllib.request import urlopen
                with urlopen(f"http://{host}:{port}/ontime/break", timeout=2) as response:
                    trigger = json.loads(response.read().decode("utf-8"))
                self.assertEqual(trigger["status"], "dry_run")
                self.assertEqual(trigger["cue"], "BRK_2")

                with urlopen(f"http://{host}:{port}/status", timeout=2) as response:
                    status = json.loads(response.read().decode("utf-8"))
                self.assertEqual(status["status"], "ok")
                self.assertEqual(status["ontime"], "connected")
                self.assertEqual(status["ontime_version"], "4.8.0")
                self.assertEqual(status["mode"], "dry_run")
                self.assertEqual(status["break_cue_regex"], r"^BRK_\d+$")
                self.assertEqual(status["last_action"]["cue"], "BRK_2")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
