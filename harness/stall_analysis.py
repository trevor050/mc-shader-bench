"""Offline, bounded summary for one passive Minecraft stall capture.

This reports observations only. It cannot attribute a stall to CPU, GPU, a
shader effect, or a memory leak from sparse capture data.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
from datetime import datetime
from pathlib import Path
from typing import Any


FRAME_METRICS = {
    "gpu_busy_ms": ("MsGPUBusy", "msGPUActive"),
    "cpu_busy_ms": ("MsCPUBusy", "msCPUBusy", "CPUBusy"),
}
TIME_MS_COLUMNS = ("TimeInMs", "CPUStartTimeInMs", "CPUStartTime")
TIME_SECONDS_COLUMNS = ("TimeInSeconds",)
TELEMETRY_METRICS = {
    "nvidia_gpu_util_percent": ("NvidiaGpuUtilPercent", "GpuUtilPercent"),
    "nvidia_vram_used_mib": ("NvidiaVramUsedMiB", "VramUsedMiB"),
    "java_private_bytes": ("JavaPrivateBytes",),
    "java_working_set_bytes": ("JavaWorkingSetBytes",),
    "java_gpu_dedicated_bytes": ("GpuDedicatedBytes",),
    "java_gpu_shared_bytes": ("GpuSharedBytes",),
    "java_gpu_total_committed_bytes": ("GpuTotalCommittedBytes",),
    "system_committed_bytes": ("SystemCommittedBytes",),
    "available_physical_bytes": ("AvailablePhysicalBytes",),
}


def _headers(fieldnames: list[str] | None) -> dict[str, str]:
    return {name.strip().casefold(): name for name in (fieldnames or []) if name and name.strip()}


def _column(headers: dict[str, str], *names: str) -> str | None:
    return next((headers[name.casefold()] for name in names if name.casefold() in headers), None)


def _number(raw: Any) -> float | None:
    if raw is None or str(raw).strip().casefold() in {"", "na", "n/a", "nan", "null", "none"}:
        return None
    try:
        number = float(raw)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _stats(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        return {"samples": 0, "min": None, "median": None, "p95": None, "max": None, "first": None, "last": None, "delta": None}
    ordered = sorted(values)
    p95 = ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]
    return {
        "samples": len(values), "min": min(values), "median": statistics.median(values),
        "p95": p95, "max": max(values), "first": values[0], "last": values[-1],
        "delta": values[-1] - values[0],
    }


def _read_json(path: Path) -> tuple[dict[str, Any] | None, str | None]:
    if not path.is_file():
        return None, "metadata file missing"
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as exc:
        return None, f"metadata unreadable: {exc}"
    return (data, None) if isinstance(data, dict) else (None, "metadata root is not an object")


def _frame_summary(path: Path, target_pid: int | None) -> dict[str, Any]:
    out: dict[str, Any] = {
        "status": "unmeasurable", "reason": None, "target_pid": target_pid,
        "rows_for_target_pid": 0, "swapchains": [], "selected_swapchain": None,
        "timestamps": {"status": "unmeasurable", "column": None, "unit": None, "unique_frames": 0},
        "present_gaps_ms": None, "gaps_over_ms": {}, "gpu_busy_ms": None, "cpu_busy_ms": None,
    }
    if not path.is_file():
        out["reason"] = "PresentMon CSV missing"
        return out
    if target_pid is None:
        out["reason"] = "target PID unavailable in capture metadata; frame rows cannot be safely attributed"
        return out
    try:
        handle = path.open("r", encoding="utf-8-sig", newline="")
    except OSError as exc:
        out["reason"] = f"PresentMon CSV unreadable: {exc}"
        return out
    with handle:
        reader = csv.DictReader(handle)
        headers = _headers(reader.fieldnames)
        if not headers:
            out["reason"] = "PresentMon CSV is empty or has no header"
            return out
        pid_col = _column(headers, "ProcessID")
        swap_col = _column(headers, "SwapChainAddress")
        if not pid_col:
            out["reason"] = "ProcessID column missing"
            return out
        rows: list[dict[str, str]] = []
        for row in reader:
            try:
                row_pid = int((row.get(pid_col) or "").strip())
            except ValueError:
                continue
            if row_pid == target_pid:
                rows.append(row)
        out["rows_for_target_pid"] = len(rows)
        if not rows:
            out["reason"] = "no PresentMon rows for target PID; frame timings unavailable"
            return out
        if swap_col is None:
            out["reason"] = "SwapChainAddress missing; multiple game swapchains cannot be excluded"
            return out
        chain_rows: dict[str, list[dict[str, str]]] = {}
        for row in rows:
            address = (row.get(swap_col) or "").strip()
            if address:
                chain_rows.setdefault(address.casefold(), []).append(row)
        out["swapchains"] = [{"address": key, "rows": len(value)} for key, value in chain_rows.items()]
        if not chain_rows:
            out["reason"] = "target rows contain no SwapChainAddress"
            return out
        if len(chain_rows) != 1:
            out["reason"] = "multiple target swapchains; refusing to combine frames or guess the render chain"
            return out
        address, selected = next(iter(chain_rows.items()))
        out["selected_swapchain"] = address

        metric_columns = {name: _column(headers, *aliases) for name, aliases in FRAME_METRICS.items()}
        for name, col in metric_columns.items():
            values = [_number(row.get(col)) for row in selected] if col else []
            clean = [value for value in values if value is not None and value >= 0]
            out[name] = _stats(clean) if col else None

        time_col = _column(headers, *TIME_MS_COLUMNS)
        unit = "ms"
        gap_kind = "present_event_gaps"
        scale = 1.0
        if time_col is None:
            time_col = _column(headers, *TIME_SECONDS_COLUMNS)
            unit, scale = "seconds", 1000.0
            gap_kind = "present_event_gaps"
        elif time_col.casefold() in {"cpustarttimeinms", "cpustarttime"}:
            gap_kind = "frame_start_gaps"
        if time_col is None:
            out["reason"] = "target swapchain found; frame busy metrics summarized, but no supported timestamp column for gap analysis"
            out["status"] = "partial"
            return out
        timestamps = [_number(row.get(time_col)) for row in selected]
        times = sorted({value * scale for value in timestamps if value is not None})
        out["timestamps"] = {"status": "measured" if len(times) >= 2 else "insufficient_samples",
                              "column": time_col, "unit": unit, "gap_kind": gap_kind,
                              "unique_frames": len(times)}
        if len(times) < 2:
            out["reason"] = "fewer than two unique frame timestamps; gaps cannot be computed"
            out["status"] = "partial"
            return out
        gaps = [b - a for a, b in zip(times, times[1:]) if b > a]
        if not gaps:
            out["reason"] = "timestamps are not increasing; gaps cannot be computed"
            out["status"] = "partial"
            return out
        out["present_gaps_ms"] = _stats(gaps)
        out["gaps_over_ms"] = {
            str(limit): sum(gap >= limit for gap in gaps)
            for limit in (50, 100, 250, 1000, 2000, 4000, 8000, 12000)
        }
        out["timestamps"]["duration_ms"] = times[-1] - times[0]
        out["status"] = "measured"
        out["reason"] = "frame timing describes observed target swapchain presents only; it does not identify stall cause"
    return out


def _parse_timestamp(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None


def _telemetry_summary(path: Path, target_pid: int | None) -> dict[str, Any]:
    out: dict[str, Any] = {"status": "unmeasurable", "reason": None, "rows": 0, "pid_rows": 0,
                           "time_range": None, "metrics": {}, "sample_errors": []}
    if not path.is_file():
        out["reason"] = "telemetry CSV missing"
        return out
    if target_pid is None:
        out["reason"] = "target PID unavailable in capture metadata; telemetry rows cannot be safely attributed"
        return out
    try:
        handle = path.open("r", encoding="utf-8-sig", newline="")
    except OSError as exc:
        out["reason"] = f"telemetry CSV unreadable: {exc}"
        return out
    with handle:
        reader = csv.DictReader(handle)
        headers = _headers(reader.fieldnames)
        if not headers:
            out["reason"] = "telemetry CSV is empty or has no header"
            return out
        pid_col = _column(headers, "ProcessId", "ProcessID")
        timestamp_col = _column(headers, "TimestampLocal", "Timestamp")
        error_col = _column(headers, "SampleError")
        metric_columns = {key: _column(headers, *aliases) for key, aliases in TELEMETRY_METRICS.items()}
        if pid_col is None:
            out["reason"] = "ProcessId column missing; cannot verify telemetry belongs to the target PID"
            return out
        rows: list[dict[str, str]] = []
        for row in reader:
            out["rows"] += 1
            try:
                if int((row.get(pid_col) or "").strip()) != target_pid:
                    continue
            except ValueError:
                continue
            rows.append(row)
        out["pid_rows"] = len(rows)
        if not rows:
            out["reason"] = "no telemetry rows for target PID"
            return out
        times = [t for t in (_parse_timestamp(row.get(timestamp_col)) for row in rows) if t] if timestamp_col else []
        if times:
            out["time_range"] = {"start": min(times).isoformat(), "end": max(times).isoformat()}
        for name, col in metric_columns.items():
            vals = [_number(row.get(col)) for row in rows] if col else []
            out["metrics"][name] = _stats([v for v in vals if v is not None]) if col else None
        if error_col:
            errors = sorted({(row.get(error_col) or "").strip() for row in rows if (row.get(error_col) or "").strip()})
            out["sample_errors"] = errors[:8]
            out["omitted_sample_error_kinds"] = max(0, len(errors) - 8)
        measured = [v for v in out["metrics"].values() if v and v["samples"]]
        out["status"] = "measured" if measured else "unmeasurable"
        out["reason"] = "telemetry trends are sampled observations; sparse samples cannot establish a leak or stall cause" if measured else "no numeric telemetry metrics were available"
    return out


def analyze(csv_path: Path) -> dict[str, Any]:
    csv_path = csv_path.resolve()
    stem = csv_path.with_suffix("")
    metadata_path = stem.with_name(stem.name + ".capture.json")
    telemetry_path = stem.with_name(stem.name + ".telemetry.csv")
    metadata, metadata_error = _read_json(metadata_path)
    pid_value = metadata.get("process_id") if metadata else None
    target_pid = pid_value if isinstance(pid_value, int) and not isinstance(pid_value, bool) and pid_value > 0 else None
    return {
        "schema_version": 1,
        "capture_csv": str(csv_path),
        "metadata_path": str(metadata_path),
        "telemetry_path": str(telemetry_path),
        "capture_metadata": {
            "status": "read" if metadata else "unavailable", "reason": metadata_error,
            "process_id": target_pid,
            "started_at_utc": metadata.get("started_at_utc") if metadata else None,
            "ended_at_utc": metadata.get("ended_at_utc") if metadata else None,
            "presentmon_returncode": metadata.get("presentmon_returncode") if metadata else None,
            "telemetry_returncode": metadata.get("telemetry_returncode") if metadata else None,
            "presentmon_timed_out": metadata.get("presentmon_timed_out") if metadata else None,
            "telemetry_timed_out": metadata.get("telemetry_timed_out") if metadata else None,
        },
        "frames": _frame_summary(csv_path, target_pid),
        "telemetry": _telemetry_summary(telemetry_path, target_pid),
        "interpretation_limit": "Correlated frame gaps and telemetry changes are descriptive. They do not by themselves distinguish CPU, GPU, driver, shader, or memory-pressure causes.",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture_csv", type=Path, help="raw PresentMon CSV produced by passive_capture.py")
    parser.add_argument("--json-out", type=Path, help="write the complete report as JSON")
    args = parser.parse_args(argv)
    try:
        result = analyze(args.capture_csv)
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(f"Capture: {result['capture_csv']}")
    print(f"Target PID: {result['capture_metadata']['process_id'] or 'unavailable'}")
    frames = result["frames"]
    print(f"Frames: {frames['status']} — {frames['reason']}")
    if frames["present_gaps_ms"]:
        gap = frames["present_gaps_ms"]
        print(f"{frames['timestamps']['gap_kind']}: n={gap['samples']}, median={gap['median']:.3f} ms, p95={gap['p95']:.3f} ms, max={gap['max']:.3f} ms; >=50/100/250/1000 ms={list(frames['gaps_over_ms'].values())}")
    for key in FRAME_METRICS:
        stat = frames.get(key)
        if stat:
            print(f"{key}: n={stat['samples']}, median={stat['median']:.3f} ms, p95={stat['p95']:.3f} ms, max={stat['max']:.3f} ms")
        else:
            print(f"{key}: unmeasurable")
    telemetry = result["telemetry"]
    print(f"Telemetry: {telemetry['status']} — {telemetry['reason']}")
    for key in ("nvidia_gpu_util_percent", "nvidia_vram_used_mib", "java_private_bytes", "java_gpu_dedicated_bytes", "system_committed_bytes", "available_physical_bytes"):
        stat = telemetry["metrics"].get(key)
        if stat:
            print(f"{key}: n={stat['samples']}, first={stat['first']}, last={stat['last']}, delta={stat['delta']}")
    print(result["interpretation_limit"])
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
