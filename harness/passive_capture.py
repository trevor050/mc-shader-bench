"""Bounded passive PresentMon and memory telemetry capture for a stalled game.

This helper validates a Java PID against the Prism instance, then starts a
unique timed PresentMon session and telemetry.ps1. It never sends game input,
queries BenchCam, or changes game state. Output CSV is kept even when it has no
frame rows; frame validation is deliberately left to later analysis.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from perf_capture import CaptureError, attest_pack_artifact, read_active_pack


MAX_SECONDS = 900
MAX_GRACE = 120


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def ps_encoded(script: str) -> str:
    return base64.b64encode(script.encode("utf-16le")).decode("ascii")


def validate_java_pid(powershell: str, pid: int, instance: Path, timeout: int = 15) -> dict[str, Any]:
    """Ask CIM for the PID and verify its command line includes this instance."""
    root = str(instance.resolve()).replace("'", "''").replace("/", "\\").rstrip("\\").lower()
    script = f"""
$ErrorActionPreference = 'Stop'
$expected = '{root}'
$p = Get-CimInstance Win32_Process -Filter \"ProcessId = {pid}\"
if (-not $p -or $p.Name -notin @('java.exe','javaw.exe')) {{ throw 'PID is not a running Java process' }}
$cmd = ([string]$p.CommandLine).Replace('/', '\\').ToLowerInvariant()
if (-not $cmd.Contains($expected)) {{ throw 'Java PID command line does not contain the requested Prism instance path' }}
[pscustomobject]@{{ process_id=[int]$p.ProcessId; name=$p.Name; creation_date=[string]$p.CreationDate; executable_path=$p.ExecutablePath }} | ConvertTo-Json -Compress
"""
    cp = subprocess.run(
        [powershell, "-NoProfile", "-NonInteractive", "-EncodedCommand", ps_encoded(script)],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, encoding="utf-8", errors="replace", timeout=timeout, check=False,
    )
    if cp.returncode:
        raise RuntimeError(f"Java PID validation failed: {cp.stderr.strip() or cp.stdout.strip()}")
    try:
        data = json.loads(cp.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Java PID validation returned invalid JSON: {cp.stdout!r}") from exc
    if int(data.get("process_id", -1)) != pid or data.get("name", "").casefold() not in {"java.exe", "javaw.exe"}:
        raise RuntimeError(f"Java PID validation returned an unexpected identity: {data!r}")
    return data


def pm_command(executable: Path, pid: int, csv_path: Path, seconds: int, session: str,
               app_only: bool = False) -> list[str]:
    command = [
        str(executable), "--process_id", str(pid), "--output_file", str(csv_path),
        "--timed", str(seconds), "--terminate_after_timed", "--session_name", session,
        "--v2_metrics", "--no_console_stats",
    ]
    if app_only:
        command.extend(("--no_track_gpu", "--no_track_display"))
    return command


def terminate_own_session(executable: Path, session: str, timeout: int = 5) -> tuple[int | None, str]:
    """Ask PresentMon to terminate only this capture's uniquely named session."""
    try:
        cp = subprocess.run(
            [str(executable), "--terminate_existing_session", "--session_name", session],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, encoding="utf-8", errors="replace", timeout=timeout, check=False,
        )
        return cp.returncode, (cp.stderr or cp.stdout)[-2000:]
    except (OSError, subprocess.SubprocessError) as exc:
        return None, str(exc)


def stop_process(proc: subprocess.Popen[Any]) -> bool:
    """Stop only the child process identified by this Popen handle."""
    if proc.poll() is not None:
        return False
    try:
        proc.terminate()
    except OSError:
        return proc.poll() is not None
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
        except OSError:
            return proc.poll() is not None
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            return False
    return True


def launch(command: list[str], stdout_path: Path, stderr_path: Path) -> subprocess.Popen[Any]:
    out = stdout_path.open("xb")
    try:
        err = stderr_path.open("xb")
    except BaseException:
        out.close()
        raise
    try:
        proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out, stderr=err)
    except BaseException:
        out.close()
        err.close()
        raise
    # The parent can close its copies; the child retains the inherited handles.
    out.close()
    err.close()
    return proc


