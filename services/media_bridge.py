"""MPS outputs owned by the existing helper; never connects to OBS."""
from __future__ import annotations

import copy
import json
import logging
import math
import os
import string
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Callable
from urllib.parse import quote
from urllib.error import HTTPError

LOG = logging.getLogger("ontime-break-sync")
_FLAGS = {"remaining_known": "remaining_ms", "playlist_remaining_known": "playlist_remaining_ms", "items_remaining_known": "items_remaining"}


def unavailable(reason: str) -> dict[str, Any]:
    return {"schema_version": 1, "available": False, "stale": True, "reason": reason,
            "remaining_known": False, "playlist_remaining_known": False, "items_remaining_known": False}


def _integer(value: Any) -> bool:
    return type(value) is int and 0 <= value <= 2**63 - 1


def validate_snapshot(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or type(value.get("schema_version")) is not int or value["schema_version"] != 1:
        raise ValueError("unsupported_schema")
    for key, item in value.items():
        if item is None or isinstance(item, (dict, list)):
            raise ValueError("invalid_snapshot_field")
    for flag, field in _FLAGS.items():
        if type(value.get(flag)) is not bool:
            raise ValueError("invalid_known_flag")
        if value[flag]:
            if not _integer(value.get(field)):
                raise ValueError("invalid_known_value")
        elif field in value:
            raise ValueError("unknown_value_must_be_absent")
    available = value.get("available", True)
    stale = value.get("stale", False)
    if type(available) is not bool or type(stale) is not bool:
        raise ValueError("invalid_availability")
    if not available or stale:
        if available or not stale or any(value[flag] for flag in _FLAGS):
            raise ValueError("invalid_unavailable_snapshot")
        if not isinstance(value.get("reason"), str) or not value["reason"]:
            raise ValueError("missing_unavailable_reason")
        return unavailable(value["reason"])
    for field in ("source_uuid", "source_name"):
        if not isinstance(value.get(field), str) or not value[field]:
            raise ValueError("missing_source_identity")
    if not _integer(value.get("snapshot_revision")):
        raise ValueError("invalid_revision")
    if value.get("state") not in {"playing", "paused", "stopped", "ended", "unknown"}:
        raise ValueError("invalid_state")
    for field in ("current_item_id", "current_path", "current_file"):
        if field in value and (not isinstance(value[field], str) or not value[field] or "\x00" in value[field]):
            raise ValueError("invalid_identity")
    for field in ("elapsed_media_ms", "duration_media_ms", "playlist_index", "folder_item_index", "speed_percent"):
        if field in value and not _integer(value[field]):
            raise ValueError("invalid_media_value")
    if value.get("speed_percent") == 0:
        raise ValueError("invalid_speed")
    for field in ("has_next", "has_previous", "shuffle", "loop"):
        if field in value and type(value[field]) is not bool:
            raise ValueError("invalid_boolean")
    return {**copy.deepcopy(value), "available": True, "stale": False}



def _validated_config(value: Any) -> dict:
    if not isinstance(value, dict):
        raise ValueError("media_bridge_config_must_be_object")
    config = copy.deepcopy(value)
    if "enabled" in config and type(config["enabled"]) is not bool:
        raise ValueError("invalid_enabled")
    if not config.get("enabled", False):
        return {"enabled": False}
    mode = config.get("source_mode", "follow_program")
    if not isinstance(mode, str) or mode not in {"explicit", "follow_program"}:
        raise ValueError("invalid_source_mode")
    for field in ("source_uuid", "source_name"):
        if field in config and not isinstance(config[field], str):
            raise ValueError("invalid_source_identity")
    if mode == "explicit" and not (config.get("source_uuid") or config.get("source_name")):
        raise ValueError("missing_source_identity")
    for section in ("txt", "json", "timer"):
        if section in config and not isinstance(config[section], dict):
            raise ValueError(f"invalid_{section}_config")
    for section, field in ((config, "enabled"), (config.get("txt", {}), "enabled"),
                           (config.get("json", {}), "enabled"),
                           (config.get("timer", {}), "change_stage_timer_secondary_source")):
        if field in section and type(section[field]) is not bool:
            raise ValueError(f"invalid_{field}")
    timer = config.get("timer", {})
    for field, allowed, default in (
        ("media_timer_source", {"off", "current_item", "playlist"}, "off"),
        ("ontime_output", {"auxiliary_timer", "secondary_message"}, "auxiliary_timer"),
        ("inactive_policy", {"stop", "keep_last"}, "stop"),
    ):
        if not isinstance(timer.get(field, default), str) or timer.get(field, default) not in allowed:
            raise ValueError(f"invalid_{field}")
    index = timer.get("aux_timer_index", 1)
    if type(index) is not int or index not in {1, 2, 3}:
        raise ValueError("invalid_aux_timer_index")
    template = timer.get("secondary_message_template", "{current_file}")
    if not isinstance(template, str) or len(template) > 2048:
        raise ValueError("invalid_secondary_template")
    fields = {"current_file", "remaining_hhmmss", "playlist_remaining_hhmmss"}
    if any(field not in fields or spec or conversion
           for _, field, spec, conversion in string.Formatter().parse(template) if field is not None):
        raise ValueError("invalid_secondary_template")
    txt = config.get("txt", {})
    if (not isinstance(txt.get("clear_policy", "clear_when_inactive"), str) or
            txt.get("clear_policy", "clear_when_inactive") not in {"clear_when_inactive", "keep_last"}):
        raise ValueError("invalid_txt_clear_policy")
    for section in ("txt", "json"):
        export = config.get(section, {})
        if export.get("enabled", False):
            path = export.get("path")
            if not isinstance(path, str) or not Path(path).is_absolute() or "\x00" in path:
                raise ValueError("export_path_must_be_absolute")
    if (txt.get("enabled") and config.get("json", {}).get("enabled") and
            txt["path"] == config["json"]["path"]):
        raise ValueError("export_paths_must_differ")
    return config


def _output_identity(snapshot: dict) -> dict:
    return {key: value for key, value in snapshot.items()
            if key not in {"elapsed_media_ms", "remaining_ms", "playlist_remaining_ms"}}


def _atomic_write(path: str, text: str) -> None:
    target = Path(path)
    if not target.is_absolute() or "\x00" in path:
        raise ValueError("export_path_must_be_absolute")
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=target.parent, delete=False) as handle:
            temporary = handle.name
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)


