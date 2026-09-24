"""Validate matched PresentMon captures and summarize per-frame timings.

The analyzer is deliberately offline. It never launches Minecraft or PresentMon.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Any


class AnalysisError(Exception):
    """An input cannot support a defensible comparison."""


METRICS = {
    "gpu-busy": ("MsGPUBusy", "msGPUActive"),
    "cpu-busy": ("MsCPUBusy", "msCPUBusy"),
    "gpu-time": ("MsGPUTime",),
    "present-interval": ("MsBetweenPresents", "msBetweenPresents"),
}
TIME_COLUMNS = (
    "CPUStartTime",
    "CPUStartQPCTime",
    "CPUStartTimeInMs",
    "TimeInSeconds",
    "TimeInMs",
)
WIDTH_COLUMNS = ("Width", "SwapChainWidth", "PresentWidth")
HEIGHT_COLUMNS = ("Height", "SwapChainHeight", "PresentHeight")


def _fail(message: str) -> None:
    raise AnalysisError(message)


def _normalized_headers(fieldnames: list[str] | None, csv_path: Path) -> dict[str, str]:
    if not fieldnames:
        _fail(f"{csv_path}: missing CSV header")
    headers: dict[str, str] = {}
    for original in fieldnames:
        normalized = original.strip().casefold()
        if not normalized:
            continue
        if normalized in headers:
            _fail(f"{csv_path}: duplicate CSV column after case normalization: {original!r}")
        headers[normalized] = original
    return headers


def _column(headers: dict[str, str], *names: str) -> str | None:
    for name in names:
        found = headers.get(name.casefold())
        if found is not None:
            return found
    return None


def _number(raw: Any) -> float | None:
    if raw is None:
        return None
    value = str(raw).strip()
    if not value or value.casefold() in {"na", "n/a", "nan", "null", "none"}:
        return None
    try:
        number = float(value)
    except ValueError:
        return None
    return number if math.isfinite(number) else None


def _process_basename(value: str) -> str:
    return value.strip().replace("\\", "/").rsplit("/", 1)[-1].casefold()


def _address_key(value: str) -> str:
    raw = value.strip()
    try:
        return str(int(raw, 0))
    except ValueError:
        return raw.casefold()


def _timestamp_seconds(raw: Any, column_name: str | None) -> float | None:
    value = _number(raw)
    if value is None or column_name is None:
        return None
    normalized = column_name.strip().casefold()
    if normalized in {"cpustarttimeinms", "cpustarttime", "cpustartqpctime", "timeinms"}:
        return value / 1000.0
    if normalized in {"cpustarttime", "timeinseconds"}:
        return value
    return None


def _percentile(values: list[float], percentile: float) -> float:
    """Nearest-rank percentile (rank = ceil(p*n), one-based)."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percentile * len(ordered)) - 1)]


def summarize(values: list[float]) -> dict[str, float | int | None]:
    if not values:
        _fail("no usable timing samples remain after filtering")
    return {
        "samples": len(values),
        "median_ms": statistics.median(values),
        "p95_ms": _percentile(values, 0.95),
        "p99_ms": _percentile(values, 0.99),
        "mean_ms": statistics.fmean(values),
        "sample_variance_ms2": statistics.variance(values) if len(values) > 1 else None,
    }


