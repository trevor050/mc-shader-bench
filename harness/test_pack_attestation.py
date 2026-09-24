"""The supplied pack fingerprint must describe Iris's selected live artifact."""

import unittest
from pathlib import Path
from unittest.mock import patch

from perf_capture import CaptureError, attest_pack_artifact


class PackAttestationTests(unittest.TestCase):
    def test_rejects_a_different_artifact_even_when_its_hash_is_valid(self):
        iris = Path(r"C:\game\config\iris.properties")
        other = Path(r"C:\source\shaderpack")

        def fake_hash(path):
            return "a" * 64 if path.resolve() == other.resolve() else "b" * 64

        with patch("perf_capture.shaderpack_sha256", side_effect=fake_hash) as hasher:
            with self.assertRaisesRegex(CaptureError, "does not match selected live pack"):
                attest_pack_artifact(iris, "ClaudeBench", other)
        self.assertEqual(hasher.call_count, 2)

    def test_accepts_the_selected_live_artifact(self):
        iris = Path(r"C:\game\config\iris.properties")
        live = Path(r"C:\game\shaderpacks\ClaudeBench")
        with patch("perf_capture.shaderpack_sha256", return_value="c" * 64) as hasher:
            self.assertEqual(attest_pack_artifact(iris, "ClaudeBench", live, "C" * 64), "c" * 64)
        hasher.assert_called_once()


if __name__ == "__main__":
    unittest.main()
