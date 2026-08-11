#!/usr/bin/env python3
"""Build a hash-linked receipt for the published WebGPU CTS subset ledger."""

from __future__ import annotations

import argparse
import hashlib
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

try:
    from bench.tools._repo_import import ensure_repo_root
except ModuleNotFoundError:
    from _repo_import import ensure_repo_root

REPO_ROOT = ensure_repo_root(__file__)

from bench.lib.bench_utils import load_json_object, write_json_object


DEFAULT_EVIDENCE_PATH = Path("config/webgpu-cts-evidence.json")
DEFAULT_PUBLICATION_CHANNEL = "repo_example"
RECEIPT_KIND = "webgpu_cts_subset_receipt"
EVIDENCE_KIND = "webgpu_cts_evidence"
CLAIM_POLICY_KIND = "webgpu_cts_conformance_claim_policy"
CLAIM_LANGUAGE = "diagnostic_until_full_published_pass_ledger"
REMAINING_PROMOTION_REQUIREMENTS = ["backend_specific_cts_pass_ledger"]
EVIDENCE_SCHEMA_VERSION = 2
RECEIPT_SCHEMA_VERSION = 2
IDENTITY_KIND = "webgpu_cts_adapter_identity"
STATUS_KEYS = ("pass", "fail", "skip", "not_run")
REQUIRED_ROW_FIELDS = (
    "query",
    "bucket",
    "status",
    "surface",
    "backend",
    "host",
    "os",
    "artifactPath",
)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        default=str(REPO_ROOT),
        help="Repository root used to resolve evidence and output paths.",
    )
    parser.add_argument(
        "--evidence",
        default=str(DEFAULT_EVIDENCE_PATH),
        help="WebGPU CTS evidence ledger path relative to the repository root.",
    )
    parser.add_argument(
        "--publication-channel",
        default=DEFAULT_PUBLICATION_CHANNEL,
        help="Publication channel label recorded in the receipt.",
    )
    parser.add_argument(
        "--receipt-id",
        default="",
        help="Optional receipt id. Defaults to a deterministic id from the CTS ledger.",
    )
    parser.add_argument(
        "--out",
        default="",
        help="Optional receipt output path relative to the repository root.",
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args()


def require_string(payload: dict[str, Any], field: str) -> str:
    value = payload.get(field)
    if not isinstance(value, str) or not value:
        raise ValueError(f"CTS evidence {field} must be a non-empty string")
    return value


def validate_claim_policy(policy: Any) -> dict[str, Any]:
    if not isinstance(policy, dict):
        raise ValueError("CTS evidence claimPolicy must be an object")
    if policy.get("artifactKind") != CLAIM_POLICY_KIND:
        raise ValueError(f"CTS evidence claimPolicy.artifactKind must be {CLAIM_POLICY_KIND}")
    if policy.get("claimLanguage") != CLAIM_LANGUAGE:
        raise ValueError(f"CTS evidence claimPolicy.claimLanguage must be {CLAIM_LANGUAGE}")
    policy_id = policy.get("policyId")
    if not isinstance(policy_id, str) or not policy_id:
        raise ValueError("CTS evidence claimPolicy.policyId must be a non-empty string")
    diagnostic_language = policy.get("diagnosticLanguage")
    if not isinstance(diagnostic_language, str) or not diagnostic_language:
        raise ValueError(
            "CTS evidence claimPolicy.diagnosticLanguage must be a non-empty string"
        )
    return policy


def normalize_row(row: dict[str, Any], index: int) -> dict[str, str]:
    out: dict[str, str] = {}
    for field in REQUIRED_ROW_FIELDS:
        value = row.get(field)
        if not isinstance(value, str) or not value:
            raise ValueError(f"CTS evidence row {index} {field} must be a non-empty string")
        out[field] = value
    if out["status"] not in STATUS_KEYS:
        raise ValueError(f"CTS evidence row {index} status is not a known CTS status")
    notes = row.get("notes")
    if notes is not None:
        if not isinstance(notes, str):
            raise ValueError(f"CTS evidence row {index} notes must be a string")
        out["notes"] = notes
    return out


def evidence_rows(payload: dict[str, Any]) -> list[dict[str, str]]:
    rows = payload.get("evidence")
    if not isinstance(rows, list) or not rows:
        raise ValueError("CTS evidence must contain at least one evidence row")
    normalized: list[dict[str, str]] = []
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ValueError(f"CTS evidence row {index} must be an object")
        normalized.append(normalize_row(row, index))
    return normalized


def published_artifacts(payload: dict[str, Any], root: Path) -> list[dict[str, Any]]:
    if payload.get("schemaVersion") != EVIDENCE_SCHEMA_VERSION:
        raise ValueError(
            f"CTS evidence schemaVersion must be {EVIDENCE_SCHEMA_VERSION} for publication"
        )
    artifacts = payload.get("publishedArtifacts")
    if not isinstance(artifacts, list) or not artifacts:
        raise ValueError("CTS evidence publishedArtifacts must contain at least one artifact")
    normalized: list[dict[str, Any]] = []
    seen_paths: set[str] = set()
    for index, artifact in enumerate(artifacts):
        if not isinstance(artifact, dict):
            raise ValueError(f"CTS published artifact {index} must be an object")
        path_value = artifact.get("path")
        expected_hash = artifact.get("sha256")
        identity = artifact.get("identity")
        if not isinstance(path_value, str) or not path_value:
            raise ValueError(f"CTS published artifact {index} path must be a non-empty string")
        if path_value in seen_paths:
            raise ValueError(f"CTS published artifact path is duplicated: {path_value}")
        seen_paths.add(path_value)
        if not isinstance(expected_hash, str) or not re.fullmatch(r"[a-f0-9]{64}", expected_hash):
            raise ValueError(f"CTS published artifact {index} sha256 must be lowercase hex")
        artifact_path = root / path_value
        if not artifact_path.is_file():
            raise ValueError(f"CTS published artifact does not exist: {path_value}")
        actual_hash = sha256_file(artifact_path)
        if actual_hash != expected_hash:
            raise ValueError(
                f"CTS published artifact hash mismatch for {path_value}: "
                f"expected {expected_hash}, got {actual_hash}"
            )
        if not isinstance(identity, dict) or identity.get("artifactKind") != IDENTITY_KIND:
            raise ValueError(
                f"CTS published artifact {index} identity.artifactKind must be {IDENTITY_KIND}"
            )
        adapter_info = identity.get("adapterInfo")
        if not isinstance(adapter_info, dict):
            raise ValueError(f"CTS published artifact {index} identity.adapterInfo must be an object")
        for field in ("vendor", "device", "description"):
            value = adapter_info.get(field)
            if not isinstance(value, str) or not value:
                raise ValueError(
                    f"CTS published artifact {index} identity.adapterInfo.{field} "
                    "must be a non-empty string"
                )
        normalized.append(
            {
                "path": path_value,
                "sha256": actual_hash,
                "identity": identity,
            }
        )
    return normalized


def published_evidence_rows(
    rows: list[dict[str, str]], artifacts: list[dict[str, Any]]
) -> list[dict[str, str]]:
    artifact_paths = {artifact["path"] for artifact in artifacts}
    published_rows = [row for row in rows if row["artifactPath"] in artifact_paths]
    used_paths = {row["artifactPath"] for row in published_rows}
    unused_paths = sorted(artifact_paths - used_paths)
    if unused_paths:
        raise ValueError(
            "CTS published artifacts have no evidence rows: " + ", ".join(unused_paths)
        )
    if not published_rows:
        raise ValueError("CTS evidence has no rows for its published artifacts")
    return published_rows


def receipt_id_from_payload(payload: dict[str, Any], rows: list[dict[str, str]]) -> str:
    last_updated = require_string(payload, "lastUpdated")
    date_slug = re.sub(r"[^a-zA-Z0-9]+", "", last_updated).lower() or "undated"
    backend_slug = "-".join(
        re.sub(r"[^a-zA-Z0-9]+", "-", backend).strip("-").lower()
        for backend in sorted({row["backend"] for row in rows})
    )
    return f"webgpu-cts-subset-{date_slug}-{backend_slug or 'unknown-backend'}"


def build_backend_coverage(rows: list[dict[str, str]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str, str], set[str]] = defaultdict(set)
    for row in rows:
        grouped[
            (
                row["backend"],
                row["surface"],
                row["host"],
                row["os"],
            )
        ].add(row["artifactPath"])
    coverage: list[dict[str, Any]] = []
    for backend, surface, host, os_name in sorted(grouped):
        coverage.append(
            {
                "backend": backend,
                "surface": surface,
                "host": host,
                "os": os_name,
                "artifactPaths": sorted(grouped[(backend, surface, host, os_name)]),
            }
        )
    return coverage


def summary_for_rows(rows: list[dict[str, str]]) -> dict[str, int]:
    statuses = Counter(row["status"] for row in rows)
    return {
        "coverageRowCount": len(rows),
        "queryCount": len({row["query"] for row in rows}),
        "backendCount": len({row["backend"] for row in rows}),
        "surfaceCount": len({row["surface"] for row in rows}),
        "artifactPathCount": len({row["artifactPath"] for row in rows}),
        "passCount": statuses.get("pass", 0),
        "failCount": statuses.get("fail", 0),
        "skipCount": statuses.get("skip", 0),
        "notRunCount": statuses.get("not_run", 0),
    }


def build_receipt(
    *,
    root: Path,
    evidence_path: Path,
    publication_channel: str = DEFAULT_PUBLICATION_CHANNEL,
    receipt_id: str = "",
) -> dict[str, Any]:
    payload = load_json_object(root / evidence_path)
    if payload.get("artifactKind") != EVIDENCE_KIND:
        raise ValueError(f"CTS evidence artifactKind must be {EVIDENCE_KIND}")
    policy = validate_claim_policy(payload.get("claimPolicy"))
    rows = evidence_rows(payload)
    artifacts = published_artifacts(payload, root)
    rows = published_evidence_rows(rows, artifacts)
    cts_source = require_string(payload, "ctsSource")
    cts_revision = require_string(payload, "ctsRevision")
    resolved_receipt_id = receipt_id or receipt_id_from_payload(payload, rows)
    if not publication_channel:
        raise ValueError("publication_channel must be a non-empty string")
    return {
        "schemaVersion": RECEIPT_SCHEMA_VERSION,
        "artifactKind": RECEIPT_KIND,
        "receiptId": resolved_receipt_id,
        "publicationStatus": "repo_published",
        "publicationChannel": publication_channel,
        "sourceEvidence": {
            "path": evidence_path.as_posix(),
            "sha256": sha256_file(root / evidence_path),
            "artifactKind": EVIDENCE_KIND,
            "policyId": policy["policyId"],
            "claimLanguage": policy["claimLanguage"],
            "diagnosticLanguage": policy["diagnosticLanguage"],
        },
        "ctsSource": cts_source,
        "ctsRevision": cts_revision,
        "conformanceClaimAllowed": False,
        "claimLanguage": CLAIM_LANGUAGE,
        "remainingPromotionRequirements": REMAINING_PROMOTION_REQUIREMENTS,
        "artifactReceipts": artifacts,
        "summary": summary_for_rows(rows),
        "backendCoverage": build_backend_coverage(rows),
        "queryCoverage": rows,
    }


def main() -> int:
    args = parse_args()
    root = Path(args.root).resolve()
    receipt = build_receipt(
        root=root,
        evidence_path=Path(args.evidence),
        publication_channel=args.publication_channel,
        receipt_id=args.receipt_id,
    )
    if args.out:
        write_json_object(root / args.out, receipt)
    if args.emit_json or not args.out:
        import json

        print(json.dumps(receipt, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
