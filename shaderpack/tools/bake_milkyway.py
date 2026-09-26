"""Bake the Milky Way glow texture (textures/milkyway.dat, 2048x1024 RGBA16, equirectangular in RA/Dec).

A painted-from-photographs model in galactic coordinates, aligned with the real sky:
  - a thin disc that thickens and brightens toward the galactic centre, with a golden bulge in Sagittarius,
  - bright, mottled star clouds (Scutum, Sagittarius, Cygnus),
  - the Great Rift (a broad dust lane from Cygnus to Sagittarius) plus filamentary dust along the plane, with
    reddened, brown edges,
  - blue-white outer arms,
  - pink hydrogen-alpha nebulae at their real positions, the colourful Rho Ophiuchi region, the Magellanic
    Clouds and Andromeda,
  - a dark background between them.
No star catalogue is needed. Usage: py bake_milkyway.py
"""

from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import map_coordinates

OUT = Path(__file__).resolve().parent.parent / "shaders" / "textures"
MW, MH = 2048, 1024
GW, GH = 4096, 2048  # galactic-coordinate noise canvas (l: -pi..pi, b: -pi/2..pi/2)

EQ_TO_GAL = np.array([
    [-0.0548755604, -0.8734370902, -0.4838350155],
    [0.4941094279, -0.4448296300, 0.7469822445],
    [-0.8676661490, -0.1980763734, 0.4559837762],
])

rng = np.random.default_rng(20260924)


