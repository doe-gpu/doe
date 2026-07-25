"""Fail-closed checks for Python package import boundaries."""

from __future__ import annotations

import ast
import json
from pathlib import Path
from typing import Any


def _is_sys_path(node: ast.AST) -> bool:
    return (
        isinstance(node, ast.Attribute)
        and isinstance(node.value, ast.Name)
        and node.value.id == "sys"
        and node.attr == "path"
    )


def _mutation_lines(source: str, path: Path) -> list[int]:
    try:
        tree = ast.parse(source, filename=str(path))
    except SyntaxError as exc:
        raise ValueError(f"{path}: cannot inspect invalid Python: {exc}") from exc

    lines: list[int] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            if _is_sys_path(node.func.value) and node.func.attr in {
                "append",
                "extend",
                "insert",
                "remove",
            }:
                lines.append(node.lineno)
        if isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
            targets: list[ast.AST]
            if isinstance(node, ast.Assign):
                targets = list(node.targets)
            else:
                targets = [node.target]
            for target in targets:
                if _is_sys_path(target):
                    lines.append(node.lineno)
                if isinstance(target, ast.Subscript) and _is_sys_path(target.value):
                    lines.append(node.lineno)
    return sorted(set(lines))


def _load_policy(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if payload.get("schemaVersion") != 1:
        raise ValueError(f"{path}: schemaVersion must be 1")
    return payload


def validate_python_import_boundaries(
    root: Path,
    policy_path: Path | None = None,
) -> list[str]:
    root = root.resolve()
    policy_file = policy_path or root / "config" / "python-import-boundaries.json"
    policy = _load_policy(policy_file)
    failures: list[str] = []

    for configured_path in policy["protectedPaths"]:
        target = root / configured_path
        candidates = [target] if target.is_file() else sorted(target.rglob("*.py"))
        if not target.exists():
            failures.append(f"protected Python path does not exist: {configured_path}")
            continue
        for candidate in candidates:
            lines = _mutation_lines(candidate.read_text(encoding="utf-8"), candidate)
            relative = candidate.relative_to(root).as_posix()
            for line in lines:
                failures.append(f"{relative}:{line}: sys.path mutation is forbidden")

    protected = [root / value for value in policy["protectedPaths"]]
    legacy = [root / value for value in policy["legacyDirectScriptRoots"]]
    overlap = sorted(
        left.relative_to(root).as_posix()
        for left in protected
        if any(left == right or right in left.parents for right in legacy)
    )
    for value in overlap:
        failures.append(f"protected Python path is nested under a legacy root: {value}")
    return failures
