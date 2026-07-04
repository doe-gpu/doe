#!/usr/bin/env python3
"""Build backend-specific pass ledgers from a WebGPU CTS subset receipt."""

from __future__ import annotations

import argparse
import hashlib
import re
from collections import Counter
from pathlib import Path
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)

from bench.lib.bench_utils import load_json_object, write_json_object


DEFAULT_SUBSET_RECEIPT_PATH = Path("examples/webgpu-cts-subset-receipt.sample.json")
LEDGER_KIND = "webgpu_cts_backend_pass_ledger"
SUBSET_RECEIPT_KIND = "webgpu_cts_subset_receipt"
EVIDENCE_KIND = "webgpu_cts_evidence"
CLAIM_LANGUAGE = "diagnostic_until_full_published_pass_ledger"
STATUS_KEYS = ("pass", "fail", "skip", "not_run")
GROUP_FIELDS = ("backend", "surface", "host", "os")
QUERY_FIELDS = ("query", "bucket", "status", "artifactPath")


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=str(REPO_ROOT),
        help="Repository root used to resolve receipt and output paths.",
    )
    parser.add_argument(
        "--subset-receipt",
        default=str(DEFAULT_SUBSET_RECEIPT_PATH),
        help="WebGPU CTS subset receipt path relative to the repository root.",
    )
    parser.add_argument(
        "--ledger-id",
        default="",
        help="Optional ledger id. Defaults to a deterministic id from the subset receipt.",
    )
    parser.add_argument(
        "--out",
        default="",
        help="Optional ledger output path relative to the repository root.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def require_string(payload: dict[str, Any], field: str, label: str) -> str:
    value = payload.get(field)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label}.{field} must be a non-empty string")
    return value


def normalize_query_row(row: dict[str, Any], index: int) -> dict[str, str]:
    normalized: dict[str, str] = {}
    for field in (*GROUP_FIELDS, *QUERY_FIELDS):
        value = row.get(field)
        if not isinstance(value, str) or not value:
            raise ValueError(f"queryCoverage[{index}].{field} must be a non-empty string")
        normalized[field] = value
    if normalized["status"] not in STATUS_KEYS:
        raise ValueError(f"queryCoverage[{index}].status is not a known CTS status")
    notes = row.get("notes")
    if notes is not None:
        if not isinstance(notes, str):
            raise ValueError(f"queryCoverage[{index}].notes must be a string")
        normalized["notes"] = notes
    return normalized


def query_rows(payload: dict[str, Any]) -> list[dict[str, str]]:
    rows = payload.get("queryCoverage")
    if not isinstance(rows, list) or not rows:
        raise ValueError("subset receipt queryCoverage must contain at least one row")
    normalized: list[dict[str, str]] = []
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ValueError(f"queryCoverage[{index}] must be an object")
        normalized.append(normalize_query_row(row, index))
    return normalized


def summary_for_rows(rows: list[dict[str, str]], backend_ledger_count: int) -> dict[str, Any]:
    status_counts = Counter(row["status"] for row in rows)
    failing_backend_count = 0
    grouped_statuses: dict[tuple[str, str, str, str], list[str]] = {}
    for row in rows:
        key = tuple(row[field] for field in GROUP_FIELDS)
        grouped_statuses.setdefault(key, []).append(row["status"])
    for statuses in grouped_statuses.values():
        if any(status != "pass" for status in statuses):
            failing_backend_count += 1
    return {
        "backendLedgerCount": backend_ledger_count,
        "coverageRowCount": len(rows),
        "passCount": status_counts.get("pass", 0),
        "failCount": status_counts.get("fail", 0),
        "skipCount": status_counts.get("skip", 0),
        "notRunCount": status_counts.get("not_run", 0),
        "failingBackendLedgerCount": failing_backend_count,
        "allBackendLedgersPass": failing_backend_count == 0,
    }


