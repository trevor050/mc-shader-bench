"""Focused offline checks for campaign image gates and exact pack fingerprints."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from PIL import Image

from campaign_review import CampaignError, _image_metrics, _pack_attestation, _stall_review, _visual_review
from pack_fingerprint import shaderpack_sha256


class CampaignVisualTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.a1 = self.root / "A1.png"
        self.b1 = self.root / "B1.png"
        self.a2 = self.root / "A2.png"

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path: Path, pixel: tuple[int, int, int]):
        Image.new("RGB", (12, 8), pixel).save(path)

    def scenario(self, limits=None):
        return {
            "id": "nether-portal",
            "screenshots": {key: f"{key}.png" for key in ("A1", "B1", "A2")},
            "visual_gate": {
                "max_control_mae": 1,
                "max_candidate_mae": 2,
                "max_candidate_p95": 16,
                **(limits or {}),
            },
        }

    def test_matching_controls_and_candidate_pass(self):
        for path in (self.a1, self.a2, self.b1):
            self.write(path, (40, 80, 120))
        result = _visual_review(self.scenario(), self.root)
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["a1_vs_a2"]["mae_0_255"], 0)

    def test_candidate_regression_requires_difference_against_both_controls(self):
        self.write(self.a1, (20, 40, 60))
        self.write(self.a2, (20, 40, 60))
        self.write(self.b1, (80, 100, 120))
        result = _visual_review(self.scenario(), self.root)
        self.assertEqual(result["status"], "REGRESSION")

    def test_dynamic_control_drift_is_inconclusive(self):
        self.write(self.a1, (20, 40, 60))
        self.write(self.a2, (25, 45, 65))
        self.write(self.b1, (20, 40, 60))
        result = _visual_review(self.scenario(), self.root)
        self.assertEqual(result["status"], "INCONCLUSIVE")

    def test_roi_bounds_are_checked(self):
        for path in (self.a1, self.a2, self.b1):
            self.write(path, (40, 80, 120))
        with self.assertRaisesRegex(CampaignError, "outside"):
            _visual_review(self.scenario({"roi": [11, 0, 2, 2]}), self.root)

    def test_full_resolution_diff_extracts_each_channel_once(self):
        for path in (self.a1, self.a2):
            self.write(path, (0, 0, 0))
        channel = Mock()
        channel.histogram.return_value = [96] + [0] * 255
        diff = Mock()
        diff.getchannel.return_value = channel
        with patch("campaign_review.ImageChops.difference", return_value=diff):
            _image_metrics(self.a1, self.a2)
        self.assertEqual(diff.getchannel.call_count, 3)
        self.assertEqual(channel.histogram.call_count, 3)

    def test_pack_attestation_requires_matching_runtime_config_log_and_content_hash(self):
        import json

        digest = "a" * 64
        (self.root / "captures").mkdir()
        runs = []
        scenario = {
            "id": "overworld-alpine", "scene_id": "overworld-alpine",
            "passive_csvs": {}, "screenshots": {},
        }
        for run_id, variant in (("A1", "A"), ("B1", "B"), ("A2", "A")):
            perf_meta = self.root / "captures" / f"{run_id}.capture.json"
            passive_csv = self.root / f"{run_id}.csv"
            passive_meta = self.root / f"{run_id}.capture.json"
            image_path = self.root / f"{run_id}.png"
            image_meta = self.root / f"{run_id}.image.json"
            perf_meta.write_text(json.dumps({
                "pack": "ClaudeBench" + variant, "pack_revision": "rev-" + variant,
                "pack_sha256": digest,
                "pack_observation": {"latest_log_pack": "ClaudeBench" + variant},
            }), encoding="utf-8")
            passive_csv.write_text("", encoding="utf-8")
            passive_meta.write_text(json.dumps({
                "process_id": 42,
                "active_pack_attestation": {
                    "selected_pack": "ClaudeBench" + variant,
                    "latest_log_pack": "ClaudeBench" + variant,
                    "pack_revision": "rev-" + variant, "pack_sha256": digest,
                },
            }), encoding="utf-8")
            Image.new("RGB", (2, 2)).save(image_path)
            image_meta.write_text(json.dumps({
                "scene_id": "overworld-alpine",
                "active_pack_attestation": {
                    "selected_pack": "ClaudeBench" + variant,
                    "latest_log_pack": "ClaudeBench" + variant,
                    "pack_sha256": digest,
                },
            }), encoding="utf-8")
            scenario["passive_csvs"][run_id] = str(passive_csv)
            scenario["screenshots"][run_id] = str(image_path)
            runs.append({
                "id": run_id, "variant": variant,
                "pack": "ClaudeBench" + variant, "pack_revision": "rev-" + variant,
                "pack_sha256": digest, "capture_metadata": str(perf_meta),
                "process_id": 42, "scene": {"id": "overworld-alpine"},
            })
        result = _pack_attestation(scenario, self.root, self.root, {"runs": runs})
        self.assertEqual(result["B1"]["latest_log_pack"], "ClaudeBenchB")

        bad = self.root / "A2.capture.json"
        payload = json.loads(bad.read_text(encoding="utf-8"))
        payload["active_pack_attestation"]["latest_log_pack"] = "Bliss"
        bad.write_text(json.dumps(payload), encoding="utf-8")
        with self.assertRaisesRegex(CampaignError, "config/log pack attestation mismatch"):
            _pack_attestation(scenario, self.root, self.root, {"runs": runs})


class PackFingerprintTests(unittest.TestCase):
    def test_directory_fingerprint_is_stable_and_tracks_content(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "b.glsl").write_text("b", encoding="utf-8")
            (root / "a.glsl").write_text("a", encoding="utf-8")
            first = shaderpack_sha256(root)
            second = shaderpack_sha256(root)
            self.assertEqual(first, second)
            (root / "a.glsl").write_text("changed", encoding="utf-8")
            self.assertNotEqual(first, shaderpack_sha256(root))


class CampaignMemoryGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.scenario = {
            "id": "overworld-alpine",
            "passive_csvs": {run: f"{run}.csv" for run in ("A1", "B1", "A2")},
            "stall_gate": {"max_extra_gaps_by_band": {
                "1-2s": 0, "2-4s": 0, "4-8s": 0, "8-12s": 0, ">=12s": 0,
            }},
            "memory_gate": {},
        }
        for run in ("A1", "B1", "A2"):
            csv = self.root / f"{run}.csv"
            csv.write_text(
                "Application,ProcessID,SwapChainAddress,TimeInMs,MsGPUBusy,MsCPUBusy\n"
                "javaw.exe,42,0xabc,0,5,3\n"
                "javaw.exe,42,0xabc,16,5,3\n"
                "javaw.exe,42,0xabc,32,5,3\n",
                encoding="utf-8",
            )
            csv.with_suffix(".capture.json").write_text('{"process_id":42}', encoding="utf-8")
            csv.with_name(f"{run}.telemetry.csv").write_text(
                "TimestampLocal,ProcessId,NvidiaVramUsedMiB\n2026-09-24T07:00:00Z,42,8000\n",
                encoding="utf-8",
            )

    def tearDown(self):
        self.temp.cleanup()

    def test_no_recognized_memory_limit_cannot_pass(self):
        result = _stall_review(self.scenario, self.root)
        self.assertEqual(result["status"], "DESCRIPTIVE")

    def test_unknown_memory_limit_is_rejected(self):
        self.scenario["memory_gate"] = {"vram_cap": 10000}
        with self.assertRaisesRegex(CampaignError, "unknown memory_gate keys"):
            _stall_review(self.scenario, self.root)


if __name__ == "__main__":
    unittest.main()
