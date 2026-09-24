"""Exercise the real MP4 encoder and optional bounded-memory RGB output."""

import tempfile
import unittest
from pathlib import Path

import imageio.v2 as imageio
import numpy as np

from rec_stream import stream_frames


class StreamRecorderTests(unittest.TestCase):
    def test_streamed_video_and_rgb_frames(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "sample.mp4"

            def frames():
                for index in range(12):
                    frame = np.zeros((48, 64, 3), dtype=np.uint8)
                    frame[:, :, 0] = index * 17
                    yield frame

            self.assertEqual(stream_frames(frames(), output, 12, save_npy=True), 12)
            with imageio.get_reader(output) as video:
                self.assertEqual(video.get_data(0).shape, (48, 64, 3))
                self.assertEqual(video.get_data(11).shape, (48, 64, 3))
            rgb = np.load(output.with_suffix(".npy"), mmap_mode="r")
            self.assertEqual(rgb.shape, (12, 48, 64, 3))
            self.assertEqual(int(rgb[11, 0, 0, 0]), 187)
            del rgb
            self.assertFalse(list(Path(directory).glob("rec-stream-*.rgb")))

    def test_existing_video_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "sample.mp4"
            output.write_bytes(b"keep")
            with self.assertRaises(FileExistsError):
                stream_frames([], output, 30)
            self.assertEqual(output.read_bytes(), b"keep")


if __name__ == "__main__":
    unittest.main()
