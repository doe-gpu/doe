#!/usr/bin/env python3
"""List benchmark output run folders with manifest-derived summary."""

from __future__ import annotations

import sys
from pathlib import Path

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)

import argparse
import json
from typing import Any

from bench.lib import output_paths


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--out-dir",
        default="bench/out",
        help="Benchmark output directory.",
    )
    parser.add_argument(
        "--include-scratch",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Include bench/out/scratch/<timestamp> folders.",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Maximum rows to print (0 = all).",
    )
    return parser.parse_args()


def collect_folders(out_dir: Path, *, include_scratch: bool) -> list[Path]:
    return output_paths.collect_timestamp_folders(out_dir, include_scratch=include_scratch)


def read_manifest(path: Path) -> dict[str, Any]:
    manifest_path = path / "run_manifest.json"
    if not manifest_path.exists():
        return {}
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def summarize_files(path: Path) -> str:
    names = sorted(item.name for item in path.iterdir())
    compare_reports = [name for name in names if name.startswith("dawn-vs-doe") and name.endswith(".json")]
    compare_html = [name for name in names if name.startswith("dawn-vs-doe") and name.endswith(".html")]
    release_windows = [name for name in names if name.startswith("release-claim-windows") and name.endswith(".json")]
    dropin_reports = [name for name in names if name.startswith("dropin_report") and name.endswith(".json")]

    if compare_reports:
        return f"compare:{len(compare_reports)} html:{len(compare_html)}"
    if release_windows:
        return f"release-windows:{len(release_windows)}"
    if dropin_reports:
        return f"dropin:{len(dropin_reports)}"
    return f"files:{len(names)}"


def group_label(out_dir: Path, folder: Path) -> str:
    try:
        relative = folder.parent.relative_to(out_dir)
    except ValueError:
        return "<external>"
    if relative == Path("."):
        return "<root>"
    return relative.as_posix()


def main() -> int:
    args = parse_args()
    out_dir = Path(args.out_dir)
    if not out_dir.exists() or not out_dir.is_dir():
        print(f"FAIL: invalid --out-dir: {out_dir}")
        return 1

    rows: list[str] = []
    folders = collect_folders(out_dir, include_scratch=args.include_scratch)
    for folder in folders:
        manifest = read_manifest(folder)
        run_type = str(manifest.get("runType", "unknown"))
        status = str(manifest.get("status", "unknown"))
        scope = "scratch" if "scratch" in folder.parts else "canonical"
        group = group_label(out_dir, folder)
        row = (
            f"{folder.name}  "
            f"{scope:9}  "
            f"{group:28}  "
            f"{run_type:24}  "
            f"{status:18}  "
            f"{summarize_files(folder)}"
        )
        rows.append(row)

    if args.limit > 0:
        rows = rows[-args.limit :]

    if not rows:
        print("no timestamp folders found")
        return 0

    print("timestamp          scope      group                         run_type                  status              summary")
    for row in rows:
        print(row)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
