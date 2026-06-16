"""Shared context for E2B layer-block self-check contracts."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class SelfCheckPaths:
    repo_root: Path
    runner_path: Path
    kernel_path: Path
    synthetic_path: Path
    receipt_path: Path
    schema_path: Path


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()