def query_projection(row: dict[str, str]) -> dict[str, str]:
    out = {field: row[field] for field in QUERY_FIELDS}
    if "notes" in row:
        out["notes"] = row["notes"]
    return out


def build_backend_ledgers(rows: list[dict[str, str]]) -> list[dict[str, Any]]:
    groups: dict[tuple[str, str, str, str], list[dict[str, str]]] = {}
    for row in rows:
        key = tuple(row[field] for field in GROUP_FIELDS)
        groups.setdefault(key, []).append(row)
    ledgers: list[dict[str, Any]] = []
    for backend, surface, host, os_name in sorted(groups):
        group_rows = groups[(backend, surface, host, os_name)]
        group_summary = summary_for_rows(group_rows, 1)
        ledgers.append(
            {
                "backend": backend,
                "surface": surface,
                "host": host,
                "os": os_name,
                "ledgerStatus": "pass"
                if group_summary["allBackendLedgersPass"]
                else "fail",
                "artifactPaths": sorted({row["artifactPath"] for row in group_rows}),
                "summary": group_summary,
                "queryCoverage": [query_projection(row) for row in group_rows],
            }
        )
    return ledgers


def ledger_id_from_receipt(payload: dict[str, Any], rows: list[dict[str, str]]) -> str:
    receipt_id = require_string(payload, "receiptId", "subset receipt")
    backend_slug = "-".join(
        re.sub(r"[^a-zA-Z0-9]+", "-", backend).strip("-").lower()
        for backend in sorted({row["backend"] for row in rows})
    )
    return f"{receipt_id}-backend-pass-ledger-{backend_slug or 'unknown-backend'}"


def build_ledger(
    *,
    root: Path,
    subset_receipt_path: Path,
    ledger_id: str = "",
) -> dict[str, Any]:
    subset_receipt = load_json_object(root / subset_receipt_path)
    if subset_receipt.get("artifactKind") != SUBSET_RECEIPT_KIND:
        raise ValueError(f"subset receipt artifactKind must be {SUBSET_RECEIPT_KIND}")
    if subset_receipt.get("claimLanguage") != CLAIM_LANGUAGE:
        raise ValueError(f"subset receipt claimLanguage must be {CLAIM_LANGUAGE}")
    source_evidence = subset_receipt.get("sourceEvidence")
    if not isinstance(source_evidence, dict):
        raise ValueError("subset receipt sourceEvidence must be an object")
    rows = query_rows(subset_receipt)
    backend_ledgers = build_backend_ledgers(rows)
    summary = summary_for_rows(rows, len(backend_ledgers))
    resolved_ledger_id = ledger_id or ledger_id_from_receipt(subset_receipt, rows)
    return {
        "schemaVersion": 1,
        "artifactKind": LEDGER_KIND,
        "ledgerId": resolved_ledger_id,
        "ledgerStatus": "pass" if summary["allBackendLedgersPass"] else "fail",
        "claimScope": "published_subset_backend_pass_ledger",
        "fullConformanceClaimAllowed": False,
        "replacementClaimAllowed": False,
        "sourceReceipt": {
            "path": subset_receipt_path.as_posix(),
            "sha256": sha256_file(root / subset_receipt_path),
            "artifactKind": SUBSET_RECEIPT_KIND,
            "receiptId": subset_receipt["receiptId"],
        },
        "sourceEvidence": {
            "path": source_evidence["path"],
            "sha256": source_evidence["sha256"],
            "artifactKind": EVIDENCE_KIND,
        },
        "claimLanguage": CLAIM_LANGUAGE,
        "summary": summary,
        "backendLedgers": backend_ledgers,
    }


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    ledger = build_ledger(
        root=root,
        subset_receipt_path=Path(args.subset_receipt),
        ledger_id=args.ledger_id,
    )
    if args.out:
        write_json_object(root / args.out, ledger)
    if args.emit_json or not args.out:
        import json

        print(json.dumps(ledger, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
