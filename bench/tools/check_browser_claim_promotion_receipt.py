#!/usr/bin/env python3
"""Check browser claim promotion receipts for forced-Doe and no-fallback evidence."""

from __future__ import annotations

import argparse
import hashlib
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
    parser.add_argument("--receipt", required=True, help="Browser claim promotion receipt JSON.")
    parser.add_argument(
        "--verify-files-root",
        default="",
        help="Resolve relative artifact paths under this root and verify sha256 values.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def resolve_artifact_path(path_text: str, verify_files_root: Path) -> Path | None:
    root = verify_files_root.resolve()
    path = Path(path_text)
    candidate = path if path.is_absolute() else root.joinpath(*PurePosixPath(path_text).parts)
    resolved = candidate.resolve()
    try:
        resolved.relative_to(root)
    except ValueError:
        return None
    return resolved


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_receipt(payload: dict[str, Any], verify_files_root: Path | None = None) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    artifacts = [row for row in payload.get("artifacts", []) if isinstance(row, dict)]
    for index, row in enumerate(artifacts):
        row_path = f"artifacts[{index}]"
        if row.get("mode") != "doe" or row.get("forcedDoe") is not True:
            failures.append(failure("artifact_not_forced_doe", row_path, "promotion artifacts must be forced-Doe runs"))
        if row.get("hiddenFallbackUsed") is True:
            failures.append(failure("hidden_fallback_used", f"{row_path}.hiddenFallbackUsed", "promotion artifacts cannot use hidden fallback"))
        if row.get("claimPolicyPassed") is not True:
            failures.append(failure("claim_policy_not_passed", f"{row_path}.claimPolicyPassed", "promotion artifacts must pass browser claim policy"))
        artifact_path = row.get("path")
        artifact_hash = row.get("sha256")
        if verify_files_root is not None and isinstance(artifact_path, str) and isinstance(artifact_hash, str):
            resolved_path = resolve_artifact_path(artifact_path, verify_files_root)
            if resolved_path is None:
                failures.append(
                    failure(
                        "unsafe_artifact_path",
                        f"{row_path}.path",
                        f"artifact path must resolve under verify-files-root: {artifact_path}",
                    )
                )
                continue
            if not resolved_path.is_file():
                failures.append(failure("artifact_file_missing", f"{row_path}.path", f"artifact file not found: {artifact_path}"))
            else:
                actual_hash = sha256_file(resolved_path)
                if actual_hash != artifact_hash:
                    failures.append(
                        failure(
                            "artifact_hash_mismatch",
                            f"{row_path}.sha256",
                            f"expected {actual_hash} for {artifact_path}",
                        )
                    )
    hidden = payload.get("hiddenFallbackCheck", {})
    if not isinstance(hidden, dict) or hidden.get("passed") is not True:
        failures.append(failure("hidden_fallback_check_failed", "hiddenFallbackCheck.passed", "hidden fallback check must pass"))
    if payload.get("promotionStatus") == "promotable" and failures:
        failures.append(failure("promotable_receipt_has_failures", "promotionStatus", "promotable receipts cannot carry failures"))
    return failures


def main() -> int:
    args = parse_args()
    verify_files_root = Path(args.verify_files_root).resolve() if args.verify_files_root else None
    failures = check_receipt(load_json(Path(args.receipt)), verify_files_root)
    report = {
        "schemaVersion": 1,
        "artifactKind": "browser_claim_promotion_receipt_check",
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: browser claim promotion receipt")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: browser claim promotion receipt")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
