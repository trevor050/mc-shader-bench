"""Capture a moving, changing-light ShaderBench route with scheduled phase trim.

This adapter intentionally has no camera scheduler. BenchCam owns route timing;
Python only loads/starts a route and polls its status/clock endpoints.
"""
from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import json
import math
import os
import re
import socket
import statistics
import struct
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Existing harness helpers are intentionally importable as both scripts and
# namespace-package modules, matching this repository's current layout.
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

try:  # Support both `py harness/dynamic_capture.py` and package-style offline tests.
    from .perf_capture import (CaptureError, attest_pack_artifact, read_active_pack,
                               validate_capture_csv)
except ImportError:
    from perf_capture import (CaptureError, attest_pack_artifact, read_active_pack,
                              validate_capture_csv)

GAME_DIR = Path(os.environ.get("APPDATA", str(Path.home() / "AppData/Roaming"))) / "PrismLauncher/instances/ShaderBench/minecraft"
PHASES = {"preparing", "armed", "streaming", "warmup", "measured", "restoring", "completed", "cancelled", "failed"}
TERMINAL = {"completed", "cancelled", "failed"}


class DynamicCaptureError(CaptureError):
    """A dynamic capture cannot be considered trustworthy."""


def canonical_route(route: dict[str, Any]) -> bytes:
    return json.dumps(route, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                      allow_nan=False).encode("utf-8")


