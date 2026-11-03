import json
import os
import sys
import threading
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "services"))
import ontime_break_sync as helper


class MediaHTTPTests(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {"VEN_MEDIA_IPC_TOKEN": "private-token", "VEN_MEDIA_CONTROL_TOKEN": "control-token"})
        self.env.start()
        self.server = helper.create_local_server(helper.Config(ontime_base_url="http://unused.invalid", media_bridge={"enabled": True, "http": {"media_enabled": True}}), port=0)
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
        for token in [None, "control-token", "wrong", "żółć"]:
            if token == "żółć":
                continue  # HTTP headers use Latin-1; handler compares encoded values safely.
            self.assertEqual(self.call("/media/_session", {"session": "run"}, token)[0], 403)
        self.assertEqual(self.call("/media/_controls")[0], 403)
        self.assertEqual(self.call("/media/_controls", token="control-token")[0], 403)

    def test_status_works_without_ontime_and_hides_path(self):
        self.ingest()
        code, state = self.call("/media/status")
        self.assertEqual(code, 200)
        self.assertTrue(state["available"])
        self.assertNotIn("current_path", state)
        self.assertNotIn("playlist_remaining_ms", state)
        self.assertEqual(self.call("/media/current-file")[1], "żółć.mp4\n".encode())

    def test_control_delivered_once_and_result_observable(self):
        self.ingest()
        self.assertEqual(self.call("/media/next", {}, "private-token")[0], 403)
        code, result = self.call("/media/next", {}, "control-token")
        self.assertEqual(code, 202)
        self.assertEqual(result["status"], "queued")
        _, commands = self.call("/media/_controls", token="private-token")
        self.assertEqual(len(commands["controls"]), 1)
        self.assertEqual(commands["controls"][0]["source_uuid"], "uuid")
        self.assertEqual(self.call("/media/_controls", token="private-token")[1]["controls"], [])
        self.assertEqual(self.call("/media/_control-result", {"id": result["id"], "result": {"status": "success"}}, "private-token")[0], 200)
        self.assertEqual(self.call("/media/status")[1]["last_control"]["status"], "success")

    def test_wrong_methods_and_invalid_state(self):
        self.assertEqual(self.call("/media/next")[0], 405)
        self.assertEqual(self.call("/media/_snapshot", [], "private-token")[0], 400)
        state = self.snapshot()
        state["playlist_remaining_ms"] = 0
        self.call("/media/_session", {"session": "run"}, "private-token")
        self.assertEqual(self.call("/media/_snapshot", {"session": "run", "sequence": 1, "snapshot": state}, "private-token")[0], 400)
        self.assertEqual(self.call("/media/pause", {}, "control-token")[0], 409)

    def test_media_does_not_expose_existing_break_routes(self):
        with self.assertRaises(ValueError):
            helper.create_local_server(helper.Config(ontime_base_url="http://unused.invalid", media_bridge={"enabled": True}), host="0.0.0.0", port=0)


if __name__ == "__main__":
    unittest.main()
