"""CPU numerical gates for the sky performance kernels, without a GPU context.

This verifies conservative dark-light rejection and complete lower-tier cloud
interval coverage. It does not establish image equivalence or Minecraft speed.
"""
from pathlib import Path
import json
import hashlib
import re
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
clouds = (ROOT / 'shaderpack/shaders/lib/clouds.glsl').read_text()
atmosphere = (ROOT / 'shaderpack/shaders/lib/atmosphere.glsl').read_text()
quality = (ROOT / 'shaderpack/shaders/lib/performance_quality.glsl').read_text()

cap = float(re.search(r'min\(raySphere\(ro, rd, ATM_TOP\).y, ([\d.]+)e3\)', atmosphere)[1]) * 1000
radius = float(re.search(r'ATM_GROUND = ([\d.]+)e3', atmosphere)[1]) * 1000 + 200
guard = float(re.search(r'lightDir.y \+ ([\d.]+) <= -0.12', atmosphere)[1])
assert guard > cap / radius
assert -0.12 - guard < -0.15  # skySelf is identically zero too.

# Sweep unit directions around the most permissive rejected elevation. The
# sample up-vector lies on the great circle between vertical and the ray.
elevation = np.linspace(0, np.pi / 2, 241)
distance = np.linspace(0, cap, 129)
e, t = np.meshgrid(elevation, distance)
px, py = np.cos(e) * t, radius + np.sin(e) * t
length = np.hypot(px, py)
up_x, up_y = px / length, py / length
ly = -0.12 - guard
max_dot = float(np.max(up_x * np.sqrt(1 - ly * ly) + up_y * ly))
assert max_dot < -0.12

report = {'source_sha256': {name: hashlib.sha256(source.encode()).hexdigest() for name, source in
          [('clouds', clouds), ('atmosphere', atmosphere), ('performance_quality', quality)]},
          'dark_light_gate': {'ray_cap': cap, 'camera_radius': radius,
          'proven_up_bound': cap / radius, 'guard': guard,
          'direction_distance_cases': int(e.size), 'max_terminator_dot': max_dot}, 'coverage': {}}

# Replay the production lower-tier step expression in float32. No opacity
# termination is assumed, so every scene-clipped interval must finish.
kernel = clouds.split('// Lower tiers integrate every segment')[1].split('#endif')[0]
nominal_counts = tuple(map(int, re.search(r'PERFORMANCE_PROFILE == 2 \? (\d+)\.0 : (\d+)\.0', kernel).groups()))
loop_bound = int(re.search(r'for \(int i = 0; i < (\d+)', kernel)[1])
base, growth = map(float, re.search(r'\((\d+\.\d+) \+ segmentStart \* (\d+\.\d+)\) \* CLOUD_MARCH_SCALE', kernel).groups())
min_stride, relative_stride = map(float, re.search(r'max\((\d+\.\d+), t0 \* (\de-\d+)\)', kernel).groups())
starts, spans = np.meshgrid(np.array([0., .1, 1., 60., 400., 1200., 6000., 12000.], dtype='f4'),
                           np.linspace(.01, 24000, 2401, dtype='f4'))
for tier, profile, nominal_count in [('Medium', 2, nominal_counts[0]), ('Low', 1, nominal_counts[1])]:
    scale = float(re.search(rf'#elif PERFORMANCE_PROFILE == {profile}\s.*?#define CLOUD_MARCH_SCALE ([\d.]+)', quality, re.S)[1])
    end = starts + spans
    pos = starts.copy()
    nominal = np.maximum((end - starts) / np.float32(nominal_count), np.maximum(np.float32(min_stride), starts * np.float32(relative_stride)))
    counts = np.zeros(starts.shape, dtype='i4')
    for _ in range(loop_bound):
        active = pos < end
        counts += active
        step = np.minimum(np.minimum(nominal, (np.float32(base) + pos * np.float32(growth)) * np.float32(scale)), end - pos)
        pos += np.where(active, step, 0)
    assert np.all(pos >= end), (tier, float(np.max(end - pos)))
    report['coverage'][tier] = {'intervals': int(pos.size), 'maximum_span': float(spans.max()),
                              'max_steps': int(counts.max()), 'loop_bound': loop_bound}

# Preserve the baseline's established iteration behavior, and make its
# uncovered long/shallow intervals visible instead of describing them as a gain.
baseline = []
for start, span in [(0, 6000), (60, 5940), (1000, 5000), (2000, 4000), (0, 1200)]:
    pos = float(start)
    step = np.clip(span / 40, 3, 12 + start * .02)
    for i in range(64):
        if pos >= start + span:
            break
        pos += step
        step = min(step * 1.035, 12 + pos * .02)
    baseline.append({'start': start, 'span': span, 'reached': pos,
                     'uncovered': max(start + span - pos, 0)})
report['baseline_ultra_high_coverage_caveat'] = baseline
out = ROOT / 'work/sky-performance-cpu.json'
out.parent.mkdir(exist_ok=True)
out.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
