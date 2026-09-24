"""Offline campaign review joining per-scene A/B/A perf, passive, and image evidence.

No game, capture process, or UI is launched. All files are read-only inputs.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

from PIL import Image, ImageChops

from perf_analysis import AnalysisError
from perf_gate import evaluate as evaluate_perf_gate
from stall_analysis import analyze as analyze_stall


class CampaignError(Exception):
    """Campaign evidence is incomplete or inconsistent."""


RUN_ORDER = ("A1", "B1", "A2")
GAP_BANDS = ((1000, 2000), (2000, 4000), (4000, 8000), (8000, 12000), (12000, None))


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except OSError as exc:
        raise CampaignError(f"cannot read {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise CampaignError(f"invalid JSON in {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise CampaignError(f"{path}: expected a JSON object")
    return value


def _resolve(base: Path, value: Any, context: str) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise CampaignError(f"{context} must be a non-empty relative or absolute path")
    path = Path(value)
    path = path if path.is_absolute() else base / path
    path = path.resolve()
    if not path.is_file():
        raise CampaignError(f"{context} does not exist: {path}")
    return path


def _image_metrics(path_a: Path, path_b: Path, roi: Any = None) -> dict[str, float | int]:
    with Image.open(path_a) as source_a, Image.open(path_b) as source_b:
        a, b = source_a.convert("RGB"), source_b.convert("RGB")
        if a.size != b.size:
            raise CampaignError(f"image dimensions differ: {path_a}={a.size}, {path_b}={b.size}")
        if roi is not None:
            if (not isinstance(roi, list) or len(roi) != 4
                    or any(isinstance(v, bool) or not isinstance(v, int) for v in roi)):
                raise CampaignError("visual_gate.roi must be [x, y, width, height] integers")
            x, y, width, height = roi
            if x < 0 or y < 0 or width <= 0 or height <= 0 or x + width > a.width or y + height > a.height:
                raise CampaignError(f"visual_gate.roi {roi!r} is outside {a.width}x{a.height}")
            a, b = a.crop((x, y, x + width, y + height)), b.crop((x, y, x + width, y + height))
        diff = ImageChops.difference(a, b)
        channel_histograms = [diff.getchannel(channel).histogram() for channel in range(3)]
        histogram = [sum(channel_histogram[i] for channel_histogram in channel_histograms)
                     for i in range(256)]
        pixels = a.width * a.height
        samples = pixels * 3
        rank = max(1, math.ceil(0.95 * samples))
        total = 0
        p95 = 0
        for value, count in enumerate(histogram):
            total += count
            if total >= rank:
                p95 = value
                break
        return {
            "width": a.width, "height": a.height,
            "mae_0_255": sum(i * count for i, count in enumerate(histogram)) / samples,
            "p95_abs_channel_diff": p95,
            "fraction_channels_over_8": sum(histogram[9:]) / samples,
            "max_abs_channel_diff": max((i for i, count in enumerate(histogram) if count), default=0),
        }


def _visual_review(scenario: dict[str, Any], base: Path,
                   expected_resolution: dict[str, int] | None = None) -> dict[str, Any]:
    screenshots = scenario.get("screenshots")
    if not isinstance(screenshots, dict) or set(screenshots) != set(RUN_ORDER):
        raise CampaignError(f"{scenario.get('id', '?')}: screenshots must map exactly A1, B1, A2")
    paths = {run_id: _resolve(base, screenshots[run_id], f"screenshots.{run_id}") for run_id in RUN_ORDER}
    if expected_resolution:
        expected_size = (expected_resolution.get("width"), expected_resolution.get("height"))
        for run_id, path in paths.items():
            with Image.open(path) as image:
                if image.size != expected_size:
                    raise CampaignError(f"{run_id}: screenshot size {image.size} does not match performance resolution {expected_size}")
    gate = scenario.get("visual_gate")
    if not isinstance(gate, dict):
        raise CampaignError(f"{scenario.get('id', '?')}: visual_gate thresholds are required")
    required_thresholds = ("max_control_mae", "max_candidate_mae", "max_candidate_p95")
    for key in required_thresholds:
        value = gate.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
            raise CampaignError(f"visual_gate.{key} must be a finite non-negative number")
    roi = gate.get("roi")
    a_drift = _image_metrics(paths["A1"], paths["A2"], roi)
    b_vs_a1 = _image_metrics(paths["B1"], paths["A1"], roi)
    b_vs_a2 = _image_metrics(paths["B1"], paths["A2"], roi)

    control_ok = a_drift["mae_0_255"] <= gate["max_control_mae"]
    candidate_pass = all(
        metrics["mae_0_255"] <= gate["max_candidate_mae"]
        and metrics["p95_abs_channel_diff"] <= gate["max_candidate_p95"]
        and metrics["fraction_channels_over_8"] <= gate.get("max_candidate_fraction_over_8", 1.0)
        for metrics in (b_vs_a1, b_vs_a2)
    )
    candidate_fail = all(
        metrics["mae_0_255"] > gate["max_candidate_mae"]
        or metrics["p95_abs_channel_diff"] > gate["max_candidate_p95"]
        or metrics["fraction_channels_over_8"] > gate.get("max_candidate_fraction_over_8", 1.0)
        for metrics in (b_vs_a1, b_vs_a2)
    )
    if not control_ok:
        status, reason = "INCONCLUSIVE", "A1/A2 visual drift exceeds the scene's control threshold"
    elif candidate_pass:
        status, reason = "PASS", "candidate remains within configured image-difference limits against both controls"
    elif candidate_fail:
        status, reason = "REGRESSION", "candidate exceeds a configured image-difference limit against both controls"
    else:
        status, reason = "INCONCLUSIVE", "candidate differs from one control more than the other; repeat matched captures"
    return {"status": status, "reason": reason, "roi": roi,
            "a1_vs_a2": a_drift, "b1_vs_a1": b_vs_a1, "b1_vs_a2": b_vs_a2,
            "thresholds": gate}


def _pack_attestation(scenario: dict[str, Any], perf_base: Path, campaign_base: Path,
                      perf_manifest: dict[str, Any]) -> dict[str, Any]:
    expected_scene = scenario.get("scene_id")
    runs = perf_manifest.get("runs")
    if not isinstance(runs, list) or len(runs) != 3:
        raise CampaignError(f"{scenario.get('id', '?')}: performance manifest must contain A1/B1/A2")
    by_id = {run.get("id"): run for run in runs if isinstance(run, dict)}
    if set(by_id) != set(RUN_ORDER):
        raise CampaignError(f"{scenario.get('id', '?')}: performance manifest run IDs must be A1/B1/A2")
    evidence: dict[str, Any] = {}
    hash_by_variant: dict[str, str] = {}
    for run_id in RUN_ORDER:
        run = by_id[run_id]
        capture_meta = _resolve(perf_base, run.get("capture_metadata"), f"performance {run_id}.capture_metadata")
        passive_csv = _resolve(campaign_base, scenario.get("passive_csvs", {}).get(run_id), f"passive_csvs.{run_id}")
        passive_meta = passive_csv.with_suffix("").with_name(passive_csv.stem + ".capture.json")
        if not passive_meta.is_file():
            raise CampaignError(f"passive capture metadata missing: {passive_meta}")
        perf_observation = _read_json(capture_meta)
        passive_observation = _read_json(passive_meta)
        attestation = passive_observation.get("active_pack_attestation")
        if not isinstance(attestation, dict):
            raise CampaignError(f"{passive_meta}: missing active_pack_attestation; recapture with --pack/--pack-artifact")
        selected = attestation.get("selected_pack")
        observed = attestation.get("latest_log_pack")
        expected_pack = run.get("pack")
        expected_revision = run.get("pack_revision")
        expected_hash = run.get("pack_sha256")
        if not expected_scene or run.get("scene", {}).get("id") != expected_scene:
            raise CampaignError(f"{run_id}: performance manifest scene id does not match scenario scene_id")
        if selected != expected_pack or observed != expected_pack:
            raise CampaignError(f"{run_id}: Iris config/log pack attestation mismatch: {selected!r}/{observed!r}, expected {expected_pack!r}")
        if attestation.get("pack_revision") != expected_revision:
            raise CampaignError(f"{run_id}: passive pack revision mismatch")
        if not isinstance(expected_hash, str) or len(expected_hash) != 64 or attestation.get("pack_sha256") != expected_hash.casefold():
            raise CampaignError(f"{run_id}: passive artifact SHA-256 does not match performance manifest pack_sha256")
        normalized_hash = expected_hash.casefold()
        previous_hash = hash_by_variant.setdefault(run.get("variant"), normalized_hash)
        if previous_hash != normalized_hash:
            raise CampaignError(f"variant {run.get('variant')!r} has different shaderpack content hashes within A/B/A")
        perf_pack_observation = perf_observation.get("pack_observation")
        if (perf_observation.get("pack") != expected_pack
                or perf_observation.get("pack_revision") != expected_revision
                or not isinstance(perf_pack_observation, dict)
                or perf_pack_observation.get("latest_log_pack") != expected_pack):
            raise CampaignError(f"{run_id}: PresentMon capture metadata pack/revision mismatch")
        if perf_observation.get("pack_sha256") != normalized_hash:
            raise CampaignError(f"{run_id}: PresentMon capture artifact SHA-256 mismatch")
        if run.get("process_id") is not None and passive_observation.get("process_id") != run.get("process_id"):
            raise CampaignError(f"{run_id}: passive capture PID differs from PresentMon run PID")
        image_path = _resolve(campaign_base, scenario.get("screenshots", {}).get(run_id), f"screenshots.{run_id}")
        image_meta_path = image_path.with_suffix(".image.json")
        if not image_meta_path.is_file():
            raise CampaignError(f"image capture metadata missing: {image_meta_path}; capture with harness/bench.py")
        image_meta = _read_json(image_meta_path)
        image_attestation = image_meta.get("active_pack_attestation")
        if image_meta.get("scene_id") != expected_scene or not isinstance(image_attestation, dict):
            raise CampaignError(f"{run_id}: screenshot scene/attestation metadata is missing or mismatched")
        if image_attestation.get("selected_pack") != expected_pack or image_attestation.get("latest_log_pack") != expected_pack:
            raise CampaignError(f"{run_id}: screenshot Iris config/log pack mismatch")
        if image_attestation.get("pack_sha256") != normalized_hash:
            raise CampaignError(f"{run_id}: screenshot pack artifact SHA-256 mismatch")
        evidence[run_id] = {"pack": selected, "latest_log_pack": observed,
                            "pack_revision": expected_revision, "pack_sha256": normalized_hash,
                            "process_id": passive_observation.get("process_id"),
                            "screenshot_pack_sha256": image_attestation["pack_sha256"]}
    return evidence


def _stall_review(scenario: dict[str, Any], base: Path) -> dict[str, Any]:
    csvs = scenario.get("passive_csvs")
    if not isinstance(csvs, dict) or set(csvs) != set(RUN_ORDER):
        raise CampaignError(f"{scenario.get('id', '?')}: passive_csvs must map exactly A1, B1, A2")
    reports = {run_id: analyze_stall(_resolve(base, csvs[run_id], f"passive_csvs.{run_id}")) for run_id in RUN_ORDER}
    per_run: dict[str, Any] = {}
    for run_id, report in reports.items():
        gaps = report["frames"].get("gaps_over_ms", {})
        bands: dict[str, int | None] = {}
        for low, high in GAP_BANDS:
            low_n = gaps.get(str(low))
            high_n = gaps.get(str(high)) if high is not None else 0
            label = f"{low/1000:g}-{high/1000:g}s" if high is not None else f">={low/1000:g}s"
            bands[label] = max(0, low_n - high_n) if isinstance(low_n, int) and isinstance(high_n, int) else None
        per_run[run_id] = {"frames": report["frames"], "telemetry": report["telemetry"], "gap_bands": bands}
    policy = scenario.get("stall_gate", {})
    if not isinstance(policy, dict):
        raise CampaignError("stall_gate must be an object")
    candidate_counts = per_run["B1"]["gap_bands"]
    control_counts = [per_run["A1"]["gap_bands"], per_run["A2"]["gap_bands"]]
    regressions = {}
    for band, allowance in policy.get("max_extra_gaps_by_band", {}).items():
        if isinstance(allowance, bool) or not isinstance(allowance, int) or allowance < 0:
            raise CampaignError(f"stall_gate allowance for {band!r} must be a non-negative integer")
        if band not in candidate_counts or candidate_counts[band] is None or any(item[band] is None for item in control_counts):
            continue
        if candidate_counts[band] > max(control[band] for control in control_counts) + allowance:
            regressions[band] = {"candidate": candidate_counts[band], "max_control": max(control[band] for control in control_counts), "allowed_extra": allowance}
    memory_policy = scenario.get("memory_gate", {})
    if not isinstance(memory_policy, dict):
        raise CampaignError("memory_gate must be an object")
    memory_limit_map = {
        "max_candidate_vram_mib": ("nvidia_vram_used_mib", "max"),
        "max_candidate_java_private_bytes": ("java_private_bytes", "max"),
        "min_candidate_available_physical_bytes": ("available_physical_bytes", "min"),
    }
    unknown_memory_limits = set(memory_policy) - set(memory_limit_map)
    if unknown_memory_limits:
        raise CampaignError(f"unknown memory_gate keys: {sorted(unknown_memory_limits)}")
    memory_regressions: dict[str, Any] = {}
    for hard_limit, (metric, direction) in memory_limit_map.items():
        limit = memory_policy.get(hard_limit)
        if limit is None:
            continue
        if isinstance(limit, bool) or not isinstance(limit, (int, float)) or not math.isfinite(limit):
            raise CampaignError(f"memory_gate.{hard_limit} must be a finite number")
        samples = per_run["B1"]["telemetry"].get("metrics", {}).get(metric)
        if not samples or samples.get("max") is None:
            memory_regressions[metric] = "unmeasurable"
            continue
        observed = samples["min"] if direction == "min" else samples["max"]
        failed = observed < limit if direction == "min" else observed > limit
        if failed:
            memory_regressions[metric] = {"candidate_observed": observed, "configured_limit": limit}
    required_bands = {f"{low/1000:g}-{high/1000:g}s" if high is not None else f">={low/1000:g}s"
                      for low, high in GAP_BANDS}
    stall_gated = (
        set(policy.get("max_extra_gaps_by_band", {})) == required_bands
        and all(per_run[run_id]["gap_bands"][band] is not None
                for run_id in RUN_ORDER for band in required_bands)
    )
    memory_gated = (
        bool(memory_policy)
        and not any(value == "unmeasurable" for value in memory_regressions.values())
    )
    has_regression = bool(regressions) or any(isinstance(v, dict) for v in memory_regressions.values())
    status = "REGRESSION" if has_regression else "PASS" if stall_gated and memory_gated else "DESCRIPTIVE"
    return {"status": status,
            "reason": "candidate adds configured long-frame-gap bands or crosses a configured memory limit" if regressions or any(isinstance(v, dict) for v in memory_regressions.values()) else "gap counts and memory trends are descriptive; sampled observations cannot identify cause",
            "runs": per_run, "regressions": regressions, "memory_limit_findings": memory_regressions,
            "limits": "1 second telemetry can miss shorter memory spikes; app-only CPUStartTime gaps are frame-start gaps, not present events or GPU Busy"}


def review(manifest_path: Path, min_frames: int = 1000) -> dict[str, Any]:
    manifest_path = manifest_path.resolve()
    manifest = _read_json(manifest_path)
    if manifest.get("schema_version") != 1:
        raise CampaignError("schema_version must be 1")
    scenarios = manifest.get("scenarios")
    if not isinstance(scenarios, list) or not scenarios:
        raise CampaignError("scenarios must be a non-empty list")
    ids: set[str] = set()
    results = []
    base = manifest_path.parent
    for scenario in scenarios:
        if not isinstance(scenario, dict):
            raise CampaignError("each scenario must be an object")
        scenario_id = scenario.get("id")
        if not isinstance(scenario_id, str) or not scenario_id.strip() or scenario_id in ids:
            raise CampaignError("each scenario needs a unique non-empty id")
        ids.add(scenario_id)
        if scenario.get("dimension") not in {"overworld", "nether", "end"}:
            raise CampaignError(f"{scenario_id}: dimension must be overworld, nether, or end")
        perf_path = _resolve(base, scenario.get("perf_manifest"), f"{scenario_id}.perf_manifest")
        perf_manifest = _read_json(perf_path)
        attestation = _pack_attestation(scenario, perf_path.parent, base, perf_manifest)
        perf = evaluate_perf_gate(perf_path, min_frames)
        first_run = next(run for run in perf_manifest["runs"] if run.get("id") == "A1")
        visual = _visual_review(scenario, base, first_run.get("resolution"))
        stalls = _stall_review(scenario, base)
        results.append({"id": scenario_id, "dimension": scenario["dimension"], "scene_id": scenario.get("scene_id"),
                        "active_pack_attestation": attestation, "performance": perf,
                        "visual": visual, "stalls_and_memory": stalls})

    blocking = [r for r in results if r["performance"]["status"] == "REGRESSION"
                or r["visual"]["status"] == "REGRESSION"
                or r["stalls_and_memory"]["status"] == "REGRESSION"]
    uncertain = [r for r in results if r["performance"]["status"] != "PASS"
                 or r["visual"]["status"] != "PASS"
                 or r["stalls_and_memory"]["status"] == "DESCRIPTIVE"]
    status = "REGRESSION" if blocking else "INCONCLUSIVE" if uncertain else "PASS"
    return {"schema_version": 1, "campaign_id": manifest.get("campaign_id"), "status": status,
            "scenarios": results,
            "confidence_limits": [
            "The performance gate compares steady per-frame PresentMon distributions and A/B/A drift; it is not a guarantee against rare stalls.",
            "The current performance gate only accepts at least a 5% GPU Busy median win; CPU/DH-bound improvements can remain inconclusive.",
                "Passive capture gap counts and sampled memory are correlated observations, not proof of stall cause or a memory leak.",
                "Visual thresholds and ROI are operator-defined per scene; image similarity cannot establish semantic parity.",
                "Pack identity is corroborated by selected Iris config, latest.log, source revision, and exact ZIP/folder content SHA-256.",
            ]}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path, help="campaign JSON; see shader-campaign.example.json")
    parser.add_argument("--min-frames", type=int, default=1000)
    parser.add_argument("--json-out", type=Path)
    args = parser.parse_args(argv)
    if args.min_frames < 2:
        parser.error("--min-frames must be at least 2")
    try:
        result = review(args.manifest, args.min_frames)
    except (CampaignError, AnalysisError, OSError, KeyError, TypeError, ValueError) as exc:
        result = {"schema_version": 1, "status": "INCONCLUSIVE", "reason": str(exc)}
    print(f"{result['status']}: {result.get('campaign_id', args.manifest.stem)}")
    for scenario in result.get("scenarios", []):
        print(f"  {scenario['dimension']}/{scenario['scene_id']}: perf={scenario['performance']['status']}, visual={scenario['visual']['status']}, stalls={scenario['stalls_and_memory']['status']}")
    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return {"PASS": 0, "REGRESSION": 1, "INCONCLUSIVE": 2}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
