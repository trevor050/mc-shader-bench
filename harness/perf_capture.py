"""Run a bounded, noninteractive PresentMon capture for one ShaderBench process.

The helper only observes Minecraft: it reads Iris' saved pack selection and asks
BenchCam for its read-only ``status`` response. It never sends game commands.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import socket
import subprocess
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class CaptureError(Exception):
    """Capture could not be trusted as a complete target-process recording."""


DEFAULT_GAME_DIR = (
    Path.home()
    / "AppData/Roaming/PrismLauncher/instances/ShaderBench/minecraft"
)


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _normalized_headers(fieldnames: list[str] | None, path: Path) -> dict[str, str]:
    if not fieldnames:
        raise CaptureError(f"{path}: CSV has no header; PresentMon may have failed to start a session")
    headers: dict[str, str] = {}
    for original in fieldnames:
        name = original.strip().casefold()
        if name and name in headers:
            raise CaptureError(f"{path}: duplicate CSV column {original!r}")
        if name:
            headers[name] = original
    return headers


def validate_capture_csv(path: Path, target_pid: int) -> int:
    """Return target frame-row count, rejecting missing/empty/wrong-PID output."""
    if not path.is_file():
        raise CaptureError(f"PresentMon exited without creating CSV: {path}")
    if path.stat().st_size == 0:
        raise CaptureError(f"PresentMon created an empty CSV: {path}")
    try:
        handle = path.open("r", encoding="utf-8-sig", newline="")
    except OSError as exc:
        raise CaptureError(f"cannot read PresentMon CSV {path}: {exc}") from exc
    with handle:
        reader = csv.DictReader(handle)
        headers = _normalized_headers(reader.fieldnames, path)
        pid_column = headers.get("processid")
        if pid_column is None:
            raise CaptureError(f"{path}: missing PresentMon ProcessID column")
        app_column = headers.get("application")
        if app_column is None:
            raise CaptureError(f"{path}: missing PresentMon Application column")
        frames = 0
        seen_pids: set[int] = set()
        for line_number, row in enumerate(reader, start=2):
            raw_pid = (row.get(pid_column) or "").strip()
            if not raw_pid:
                continue
            try:
                pid = int(raw_pid)
            except ValueError as exc:
                raise CaptureError(f"{path}:{line_number}: invalid ProcessID {raw_pid!r}") from exc
            seen_pids.add(pid)
            if pid == target_pid:
                application = (row.get(app_column) or "").strip().replace("\\", "/").rsplit("/", 1)[-1]
                if application.casefold() != "javaw.exe":
                    raise CaptureError(
                        f"{path}:{line_number}: target PID {target_pid} belongs to {application!r}, expected javaw.exe"
                    )
                frames += 1
    if not frames:
        others = f"; CSV contains PIDs {sorted(seen_pids)}" if seen_pids else ""
        raise CaptureError(f"{path}: no frame rows for target PID {target_pid}{others}")
    return frames


def read_active_pack(iris_properties: Path, expected_pack: str, game_log: Path | None) -> dict[str, str]:
    if not iris_properties.is_file():
        raise CaptureError(f"Iris config not found, cannot attest active pack: {iris_properties}")
    selected = None
    for line in iris_properties.read_text(encoding="utf-8-sig", errors="replace").splitlines():
        match = re.match(r"\s*shaderPack\s*=\s*(.*?)\s*$", line)
        if match:
            selected = match.group(1)
    if not selected:
        raise CaptureError(f"Iris config has no non-empty shaderPack entry: {iris_properties}")
    if selected.casefold() != expected_pack.casefold():
        raise CaptureError(f"requested pack {expected_pack!r} but Iris config selects {selected!r}")
    result = {"selected_pack": selected, "iris_properties": str(iris_properties)}
    if game_log and game_log.is_file():
        log_text = game_log.read_text(encoding="utf-8-sig", errors="replace")
        confirmations = re.findall(r"Using shaderpack:\s*(.+?)\s*$", log_text, re.MULTILINE | re.IGNORECASE)
        if confirmations:
            observed = confirmations[-1].strip()
            result["latest_log_pack"] = observed
            if observed.casefold() != selected.casefold():
                raise CaptureError(
                    f"latest.log reports shader pack {observed!r}, but Iris config selects {selected!r}; "
                    "wait for pack reload to finish before capturing"
                )
    return result


def read_benchcam_status(port: int, timeout: float) -> dict[str, Any]:
    """Read status only; does not issue any state-changing BenchCam command."""
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
            sock.settimeout(timeout)
            sock.sendall(b"status\n")
            stream = sock.makefile("r", encoding="utf-8")
            reply = stream.readline().strip()
    except OSError as exc:
        raise CaptureError(f"cannot read BenchCam status on 127.0.0.1:{port}: {exc}") from exc
    return parse_benchcam_status(reply)


def parse_benchcam_status(reply: str) -> dict[str, Any]:
    if not reply.startswith("ok "):
        raise CaptureError(f"BenchCam status failed: {reply or 'no response'}")
    pose_match = re.search(r"\bpos=(.*?)\s+time=([^ ]+)", reply)
    if not pose_match:
        raise CaptureError(f"BenchCam status has no recognizable pose/time: {reply}")
    pos, raw_time = pose_match.groups()
    if pos == "none" or not pos:
        raise CaptureError("BenchCam reports no player pose; join the target world before capture")
    parts = pos.split()
    if len(parts) != 5:
        raise CaptureError(f"unrecognized BenchCam pose in status: {pos!r}")
    try:
        x, y, z, yaw, pitch = map(float, parts)
        world_time = int(raw_time)
    except ValueError as exc:
        raise CaptureError(f"unrecognized BenchCam pose/time in status: {reply}") from exc
    return {
        "position": {"x": x, "y": y, "z": z},
        "yaw": yaw,
        "pitch": pitch,
        "world_time": world_time,
        "status_reply": reply,
    }


def build_presentmon_command(executable: Path, pid: int, csv_path: Path, seconds: int, session_name: str) -> list[str]:
    return [
        str(executable), "--process_id", str(pid), "--output_file", str(csv_path),
        "--timed", str(seconds), "--terminate_after_timed", "--session_name", session_name,
        "--v2_metrics", "--no_console_stats",
    ]


def capture(args: argparse.Namespace) -> dict[str, Any]:
    executable = args.presentmon.resolve()
    if not executable.is_file():
        raise CaptureError(f"PresentMon executable does not exist: {executable}")
    csv_path = args.output.resolve()
    if csv_path.exists():
        raise CaptureError(f"refusing to overwrite existing output: {csv_path}")
    metadata_path = csv_path.with_suffix(".capture.json")
    if metadata_path.exists():
        raise CaptureError(f"refusing to overwrite existing metadata: {metadata_path}")
    csv_path.parent.mkdir(parents=True, exist_ok=True)

    pack = read_active_pack(args.iris_properties, args.pack, args.game_log)
    pose = read_benchcam_status(args.benchcam_port, args.status_timeout)
    if pose["world_time"] < 0:
        raise CaptureError("BenchCam reports no loaded world clock")
    session = f"shaderbench-{args.pid}-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{uuid.uuid4().hex[:8]}"
    command = build_presentmon_command(executable, args.pid, csv_path, args.seconds, session)
    started_at = _utc_now()
    try:
        completed = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=args.seconds + args.exit_grace,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise CaptureError(
            f"PresentMon exceeded {args.seconds + args.exit_grace}s timeout; session {session!r} may still be active"
        ) from exc
    ended_at = _utc_now()
    if completed.returncode != 0:
        raise CaptureError(
            f"PresentMon exited with code {completed.returncode}; session={session!r}\n"
            f"stdout:\n{completed.stdout[-4000:]}\nstderr:\n{completed.stderr[-4000:]}"
        )
    frames = validate_capture_csv(csv_path, args.pid)
    metadata = {
        "schema_version": 1,
        "capture_id": args.capture_id,
        "variant": args.variant,
        "process_id": args.pid,
        "presentmon_executable": str(executable),
        "presentmon_session_name": session,
        "duration_seconds": args.seconds,
        "started_at_utc": started_at,
        "ended_at_utc": ended_at,
        "csv": str(csv_path),
        "target_frame_rows": frames,
        "pack": pack["selected_pack"],
        "pack_observation": pack,
        "pack_revision": args.pack_revision,
        "scene": {"id": args.scene_id, **pose},
        "resolution": {"width": args.width, "height": args.height},
        "environment": json.loads(args.environment.read_text(encoding="utf-8-sig")),
        "presentmon_returncode": completed.returncode,
        "presentmon_stdout_tail": completed.stdout[-4000:],
        "presentmon_stderr_tail": completed.stderr[-4000:],
    }
    metadata_path.write_text(json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return metadata


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--presentmon", required=True, type=Path, help="PresentMon console executable")
    p.add_argument("--pid", required=True, type=int, help="javaw.exe PID to capture")
    p.add_argument("--output", required=True, type=Path, help="new CSV path; existing files are never overwritten")
    p.add_argument("--seconds", type=int, default=60, help="capture duration (default: 60)")
    p.add_argument("--exit-grace", type=int, default=30, help="extra seconds for orderly PresentMon shutdown")
    p.add_argument("--capture-id", required=True, help="run identifier such as A1")
    p.add_argument("--variant", required=True, help="pack variant label such as A or B")
    p.add_argument("--pack", required=True, help="expected active Iris shader pack name")
    p.add_argument("--pack-revision", required=True, help="source revision or settings fingerprint")
    p.add_argument("--scene-id", required=True, help="operator-supplied stable scene identifier")
    p.add_argument("--width", required=True, type=int, help="game render width")
    p.add_argument("--height", required=True, type=int, help="game render height")
    p.add_argument("--environment", required=True, type=Path, help="non-empty JSON object describing matching environment")
    p.add_argument("--iris-properties", type=Path, default=DEFAULT_GAME_DIR / "config/iris.properties")
    p.add_argument("--game-log", type=Path, default=DEFAULT_GAME_DIR / "logs/latest.log")
    p.add_argument("--benchcam-port", type=int, default=25599)
    p.add_argument("--status-timeout", type=float, default=5.0)
    return p


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.pid <= 0 or args.seconds <= 0 or args.exit_grace < 0:
        parser().error("--pid and --seconds must be positive; --exit-grace must be non-negative")
    if args.width <= 0 or args.height <= 0:
        parser().error("--width and --height must be positive")
    if args.environment:
        try:
            environment = json.loads(args.environment.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"error: invalid --environment JSON: {exc}", file=sys.stderr)
            return 2
        if not isinstance(environment, dict) or not environment:
            print("error: --environment JSON root must be a non-empty object", file=sys.stderr)
            return 2
    try:
        result = capture(args)
        print(f"capture complete: {result['target_frame_rows']} target frame rows")
        print(f"CSV: {result['csv']}")
        print(f"metadata: {Path(result['csv']).with_suffix('.capture.json')}")
    except (CaptureError, OSError, subprocess.SubprocessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
