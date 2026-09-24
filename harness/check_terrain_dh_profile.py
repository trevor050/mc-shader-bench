"""Check the optional DH callback rows in a drained BenchCam GPU profile."""

import argparse
import csv
from collections import Counter, defaultdict
from pathlib import Path


HEADER = ("frame", "stage", "pass", "gpu_ns", "cpu_wall_ns", "feature_nodes")
DH = ("dh_opaque_callback", "dh_translucent_callback")
BASELINE = (
    *( ("shadow", name) for name in (
        "terrain_opaque_callbacks", "entity_setup_extract", "entity_submit",
        "block_entity_extract", "block_entity_submit", "feature_prepare_frame",
        "feature_solid", "feature_translucent", "feature_after_terrain",
        "feature_always_on_top", "feature_close", "buffer_end_frame",
        "depth_copy", "translucent_setup", "terrain_translucent",
        "post_translucent", "mipmaps", "restore_state", "shadowcomp",
    )),
    *( ("deferred", name) for name in ("deferred", "deferred1", "deferred2")),
    *( ("composite", name) for name in (
        "composite", "composite1", "composite2", "composite3", "composite4",
    )),
    ("final", "final"),
    ("frame", "renderLevel_command_span"),
)
EXPECTED = Counter(BASELINE + tuple(("world", name) for name in DH))


def validate(path: Path, min_frames: int) -> None:
    rows = defaultdict(list)
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream)
        if tuple(reader.fieldnames or ()) != HEADER:
            raise ValueError(f"expected CSV columns {HEADER}, got {reader.fieldnames}")
        for line, row in enumerate(reader, 2):
            try:
                frame = int(row["frame"])
                gpu_ns = int(row["gpu_ns"])
                cpu_ns = int(row["cpu_wall_ns"])
                if gpu_ns < 0 or cpu_ns < 0:
                    raise ValueError("negative interval")
                if row["pass"] in DH:
                    if row["stage"] != "world" or row["feature_nodes"]:
                        raise ValueError("invalid DH row stage or feature_nodes")
            except (TypeError, ValueError) as error:
                raise ValueError(f"CSV line {line}: {error}") from error
            rows[frame].append((row["stage"], row["pass"]))

    full = 0
    cardinality = Counter()
    for frame, passes in rows.items():
        for name in DH:
            if passes.count(("world", name)) > 1:
                raise ValueError(f"frame {frame}: duplicate {name}")
        if all(("world", name) in passes for name in DH) and (
            "frame", "renderLevel_command_span"
        ) in passes and ("shadow", "terrain_opaque_callbacks") in passes and (
            "shadow", "shadowcomp"
        ) in passes:
            cardinality[len(passes)] += 1
            if Counter(passes) == EXPECTED and passes.index(("world", DH[0])) < passes.index(("world", DH[1])):
                full += 1
    if full < min_frames:
        raise ValueError(
            f"only {full} complete 31-row frames, need {min_frames}; "
            f"cardinality={dict(sorted(cardinality.items()))}"
        )
    print(f"ok complete_31_row_frames={full} cardinality={dict(sorted(cardinality.items()))}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    parser.add_argument("--min-frames", type=int, default=100)
    args = parser.parse_args()
    validate(args.csv, args.min_frames)
