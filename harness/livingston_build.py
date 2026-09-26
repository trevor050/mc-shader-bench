"""Build Rutgers Livingston campus in BenchWorld from OpenStreetMap, 1 block = 1 m, floating on the ocean.

Data: livingston_data/osm.json (Overpass export: buildings, highways, parking, natural, landuse, leisure, trees).
The map is projected around ORIGIN_LL (lat, lon) onto the flat ocean surface centred at ORIGIN_MC; ground is grass at
y 62 over dirt, so camera eye height at ground level is y 64.62. OSM has no heights here, so building heights and
materials come from HEIGHTS (from street view and aerial imagery). Trees: OSM tree nodes, rows along footpaths across
the lawns, and jittered stands in the wood polygons (Rutgers Ecological Preserve), plus the spruce by Tillett Hall.

Usage:
  py livingston_build.py plan            write livingston_data/commands.txt and a raster preview png
  py livingston_build.py build [ground]  send the commands to the game (tile by tile, loading chunks first);
                                         "ground" resends only the ground layers
"""
import json
import math
import random
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))

DATA = Path(__file__).parent / "livingston_data"
ORIGIN_LL = (40.5240, -74.4380)
ORIGIN_MC = (1370, 982)
HALF = 520                      # half extent of the built square, blocks
GROUND_Y = 62
TILE = 256
M_PER_DEG_LAT = 110_540.0
M_PER_DEG_LON = 111_320.0 * math.cos(math.radians(ORIGIN_LL[0]))

# (name substring, height m, block)
HEIGHTS = [
    ("Lynton", 36, "minecraft:bricks"),
    ("Livingston Apartments", 22, "minecraft:white_terracotta"),
    ("Student Housing Building A", 22, "minecraft:white_terracotta"),
    ("Residential Unit", 11, "minecraft:bricks"),
    ("Res Unit", 11, "minecraft:bricks"),
    ("Residental Unit", 11, "minecraft:bricks"),
    ("Residntial Unit", 11, "minecraft:bricks"),
    ("Tillett", 13, "minecraft:bricks"),
    ("Lucy Stone", 9, "minecraft:bricks"),
    ("Student Center", 13, "minecraft:light_gray_concrete"),
    ("Dining Commons", 12, "minecraft:light_gray_concrete"),
    ("Beck Hall", 18, "minecraft:gray_concrete"),
    ("Janice", 16, "minecraft:light_gray_concrete"),
    ("Business School", 26, "minecraft:white_concrete"),
    ("Carr Library", 10, "minecraft:brown_terracotta"),
    ("Jersey Mike", 22, "minecraft:light_gray_concrete"),
    ("Recreation Center", 14, "minecraft:light_gray_concrete"),
    ("Health Center", 9, "minecraft:bricks"),
]
DEFAULT_BUILDING = (10, "minecraft:light_gray_concrete")
ROAD_WIDTH = {"motorway_link": 8, "secondary": 12, "tertiary": 10, "unclassified": 7, "residential": 7,
              "service": 5, "track": 3, "footway": 3, "path": 2, "steps": 3, "pedestrian": 4}
# Ground codes in the raster.
GRASS, ROAD, WALK, PARKING, MEADOW, WATER = 0, 1, 2, 3, 4, 5
GROUND_BLOCK = {ROAD: "minecraft:black_concrete", WALK: "minecraft:light_gray_concrete",
                PARKING: "minecraft:gray_concrete", WATER: "minecraft:water"}


def project(lat: float, lon: float) -> tuple:
    """(lat, lon) -> raster pixel (px, pz); +x east, +z south, 1 px = 1 m, (HALF, HALF) at the origin."""
    x = (lon - ORIGIN_LL[1]) * M_PER_DEG_LON
    z = -(lat - ORIGIN_LL[0]) * M_PER_DEG_LAT
    return (x + HALF, z + HALF)


def to_world(px: float, pz: float) -> tuple:
    return (round(ORIGIN_MC[0] + px - HALF), round(ORIGIN_MC[1] + pz - HALF))


