"""Offline acceptance gate for one matched PresentMon A/B/A comparison.

Reads existing CSV and manifest files only. It never launches the game or a
profiler. GPU Busy is the default primary metric; CPU Busy or Present Interval
can be selected for a known bottleneck. See docs/perf-v3.md for thresholds and
DH state attestation.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from perf_analysis import AnalysisError, analyze


MIN_FRAMES = 1000
MAX_BASELINE_DRIFT_PERCENT = 3.0
MAX_SUPPORT_REGRESSION_PERCENT = 3.0
MIN_PRIMARY_IMPROVEMENT_PERCENT = 5.0
PRIMARY_METRICS = ("gpu-busy", "cpu-busy", "present-interval")


def _load_manifest(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except OSError as exc:
        raise AnalysisError(f"cannot read manifest {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise AnalysisError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise AnalysisError("manifest root must be a JSON object")
    return value


def _pct_change(candidate: float, baseline: float) -> float:
    if baseline == 0:
        raise AnalysisError("cannot calculate a percentage change from a zero baseline")
    return 100.0 * (candidate - baseline) / baseline


def evaluate(manifest_path: Path, min_frames: int = MIN_FRAMES,
             primary_metric: str = "gpu-busy") -> dict[str, Any]:
    """Evaluate exactly three matched runs: baseline, candidate, baseline."""
    if primary_metric not in PRIMARY_METRICS:
        raise AnalysisError(f"primary_metric must be one of {', '.join(PRIMARY_METRICS)}")
    manifest = _load_manifest(manifest_path)
    runs = manifest.get("runs")
    baseline_variant = manifest.get("baseline_variant")
    if not isinstance(runs, list) or len(runs) != 3:
        raise AnalysisError("acceptance gate requires exactly three runs ordered A/B/A")
    if not isinstance(baseline_variant, str) or not baseline_variant.strip():
        raise AnalysisError("baseline_variant must be a non-empty string")
    if not all(isinstance(run, dict) for run in runs):
        raise AnalysisError("each run must be an object")
    variants = [run.get("variant") for run in runs]
    if variants[0] != baseline_variant or variants[2] != baseline_variant or variants[1] == baseline_variant:
        raise AnalysisError("run variants must be baseline, candidate, baseline (A/B/A)")

    # The existing analyzer is the source of truth for PID/swapchain selection,
    # row validity, warm-up, resolution and shared scene/environment checks.
    reports = {
        metric: analyze(manifest_path, metric, min_frames)
        for metric in ("gpu-busy", "cpu-busy", "present-interval")
    }
    dh_states = [run.get("dh_state") for run in runs]
    if any(not isinstance(state, str) or not state.strip() for state in dh_states):
        raise AnalysisError("each run needs a categorical dh_state attestation (use 'unknown' if unavailable)")
    normalized_dh = [state.strip().casefold() for state in dh_states]
    if any(state == "unknown" for state in normalized_dh):
        return {
            "status": "INCONCLUSIVE",
            "reason": "DH state is unknown for at least one run; chunks=true does not attest DH queue state",
            "primary_metric": primary_metric,
            "dh_state_by_run": dict(zip((run.get("id", f"run{i+1}") for i, run in enumerate(runs)), dh_states)),
        }
    if len(set(normalized_dh)) != 1:
        return {
            "status": "INCONCLUSIVE",
            "reason": "DH state differs across A/B/A; captures are not matched",
            "primary_metric": primary_metric,
            "dh_state_by_run": dict(zip((run.get("id", f"run{i+1}") for i, run in enumerate(runs)), dh_states)),
        }

    first_id, candidate_id, last_id = [run["id"] for run in runs]
    changes: dict[str, dict[str, float]] = {}
    drift: dict[str, float] = {}
    samples: dict[str, dict[str, int]] = {}
    for metric, report in reports.items():
        run_results = {result["id"]: result for result in report["runs"]}
        first, candidate, last = (run_results[run_id] for run_id in (first_id, candidate_id, last_id))
        bracket_center = (first["median_ms"] + last["median_ms"]) / 2
        drift[metric] = abs(_pct_change(last["median_ms"], first["median_ms"]))
        changes[metric] = {
            "median_percent": _pct_change(candidate["median_ms"], bracket_center),
            "p95_percent": _pct_change(candidate["p95_ms"], (first["p95_ms"] + last["p95_ms"]) / 2),
        }
        samples[metric] = {run_id: run_results[run_id]["samples"] for run_id in (first_id, candidate_id, last_id)}

    if any(value > MAX_BASELINE_DRIFT_PERCENT for value in drift.values()):
        return {
            "status": "INCONCLUSIVE",
            "reason": f"A1/A2 median drift exceeds {MAX_BASELINE_DRIFT_PERCENT:.1f}% for at least one metric",
            "primary_metric": primary_metric,
            "dh_state": dh_states[0], "baseline_drift_percent": drift,
            "candidate_change_percent": changes, "usable_samples": samples,
        }

    regressions = {
        metric: change
        for metric, change in changes.items()
        if change["median_percent"] > MAX_SUPPORT_REGRESSION_PERCENT
        or change["p95_percent"] > MAX_SUPPORT_REGRESSION_PERCENT
    }
    if regressions:
        return {
            "status": "REGRESSION",
            "reason": f"candidate worsens median or p95 by more than {MAX_SUPPORT_REGRESSION_PERCENT:.1f}%",
            "primary_metric": primary_metric,
            "dh_state": dh_states[0], "baseline_drift_percent": drift,
            "candidate_change_percent": changes, "regressions": regressions,
            "usable_samples": samples,
        }

    primary_change = changes[primary_metric]["median_percent"]
    minimum_improvement = max(
        MIN_PRIMARY_IMPROVEMENT_PERCENT,
        2 * drift[primary_metric],
    )
    if primary_change > -minimum_improvement:
        return {
            "status": "INCONCLUSIVE",
            "reason": f"{primary_metric} median improvement is below the required {minimum_improvement:.1f}%",
            "primary_metric": primary_metric,
            "dh_state": dh_states[0], "baseline_drift_percent": drift,
            "candidate_change_percent": changes, "usable_samples": samples,
        }

    other_metrics = ", ".join(metric for metric in PRIMARY_METRICS if metric != primary_metric)
    return {
        "status": "PASS",
        "reason": f"{primary_metric} median improves by at least {minimum_improvement:.1f}%; {other_metrics} show no >3.0% median/p95 regression",
        "primary_metric": primary_metric,
        "dh_state": dh_states[0], "baseline_drift_percent": drift,
        "candidate_change_percent": changes, "usable_samples": samples,
        "thresholds": {
            "minimum_frames_per_metric_per_run": min_frames,
            "maximum_baseline_median_drift_percent": MAX_BASELINE_DRIFT_PERCENT,
            "minimum_primary_improvement_percent": MIN_PRIMARY_IMPROVEMENT_PERCENT,
            "minimum_improvement_vs_observed_primary_drift_multiplier": 2,
            "maximum_metric_regression_percent_median_or_p95": MAX_SUPPORT_REGRESSION_PERCENT,
        },
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="metadata-complete A/B/A manifest")
    parser.add_argument("--min-frames", type=int, default=MIN_FRAMES,
                        help=f"minimum usable samples per run and metric (default: {MIN_FRAMES})")
    parser.add_argument("--primary-metric", choices=PRIMARY_METRICS, default="gpu-busy",
                        help="which cost or cadence must improve; default gpu-busy")
    parser.add_argument("--json-out", type=Path, help="also write the gate result as JSON")
    args = parser.parse_args(argv)
    if args.min_frames < 2:
        parser.error("--min-frames must be at least 2")
    try:
        result = evaluate(args.manifest, args.min_frames, args.primary_metric)
    except (AnalysisError, OSError, KeyError, TypeError) as exc:
        result = {"status": "INCONCLUSIVE", "reason": str(exc)}
    print(f"{result['status']}: {result['reason']}")
    for metric, drift in result.get("baseline_drift_percent", {}).items():
        change = result["candidate_change_percent"][metric]
        print(f"  {metric}: A drift={drift:.2f}%, B median={change['median_percent']:+.2f}%, B p95={change['p95_percent']:+.2f}%")
    for metric, counts in result.get("usable_samples", {}).items():
        print(f"  {metric} usable frames: " + ", ".join(f"{run}={count}" for run, count in counts.items()))
    if "dh_state" in result:
        print(f"  DH state: {result['dh_state']}")
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return {"PASS": 0, "INCONCLUSIVE": 2, "REGRESSION": 1}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
