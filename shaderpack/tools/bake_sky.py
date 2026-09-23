"""Bake the night-sky textures from real star data.

Inputs: the HYG star database (hygdata_v40.csv.gz, CC BY-SA 4.0, https://github.com/astronexus/HYG-Database).
Outputs (raw RGBA16, loaded through customTexture in shaders.properties):
  textures/starmap.dat   2048x1024 equirectangular in equatorial coordinates (RA, Dec). One star per texel:
                         R,G = sub-texel position, B = magnitude code, A = colour index code. Stars are drawn
                         analytically in the shader, so they stay pin sharp at any resolution.
  textures/milkyway.dat  1024x512 equirectangular (RA, Dec) diffuse glow: the unresolved light of faint stars,
                         built from the real faint-star density plus a galactic-plane model with dust lanes.

Usage: py bake_sky.py <path to hygdata csv.gz>
"""

import csv
import gzip
import math
import sys
from pathlib import Path

import numpy as np

OUT = Path(__file__).resolve().parent.parent / "shaders" / "textures"
SW, SH = 2048, 1024
MW, MH = 1024, 512
MAG_LIMIT = 7.0


def load_stars(path):
    stars = []
    with gzip.open(path, "rt", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["proper"] == "Sol":
                continue
            try:
                mag = float(row["mag"])
                ra = float(row["ra"]) * 15.0  # hours -> degrees
                dec = float(row["dec"])
            except ValueError:
                continue
            ci = float(row["ci"]) if row["ci"] else 0.6
            stars.append((ra, dec, mag, ci))
    return stars


def bake_starmap(stars):
    img = np.zeros((SH, SW, 4), dtype=np.uint16)
    best = np.full((SH, SW), 99.0)
    for ra, dec, mag, ci in stars:
        if mag > MAG_LIMIT:
            continue
        x = (ra / 360.0) * SW
        y = (dec + 90.0) / 180.0 * SH
        ix, iy = min(int(x), SW - 1), min(int(y), SH - 1)
        if mag >= best[iy, ix]:
            continue
        best[iy, ix] = mag
        fx, fy = x - ix, y - iy
        img[iy, ix] = (
            int(fx * 65535),
            int(fy * 65535),
            int(np.clip((mag + 2.0) / 10.0, 0.0, 1.0) * 65535),  # mag -2..8
            int(np.clip((ci + 0.5) / 2.5, 0.0, 1.0) * 65535),    # B-V -0.5..2.0
        )
    count = int((best < 99).sum())
    img.tofile(OUT / "starmap.dat")
    print(f"starmap: {count} stars")


# J2000 equatorial -> galactic rotation matrix.
EQ_TO_GAL = np.array([
    [-0.0548755604, -0.8734370902, -0.4838350155],
    [0.4941094279, -0.4448296300, 0.7469822445],
    [-0.8676661490, -0.1980763734, 0.4559837762],
])


def fbm(x, y, octaves, seed):
    rng = np.random.default_rng(seed)
    out = np.zeros_like(x)
    amp, freq, total = 1.0, 1.0, 0.0
    for _ in range(octaves):
        phase = rng.uniform(0, 2 * np.pi, 4)
        n = (np.sin(x * freq * 1.7 + phase[0] + np.sin(y * freq * 2.3 + phase[1]))
             * np.sin(y * freq * 1.9 + phase[2] + np.sin(x * freq * 1.3 + phase[3])))
        out += n * amp
        total += amp
        amp *= 0.55
        freq *= 2.03
    return out / total


def bake_milkyway(stars):
    # Pixel directions in equatorial coordinates.
    u = (np.arange(MW) + 0.5) / MW * 2 * np.pi
    v = ((np.arange(MH) + 0.5) / MH - 0.5) * np.pi
    ra, dec = np.meshgrid(u, v)
    eq = np.stack([np.cos(dec) * np.cos(ra), np.cos(dec) * np.sin(ra), np.sin(dec)], -1)
    gal = eq @ EQ_TO_GAL.T
    l = np.arctan2(gal[..., 1], gal[..., 0])  # -pi..pi, 0 = galactic centre
    b = np.arcsin(np.clip(gal[..., 2], -1, 1))

    # Disc: thin near the core, brightening strongly toward Sagittarius (l = 0), plus the central bulge.
    core = np.exp(-np.abs(l) / 1.2)
    width = np.radians(9.0 + 9.0 * core)
    disc = np.exp(-np.abs(b) / width) * (0.35 + 0.65 * core)
    bulge = np.exp(-(l / 0.28) ** 2 - (b / 0.2) ** 2) * 1.4
    glow = disc + bulge

    # Dust: dark lanes hugging the plane (the Great Rift runs from Cygnus, l ~ 80, to Sagittarius).
    lanes = fbm(l * 5.0, b * 10.0, 6, 7) * 0.5 + 0.5
    rift = np.exp(-((b - np.radians(1.0)) / np.radians(5.0)) ** 2) * np.clip(1.6 - np.abs(l - 0.35), 0, 1)
    dust = np.clip((lanes - 0.35) * 2.2, 0, 1) * np.exp(-(b / np.radians(9.0)) ** 2) * 0.8 + rift * 0.55 * lanes
    glow *= np.clip(1.0 - dust, 0.05, 1.0)

    # Mottling from star clouds.
    clouds = fbm(l * 14.0 + 3.0, b * 30.0, 5, 11) * 0.5 + 0.5
    glow *= 0.65 + 0.7 * clouds

    # Real faint stars (below the drawn limit) add their integrated light and real clumping.
    faint = np.zeros((MH, MW))
    for ra_d, dec_d, mag, _ in stars:
        if mag <= MAG_LIMIT:
            continue
        x = min(int(ra_d / 360.0 * MW), MW - 1)
        y = min(int((dec_d + 90.0) / 180.0 * MH), MH - 1)
        faint[y, x] += min(10 ** (-0.4 * (mag - 7.0)), 0.4)
    # Blur the faint-star light a little.
    k = np.array([1, 4, 6, 4, 1], float)
    k /= k.sum()
    # Heavy blur: only the large-scale density of faint stars should survive, never individual clumps
    # (single faint clusters otherwise show up as fuzzy blobs next to the sharp drawn stars).
    for _ in range(40):
        for axis in (0, 1):
            faint = np.apply_along_axis(lambda r: np.convolve(r, k, mode="same"), axis, faint)
    faint /= max(np.percentile(faint, 99.5), 1e-6)

    total = glow / glow.max() + faint * 0.08
    # Colour: warm, dusty-yellow core; bluer, whiter arms; reddened near dust.
    warm = np.clip(core * 1.2 + bulge, 0, 1)[..., None]
    col = (1 - warm) * np.array([0.78, 0.85, 1.0]) + warm * np.array([1.0, 0.86, 0.66])
    col = col * (1 - 0.3 * dust[..., None]) + dust[..., None] * 0.3 * np.array([0.9, 0.6, 0.45])
    rgb = np.clip(total[..., None] * col, 0, 1)
    img = np.zeros((MH, MW, 4), dtype=np.uint16)
    img[..., :3] = (rgb * 65535).astype(np.uint16)
    img[..., 3] = 65535
    img.tofile(OUT / "milkyway.dat")
    print("milkyway: baked")


def main():
    stars = load_stars(sys.argv[1])
    print(f"loaded {len(stars)} stars")
    bake_starmap(stars)
    bake_milkyway(stars)


if __name__ == "__main__":
    main()