def _finite_number(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise DynamicCaptureError(f"route {label} must be a finite number")
    return float(value)


def validate_route(route: Any) -> dict[str, Any]:
    if not isinstance(route, dict):
        raise DynamicCaptureError("route root must be an object")
    if route.get("version") != 1:
        raise DynamicCaptureError("route version must be 1")
    if not isinstance(route.get("id"), str) or not re.fullmatch(r"[a-z0-9_-]{1,64}", route["id"]):
        raise DynamicCaptureError("route id must match [a-z0-9_-]{1,64}")
    if route.get("dimension") != "minecraft:overworld":
        raise DynamicCaptureError("route dimension must be minecraft:overworld")
    duration = _finite_number(route.get("duration_s"), "duration_s")
    if not 5 <= duration <= 180:
        raise DynamicCaptureError("route duration_s must be in [5, 180]")
    points = route.get("points")
    if not isinstance(points, list) or not 5 <= len(points) <= 65:
        raise DynamicCaptureError("route points must contain 5..65 points including repeated endpoint")
    normalized_points = []
    for i, point in enumerate(points):
        if not isinstance(point, dict):
            raise DynamicCaptureError(f"route points[{i}] must be an object")
        normalized_points.append({k: _finite_number(point.get(k), f"points[{i}].{k}")
                                  for k in ("x", "y", "z", "yaw", "pitch")})
        if not -90 <= normalized_points[-1]["pitch"] <= 90:
            raise DynamicCaptureError(f"route points[{i}].pitch must be in [-90, 90]")
    for i, (left, right) in enumerate(zip(normalized_points, normalized_points[1:])):
        if abs(right["yaw"] - left["yaw"]) > 180:
            raise DynamicCaptureError(f"adjacent route yaw changes must not exceed 180 degrees (at points[{i}])")
    first, last = normalized_points[0], normalized_points[-1]
    for axis in ("x", "y", "z", "pitch"):
        if abs(first[axis] - last[axis]) > 1e-6:
            raise DynamicCaptureError(f"closed route final {axis} must match its initial value")
    yaw_delta = (last["yaw"] - first["yaw"]) / 360.0
    if abs(yaw_delta - round(yaw_delta)) > 1e-6:
        raise DynamicCaptureError("closed route final yaw must equal its initial yaw modulo 360 degrees")
    environment = route.get("environment")
    if not isinstance(environment, list) or not 2 <= len(environment) <= 64:
        raise DynamicCaptureError("route environment must contain 2..64 timeline keys")
    previous = -math.inf
    for i, item in enumerate(environment):
        if not isinstance(item, dict):
            raise DynamicCaptureError(f"route environment[{i}] must be an object")
        t = _finite_number(item.get("t_s"), f"environment[{i}].t_s")
        ticks = _finite_number(item.get("time_ticks"), f"environment[{i}].time_ticks")
        if t < 0 or t > duration or t <= previous:
            raise DynamicCaptureError("environment t_s keys must be strictly increasing within the route duration")
        previous = t
        for field in ("rain", "thunder"):
            val = _finite_number(item.get(field), f"environment[{i}].{field}")
            if not 0 <= val <= 1:
                raise DynamicCaptureError(f"environment[{i}].{field} must be in [0, 1]")
        if not 0 <= ticks <= 2_000_000_000:
            raise DynamicCaptureError(f"environment[{i}].time_ticks must be in [0, 2000000000]")
    if abs(_finite_number(environment[0].get("t_s"), "environment[0].t_s")) > 1e-9:
        raise DynamicCaptureError("environment timeline must start at t_s=0")
    if abs(previous - duration) > 1e-6:
        raise DynamicCaptureError("environment timeline must end at duration_s")
    # Force canonical serialization now so NaN or non-UTF8 oddities fail before any game command.
    canonical_route(route)
    return route


def load_catalog(path: Path, route_id: str) -> tuple[dict[str, Any], bytes, str]:
    try:
        catalog = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        raise DynamicCaptureError(f"cannot read routes catalog {path}: {exc}") from exc
    routes = catalog.get("routes") if isinstance(catalog, dict) else None
    if not isinstance(routes, list):
        raise DynamicCaptureError("routes catalog root must contain a routes array")
    matches = [r for r in routes if isinstance(r, dict) and r.get("id") == route_id]
    if len(matches) != 1:
        raise DynamicCaptureError(f"route selector {route_id!r} matched {len(matches)} entries")
    route = validate_route(matches[0])
    payload = canonical_route(route)
    return route, payload, hashlib.sha256(payload).hexdigest()


def parse_ok_json(reply: str, operation: str) -> dict[str, Any]:
    if not reply.startswith("ok "):
        raise DynamicCaptureError(f"BenchCam {operation} failed: {reply or 'no response'}")
    try:
        value = json.loads(reply[3:])
    except json.JSONDecodeError as exc:
        raise DynamicCaptureError(f"BenchCam {operation} returned invalid JSON: {reply}") from exc
    if not isinstance(value, dict):
        raise DynamicCaptureError(f"BenchCam {operation} JSON root must be an object")
    return value


def validate_gpu_profiler_idle(reply: str) -> dict[str, str]:
    """Require a drained, healthy profiler before and after acceptance timing."""
    if not reply.startswith("ok "):
        raise DynamicCaptureError(f"GPU pass profiler status failed: {reply or 'no response'}")
    fields = dict(re.findall(r"([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)", reply))
    required = {"state", "pending", "failed_reason", "restart_required",
                "unreleased_queries", "writer_error"}
    missing = sorted(required - fields.keys())
    if missing:
        raise DynamicCaptureError(f"GPU profiler status missing fields {missing}: {reply}")
    if fields["state"] not in {"idle", "closed"}:
        raise DynamicCaptureError(f"GPU profiler must be idle/closed: {reply}")
    if fields["pending"] != "0" or fields["unreleased_queries"] != "0":
        raise DynamicCaptureError(f"GPU profiler still has pending/unreleased queries: {reply}")
    if fields["failed_reason"] != "none" or fields["writer_error"] != "none":
        raise DynamicCaptureError(f"GPU profiler reports a failure: {reply}")
    if fields["restart_required"] != "false":
        raise DynamicCaptureError(f"GPU profiler requires restart: {reply}")
    return fields


class BenchProtocol:
    def __init__(self, port: int, timeout: float):
        self.port, self.timeout = port, timeout

    def command(self, line: str) -> str:
        try:
            with socket.create_connection(("127.0.0.1", self.port), timeout=self.timeout) as sock:
                sock.settimeout(self.timeout)
                sock.sendall((line + "\n").encode("utf-8"))
                stream = sock.makefile("r", encoding="utf-8")
                reply = stream.readline().strip()
        except OSError as exc:
            raise DynamicCaptureError(f"BenchCam command {line.split(' ', 1)[0]!r} failed: {exc}") from exc
        if reply.startswith("err") or not reply:
            raise DynamicCaptureError(f"BenchCam command failed: {reply or 'no response'}")
        return reply

    def json(self, line: str) -> dict[str, Any]:
        return parse_ok_json(self.command(line), line.split(" ", 1)[0])

    def clock_pair(self, qpc: "QpcClock") -> dict[str, Any]:
        before = qpc.read()
        value = self.json("route clock")
        after = qpc.read()
        try:
            mono = int(value["monotonic_ns"])
        except (KeyError, TypeError, ValueError) as exc:
            raise DynamicCaptureError("route clock lacks integer monotonic_ns") from exc
        if after < before or mono < 0:
            raise DynamicCaptureError("route clock returned invalid monotonic sample")
        return {"qpc_mid": (before + after) / 2.0, "monotonic_ns": mono,
                "rtt_qpc": after - before, "epoch_ms": value.get("epoch_ms")}


class QpcClock:
    """Windows QueryPerformanceCounter clock used only for PresentMon correlation."""
    def __init__(self):
        if os.name != "nt":
            raise DynamicCaptureError("dynamic PresentMon capture requires Windows QPC")
        import ctypes
        self.ctypes = ctypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        freq = ctypes.c_longlong()
        if not kernel.QueryPerformanceFrequency(ctypes.byref(freq)) or freq.value <= 0:
            raise DynamicCaptureError("QueryPerformanceFrequency failed")
        self.frequency = int(freq.value)
        self._counter = kernel.QueryPerformanceCounter
        self._counter.argtypes = [ctypes.POINTER(ctypes.c_longlong)]
        self._counter.restype = ctypes.c_int

    def read(self) -> int:
        value = self.ctypes.c_longlong()
        if not self._counter(self.ctypes.byref(value)):
            raise DynamicCaptureError("QueryPerformanceCounter failed")
        return int(value.value)


def fit_clock_map(samples: list[dict[str, Any]], qpc_frequency: int,
                  max_rtt_ms: float = 20.0, max_residual_ms: float = 3.0) -> dict[str, float]:
    good = [s for s in samples if s["rtt_qpc"] * 1000.0 / qpc_frequency <= max_rtt_ms]
    if len(good) < 4:
        raise DynamicCaptureError(f"only {len(good)} bounded-RTT route clock pairs; need at least four")
    xs = [float(s["qpc_mid"]) for s in good]
    ys = [float(s["monotonic_ns"]) for s in good]
    xbar, ybar = statistics.mean(xs), statistics.mean(ys)
    denom = sum((x - xbar) ** 2 for x in xs)
    if denom <= 0:
        raise DynamicCaptureError("route clock calibration has no QPC span")
    slope = sum((x - xbar) * (y - ybar) for x, y in zip(xs, ys)) / denom
    intercept = ybar - slope * xbar
    expected = 1e9 / qpc_frequency
    drift_ppm = 1e6 * (slope / expected - 1)
    residual_ms = max(abs((y - (slope * x + intercept)) / 1e6) for x, y in zip(xs, ys))
    if abs(drift_ppm) > 1000 or residual_ms > max_residual_ms:
        raise DynamicCaptureError(f"QPC/Java monotonic map failed: drift={drift_ppm:.1f} ppm, max residual={residual_ms:.3f} ms")
    return {"slope_ns_per_qpc": slope, "intercept_ns": intercept, "drift_ppm": drift_ppm,
            "max_residual_ms": residual_ms, "samples": float(len(good)),
            "max_rtt_ms": max(s["rtt_qpc"] * 1000.0 / qpc_frequency for s in good)}


def qpc_to_monotonic_ns(qpc_value: float, mapping: dict[str, float]) -> float:
    return mapping["slope_ns_per_qpc"] * qpc_value + mapping["intercept_ns"]


def parse_qpc_value(row: dict[str, str]) -> int | None:
    # --qpc_time is the explicit PresentMon flag; never fall back to ambiguous CPUStartTime ms.
    for name in ("CPUStartTime", "CPUStartQPCTime"):
        value = row.get(name)
        if value is None or not value.strip() or value.strip().casefold() == "na":
            continue
        try:
            number = float(value)
        except ValueError:
            continue
        if math.isfinite(number):
            return round(number)
    return None


def _percentiles(values: list[float]) -> dict[str, float | int]:
    values = sorted(values)
    def q(p: float) -> float:
        index = (len(values) - 1) * p
        lo, hi = math.floor(index), math.ceil(index)
        return values[lo] + (values[hi] - values[lo]) * (index - lo)
    return {"n": len(values), "min_ms": values[0], "p50_ms": q(.5), "p95_ms": q(.95),
            "p99_ms": q(.99), "max_ms": values[-1]}


def analyze_measured_csv(path: Path, pid: int, start_ns: int, end_ns: int,
                         mapping: dict[str, float], qpc_frequency: int) -> dict[str, Any]:
    if end_ns <= start_ns:
        raise DynamicCaptureError("invalid measured phase boundaries")
    with path.open("r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        headers = {name.casefold(): name for name in (reader.fieldnames or [])}
        if "processid" not in headers:
            raise DynamicCaptureError("PresentMon CSV lacks ProcessID")
        if "application" not in headers:
            raise DynamicCaptureError("PresentMon CSV lacks Application")
        rows = []
        for row in reader:
            try:
                row_pid = int(row.get(headers["processid"], ""))
            except (ValueError, TypeError):
                continue
            if row_pid != pid:
                continue
            app = (row.get(headers["application"]) or "").replace("\\", "/").rsplit("/", 1)[-1]
            if app.casefold() != "javaw.exe":
                raise DynamicCaptureError(f"PresentMon PID {pid} row belongs to {app!r}, expected javaw.exe")
            qpc = parse_qpc_value(row)
            if qpc is None:
                raise DynamicCaptureError("target PresentMon row has no numeric QPC CPUStartTime")
            mono = qpc_to_monotonic_ns(qpc, mapping)
            if start_ns <= mono < end_ns:
                rows.append((qpc, row))
    if not rows:
        raise DynamicCaptureError("no target frames fall inside scheduled measured boundaries")
    rows.sort(key=lambda pair: pair[0])
    metrics: dict[str, Any] = {"frame_rows": len(rows), "scheduled_start_ns": start_ns,
                               "scheduled_end_ns": end_ns, "measured_duration_s": (end_ns-start_ns)/1e9}
    for label, candidates in {
        "frame_time": ("FrameTime",), "gpu_busy": ("GPUBusy",), "cpu_busy": ("CPUBusy",),
        "gpu_time": ("GPUTime",), "displayed_time": ("DisplayedTime",),
    }.items():
        key = next((headers[name.casefold()] for name in candidates if name.casefold() in headers), None)
        if key is None:
            metrics[label] = {"unavailable": True}
            continue
        vals, missing = [], 0
        for _, row in rows:
            raw = (row.get(key) or "").strip()
            if not raw or raw.casefold() == "na":
                missing += 1
                continue
            try:
                value = float(raw)
            except ValueError:
                missing += 1
                continue
            if math.isfinite(value):
                vals.append(value)
            else:
                missing += 1
        metrics[label] = _percentiles(vals) if vals else {"n": 0, "unavailable": True}
        metrics[label]["missing_or_na"] = missing
    delta_ms = [((b[0] - a[0]) * 1000.0 / qpc_frequency) for a, b in zip(rows, rows[1:])]
    metrics["present_start_gaps"] = _percentiles(delta_ms) if delta_ms else {"n": 0, "unavailable": True}
    displayed = next((headers[k] for k in ("displayedtime", "msbetween display change") if k in headers), None)
    if displayed:
        not_displayed = sum((row.get(displayed) or "").strip().casefold() == "na" for _, row in rows)
        mode = headers.get("presentmode")
        runtime = headers.get("presentruntime")
        metrics["presentation"] = {"rows": len(rows), "not_displayed": not_displayed,
            "not_displayed_percent": 100.0 * not_displayed / len(rows),
            "present_modes": _counter(row.get(mode) for _, row in rows) if mode else {},
            "present_runtimes": _counter(row.get(runtime) for _, row in rows) if runtime else {}}
    return metrics


def _counter(values: Any) -> dict[str, int]:
    result: dict[str, int] = {}
    for value in values:
        key = value or "(missing)"
        result[key] = result.get(key, 0) + 1
    return result


def _status_max(statuses: list[dict[str, Any]], key: str) -> float | None:
    values = []
    for item in statuses:
        try:
            value = float(item[key])
        except (KeyError, TypeError, ValueError):
            continue
        if math.isfinite(value):
            values.append(value)
    return max(values) if values else None


def has_lost_events(output: str) -> bool:
    return bool(re.search(r"\b[1-9]\d*\s+(?:ETW\s+)?events?\s+were\s+lost\b|\blost\s+(?:[1-9]\d*\s+)?ETW\s+events?\b", output, re.I))


def qpc_clock_frequency() -> int:
    return QpcClock().frequency


def _utc() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _snapshot(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"path": str(path), "exists": False}
    raw = path.read_bytes()
    return {"path": str(path.resolve()), "exists": True,
            "sha256": hashlib.sha256(raw).hexdigest(), "text": raw.decode("utf-8-sig", "replace")}


def _active_console_session() -> int:
    import ctypes
    return int(ctypes.WinDLL("kernel32", use_last_error=True).WTSGetActiveConsoleSessionId())


def process_preflight(pid: int, game_dir: Path) -> dict[str, Any]:
    if os.name != "nt":
        raise DynamicCaptureError("physical-console javaw preflight requires Windows")
    query = (f'$p=Get-CimInstance Win32_Process -Filter "ProcessId={int(pid)}";'
             'if($null -eq $p){throw "PID not found"};'
             '[pscustomobject]@{pid=$p.ProcessId;name=$p.Name;path=$p.ExecutablePath;'
             'command=$p.CommandLine;session_id=$p.SessionId}|ConvertTo-Json -Compress')
    try:
        record = json.loads(subprocess.check_output(["powershell", "-NoProfile", "-Command", query],
                                                    text=True, stderr=subprocess.STDOUT))
    except (subprocess.SubprocessError, json.JSONDecodeError) as exc:
        raise DynamicCaptureError(f"cannot inspect target javaw PID {pid}: {exc}") from exc
    if int(record.get("pid", -1)) != pid or str(record.get("name", "")).casefold() != "javaw.exe":
        raise DynamicCaptureError(f"PID {pid} is not javaw.exe")
    active_session = _active_console_session()
    if int(record.get("session_id", -2)) != active_session:
        raise DynamicCaptureError(f"PID {pid} is in session {record.get('session_id')}, active physical console is {active_session}")
    command = str(record.get("command") or "").replace("/", "\\").casefold()
    needle = str(game_dir.resolve()).replace("/", "\\").casefold()
    if needle not in command:
        raise DynamicCaptureError(f"PID {pid} command line does not identify Prism instance path {game_dir}")
    record["active_console_session"] = active_session
    return record


def _framebuffer(bench: BenchProtocol, path: Path) -> tuple[int, int]:
    if path.exists():
        raise DynamicCaptureError(f"refusing to overwrite framebuffer evidence: {path}")
    reply = bench.command("shot " + str(path.resolve()))
    if not reply.startswith("ok"):
        raise DynamicCaptureError(f"BenchCam screenshot failed: {reply}")
    try:
        with path.open("rb") as file:
            header = file.read(24)
        if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
            raise ValueError("not a PNG")
        return struct.unpack(">II", header[16:24])
    except (OSError, ValueError, struct.error) as exc:
        raise DynamicCaptureError(f"cannot verify framebuffer screenshot {path}: {exc}") from exc


def _latest_renderer(game_log: Path) -> str:
    if not game_log.is_file():
        raise DynamicCaptureError(f"Minecraft log not found: {game_log}")
    lines = [line for line in game_log.read_text(encoding="utf-8-sig", errors="replace").splitlines()
             if "OpenGL Renderer:" in line]
    if not lines or "NVIDIA GeForce RTX 4070" not in lines[-1]:
        raise DynamicCaptureError("latest.log does not report NVIDIA GeForce RTX 4070 as the active OpenGL renderer")
    return lines[-1]


def _check_route_status(status: dict[str, Any], expected_hash: str,
                        expected_request_id: str | None = None) -> str:
    phase = status.get("phase")
    if phase not in PHASES:
        raise DynamicCaptureError(f"route status has invalid phase {phase!r}")
    if status.get("route_sha256") != expected_hash:
        raise DynamicCaptureError("BenchCam route status hash differs from loaded canonical route")
    if expected_request_id is not None and status.get("request_id") != expected_request_id:
        raise DynamicCaptureError("BenchCam route status request_id differs from this start request")
    reasons = status.get("reason_codes") or []
    # Keep a running desync in the scheduled interval; aborting here would censor
    # the rest of the frame tail. Context loss remains an immediate stop condition.
    if isinstance(reasons, list) and any(str(reason).upper() in {
            "WORLD_LOST", "SERVER_PLAYER_LOST", "CLIENT_CONTEXT_LOST"} for reason in reasons):
        raise DynamicCaptureError(f"dynamic route world/context lost: {reasons}")
    return phase


def validate_terminal_route_status(status: dict[str, Any], phase: str,
                                   expected_request_id: str | None = None) -> None:
    """Reject only after the planned run is terminal so raw measured tails are complete."""
    reasons = status.get("reason_codes") or []
    restore = status.get("restore_result")
    if phase != "completed":
        raise DynamicCaptureError(f"route finished as {phase}: {reasons}")
    if expected_request_id is not None and status.get("request_id") != expected_request_id:
        raise DynamicCaptureError("terminal route status request_id differs from this start request")
    if not isinstance(restore, dict) or restore.get("server") is not True or restore.get("client") is not True:
        raise DynamicCaptureError(f"route restoration is incomplete or malformed: {restore!r}")
    if status.get("measured_workload_valid") is not True:
        raise DynamicCaptureError(f"BenchCam marked measured workload invalid: {reasons}")
    if isinstance(reasons, list) and any(str(reason).upper() in {"CONTROL_DESYNC", "CONTROL_DESYNC_ONE_CHUNK"}
                                         for reason in reasons):
        raise DynamicCaptureError(f"measured camera control desynchronized: {reasons}")
    try:
        separation = float(status["camera_server_measured_max_distance"])
    except (KeyError, TypeError, ValueError) as exc:
        raise DynamicCaptureError("terminal route status lacks measured camera/server separation") from exc
    if not math.isfinite(separation) or separation > 16.0:
        raise DynamicCaptureError(f"measured camera/server separation is invalid: {separation}")


def cancel_route_only_if_owned(bench: Any, route_id: str, route_hash: str,
                               baseline: dict[str, Any] | None,
                               start_receipt: dict[str, Any] | None,
                               request_id: str, timeout: float,
                               poll_interval: float) -> dict[str, Any]:
    """Recover a possibly accepted start whose TCP reply was lost, without stopping another run."""
    state = bench.json("route status")
    baseline_id = baseline.get("run_id") if baseline else None
    expected_id = start_receipt.get("run_id") if start_receipt else None
    run_id = state.get("run_id")
    matches_route = (state.get("route_sha256") == route_hash and state.get("route_id") == route_id
                     and state.get("request_id") == request_id)
    matches_run = bool(run_id) and (run_id == expected_id if expected_id else run_id != baseline_id)
    if not matches_route or not matches_run:
        return {"action": "left_untouched_not_owned", "status": state}
    history = [state]
    if state.get("phase") in TERMINAL or state.get("running") is False:
        return {"action": "already_terminal", "run_id": run_id, "status_history": history}
    cancel_reply = bench.command("route cancel request_id=" + request_id)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = bench.json("route status")
        history.append(state)
        if (state.get("route_sha256") != route_hash or state.get("route_id") != route_id
                or state.get("request_id") != request_id or state.get("run_id") != run_id):
            return {"action": "ownership_changed", "run_id": run_id, "cancel_reply": cancel_reply,
                    "status_history": history}
        if state.get("phase") in TERMINAL or state.get("running") is False:
            restore = state.get("restore_result")
            return {"action": "cancelled", "run_id": run_id, "cancel_reply": cancel_reply,
                    "status_history": history,
                    "restore_verified": isinstance(restore, dict) and restore.get("server") is True and restore.get("client") is True}
        time.sleep(min(poll_interval, 0.5))
    return {"action": "cancel_timeout", "run_id": run_id, "cancel_reply": cancel_reply,
            "status_history": history}


def stop_owned_presentmon(executable: Path, session: str, process: Any,
                          timeout: float = 15.0) -> dict[str, Any]:
    """Stop and reap only this adapter's named PresentMon session, even during Ctrl+C cleanup."""
    stop_reply: dict[str, Any] = {"returncode": None, "stdout": "", "stderr": "", "error": None}
    try:
        stopped = subprocess.run([str(executable), "--terminate_existing_session", "--session_name", session],
                                  stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                  encoding="utf-8", errors="replace", timeout=timeout, check=False)
        stop_reply.update(returncode=stopped.returncode, stdout=stopped.stdout, stderr=stopped.stderr)
    except BaseException as exc:
        # Continue to reap our child; the caller preserves/rethrows the original interruption.
        stop_reply["error"] = f"{type(exc).__name__}: {exc}"
    finally:
        if process is not None:
            try:
                process_out, process_err = process.communicate(timeout=timeout)
                stop_reply["stdout"] = str(stop_reply.get("stdout") or "") + (process_out or "")
                stop_reply["stderr"] = str(stop_reply.get("stderr") or "") + (process_err or "")
            except BaseException as wait_exc:
                stop_reply["communicate_error"] = f"{type(wait_exc).__name__}: {wait_exc}"
                try:
                    process.terminate()
                    process_out, process_err = process.communicate(timeout=5.0)
                    stop_reply["stdout"] = str(stop_reply.get("stdout") or "") + (process_out or "")
                    stop_reply["stderr"] = str(stop_reply.get("stderr") or "") + (process_err or "")
                except BaseException as terminate_exc:
                    stop_reply["terminate_error"] = f"{type(terminate_exc).__name__}: {terminate_exc}"
                    try:
                        process.kill()
                        process_out, process_err = process.communicate(timeout=5.0)
                        stop_reply["stdout"] = str(stop_reply.get("stdout") or "") + (process_out or "")
                        stop_reply["stderr"] = str(stop_reply.get("stderr") or "") + (process_err or "")
                    except BaseException as kill_exc:
                        stop_reply["kill_error"] = f"{type(kill_exc).__name__}: {kill_exc}"
        stop_reply["process_returncode"] = process.poll() if process is not None else None
    return stop_reply


def build_presentmon_command(executable: Path, pid: int, csv_path: Path, session: str) -> list[str]:
    return [str(executable), "--process_id", str(pid), "--output_file", str(csv_path),
            "--session_name", session, "--v2_metrics", "--qpc_time", "--no_console_stats"]


def run_capture(args: argparse.Namespace, bench: BenchProtocol | None = None,
                qpc: QpcClock | None = None) -> dict[str, Any]:
    output = args.output.resolve()
    raw_path = output.with_suffix(".csv") if output.suffix.casefold() != ".csv" else output
    metadata_path = raw_path.with_suffix(".dynamic.capture.json")
    if raw_path.exists() or metadata_path.exists():
        raise DynamicCaptureError(f"refusing to overwrite existing capture output: {raw_path}")
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    route, payload, route_hash = load_catalog(args.routes, args.route)
    executable = args.presentmon.resolve()
    if not executable.is_file():
        raise DynamicCaptureError(f"PresentMon executable does not exist: {executable}")
    artifact = args.pack_artifact.resolve()
    if not artifact.exists():
        raise DynamicCaptureError(f"pack artifact does not exist: {artifact}")
    game_dir = args.game_dir.resolve()
    iris_path = args.iris_properties.resolve()
    game_log = args.game_log.resolve()
    process_before = process_preflight(args.pid, game_dir)
    renderer_before = _latest_renderer(game_log)
    pack_before = read_active_pack(iris_path, args.pack, game_log)
    pack_hash_before = attest_pack_artifact(iris_path, pack_before["selected_pack"], artifact,
                                            args.expected_pack_sha256)
    option_path = game_dir / "shaderpacks" / f"{args.pack}.txt"
    iris_snapshot_before, options_before = _snapshot(iris_path), _snapshot(option_path)
    bench = bench or BenchProtocol(args.benchcam_port, args.timeout)
    qpc = qpc or QpcClock()
    if args.dry_run:
        return {"dry_run": True, "mode": "preflight_only", "framebuffer_verified": False,
                "route_id": route["id"], "route_sha256": route_hash,
                "canonical_route_bytes": len(payload), "process": process_before,
                "renderer": renderer_before, "pack_sha256": pack_hash_before,
                "iris_snapshot": iris_snapshot_before, "options_snapshot": options_before,
                "resolution_requested": [args.width, args.height]}
    # Capture actual framebuffer dimensions before arming; dimensions are explicit and must agree.
    before_png = raw_path.with_suffix(".before.png")
    actual_size = _framebuffer(bench, before_png)
    if actual_size != (args.width, args.height):
        raise DynamicCaptureError(f"actual framebuffer {actual_size} differs from requested {(args.width, args.height)}")
    session = f"dynamic-{args.pid}-{uuid.uuid4().hex}"
    started_at = _utc()
    command = build_presentmon_command(executable, args.pid, raw_path, session)
    process = None
    samples: list[dict[str, Any]] = []
    status_history: list[dict[str, Any]] = []
    profiler_replies: list[dict[str, str]] = []
    start_reply: dict[str, Any] | None = None
    start_baseline: dict[str, Any] | None = None
    start_attempted = False
    request_id: str | None = None
    route_cleanup: dict[str, Any] | None = None
    pm_cleanup: dict[str, Any] | None = None
    pm_out = pm_err = ""
    try:
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
        # Spread calibration across the entire run, while keeping each pair bounded by its TCP RTT.
        for _ in range(4):
            samples.append(bench.clock_pair(qpc))
        if process.poll() is not None:
            raise DynamicCaptureError(f"PresentMon exited before route start with code {process.returncode}")
        profiler_pre = bench.command("gpuprof status")
        profiler_replies.append({"stage": "pre_route", "reply": profiler_pre})
        validate_gpu_profiler_idle(profiler_pre)
        encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
        loaded = bench.json("route load " + encoded)
        if loaded.get("route_sha256") != route_hash or loaded.get("id") != route["id"]:
            raise DynamicCaptureError("BenchCam route load receipt does not attest the exact canonical route")
        start_baseline = bench.json("route status")
        if start_baseline.get("running") is True:
            raise DynamicCaptureError("BenchCam already has a running route; refusing to start or cancel over it")
        request_id = str(uuid.uuid4())
        start_attempted = True
        start_reply = bench.json(f"route start warmup={args.warmup} measure={args.measure} arm_ms={args.arm_ms} request_id={request_id}")
        if (start_reply.get("route_sha256") != route_hash or not start_reply.get("run_id")
                or start_reply.get("request_id") != request_id):
            raise DynamicCaptureError("BenchCam route start receipt lacks matching route hash/run_id/request_id")
        run_id = start_reply["run_id"]
        if start_reply.get("running") is not True:
            raise DynamicCaptureError("BenchCam route start receipt did not report running=true")
        deadline = time.monotonic() + args.timeout
        last_phase = None
        terminal_phase = None
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise DynamicCaptureError(f"PresentMon exited while route was active with code {process.returncode}")
            status = bench.json("route status")
            if status.get("run_id") != run_id:
                raise DynamicCaptureError("BenchCam route status run_id changed during capture")
            phase = _check_route_status(status, route_hash, request_id)
            status_history.append(status)
            if phase != last_phase:
                print(f"route phase: {phase}", flush=True)
                last_phase = phase
            samples.append(bench.clock_pair(qpc))
            if phase in TERMINAL:
                terminal_phase = phase
                break
            time.sleep(args.poll_interval)
        else:
            raise DynamicCaptureError("route did not reach a terminal state before timeout; requesting scoped cancellation")
        final_status = status_history[-1]
        profiler_post = bench.command("gpuprof status")
        profiler_replies.append({"stage": "post_restore", "reply": profiler_post})
        validate_gpu_profiler_idle(profiler_post)
        for _ in range(4):
            samples.append(bench.clock_pair(qpc))
        pm_cleanup = stop_owned_presentmon(executable, session, process)
        pm_out += pm_cleanup.get("stdout", "")
        pm_err += pm_cleanup.get("stderr", "")
        returncode = pm_cleanup.get("process_returncode")
        if any(pm_cleanup.get(key) for key in ("error", "communicate_error", "terminate_error", "kill_error")):
            raise DynamicCaptureError(f"PresentMon owned-session cleanup failed: {pm_cleanup}")
        if pm_cleanup.get("returncode") != 0:
            raise DynamicCaptureError(f"PresentMon owned-session stop returned {pm_cleanup.get('returncode')}: {pm_err[-3000:]}")
        if returncode != 0:
            raise DynamicCaptureError(f"PresentMon exited {returncode}: {pm_err[-3000:]} {pm_out[-1000:]}")
        if has_lost_events(pm_out + pm_err):
            raise DynamicCaptureError("PresentMon reported lost ETW events")
        frames = validate_capture_csv(raw_path, args.pid)
        validate_terminal_route_status(final_status, terminal_phase or "missing", request_id)
        mapping = fit_clock_map(samples, qpc.frequency)
        try:
            measured_start = int(final_status["measured_start_ns"])
            measured_end = int(final_status["measured_end_ns"])
        except (KeyError, TypeError, ValueError) as exc:
            raise DynamicCaptureError("completed route status lacks exact measured_start_ns/measured_end_ns") from exc
        metrics = analyze_measured_csv(raw_path, args.pid, measured_start, measured_end, mapping, qpc.frequency)
        route_gaps = {"frame_max_gap_ms_observed": _status_max(status_history, "frame_max_gap_ms"),
                      "server_max_gap_ms_observed": _status_max(status_history, "server_max_gap_ms"),
                      "camera_server_max_distance_observed": _status_max(status_history, "camera_server_max_distance"),
                      "camera_server_measured_max_distance_observed": _status_max(status_history, "camera_server_measured_max_distance")}
        iris_timer_fields = ("iris_frame_time_counter_s", "iris_timer_at_request_s",
                             "iris_timer_at_first_measured_render_s", "iris_timer_at_first_end_render_s",
                             "iris_timer_at_finish_s")
        iris_timer_observations = [{name: status.get(name) for name in iris_timer_fields}
                                   for status in status_history]
        # Re-attest the live selection, artifact, and exact option/config text after the full run.
        process_after = process_preflight(args.pid, game_dir)
        renderer_after = _latest_renderer(game_log)
        pack_after = read_active_pack(iris_path, args.pack, game_log)
        pack_hash_after = attest_pack_artifact(iris_path, pack_after["selected_pack"], artifact,
                                               args.expected_pack_sha256)
        iris_snapshot_after, options_after = _snapshot(iris_path), _snapshot(option_path)
        if pack_hash_after != pack_hash_before or iris_snapshot_after != iris_snapshot_before or options_after != options_before:
            raise DynamicCaptureError("Iris pack selection/config/options changed during dynamic capture")
        if renderer_after != renderer_before:
            raise DynamicCaptureError("OpenGL renderer log changed during dynamic capture")
        after_png = raw_path.with_suffix(".after.png")
        after_size = _framebuffer(bench, after_png)
        if after_size != (args.width, args.height):
            raise DynamicCaptureError(f"post-capture framebuffer {after_size} differs from requested {(args.width, args.height)}")
        metadata = {"schema_version": 1, "capture_id": args.capture_id, "variant": args.variant,
            "route_id": route["id"], "route_sha256": route_hash, "route": route,
            "run_id": run_id, "pid": args.pid, "process_before": process_before, "process_after": process_after,
            "renderer": renderer_before, "presentmon": str(executable), "presentmon_session": session,
            "presentmon_command": command, "presentmon_returncode": returncode,
            "presentmon_stdout": pm_out[-8000:], "presentmon_stderr": pm_err[-8000:],
            "raw_csv": str(raw_path), "target_frame_rows": frames, "metrics": metrics,
            "route_gaps_and_control": route_gaps,
            "phase_status_history": status_history, "start_receipt": start_reply,
            "start_status_baseline": start_baseline, "start_attempted": start_attempted,
            "route_request_id": request_id,
            "gpu_profiler_status_replies": profiler_replies,
            "presentmon_cleanup": pm_cleanup,
            "iris_timer_observations": iris_timer_observations,
            "iris_timer_note": "Iris timers are recorded as observed; freezing world time does not imply frozen shader animation.",
            "clock_mapping": mapping, "clock_pairs": samples, "qpc_frequency_hz": qpc.frequency,
            "measured_start_ns": measured_start, "measured_end_ns": measured_end,
            "pack": pack_before, "pack_sha256": pack_hash_before, "pack_artifact": str(artifact),
            "iris_before": iris_snapshot_before, "iris_after": iris_snapshot_after,
            "options_before": options_before, "options_after": options_after,
            "resolution": {"width": args.width, "height": args.height},
            "resolution_before_png": str(before_png), "resolution_after_png": str(after_png),
            "resolution_after": list(after_size), "started_at_utc": started_at, "ended_at_utc": _utc(),
            "warmup_traversals": args.warmup, "measured_traversals": args.measure,
            "arm_ms": args.arm_ms}
        metadata_path.write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return metadata
    except BaseException as exc:
        # Ask BenchCam to restore its saved state on harness faults, then verify its terminal receipt.
        if start_attempted and bench is not None:
            try:
                route_cleanup = cancel_route_only_if_owned(
                    bench, route["id"], route_hash, start_baseline, start_reply, request_id or "",
                    min(120.0, args.timeout), args.poll_interval)
                status_history.extend(route_cleanup.get("status_history", []))
                if (route_cleanup.get("action") in {"cancel_timeout", "ownership_changed"}
                        or route_cleanup.get("action") == "cancelled" and not route_cleanup.get("restore_verified")):
                    exc = DynamicCaptureError(f"{exc}; route cleanup could not verify owned-run restoration: {route_cleanup}")
            except BaseException as restore_exc:
                exc = DynamicCaptureError(f"{exc}; route restore/status failed: {restore_exc}")
        if bench is not None and not any(item["stage"] == "post_restore" for item in profiler_replies):
            try:
                profiler_post = bench.command("gpuprof status")
                profiler_replies.append({"stage": "post_failure_restore", "reply": profiler_post})
                validate_gpu_profiler_idle(profiler_post)
            except BaseException as profiler_exc:
                if profiler_replies and not any(item["stage"] == "post_restore" for item in profiler_replies):
                    # Keep the original failure while making the failed postcondition explicit.
                    exc = DynamicCaptureError(f"{exc}; post-restore GPU profiler check failed: {profiler_exc}")
        # Raw CSV remains available for diagnosis; never erase/censor a failed or slow capture.
        if pm_cleanup is None:
            pm_cleanup = stop_owned_presentmon(executable, session, process, timeout=10)
            pm_out += pm_cleanup.get("stdout", "")
            pm_err += pm_cleanup.get("stderr", "")
        if has_lost_events(pm_out + pm_err) and "lost ETW events" not in str(exc):
            exc = DynamicCaptureError(f"{exc}; PresentMon reported lost ETW events")
        try:
            iris_snapshot_after = _snapshot(iris_path)
            options_after = _snapshot(option_path)
            pack_after_hash = attest_pack_artifact(iris_path, args.pack, artifact)
        except Exception as post_exc:
            iris_snapshot_after = options_after = None
            pack_after_hash = f"unavailable: {post_exc}"
        reject = {"schema_version": 1, "rejected": True, "reason": str(exc),
                  "raw_csv": str(raw_path), "presentmon_session": session,
                  "presentmon_command": command, "presentmon_returncode": process.poll() if process is not None else None,
                  "route_sha256": route_hash, "route_id": route["id"],
                  "start_status_baseline": start_baseline, "start_attempted": start_attempted,
                  "route_request_id": request_id,
                  "phase_status_history": status_history, "clock_pairs": samples,
                  "gpu_profiler_status_replies": profiler_replies,
                  "route_cleanup": route_cleanup, "presentmon_cleanup": pm_cleanup,
                  "stdout_tail": pm_out[-4000:], "stderr_tail": pm_err[-4000:],
                  "iris_before": iris_snapshot_before, "iris_after": iris_snapshot_after,
                  "options_before": options_before, "options_after": options_after,
                  "pack_sha256_before": pack_hash_before, "pack_sha256_after": pack_after_hash}
        reject_path = raw_path.with_suffix(".rejected.json")
        if not reject_path.exists():
            reject_path.write_text(json.dumps(reject, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        raise


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--routes", type=Path, default=Path(__file__).with_name("dynamic_routes.json"))
    p.add_argument("--route", required=True, help="route id in --routes catalog")
    p.add_argument("--presentmon", required=True, type=Path)
    p.add_argument("--pid", required=True, type=int)
    p.add_argument("--output", required=True, type=Path, help="new CSV path or capture basename")
    p.add_argument("--capture-id", required=True)
    p.add_argument("--variant", required=True)
    p.add_argument("--pack", required=True)
    p.add_argument("--pack-artifact", required=True, type=Path)
    p.add_argument("--expected-pack-sha256")
    p.add_argument("--width", required=True, type=int)
    p.add_argument("--height", required=True, type=int)
    p.add_argument("--warmup", type=int, default=1, help="complete unmeasured route traversals")
    p.add_argument("--measure", type=int, default=3, help="complete measured route traversals")
    p.add_argument("--arm-ms", type=int, default=3000)
    p.add_argument("--poll-interval", type=float, default=0.5)
    p.add_argument("--timeout", type=float, default=1800)
    p.add_argument("--benchcam-port", type=int, default=25599)
    p.add_argument("--game-dir", type=Path, default=GAME_DIR)
    p.add_argument("--iris-properties", type=Path, default=GAME_DIR / "config/iris.properties")
    p.add_argument("--game-log", type=Path, default=GAME_DIR / "logs/latest.log")
    p.add_argument("--dry-run", action="store_true", help="preflight only; skips BenchCam, PresentMon, and live framebuffer verification")
    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.pid <= 0 or args.width <= 0 or args.height <= 0:
        parser.error("--pid, --width, and --height must be positive")
    if not 1 <= args.warmup <= 10 or not 1 <= args.measure <= 10 or not 2000 <= args.arm_ms <= 60000:
        parser.error("--warmup and --measure must be 1..10; --arm-ms must be 2000..60000")
    if args.poll_interval <= 0 or args.timeout <= 0:
        parser.error("--poll-interval and --timeout must be positive")
    if args.expected_pack_sha256 and not args.pack_artifact:
        parser.error("--expected-pack-sha256 requires --pack-artifact")
    try:
        metadata = run_capture(args)
        if metadata.get("dry_run"):
            print(f"preflight only: route={metadata['route_id']} sha256={metadata['route_sha256']} (live framebuffer not checked)")
        else:
            print(f"dynamic capture complete: {metadata['target_frame_rows']} raw target frame rows")
            print(f"CSV: {metadata['raw_csv']}\nmetadata: {Path(metadata['raw_csv']).with_suffix('.dynamic.capture.json')}")
        return 0
    except (DynamicCaptureError, OSError, subprocess.SubprocessError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
