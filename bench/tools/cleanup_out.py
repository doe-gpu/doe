#!/usr/bin/env python3
"""Prune legacy benchmark artifacts from bench/out."""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)

import argparse
import re
import shutil
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from bench.lib import output_paths


TIMESTAMP_CAPTURE_RE = re.compile(r"(\d{8}T\d{6}Z)")
DEFAULT_RETENTION_DAYS = 0


@dataclass(frozen=True)
class Candidate:
    path: Path
    reason: str
    size_bytes: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--out-dir",
        default="bench/out",
        help="Benchmark artifact directory to prune.",
    )
    parser.add_argument(
        "--remove-untimestamped",
        dest="remove_untimestamped",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Remove entries without a YYYYMMDDTHHMMSSZ token.",
    )
    parser.add_argument(
        "--retention-days",
        type=int,
        default=DEFAULT_RETENTION_DAYS,
        help=(
            "If > 0, also remove timestamped entries older than this many days. "
            "Default keeps all timestamped entries."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report removals without deleting files.",
    )
    return parser.parse_args()


def path_size_bytes(path: Path) -> int:
    if not path.exists():
        return 0
    if path.is_file() or path.is_symlink():
        return path.stat().st_size
    total = 0
    for child in path.rglob("*"):
        if child.is_file():
            total += child.stat().st_size
    return total


def parse_embedded_timestamp(name: str) -> datetime | None:
    match = TIMESTAMP_CAPTURE_RE.search(name)
    if not match:
        return None
    return datetime.strptime(match.group(1), output_paths.TIMESTAMP_FORMAT).replace(
        tzinfo=timezone.utc
    )


def classify(
    path: Path,
    *,
    remove_untimestamped: bool,
    cutoff: datetime | None,
) -> Candidate | None:
    timestamp = parse_embedded_timestamp(path.name)
    if timestamp is None:
        if not remove_untimestamped:
            return None
        return Candidate(
            path=path,
            reason="legacy-untimestamped",
            size_bytes=path_size_bytes(path),
        )

    if cutoff is not None and timestamp < cutoff:
        return Candidate(
            path=path,
            reason="expired-timestamped",
            size_bytes=path_size_bytes(path),
        )
    return None


def remove_path(path: Path) -> None:
    if path.is_file() or path.is_symlink():
        path.unlink()
        return
    shutil.rmtree(path)


def human_size(size_bytes: int) -> str:
    size = float(size_bytes)
    units = ["B", "KB", "MB", "GB", "TB"]
    for unit in units:
        if size < 1024.0 or unit == units[-1]:
            return f"{size:.1f}{unit}"
        size /= 1024.0
    return f"{size_bytes}B"


def main() -> int:
    args = parse_args()
    out_dir = Path(args.out_dir)
    if not out_dir.exists():
        raise SystemExit(f"out directory does not exist: {out_dir}")
    if args.retention_days < 0:
        raise SystemExit("--retention-days must be >= 0")

    cutoff = None
    if args.retention_days > 0:
        cutoff = datetime.now(timezone.utc) - timedelta(days=args.retention_days)

    candidates: list[Candidate] = []
    seen_paths: set[Path] = set()

    for folder in output_paths.collect_timestamp_folders(out_dir, include_scratch=True):
        if folder in seen_paths:
            continue
        seen_paths.add(folder)
        candidate = classify(
            folder,
            remove_untimestamped=False,
            cutoff=cutoff,
        )
        if candidate is not None:
            candidates.append(candidate)

    for entry in sorted(out_dir.iterdir(), key=lambda item: item.name):
        if entry in seen_paths:
            continue
        if entry.name == "scratch":
            continue
        if entry.is_dir():
            child_timestamps = output_paths.collect_timestamp_folders(entry, include_scratch=True)
            if child_timestamps:
                continue
        candidate = classify(
            entry,
            remove_untimestamped=args.remove_untimestamped,
            cutoff=None,
        )
        if candidate is not None:
            candidates.append(candidate)

    total_bytes = sum(item.size_bytes for item in candidates)
    print(
        f"cleanup candidates: {len(candidates)} "
        f"(~{human_size(total_bytes)})"
    )
    for item in candidates:
        print(f"{item.reason}\t{item.path}")

    if args.dry_run or not candidates:
        return 0

    for item in candidates:
        remove_path(item.path)

    print(f"removed: {len(candidates)} entries (~{human_size(total_bytes)})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