def _validate_manifest(path: Path) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8-sig"))
    except OSError as exc:
        _fail(f"cannot read manifest {path}: {exc}")
    except json.JSONDecodeError as exc:
        _fail(f"invalid JSON in {path}: {exc}")
    if not isinstance(manifest, dict):
        _fail("manifest root must be a JSON object")
    if manifest.get("schema_version") != 1:
        _fail("schema_version must be 1")
    for key in ("comparison_id", "baseline_variant"):
        if not isinstance(manifest.get(key), str) or not manifest[key].strip():
            _fail(f"manifest {key} must be a non-empty string")
    warmup = manifest.get("warmup_seconds")
    if isinstance(warmup, bool) or not isinstance(warmup, (int, float)) or not math.isfinite(warmup) or warmup < 0:
        _fail("warmup_seconds must be a finite non-negative number")
    runs = manifest.get("runs")
    if not isinstance(runs, list) or len(runs) < 3:
        _fail("runs must contain at least three ordered captures in a baseline-bracketed sequence (A/B/A)")

    required = ("id", "variant", "pack", "pack_revision", "csv", "scene", "resolution", "environment")
    ids: set[str] = set()
    variants: list[str] = []
    pack_by_variant: dict[str, tuple[str, str]] = {}
    common_scene: Any = None
    common_resolution: Any = None
    common_environment: Any = None
    for index, run in enumerate(runs):
        if not isinstance(run, dict):
            _fail(f"runs[{index}] must be an object")
        for key in required:
            if key not in run:
                _fail(f"runs[{index}] is missing required field {key!r}")
        for key in ("id", "variant", "pack", "pack_revision", "csv"):
            if not isinstance(run[key], str) or not run[key].strip():
                _fail(f"runs[{index}].{key} must be a non-empty string")
        run_id = run["id"].strip()
        if run_id in ids:
            _fail(f"duplicate run id {run_id!r}")
        ids.add(run_id)
        variant = run["variant"].strip()
        variants.append(variant)
        identity = (run["pack"].strip(), run["pack_revision"].strip())
        previous_identity = pack_by_variant.setdefault(variant, identity)
        if previous_identity != identity:
            _fail(
                f"variant {variant!r} has inconsistent pack metadata: "
                f"{previous_identity!r} versus {identity!r}"
            )
        resolution = run["resolution"]
        if not isinstance(resolution, dict) or set(("width", "height")) - resolution.keys():
            _fail(f"runs[{index}].resolution must contain integer width and height")
        for dim in ("width", "height"):
            value = resolution[dim]
            if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
                _fail(f"runs[{index}].resolution.{dim} must be a positive integer")
        if not isinstance(run["scene"], dict) or not run["scene"]:
            _fail(f"runs[{index}].scene must be a non-empty object (include scene id and exact pose)")
        if not isinstance(run["environment"], dict) or not run["environment"]:
            _fail(f"runs[{index}].environment must be a non-empty object")
        if index == 0:
            common_scene = run["scene"]
            common_resolution = resolution
            common_environment = run["environment"]
        else:
            if run["scene"] != common_scene:
                _fail(f"scene/pose metadata mismatch at run {run_id!r}")
            if resolution != common_resolution:
                _fail(f"resolution metadata mismatch at run {run_id!r}")
            if run["environment"] != common_environment:
                _fail(f"environment metadata mismatch at run {run_id!r}")
        if "process_id" in run and (isinstance(run["process_id"], bool) or not isinstance(run["process_id"], int) or run["process_id"] <= 0):
            _fail(f"runs[{index}].process_id must be a positive integer")
        if "swapchain_address" in run and not isinstance(run["swapchain_address"], str):
            _fail(f"runs[{index}].swapchain_address must be a string")

    unique_variants = set(variants)
    baseline = manifest["baseline_variant"]
    if len(unique_variants) < 2:
        _fail("at least two variants are required")
    if baseline not in unique_variants:
        _fail(f"baseline_variant {baseline!r} is not present in runs")
    if variants[0] != baseline or variants[-1] != baseline or variants.count(baseline) < 2:
        _fail("run order must start and end with the baseline variant to bracket drift (A/B/A)")

    base = path.resolve().parent
    for run in runs:
        csv_path = (base / run["csv"]).resolve()
        if not csv_path.is_file():
            _fail(f"run {run['id']!r}: CSV file does not exist: {csv_path}")
        run["_csv_path"] = csv_path
    return manifest, runs


