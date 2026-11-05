import json
import os
import sys
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services"))
import ontime_break_sync as helper


class MediaHTTPTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {"VEN_MEDIA_IPC_TOKEN": "private-token", "VEN_MEDIA_CONTROL_TOKEN": "control-token"})
        self.env.start()
        self.server = helper.create_local_server(helper.Config(ontime_base_url="http://unused.invalid", media_bridge={"enabled": True}), port=0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.env.stop()

    def call(self, path, body=None, token=None, method=None):
        headers = {"Authorization": "Bearer " + token} if token else {}
        data = json.dumps(body).encode() if body is not None else None
        request = Request(self.url + path, data=data, headers=headers, method=method)
        try:
            response = urlopen(request, timeout=3)
        except HTTPError as error:
            response = error
        with response:
            raw = response.read()
            if "application/json" in response.headers.get("Content-Type", ""):
                raw = json.loads(raw)
            return response.status, raw

    def snapshot(self):
        return {"schema_version": 1, "available": True, "stale": False, "source_uuid": "uuid", "source_name": "MPS",
                "snapshot_revision": 1, "state": "playing", "current_item_id": "a", "current_file": "żółć.mp4",
                "current_path": "/private/żółć.mp4", "remaining_known": True, "remaining_ms": 1000,
                "playlist_remaining_known": False, "items_remaining_known": True, "items_remaining": 2,
                "shuffle": True, "loop": True, "has_next": True, "has_previous": False}

    def ingest(self):
        self.assertEqual(self.call("/media/_session", {"session": "run"}, "private-token")[0], 200)
        self.assertEqual(self.call("/media/_snapshot", {"session": "run", "sequence": 1, "snapshot": self.snapshot()}, "private-token")[0], 200)

    def test_private_ingestion_requires_separate_token(self):
        for token in [None, "control-token", "wrong"]:
            self.assertEqual(self.call("/media/_session", {"session": "run"}, token)[0], 403)
        self.assertEqual(self.call("/media/_status")[0], 403)
        self.assertEqual(self.call("/media/_status", token="control-token")[0], 403)

    def test_status_works_without_ontime_and_hides_path(self):
        self.ingest()
        code, state = self.call("/media/_status", token="private-token")
        self.assertEqual(code, 200)
        self.assertTrue(state["available"])
        self.assertNotIn("current_path", state)
        self.assertNotIn("playlist_remaining_ms", state)
        self.assertEqual(state["current_file"], "żółć.mp4")
        self.assertEqual(self.call("/media/current-file")[0], 404)
        self.assertEqual(self.call("/media/status")[0], 404)

    def test_public_controls_are_removed_even_with_old_token(self):
        self.ingest()
        for action in ["play", "pause", "next", "previous", "restart", "stop"]:
            for token in ["private-token", "control-token", None]:
                self.assertEqual(self.call("/media/" + action, {}, token)[0], 404)
        self.assertEqual(self.call("/media/_controls", token="private-token")[0], 404)

    def test_wrong_methods_and_invalid_state(self):
        self.assertEqual(self.call("/media/next")[0], 404)
        self.assertEqual(self.call("/media/_snapshot", [], "private-token")[0], 400)
        state = self.snapshot()
        state["playlist_remaining_ms"] = 0
        self.call("/media/_session", {"session": "run"}, "private-token")
        self.assertEqual(self.call("/media/_snapshot", {"session": "run", "sequence": 1, "snapshot": state}, "private-token")[0], 400)
        self.assertEqual(self.call("/media/pause", {}, "control-token")[0], 404)

    def test_connected_health_and_media_use_the_same_user_agent(self):
        started = threading.Event()
        agents = []

        class OntimeGate(BaseHTTPRequestHandler):
            def do_GET(inner):
                agent = inner.headers.get("User-Agent")
                agents.append((inner.path, agent))
                if agent != "VEN-OBS-Utils/1.0":
                    inner.send_error(403)
                    return
                if inner.path == "/api/version":
                    payload = {"payload": "4.14.0"}
                elif inner.path == "/api/poll":
                    payload = {"payload": {"auxtimer1": {"current": 300000, "duration": 300000,
                        "playback": "stop", "direction": "count-down"}}}
                else:
                    payload = {}
                    if inner.path.endswith("/start"):
                        started.set()
                data = json.dumps(payload).encode()
                inner.send_response(200)
                inner.send_header("Content-Type", "application/json")
                inner.send_header("Content-Length", str(len(data)))
                inner.end_headers()
                inner.wfile.write(data)

            def log_message(inner, *_):
                pass

        ontime = ThreadingHTTPServer(("127.0.0.1", 0), OntimeGate)
        ontime_thread = threading.Thread(target=ontime.serve_forever, daemon=True)
        ontime_thread.start()
        config = helper.Config(ontime_base_url="http://127.0.0.1:%d" % ontime.server_address[1], dry_run=False,
            media_bridge={"enabled": True, "timer": {"media_timer_source": "current_item"}})
        service = helper.create_local_server(config, port=0)
        worker = threading.Thread(target=service.serve_forever, daemon=True)
        worker.start()
        base = "http://127.0.0.1:%d" % service.server_address[1]
        try:
            with urlopen(base + "/health", timeout=2) as response:
                self.assertEqual(json.load(response)["status"], "ok")
            for path, body in [("/media/_session", {"session": "ua-test"}),
                ("/media/_snapshot", {"session": "ua-test", "sequence": 1, "snapshot": self.snapshot()})]:
                request = Request(base + path, data=json.dumps(body).encode(),
                    headers={"Authorization": "Bearer private-token", "Content-Type": "application/json"})
                with urlopen(request, timeout=2) as response:
                    self.assertEqual(response.status, 200)
            self.assertTrue(started.wait(2), "Connected health succeeded but media was blocked by the HTTP gate")
            self.assertTrue(all(agent == "VEN-OBS-Utils/1.0" for _, agent in agents))
        finally:
            service.shutdown()
            service.server_close()
            worker.join()
            ontime.shutdown()
            ontime.server_close()
            ontime_thread.join()

    def test_media_does_not_expose_existing_break_routes(self):
        with self.assertRaises(ValueError):
            helper.create_local_server(helper.Config(ontime_base_url="http://unused.invalid", media_bridge={"enabled": True}), host="0.0.0.0", port=0)


if __name__ == "__main__":
    unittest.main()
