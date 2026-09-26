"""Offline tests for dynamic route validation, protocol parsing, and QPC trimming."""
from __future__ import annotations

import csv
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

try:
    from . import dynamic_capture as dc
except ImportError:
    import dynamic_capture as dc


def sample_route() -> dict:
    return {
        "version": 1, "id": "loop", "dimension": "minecraft:overworld", "duration_s": 10,
        "points": [
            {"x": 0, "y": 70, "z": 0, "yaw": 0, "pitch": 0},
            {"x": 5, "y": 70, "z": 0, "yaw": 90, "pitch": 0},
            {"x": 0, "y": 70, "z": 5, "yaw": 180, "pitch": 0},
            {"x": -5, "y": 70, "z": 0, "yaw": 270, "pitch": 0},
            {"x": 0, "y": 70, "z": 0, "yaw": 360, "pitch": 0},
        ],
        "environment": [
            {"t_s": 0, "time_ticks": 150000, "rain": 0, "thunder": 0},
            {"t_s": 5, "time_ticks": 156000, "rain": .4, "thunder": .2},
            {"t_s": 10, "time_ticks": 162000, "rain": 0, "thunder": 0},
        ],
    }


class DynamicCaptureTests(unittest.TestCase):
    def test_real_catalog_routes_validate_and_hash_canonical_payload(self):
        catalog = Path(__file__).with_name("dynamic_routes.json")
        if catalog.exists():
            for route_id in ("night_orbit", "landscape_cycle", "cave_torch_loop"):
                route, payload, digest = dc.load_catalog(catalog, route_id)
                self.assertEqual(route["id"], route_id)
                self.assertEqual(dc.hashlib.sha256(payload).hexdigest(), digest)
                self.assertEqual(json.loads(payload), route)

    def test_route_closure_accepts_full_turn_and_rejects_bad_closure(self):
        route = dc.validate_route(sample_route())
        self.assertEqual(route["id"], "loop")
        bad = sample_route()
        bad["points"][-1]["yaw"] = 359
        with self.assertRaisesRegex(dc.DynamicCaptureError, "yaw"):
            dc.validate_route(bad)

    def test_java_route_bounds_are_checked_offline(self):
        bad = sample_route()
        bad["id"] = "Not Valid"
        with self.assertRaisesRegex(dc.DynamicCaptureError, "route id"):
            dc.validate_route(bad)
        bad = sample_route()
        bad["duration_s"] = 181
        with self.assertRaisesRegex(dc.DynamicCaptureError, "5, 180"):
            dc.validate_route(bad)
        bad = sample_route()
        bad["points"][1]["pitch"] = 91
        with self.assertRaisesRegex(dc.DynamicCaptureError, "pitch"):
            dc.validate_route(bad)
        bad = sample_route()
        bad["points"][1]["yaw"] = 181
        with self.assertRaisesRegex(dc.DynamicCaptureError, "adjacent.*yaw"):
            dc.validate_route(bad)
        bad = sample_route()
        bad["environment"][1]["time_ticks"] = 2_000_000_001
        with self.assertRaisesRegex(dc.DynamicCaptureError, "time_ticks"):
            dc.validate_route(bad)

    def test_route_timeline_must_cover_exact_duration_and_weather_bounds(self):
        bad = sample_route()
        bad["environment"][-1]["t_s"] = 9
        with self.assertRaisesRegex(dc.DynamicCaptureError, "end at duration"):
            dc.validate_route(bad)
        bad = sample_route()
        bad["environment"][1]["rain"] = 1.01
        with self.assertRaisesRegex(dc.DynamicCaptureError, r"\[0, 1\]"):
            dc.validate_route(bad)

    def test_catalog_selector_requires_one_exact_id(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "routes.json"
            path.write_text(json.dumps({"routes": [sample_route(), sample_route()]}), encoding="utf-8")
            with self.assertRaisesRegex(dc.DynamicCaptureError, "matched 2"):
                dc.load_catalog(path, "loop")

    def test_protocol_rejects_bad_json_and_malformed_reply(self):
        with self.assertRaisesRegex(dc.DynamicCaptureError, "invalid JSON"):
            dc.parse_ok_json("ok {broken", "route status")
        with self.assertRaisesRegex(dc.DynamicCaptureError, "failed"):
            dc.parse_ok_json("err not ready", "route status")

    def test_profiler_accepts_only_healthy_idle_or_closed_and_fully_drained(self):
        good = ("ok state=idle submitted=0 received=0 written=0 dropped_queries=0 dropped_rows=0 "
                "pending=0 failed_reason=none restart_required=false unreleased_queries=0 writer_error=none output=none")
        self.assertEqual(dc.validate_gpu_profiler_idle(good)["state"], "idle")
        self.assertEqual(dc.validate_gpu_profiler_idle(good.replace("state=idle", "state=closed"))["state"], "closed")
        for bad in (
            good.replace("state=idle", "state=recording"),
            good.replace("state=idle", "state=draining"),
            good.replace("pending=0", "pending=1"),
            good.replace("unreleased_queries=0", "unreleased_queries=2"),
            good.replace("failed_reason=none", "failed_reason=lost_context"),
            good.replace("writer_error=none", "writer_error=write_failed"),
            good.replace("restart_required=false", "restart_required=true"),
        ):
            with self.subTest(reply=bad):
                with self.assertRaises(dc.DynamicCaptureError):
                    dc.validate_gpu_profiler_idle(bad)
        with self.assertRaisesRegex(dc.DynamicCaptureError, "missing fields"):
            dc.validate_gpu_profiler_idle("ok state=idle pending=0")

    def test_clock_mapping_uses_qpc_pairs_and_rejects_bad_calibration(self):
        frequency = 10_000_000
        samples = [{"qpc_mid": 100_000_000 + i * frequency,
                    "monotonic_ns": 8_000_000_000 + i * 1_000_000_000,
                    "rtt_qpc": 1000} for i in range(6)]
        mapping = dc.fit_clock_map(samples, frequency)
        self.assertAlmostEqual(dc.qpc_to_monotonic_ns(130_000_000, mapping), 11_000_000_000, delta=10)
        with self.assertRaisesRegex(dc.DynamicCaptureError, "bounded-RTT"):
            dc.fit_clock_map([{**s, "rtt_qpc": 1_000_000} for s in samples], frequency)
        attempts = samples + [{**samples[0], "qpc_mid": 170_000_000, "monotonic_ns": 15_000_000_000,
                               "rtt_qpc": 500_000}]
        mapping = dc.fit_clock_map(attempts, frequency)
        self.assertEqual(len(attempts), 7)  # Slow attempts remain available for the capture receipt.
        self.assertEqual(mapping["samples"], 6)  # Only bounded-RTT pairs contribute to the fit.

    def test_measured_trim_uses_exact_scheduled_qpc_boundaries_and_keeps_tails(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "frames.csv"
            columns = ["ProcessID", "Application", "CPUStartTime", "FrameTime", "GPUBusy",
                       "CPUBusy", "GPUTime", "DisplayedTime", "PresentMode", "PresentRuntime"]
            rows = [
                [42, "javaw.exe", 1000, 1, .5, .5, .5, 1, "Hardware: Independent Flip", "DXGI"],
                [42, "javaw.exe", 1010, 2, 1, 1, 1, "NA", "Composed: Flip", "DXGI"],
                [42, "javaw.exe", 1020, 40, 35, 4, 36, 40, "Hardware: Independent Flip", "DXGI"],
                [42, "javaw.exe", 1030, 4, 3, 3, 3, 4, "Hardware: Independent Flip", "DXGI"],
                [42, "javaw.exe", 1040, 999, 999, 999, 999, 999, "Hardware: Independent Flip", "DXGI"],
                [77, "other.exe", 1025, 9000, 9000, 9000, 9000, 9000, "Other", "Other"],
            ]
            with path.open("w", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)
                writer.writerow(columns)
                writer.writerows(rows)
            # one QPC tick = one ms; map qpc=1000 -> mono=10s.
            mapping = {"slope_ns_per_qpc": 1_000_000, "intercept_ns": 9_000_000_000,
                       "drift_ppm": 0, "max_residual_ms": 0, "samples": 4, "max_rtt_ms": 1}
            result = dc.analyze_measured_csv(path, 42, 10_010_000_000, 10_040_000_000,
                                             mapping, 1000)
            self.assertEqual(result["frame_rows"], 3)
            self.assertEqual(result["frame_time"]["max_ms"], 40)
            self.assertEqual(result["frame_time"]["p99_ms"], 39.28)
            self.assertEqual(result["presentation"]["not_displayed"], 1)
            self.assertEqual(result["present_start_gaps"]["max_ms"], 10)

    def test_lost_event_detector_and_qpc_parser_are_explicit(self):
        self.assertTrue(dc.has_lost_events("warning: 4 ETW events were lost"))
        self.assertTrue(dc.has_lost_events("Lost 1 ETW event"))
        self.assertFalse(dc.has_lost_events("0 ETW events were lost"))
        self.assertEqual(dc.parse_qpc_value({"CPUStartTime": "123456"}), 123456)
        self.assertIsNone(dc.parse_qpc_value({"TimeInMs": "123.4"}))

    def test_route_status_checks_hash_phase_and_control_state(self):
        self.assertEqual(dc._check_route_status({"phase": "measured", "route_sha256": "a" * 64}, "a" * 64), "measured")
        with self.assertRaisesRegex(dc.DynamicCaptureError, "hash"):
            dc._check_route_status({"phase": "measured", "route_sha256": "wrong"}, "a" * 64)
        with self.assertRaisesRegex(dc.DynamicCaptureError, "request_id"):
            dc._check_route_status({"phase": "measured", "route_sha256": "a" * 64,
                                    "request_id": "another-run"}, "a" * 64, "this-run")
        self.assertEqual(dc._check_route_status({"phase": "measured", "route_sha256": "a" * 64,
                                                "reason_codes": ["CONTROL_DESYNC"]}, "a" * 64), "measured")
        self.assertEqual(dc._check_route_status({"phase": "measured", "route_sha256": "a" * 64,
                                                "camera_server_measured_max_distance": 16.1}, "a" * 64), "measured")
        # A large global maximum from the initial traversal/warmup is diagnostic only.
        status = {"phase": "measured", "route_sha256": "a" * 64,
                  "camera_server_max_distance": 45.0, "camera_server_measured_max_distance": 15.9}
        self.assertEqual(dc._check_route_status(status, "a" * 64), "measured")
        # A desync during a running route is diagnostic until the scheduled end,
        # preserving all remaining frames in the raw capture.
        running = {"phase": "measured", "route_sha256": "a" * 64,
                   "reason_codes": ["CONTROL_DESYNC_ONE_CHUNK"], "measured_workload_valid": False,
                   "camera_server_measured_max_distance": 18.0}
        self.assertEqual(dc._check_route_status(running, "a" * 64), "measured")
        with self.assertRaisesRegex(dc.DynamicCaptureError, "invalid"):
            dc.validate_terminal_route_status({**running, "restore_result": {"server": True, "client": True}}, "completed")

    def test_terminal_route_requires_completed_and_both_restores(self):
        status = {"phase": "completed", "reason_codes": [], "measured_workload_valid": True,
                  "camera_server_measured_max_distance": 8.0,
                  "request_id": "owned-request",
                  "restore_result": {"server": True, "client": True}}
        dc.validate_terminal_route_status(status, "completed", "owned-request")
        with self.assertRaisesRegex(dc.DynamicCaptureError, "request_id"):
            dc.validate_terminal_route_status(status, "completed", "different-request")
        for restore in (None, "ok", {"server": True}, {"server": True, "client": False}):
            with self.subTest(restore=restore):
                with self.assertRaisesRegex(dc.DynamicCaptureError, "restoration"):
                    dc.validate_terminal_route_status({**status, "restore_result": restore}, "completed", "owned-request")
        with self.assertRaisesRegex(dc.DynamicCaptureError, "failed"):
            dc.validate_terminal_route_status({**status, "phase": "failed"}, "failed", "owned-request")
        with self.assertRaisesRegex(dc.DynamicCaptureError, "separation"):
            dc.validate_terminal_route_status({**status, "camera_server_measured_max_distance": 16.1}, "completed", "owned-request")

    def test_lost_start_reply_cancels_only_new_matching_route(self):
        class FakeBench:
            def __init__(self):
                self.states = [
                    {"phase": "preparing", "running": True, "run_id": "owned-new",
                     "route_id": "loop", "route_sha256": "a" * 64, "request_id": "request-owned"},
                    {"phase": "cancelled", "running": False, "run_id": "owned-new",
                     "route_id": "loop", "route_sha256": "a" * 64,
                     "request_id": "request-owned",
                     "restore_result": {"server": True, "client": True}},
                ]
                self.commands = []
            def json(self, command):
                self.commands.append(command)
                return self.states.pop(0)
            def command(self, command):
                self.commands.append(command)
                return "ok cancelled"
        bench = FakeBench()
        result = dc.cancel_route_only_if_owned(
            bench, "loop", "a" * 64,
            {"phase": "idle", "running": False, "run_id": None},
            None, "request-owned", timeout=1, poll_interval=.01)
        self.assertEqual(result["action"], "cancelled")
        self.assertTrue(result["restore_verified"])
        self.assertIn("route cancel request_id=request-owned", bench.commands)

        unrelated = FakeBench()
        unrelated.states = [{"phase": "measured", "running": True, "run_id": "preexisting",
                             "route_id": "loop", "route_sha256": "a" * 64,
                             "request_id": "foreign-request"}]
        result = dc.cancel_route_only_if_owned(
            unrelated, "loop", "a" * 64,
            {"phase": "idle", "running": False, "run_id": "older"},
            None, "our-request", timeout=1, poll_interval=.01)
        self.assertEqual(result["action"], "left_untouched_not_owned")
        self.assertFalse(any(command.startswith("route cancel") for command in unrelated.commands))

    def test_keyboardinterrupt_cleanup_cancels_matching_route_and_owned_etw(self):
        class FakeBench:
            def __init__(self):
                self.states = [
                    {"phase": "measured", "running": True, "run_id": "run-2",
                     "route_id": "loop", "route_sha256": "b" * 64, "request_id": "req-k"},
                    {"phase": "cancelled", "running": False, "run_id": "run-2",
                     "route_id": "loop", "route_sha256": "b" * 64,
                     "request_id": "req-k",
                     "restore_result": {"server": True, "client": True}},
                ]
                self.commands = []
            def json(self, command):
                self.commands.append(command)
                return self.states.pop(0)
            def command(self, command):
                self.commands.append(command)
                return "ok cancelled"
        class FakeProcess:
            def __init__(self):
                self.code, self.timeouts = None, []
            def communicate(self, timeout=None):
                self.timeouts.append(timeout)
                self.code = 0
                return "csv-out", "csv-err"
            def poll(self):
                return self.code
        bench, process = FakeBench(), FakeProcess()
        executable = Path("presentmon.exe")
        session = "dynamic-owned-session"
        caught = None
        try:
            raise KeyboardInterrupt("ctrl-c")
        except BaseException as interruption:
            caught = interruption
            route_result = dc.cancel_route_only_if_owned(
                bench, "loop", "b" * 64,
                {"phase": "armed", "running": False, "run_id": "older"},
                None, "req-k", timeout=1, poll_interval=.01)
            with patch.object(dc.subprocess, "run", return_value=SimpleNamespace(
                    returncode=0, stdout="stop-out", stderr="stop-err")) as run:
                pm_result = dc.stop_owned_presentmon(executable, session, process)
        self.assertIsInstance(caught, KeyboardInterrupt)
        self.assertEqual(route_result["action"], "cancelled")
        self.assertIn("route cancel request_id=req-k", bench.commands)
        self.assertEqual(run.call_args.args[0], [str(executable), "--terminate_existing_session", "--session_name", session])
        self.assertEqual(pm_result["process_returncode"], 0)
        self.assertIn("csv-out", pm_result["stdout"])
        self.assertIn("csv-err", pm_result["stderr"])
        self.assertEqual(process.timeouts, [15.0])

    def test_presentmon_pipe_drain_is_bounded_and_terminates_on_timeout(self):
        class SlowFakeProcess:
            def __init__(self):
                self.code, self.calls, self.terminated = None, 0, False
            def communicate(self, timeout=None):
                self.calls += 1
                if self.calls == 1:
                    raise dc.subprocess.TimeoutExpired("presentmon", timeout)
                self.code = 0
                return "complete", ""
            def terminate(self):
                self.terminated = True
            def poll(self):
                return self.code
        process = SlowFakeProcess()
        with patch.object(dc.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="", stderr="")):
            result = dc.stop_owned_presentmon(Path("presentmon.exe"), "exact-owned-session", process, timeout=.01)
        self.assertTrue(process.terminated)
        self.assertEqual(process.calls, 2)
        self.assertIn("TimeoutExpired", result["communicate_error"])
        self.assertEqual(result["stdout"], "complete")

    def test_presentmon_pipe_drain_kills_owned_child_after_terminate_timeout(self):
        class StuckFakeProcess:
            def __init__(self):
                self.code, self.calls, self.terminated, self.killed = None, 0, False, False
            def communicate(self, timeout=None):
                self.calls += 1
                if self.calls < 3:
                    raise dc.subprocess.TimeoutExpired("presentmon", timeout)
                self.code = 0
                return "drained", ""
            def terminate(self):
                self.terminated = True
            def kill(self):
                self.killed = True
                self.code = -9
            def poll(self):
                return self.code
        process = StuckFakeProcess()
        with patch.object(dc.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="", stderr="")):
            result = dc.stop_owned_presentmon(Path("presentmon.exe"), "owned-after-timeout", process, timeout=.01)
        self.assertTrue(process.terminated)
        self.assertTrue(process.killed)
        self.assertEqual(process.calls, 3)
        self.assertIn("TimeoutExpired", result["terminate_error"])
        self.assertEqual(result["stdout"], "drained")


if __name__ == "__main__":
    unittest.main()