def _clock(ms: int | None) -> str:
    if ms is None:
        return "--:--"
    seconds = ms // 1000
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02}:{minutes:02}:{seconds:02}"


class MediaBridge:
    """One bounded output worker; ingestion and status never wait for Ontime."""

    def __init__(self, config: dict, dry_run: bool, ontime_get: Callable[[str], Any],
                 *, ownership_path: Path | None = None, target_id: str = ""):
        self.config = _validated_config(config)
        if type(dry_run) is not bool:
            raise ValueError("invalid_dry_run")
        self.dry_run = dry_run
        self._get = ontime_get
        self._lock = threading.Lock()
        self._output_lock = threading.Lock()
        self._wake = threading.Event()
        self._closed = threading.Event()
        self._thread: threading.Thread | None = None
        self._session: str | None = None
        self._session_epoch = -1
        self._retired: set[str] = set()
        self._sequence = -1
        self._snapshot = unavailable("waiting_for_snapshot" if config.get("enabled") else "disabled")
        self._received = 0.0
        self._version = 0
        self._output_generation = 0
        self._processed = -1
        self._last_ontime_action: dict | None = None
        self._last_ontime_request: dict | None = None
        self._output_error: str | None = None
        self._last_txt: str | None = None
        self._last_json: str | None = None
        self._last_message: str | None = None
        self._message_sent_at = float("-inf")
        self._message_due: float | None = None
        self._timer_signature: tuple | None = None
        self._timer_state: str | None = None
        self._timer_owned = False
        self._secondary_selected = False
        self._ownership_path = ownership_path
        self._target_id = target_id
        self._recovery = None
        self._recovery_due = 0.0
        self._recovery_error = "timer_recovery_required"
        if ownership_path and ownership_path.exists():
            try:
                record = json.loads(ownership_path.read_text(encoding="utf-8"))
                if (not isinstance(record, dict) or type(record.get("index")) is not int or
                        record["index"] not in {1, 2, 3} or not isinstance(record.get("target"), str)):
                    raise ValueError("invalid_timer_journal")
                self._recovery = record
            except (OSError, ValueError):
                self._recovery = {"target": None}


    def reset_session(self, session: str, epoch: int | None = None) -> dict:
        if not isinstance(session, str) or not session or len(session) > 128:
            raise ValueError("invalid_session")
        with self._lock:
            if epoch is None:
                epoch = self._session_epoch + 1
            if not _integer(epoch):
                raise ValueError("invalid_session_epoch")
            if epoch < self._session_epoch or (epoch == self._session_epoch and session != self._session):
                raise ValueError("older_session_epoch")
            if session == self._session:
                return {"status": "success", "session": session}
            if session in self._retired:
                raise ValueError("retired_session")
            if self._session:
                self._retired.add(self._session)
            self._session_epoch = epoch
            self._session = session
            self._sequence = -1
            self._snapshot = unavailable("waiting_for_snapshot")
            self._received = 0
            self._version += 1
            self._output_generation += 1
        self._wake.set()
        return {"status": "success", "session": session}

    def ingest(self, envelope: dict) -> dict:
        if not self.config.get("enabled", False):
            return {"status": "ignored", "reason": "disabled"}
        if not isinstance(envelope, dict) or not _integer(envelope.get("sequence")):
            raise ValueError("invalid_envelope")
        snapshot = validate_snapshot(envelope.get("snapshot"))
        with self._lock:
            if not self._session or envelope.get("session") != self._session:
                raise ValueError("wrong_session")
            if envelope["sequence"] <= self._sequence:
                return {"status": "ignored", "reason": "older_sequence"}
            old = self._snapshot
            if (snapshot.get("available") and old.get("available") and
                    snapshot.get("source_uuid") == old.get("source_uuid") and
                    snapshot["snapshot_revision"] < old["snapshot_revision"]):
                return {"status": "ignored", "reason": "older_revision"}
            self._sequence = envelope["sequence"]
            self._snapshot = snapshot
            if _output_identity(snapshot) != _output_identity(old):
                self._output_generation += 1
            self._received = time.monotonic()
            self._version += 1
        self._wake.set()
        return {"status": "success"}

    def heartbeat(self, envelope: dict) -> dict:
        """Renew transport liveness without treating an old snapshot as new data."""
        with self._lock:
            self._expire_locked()
            if (not isinstance(envelope, dict) or not self._session or
                    envelope.get("session") != self._session or not _integer(envelope.get("sequence"))):
                raise ValueError("invalid_heartbeat")
            if not self._snapshot.get("available"):
                raise ValueError("snapshot_required")
            if envelope["sequence"] <= self._sequence:
                return {"status": "ignored", "reason": "older_sequence"}
            self._sequence = envelope["sequence"]
            self._received = time.monotonic()
            if self._output_error:
                self._processed = -1
        self._wake.set()
        return {"status": "success"}

    def _save_ownership(self, index: int) -> None:
        if self._ownership_path and not self.dry_run:
            _atomic_write(str(self._ownership_path), json.dumps({"target": self._target_id, "index": index}))
            directory = os.open(self._ownership_path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)

    def _clear_ownership(self) -> None:
        if self._ownership_path and not self.dry_run:
            self._ownership_path.unlink(missing_ok=True)

    def _recover_timer(self) -> None:
        if not self._recovery:
            return
        if time.monotonic() < self._recovery_due:
            raise ValueError(self._recovery_error)
        self._recovery_due = time.monotonic() + 2
        self._recovery_error = "timer_recovery_required"
        if self.dry_run:
            raise ValueError(self._recovery_error)
        if self._recovery.get("target") != self._target_id:
            self._recovery_error = "timer_recovery_target_changed"
            raise ValueError(self._recovery_error)
        poll = self._request("/api/poll")
        if isinstance(poll, dict) and isinstance(poll.get("payload"), dict):
            poll = poll["payload"]
        runtime = poll.get(f"auxtimer{self._recovery['index']}") if isinstance(poll, dict) else None
        # Ontime 4 has no exclusive owner token; elapsed/duration cannot prove ownership.
        if not isinstance(runtime, dict) or runtime.get("playback") != "stop":
            raise ValueError("timer_recovery_required")
        self._clear_ownership()
        self._recovery = None

    def _expire_locked(self) -> None:
        if self._message_due is not None and time.monotonic() >= self._message_due:
            self._message_due = None
            self._processed = -1
        if self._received and time.monotonic() - self._received > 6 and self._snapshot.get("available"):
            self._snapshot = unavailable("stale_telemetry")
            self._output_generation += 1
            self._version += 1
            self._wake.set()

    def status(self, private: bool = False) -> dict:
        with self._lock:
            self._expire_locked()
            state = copy.deepcopy(self._snapshot)
            if not private:
                state.pop("current_path", None)
            if self._recovery:
                state["recovery_timer_index"] = self._recovery.get("index")
                state["recovery_target_changed"] = self._recovery.get("target") != self._target_id
            if self._last_ontime_action:
                state["last_ontime_action"] = copy.deepcopy(self._last_ontime_action)
            if self._last_ontime_request:
                state["last_ontime_request"] = copy.deepcopy(self._last_ontime_request)
            timer = self.config.get("timer", {})
            mode = timer.get("media_timer_source", "off")
            state["ontime_output"] = timer.get("ontime_output", "auxiliary_timer")
            state["media_timer_source"] = mode
            if self._recovery:
                state["output_status"] = "error"
            elif not self.config.get("enabled"):
                state["output_status"] = "disabled"
            elif mode == "off":
                state["output_status"] = "off"
            elif self._output_error:
                state["output_status"] = "error"
            elif not state.get("available"):
                state["output_status"] = "waiting_for_snapshot"
            elif state.get("state") not in {"playing", "paused"}:
                state["output_status"] = "inactive"
            elif (timer.get("ontime_output", "auxiliary_timer") == "auxiliary_timer" and
                  not state.get("remaining_known" if mode == "current_item" else "playlist_remaining_known")):
                state["output_status"] = "unknown_remaining"
            elif self.dry_run:
                state["output_status"] = "dry_run"
            elif self._processed != self._version:
                state["output_status"] = "pending"
            else:
                state["output_status"] = "synced"
            if self._output_error:
                state["output_error"] = self._output_error
            return state

    def ontime_unavailable(self) -> None:
        with self._lock:
            if not self.config.get("enabled") or self.config.get("timer", {}).get("media_timer_source", "off") == "off":
                return
            self._output_error = "ontime_unreachable"
            self._processed = -1
            self._last_message = None
            self._secondary_selected = False
        self._wake.set()

    def current_file(self) -> str:
        state = self.status()
        return self._filename(state)

    @staticmethod
    def _filename(state: dict) -> str:
        if not state.get("available") or state.get("stale") or state.get("state") not in {"playing", "paused"}:
            return ""
        name = state.get("current_file", "")
        return name.replace("\\", "/").rsplit("/", 1)[-1].replace("\r", " ").replace("\n", " ")

    def start(self) -> None:
        if (not self.config.get("enabled") and not self._recovery) or self._thread:
            return
        self._thread = threading.Thread(target=self._run, name="mps-outputs", daemon=True)
        self._thread.start()

    def close(self) -> None:
        with self._lock:
            self._snapshot = unavailable("shutdown")
            self._output_generation += 1
            self._version += 1
        self._closed.set()
        self._wake.set()
        if self._thread:
            self._thread.join()
            self._thread = None
        else:
            self.process_outputs()

    def _run(self) -> None:
        while True:
            with self._lock:
                self._expire_locked()
                deadlines = []
                if self._recovery:
                    deadlines.append(self._recovery_due)
                if self._received and self._snapshot.get("available"):
                    deadlines.append(self._received + 6.01)
                if self._message_due is not None:
                    deadlines.append(self._message_due)
                timeout = max(0.01, min(deadlines) - time.monotonic()) if deadlines else None
                pending = self._processed != self._version or (self._recovery and time.monotonic() >= self._recovery_due)
            if pending:
                self.process_outputs()
            if self._closed.is_set():
                self.process_outputs()
                return
            self._wake.wait(timeout)
            self._wake.clear()

    def process_outputs(self) -> None:
        """Synchronous test seam; production calls this only on its worker."""
        with self._output_lock:
            with self._lock:
                self._expire_locked()
                state = copy.deepcopy(self._snapshot)
                version = self._version
                self._working_generation = self._output_generation
                if self._processed == version and not self._recovery:
                    return
            errors = []
            for operation in (self._export, self._sync_timer):
                try:
                    operation(state)
                except Exception as exc:
                    LOG.warning("MPS output failed: %s", exc)
                    if isinstance(exc, HTTPError):
                        errors.append(f"ontime_http_{exc.code}")
                    elif isinstance(exc, ValueError):
                        errors.append(str(exc)[:256])
                    elif isinstance(exc, InterruptedError):
                        errors.append("snapshot_superseded")
                    else:
                        errors.append("export_failed" if operation == self._export else "ontime_request_failed")
            with self._lock:
                self._processed = version
                self._output_error = "; ".join(errors) if errors else None

    def _export(self, state: dict) -> None:
        if not self.config.get("enabled", False):
            return
        txt = self.config.get("txt", {})
        if txt.get("enabled", False):
            name = self._filename(state)
            if name or txt.get("clear_policy", "clear_when_inactive") != "keep_last":
                text = name + "\n" if name else ""
                if text != self._last_txt:
                    _atomic_write(txt.get("path", ""), text)
                    self._last_txt = text
        export = self.config.get("json", {})
        if export.get("enabled", False):
            # Clock progress alone must not generate per-second filesystem writes.
            stable = {key: value for key, value in state.items()
                      if key not in {"elapsed_media_ms", "remaining_ms", "playlist_remaining_ms"}}
            signature = json.dumps(stable, ensure_ascii=False, sort_keys=True)
            if signature != self._last_json:
                _atomic_write(export.get("path", ""), json.dumps(state, ensure_ascii=False, sort_keys=True) + "\n")
                self._last_json = signature

    def _request(self, path: str) -> Any:
        try:
            result = self._get(path)
        except Exception as exc:
            attempt = {"status": "error", "path": path,
                       "reason": "http_error" if isinstance(exc, HTTPError) else "request_failed"}
            if isinstance(exc, HTTPError):
                attempt["http_status"] = exc.code
            with self._lock:
                self._last_ontime_request = attempt
                if path != "/api/poll":
                    self._last_ontime_action = copy.deepcopy(attempt)
            raise
        with self._lock:
            self._last_ontime_request = {"status": "success", "path": path}
        return result

    def _action(self, path: str) -> None:
        with self._lock:
            self._expire_locked()
            if self._output_generation != self._working_generation:
                raise InterruptedError("snapshot_superseded")
        if not self.dry_run:
            self._request(path)
        with self._lock:
            self._last_ontime_action = {"status": "dry_run" if self.dry_run else "success", "path": path}

    def _sync_timer(self, state: dict) -> None:
        self._recover_timer()
        timer = self.config.get("timer", {})
        mode = timer.get("media_timer_source", "off")
        if not self.config.get("enabled", False) or mode == "off":
            return
        if mode not in {"current_item", "playlist"}:
            raise ValueError("invalid_timer_source")
        field = "remaining_ms" if mode == "current_item" else "playlist_remaining_ms"
        known = "remaining_known" if mode == "current_item" else "playlist_remaining_known"
        active = (state.get("available") and not state.get("stale") and
                  state.get("state") in {"playing", "paused"})
        if timer.get("ontime_output", "auxiliary_timer") == "secondary_message":
            self._secondary(state, timer, bool(active))
            return
        valid = active and state.get(known)
        index = timer.get("aux_timer_index", 1)
        if type(index) is not int or index not in {1, 2, 3}:
            raise ValueError("invalid_aux_timer_index")
        prefix = f"/api/auxtimer/{index}"
        if not valid:
            if self._timer_owned:
                if timer.get("inactive_policy", "stop") == "keep_last":
                    self._action(prefix + "/pause")
                else:
                    self._action(prefix + "/stop")
                self._clear_ownership()
                self._timer_owned = False
                self._timer_signature = None
                self._timer_state = None
            return
        target = state[field]
        desired = "pause" if state["state"] == "paused" else "play"
        signature = (state.get("source_uuid"), state.get("current_item_id"), state.get("speed_percent"), state.get("snapshot_revision"))
        runtime = None
        if not self.dry_run:
            poll = self._request("/api/poll")
            if isinstance(poll, dict) and isinstance(poll.get("payload"), dict):
                poll = poll["payload"]
            runtime = poll.get(f"auxtimer{index}") if isinstance(poll, dict) else None
            if (not isinstance(runtime, dict) or (type(runtime.get("current")) not in {int, float} or
                    not math.isfinite(runtime["current"])) or
                    runtime.get("playback") not in {"start", "play", "pause", "stop"}):
                raise ValueError("aux_timer_unavailable")
            runtime = {**runtime, "playback": "play" if runtime["playback"] == "start" else runtime["playback"]}
        if not self._timer_owned and runtime is not None and runtime["playback"] != "stop":
            raise ValueError("aux_timer_in_use")
        changed = self._timer_signature != signature
        state_change = self._timer_state != state["state"]
        aligned = runtime is None or (abs(runtime["current"] - target) <= 1500 and runtime.get("direction") == "count-down")
        rebase = not self._timer_owned or not aligned or (changed and not state_change)
        if rebase:
            if not self._timer_owned:
                self._save_ownership(index)
            # Stop before changing duration: never rely on running-duration semantics.
            try:
                self._action(prefix + "/stop")
            except InterruptedError:
                if not self._timer_owned:
                    self._clear_ownership()
                raise
            self._timer_owned = True
            self._timer_signature = signature
            self._timer_state = state["state"]
            self._action(prefix + "/direction/count-down")
            self._action(prefix + f"/duration/{target}")
            self._action(prefix + "/start")
            if desired == "pause":
                self._action(prefix + "/pause")
        elif state_change or (runtime is not None and runtime["playback"] != desired):
            self._action(prefix + ("/pause" if desired == "pause" else "/start"))
        if timer.get("change_stage_timer_secondary_source", False) and not self._secondary_selected:
            self._action(f"/api/message/timer?secondarySource=aux{index}")
            self._secondary_selected = True
        self._timer_owned = True
        self._timer_signature = signature
        self._timer_state = state["state"]

    def _secondary(self, state: dict, timer: dict, valid: bool) -> None:
        if not valid and timer.get("inactive_policy", "stop") == "keep_last":
            return
        values = {"current_file": self._filename(state),
                  "remaining_hhmmss": _clock(state.get("remaining_ms")),
                  "playlist_remaining_hhmmss": _clock(state.get("playlist_remaining_ms"))}
        template = timer.get("secondary_message_template", "VT: {current_file} · {playlist_remaining_hhmmss}")
        if not isinstance(template, str) or len(template) > 2048:
            raise ValueError("invalid_secondary_template")
        if any(field not in values or spec or conversion for _, field, spec, conversion in string.Formatter().parse(template) if field is not None):
            raise ValueError("invalid_secondary_template")
        text = template.format(**values) if valid else ""
        if text != self._last_message:
            if valid and time.monotonic() - self._message_sent_at < 1:
                with self._lock:
                    self._message_due = self._message_sent_at + 1
                return
            self._action("/api/message/secondary/" + quote(text, safe=""))
            self._last_message = text
            self._message_sent_at = time.monotonic()
            with self._lock:
                self._message_due = None
        if timer.get("change_stage_timer_secondary_source", False) and not self._secondary_selected:
            self._action("/api/message/timer?secondarySource=secondary")
            self._secondary_selected = True
