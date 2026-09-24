"""Focused tests for metadata rejection and PresentMon CSV aggregation."""

import json
import tempfile
import unittest
from pathlib import Path

from perf_analysis import AnalysisError, analyze


HEADER = (
    "Application,ProcessID,SwapChainAddress,PresentRuntime,CPUStartTimeInMs,"
    "MsGPUBusy,MsCPUBusy,MsBetweenPresents,Width,Height\n"
)


class PerfAnalysisTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        for run_id, offset in (("A1", 0), ("B1", -2), ("A2", 0.5)):
            rows = [
                (0, 10 + offset, 8 + offset, 15 + offset),
                (1000, 11 + offset, 9 + offset, 14 + offset),
                (2000, 12 + offset, 10 + offset, 13 + offset),
                (3000, 13 + offset, 11 + offset, 12 + offset),
            ]
            text = HEADER + "".join(
                f"javaw.exe,123,0xABCD,DXGI,{timestamp},{gpu},{cpu},{present},1920,1080\n"
                for timestamp, gpu, cpu, present in rows
            )
            (self.root / f"{run_id}.csv").write_text(text, encoding="utf-8")
        self.manifest = {
            "schema_version": 1,
            "comparison_id": "test",
            "baseline_variant": "A",
            "warmup_seconds": 1,
            "runs": [
                self._run("A1", "A", "ClaudeBench", "base", "A1.csv"),
                self._run("B1", "B", "ClaudeBench", "candidate", "B1.csv"),
                self._run("A2", "A", "ClaudeBench", "base", "A2.csv"),
            ],
        }
        self.manifest_path = self.root / "manifest.json"
        self._write_manifest()

    def tearDown(self):
        self.temp.cleanup()

    def _run(self, run_id, variant, pack, revision, csv_name):
        return {
            "id": run_id,
            "variant": variant,
            "pack": pack,
            "pack_revision": revision,
            "csv": csv_name,
            "scene": {"id": "nether", "x": 0.5, "y": 80, "z": 0.5, "yaw": -180, "pitch": 15},
            "resolution": {"width": 1920, "height": 1080},
            "environment": {"game_version": "MC 26.2", "gpu": "RTX 4070"},
        }

    def _write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest), encoding="utf-8")

    def test_warmup_and_nearest_rank_summary_for_gpu_cpu_and_present(self):
        gpu = analyze(self.manifest_path, "gpu-busy", 2)
        cpu = analyze(self.manifest_path, "cpu-busy", 2)
        present = analyze(self.manifest_path, "present-interval", 2)
        self.assertEqual(gpu["runs"][0]["warmup_dropped_frames"], 1)
        self.assertEqual(gpu["runs"][0]["samples"], 3)
        self.assertEqual(gpu["runs"][0]["median_ms"], 12)
        self.assertEqual(gpu["runs"][0]["p95_ms"], 13)
        self.assertEqual(gpu["runs"][0]["p99_ms"], 13)
        self.assertEqual(gpu["runs"][0]["sample_variance_ms2"], 1)
        self.assertEqual(cpu["runs"][0]["median_ms"], 10)
        self.assertEqual(present["runs"][0]["median_ms"], 13)

    def test_rejects_resolution_mismatch(self):
        self.manifest["runs"][1]["resolution"]["width"] = 2560
        self._write_manifest()
        with self.assertRaisesRegex(AnalysisError, "resolution metadata mismatch"):
            analyze(self.manifest_path, "gpu-busy", 2)

    def test_rejects_scene_mismatch(self):
        self.manifest["runs"][1]["scene"]["yaw"] = 0
        self._write_manifest()
        with self.assertRaisesRegex(AnalysisError, "scene/pose metadata mismatch"):
            analyze(self.manifest_path, "gpu-busy", 2)

    def test_rejects_pack_revision_mismatch_within_variant(self):
        self.manifest["runs"][2]["pack_revision"] = "wrong-revision"
        self._write_manifest()
        with self.assertRaisesRegex(AnalysisError, "inconsistent pack metadata"):
            analyze(self.manifest_path, "gpu-busy", 2)

    def test_rejects_resolution_mismatch_in_csv_rows(self):
        csv_path = self.root / "A1.csv"
        text = csv_path.read_text(encoding="utf-8")
        csv_path.write_text(text.replace(",1920,1080", ",2560,1080", 1), encoding="utf-8")
        with self.assertRaisesRegex(AnalysisError, "CSV width 2560 mismatches manifest width 1920"):
            analyze(self.manifest_path, "gpu-busy", 2)

    def test_rejects_environment_mismatch(self):
        self.manifest["runs"][1]["environment"]["driver"] = "different"
        self._write_manifest()
        with self.assertRaisesRegex(AnalysisError, "environment metadata mismatch"):
            analyze(self.manifest_path, "gpu-busy", 2)


if __name__ == "__main__":
    unittest.main()
