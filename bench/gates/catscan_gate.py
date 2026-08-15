#!/usr/bin/env python3
"""Validate recursive CATSCAN component charters and their generated index."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import re
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_INDEX = Path("docs/component-index.md")
MAX_WORDS = 250
REQUIRED_SECTIONS = (
    "Target",
    "Authority",
    "Scope",
    "Contracts",
    "Invariants",
    "Acceptance",
    "Non-goals",
    "Freedom",
)
EXCLUDED_PARTS = {
    ".cache",
    ".git",
    ".pytest_cache",
    ".tooling",
    "node_modules",
}
EXTERNAL_SCHEMES = ("http://", "https://", "mailto:", "ftp://")
TITLE_RE = re.compile(r"^# CATSCAN: (.+)$", re.MULTILINE)
PARENT_LINE_RE = re.compile(r"^Parent: (.+)$", re.MULTILINE)
PARENT_LINK_RE = re.compile(r"^\[[^\]]+\]\(([^)]+CATSCAN\.md)\)$")
SECTION_RE = re.compile(r"^## (.+)$", re.MULTILINE)
LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
WORD_RE = re.compile(r"\b[\w'-]+\b")


@dataclass(frozen=True)
class Charter:
    path: Path
    relative_path: str
    component: str
    parent_target: str | None
    target: str
    sections: dict[str, str]
    word_count: int


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def _is_excluded(path: Path, root: Path) -> bool:
    relative = path.relative_to(root)
    if any(part in EXCLUDED_PARTS for part in relative.parts):
        return True
    if relative.parts and relative.parts[0] == "bench" and "out" in relative.parts[1:2]:
        return True
    return any(part.startswith("wio_flows_tmpdir.") for part in relative.parts)


def discover_charter_paths(root: Path) -> list[Path]:
    return [
        path
        for path in sorted(root.rglob("CATSCAN.md"))
        if not _is_excluded(path, root)
    ]


def _section_bodies(text: str) -> tuple[dict[str, str], list[str]]:
    matches = list(SECTION_RE.finditer(text))
    bodies: dict[str, str] = {}
    duplicates: list[str] = []
    for index, match in enumerate(matches):
        name = match.group(1).strip()
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        if name in bodies:
            duplicates.append(name)
        else:
            bodies[name] = text[start:end].strip()
    return bodies, duplicates


def parse_charter(path: Path, root: Path) -> tuple[Charter | None, list[dict[str, str]]]:
    relative_path = path.relative_to(root).as_posix()
    failures: list[dict[str, str]] = []
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return None, [failure("unreadable_charter", relative_path, str(exc))]

    title_matches = TITLE_RE.findall(text)
    if len(title_matches) != 1:
        failures.append(
            failure(
                "invalid_component_title",
                relative_path,
                "expected exactly one '# CATSCAN: <Component>' title",
            )
        )
    parent_lines = PARENT_LINE_RE.findall(text)
    parent_target: str | None = None
    valid_parent = False
    if len(parent_lines) == 1:
        parent_value = parent_lines[0].strip()
        if parent_value == "none":
            valid_parent = True
        else:
            parent_match = PARENT_LINK_RE.fullmatch(parent_value)
            if parent_match is not None:
                parent_target = parent_match.group(1)
                valid_parent = True
    if not valid_parent:
        failures.append(
            failure(
                "invalid_parent_field",
                relative_path,
                "expected exactly one Parent field with 'none' or a CATSCAN.md link",
            )
        )

    sections, duplicate_sections = _section_bodies(text)
    for name in duplicate_sections:
        failures.append(
            failure("duplicate_section", relative_path, f"duplicate section: {name}")
        )
    for name in REQUIRED_SECTIONS:
        if not sections.get(name, "").strip():
            failures.append(
                failure(
                    "missing_required_section",
                    relative_path,
                    f"missing or empty required section: {name}",
                )
            )

    word_count = len(WORD_RE.findall(text))
    if word_count > MAX_WORDS:
        failures.append(
            failure(
                "charter_too_large",
                relative_path,
                f"charter has {word_count} words; maximum is {MAX_WORDS}",
            )
        )

    acceptance = sections.get("Acceptance", "")
    if not re.search(r"^- Evidence:\s+.*\[[^\]]+\]\([^)]+\)", acceptance, re.MULTILINE):
        failures.append(
            failure(
                "missing_acceptance_evidence",
                relative_path,
                "Acceptance must contain an '- Evidence:' Markdown link",
            )
        )

    if failures and not title_matches:
        return None, failures

    component = title_matches[0].strip() if title_matches else ""
    target = " ".join(sections.get("Target", "").split())
    return (
        Charter(
            path=path,
            relative_path=relative_path,
            component=component,
            parent_target=parent_target,
            target=target,
            sections=sections,
            word_count=word_count,
        ),
        failures,
    )


def _resolve_local_link(charter: Charter, raw_target: str, root: Path) -> Path | None:
    if raw_target.startswith(EXTERNAL_SCHEMES) or raw_target.startswith("#"):
        return None
    target = raw_target.split("#", 1)[0]
    if not target:
        return None
    if target.startswith("/") or "\\" in target:
        raise ValueError("link must be repository-relative and use forward slashes")
    resolved = (charter.path.parent / target).resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise ValueError("link escapes the Doe repository") from exc
    return resolved


def _expected_parent(path: Path, root: Path, charter_paths: set[Path]) -> Path | None:
    if path == root / "CATSCAN.md":
        return None
    cursor = path.parent.parent
    while cursor == root or root in cursor.parents:
        candidate = cursor / "CATSCAN.md"
        if candidate in charter_paths:
            return candidate
        if cursor == root:
            break
        cursor = cursor.parent
    return root / "CATSCAN.md"


def _escape_table(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def render_component_index(charters: list[Charter], root: Path) -> str:
    by_path = {charter.path.resolve(): charter for charter in charters}
    lines = [
        "# Doe component index",
        "",
        "Generated by `python3 bench/gates/catscan_gate.py --write-index`.",
        "Do not edit this file by hand.",
        "",
        "| Component | Directory | Parent | Target |",
        "| --- | --- | --- | --- |",
    ]
    for charter in sorted(charters, key=lambda item: item.relative_path):
        directory = charter.path.parent.relative_to(root).as_posix()
        directory = "." if directory == "." else directory
        charter_link = Path("..").joinpath(charter.relative_path).as_posix()
        component = f"[{charter.component}]({charter_link})"
        if charter.parent_target is None:
            parent = "None"
        else:
            parent_path = (charter.path.parent / charter.parent_target).resolve()
            parent_charter = by_path.get(parent_path)
            parent = parent_charter.component if parent_charter else "INVALID"
        lines.append(
            "| "
            + " | ".join(
                (
                    _escape_table(component),
                    f"`{directory}`",
                    _escape_table(parent),
                    _escape_table(charter.target),
                )
            )
            + " |"
        )
    lines.append("")
    return "\n".join(lines)


def evaluate_repository(root: Path, index_path: Path) -> dict[str, Any]:
    root = root.resolve()
    absolute_index = index_path if index_path.is_absolute() else root / index_path
    charter_paths = discover_charter_paths(root)
    failures: list[dict[str, str]] = []
    charters: list[Charter] = []

    if root / "CATSCAN.md" not in charter_paths:
        failures.append(
            failure("missing_root_charter", "CATSCAN.md", "root CATSCAN.md is required")
        )

    for path in charter_paths:
        charter, parse_failures = parse_charter(path, root)
        failures.extend(parse_failures)
        if charter is not None:
            charters.append(charter)

    component_paths: dict[str, str] = {}
    path_set = {path.resolve() for path in charter_paths}
    for charter in charters:
        component_key = charter.component.casefold()
        if component_key in component_paths:
            failures.append(
                failure(
                    "duplicate_component_identifier",
                    charter.relative_path,
                    f"component duplicates {component_paths[component_key]}: {charter.component}",
                )
            )
        else:
            component_paths[component_key] = charter.relative_path

        expected_parent = _expected_parent(charter.path, root, path_set)
        if charter.parent_target is None:
            actual_parent = None
        else:
            actual_parent = (charter.path.parent / charter.parent_target).resolve()
        if actual_parent != expected_parent:
            expected = (
                "None"
                if expected_parent is None
                else expected_parent.relative_to(root).as_posix()
            )
            actual = (
                "None"
                if actual_parent is None
                else actual_parent.relative_to(root).as_posix()
                if root == actual_parent or root in actual_parent.parents
                else str(actual_parent)
            )
            failures.append(
                failure(
                    "incorrect_parent_charter",
                    charter.relative_path,
                    f"expected parent {expected}, found {actual}",
                )
            )

        text = charter.path.read_text(encoding="utf-8")
        for raw_target in LINK_RE.findall(text):
            try:
                resolved = _resolve_local_link(charter, raw_target, root)
            except ValueError as exc:
                failures.append(
                    failure("invalid_charter_link", charter.relative_path, f"{raw_target}: {exc}")
                )
                continue
            if resolved is not None and not resolved.exists():
                failures.append(
                    failure(
                        "missing_charter_link_target",
                        charter.relative_path,
                        f"link target does not exist: {raw_target}",
                    )
                )

    generated = render_component_index(charters, root)
    index_relative = (
        absolute_index.relative_to(root).as_posix()
        if root == absolute_index or root in absolute_index.parents
        else str(absolute_index)
    )
    if not absolute_index.is_file():
        failures.append(
            failure("missing_component_index", index_relative, "generated index is missing")
        )
    else:
        current = absolute_index.read_text(encoding="utf-8")
        if current != generated:
            failures.append(
                failure(
                    "stale_component_index",
                    index_relative,
                    "run python3 bench/gates/catscan_gate.py --write-index",
                )
            )

    return {
        "ok": not failures,
        "failures": failures,
        "summary": {
            "charterCount": len(charters),
            "maxWords": max((charter.word_count for charter in charters), default=0),
            "indexPath": index_relative,
        },
    }


def write_component_index(root: Path, index_path: Path) -> Path:
    root = root.resolve()
    absolute_index = index_path if index_path.is_absolute() else root / index_path
    charters: list[Charter] = []
    parse_failures: list[dict[str, str]] = []
    for path in discover_charter_paths(root):
        charter, failures = parse_charter(path, root)
        parse_failures.extend(failures)
        if charter is not None:
            charters.append(charter)
    if parse_failures:
        messages = "; ".join(
            f"{item['path']}:{item['code']}" for item in parse_failures
        )
        raise ValueError(f"cannot generate index from invalid charters: {messages}")
    absolute_index.parent.mkdir(parents=True, exist_ok=True)
    absolute_index.write_text(render_component_index(charters, root), encoding="utf-8")
    return absolute_index


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=str(REPO_ROOT))
    parser.add_argument("--index", default=str(DEFAULT_INDEX))
    parser.add_argument("--write-index", action="store_true")
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    index_path = Path(args.index)
    if args.write_index:
        try:
            written = write_component_index(root, index_path)
        except (OSError, UnicodeError, ValueError) as exc:
            print(f"CATSCAN FAIL: {exc}")
            return 1
        print(f"CATSCAN index written: {written.relative_to(root)}")

    result = evaluate_repository(root, index_path)
    if args.emit_json:
        print(json.dumps(result, indent=2, sort_keys=True))
    elif result["ok"]:
        print(
            "CATSCAN PASS: "
            f"{result['summary']['charterCount']} charters; "
            f"index={result['summary']['indexPath']}"
        )
    else:
        for item in result["failures"]:
            print(
                f"CATSCAN FAIL [{item['code']}] "
                f"{item['path']}: {item['message']}"
            )
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