def load():
    d = json.loads((DATA / "osm.json").read_text(encoding="utf-8"))
    nodes = {e["id"]: e for e in d["elements"] if e["type"] == "node"}
    ways = {e["id"]: e for e in d["elements"] if e["type"] == "way"}
    rels = [e for e in d["elements"] if e["type"] == "relation"]
    return nodes, ways, rels


def way_points(way, nodes):
    return [project(nodes[n]["lat"], nodes[n]["lon"]) for n in way.get("nodes", []) if n in nodes]


def rects(mask: np.ndarray):
    """Greedy rectangles covering a boolean mask: row runs merged downward while identical."""
    out = []
    open_runs = {}
    for z in range(mask.shape[0] + 1):
        row = mask[z] if z < mask.shape[0] else np.zeros(mask.shape[1], bool)
        runs = set()
        if row.any():
            padded = np.concatenate([[False], row, [False]])
            edges = np.flatnonzero(padded[1:] != padded[:-1])
            runs = {(int(edges[i]), int(edges[i + 1]) - 1) for i in range(0, len(edges), 2)}
        for run in list(open_runs):
            if run not in runs:
                out.append((run[0], open_runs.pop(run), run[1], z - 1))
        for run in runs:
            if run not in open_runs:
                open_runs[run] = z
    return out


