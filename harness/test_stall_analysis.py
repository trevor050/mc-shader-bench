import json
import tempfile
import unittest
from pathlib import Path

import stall_analysis


class StallAnalysisTests(unittest.TestCase):
    def capture(self, root: Path, present: str, telemetry: str = "") -> Path:
        csv_path = root / "stall.csv"
        csv_path.write_text(present, encoding="utf-8")
        csv_path.with_name("stall.capture.json").write_text(
            json.dumps({"schema_version": 1, "process_id": 42, "started_at_utc": "2026-09-24T07:00:00Z"}),
            encoding="utf-8",
        )
        csv_path.with_name("stall.telemetry.csv").write_text(telemetry, encoding="utf-8")
        return csv_path

    def test_empty_presentmon_keeps_telemetry_and_marks_frames_unmeasurable(self):
        with tempfile.TemporaryDirectory() as temp:
            path = self.capture(Path(temp), "", "TimestampLocal,ProcessId,NvidiaGpuUtilPercent,NvidiaVramUsedMiB,JavaPrivateBytes\n"
                "2026-09-24T07:00:00-04:00,42,90,8000,1000\n"
                "2026-09-24T07:00:01-04:00,42,95,8100,1200\n")
            result = stall_analysis.analyze(path)
            self.assertEqual(result["frames"]["status"], "unmeasurable")
            self.assertEqual(result["telemetry"]["metrics"]["nvidia_vram_used_mib"]["delta"], 100)

    def test_gaps_and_busy_metrics_filter_pid_and_use_single_chain(self):
        with tempfile.TemporaryDirectory() as temp:
            present = (
                "Application,ProcessID,SwapChainAddress,CPUStartTimeInMs,MsGPUBusy,MsCPUBusy\n"
                "javaw.exe,42,0xabc,100,10,3\n"
                "javaw.exe,42,0xabc,116,12,4\n"
                "javaw.exe,42,0xabc,226,80,30\n"
                "javaw.exe,7,0xdef,300,500,500\n"
            )
            result = stall_analysis.analyze(self.capture(Path(temp), present))
            self.assertEqual(result["frames"]["present_gaps_ms"]["max"], 110)
            self.assertEqual(result["frames"]["gaps_over_ms"]["100"], 1)
            self.assertEqual(result["frames"]["gpu_busy_ms"]["max"], 80)
            self.assertEqual(result["frames"]["rows_for_target_pid"], 3)

    def test_present_timeline_wins_when_present_and_cpu_start_times_differ(self):
        with tempfile.TemporaryDirectory() as temp:
            present = (
                "Application,ProcessID,SwapChainAddress,TimeInMs,CPUStartTimeInMs,MsGPUBusy,MsCPUBusy\n"
                "javaw.exe,42,0xabc,100,1000,10,3\n"
                "javaw.exe,42,0xabc,116,1500,12,4\n"
                "javaw.exe,42,0xabc,226,1900,80,30\n"
            )
            frames = stall_analysis.analyze(self.capture(Path(temp), present))["frames"]
            self.assertEqual(frames["timestamps"]["column"], "TimeInMs")
            self.assertEqual(frames["timestamps"]["gap_kind"], "present_event_gaps")
            self.assertEqual(frames["present_gaps_ms"]["max"], 110)

    def test_counts_progressive_one_to_twelve_second_gaps(self):
        with tempfile.TemporaryDirectory() as temp:
            present = (
                "Application,ProcessID,SwapChainAddress,TimeInMs,MsGPUBusy,MsCPUBusy\n"
                "javaw.exe,42,0xabc,0,10,3\n"
                "javaw.exe,42,0xabc,1500,10,3\n"
                "javaw.exe,42,0xabc,3500,10,3\n"
                "javaw.exe,42,0xabc,7500,10,3\n"
                "javaw.exe,42,0xabc,15500,10,3\n"
                "javaw.exe,42,0xabc,28000,10,3\n"
            )
            gaps = stall_analysis.analyze(self.capture(Path(temp), present))["frames"]["gaps_over_ms"]
            self.assertEqual([gaps[str(ms)] for ms in (1000, 2000, 4000, 8000, 12000)], [5, 4, 3, 2, 1])

    def test_cpu_start_fallback_is_labeled_as_frame_start_gaps(self):
        with tempfile.TemporaryDirectory() as temp:
            present = (
                "Application,ProcessID,SwapChainAddress,CPUStartTimeInMs,MsGPUBusy,MsCPUBusy\n"
                "javaw.exe,42,0xabc,1000,10,3\n"
                "javaw.exe,42,0xabc,1500,12,4\n"
            )
            frames = stall_analysis.analyze(self.capture(Path(temp), present))["frames"]
            self.assertEqual(frames["timestamps"]["gap_kind"], "frame_start_gaps")
            self.assertEqual(frames["present_gaps_ms"]["max"], 500)

    def test_presentmon_app_only_columns_report_cpu_and_frame_start_gaps_only(self):
        with tempfile.TemporaryDirectory() as temp:
            present = (
                "Application,ProcessID,SwapChainAddress,PresentRuntime,SyncInterval,PresentFlags,"
                "CPUStartTime,FrameTime,CPUBusy,CPUWait,AllInputToPhotonLatency,ClickToPhotonLatency\n"
                "javaw.exe,42,0xabc,DXGI,0,512,15.4673,7.2365,7.1824,0.0541,NA,NA\n"
                "javaw.exe,42,0xabc,DXGI,0,512,22.7038,0.0541,0.0000,0.0541,NA,NA\n"
                "javaw.exe,42,0xabc,DXGI,0,512,30.2582,7.5545,7.5027,0.0518,NA,NA\n"
            )
            frames = stall_analysis.analyze(self.capture(Path(temp), present))["frames"]
            self.assertEqual(frames["timestamps"]["column"], "CPUStartTime")
            self.assertEqual(frames["timestamps"]["gap_kind"], "frame_start_gaps")
            self.assertAlmostEqual(frames["present_gaps_ms"]["max"], 7.5544, places=3)
            self.assertEqual(frames["cpu_busy_ms"]["max"], 7.5027)
            self.assertIsNone(frames["gpu_busy_ms"])

    def test_multiple_swapchains_are_not_combined(self):
        with tempfile.TemporaryDirectory() as temp:
            present = (
                "Application,ProcessID,SwapChainAddress,CPUStartTimeInMs,MsGPUBusy,MsCPUBusy\n"
                "javaw.exe,42,0xabc,100,10,3\n"
                "javaw.exe,42,0xdef,120,12,4\n"
            )
            frames = stall_analysis.analyze(self.capture(Path(temp), present))["frames"]
            self.assertEqual(frames["status"], "unmeasurable")
            self.assertIn("multiple target swapchains", frames["reason"])
            self.assertIsNone(frames["present_gaps_ms"])

    def test_header_only_csv_and_absent_telemetry_report_explicit_states(self):
        with tempfile.TemporaryDirectory() as temp:
            present = "Application,ProcessID,SwapChainAddress,CPUStartTimeInMs,MsGPUBusy,MsCPUBusy\n"
            result = stall_analysis.analyze(self.capture(Path(temp), present))
            self.assertEqual(result["frames"]["status"], "unmeasurable")
            self.assertEqual(result["frames"]["rows_for_target_pid"], 0)
            self.assertEqual(result["telemetry"]["status"], "unmeasurable")

    def test_missing_metadata_pid_does_not_aggregate_unattributed_rows(self):
        with tempfile.TemporaryDirectory() as temp:
            path = self.capture(
                Path(temp),
                "Application,ProcessID,SwapChainAddress,TimeInMs,MsGPUBusy,MsCPUBusy\njavaw.exe,42,0xabc,10,5,3\n",
                "TimestampLocal,ProcessId,NvidiaGpuUtilPercent\n2026-09-24T07:00:00-04:00,42,90\n",
            )
            path.with_name("stall.capture.json").write_text('{"schema_version":1}', encoding="utf-8")
            result = stall_analysis.analyze(path)
            self.assertEqual(result["frames"]["status"], "unmeasurable")
            self.assertEqual(result["frames"]["rows_for_target_pid"], 0)
            self.assertEqual(result["telemetry"]["status"], "unmeasurable")
            self.assertEqual(result["telemetry"]["pid_rows"], 0)


if __name__ == "__main__":
    unittest.main()
