"""Livingston sky match: render the in-game "Livingston" canvas at the poses of reference photos and compare.

Reference photos: Trevor's walk on Rutgers Livingston campus, 2026-09-25 18:47-18:57 EDT (sunset ~18:52), iPhone 14 Pro
Max, EXIF intact. Each scene reproduces a photo's compass heading and sun elevation (0.19 deg per minute around sunset
at that latitude and date) on the OSM reconstruction of the campus (livingston_build.py). The camera stands at each
photo's EXIF GPS position, projected the same way as the build, at eye height.

Usage:
  py livingston.py <tag> [scene,scene,...|all]      capture renders, pair with photos, write stats
Outputs out/livingston/<tag>/: <scene>_pair.jpg (photo | render, both cropped to 16:9), sheet.jpg, stats.json.

Stats compare the sky region (upper 55% of each frame) in CIELAB: mean L*, a*, b*, chroma, and the hue histogram,
so palette differences ("the lilac is too blue") are measurable instead of eyeballed.
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
from bench import Bench  # noqa: E402
from livingston_build import GROUND_Y, HALF, ORIGIN_MC, project  # noqa: E402
from PIL import ExifTags  # noqa: E402

EYE = 1.62
CAMERA_NUDGE = {"lilac_brick": (-22.0, 6.0)}

PHOTOS = Path.home() / "Downloads" / "Claude"
OUT = Path(__file__).parent / "out" / "livingston"

# name: (photo file prefix, local time, compass heading deg, camera pitch deg (negative looks up), 35mm-equivalent
# focal length, note)
SCENES = {
    "tree_orange":  ("093D57A4", "18:57:07", 257.4, -12, 24, "mackerel sky over the lone spruce, lit after sunset"),
    "tree_blue":    ("FCF6178D", "18:57:02", 257.4, -12, 24, "same scene 5 s earlier; the phone metered cooler"),
    "wide_rainbow": ("3D0DA647", "18:49:54", 169.1, -14, 14, "ultra-wide: peach cloud streaks, blue gaps, rainbow leg in virga"),
    "lilac_brick":  ("33F061FF", "18:55:50", 88.1, -22, 24, "looking east: pink-lilac deck over the brick dorm"),
    "lilac_spruce": ("DB31F647", "18:56:19", 189.1, -30, 24, "pink cirrus swirls, lilac sky"),
    "complicated":  ("C66649D5", "18:51:38", 196.1, -24, 24, "gold and lavender altocumulus floccus"),
}
# The game's vertical field of view (options.txt fov 0.575 -> 70 + 40 * 0.575 = 93 degrees). Renders are
# centre-cropped to the photo lens's vertical field of view in a 16:9 frame.
GAME_VFOV = 93.0
SUNSET_MIN = 18 * 60 + 52
DEG_PER_MIN = 0.19


def sun_elevation_at(local_time: str) -> float:
    h, m, s = (int(x) for x in local_time.split(":"))
    minutes = h * 60 + m + s / 60.0
    return (SUNSET_MIN - minutes) * DEG_PER_MIN


def minecraft_elevation(tick: float) -> float:
    d = (tick / 24000.0 - 0.25) % 1.0
    e = 0.5 - math.cos(d * math.pi) / 2.0
    angle = (d * 2.0 + e) / 3.0
    return 90.0 - angle * 360.0


def tick_for_elevation(target: float) -> int:
    lo, hi = 10000.0, 14000.0
    for _ in range(60):
        mid = (lo + hi) / 2.0
        if minecraft_elevation(mid) > target:
            lo = mid
        else:
            hi = mid
    return round(lo)


def lens_crop(im: Image.Image, focal_mm: float) -> Image.Image:
    vfov = 2.0 * math.degrees(math.atan(10.125 / focal_mm))  # 16:9 crop of a 36 mm-wide frame
    k = math.tan(math.radians(vfov / 2.0)) / math.tan(math.radians(GAME_VFOV / 2.0))
    w, h = im.size
    ch = min(h, round(h * k))
    cw = min(w, round(ch * 16 / 9))
    x0, y0 = (w - cw) // 2, (h - ch) // 2
    return im.crop((x0, y0, x0 + cw, y0 + ch))


def photo_position(path: Path) -> tuple:
    """World (x, z) of the photo's EXIF GPS position on the reconstruction."""
    gps = Image.open(path).getexif().get_ifd(0x8825)
    tags = {ExifTags.GPSTAGS.get(k, k): v for k, v in gps.items()}

    def dms(v):
        return float(v[0]) + float(v[1]) / 60.0 + float(v[2]) / 3600.0

    lat = dms(tags["GPSLatitude"]) * (1 if tags.get("GPSLatitudeRef", "N") == "N" else -1)
    lon = dms(tags["GPSLongitude"]) * (1 if tags.get("GPSLongitudeRef", "E") == "E" else -1)
    px, pz = project(lat, lon)
    return (ORIGIN_MC[0] + px - HALF, ORIGIN_MC[1] + pz - HALF)


