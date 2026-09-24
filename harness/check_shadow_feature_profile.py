"""Validate the six shadow feature intervals in a drained BenchCam GPU CSV."""

import argparse
import csv
from collections import Counter, defaultdict
from pathlib import Path


PHASES = (
    "feature_prepare_frame",
    "feature_solid",
    "feature_translucent",
    "feature_after_terrain",
    "feature_always_on_top",
    "feature_close",
)
HEADER = ("frame", "stage", "pass", "gpu_ns", "cpu_wall_ns", "feature_nodes")


def validate(path: Path, min_frames: int) -> None:
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != HEADER:
            raise ValueError(f"expected CSV columns {HEADER}, got {reader.fieldnames}")
        rows = defaultdict(list)
        for line, row in enumerate(reader, 2):
            try:
                frame = int(row["frame"])
                if int(row["gpu_ns"]) < 0 or int(row["cpu_wall_ns"]) < 0:
                    raise ValueError("negative interval")
                if row["stage"] == "shadow" and row["pass"] in PHASES:
                    nodes = int(row["feature_nodes"])
                    if nodes < 0 or (row["pass"] in (PHASES[0], PHASES[-1]) and nodes != 0):
                        raise ValueError("invalid feature_nodes")
                elif row["feature_nodes"] != "":
                    raise ValueError("feature_nodes populated outside shadow feature interval")
            except (TypeError, ValueError) as error:
                raise ValueError(f"CSV line {line}: {error}") from error
            if row["stage"] == "shadow":
                rows[frame].append(row["pass"])

    complete = 0
    cardinality = Counter()
    for frame, passes in rows.items():
        # start/stop can bisect a frame; examine frames with both shadow bookends.
        if "terrain_opaque_callbacks" not in passes or "shadowcomp" not in passes:
            continue
        actual = tuple(name for name in passes if name.startswith("feature_"))
        if actual != PHASES:
            raise ValueError(f"frame {frame}: feature order/cardinality {actual}, expected {PHASES}")
        if passes.index("feature_close") >= passes.index("buffer_end_frame"):
            raise ValueError(f"frame {frame}: feature_close must precede buffer_end_frame")
        complete += 1
        cardinality[len(passes)] += 1
    if complete < min_frames:
        raise ValueError(f"only {complete} complete shadow frames, need {min_frames}")
    print(f"ok complete_shadow_frames={complete} shadow_row_cardinality={dict(sorted(cardinality.items()))}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    parser.add_argument("--min-frames", type=int, default=100)
    args = parser.parse_args()
    validate(args.csv, args.min_frames)