def noise_canvas(cells_x, cells_y):
    """Smooth value noise on the galactic canvas, periodic in longitude."""
    base = rng.random((cells_y, cells_x)).astype(np.float32)
    base = np.concatenate([base, base[:, :1]], axis=1)  # wrap in l
    img = Image.fromarray(base, mode="F").resize((GW + GW // cells_x, GH), Image.BICUBIC)
    return np.asarray(img)[:, :GW]


def fbm(octaves, cells, gain=0.55):
    out = np.zeros((GH, GW), np.float32)
    amp, total = 1.0, 0.0
    for i in range(octaves):
        c = int(cells * 2 ** i)
        out += noise_canvas(c, max(c // 2, 2)) * amp
        total += amp
        amp *= gain
    return out / total


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def main():
    # Galactic canvas coordinates.
    lg = (np.arange(GW) + 0.5) / GW * 2 * np.pi - np.pi
    bg = ((np.arange(GH) + 0.5) / GH - 0.5) * np.pi
    L, B = np.meshgrid(lg, bg)
    deg = np.radians

    # Longitude-dependent terms converge at the galactic poles; blend them to a constant there (no pinch).
    pole = smoothstep(deg(30), deg(70), np.abs(B))
    core = np.exp(-np.abs(L) / 1.05) * (1 - pole) + 0.3 * pole
    width = deg(4.5 + 7.5 * core)
    disc = np.exp(-np.abs(B) / width) * (0.22 + 0.78 * core)
    halo = np.exp(-np.abs(B) / (width * 3.0)) * 0.10 * (0.3 + 0.7 * core)
    bulge = np.exp(-(L / 0.23) ** 2 - (B / 0.15) ** 2) * 1.5

    # Star clouds: mottled bright patches.
    n1 = fbm(4, 48)
    n2 = fbm(4, 160)
    clouds = smoothstep(0.35, 0.78, n1 * 0.65 + n2 * 0.35)
    starclouds = 0.35 + 1.25 * clouds
    # Named bright clouds (l, b in degrees, radius, gain).
    for l0, b0, r, g in [(27, -3, 3.5, 0.9), (8, -3.5, 4.0, 1.1), (357, -4, 3.0, 0.8), (75, 1, 6.0, 0.6),
                         (285, -1, 5.0, 0.5), (305, 0, 6.0, 0.35)]:
        dl = np.angle(np.exp(1j * (L - deg(l0))))
        starclouds += g * np.exp(-(dl ** 2 + (B - deg(b0)) ** 2) / deg(r) ** 2)
    glow = (disc * starclouds + bulge) + halo

    # Dust: ridged filaments hugging the plane, the Great Rift, and dark nebulae around Ophiuchus.
    r1 = 1.0 - np.abs(2.0 * fbm(5, 40) - 1.0)
    r2 = 1.0 - np.abs(2.0 * fbm(4, 130) - 1.0)
    fil = smoothstep(0.62, 0.92, r1 * 0.6 + r2 * 0.4) * np.exp(-(B / deg(6.0)) ** 2)
    rift_l = smoothstep(deg(-8), deg(5), L) * (1 - smoothstep(deg(70), deg(88), L))
    rift = np.exp(-((B - deg(1.2) - 0.02 * L) / deg(2.6)) ** 2) * rift_l * (0.55 + 0.45 * fbm(4, 90))
    oph = np.exp(-(np.angle(np.exp(1j * (L - deg(0)))) ** 2 + (B - deg(9)) ** 2) / deg(7) ** 2) * fbm(4, 70)
    dust = np.clip(fil * 0.85 + rift * 1.0 + oph * 0.6, 0, 1)
    glow *= np.clip(1.0 - dust * 0.93, 0.03, 1.0)

    # Colour.
    warm = np.clip(core * 1.1 + bulge * 0.8, 0, 1)[..., None]
    arms = np.array([0.60, 0.72, 1.0])
    gold = np.array([1.0, 0.70, 0.40])
    col = (1 - warm) * arms + warm * gold
    # Bright star clouds read whiter; dust edges reddened brown.
    col = col * (1 - 0.35 * clouds[..., None] * (1 - warm)) + 0.35 * clouds[..., None] * (1 - warm) * np.array([0.9, 0.92, 1.0])
    edge = (dust * (1 - dust) * 4.0)[..., None]
    col = col * (1 - 0.45 * edge) + 0.45 * edge * np.array([1.0, 0.55, 0.32])
    rgb = glow[..., None] * col

    # Emission nebulae (hydrogen-alpha pink) and the Rho Ophiuchi colours.
    neb_noise = fbm(4, 220)
    def blob(l0, b0, r, colr, gain, shape=1.0):
        dl = np.angle(np.exp(1j * (L - deg(l0))))
        g = np.exp(-(dl ** 2 + (B - deg(b0)) ** 2) / deg(r) ** 2)
        return g[..., None] * np.array(colr) * gain * (0.4 + 0.6 * neb_noise[..., None] ** shape)
    halpha = [1.0, 0.28, 0.45]
    rgb += blob(6.0, -1.2, 1.3, halpha, 1.6)      # Lagoon + Trifid
    rgb += blob(17.0, 0.8, 1.2, halpha, 0.9)      # Eagle / Omega
    rgb += blob(85.0, -1.0, 2.2, halpha, 0.8)     # North America / Pelican
    rgb += blob(78.0, 2.0, 4.0, halpha, 0.35)     # Cygnus complex
    rgb += blob(287.6, -0.6, 1.8, halpha, 1.3)    # Eta Carinae
    rgb += blob(209.0, -19.4, 1.6, halpha, 0.9)   # Orion Nebula
    rgb += blob(207.0, -17.0, 7.0, halpha, 0.25)  # Barnard's Loop region
    rgb += blob(268.0, -1.0, 5.0, halpha, 0.25)   # Gum / Vela
    rgb += blob(353.0, 17.5, 3.5, [0.45, 0.6, 1.0], 0.35)   # Rho Oph blue reflection
    rgb += blob(351.9, 15.1, 2.0, [1.0, 0.75, 0.35], 0.45)  # Antares' yellow glow
    rgb += blob(1.0, 21.0, 2.5, [1.0, 0.35, 0.4], 0.25)     # Sh2-27 hint
    # Magellanic Clouds and Andromeda: soft smudges well off the plane.
    rgb += blob(280.5, -32.9, 3.2, [0.85, 0.88, 1.0], 0.28, 0.5)
    rgb += blob(302.8, -44.3, 1.6, [0.85, 0.88, 1.0], 0.2, 0.5)
    rgb += blob(121.2, -21.6, 0.9, [1.0, 0.92, 0.82], 0.30, 0.3)

    # Very faint unresolved sky background.
    rgb += 0.006 * (0.6 + 0.4 * (fbm(3, 20) * (1 - pole) + 0.5 * pole))[..., None]
    rgb /= np.percentile(rgb.max(-1), 99.93)
    rgb = np.clip(rgb, 0, 1).astype(np.float32)

    # Resample the galactic canvas into the equatorial texture.
    u = (np.arange(MW) + 0.5) / MW * 2 * np.pi
    v = ((np.arange(MH) + 0.5) / MH - 0.5) * np.pi
    ra, dec = np.meshgrid(u, v)
    eq = np.stack([np.cos(dec) * np.cos(ra), np.cos(dec) * np.sin(ra), np.sin(dec)], -1)
    gal = eq @ EQ_TO_GAL.T
    l = np.arctan2(gal[..., 1], gal[..., 0])
    b = np.arcsin(np.clip(gal[..., 2], -1, 1))
    px = (l + np.pi) / (2 * np.pi) * GW - 0.5
    py = (b / np.pi + 0.5) * GH - 0.5
    out = np.zeros((MH, MW, 4), np.uint16)
    for c in range(3):
        ch = map_coordinates(rgb[..., c], [py, px], order=1, mode="grid-wrap")
        out[..., c] = (np.clip(ch, 0, 1) * 65535).astype(np.uint16)
    out[..., 3] = 65535
    out.tofile(OUT / "milkyway.dat")
    prev = (np.clip(out[..., :3] / 65535.0 * 3.0, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)
    Image.fromarray(prev).save(OUT.parent.parent / "tools" / "milkyway_preview.png")
    print("milkyway: baked", MW, MH)


if __name__ == "__main__":
    main()
