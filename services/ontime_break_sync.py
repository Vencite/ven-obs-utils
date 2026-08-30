#!/usr/bin/env python3
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import quote
from urllib.request import Request, urlopen


DEFAULT_BREAK_CUE_REGEX = r"^BRK_\d+$"


@dataclass(frozen=True)
class Config:
    ontime_base_url: str
    break_cue_regex: str = DEFAULT_BREAK_CUE_REGEX
    dry_run: bool = True
    debounce_seconds: float = 2.0
    request_timeout_seconds: float = 3.0
    server_host: str = "127.0.0.1"
    server_port: int = 8765


def load_config(path: Path) -> Config:
    data = json.loads(path.read_text(encoding="utf-8"))

    # VEN OBS Utils schema. The legacy flat schema remains supported so an
    # existing break-sync config can be dropped in without migration first.
    if isinstance(data.get("ontime"), dict):
        ontime = data["ontime"]
        server = data.get("server") if isinstance(data.get("server"), dict) else {}
        safety = data.get("safety") if isinstance(data.get("safety"), dict) else {}
        base_url = str(ontime["base_url"]).rstrip("/")
        break_cue_regex = str(ontime.get("break_cue_regex", DEFAULT_BREAK_CUE_REGEX))
        request_timeout_seconds = float(ontime.get("request_timeout_seconds", 3.0))
        dry_run = bool(safety.get("dry_run", True))
        debounce_seconds = float(safety.get("debounce_seconds", 2.0))
        server_host = str(server.get("host", "127.0.0.1"))
        server_port = int(server.get("port", 8765))
    else:
        base_url = str(data["ontime_base_url"]).rstrip("/")
        break_cue_regex = str(data.get("break_cue_regex", DEFAULT_BREAK_CUE_REGEX))
        request_timeout_seconds = float(data.get("request_timeout_seconds", 3.0))
        dry_run = bool(data.get("dry_run", True))
        debounce_seconds = float(data.get("debounce_seconds", 2.0))
        server_host = str(data.get("server_host", "127.0.0.1"))
        server_port = int(data.get("server_port", 8765))

    re.compile(break_cue_regex)
    return Config(
        ontime_base_url=base_url,
        break_cue_regex=break_cue_regex,
        dry_run=dry_run,
        debounce_seconds=debounce_seconds,
        request_timeout_seconds=request_timeout_seconds,
        server_host=server_host,
        server_port=server_port,
    )


def _get_json(url: str, timeout: float) -> Any:
    request = Request(url, method="GET", headers={"Accept": "application/json", "User-Agent": "VEN-OBS-Utils/1.0"})
    with urlopen(request, timeout=timeout) as response:
        charset = response.headers.get_content_charset() or "utf-8"
        return json.loads(response.read().decode(charset))


def _unwrap_payload(data: Any) -> Any:
    if isinstance(data, dict) and "payload" in data:
        return data["payload"]
    return data


def _cue_matches(cue: Any, regex: str) -> bool:
    if not isinstance(cue, str):
        return False
    return re.fullmatch(regex, cue.strip()) is not None


def find_next_break(rundown: dict[str, Any], current_event_id: str, break_cue_regex: str) -> dict[str, Any] | None:
    flat_order = rundown.get("flatOrder")
    entries = rundown.get("entries")
    if not isinstance(flat_order, list) or not isinstance(entries, dict):
        return None

    try:
        current_index = flat_order.index(current_event_id)
    except ValueError:
        return None

    for entry_id in flat_order[current_index + 1 :]:
        entry = entries.get(entry_id)
        if not isinstance(entry, dict):
            continue
        if entry.get("type") != "event":
            continue
        if entry.get("skip") is True:
            continue
        if _cue_matches(entry.get("cue"), break_cue_regex):
            return entry
    return None


def sync_to_next_break(config: Config) -> dict[str, Any]:
    runtime_raw = _get_json(f"{config.ontime_base_url}/api/poll", config.request_timeout_seconds)
    runtime = _unwrap_payload(runtime_raw)
    if not isinstance(runtime, dict):
        return {"status": "ignored", "reason": "invalid_runtime"}

    current = runtime.get("eventNow")
    if not isinstance(current, dict) or not current.get("id"):
        return {"status": "ignored", "reason": "no_current_event"}

    if _cue_matches(current.get("cue"), config.break_cue_regex):
        return {
            "status": "ignored",
            "reason": "already_on_break",
            "cue": current.get("cue", ""),
            "event_id": current["id"],
        }

    rundown_raw = _get_json(f"{config.ontime_base_url}/data/rundowns/current", config.request_timeout_seconds)
    rundown = _unwrap_payload(rundown_raw)
    if not isinstance(rundown, dict):
        return {"status": "ignored", "reason": "invalid_rundown"}

    next_break = find_next_break(rundown, str(current["id"]), config.break_cue_regex)
    if next_break is None:
        return {"status": "ignored", "reason": "no_next_break"}

    result = {
        "cue": next_break.get("cue", ""),
        "event_id": next_break["id"],
        "title": next_break.get("title", ""),
    }

    if config.dry_run:
        return {"status": "dry_run", **result}

    event_id = quote(str(next_break["id"]), safe="")
    _get_json(f"{config.ontime_base_url}/api/start/id/{event_id}", config.request_timeout_seconds)
    return {"status": "started", **result}


