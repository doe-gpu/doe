#!/usr/bin/env python3
"""Reject tracked files that expose developer home-directory paths."""

from __future__ import annotations

import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


PRIVATE_HOME_PATTERNS = (
    (
        "macOS user home",
        re.compile(
            r"/Users/(?!(?:<user>|runner|Shared)(?=/|[\s\"'`,:}\]]|$))"
            r"[^/\s\"'`]+"
        ),
    ),
    (
        "Linux user home",
        re.compile(
            r"/home/(?!(?:user|runner|x|web_user|chrome)"
            r"(?=/|[\s\"'`,:}\]]|$))[^/\s\"'`]+"
        ),
    ),
    (
        "Windows user home",
        re.compile(
            r"[A-Za-z]:\\Users\\"
            r"(?!<user>(?:\\|$)|runner(?:\\|$)|Public(?:\\|$))"
            r"[^\\\s\"'`]+"
        ),
    ),
)

PUBLIC_CORPUS_PREFIXES = ("dawn-research/data/",)


@dataclass(frozen=True)
class Finding:
    path: Path
    line: int
    label: str


def list_tracked_files() -> list[Path]:
    """Return every path tracked by the current Git worktree."""

    result = subprocess.run(
        ["git", "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
    )
    paths = [Path(raw.decode("utf-8")) for raw in result.stdout.split(b"\0") if raw]
    return [
        path
        for path in paths
        if not any(path.as_posix().startswith(prefix) for prefix in PUBLIC_CORPUS_PREFIXES)
    ]


def scan_file(path: Path) -> list[Finding]:
    """Return private-home findings for one tracked text file."""

    if not path.is_file():
        return []
    payload = path.read_bytes()
    if b"\0" in payload:
        return []

    findings: list[Finding] = []
    text = payload.decode("utf-8", errors="ignore")
    for line_number, line in enumerate(text.splitlines(), 1):
        for label, pattern in PRIVATE_HOME_PATTERNS:
            if pattern.search(line):
                findings.append(Finding(path=path, line=line_number, label=label))
    return findings


def main() -> int:
    files = list_tracked_files()
    findings = [finding for path in files for finding in scan_file(path)]
    if findings:
        for finding in findings:
            print(f"{finding.path}:{finding.line}: {finding.label}")
        print(f"publication hygiene failed: {len(findings)} private path(s)")
        return 1

    print(f"publication hygiene passed: {len(files)} tracked files scanned")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
