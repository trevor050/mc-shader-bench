"""Generate the Iris program stub files (.vsh/.fsh) for every dimension.

Each stub only selects a shared source in shaders/program/ plus variant defines, so all real code
lives in one place. Re-run after changing the table below.
"""

from pathlib import Path

SHADERS = Path(__file__).resolve().parent.parent / "shaders"

# program name -> (shared source, extra define or "")
PROGRAMS = {
    "shadow": ("shadow.glsl", ""),
    "gbuffers_basic": ("gbuffers_solid.glsl", "PROG_BASIC"),
    "gbuffers_line": ("gbuffers_solid.glsl", "PROG_BASIC"),
    "gbuffers_textured": ("gbuffers_solid.glsl", "PROG_TEXTURED"),
    "gbuffers_textured_lit": ("gbuffers_solid.glsl", "PROG_TEXTURED"),
    "gbuffers_spidereyes": ("gbuffers_solid.glsl", "PROG_TEXTURED"),
    "gbuffers_beaconbeam": ("gbuffers_solid.glsl", "PROG_TEXTURED"),
    "gbuffers_terrain": ("gbuffers_solid.glsl", "PROG_TERRAIN"),
    "gbuffers_damagedblock": ("gbuffers_solid.glsl", ""),
    "gbuffers_block": ("gbuffers_solid.glsl", ""),
    "gbuffers_entities": ("gbuffers_solid.glsl", "PROG_ENTITIES"),
    "dh_terrain": ("gbuffers_solid.glsl", "PROG_DH"),
    "gbuffers_water": ("gbuffers_translucent.glsl", "PROG_WATER"),
    "gbuffers_hand_water": ("gbuffers_translucent.glsl", "PROG_WATER"),
    "gbuffers_hand": ("gbuffers_solid.glsl", "PROG_HAND"),
    "dh_water": ("gbuffers_translucent.glsl", "PROG_DH"),
    "gbuffers_skybasic": ("sky.glsl", ""),
    "gbuffers_skytextured": ("sky.glsl", "PROG_SKYTEXTURED"),
    "gbuffers_weather": ("weather.glsl", ""),
    "gbuffers_clouds": ("discard.glsl", ""),
    "gbuffers_armor_glint": ("discard.glsl", ""),
    "deferred": ("deferred.glsl", ""),
    "composite": ("composite.glsl", ""),
    "composite1": ("taa.glsl", ""),
    "final": ("final.glsl", ""),
}

# Iris dimension folders: root is the overworld.
DIMENSIONS = {"": "", "world-1": "DIM_NETHER", "world1": "DIM_END"}


def main():
    count = 0
    for folder, dim_define in DIMENSIONS.items():
        out = SHADERS / folder
        out.mkdir(exist_ok=True)
        for name, (source, define) in PROGRAMS.items():
            for ext, stage in (("vsh", "VERTEX"), ("fsh", "FRAGMENT")):
                lines = ["#version 330 compatibility", f"#define {stage}"]
                if dim_define:
                    lines.append(f"#define {dim_define}")
                if define:
                    lines.append(f"#define {define}")
                lines.append(f'#include "/program/{source}"')
                (out / f"{name}.{ext}").write_text("\n".join(lines) + "\n", newline="\n")
                count += 1
    print(f"wrote {count} stubs")


if __name__ == "__main__":
    main()