import argparse
import logging
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


LOG = logging.getLogger("ontime-break-sync")


def check_ontime(config: Config) -> dict[str, Any]:
    version_raw = _get_json(f"{config.ontime_base_url}/api/version", config.request_timeout_seconds)
    version = _unwrap_payload(version_raw)
    return {"status": "ok", "ontime_version": str(version)}


def create_local_server(config: Config, host: str = "127.0.0.1", port: int = 8765) -> ThreadingHTTPServer:
    state_lock = threading.Lock()
    state = {"last_trigger": float("-inf"), "last_action": None}

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == "/health":
                try:
                    self._send_json(200, check_ontime(config))
                except Exception as exc:
                    LOG.error("Health check failed: %s", exc)
                    self._send_json(503, {"status": "error", "reason": "ontime_unreachable"})
                return

            if self.path == "/status":
                try:
                    health = check_ontime(config)
                    with state_lock:
                        last_action = state["last_action"]
                    self._send_json(200, {
                        "status": "ok",
                        "service": "running",
                        "ontime": "connected",
                        "ontime_version": health["ontime_version"],
                        "mode": "dry_run" if config.dry_run else "live",
                        "break_cue_regex": config.break_cue_regex,
                        "last_action": last_action,
                    })
                except Exception as exc:
                    LOG.error("Status check failed: %s", exc)
                    with state_lock:
                        last_action = state["last_action"]
                    self._send_json(503, {
                        "status": "degraded",
                        "service": "running",
                        "ontime": "disconnected",
                        "mode": "dry_run" if config.dry_run else "live",
                        "break_cue_regex": config.break_cue_regex,
                        "last_action": last_action,
                    })
                return

            if self.path not in ("/break", "/ontime/break"):
                self._send_json(404, {"status": "error", "reason": "not_found"})
                return

            now = time.monotonic()
            with state_lock:
                if now - state["last_trigger"] < config.debounce_seconds:
                    self._send_json(200, {"status": "ignored", "reason": "debounce"})
                    return
                state["last_trigger"] = now

            try:
                result = sync_to_next_break(config)
                with state_lock:
                    state["last_action"] = result
                LOG.info("Break trigger result: %s", result)
                self._send_json(200, result)
            except Exception as exc:
                LOG.exception("Break trigger failed")
                result = {"status": "error", "reason": "ontime_request_failed", "detail": str(exc)}
                with state_lock:
                    state["last_action"] = result
                self._send_json(503, result)

        def _send_json(self, status: int, payload: dict[str, Any]):
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            LOG.debug("HTTP: " + fmt, *args)

    return ThreadingHTTPServer((host, port), Handler)


def main() -> int:
    parser = argparse.ArgumentParser(description="VEN OBS Utils - Ontime break sync helper")
    parser.add_argument("--config", default="config.json", help="Path to config JSON")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", datefmt="%H:%M:%S")

    config_path = Path(args.config).expanduser().resolve()
    try:
        config = load_config(config_path)
    except Exception as exc:
        LOG.error("Cannot load config %s: %s", config_path, exc)
        return 2

    try:
        health = check_ontime(config)
        LOG.info("Ontime connected: version %s", health["ontime_version"])
    except Exception as exc:
        LOG.warning("Ontime health check failed at startup: %s", exc)

    LOG.info("Break CUE regex: %s", config.break_cue_regex)
    LOG.info("Mode: %s", "DRY RUN" if config.dry_run else "LIVE")
    LOG.info("Listening only on http://%s:%s", config.server_host, config.server_port)

    try:
        server = create_local_server(config, host=config.server_host, port=config.server_port)
        server.serve_forever()
    except KeyboardInterrupt:
        LOG.info("Stopping")
    except OSError as exc:
        LOG.error("Cannot start local server: %s", exc)
        return 3
    finally:
        if "server" in locals():
            server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
