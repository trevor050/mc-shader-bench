"""Offline compile check for every generated program stub with glslang.

Expands Iris-style absolute includes, injects the few symbols Iris declares implicitly, and compiles each
stage. This catches syntax and type errors only; Iris-side linking and visual correctness still need the game.

Usage: py check_compile.py [substring filter...]
"""

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SHADERS = Path(__file__).resolve().parent.parent / "shaders"
GLSLANG = os.environ.get("GLSLANG", str(Path.home() / "tools" / "glslang" / "bin" / "glslang.exe"))

INCLUDE = re.compile(r'^\s*#include\s+"([^"]+)"', re.M)

# Symbols Iris provides without an explicit declaration in the pack.
PRELUDE = """
#define MC_VERSION 12602
#define IRIS_VERSION 11104
#define MC_RENDER_STAGE_NONE 0
#define MC_RENDER_STAGE_SKY 1
#define MC_RENDER_STAGE_SUNSET 2
#define MC_RENDER_STAGE_CUSTOM_SKY 3
#define MC_RENDER_STAGE_SUN 4
#define MC_RENDER_STAGE_MOON 5
#define MC_RENDER_STAGE_STARS 6
#define MC_RENDER_STAGE_VOID 7
#define MC_RENDER_STAGE_TERRAIN_SOLID 8
#define MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED 9
#define MC_RENDER_STAGE_TERRAIN_CUTOUT 10
#define MC_RENDER_STAGE_ENTITIES 11
#define MC_RENDER_STAGE_BLOCK_ENTITIES 12
#define MC_RENDER_STAGE_DESTROY 13
#define MC_RENDER_STAGE_OUTLINE 14
#define MC_RENDER_STAGE_DEBUG 15
#define MC_RENDER_STAGE_HAND_SOLID 16
#define MC_RENDER_STAGE_TERRAIN_TRANSLUCENT 17
#define MC_RENDER_STAGE_TRIPWIRE 18
#define MC_RENDER_STAGE_PARTICLES 19
#define MC_RENDER_STAGE_CLOUDS 20
#define MC_RENDER_STAGE_RAIN_SNOW 21
#define MC_RENDER_STAGE_WORLD_BORDER 22
#define MC_RENDER_STAGE_HAND_TRANSLUCENT 23
#define DH_BLOCK_UNKNOWN 0
#define DH_BLOCK_LEAVES 1
#define DH_BLOCK_STONE 2
#define DH_BLOCK_WOOD 3
#define DH_BLOCK_METAL 4
#define DH_BLOCK_DIRT 5
#define DH_BLOCK_LAVA 6
#define DH_BLOCK_DEEPSLATE 7
#define DH_BLOCK_SNOW 8
#define DH_BLOCK_SAND 9
#define DH_BLOCK_TERRACOTTA 10
#define DH_BLOCK_NETHER_STONE 11
#define DH_BLOCK_WATER 12
#define DH_BLOCK_GRASS 13
#define DH_BLOCK_AIR 14
#define DH_BLOCK_ILLUMINATED 15
"""
DH_PRELUDE = "uniform int dhMaterialId;\n"


def expand(path: Path, seen: list) -> str:
    text = path.read_text()

    def repl(m):
        inc = SHADERS / m.group(1).lstrip("/")
        return expand(inc, seen)

    return INCLUDE.sub(repl, text)


def main():
    filters = sys.argv[1:]
    stubs = sorted(p for p in SHADERS.rglob("*") if p.suffix in (".vsh", ".fsh", ".csh")
                   and p.parent.name in ("shaders", "world-1", "world1"))
    stage_for = {".vsh": "vert", ".fsh": "frag", ".csh": "comp"}
    failures = 0
    checked = 0
    with tempfile.TemporaryDirectory() as tmp:
        for stub in stubs:
            rel = stub.relative_to(SHADERS).as_posix()
            if filters and not any(f in rel for f in filters):
                continue
            src = expand(stub, [])
            lines = src.split("\n")
            prelude = PRELUDE + (DH_PRELUDE if stub.stem.startswith("dh_") else "")
            src = lines[0] + "\n" + prelude + "\n".join(lines[1:])
            out = Path(tmp) / (rel.replace("/", "__") + "." + stage_for[stub.suffix])
            out.write_text(src)
            r = subprocess.run([GLSLANG, "-S", stage_for[stub.suffix], str(out)], capture_output=True, text=True)
            checked += 1
            if r.returncode != 0:
                failures += 1
                msg = "\n".join(l for l in r.stdout.splitlines() if "ERROR" in l)[:1500]
                print(f"FAIL {rel}\n{msg}\n")
    print(f"checked {checked}, failed {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
