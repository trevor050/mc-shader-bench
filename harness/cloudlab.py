"""Cloud lab: render designed skies (SKY_PRESET) from fixed views next to reference photos.

Usage:
  py cloudlab.py <tag> <preset> [sun_elevation_deg] [--keep]
Sets SKY_PRESET in the live pack's settings.glsl, reloads, renders four views from the Livingston green (west toward the
sun, zenith, south, east) at the given sun elevation (default -0.9, a minute after the 2026-09-25 photos' sunset), and
writes out/cloudlab/<tag>/sheet.jpg with the reference photos in the top row. Restores SKY_PRESET 0 unless --keep.
"""
import re
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
from bench import Bench  # noqa: E402
from livingston import tick_for_elevation, lens_crop, crop_16x9  # noqa: E402

SETTINGS = Path(r"C:\Users\Trevor\codeprojects\mc-shader-bench-claude-art\shaderpack\shaders\lib\settings.glsl")
REFS = Path(__file__).parent / "reference" / "sky-2026-09-25"
OUT = Path(__file__).parent / "out" / "cloudlab"
CAMERA = (1288.4, 63.0, 911.1)  # the Livingston green (wide rainbow photo position)
# name: (yaw, pitch, 35mm-equivalent focal length)
VIEWS = {"west": (77.0, -14.0, 24), "zenith": (77.0, -80.0, 14), "south": (0.0, -35.0, 24), "east": (-90.0, -25.0, 24)}


def set_preset(n: int) -> None:
    s = SETTINGS.read_text(encoding="utf-8")
    s2 = re.sub(r"^#define SKY_PRESET \d+", f"#define SKY_PRESET {n}", s, flags=re.M)
    SETTINGS.write_text(s2, encoding="utf-8", newline="\n")


def tile(im: Image.Image, w: int, h: int) -> Image.Image:
    im = im.convert("RGB")
    k = max(w / im.width, h / im.height)
    im = im.resize((round(im.width * k), round(im.height * k)))
    x0, y0 = (im.width - w) // 2, (im.height - h) // 2
    return im.crop((x0, y0, x0 + w, y0 + h))


def main(argv: list) -> None:
    if len(argv) < 2:
        print(__doc__)
        return
    tag, preset = argv[0], int(argv[1])
    elev = float(argv[2]) if len(argv) > 2 and not argv[2].startswith("--") else -0.9
    out = OUT / tag
    out.mkdir(parents=True, exist_ok=True)
    set_preset(preset)
    b = Bench()
    try:
        b.send("reload")
        b.send("closescreen")
        b.send("hud off")
        b.send("cmd gamemode spectator")
        b.send("cmd weather clear")
        b.send(f"cmd tp @s {CAMERA[0]} {CAMERA[1]} {CAMERA[2]}")
        b.send(f"cmd time set {tick_for_elevation(elev)}")
        b.send("waitchunks 30")
        renders = []
        for name, (yaw, pitch, focal) in VIEWS.items():
            b.send(f"look {yaw} {pitch}")
            b.send("wait 90")
            shot = out / f"{name}.png"
            b.send(f"shot {shot}")
            renders.append((name, crop_16x9(lens_crop(Image.open(shot), focal))))
        b.send("hud on")
        b.send("mouse free")
    finally:
        b.close()
        if "--keep" not in argv:
            set_preset(0)
    refs = sorted(REFS.glob("*"))[:4]
    W, H = 640, 360
    sheet = Image.new("RGB", (W * 4, H * 2 + 30), (16, 16, 16))
    for i, r in enumerate(refs):
        sheet.paste(tile(Image.open(r), W, H), (W * i, 0))
    for i, (name, im) in enumerate(renders):
        sheet.paste(tile(im, W, H), (W * i, H + 30))
    ImageDraw.Draw(sheet).text((8, H + 8), f"top: reference   bottom: preset {preset}, sun {elev:+.1f} deg  "
                               + "  ".join(n for n, _ in renders), fill=(230, 230, 230))
    sheet.save(out / "sheet.jpg", quality=88)
    print(out / "sheet.jpg")


if __name__ == "__main__":
    main(sys.argv[1:])
