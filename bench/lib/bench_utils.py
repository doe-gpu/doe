"""Shared utility functions for bench tooling.

Centralizes commonly duplicated helpers (JSON loading, path
canonicalization, repo-root detection) so that bench scripts import
from one place instead of copy-pasting identical definitions.
"""

from __future__ import annotations

import json
from pathlib import Path, PurePosixPath
from typing import Any


def load_json(path: Path) -> Any:
    """Load a JSON or JSONL file and return its parsed content.

    For ``.json`` files the return type mirrors the top-level JSON value
    (usually a ``dict`` or ``list``).  For ``.jsonl`` files a list of
    parsed objects is returned, one per non-empty line.
    """
    if path.suffix == ".jsonl":
        payloads: list[Any] = []
        for line_no, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                payloads.append(json.loads(stripped))
            except json.JSONDecodeError as exc:
                raise json.JSONDecodeError(
                    f"{exc.msg} (line {line_no})",
                    exc.doc,
                    exc.pos,
                ) from exc
        return payloads
    return json.loads(path.read_text(encoding="utf-8"))


def load_json_object(path: Path) -> dict[str, Any]:
    """Load a JSON file and verify the top-level value is an object.

    Raises ``ValueError`` when the file does not contain a JSON object.
    """
    payload = load_json(path)
    if not isinstance(payload, dict):
        raise ValueError(f"invalid JSON object: {path}")
    return payload


def write_json_object(path: Path, payload: dict[str, Any]) -> None:
    """Write a JSON object using the canonical bench object formatting."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def unsafe_repo_path_reason(value: Any, *, allow_empty: bool = True) -> str:
    """Return a policy reason when *value* is not a safe repo-relative path."""
    if not isinstance(value, str):
        return "path must be a string"
    if not value:
        return "" if allow_empty else "path must be a non-empty string"
    if "\\" in value:
        return "path must use forward slashes"
    path = PurePosixPath(value)
    if path.is_absolute():
        return "path must be repository-relative"
    if any(part in ("", ".", "..") for part in value.split("/")):
        return "path must not contain empty, current, or parent segments"
    return ""


def is_safe_repo_path(value: Any, *, allow_empty: bool = False) -> bool:
    """Return true when *value* is a repository-relative path under bench policy."""
    return unsafe_repo_path_reason(value, allow_empty=allow_empty) == ""


def canonical(source: Any) -> str:
    """Return the canonical timing-source identifier.

    Strips any ``+``-suffixed qualifier (e.g. ``"gpu+cpu"`` -> ``"gpu"``).
    Returns an empty string for falsy or non-string inputs; accepts ``Any``
    so callers loading raw JSON values can route directly through this
    helper without a separate type-guard pass.
    """
    if not isinstance(source, str) or not source:
        return ""
    return source.split("+", 1)[0]


def canonical_source(source: Any) -> str:
    """Alias for :func:`canonical` kept for callers that use the longer name."""
    return canonical(source)


def detect_repo_root(explicit_root: str) -> Path:
    """Resolve the Fawn repository root directory.

    When *explicit_root* is non-empty it is validated and returned.
    Otherwise the current working directory (and a ``fawn/`` child) are
    probed for the expected directory markers (``config/`` and ``bench/``).

    Raises ``ValueError`` when auto-detection fails.
    """
    if explicit_root:
        root = Path(explicit_root)
        if not root.exists():
            raise ValueError(f"invalid --root path: {root}")
        return root.resolve()

    cwd = Path.cwd()
    direct_root = cwd
    nested_root = cwd / "fawn"

    if (direct_root / "config").is_dir() and (direct_root / "bench").is_dir():
        return direct_root.resolve()
    if (nested_root / "config").is_dir() and (nested_root / "bench").is_dir():
        return nested_root.resolve()

    raise ValueError(
        "unable to auto-detect repository root; pass --root with a path "
        "containing config/ and bench/"
    )