def _read_run(run: dict[str, Any], metric_name: str, warmup_seconds: float, min_frames: int) -> dict[str, Any]:
    csv_path: Path = run["_csv_path"]
    aliases = METRICS[metric_name]
    try:
        handle = csv_path.open("r", encoding="utf-8-sig", newline="")
    except OSError as exc:
        _fail(f"run {run['id']!r}: cannot read {csv_path}: {exc}")
    with handle:
        reader = csv.DictReader(handle)
        headers = _normalized_headers(reader.fieldnames, csv_path)
        app_col = _column(headers, "Application")
        pid_col = _column(headers, "ProcessID")
        swap_col = _column(headers, "SwapChainAddress")
        metric_col = _column(headers, *aliases)
        time_col = _column(headers, *TIME_COLUMNS)
        if app_col is None or pid_col is None:
            _fail(f"{csv_path}: expected PresentMon Application and ProcessID columns")
        if metric_col is None:
            _fail(f"{csv_path}: no {metric_name} metric column; expected one of {aliases!r}")
        if warmup_seconds > 0 and time_col is None:
            _fail(f"{csv_path}: warm-up exclusion requested but no PresentMon frame time column was found")

        java_rows: list[dict[str, str]] = []
        java_pids: set[int] = set()
        for row in reader:
            application = (row.get(app_col) or "").strip()
            if _process_basename(application) != "javaw.exe":
                continue
            try:
                pid = int((row.get(pid_col) or "").strip())
            except ValueError:
                _fail(f"{csv_path}: javaw.exe row has an invalid ProcessID")
            if "process_id" in run and pid != run["process_id"]:
                continue
            java_pids.add(pid)
            java_rows.append(row)
        if not java_rows:
            expected = f" PID {run['process_id']}" if "process_id" in run else ""
            _fail(f"{csv_path}: no javaw.exe rows{expected}; check process_name/java process_id")
        if len(java_pids) != 1:
            _fail(f"{csv_path}: found multiple javaw.exe process IDs {sorted(java_pids)}; specify process_id in that run")
        selected_pid = next(iter(java_pids))

        if swap_col is None:
            _fail(f"{csv_path}: missing SwapChainAddress; cannot ensure one game swap chain is analyzed")
        addresses = {
            _address_key(row.get(swap_col, ""))
            for row in java_rows
            if (row.get(swap_col) or "").strip()
        }
        if "swapchain_address" in run:
            desired_address = _address_key(run["swapchain_address"])
            java_rows = [row for row in java_rows if _address_key(row.get(swap_col, "")) == desired_address]
            if not java_rows:
                _fail(f"{csv_path}: no rows for requested swapchain_address {run['swapchain_address']!r}")
            selected_address = desired_address
        else:
            if len(addresses) != 1:
                _fail(
                    f"{csv_path}: found {len(addresses)} Java swap chains; specify swapchain_address "
                    "in the run metadata to select the Minecraft render chain"
                )
            selected_address = next(iter(addresses))

        width_col = _column(headers, *WIDTH_COLUMNS)
        height_col = _column(headers, *HEIGHT_COLUMNS)
        expected_width = run["resolution"]["width"]
        expected_height = run["resolution"]["height"]
        runtimes_col = _column(headers, "PresentRuntime", "Runtime")
        frame_types_col = _column(headers, "FrameType")
        runtime_values: set[str] = set()
        frame_types: set[str] = set()
        samples: list[tuple[float | None, float]] = []
        frame_timestamps: list[float] = []
        invalid_metric_rows = 0
        checked_rows = 0
        for row in java_rows:
            if _address_key(row.get(swap_col, "")) != selected_address:
                continue
            checked_rows += 1
            if width_col and height_col:
                width = _number(row.get(width_col))
                height = _number(row.get(height_col))
                if width is not None and int(width) != expected_width:
                    _fail(f"{csv_path}: CSV width {width:g} mismatches manifest width {expected_width}")
                if height is not None and int(height) != expected_height:
                    _fail(f"{csv_path}: CSV height {height:g} mismatches manifest height {expected_height}")
            if runtimes_col:
                runtime = (row.get(runtimes_col) or "").strip()
                if runtime:
                    runtime_values.add(runtime)
            if frame_types_col:
                frame_type = (row.get(frame_types_col) or "").strip()
                if frame_type:
                    frame_types.add(frame_type)
            value = _number(row.get(metric_col))
            timestamp = _timestamp_seconds(row.get(time_col), time_col) if time_col else None
            if timestamp is not None:
                frame_timestamps.append(timestamp)
            if value is None or value < 0:
                invalid_metric_rows += 1
                continue
            samples.append((timestamp, value))

        if checked_rows == 0:
            _fail(f"{csv_path}: no rows remain for process/swapchain selection")
        if len(runtime_values) > 1:
            _fail(f"{csv_path}: selected swapchain changed PresentRuntime within the capture: {sorted(runtime_values)}")
        if len(frame_types) > 1:
            _fail(f"{csv_path}: mixed FrameType rows {sorted(frame_types)}; use a capture with a stable frame type")
        if not samples:
            _fail(f"{csv_path}: no non-negative finite {metric_name} samples in the selected swapchain")

        warmup_dropped = 0
        if warmup_seconds > 0:
            if not frame_timestamps:
                _fail(f"{csv_path}: no numeric frame timestamps available to apply warm-up exclusion")
            start = min(frame_timestamps)
            cutoff = start + warmup_seconds
            filtered = [(timestamp, value) for timestamp, value in samples if timestamp is not None and timestamp >= cutoff]
            warmup_dropped = len(samples) - len(filtered)
            samples = filtered
        values = [value for _, value in samples]
        if len(values) < min_frames:
            _fail(
                f"{csv_path}: only {len(values)} usable {metric_name} samples after warm-up, "
                f"below minimum {min_frames}; capture longer or lower --min-frames deliberately"
            )

    stats = summarize(values)
    return {
        "id": run["id"],
        "variant": run["variant"],
        "pack": run["pack"],
        "pack_revision": run["pack_revision"],
        "csv": str(csv_path),
        "process_id": selected_pid,
        "swapchain_address": selected_address,
        "present_runtime": next(iter(runtime_values), None),
        "frame_type": next(iter(frame_types), None),
        "metric_column": metric_col,
        "warmup_dropped_frames": warmup_dropped,
        "invalid_metric_rows": invalid_metric_rows,
        **stats,
    }