def run(args: argparse.Namespace) -> dict[str, Any]:
    pm = args.presentmon.resolve()
    telemetry = args.telemetry.resolve()
    if not pm.is_file():
        raise RuntimeError(f"PresentMon executable does not exist: {pm}")
    if not telemetry.is_file():
        raise RuntimeError(f"telemetry script does not exist: {telemetry}")
    active_pack_attestation = None
    if args.pack:
        pack_observation = read_active_pack(args.iris_properties, args.pack, args.game_log)
        pack_sha256 = attest_pack_artifact(
            args.iris_properties, pack_observation["selected_pack"], args.pack_artifact, args.expected_pack_sha256
        )
        active_pack_attestation = {
            **pack_observation,
            "pack_revision": args.pack_revision,
            "pack_sha256": pack_sha256,
            "pack_artifact": str(args.pack_artifact.resolve()) if args.pack_artifact else None,
        }

    csv_path = args.output.resolve()
    stem = csv_path.with_suffix("")
    telemetry_csv = stem.with_name(stem.name + ".telemetry.csv")
    metadata_path = stem.with_name(stem.name + ".capture.json")
    pm_stdout = stem.with_name(stem.name + ".presentmon.stdout.log")
    pm_stderr = stem.with_name(stem.name + ".presentmon.stderr.log")
    telemetry_stdout = stem.with_name(stem.name + ".telemetry.stdout.log")
    telemetry_stderr = stem.with_name(stem.name + ".telemetry.stderr.log")
    lock_path = stem.with_name(stem.name + ".passive.lock")
    paths = [csv_path, telemetry_csv, metadata_path, pm_stdout, pm_stderr,
             telemetry_stdout, telemetry_stderr]
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    for path in paths:
        if path.exists():
            raise RuntimeError(f"refusing to overwrite existing output: {path}")
    try:
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError as exc:
        raise RuntimeError(f"capture lock already exists: {lock_path}; inspect before removing") from exc

    session = f"shaderbench-passive-{args.pid}-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{uuid.uuid4().hex[:10]}"
    data: dict[str, Any] = {
        "schema_version": 1, "process_id": args.pid, "instance_path": str(args.instance.resolve()),
        "presentmon_executable": str(pm), "presentmon_session_name": session,
        "duration_seconds": args.seconds, "app_only": args.app_only,
        "output_csv": str(csv_path),
        "telemetry_csv": str(telemetry_csv), "started_at_utc": None, "ended_at_utc": None,
        "java_identity": None, "presentmon_returncode": None, "telemetry_returncode": None,
        "presentmon_timed_out": False, "telemetry_timed_out": False,
        "cleanup": [],
    }
    if active_pack_attestation is not None:
        data["active_pack_attestation"] = active_pack_attestation
    pm_proc = telemetry_proc = None
    try:
        os.close(lock_fd)
        data["java_identity"] = validate_java_pid(args.powershell, args.pid, args.instance)
        data["started_at_utc"] = utc_now()
        started = time.monotonic()
        pm_proc = launch(pm_command(pm, args.pid, csv_path, args.seconds, session, args.app_only), pm_stdout, pm_stderr)
        data["presentmon_started_at_utc"] = utc_now()
        telemetry_cmd = [
            args.powershell, "-NoProfile", "-NonInteractive", "-File", str(telemetry),
            "-InstancePath", str(args.instance.resolve()), "-ProcessId", str(args.pid),
            "-DurationSeconds", str(args.seconds), "-IntervalSeconds", str(args.interval),
            "-OutputPath", str(telemetry_csv),
        ]
        telemetry_proc = launch(telemetry_cmd, telemetry_stdout, telemetry_stderr)
        data["telemetry_started_at_utc"] = utc_now()

        total_timeout = args.seconds + args.grace
        deadline = started + total_timeout
        for proc, key in ((pm_proc, "presentmon"), (telemetry_proc, "telemetry")):
            remaining = max(0.0, deadline - time.monotonic())
            try:
                proc.wait(timeout=remaining)
            except subprocess.TimeoutExpired:
                data[f"{key}_timed_out"] = True
                was_running = stop_process(proc)
                data["cleanup"].append({"process": key, "forced_stop": was_running})
        data["presentmon_returncode"] = pm_proc.poll()
        data["telemetry_returncode"] = telemetry_proc.poll()
    except KeyboardInterrupt:
        data["interrupted"] = True
        for proc, key in ((telemetry_proc, "telemetry"), (pm_proc, "presentmon")):
            if proc and proc.poll() is None:
                stopped = stop_process(proc)
                data["cleanup"].append({"process": key, "forced_stop": stopped})
    except BaseException as exc:
        data["orchestration_error"] = f"{type(exc).__name__}: {exc}"
        for proc, key in ((telemetry_proc, "telemetry"), (pm_proc, "presentmon")):
            if proc and proc.poll() is None:
                stopped = stop_process(proc)
                data["cleanup"].append({"process": key, "forced_stop": stopped})
    finally:
        # Even a clean CLI exit can leave its ETW session behind. Ask PresentMon
        # to close this capture's unique session before publishing the metadata.
        if pm_proc is not None:
            rc, detail = terminate_own_session(pm, session)
            data["cleanup"].append({"presentmon_session_termination_returncode": rc, "detail": detail})
        data["ended_at_utc"] = utc_now()
        data["presentmon_stdout_log"] = str(pm_stdout)
        data["presentmon_stderr_log"] = str(pm_stderr)
        data["telemetry_stdout_log"] = str(telemetry_stdout)
        data["telemetry_stderr_log"] = str(telemetry_stderr)
        data["presentmon_csv_exists"] = csv_path.is_file()
        data["presentmon_csv_bytes"] = csv_path.stat().st_size if csv_path.is_file() else None
        data["telemetry_csv_exists"] = telemetry_csv.is_file()
        data["telemetry_csv_bytes"] = telemetry_csv.stat().st_size if telemetry_csv.is_file() else None
        try:
            with metadata_path.open("x", encoding="utf-8", newline="\n") as handle:
                handle.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        finally:
            try:
                lock_path.unlink()
            except OSError:
                pass
    return data


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--presentmon", required=True, type=Path)
    p.add_argument("--pid", required=True, type=int, help="verified java.exe/javaw.exe PID")
    p.add_argument("--instance", type=Path, default=Path(os.environ.get("APPDATA", str(Path.home()))) / "PrismLauncher/instances/ShaderBench")
    p.add_argument("--output", required=True, type=Path, help="new raw PresentMon CSV path")
    p.add_argument("--seconds", type=int, default=60, help=f"capture duration, 1..{MAX_SECONDS} seconds")
    p.add_argument("--app-only", action="store_true", help="record app frame starts without display/GPU tracking; useful while monitors are powered off")
    p.add_argument("--interval", type=int, default=1, help="telemetry sampling interval in seconds")
    p.add_argument("--grace", type=int, default=30, help=f"shutdown grace, 0..{MAX_GRACE} seconds")
    p.add_argument("--telemetry", type=Path, default=Path(__file__).with_name("telemetry.ps1"))
    p.add_argument("--powershell", default=shutil.which("pwsh") or "powershell.exe")
    p.add_argument("--pack", help="expected active Iris shader pack; records config and latest.log attestation")
    p.add_argument("--pack-revision", help="source revision or settings fingerprint for this pack")
    p.add_argument("--pack-artifact", type=Path, help="exact shaderpack ZIP or directory to fingerprint")
    p.add_argument("--expected-pack-sha256", help="optional required SHA-256 for --pack-artifact")
    p.add_argument("--iris-properties", type=Path, default=Path.home() / "AppData/Roaming/PrismLauncher/instances/ShaderBench/minecraft/config/iris.properties")
    p.add_argument("--game-log", type=Path, default=Path.home() / "AppData/Roaming/PrismLauncher/instances/ShaderBench/minecraft/logs/latest.log")
    return p


