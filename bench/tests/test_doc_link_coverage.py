"""Lock markdown-link integrity across Doe docs.

Tick 19 found a load-bearing file (`docs/loop-protocol.md`) missing from
disk while `docs/status.md`, `docs/tsir-lowering-plan.md`, and every
recent status-shard entry linked to it. Nobody caught it for a long
time because there was no test for the class.

This test walks `docs/**/*.md` (excluding `docs/status/archive/`),
extracts every markdown link that resolves to a local relative path
inside the doe repo, and asserts the target exists on disk. External
URLs, cross-repo paths (e.g. `../../doppler/...`), and same-doc
anchors (`#section`) are skipped — those are valid references that
this test is not in a position to check.

Run: `python3 -m unittest bench.tests.test_doc_link_coverage`.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DOCS_ROOT = REPO_ROOT / "docs"
ARCHIVE_PREFIX = DOCS_ROOT / "status" / "archive"

# Matches Markdown inline links `[text](target)` and image links
# `![alt](target)`. Captures only the target. Handles nested brackets
# in link text via `[^\]]*`.
LINK_PATTERN = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")

# URL schemes we do not try to verify — purely external.
EXTERNAL_SCHEMES = ("http://", "https://", "mailto:", "ftp://", "file://")


def _iter_doc_files() -> list[Path]:
    paths: list[Path] = []
    for path in sorted(DOCS_ROOT.rglob("*.md")):
        # Archive entries are historical snapshots; links in them can
        # reference files that existed at the time and no longer do.
        if ARCHIVE_PREFIX in path.parents or path == ARCHIVE_PREFIX:
            continue
        paths.append(path)
    # Root-level markdown files carry load-bearing links too
    # (AGENTS.md lists style guides, CLAUDE.md lists mandatory-reading
    # docs, etc). Include any that exist; do not require all.
    for name in ("AGENTS.md", "README.md", "CLAUDE.md", "SKILLS.md"):
        candidate = REPO_ROOT / name
        if candidate.is_file():
            paths.append(candidate)
    return paths


def _resolve_link(doc_path: Path, raw_target: str) -> Path | None:
    """Return an absolute Path for a markdown link target, or None if
    the link is not a local path we should verify."""
    # Strip anchor fragment — we only care the file exists, not the
    # anchor. `target.md#section` → `target.md`. Bare `#anchor` means
    # same-file anchor; skip.
    fragment_pos = raw_target.find("#")
    if fragment_pos == 0:
        return None
    if fragment_pos > 0:
        raw_target = raw_target[:fragment_pos]

    if not raw_target:
        return None
    if raw_target.startswith(EXTERNAL_SCHEMES):
        return None
    if raw_target.startswith("/"):
        # Absolute paths (e.g. `/opt/project/...`) are unresolvable in a
        # portable test — treat as out of scope.
        return None

    try:
        resolved = (doc_path.parent / raw_target).resolve()
    except (OSError, ValueError):
        return None

    # Only check paths that stay inside the Doe repo. Cross-repo
    # paths that ascend out of the repo root resolve outside it and
    # are skipped — their existence is checked by those repos.
    try:
        resolved.relative_to(REPO_ROOT)
    except ValueError:
        return None

    return resolved


class DocLinkCoverage(unittest.TestCase):
    def test_markdown_links_in_docs_resolve_to_existing_paths(self) -> None:
        broken: list[tuple[str, str, str]] = []
        checked_docs = 0
        checked_links = 0
        for doc_path in _iter_doc_files():
            checked_docs += 1
            text = doc_path.read_text(encoding="utf-8")
            for match in LINK_PATTERN.finditer(text):
                raw_target = match.group(1)
                resolved = _resolve_link(doc_path, raw_target)
                if resolved is None:
                    continue
                checked_links += 1
                if not resolved.exists():
                    rel_doc = doc_path.relative_to(REPO_ROOT).as_posix()
                    rel_target = resolved.relative_to(REPO_ROOT).as_posix()
                    broken.append((rel_doc, raw_target, rel_target))

        # Floor checks catch a scan that silently found nothing.
        self.assertGreater(checked_docs, 0, "no docs scanned")
        self.assertGreater(checked_links, 0, "no in-repo links found")

        if broken:
            lines = [
                f"  {doc}: `{raw}` → {resolved}"
                for doc, raw, resolved in broken
            ]
            self.fail(
                "markdown links to missing in-repo paths "
                f"({len(broken)} broken):\n" + "\n".join(lines)
            )


if __name__ == "__main__":
    unittest.main()