def analyze(manifest_path: Path, metric_name: str, min_frames: int) -> dict[str, Any]:
    manifest, runs = _validate_manifest(manifest_path)
    results = [
        _read_run(run, metric_name, float(manifest["warmup_seconds"]), min_frames)
        for run in runs
    ]
    runtime_names = {result["present_runtime"] for result in results if result["present_runtime"] is not None}
    if len(runtime_names) > 1:
        _fail(f"PresentRuntime mismatch across matched runs: {sorted(runtime_names)}")
    frame_types = {result["frame_type"] for result in results if result["frame_type"] is not None}
    if len(frame_types) > 1:
        _fail(f"FrameType mismatch across matched runs: {sorted(frame_types)}")

    variant_names = list(dict.fromkeys(run["variant"] for run in runs))
    grouped: dict[str, list[dict[str, Any]]] = {name: [] for name in variant_names}
    for result in results:
        grouped[result["variant"]].append(result)
    baseline = manifest["baseline_variant"]
    base_trials = grouped[baseline]
    baseline_drift = None
    if len(base_trials) >= 2:
        first, last = base_trials[0], base_trials[-1]
        baseline_drift = {
            "first_run": first["id"],
            "last_run": last["id"],
            "median_ms_first": first["median_ms"],
            "median_ms_last": last["median_ms"],
            "median_change_percent": 100.0 * (last["median_ms"] - first["median_ms"]) / first["median_ms"],
        }

    variants: dict[str, Any] = {}
    for name, trials in grouped.items():
        variants[name] = {
            "pack": trials[0]["pack"],
            "pack_revision": trials[0]["pack_revision"],
            "captures": len(trials),
            "median_of_capture_medians_ms": statistics.median(trial["median_ms"] for trial in trials),
            "median_of_capture_p95_ms": statistics.median(trial["p95_ms"] for trial in trials),
            "median_of_capture_p99_ms": statistics.median(trial["p99_ms"] for trial in trials),
            "median_of_capture_variance_ms2": statistics.median(
                trial["sample_variance_ms2"] for trial in trials if trial["sample_variance_ms2"] is not None
            ),
        }
    baseline_median = variants[baseline]["median_of_capture_medians_ms"]
    deltas = {
        name: {
            "median_change_percent_vs_baseline": 100.0 * (values["median_of_capture_medians_ms"] - baseline_median) / baseline_median,
            "p95_change_percent_vs_baseline": 100.0 * (values["median_of_capture_p95_ms"] - variants[baseline]["median_of_capture_p95_ms"]) / variants[baseline]["median_of_capture_p95_ms"],
            "p99_change_percent_vs_baseline": 100.0 * (values["median_of_capture_p99_ms"] - variants[baseline]["median_of_capture_p99_ms"]) / variants[baseline]["median_of_capture_p99_ms"],
        }
        for name, values in variants.items()
        if name != baseline
    }
    return {
        "comparison_id": manifest["comparison_id"],
        "metric": metric_name,
        "baseline_variant": baseline,
        "warmup_seconds_excluded_per_capture": manifest["warmup_seconds"],
        "match_metadata": {
            "scene": runs[0]["scene"],
            "resolution": runs[0]["resolution"],
            "environment": runs[0]["environment"],
            "present_runtime": next(iter(runtime_names), None),
            "frame_type": next(iter(frame_types), None),
        },
        "run_order": [run["variant"] for run in runs],
        "baseline_bracket_drift": baseline_drift,
        "variant_summaries": variants,
        "changes_vs_baseline": deltas,
        "runs": results,
        "statistical_notes": {
            "percentile_method": "nearest rank: sorted[ceil(p*n)-1]",
            "variance": "sample variance with denominator n-1, in ms^2",
            "variant_aggregation": "median of per-capture statistics; frames are not pooled across captures",
        },
    }


