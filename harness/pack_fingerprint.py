"""Stable content fingerprints for a shaderpack directory or archive."""

from __future__ import annotations

import hashlib
from pathlib import Path


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def shaderpack_sha256(path: Path) -> str:
    """Hash a pack archive byte-for-byte or a folder by sorted relative file content."""
    path = path.resolve()
    if path.is_file():
        return sha256_file(path)
    if not path.is_dir():
        raise FileNotFoundError(f"shaderpack artifact does not exist: {path}")

    digest = hashlib.sha256()
    files = sorted((entry for entry in path.rglob("*") if entry.is_file()),
                   key=lambda entry: entry.relative_to(path).as_posix().casefold())
    if not files:
        raise ValueError(f"shaderpack directory is empty: {path}")
    for entry in files:
        relative = entry.relative_to(path).as_posix().encode("utf-8")
        content_hash = bytes.fromhex(sha256_file(entry))
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(content_hash)
    return digest.hexdigest()
