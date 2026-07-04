#!/usr/bin/env python3
"""Tests for the WebGPU CTS subset receipt builder."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

import jsonschema

from bench.tools import build_webgpu_cts_subset_receipt as builder


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "config" / "webgpu-cts-subset-receipt.schema.json"
EVIDENCE_PATH = REPO_ROOT / "config" / "webgpu-cts-evidence.json"


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_build_receipt_binds_cts_evidence_rows_and_policy() -> None:
    receipt = builder.build_receipt(
        root=REPO_ROOT,
        evidence_path=Path("config/webgpu-cts-evidence.json"),
    )
    evidence = _load(EVIDENCE_PATH)

    jsonschema.validate(receipt, _load(SCHEMA_PATH))
    assert receipt["artifactKind"] == "webgpu_cts_subset_receipt"
    assert receipt["publicationStatus"] == "repo_published"
    assert receipt["sourceEvidence"]["path"] == "config/webgpu-cts-evidence.json"
    assert receipt["sourceEvidence"]["sha256"] == builder.sha256_file(EVIDENCE_PATH)
    assert receipt["sourceEvidence"]["policyId"] == evidence["claimPolicy"]["policyId"]
    assert receipt["conformanceClaimAllowed"] is False
    assert receipt["remainingPromotionRequirements"] == ["backend_specific_cts_pass_ledger"]
    assert receipt["queryCoverage"] == evidence["evidence"]
    assert receipt["summary"]["coverageRowCount"] == len(evidence["evidence"])
    assert receipt["summary"]["passCount"] == len(evidence["evidence"])
    assert receipt["summary"]["failCount"] == 0


def test_build_receipt_rejects_missing_claim_policy() -> None:
    payload = _load(EVIDENCE_PATH)
    del payload["claimPolicy"]
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        evidence_path = Path(tmpdir) / "webgpu-cts-evidence.json"
        evidence_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        rel_path = evidence_path.relative_to(REPO_ROOT)
        try:
            builder.build_receipt(root=REPO_ROOT, evidence_path=rel_path)
        except ValueError as exc:
            assert "claimPolicy must be an object" in str(exc)
        else:
            raise AssertionError("missing claimPolicy should reject CTS subset receipt build")


def test_build_receipt_rejects_malformed_evidence_row() -> None:
    payload = _load(EVIDENCE_PATH)
    del payload["evidence"][0]["backend"]
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        evidence_path = Path(tmpdir) / "webgpu-cts-evidence.json"
        evidence_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        rel_path = evidence_path.relative_to(REPO_ROOT)
        try:
            builder.build_receipt(root=REPO_ROOT, evidence_path=rel_path)
        except ValueError as exc:
            assert "backend must be a non-empty string" in str(exc)
        else:
            raise AssertionError("malformed CTS evidence row should reject receipt build")
