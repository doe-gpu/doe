#!/usr/bin/env python3
"""Build source-to-IR-to-backend link receipts from compiler evidence."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


VALID_HEX = set("0123456789abcdef")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", required=True, help="Tint compiler evidence report.")
    parser.add_argument("--manifest", required=True, help="WGSL corpus manifest.")
    parser.add_argument("--out", required=True, help="Output lowering link receipt.")
    return parser.parse_args()


def load_json(path: Path) -> dict[str, Any]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"expected JSON object: {path}")
    return payload


def is_sha256(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(char in VALID_HEX for char in value)


def failure(code: str, row_id: str, message: str) -> dict[str, str]:
    return {"code": code, "rowId": row_id or "unknown", "message": message}


def build_manifest_index(manifest: dict[str, Any]) -> dict[str, dict[str, Any]]:
    index: dict[str, dict[str, Any]] = {}
    for row in manifest.get("rows", []):
        if not isinstance(row, dict):
            continue
        shader_id = str(row.get("shaderId", ""))
        source_path = str(row.get("sourcePath", ""))
        if shader_id:
            index[f"shader:{shader_id}"] = row
        if source_path:
            index[f"path:{source_path}"] = row
    return index


def find_manifest_row(index: dict[str, dict[str, Any]], row: dict[str, Any]) -> dict[str, Any] | None:
    shader_id = str(row.get("shaderId", ""))
    source_path = str(row.get("sourcePath", ""))
    return index.get(f"shader:{shader_id}") or index.get(f"path:{source_path}")


def link_row(row: dict[str, Any], manifest_row: dict[str, Any] | None) -> dict[str, Any]:
    row_id = str(row.get("shaderId", ""))
    failures: list[dict[str, str]] = []
    doe = row.get("doe", {})
    tint = row.get("tint", {})
    comparability = row.get("comparability", {})
    claimability = row.get("claimability", {})

    if not isinstance(manifest_row, dict):
        failures.append(failure("missing_manifest_row", row_id, "compiler evidence row does not map to the WGSL corpus manifest"))
        manifest_row = {
            "shaderId": row_id or "unknown",
            "sourcePath": str(row.get("sourcePath", "")),
            "normalizedSourceSha256": str(row.get("sourceSha256", "0" * 64)),
            "expectedValidity": str(row.get("expectedValidity", "valid")),
        }

    source_sha = row.get("sourceSha256")
    manifest_sha = manifest_row.get("normalizedSourceSha256")
    if source_sha != manifest_sha:
        failures.append(
            failure(
                "source_hash_mismatch",
                row_id,
                f"compiler evidence source hash does not match manifest shader {manifest_row.get('shaderId')}",
            )
        )

    if not isinstance(doe, dict) or doe.get("status") != "ok":
        failures.append(failure("doe_result_not_ok", row_id, "Doe compiler result is not ok"))
        doe = {} if not isinstance(doe, dict) else doe
    if not is_sha256(doe.get("irSha256")):
        failures.append(failure("missing_doe_ir_hash", row_id, "Doe compiler result is missing irSha256"))
    if not is_sha256(doe.get("outputSha256")):
        failures.append(failure("missing_doe_backend_hash", row_id, "Doe compiler result is missing outputSha256"))
    if not isinstance(doe.get("receiptPath"), str) or not doe.get("receiptPath"):
        failures.append(failure("missing_doe_receipt_path", row_id, "Doe compiler result is missing receiptPath"))

    if not isinstance(tint, dict) or tint.get("status") != "ok":
        failures.append(failure("tint_result_not_ok", row_id, "Tint compiler result is not ok"))
        tint = {} if not isinstance(tint, dict) else tint
    if not is_sha256(tint.get("outputSha256")):
        failures.append(failure("missing_tint_backend_hash", row_id, "Tint compiler result is missing outputSha256"))
    if not isinstance(tint.get("receiptPath"), str) or not tint.get("receiptPath"):
        failures.append(failure("missing_tint_receipt_path", row_id, "Tint compiler result is missing receiptPath"))

    linked = not failures
    return {
        "shaderId": row_id or str(manifest_row.get("shaderId", "unknown")),
        "manifestShaderId": str(manifest_row.get("shaderId", "unknown")),
        "sourcePath": str(manifest_row.get("sourcePath", row.get("sourcePath", ""))),
        "sourceSha256": str(manifest_sha if is_sha256(manifest_sha) else source_sha),
        "expectedValidity": str(manifest_row.get("expectedValidity", row.get("expectedValidity", "valid"))),
        "shaderStage": str(row.get("shaderStage", "mixed")),
        "backendTarget": str(row.get("target", "msl")),
        "doeIrSha256": doe.get("irSha256") if is_sha256(doe.get("irSha256")) else None,
        "doeBackendOutputSha256": doe.get("outputSha256") if is_sha256(doe.get("outputSha256")) else None,
        "doeReceiptPath": str(doe.get("receiptPath", "")),
        "doeValidationStatus": str(doe.get("validationStatus", "not_run")),
        "tintBackendOutputSha256": tint.get("outputSha256") if is_sha256(tint.get("outputSha256")) else None,
        "tintReceiptPath": str(tint.get("receiptPath", "")),
        "tintValidationStatus": str(tint.get("validationStatus", "not_run")),
        "validationStatus": str(doe.get("validationStatus", "not_run")),
        "comparabilityStatus": str(comparability.get("status", "diagnostic")) if isinstance(comparability, dict) else "diagnostic",
        "claimabilityStatus": str(claimability.get("status", "diagnostic")) if isinstance(claimability, dict) else "diagnostic",
        "linkStatus": "linked" if linked else "diagnostic",
        "failureCodes": failures,
    }


def build_receipt(
    *,
    evidence: dict[str, Any],
    evidence_path: str,
    manifest: dict[str, Any],
    manifest_path: str,
) -> dict[str, Any]:
    manifest_index = build_manifest_index(manifest)
    rows = [
        link_row(row, find_manifest_row(manifest_index, row))
        for row in evidence.get("rows", [])
        if isinstance(row, dict)
    ]
    linked_rows = sum(1 for row in rows if row["linkStatus"] == "linked")
    failure_codes = [
        item
        for row in rows
        for item in row["failureCodes"]
    ]
    return {
        "schemaVersion": 1,
        "artifactKind": "wgsl_lowering_link_receipt",
        "evidencePath": evidence_path,
        "manifestPath": manifest_path,
        "corpusId": str(manifest.get("corpusId", "unknown")),
        "rows": rows,
        "summary": {
            "rowCount": len(rows),
            "linkedRows": linked_rows,
            "diagnosticRows": len(rows) - linked_rows,
            "failureCodes": failure_codes,
        },
    }


def main() -> int:
    args = parse_args()
    receipt = build_receipt(
        evidence=load_json(Path(args.evidence)),
        evidence_path=args.evidence,
        manifest=load_json(Path(args.manifest)),
        manifest_path=args.manifest,
    )
    Path(args.out).write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return 1 if receipt["summary"]["failureCodes"] else 0


if __name__ == "__main__":
    sys.exit(main())
