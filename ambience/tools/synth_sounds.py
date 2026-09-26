"""Synthesize the End storm ambience (no samples needed): mono Ogg Vorbis files for the ClaudeBench Ambience mod.

Layers
  wind_drone   seamless 24 s loop: deep, restless roar (brown noise, slow low-pass sweeps, amplitude drift)
  wind_howl    seamless 18 s loop: resonant, whistling gusts (band-passed noise with gliding resonances)
  rumble       seamless 20 s loop: sub-bass churn under everything
  alien_choir  seamless 30 s loop: eerie detuned tones through a formant filter, barely musical
  thunder_near_1..3, thunder_far_1..3: crack + rolling rumble one-shots

Usage: py synth_sounds.py
"""

from pathlib import Path

import numpy as np
import soundfile as sf
from scipy import signal

SR = 44100
OUT = Path(__file__).resolve().parent.parent / "src" / "main" / "resources" / "assets" / "claudebench_ambience" / "sounds"
rng = np.random.default_rng(1234)


def brown(n):
    x = np.cumsum(rng.standard_normal(n))
    x = signal.lfilter([1, -1], [1, -0.995], x)  # remove drift, keep the low end
    return x / np.max(np.abs(x))


def pink(n):
    b = [0.049922035, -0.095993537, 0.050612699, -0.004408786]
    a = [1, -2.494956002, 2.017265875, -0.522189400]
    x = signal.lfilter(b, a, rng.standard_normal(n))
    return x / np.max(np.abs(x))


def smooth_noise(n, rate_hz, seed):
    """Slow random curve in [0, 1] with about rate_hz changes per second."""
    r = np.random.default_rng(seed)
    k = max(int(n / SR * rate_hz) + 3, 4)
    pts = r.random(k)
    x = np.linspace(0, k - 3, n)
    i = np.floor(x).astype(int)
    f = x - i
    f = f * f * (3 - 2 * f)
    return pts[i] * (1 - f) + pts[i + 1] * f


def time_varying_bandpass(x, centers, q, block=512):
    """Band-pass with a centre frequency that changes over time (per block, with state carried over)."""
    y = np.zeros_like(x)
    zi = None
    for s in range(0, len(x), block):
        fc = float(np.clip(centers[s], 40, SR / 2 - 100))
        b, a = signal.iirpeak(fc, q, fs=SR)
        if zi is None:
            zi = signal.lfilter_zi(b, a) * 0
        y[s:s + block], zi = signal.lfilter(b, a, x[s:s + block], zi=zi)
    return y


def loopify(x, fade_s=2.0):
    """Crossfade the tail into the head so the file loops without a seam."""
    f = int(fade_s * SR)
    head, tail = x[:f].copy(), x[-f:].copy()
    w = np.linspace(0, 1, f)
    out = x[f:].copy()
    out[-f:] = tail * (1 - w) + head * w
    return out


def normalize(x, peak=0.9):
    return x / (np.max(np.abs(x)) + 1e-9) * peak


def write(name, x):
    OUT.mkdir(parents=True, exist_ok=True)
    # libsndfile's Vorbis encoder crashes on large single writes; stream it in blocks.
    data = normalize(x).astype(np.float32)
    with sf.SoundFile(OUT / f"{name}.ogg", "w", SR, 1, format="OGG", subtype="VORBIS") as f:
        for s in range(0, len(data), 8192):
            f.write(data[s:s + 8192])
    print(name, f"{len(x) / SR:.1f}s")


def wind_drone(secs=26):
    n = secs * SR
    x = brown(n) * 0.7 + pink(n) * 0.3
    cutoff = 180 + 520 * smooth_noise(n, 0.25, 1)
    y = np.zeros(n)
    zi = None
    for s in range(0, n, 512):
        b, a = signal.butter(2, cutoff[s], fs=SR)
        if zi is None:
            zi = signal.lfilter_zi(b, a) * 0
        y[s:s + 512], zi = signal.lfilter(b, a, x[s:s + 512], zi=zi)
    y *= 0.55 + 0.45 * smooth_noise(n, 0.4, 2)
    return loopify(y)


def wind_howl(secs=20):
    n = secs * SR
    x = pink(n)
    g = smooth_noise(n, 0.35, 3) ** 2
    c1 = 260 + 700 * smooth_noise(n, 0.3, 4)
    c2 = 900 + 1400 * smooth_noise(n, 0.22, 5)
    y = time_varying_bandpass(x, c1, 9) * 1.0 + time_varying_bandpass(x, c2, 14) * 0.45
    y *= 0.15 + 0.85 * g
    return loopify(y)


def rumble(secs=22):
    n = secs * SR
    b, a = signal.butter(3, 90, fs=SR)
    y = signal.lfilter(b, a, brown(n))
    y *= 0.5 + 0.5 * smooth_noise(n, 0.5, 6)
    return loopify(y)


def alien_choir(secs=32):
    """Low detuned tones with slow beating, pushed through gliding vowel-like formants: unsettling, not a melody."""
    n = secs * SR
    t = np.arange(n) / SR
    base = [55.0, 58.3, 82.4, 87.3, 110.0 * 1.012]
    x = np.zeros(n)
    for i, f in enumerate(base):
        vib = 1 + 0.004 * np.sin(2 * np.pi * (0.07 + 0.03 * i) * t + i)
        phase = 2 * np.pi * np.cumsum(f * vib) / SR
        # Sawtooth-ish: rich in harmonics so the formants have something to shape.
        x += signal.sawtooth(phase) * (0.6 + 0.4 * smooth_noise(n, 0.1, 10 + i))
    x += pink(n) * 0.25
    f1 = 350 + 350 * smooth_noise(n, 0.08, 20)
    f2 = 1100 + 900 * smooth_noise(n, 0.06, 21)
    y = time_varying_bandpass(x, f1, 6) + 0.6 * time_varying_bandpass(x, f2, 8)
    y *= 0.4 + 0.6 * smooth_noise(n, 0.12, 22)
    return loopify(y, 3.0)


def thunder(near, seed, secs=7.0):
    r = np.random.default_rng(seed)
    n = int(secs * SR)
    t = np.arange(n) / SR
    x = np.zeros(n)
    # Crack: a few broadband bursts in quick succession (branches of the bolt).
    if near:
        for k in range(r.integers(3, 6)):
            t0 = r.uniform(0.0, 0.25)
            env = np.exp(-np.maximum(t - t0, 0) / r.uniform(0.02, 0.06)) * (t >= t0)
            x += env * r.standard_normal(n) * r.uniform(0.6, 1.0)
    # Rolling rumble: brown noise with a slow irregular envelope.
    roll_env = np.exp(-t / (2.2 if near else 3.0)) * (0.5 + 0.5 * smooth_noise(n, 2.0, seed + 1)) * (1 - np.exp(-t / 0.05))
    rum = brown(n)
    b, a = signal.butter(3, 260 if near else 140, fs=SR)
    x += signal.lfilter(b, a, rum) * roll_env * (1.6 if near else 2.2)
    if not near:
        b, a = signal.butter(2, 900, fs=SR)
        x = signal.lfilter(b, a, x)
    x[-int(0.3 * SR):] *= np.linspace(1, 0, int(0.3 * SR))
    return x


def main():
    write("wind_drone", wind_drone())
    write("wind_howl", wind_howl())
    write("rumble", rumble())
    write("alien_choir", alien_choir())
    for i in range(3):
        write(f"thunder_near_{i + 1}", thunder(True, 100 + i))
        write(f"thunder_far_{i + 1}", thunder(False, 200 + i))


if __name__ == "__main__":
    main()
