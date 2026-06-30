#!/usr/bin/env python3
"""Check WGSL source-to-IR-to-backend lowering link receipts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

ensure_repo_root(__file__)

from bench.lib.bench_utils import is_safe_repo_path


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", required=True, help="wgsl_lowering_link_receipt JSON path.")
    parser.add_argument(
        "--verify-files-root",
        default="",
        help="Resolve relative source/receipt paths under this root and verify linked evidence.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def normalize_source(text: str) -> str:
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    if not normalized.endswith("\n"):
        normalized += "\n"
    return normalized


def normalized_sha256(path: Path) -> str:
    return hashlib.sha256(
        normalize_source(path.read_text(encoding="utf-8")).encode("utf-8")
    ).hexdigest()


def is_sha256(value: Any) -> bool:
    return isinstance(value, str) and bool(SHA256_RE.fullmatch(value))


def safe_repo_path(path_text: str) -> bool:
    return is_safe_repo_path(path_text)


def resolve_path(path_text: str, verify_files_root: Path | None) -> Path:
    path = Path(path_text)
    if path.is_absolute() or verify_files_root is None:
        return path
    return verify_files_root / path


def check_receipt(
    payload: dict[str, Any],
    verify_files_root: Path | None = None,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if payload.get("artifactKind") != "wgsl_lowering_link_receipt":
        failures.append(
            failure("invalid_artifact_kind", "artifactKind", "artifactKind must be wgsl_lowering_link_receipt")
        )

    rows = payload.get("rows", [])
    if not isinstance(rows, list):
        failures.append(failure("invalid_rows", "rows", "rows must be an array"))
        rows = []
    summary = payload.get("summary")
    if not isinstance(summary, dict):
        failures.append(failure("missing_summary", "summary", "summary must be an object"))
        summary = {}

    linked_rows = 0
    diagnostic_rows = 0
    row_failures: list[dict[str, Any]] = []
    seen_shader_ids: set[str] = set()
    for index, row in enumerate(rows):
        row_path = f"rows[{index}]"
        if not isinstance(row, dict):
            failures.append(failure("invalid_row", row_path, "row must be an object"))
            continue
        shader_id = row.get("shaderId")
        if not isinstance(shader_id, str) or not shader_id:
            failures.append(failure("missing_shader_id", f"{row_path}.shaderId", "shaderId is required"))
        elif shader_id in seen_shader_ids:
            failures.append(failure("duplicate_shader_id", f"{row_path}.shaderId", f"duplicate shaderId {shader_id}"))
        else:
            seen_shader_ids.add(shader_id)

        link_status = row.get("linkStatus")
        failures_for_row = row.get("failureCodes")
        if not isinstance(failures_for_row, list):
            failures.append(failure("invalid_row_failures", f"{row_path}.failureCodes", "failureCodes must be an array"))
            failures_for_row = []
        row_failures.extend(item for item in failures_for_row if isinstance(item, dict))
        if link_status == "linked":
            linked_rows += 1
            for field in (
                "sourceSha256",
                "doeIrSha256",
                "doeBackendOutputSha256",
                "tintBackendOutputSha256",
            ):
                if not is_sha256(row.get(field)):
                    failures.append(failure("missing_link_hash", f"{row_path}.{field}", f"{field} must be sha256 hex"))
            if not row.get("doeReceiptPath"):
                failures.append(failure("missing_doe_receipt_path", f"{row_path}.doeReceiptPath", "Doe receipt path is required"))
            if not row.get("tintReceiptPath"):
                failures.append(failure("missing_tint_receipt_path", f"{row_path}.tintReceiptPath", "Tint receipt path is required"))
            if failures_for_row:
                failures.append(failure("linked_row_has_failures", f"{row_path}.failureCodes", "linked rows cannot carry failures"))
        elif link_status == "diagnostic":
            diagnostic_rows += 1
            if not failures_for_row:
                failures.append(failure("diagnostic_row_without_failure", f"{row_path}.failureCodes", "diagnostic rows require failures"))
        else:
            failures.append(failure("invalid_link_status", f"{row_path}.linkStatus", "linkStatus must be linked or diagnostic"))

        source_path = row.get("sourcePath")
        source_hash = row.get("sourceSha256")
        if isinstance(source_path, str) and source_path and not safe_repo_path(source_path):
            failures.append(
                failure(
                    "unsafe_source_path",
                    f"{row_path}.sourcePath",
                    "sourcePath must be repo-relative",
                )
            )
        doe_receipt_path = row.get("doeReceiptPath")
        if isinstance(doe_receipt_path, str) and doe_receipt_path and not safe_repo_path(doe_receipt_path):
            failures.append(
                failure(
                    "unsafe_doe_receipt_path",
                    f"{row_path}.doeReceiptPath",
                    "doeReceiptPath must be repo-relative",
                )
            )
        tint_receipt_path = row.get("tintReceiptPath")
        if isinstance(tint_receipt_path, str) and tint_receipt_path and not safe_repo_path(tint_receipt_path):
            failures.append(
                failure(
                    "unsafe_tint_receipt_path",
                    f"{row_path}.tintReceiptPath",
                    "tintReceiptPath must be repo-relative",
                )
            )
        if verify_files_root is not None:
            if isinstance(source_path, str) and safe_repo_path(source_path) and is_sha256(source_hash):
                resolved_source = resolve_path(source_path, verify_files_root)
                if not resolved_source.is_file():
                    failures.append(
                        failure(
                            "source_file_missing",
                            f"{row_path}.sourcePath",
                            f"source file not found: {source_path}",
                        )
                    )
                else:
                    actual_hash = normalized_sha256(resolved_source)
                    if actual_hash != source_hash:
                        failures.append(
                            failure(
                                "source_hash_mismatch",
                                f"{row_path}.sourceSha256",
                                f"expected {source_hash}, got {actual_hash}",
                            )
                        )
            if (
                link_status == "linked"
                and isinstance(doe_receipt_path, str)
                and doe_receipt_path
                and safe_repo_path(doe_receipt_path)
            ):
                resolved_receipt = resolve_path(doe_receipt_path, verify_files_root)
                if not resolved_receipt.is_file():
                    failures.append(
                        failure(
                            "doe_receipt_missing",
                            f"{row_path}.doeReceiptPath",
                            f"Doe receipt not found: {doe_receipt_path}",
                        )
                    )
            if (
                link_status == "linked"
                and isinstance(tint_receipt_path, str)
                and tint_receipt_path
                and safe_repo_path(tint_receipt_path)
            ):
                resolved_receipt = resolve_path(tint_receipt_path, verify_files_root)
                if not resolved_receipt.is_file():
                    failures.append(
                        failure(
                            "tint_receipt_missing",
                            f"{row_path}.tintReceiptPath",
                            f"Tint receipt not found: {tint_receipt_path}",
                        )
                    )

    expected = {
        "rowCount": len(rows),
        "linkedRows": linked_rows,
        "diagnosticRows": diagnostic_rows,
    }
    for key, value in expected.items():
        if summary.get(key) != value:
            failures.append(failure("summary_count_mismatch", f"summary.{key}", f"{key} must be {value}"))
    summary_failures = summary.get("failureCodes")
    if not isinstance(summary_failures, list):
        failures.append(failure("invalid_summary_failures", "summary.failureCodes", "failureCodes must be an array"))
    elif len(summary_failures) != len(row_failures):
        failures.append(
            failure(
                "summary_failure_count_mismatch",
                "summary.failureCodes",
                "summary failureCodes must mirror row failureCodes",
            )
        )
    if row_failures:
        failures.append(failure("lowering_link_has_diagnostic_rows", "rows", "all lowering link rows must be linked"))
    return failures


def main() -> int:
    args = parse_args()
    verify_files_root = Path(args.verify_files_root).resolve() if args.verify_files_root else None
    failures = check_receipt(load_json(Path(args.receipt)), verify_files_root)
    report = {
        "schemaVersion": 1,
        "artifactKind": "wgsl_lowering_link_receipt_check",
        "receiptPath": args.receipt,
        "status": "fail" if failures else "pass",
        "failures": failures,
    }
    if args.emit_json:
        print(json.dumps(report, indent=2))
    elif failures:
        print("FAIL: WGSL lowering link receipt")
        for item in failures:
            print(f"- {item['code']}: {item['path']}: {item['message']}")
    else:
        print("PASS: WGSL lowering link receipt")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
