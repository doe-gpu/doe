#!/usr/bin/env python3
"""Organize benchmark artifacts under grouped bench/out/<group>/<timestamp>/ folders."""

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

from bench.lib import output_paths


TIMESTAMP_RE = re.compile(r"\d{8}T\d{6}Z")
EXACT_TIMESTAMP_RE = re.compile(r"^\d{8}T\d{6}Z$")


@dataclass(frozen=True)
class MovePlan:
    source: Path
    target: Path
    timestamp: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--out-dir",
        default="bench/out",
        help="Benchmark artifact directory.",
    )
    parser.add_argument(
        "--keep-filename-timestamp",
        action=argparse.BooleanOptionalAction,
        default=False,
        help="Keep timestamp token in file/dir names inside timestamp folders.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned moves without changing files.",
    )
    return parser.parse_args()


def extract_timestamp(name: str) -> str | None:
    match = TIMESTAMP_RE.search(name)
    if not match:
        return None
    return match.group(0)


def strip_timestamp_from_name(name: str, timestamp: str) -> str:
    for token in (f".{timestamp}", f"_{timestamp}", f"-{timestamp}", timestamp):
        idx = name.find(token)
        if idx != -1:
            updated = name[:idx] + name[idx + len(token) :]
            while ".." in updated:
                updated = updated.replace("..", ".")
            while "__" in updated:
                updated = updated.replace("__", "_")
            while "--" in updated:
                updated = updated.replace("--", "-")
            updated = updated.replace("._", ".").replace("_.", ".")
            updated = updated.strip("._-")
            return updated or name
    return name


def plan_moves(out_dir: Path, *, keep_filename_timestamp: bool) -> tuple[list[MovePlan], list[str]]:
    moves: list[MovePlan] = []
    skipped: list[str] = []

    for entry in sorted(out_dir.iterdir(), key=lambda item: item.name):
        if EXACT_TIMESTAMP_RE.fullmatch(entry.name):
            continue
        timestamp = extract_timestamp(entry.name)
        if timestamp is None:
            continue

        target_name = entry.name
        if not keep_filename_timestamp:
            target_name = strip_timestamp_from_name(entry.name, timestamp)
        target_path = output_paths.with_timestamp(out_dir / target_name, timestamp, enabled=True)

        if target_path.exists():
            skipped.append(f"conflict: {entry} -> {target_path}")
            continue

        moves.append(MovePlan(source=entry, target=target_path, timestamp=timestamp))

    return moves, skipped


def apply_moves(plans: list[MovePlan]) -> None:
    for plan in plans:
        plan.target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(plan.source), str(plan.target))


def main() -> int:
    args = parse_args()
    out_dir = Path(args.out_dir)
    if not out_dir.exists():
        print(f"FAIL: out directory does not exist: {out_dir}")
        return 1
    if not out_dir.is_dir():
        print(f"FAIL: out path is not a directory: {out_dir}")
        return 1

    plans, skipped = plan_moves(
        out_dir,
        keep_filename_timestamp=args.keep_filename_timestamp,
    )

    print(f"planned moves: {len(plans)}")
    for item in plans:
        print(f"{item.source} -> {item.target}")
    if skipped:
        print(f"skipped: {len(skipped)}")
        for reason in skipped:
            print(reason)

    if args.dry_run or not plans:
        return 0

    apply_moves(plans)
    print(f"moved: {len(plans)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
