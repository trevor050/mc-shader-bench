"""Client for the BenchCam mod: scripted camera placement and screenshots.

Usage:
  py bench.py raw "status"                 send one command, print reply
  py bench.py shots [scene ...]            capture scenes from scenes.json (all if none given)
  py bench.py reload                       hot-reload the shader pack, report compile errors
  py bench.py launch                       start the game straight into BenchWorld
"""

import json
import socket
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

HERE = Path(__file__).resolve().parent
PORT = 25599
INSTANCE = "ShaderBench"
PRISM = Path.home() / "AppData/Local/Programs/PrismLauncher/prismlauncher.exe"
GAME_DIR = Path.home() / "AppData/Roaming/PrismLauncher/instances" / INSTANCE / "minecraft"
LOG = GAME_DIR / "logs" / "latest.log"
# Top-left of the game window: parks it on the secondary (left) monitor, clear of the main screen.
WINDOW_POS = (-2496, 220)


class Bench:
    def __init__(self, port: int = PORT, timeout: float = 600):
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=timeout)
        self.rfile = self.sock.makefile("r", encoding="utf-8")

    def send(self, line: str) -> str:
        self.sock.sendall((line + "\n").encode("utf-8"))
        reply = self.rfile.readline().strip()
        if reply.startswith("err"):
            raise RuntimeError(f"{line!r} -> {reply}")
        return reply

    def close(self):
        self.sock.close()


def wait_for_game(timeout: float = 300) -> Bench:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            b = Bench()
            b.send("ping")
            return b
        except OSError:
            time.sleep(2)
    raise TimeoutError("BenchCam did not come up")


def wait_for_world(b: Bench, timeout: float = 300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if "pos=none" not in b.send("status"):
            return
        time.sleep(2)
    raise TimeoutError("player never joined a world")


def log_size() -> int:
    return LOG.stat().st_size if LOG.exists() else 0


def new_log_errors(offset: int) -> list[str]:
    if not LOG.exists():
        return []
    with LOG.open("r", encoding="utf-8", errors="replace") as f:
        f.seek(offset)
        text = f.read()
    keys = ("error", "Failed to compile", "shader", "Shader", "Iris")
    return [l for l in text.splitlines() if "ERROR" in l or ("Iris" in l and any(k in l for k in keys[1:]))]


def reload(b: Bench) -> list[str]:
    off = log_size()
    b.send("reload")
    b.send("wait 10")
    return new_log_errors(off)


def capture(b: Bench, scenes: dict, names: list[str], out_dir: Path):
    b.send("mouse free")
    b.send("closescreen")
    b.send("hud off")
    b.send("cmd gamemode spectator")
    for name in names:
        s = scenes[name]
        x, y, z = s["pos"]
        yaw, pitch = s.get("look", [0, 0])
        b.send(f"cmd tp @s {x} {y} {z} {yaw} {pitch}")
        b.send(f"cmd time set {s.get('time', 6000)}")
        b.send(f"cmd weather {s.get('weather', 'clear')}")
        # The teleport lands a tick or two later; let the renderer notice before polling chunks.
        b.send("wait 10")
        b.send("waitchunks 600")
        b.send(f"wait {s.get('settle', 40)}")
        path = out_dir / f"{name}.png"
        b.send(f"shot {path}")
        print(f"  {name}: {path}")
    b.send("hud on")
    # Leave the player playable. The mouse stays free (auto-grabbing traps the OS cursor if nobody is at the
    # game); clicking inside the game window takes control again.
    b.send("cmd gamemode creative")


def contact_sheet(out_dir: Path, names: list[str], cell_w: int = 640, cols: int = 3) -> Path:
    """Tile the run's screenshots into one labeled image so a whole run can be reviewed at once."""
    from PIL import Image, ImageDraw

    cell_h = cell_w * 9 // 16
    rows = (len(names) + cols - 1) // cols
    sheet = Image.new("RGB", (cell_w * cols, cell_h * rows), "black")
    draw = ImageDraw.Draw(sheet)
    for i, name in enumerate(names):
        img = Image.open(out_dir / f"{name}.png").convert("RGB").resize((cell_w, cell_h), Image.LANCZOS)
        x, y = (i % cols) * cell_w, (i // cols) * cell_h
        sheet.paste(img, (x, y))
        draw.rectangle((x, y, x + 8 + 7 * len(name), y + 16), fill="black")
        draw.text((x + 4, y + 2), name, fill="white")
    path = out_dir / "sheet.jpg"
    sheet.save(path, quality=88)
    return path


def main(argv: list[str]):
    if not argv:
        print(__doc__)
        return
    cmd, args = argv[0], argv[1:]

    if cmd == "launch":
        subprocess.Popen([str(PRISM), "--launch", INSTANCE, "--world", "BenchWorld"])
        b = wait_for_game()
        b.send(f"window {WINDOW_POS[0]} {WINDOW_POS[1]}")
        wait_for_world(b)
        print(b.send("status"))
        return

    b = wait_for_game(timeout=10)
    if cmd == "raw":
        for line in args:
            print(b.send(line))
    elif cmd == "reload":
        errs = reload(b)
        print("\n".join(errs) if errs else "reload ok, no errors logged")
    elif cmd == "shots":
        vanilla = "--vanilla" in args
        names_arg = [a for a in args if not a.startswith("--")]
        scenes = json.loads((HERE / "scenes.json").read_text())
        names = names_arg or list(scenes)
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        out = HERE / "out" / (stamp + ("-vanilla" if vanilla else ""))
        if vanilla:
            b.send("shaders off")
        try:
            capture(b, scenes, names, out)
        finally:
            if vanilla:
                b.send("shaders on")
        print(contact_sheet(out, names))
    elif cmd == "sheet":
        out = Path(args[0])
        print(contact_sheet(out, [p.stem for p in sorted(out.glob("*.png")) if p.stem != "sheet"]))
    else:
        print(__doc__)
    b.close()


if __name__ == "__main__":
    main(sys.argv[1:])
