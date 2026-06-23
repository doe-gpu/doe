"""Import bootstrap for directly executed bench tools."""

from __future__ import annotations

import sys
from pathlib import Path


def ensure_repo_root(source_file: str | Path) -> Path:
    """Add the Doe repo root and bench root to ``sys.path``."""
    repo_root = Path(source_file).resolve().parents[2]
    bench_root = repo_root / "bench"
    for path in (repo_root, bench_root):
        path_text = str(path)
        if path_text not in sys.path:
            sys.path.insert(0, path_text)
    return repo_root