def _format_number(value: Any, places: int = 3) -> str:
    return "n/a" if value is None else f"{value:.{places}f}"


def print_summary(result: dict[str, Any]) -> None:
    print(f"Comparison: {result['comparison_id']}  metric: {result['metric']}")
    drift = result["baseline_bracket_drift"]
    if drift:
        print(
            "Baseline bracket drift: "
            f"{drift['first_run']} to {drift['last_run']} = "
            f"{drift['median_change_percent']:+.2f}% median "
            f"({_format_number(drift['median_ms_first'])} to {_format_number(drift['median_ms_last'])} ms)"
        )
    print("variant | captures | median ms | p95 ms | p99 ms | variance ms^2 | median Δ% | p95 Δ% | p99 Δ%")
    baseline = result["baseline_variant"]
    for name, summary in result["variant_summaries"].items():
        deltas = result["changes_vs_baseline"].get(name)
        delta_texts = (
            ("baseline", "baseline", "baseline")
            if name == baseline
            else tuple(
                f"{_format_number(deltas[key], 2)}%"
                for key in (
                    "median_change_percent_vs_baseline",
                    "p95_change_percent_vs_baseline",
                    "p99_change_percent_vs_baseline",
                )
            )
        )
        print(
            f"{name} | {summary['captures']} | "
            f"{_format_number(summary['median_of_capture_medians_ms'])} | "
            f"{_format_number(summary['median_of_capture_p95_ms'])} | "
            f"{_format_number(summary['median_of_capture_p99_ms'])} | "
            f"{_format_number(summary['median_of_capture_variance_ms2'])} | "
            f"{delta_texts[0]} | {delta_texts[1]} | {delta_texts[2]}"
        )
    print("\nPer-capture frame samples:")
    for run in result["runs"]:
        print(
            f"  {run['id']} ({run['variant']}): n={run['samples']}, "
            f"median={_format_number(run['median_ms'])} ms, "
            f"p95={_format_number(run['p95_ms'])} ms, "
            f"p99={_format_number(run['p99_ms'])} ms, "
            f"variance={_format_number(run['sample_variance_ms2'])} ms^2, "
            f"warmup_dropped={run['warmup_dropped_frames']}"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="JSON manifest with ordered matched PresentMon captures")
    parser.add_argument("--metric", choices=sorted(METRICS), default="gpu-busy", help="gpu-busy is the recommended shader-cost metric; cpu-busy and present-interval are useful context")
    parser.add_argument("--min-frames", type=int, default=1000, help="minimum usable per-capture samples after warm-up (default: 1000)")
    parser.add_argument("--json-out", type=Path, help="also write the complete report as JSON")
    args = parser.parse_args(argv)
    if args.min_frames < 2:
        parser.error("--min-frames must be at least 2")
    try:
        result = analyze(args.manifest, args.metric, args.min_frames)
        print_summary(result)
        if args.json_out:
            args.json_out.parent.mkdir(parents=True, exist_ok=True)
            args.json_out.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    except (AnalysisError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
