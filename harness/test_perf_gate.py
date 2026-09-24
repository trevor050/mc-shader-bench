"""Offline tests for the combined A/B/A acceptance gate."""

from __future__ import annotations

import csv
import json
import tempfile
import unittest
from pathlib import Path

from perf_gate import evaluate
from perf_analysis import AnalysisError


HEADERS = [
    "Application", "ProcessID", "SwapChainAddress", "MsGPUBusy", "MsCPUBusy",
    "MsBetweenPresents", "CPUStartTimeInMs", "Width", "Height",
]


class PerfGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.manifest_path = self.base / "manifest.json"
        self.runs = []

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_run(self, run_id: str, variant: str, gpu: float, cpu: float = 3.0,
                  present: float = 10.0, frames: int = 1100, dh_state: str = "idle",
                  scene_id: str = "fixed-vista") -> dict:
        csv_path = self.base / f"{run_id}.csv"
        with csv_path.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=HEADERS)
            writer.writeheader()
            for index in range(frames):
                writer.writerow({
                    "Application": "javaw.exe", "ProcessID": 4321, "SwapChainAddress": "0x1",
                    "MsGPUBusy": gpu, "MsCPUBusy": cpu, "MsBetweenPresents": present,
                    "CPUStartTimeInMs": index * 10, "Width": 1920, "Height": 1080,
                })
        return {
            "id": run_id, "variant": variant, "pack": "ClaudeBench",
            "pack_revision": f"rev-{variant}", "csv": csv_path.name,
            "scene": {"id": scene_id, "x": 10, "y": 100, "z": 20, "yaw": 0, "pitch": 0, "time": 6000},
            "resolution": {"width": 1920, "height": 1080},
            "environment": {"game": "26.2", "gpu": "RTX 4070"},
            "dh_state": dh_state,
        }

    def write_manifest(self, a1: dict, b: dict, a2: dict) -> None:
        self.manifest_path.write_text(json.dumps({
            "schema_version": 1, "comparison_id": "gate-test", "baseline_variant": "A",
            "warmup_seconds": 0, "runs": [a1, b, a2],
        }), encoding="utf-8")

    def standard_runs(self, *, a2_gpu: float = 8.1, b_gpu: float = 7.0,
                      b_cpu: float = 3.0, dh: str = "idle", frames: int = 1100):
        return (
            self.write_run("A1", "A", 8.0, frames=frames, dh_state=dh),
            self.write_run("B1", "B", b_gpu, cpu=b_cpu, frames=frames, dh_state=dh),
            self.write_run("A2", "A", a2_gpu, frames=frames, dh_state=dh),
        )

    def test_passes_clear_gpu_improvement_with_stable_bracket(self) -> None:
        self.write_manifest(*self.standard_runs())
        result = evaluate(self.manifest_path)
        self.assertEqual(result["status"], "PASS")
        self.assertLess(result["candidate_change_percent"]["gpu-busy"]["median_percent"], -5)

    def test_unstable_baseline_is_inconclusive(self) -> None:
        self.write_manifest(*self.standard_runs(a2_gpu=9.0))
        result = evaluate(self.manifest_path)
        self.assertEqual(result["status"], "INCONCLUSIVE")
        self.assertIn("drift", result["reason"])

    def test_unknown_dh_state_is_inconclusive(self) -> None:
        self.write_manifest(*self.standard_runs(dh="unknown"))
        result = evaluate(self.manifest_path)
        self.assertEqual(result["status"], "INCONCLUSIVE")
        self.assertIn("DH state is unknown", result["reason"])

    def test_dh_state_change_is_inconclusive(self) -> None:
        a1, b, a2 = self.standard_runs()
        b["dh_state"] = "active"
        self.write_manifest(a1, b, a2)
        self.assertEqual(evaluate(self.manifest_path)["status"], "INCONCLUSIVE")

    def test_cpu_regression_fails_even_when_gpu_improves(self) -> None:
        self.write_manifest(*self.standard_runs(b_cpu=4.0))
        result = evaluate(self.manifest_path)
        self.assertEqual(result["status"], "REGRESSION")
        self.assertIn("cpu-busy", result["regressions"])

    def test_changed_scene_is_inconclusive(self) -> None:
        a1, b, a2 = self.standard_runs()
        b["scene"]["yaw"] = 10
        self.write_manifest(a1, b, a2)
        with self.assertRaises(AnalysisError):
            evaluate(self.manifest_path)

    def test_too_few_rows_is_rejected_by_minimum_sample_gate(self) -> None:
        self.write_manifest(*self.standard_runs(frames=20))
        with self.assertRaises(AnalysisError):
            evaluate(self.manifest_path)


if __name__ == "__main__":
    unittest.main()
