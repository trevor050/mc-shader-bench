"""Bake a tileable 64^3 RGBA16 cloud noise volume for the shader pack.

R: Perlin-Worley (billowy base shape)
G, B, A: inverted Worley at increasing frequencies (used for erosion)

Output: ../shaders/textures/cloudnoise.dat, raw RGBA16 (little-endian), x fastest. Referenced from
shaders.properties. 16 bits matter: the density remap stretches narrow ranges and 8-bit data bands visibly.
"""

from pathlib import Path

import numpy as np

N = 64
rng = np.random.default_rng(1337)
coords = np.stack(np.meshgrid(np.arange(N), np.arange(N), np.arange(N), indexing="ij"), -1).astype(np.float32) / N


def worley(freq: int) -> np.ndarray:
    """Tileable F1 Worley noise, one feature point per cell."""
    pts = rng.random((freq, freq, freq, 3)).astype(np.float32)
    p = coords * freq
    cell = np.floor(p).astype(int)
    best = np.full(p.shape[:3], 10.0, dtype=np.float32)
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for dz in (-1, 0, 1):
                off = np.array([dx, dy, dz])
                c = cell + off
                wrapped = c % freq
                fp = pts[wrapped[..., 0], wrapped[..., 1], wrapped[..., 2]] + c
                d = np.linalg.norm(fp - p, axis=-1)
                best = np.minimum(best, d)
    return np.clip(best, 0.0, 1.0)


def perlin(freq: int) -> np.ndarray:
    """Tileable gradient noise in [-1, 1]."""
    g = rng.normal(size=(freq, freq, freq, 3)).astype(np.float32)
    g /= np.linalg.norm(g, axis=-1, keepdims=True)
    p = coords * freq
    i0 = np.floor(p).astype(int)
    f = p - i0
    u = f * f * f * (f * (f * 6 - 15) + 10)
    out = np.zeros(p.shape[:3], dtype=np.float32)
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                off = np.array([dx, dy, dz])
                c = (i0 + off) % freq
                grad = g[c[..., 0], c[..., 1], c[..., 2]]
                dot = np.sum(grad * (f - off), axis=-1)
                w = (u[..., 0] if dx else 1 - u[..., 0]) * (u[..., 1] if dy else 1 - u[..., 1]) * (u[..., 2] if dz else 1 - u[..., 2])
                out += w * dot
    return out


def fbm(fn, base: int, octaves: int) -> np.ndarray:
    total, amp, norm = 0.0, 1.0, 0.0
    for o in range(octaves):
        total = total + fn(base * 2**o) * amp
        norm += amp
        amp *= 0.5
    return total / norm


def remap(v, lo, hi, nlo, nhi):
    return nlo + (v - lo) * (nhi - nlo) / (hi - lo)


def norm01(a):
    return (a - a.min()) / (a.max() - a.min())


w1 = 1.0 - fbm(worley, 4, 3)
w2 = 1.0 - fbm(worley, 8, 3)
w3 = 1.0 - fbm(worley, 16, 3)
p = norm01(fbm(perlin, 4, 4))
perlin_worley = np.clip(remap(p, w1 - 1.0, 1.0, 0.0, 1.0), 0.0, 1.0)

vol = np.stack([norm01(perlin_worley), norm01(w1), norm01(w2), norm01(w3)], -1)
data = (vol * 65535.0 + 0.5).astype("<u2")
# Texture upload order is x fastest, then y, then z.
data = np.transpose(data, (2, 1, 0, 3))
out = Path(__file__).resolve().parent.parent / "shaders" / "textures" / "cloudnoise.dat"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_bytes(data.tobytes())
print(out, data.nbytes)
