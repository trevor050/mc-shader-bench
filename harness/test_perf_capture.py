"""Offline tests for PresentMon runner command construction and capture validation."""

import tempfile
import unittest
from pathlib import Path

from perf_capture import (
    CaptureError,
    build_presentmon_command,
    parse_benchcam_status,
    read_active_pack,
    validate_capture_csv,
)


class PerfCaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.csv = self.root / "capture.csv"

    def tearDown(self):
        self.temp.cleanup()

    def write_csv(self, rows, header="Application,ProcessID,MsGPUBusy\n"):
        self.csv.write_text(header + rows, encoding="utf-8")

    def test_accepts_frames_for_exact_pid(self):
        self.write_csv("javaw.exe,4321,8.4\njavaw.exe,4321,8.1\nother.exe,9,1\n")
        self.assertEqual(validate_capture_csv(self.csv, 4321), 2)

    def test_rejects_missing_and_empty_csv(self):
        with self.assertRaisesRegex(CaptureError, "without creating CSV"):
            validate_capture_csv(self.csv, 4321)
        self.csv.touch()
        with self.assertRaisesRegex(CaptureError, "empty CSV"):
            validate_capture_csv(self.csv, 4321)

    def test_rejects_header_only_or_wrong_pid_csv(self):
        self.write_csv("")
        with self.assertRaisesRegex(CaptureError, "no frame rows for target PID 4321"):
            validate_capture_csv(self.csv, 4321)
        self.write_csv("javaw.exe,1234,8.4\n")
        with self.assertRaisesRegex(CaptureError, r"contains PIDs \[1234\]"):
            validate_capture_csv(self.csv, 4321)

    def test_rejects_non_java_target_pid(self):
        self.write_csv("notepad.exe,4321,8.4\n")
        with self.assertRaisesRegex(CaptureError, "expected javaw.exe"):
            validate_capture_csv(self.csv, 4321)

    def test_rejects_missing_required_csv_columns(self):
        self.write_csv("javaw.exe,4321,8.4\n", header="Application,MsGPUBusy\n")
        with self.assertRaisesRegex(CaptureError, "missing PresentMon ProcessID"):
            validate_capture_csv(self.csv, 4321)

    def test_capture_command_uses_unique_session_and_timed_termination(self):
        command = build_presentmon_command(
            Path("PresentMon.exe"), 4321, Path("A1.csv"), 60, "shaderbench-4321-unique"
        )
        self.assertEqual(command[command.index("--session_name") + 1], "shaderbench-4321-unique")
        self.assertIn("--terminate_after_timed", command)
        self.assertEqual(command[command.index("--timed") + 1], "60")
        self.assertEqual(command[command.index("--process_id") + 1], "4321")
        self.assertNotIn("--stop_existing_session", command)
        self.assertNotIn("--terminate_existing_session", command)

    def test_pack_is_passively_confirmed_and_mismatch_fails(self):
        props = self.root / "iris.properties"
        log = self.root / "latest.log"
        props.write_text("shaderPack=ClaudeBench\n", encoding="utf-8")
        log.write_text("[Render thread/INFO]: Using shaderpack: ClaudeBench\n", encoding="utf-8")
        info = read_active_pack(props, "ClaudeBench", log)
        self.assertEqual(info["selected_pack"], "ClaudeBench")
        self.assertEqual(info["latest_log_pack"], "ClaudeBench")
        log.write_text("[Render thread/INFO]: Using shaderpack: Bliss\n", encoding="utf-8")
        with self.assertRaisesRegex(CaptureError, "latest.log reports shader pack"):
            read_active_pack(props, "ClaudeBench", log)

    def test_parses_read_only_benchcam_pose_and_world_time(self):
        result = parse_benchcam_status(
            "ok fps=60 pos=2486.50 175.00 5.50 -135.0 12.0 time=6500 screen=none chunks=true"
        )
        self.assertEqual(result["position"], {"x": 2486.5, "y": 175.0, "z": 5.5})
        self.assertEqual(result["yaw"], -135.0)
        self.assertEqual(result["pitch"], 12.0)
        self.assertEqual(result["world_time"], 6500)

    def test_rejects_benchcam_without_loaded_player(self):
        with self.assertRaisesRegex(CaptureError, "no player pose"):
            parse_benchcam_status("ok fps=60 pos=none time=-1 screen=none chunks=false")


if __name__ == "__main__":
    unittest.main()
