#!/usr/bin/env python3
"""Enforce Doe's blocking source-size rules and report sharding advisories.

Zig policy comes from runtime/zig/source-layout.json. Python benchmark and
tooling files above the review threshold are advisory and require tracked
sharding follow-ups rather than blocking release by size alone.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import sys
from dataclasses import dataclass
from pathlib import Path


PYTHON_LINE_LIMIT = 1200

# Directories containing third-party code that are not subject to project limits.
IGNORED_DIRS = (".venv", "__pycache__", "node_modules", "out", "vendor")

@dataclass(frozen=True)
class Violation:
    path: str
    line_count: int
    limit: int
    language: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default="",
        help="Repository root. Auto-detected when omitted.",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="json_output",
        help="Emit machine-readable JSON output.",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        default=[],
        help="Relative path (from repo root) to exclude from checks. May be repeated.",
    )
    return parser.parse_args()


def detect_repo_root(explicit_root: str) -> Path:
    if explicit_root:
        root = Path(explicit_root)
        if not root.exists():
            raise ValueError(f"invalid --root path: {root}")
        return root.resolve()

    cwd = Path.cwd()
    if (cwd / "runtime" / "zig" / "src").is_dir() and (cwd / "bench").is_dir():
        return cwd.resolve()
    nested = cwd / "fawn"
    if (nested / "runtime" / "zig" / "src").is_dir() and (nested / "bench").is_dir():
        return nested.resolve()

    raise ValueError(
        "unable to auto-detect repository root; pass --root with a path "
        "containing runtime/zig/src/ and bench/"
    )


def count_lines(path: Path) -> int:
    return len(path.read_text(encoding="utf-8", errors="replace").splitlines())


def _is_ignored_tree(path: Path, scan_root: Path) -> bool:
    """Return True when the file lives under generated or third-party output."""
    try:
        parts = path.relative_to(scan_root).parts
    except ValueError:
        return False
    return any(part in IGNORED_DIRS for part in parts)


def scan_directory(
    root: Path,
    rel_dir: str,
    extension: str,
    limit: int,
    language: str,
    excludes: set[str],
) -> list[Violation]:
    violations: list[Violation] = []
    scan_root = root / rel_dir
    if not scan_root.is_dir():
        return violations
    for path in sorted(scan_root.rglob(f"*{extension}")):
        if not path.is_file():
            continue
        if _is_ignored_tree(path, scan_root):
            continue
        rel = str(path.relative_to(root))
        if rel in excludes:
            continue
        lines = count_lines(path)
        if lines > limit:
            violations.append(
                Violation(
                    path=rel,
                    line_count=lines,
                    limit=limit,
                    language=language,
                )
            )
    return violations


def scan_zig_sources(root: Path, excludes: set[str]) -> list[Violation]:
    """Apply the canonical source-layout line policy to production Zig."""

    runtime_root = root / "runtime" / "zig"
    config = json.loads((runtime_root / "source-layout.json").read_text(encoding="utf-8"))
    architecture = config["architecture"]
    policy = architecture["linePolicy"]
    generated_globs = architecture["specialRoles"]["generated"]
    justifications = {
        entry["path"] for entry in architecture["cohesiveModuleJustifications"]
    }
    hard_limit = policy["futureHardMaximumLines"]
    justification_limit = policy["futureJustificationAboveLines"]
    violations: list[Violation] = []
    for path in sorted((runtime_root / "src").rglob("*.zig")):
        manifest_path = path.relative_to(runtime_root).as_posix()
        repo_path = path.relative_to(root).as_posix()
        if repo_path in excludes:
            continue
        if any(fnmatch.fnmatchcase(manifest_path, pattern) for pattern in generated_globs):
            continue
        line_count = count_lines(path)
        limit = hard_limit
        if line_count > hard_limit:
            pass
        elif line_count > justification_limit and manifest_path not in justifications:
            limit = justification_limit
        else:
            continue
        violations.append(
            Violation(
                path=repo_path,
                line_count=line_count,
                limit=limit,
                language="zig",
            )
        )
    return violations


def main() -> int:
    args = parse_args()
    try:
        root = detect_repo_root(args.root)
    except ValueError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    excludes = set(args.exclude)
    try:
        violations = scan_zig_sources(root, excludes)
    except (FileNotFoundError, KeyError, OSError, TypeError, ValueError) as exc:
        print(f"FAIL: invalid Zig source-layout policy: {exc}", file=sys.stderr)
        return 1
    advisories: list[Violation] = []
    advisories.extend(
        scan_directory(root, "bench", ".py", PYTHON_LINE_LIMIT, "python", excludes)
    )
    advisories.extend(
        scan_directory(
            root,
            "pipeline/agent",
            ".py",
            PYTHON_LINE_LIMIT,
            "python",
            excludes,
        )
    )

    if args.json_output:
        payload = {
            "gate": "file-size",
            "status": "fail" if violations else "pass",
            "violations": [
                {
                    "filePath": v.path,
                    "lineCount": v.line_count,
                    "limit": v.limit,
                    "language": v.language,
                }
                for v in violations
            ],
            "advisories": [
                {
                    "filePath": item.path,
                    "lineCount": item.line_count,
                    "reviewThreshold": item.limit,
                    "language": item.language,
                }
                for item in advisories
            ],
            "checkedLimits": {
                "zig": {
                    "directory": "runtime/zig/src",
                    "policy": "runtime/zig/source-layout.json",
                },
                "python": {
                    "directories": ["bench", "pipeline/agent"],
                    "advisoryReviewLines": PYTHON_LINE_LIMIT,
                },
            },
        }
        json.dump(payload, sys.stdout, indent=2)
        sys.stdout.write("\n")
        return 1 if violations else 0

    if violations:
        print("FAIL: file-size gate")
        for v in violations:
            print(
                f"  {v.path}: {v.line_count} lines "
                f"(limit {v.limit} for {v.language})"
            )
        return 1

    print("PASS: file-size gate")
    for item in advisories:
        print(
            f"  advisory: {item.path}: {item.line_count} lines "
            f"(review threshold {item.limit} for {item.language})"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