def split_rect(r, max_blocks, height):
    x0, z0, x1, z1 = r
    rows = max(1, max_blocks // max(1, (x1 - x0 + 1) * height))
    for zs in range(z0, z1 + 1, rows):
        yield (x0, zs, x1, min(z1, zs + rows - 1))


def plan():
    nodes, ways, rels = load()
    size = 2 * HALF + 1
    ground = Image.new("L", (size, size), GRASS)
    g = ImageDraw.Draw(ground)
    bld = []
    canopies = Image.new("1", (size, size), 0)
    cd = ImageDraw.Draw(canopies)
    woods = Image.new("1", (size, size), 0)
    wd = ImageDraw.Draw(woods)
    footways = []

    wood_ways = set()
    for r in rels:
        if r.get("tags", {}).get("natural") == "wood":
            wood_ways |= {m["ref"] for m in r.get("members", []) if m["type"] == "way" and m.get("role") == "outer"}

    for w in ways.values():
        t = w.get("tags", {})
        pts = way_points(w, nodes)
        if len(pts) < 2:
            continue
        closed = len(pts) > 3 and w["nodes"][0] == w["nodes"][-1]
        if t.get("amenity") == "parking" and closed:
            g.polygon(pts, fill=PARKING)
        elif t.get("natural") == "water" and closed:
            g.polygon(pts, fill=WATER)
        elif (t.get("landuse") == "meadow" or t.get("natural") == "grassland") and closed:
            g.polygon(pts, fill=MEADOW)
        if (t.get("natural") == "wood" and closed) or w["id"] in wood_ways:
            if closed:
                wd.polygon(pts, fill=1)
    for w in ways.values():
        t = w.get("tags", {})
        hw = t.get("highway")
        if hw in ROAD_WIDTH:
            pts = way_points(w, nodes)
            if len(pts) < 2:
                continue
            width = ROAD_WIDTH[hw]
            code = WALK if hw in ("footway", "path", "steps", "pedestrian", "track") else ROAD
            g.line(pts, fill=code, width=width)
            if code == WALK:
                footways.append(pts)
    for w in ways.values():
        t = w.get("tags", {})
        if "building" not in t:
            continue
        pts = way_points(w, nodes)
        if len(pts) < 4:
            continue
        if t["building"] == "roof":
            cd.polygon(pts, fill=1)
            continue
        name = t.get("name", "")
        h, block = DEFAULT_BUILDING
        for key, hh, bb in HEIGHTS:
            if key in name:
                h, block = hh, bb
                break
        m = Image.new("1", (size, size), 0)
        ImageDraw.Draw(m).polygon(pts, fill=1)
        bld.append((name, h, block, np.array(m, dtype=bool)))

    ground_a = np.array(ground)
    bmask = np.zeros((size, size), bool)
    for _, _, _, m in bld:
        bmask |= m
    cmds = []  # (tile key, command)

    def add(x0, z0, cmd, category="object"):
        wx, wz = to_world(x0, z0)
        key = ((wx - ORIGIN_MC[0] + HALF) // TILE, (wz - ORIGIN_MC[1] + HALF) // TILE)
        cmds.append((key, category, cmd))

    # Ground: dirt and grass everywhere, then surfaces. Issued in 64-block squares so each fill lies inside the chunks
    # loaded around its tile (one fill spanning the whole map failed silently where its far end was not loaded).
    for z0 in range(0, size, 64):
        for x0 in range(0, size, 64):
            x1, z1 = min(x0 + 63, size - 1), min(z0 + 63, size - 1)
            a, b = to_world(x0, z0)
            c, d = to_world(x1, z1)
            add(x0, z0, f"fill {a} {GROUND_Y - 2} {b} {c} {GROUND_Y - 1} {d} minecraft:dirt", "ground")
            add(x0, z0, f"fill {a} {GROUND_Y} {b} {c} {GROUND_Y} {d} minecraft:grass_block", "ground")
            # Clear anything standing on the ocean (islands, kelp tops) up to 8 blocks above the ground.
            add(x0, z0, f"fill {a} {GROUND_Y + 1} {b} {c} {GROUND_Y + 8} {d} minecraft:air replace minecraft:water", "ground")
    for code, block in GROUND_BLOCK.items():
        for r in rects(ground_a == code):
            for x0, z0, x1, z1 in split_rect(r, 32768, 1):
                a, b = to_world(x0, z0)
                c, d = to_world(x1, z1)
                add(x0, z0, f"fill {a} {GROUND_Y} {b} {c} {GROUND_Y} {d} {block}", "ground")
    for r in rects((ground_a == MEADOW) & ~bmask):
        for x0, z0, x1, z1 in split_rect(r, 32768, 1):
            a, b = to_world(x0, z0)
            c, d = to_world(x1, z1)
            add(x0, z0, f"fill {a} {GROUND_Y + 1} {b} {c} {GROUND_Y + 1} {d} minecraft:short_grass", "ground")
    # Buildings: solid blocks with a slab parapet line on the roof edge left out for simplicity.
    for name, h, block, m in bld:
        for r in rects(m):
            for x0, z0, x1, z1 in split_rect(r, 32768, h):
                a, b = to_world(x0, z0)
                c, d = to_world(x1, z1)
                add(x0, z0, f"fill {a} {GROUND_Y + 1} {b} {c} {GROUND_Y + h} {d} {block}")
    # Solar canopies over the lots: a thin dark roof about 4 m up.
    for r in rects(np.array(canopies, dtype=bool) & ~bmask):
        for x0, z0, x1, z1 in split_rect(r, 32768, 1):
            a, b = to_world(x0, z0)
            c, d = to_world(x1, z1)
            add(x0, z0, f"fill {a} {GROUND_Y + 5} {b} {c} {GROUND_Y + 5} {d} minecraft:blue_terracotta")

    # Trees.
    rng = random.Random(25)
    occupied = bmask | (ground_a == ROAD) | (ground_a == PARKING) | (ground_a == WALK) | np.array(canopies, dtype=bool)
    trees = []

    def try_tree(px, pz, feature):
        ix, iz = int(px), int(pz)
        if not (3 <= ix < size - 3 and 3 <= iz < size - 3):
            return
        if occupied[iz - 2:iz + 3, ix - 2:ix + 3].any():
            return
        for tx, tz, _ in trees:
            if (tx - ix) ** 2 + (tz - iz) ** 2 < 36:
                return
        trees.append((ix, iz, feature))

    for n in nodes.values():
        if n.get("tags", {}).get("natural") == "tree":
            px, pz = project(n["lat"], n["lon"])
            try_tree(px, pz, "minecraft:fancy_oak")
    broad = ["minecraft:fancy_oak", "minecraft:oak", "minecraft:fancy_oak", "minecraft:birch", "minecraft:dark_oak"]
    for pts in footways:
        for (x0, z0), (x1, z1) in zip(pts, pts[1:]):
            seg = math.hypot(x1 - x0, z1 - z0)
            if seg < 1:
                continue
            ux, uz = (x1 - x0) / seg, (z1 - z0) / seg
            t = rng.uniform(0, 12)
            while t < seg:
                for side in (-1, 1):
                    if rng.random() < 0.5:
                        px = x0 + ux * t - uz * side * 5.0
                        pz = z0 + uz * t + ux * side * 5.0
                        try_tree(px, pz, rng.choice(broad))
                t += 12
    wood_a = np.array(woods, dtype=bool)
    for iz in range(4, size - 4, 7):
        for ix in range(4, size - 4, 7):
            jx, jz = ix + rng.uniform(-2.5, 2.5), iz + rng.uniform(-2.5, 2.5)
            if wood_a[int(jz), int(jx)]:
                try_tree(jx, jz, rng.choice(["minecraft:oak", "minecraft:fancy_oak", "minecraft:dark_oak",
                                             "minecraft:birch", "minecraft:fancy_oak"]))
    # The big spruce by Tillett Hall in Trevor's tree photos: about 90 m west-south-west (257 deg) of where he stood.
    sx, sz = project(40.522142, -74.436364)
    sx += math.sin(math.radians(257)) * 90
    sz -= math.cos(math.radians(257)) * 90
    trees.append((int(sx), int(sz), "minecraft:mega_spruce"))
    for ix, iz, feature in trees:
        wx, wz = to_world(ix, iz)
        add(ix, iz, f"place feature {feature} {wx} {GROUND_Y + 1} {wz}")

    # Ground first everywhere (surfaces overwrite grass), then objects; tile order within each pass.
    cmds.sort(key=lambda c: (c[1] != "ground", c[0]))
    with open(DATA / "commands.txt", "w", encoding="utf-8") as f:
        for key, category, cmd in cmds:
            f.write(f"{key[0]} {key[1]}\t{category}\t{cmd}\n")
    prev = np.zeros((size, size, 3), np.uint8)
    prev[:] = (70, 130, 60)
    prev[ground_a == ROAD] = (30, 30, 30)
    prev[ground_a == WALK] = (180, 180, 180)
    prev[ground_a == PARKING] = (110, 110, 110)
    prev[ground_a == MEADOW] = (120, 150, 70)
    prev[wood_a] = (30, 80, 30)
    prev[bmask] = (170, 90, 60)
    img = Image.fromarray(prev)
    dr = ImageDraw.Draw(img)
    for ix, iz, _ in trees:
        dr.ellipse((ix - 2, iz - 2, ix + 2, iz + 2), fill=(10, 50, 10))
    img.save(DATA / "preview.png")
    print(f"{len(cmds)} commands, {len(bld)} buildings, {len(trees)} trees")


def build(only=None):
    from bench import Bench
    lines = (DATA / "commands.txt").read_text(encoding="utf-8").splitlines()
    if only:
        lines = [ln for ln in lines if ln.split("	")[1] == only]
    b = Bench()
    b.send("cmd gamerule sendCommandFeedback false")
    current = None
    for i, line in enumerate(lines):
        key, cmd = line.split("\t")
        if key != current:
            current = key
            tx, tz = (int(v) for v in key.split())
            cx = ORIGIN_MC[0] - HALF + tx * TILE + TILE // 2
            cz = ORIGIN_MC[1] - HALF + tz * TILE + TILE // 2
            b.send(f"cmd tp @s {cx} 140 {cz}")
            b.send("waitchunks 60")
            print(f"tile {key} ({i}/{len(lines)})", flush=True)
        b.send(f"cmd {cmd}")
    b.send("cmd gamerule sendCommandFeedback true")
    b.close()


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "build":
        build(sys.argv[2] if len(sys.argv) > 2 else None)
    else:
        plan()
