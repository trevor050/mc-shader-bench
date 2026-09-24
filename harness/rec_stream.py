"""Bounded-memory screen recording for the ShaderBench monitor.

Usage: py harness/rec_stream.py 10 harness/out/storm.mp4 [--fps 30] [--npy]
The optional .npy copy is streamed through a temporary raw file instead of
holding every RGB frame in RAM.
"""

from __future__ import annotations

import argparse
import math
import shutil
import tempfile
import time
from pathlib import Path
from typing import Iterable

import imageio.v2 as imageio
import mss
import numpy as np
from PIL import Image


MONITOR = {"left": -2507, "top": 222, "width": 1532, "height": 860}
OUTPUT_SIZE = (766, 430)


def capture_frames(seconds: float, fps: int) -> Iterable[np.ndarray]:
    frame_count = math.ceil(seconds * fps)
    interval = 1.0 / fps
    with mss.MSS() as screen:
        started = time.perf_counter()
        for index in range(frame_count):
            delay = started + index * interval - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
            shot = screen.grab(MONITOR)
            image = Image.frombytes("RGB", shot.size, shot.bgra, "raw", "BGRX")
            yield np.asarray(image.resize(OUTPUT_SIZE), dtype=np.uint8)


def stream_frames(frames: Iterable[np.ndarray], output: Path, fps: int,
                  save_npy: bool = False) -> int:
    output = output.resolve()
    if output.suffix.lower() != ".mp4":
        raise ValueError("output must end in .mp4")
    if output.exists():
        raise FileExistsError(f"refusing to overwrite {output}")
    npy_output = output.with_suffix(".npy")
    if save_npy and npy_output.exists():
        raise FileExistsError(f"refusing to overwrite {npy_output}")
    output.parent.mkdir(parents=True, exist_ok=True)

    raw_path: Path | None = None
    raw = None
    count = 0
    frame_shape: tuple[int, int, int] | None = None
    try:
        if save_npy:
            raw = tempfile.NamedTemporaryFile(mode="wb", prefix="rec-stream-",
                                              suffix=".rgb", dir=output.parent, delete=False)
            raw_path = Path(raw.name)
        with imageio.get_writer(output, fps=fps, quality=8, macro_block_size=2) as writer:
            for frame in frames:
                frame = np.ascontiguousarray(frame, dtype=np.uint8)
                if frame.ndim != 3 or frame.shape[2] != 3:
                    raise ValueError("frames must have RGB shape (height, width, 3)")
                if frame_shape is None:
                    frame_shape = frame.shape
                elif frame.shape != frame_shape:
                    raise ValueError("all frames must have the same shape")
                writer.append_data(frame)
                if raw is not None:
                    raw.write(frame.tobytes())
                count += 1
        if count == 0:
            raise ValueError("no frames captured")
        if raw is not None and raw_path is not None and frame_shape is not None:
            raw.close()
            raw = None
            source = np.memmap(raw_path, mode="r", dtype=np.uint8,
                               shape=(count, *frame_shape))
            destination = np.lib.format.open_memmap(npy_output, mode="w+",
                                                      dtype=np.uint8,
                                                      shape=(count, *frame_shape))
            for index in range(0, count, 8):
                destination[index:index + 8] = source[index:index + 8]
            destination.flush()
            del destination, source
        return count
    finally:
        if raw is not None:
            raw.close()
        if raw_path is not None:
            raw_path.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("seconds", type=float)
    parser.add_argument("output", type=Path)
    parser.add_argument("--fps", type=int, default=30)
    parser.add_argument("--npy", action="store_true", help="also save exact RGB frames as .npy")
    args = parser.parse_args()
    if not math.isfinite(args.seconds) or not 0 < args.seconds <= 900:
        parser.error("seconds must be between 0 and 900")
    if not 1 <= args.fps <= 120:
        parser.error("fps must be between 1 and 120")
    if args.npy:
        parent = args.output.resolve().parent
        parent.mkdir(parents=True, exist_ok=True)
        raw_bytes = math.ceil(args.seconds * args.fps) * OUTPUT_SIZE[0] * OUTPUT_SIZE[1] * 3
        required = raw_bytes * 2 + 128 * 1024 * 1024
        if shutil.disk_usage(parent).free < required:
            parser.error(f"--npy needs roughly {required / 2**30:.1f} GiB of free disk during conversion")
    started = time.perf_counter()
    count = stream_frames(capture_frames(args.seconds, args.fps), args.output,
                          args.fps, args.npy)
    elapsed = time.perf_counter() - started
    print(f"{count} frames, {elapsed:.2f} s total pipeline time, {count / elapsed:.1f} pipeline FPS")
    print(f"video: {args.output.resolve()}")
    if args.npy:
        print(f"RGB frames: {args.output.resolve().with_suffix('.npy')}")


if __name__ == "__main__":
    main()
