#!/usr/bin/env python3
"""Tests for the WebGPU CTS backend pass-ledger builder."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

import jsonschema

from bench.tools import build_webgpu_cts_backend_pass_ledger as builder


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "config" / "webgpu-cts-backend-pass-ledger.schema.json"
SUBSET_RECEIPT_PATH = REPO_ROOT / "examples" / "webgpu-cts-subset-receipt.sample.json"


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_build_ledger_groups_subset_rows_by_backend_identity() -> None:
    ledger = builder.build_ledger(
        root=REPO_ROOT,
        subset_receipt_path=Path("examples/webgpu-cts-subset-receipt.sample.json"),
    )
    subset_receipt = _load(SUBSET_RECEIPT_PATH)

    jsonschema.validate(ledger, _load(SCHEMA_PATH))
    assert ledger["artifactKind"] == "webgpu_cts_backend_pass_ledger"
    assert ledger["ledgerStatus"] == "pass"
    assert ledger["sourceReceipt"]["path"] == "examples/webgpu-cts-subset-receipt.sample.json"
    assert ledger["sourceReceipt"]["sha256"] == builder.sha256_file(SUBSET_RECEIPT_PATH)
    assert ledger["sourceReceipt"]["receiptId"] == subset_receipt["receiptId"]
    assert ledger["sourceEvidence"] == {
        "path": subset_receipt["sourceEvidence"]["path"],
        "sha256": subset_receipt["sourceEvidence"]["sha256"],
        "artifactKind": "webgpu_cts_evidence",
    }
    assert ledger["fullConformanceClaimAllowed"] is False
    assert ledger["replacementClaimAllowed"] is False
    assert ledger["summary"]["allBackendLedgersPass"] is True
    assert ledger["summary"]["coverageRowCount"] == len(subset_receipt["queryCoverage"])
    assert ledger["summary"]["failingBackendLedgerCount"] == 0
    assert len(ledger["backendLedgers"]) == len(subset_receipt["backendCoverage"])
    backend_ledger = ledger["backendLedgers"][0]
    assert backend_ledger["backend"] == subset_receipt["backendCoverage"][0]["backend"]
    assert backend_ledger["ledgerStatus"] == "pass"
    assert len(backend_ledger["queryCoverage"]) == len(subset_receipt["queryCoverage"])


def test_build_ledger_records_non_pass_subset_rows_without_claiming_pass() -> None:
    subset_receipt = _load(SUBSET_RECEIPT_PATH)
    subset_receipt["queryCoverage"][0]["status"] = "fail"
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        subset_path = Path(tmpdir) / "webgpu-cts-subset-receipt.json"
        subset_path.write_text(
            json.dumps(subset_receipt, indent=2) + "\n",
            encoding="utf-8",
        )
        ledger = builder.build_ledger(
            root=REPO_ROOT,
            subset_receipt_path=subset_path.relative_to(REPO_ROOT),
        )

    jsonschema.validate(ledger, _load(SCHEMA_PATH))
    assert ledger["ledgerStatus"] == "fail"
    assert ledger["summary"]["allBackendLedgersPass"] is False
    assert ledger["summary"]["failingBackendLedgerCount"] == 1
    assert ledger["summary"]["failCount"] == 1
    assert ledger["backendLedgers"][0]["ledgerStatus"] == "fail"


def test_build_ledger_rejects_malformed_subset_receipt_kind() -> None:
    subset_receipt = _load(SUBSET_RECEIPT_PATH)
    subset_receipt["artifactKind"] = "wrong"
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        subset_path = Path(tmpdir) / "webgpu-cts-subset-receipt.json"
        subset_path.write_text(
            json.dumps(subset_receipt, indent=2) + "\n",
            encoding="utf-8",
        )
        try:
            builder.build_ledger(
                root=REPO_ROOT,
                subset_receipt_path=subset_path.relative_to(REPO_ROOT),
            )
        except ValueError as exc:
            assert "artifactKind must be webgpu_cts_subset_receipt" in str(exc)
        else:
            raise AssertionError("malformed subset receipt kind should reject ledger build")
