"""Artifacts for browser release evidence."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def nested_value(value: Any, path: tuple[str, ...]) -> Any:
    current = value
    for key in path:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def unsafe_receipt_path_reason(path: Any) -> str:
    if not isinstance(path, str) or not path:
        return "receipt path must be a non-empty string"
    if "\\" in path:
        return "receipt path must use forward slashes"
    if path.startswith("/"):
        return "receipt path must be repository-relative"
    if not path.endswith(".json"):
        return "receipt path must end in .json"
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return "receipt path must not contain empty, current, or parent segments"
    return ""


def unsafe_repo_path_reason(path: Any) -> str:
    if not isinstance(path, str) or not path:
        return "artifact path must be a non-empty string"
    if "\\" in path:
        return "artifact path must use forward slashes"
    if path.startswith("/"):
        return "artifact path must be repository-relative"
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return "artifact path must not contain empty, current, or parent segments"
    return ""


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def non_bool_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def validate_json_receipt_artifact_file(
    *,
    root: Path,
    artifact: dict[str, Any],
    failure_prefix: str,
    proof_surface_path: str,
    label: str,
) -> tuple[dict[str, Any] | None, list[dict[str, str]]]:
    rel_path = artifact.get("path")
    reason = unsafe_receipt_path_reason(rel_path)
    if reason:
        return None, [
            failure(
                f"{failure_prefix}_incomplete",
                proof_surface_path,
                reason,
            )
        ]
    path = root / rel_path
    if not path.exists():
        return None, [
            failure(
                f"{failure_prefix}_unavailable",
                proof_surface_path,
                f"{rel_path}: missing_required",
            )
        ]

    failures: list[dict[str, str]] = []
    try:
        actual_sha = sha256_file(path)
    except OSError as exc:
        return None, [
            failure(
                f"{failure_prefix}_unavailable",
                proof_surface_path,
                f"{rel_path}: hash_failed: {exc}",
            )
        ]
    if actual_sha != artifact.get("sha256"):
        failures.append(
            failure(
                f"{failure_prefix}_hash_mismatch",
                proof_surface_path,
                (
                    f"{label} artifact {rel_path} must hash to "
                    f"{actual_sha}, got {artifact.get('sha256')!r}"
                ),
            )
        )

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        failures.append(
            failure(
                f"{failure_prefix}_unavailable",
                proof_surface_path,
                f"{rel_path}: parse_failed: {exc}",
            )
        )
        return None, failures
    if not isinstance(payload, dict):
        failures.append(
            failure(
                f"{failure_prefix}_incomplete",
                proof_surface_path,
                f"{label} payload must be a JSON object",
            )
        )
        return None, failures
    return payload, failures