def crop_16x9(im: Image.Image) -> Image.Image:
    w, h = im.size
    if w / h > 16 / 9:
        nw = round(h * 16 / 9)
        x0 = (w - nw) // 2
        return im.crop((x0, 0, x0 + nw, h))
    nh = round(w * 9 / 16)
    y0 = (h - nh) // 2
    return im.crop((0, y0, w, y0 + nh))


def srgb_to_lab(rgb: np.ndarray) -> np.ndarray:
    c = rgb / 255.0
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16.0 / 116.0)
    L = 116.0 * f[..., 1] - 16.0
    a = 500.0 * (f[..., 0] - f[..., 1])
    b = 200.0 * (f[..., 1] - f[..., 2])
    return np.stack([L, a, b], axis=-1)


def sky_stats(im: Image.Image) -> dict:
    arr = np.asarray(im.convert("RGB").resize((320, 180)), dtype=np.float64)
    sky = arr[: int(180 * 0.55)].reshape(-1, 3)
    lab = srgb_to_lab(sky)
    chroma = np.hypot(lab[:, 1], lab[:, 2])
    hue = (np.degrees(np.arctan2(lab[:, 2], lab[:, 1])) + 360.0) % 360.0
    hist, _ = np.histogram(hue[chroma > 8], bins=12, range=(0, 360))
    total = max(hist.sum(), 1)
    return {
        "L": round(float(lab[:, 0].mean()), 1),
        "a": round(float(lab[:, 1].mean()), 1),
        "b": round(float(lab[:, 2].mean()), 1),
        "chroma": round(float(chroma.mean()), 1),
        "L_p10_p90": [round(float(np.percentile(lab[:, 0], 10)), 1), round(float(np.percentile(lab[:, 0], 90)), 1)],
        "hue_hist_30deg": [round(float(x) / total, 3) for x in hist],
    }


def capture(tag: str, names: list) -> None:
    out = OUT / tag
    out.mkdir(parents=True, exist_ok=True)
    b = Bench()
    b.send("closescreen")
    b.send("hud off")
    b.send("cmd gamemode spectator")
    b.send("cmd weather clear")
    first = True
    stats = {}
    pairs = []
    for name in names:
        prefix, local, heading, pitch, focal, note = SCENES[name]
        elev = sun_elevation_at(local)
        tick = tick_for_elevation(elev)
        photo_path = next(PHOTOS.glob(prefix + "*"))
        wx, wz = photo_position(photo_path)
        # Phone GPS is good to ~10-20 m; nudge cameras that land inside a tree or wall (east, south metres).
        ox, oz = CAMERA_NUDGE.get(name, (0.0, 0.0))
        wx, wz = wx + ox, wz + oz
        b.send(f"cmd tp @s {wx:.2f} {GROUND_Y + 1} {wz:.2f}")
        if first:
            b.send("waitchunks 30")
            first = False
        b.send(f"cmd time set {tick}")
        b.send(f"look {heading - 180.0:.2f} {pitch}")
        b.send("wait 90")
        shot = out / f"{name}_render.png"
        b.send(f"shot {shot}")
        photo = crop_16x9(Image.open(photo_path).convert("RGB")).resize((960, 540))
        render = crop_16x9(lens_crop(Image.open(shot).convert("RGB"), focal)).resize((960, 540))
        pair = Image.new("RGB", (1920, 580), (16, 16, 16))
        pair.paste(photo, (0, 40))
        pair.paste(render, (960, 40))
        d = ImageDraw.Draw(pair)
        d.text((10, 12), f"{name}  photo {local} heading {heading:.0f}  |  render tick {tick} (sun {elev:+.2f} deg)  -  {note}",
               fill=(230, 230, 230))
        pair.save(out / f"{name}_pair.jpg", quality=90)
        pairs.append(pair)
        stats[name] = {"photo": sky_stats(photo), "render": sky_stats(render), "tick": tick, "sun_elevation": elev}
    b.send("hud on")
    b.send("mouse free")
    b.close()
    if pairs:
        sheet = Image.new("RGB", (1920, 580 * len(pairs)))
        for i, p in enumerate(pairs):
            sheet.paste(p, (0, 580 * i))
        sheet.save(out / "sheet.jpg", quality=85)
    (out / "stats.json").write_text(json.dumps(stats, indent=2))
    for name, s in stats.items():
        p, r = s["photo"], s["render"]
        print(f"{name:13s} L {p['L']:5.1f}/{r['L']:5.1f}  a {p['a']:5.1f}/{r['a']:5.1f}  "
              f"b {p['b']:5.1f}/{r['b']:5.1f}  C {p['chroma']:5.1f}/{r['chroma']:5.1f}   (photo/render)")


def main(argv: list) -> None:
    if not argv:
        print(__doc__)
        return
    tag = argv[0]
    names = list(SCENES) if len(argv) < 2 or argv[1] == "all" else argv[1].split(",")
    capture(tag, names)


if __name__ == "__main__":
    main(sys.argv[1:])