def main(argv: list[str] | None = None) -> int:
    p = parser()
    args = p.parse_args(argv)
    if args.pid <= 0:
        p.error("--pid must be positive")
    if not 1 <= args.seconds <= MAX_SECONDS:
        p.error(f"--seconds must be between 1 and {MAX_SECONDS}")
    if not 1 <= args.interval <= min(60, args.seconds):
        p.error("--interval must be between 1 and min(60, --seconds)")
    if not 0 <= args.grace <= MAX_GRACE:
        p.error(f"--grace must be between 0 and {MAX_GRACE}")
    if args.pack_artifact and not args.pack:
        p.error("--pack-artifact requires --pack")
    if args.expected_pack_sha256 and not args.pack_artifact:
        p.error("--expected-pack-sha256 requires --pack-artifact")
    if args.pack and not args.pack_revision:
        p.error("--pack requires --pack-revision so the capture has source identity")
    try:
        result = run(args)
    except (CaptureError, OSError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(f"PresentMon CSV: {result['output_csv']} ({result['presentmon_csv_bytes']} bytes)")
    print(f"Telemetry CSV: {result['telemetry_csv']}")
    print(f"Metadata: {Path(result['output_csv']).with_suffix('').with_name(Path(result['output_csv']).stem + '.capture.json')}")
    if result.get("orchestration_error"):
        print(f"capture orchestration error: {result['orchestration_error']}", file=sys.stderr)
        return 2
    if result.get("interrupted"):
        print("capture interrupted; inspect metadata and logs", file=sys.stderr)
        return 130
    if result.get("presentmon_timed_out") or result.get("telemetry_timed_out"):
        print("capture ended by timeout; inspect metadata and logs", file=sys.stderr)
        return 2
    if not result.get("presentmon_csv_exists") or not result.get("telemetry_csv_exists"):
        print("capture output missing; inspect metadata and logs", file=sys.stderr)
        return 2
    return 0 if result.get("presentmon_returncode") == 0 and result.get("telemetry_returncode") == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
