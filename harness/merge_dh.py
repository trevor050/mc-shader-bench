"""Merge a Distant Horizons LOD database (e.g. from a dedicated-server pregen) into the client world's.

Usage: py merge_dh.py <source DistantHorizons.sqlite> <target DistantHorizons.sqlite>
Source rows replace target rows with the same key. Run only while the game is closed.
"""

import shutil
import sqlite3
import sys
from pathlib import Path

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
backup = dst.with_suffix(".sqlite.bak")
if not backup.exists():
    # Checkpoint the WAL first so the backup is self-contained.
    sqlite3.connect(dst).execute("PRAGMA wal_checkpoint(TRUNCATE)").close()
    shutil.copy2(dst, backup)
    print("backup:", backup)

con = sqlite3.connect(dst)
con.execute("ATTACH DATABASE ? AS src", (str(src),))
tables = [r[0] for r in con.execute("SELECT name FROM src.sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
for t in tables:
    exists = con.execute("SELECT 1 FROM main.sqlite_master WHERE type='table' AND name=?", (t,)).fetchone()
    before = con.execute(f'SELECT COUNT(*) FROM main."{t}"').fetchone()[0] if exists else 0
    if not exists:
        sql = con.execute("SELECT sql FROM src.sqlite_master WHERE name=?", (t,)).fetchone()[0]
        con.execute(sql)
    if t.lower().startswith("schema") or "migration" in t.lower():
        print(f"{t}: skipped (metadata)")
        continue
    con.execute(f'INSERT OR REPLACE INTO main."{t}" SELECT * FROM src."{t}"')
    after = con.execute(f'SELECT COUNT(*) FROM main."{t}"').fetchone()[0]
    print(f"{t}: {before} -> {after} rows")
con.commit()
con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
con.close()
