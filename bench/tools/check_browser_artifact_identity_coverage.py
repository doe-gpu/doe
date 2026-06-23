#!/usr/bin/env python3
"""Validate browser artifacts carry their declared identity anchors."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any


try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)
from bench.lib.bench_utils import load_json_object as load_json


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--coverage",
        default="config/browser-artifact-identity-coverage.json",
        help="Browser artifact identity coverage manifest.",
    )
    parser.add_argument(
        "--root",
        default=str(REPO_ROOT),
        help="Repository root used to resolve artifact paths.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def safe_repo_path(path_text: str) -> bool:
    path = PurePosixPath(path_text)
    return bool(path_text) and not path.is_absolute() and ".." not in path.parts


def resolve_repo_path(root: Path, path_text: str) -> Path:
    return root.joinpath(*PurePosixPath(path_text).parts)


def pointer_parts(pointer: str) -> list[str]:
    return [part.replace("~1", "/").replace("~0", "~") for part in pointer.split("/")[1:]]


def pointer_value(payload: Any, pointer: str) -> tuple[bool, Any]:
    value = payload
    for part in pointer_parts(pointer):
        if isinstance(value, dict):
            if part not in value:
                return False, None
            value = value[part]
            continue
        if isinstance(value, list):
            if not part.isdigit():
                return False, None
            index = int(part)
            if index >= len(value):
                return False, None
            value = value[index]
            continue
        return False, None
    return True, value


def has_identity_value(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, str):
        return bool(value)
    if isinstance(value, (list, dict)):
        return bool(value)
    return True


def check_coverage(payload: dict[str, Any], *, root: Path = REPO_ROOT) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if payload.get("schemaVersion") != 1:
        failures.append(failure("invalid_schema_version", "schemaVersion", "schemaVersion must be 1"))
    if payload.get("artifactKind") != "browser_artifact_identity_coverage":
        failures.append(
            failure(
                "invalid_artifact_kind",
                "artifactKind",
                "artifactKind must be browser_artifact_identity_coverage",
            )
        )

    artifacts = payload.get("artifacts")
    if not isinstance(artifacts, list) or not artifacts:
        return failures + [failure("missing_artifacts", "artifacts", "artifacts must be a non-empty array")]

    seen_paths: set[str] = set()
    for index, row in enumerate(artifacts):
        row_path = f"artifacts[{index}]"
        if not isinstance(row, dict):
            failures.append(failure("invalid_artifact_row", row_path, "artifact row must be an object"))
            continue

        artifact_path = row.get("artifactPath")
        if not isinstance(artifact_path, str) or not artifact_path:
            failures.append(failure("missing_artifact_path", f"{row_path}.artifactPath", "artifactPath is required"))
            continue
        if artifact_path in seen_paths:
            failures.append(
                failure("duplicate_artifact_path", f"{row_path}.artifactPath", f"duplicate artifactPath {artifact_path}")
            )
        seen_paths.add(artifact_path)
        if not safe_repo_path(artifact_path):
            failures.append(
                failure(
                    "unsafe_artifact_path",
                    f"{row_path}.artifactPath",
                    f"artifact path must be repo-relative: {artifact_path}",
                )
            )
            continue

        resolved = resolve_repo_path(root, artifact_path)
        if not resolved.is_file():
            failures.append(
                failure(
                    "missing_artifact",
                    f"{row_path}.artifactPath",
                    f"artifact does not exist: {artifact_path}",
                )
            )
            continue

        try:
            artifact = load_json(resolved)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            failures.append(
                failure(
                    "invalid_artifact_json",
                    f"{row_path}.artifactPath",
                    f"artifact is not a JSON object: {exc}",
                )
            )
            continue

        kind_field = row.get("kindField")
        expected_kind = row.get("expectedKind")
        if kind_field not in {"artifactKind", "reportKind"}:
            failures.append(failure("invalid_kind_field", f"{row_path}.kindField", "kindField is invalid"))
        elif artifact.get(kind_field) != expected_kind:
            failures.append(
                failure(
                    "artifact_kind_mismatch",
                    f"{row_path}.expectedKind",
                    f"{artifact_path} has {kind_field}={artifact.get(kind_field)!r}",
                )
            )

        pointers = row.get("requiredPointers")
        if not isinstance(pointers, list) or not pointers:
            failures.append(
                failure("missing_required_pointers", f"{row_path}.requiredPointers", "requiredPointers must be non-empty")
            )
            continue
        for pointer in pointers:
            if not isinstance(pointer, str) or not pointer.startswith("/"):
                failures.append(
                    failure("invalid_pointer", f"{row_path}.requiredPointers", f"invalid JSON pointer {pointer!r}")
                )
                continue
            exists, value = pointer_value(artifact, pointer)
            if not exists or not has_identity_value(value):
                failures.append(
                    failure(
                        "missing_identity_anchor",
                        f"{artifact_path}{pointer}",
                        "required identity anchor is missing or empty",
                    )
                )

    return failures


def main() -> int:
    args = parse_args()
    failures = check_coverage(load_json(Path(args.coverage)), root=Path(args.root).resolve())
    report = {
        "schemaVersion": 1,
        "artifactKind": "browser_artifact_identity_coverage_check",
        "coveragePath": args.coverage,
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: browser artifact identity coverage")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: browser artifact identity coverage")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
