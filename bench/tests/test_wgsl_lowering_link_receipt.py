#!/usr/bin/env python3
"""Tests for WGSL source-to-IR-to-backend link receipts."""

from __future__ import annotations

import json
from pathlib import Path

import jsonschema

from bench.tools import build_wgsl_lowering_link_receipt as links
from bench.tools import check_wgsl_lowering_link_receipt as check_links


REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / "config" / "wgsl-browser-corpus.json"
SCHEMA_PATH = REPO_ROOT / "config" / "wgsl-lowering-link-receipt.schema.json"
SAMPLE_PATH = REPO_ROOT / "examples" / "wgsl-lowering-link-receipt.sample.json"


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _evidence_for_prefix_sum() -> dict:
    return {
        "rows": [
            {
                "shaderId": "webgpu-prefix-sum",
                "sourcePath": "bench/fixtures/wgsl-corpus/webgpu/sample-prefix-sum.wgsl",
                "sourceSha256": "a8a642a54aaca908b707d20666566db8db62dbb5c9bfd518fbe98925da22c416",
                "target": "spirv",
                "shaderStage": "compute",
                "expectedValidity": "valid",
                "doe": {
                    "status": "ok",
                    "irSha256": "3" * 64,
                    "outputSha256": "2" * 64,
                    "receiptPath": "bench/out/scratch/webgpu-prefix-sum/doe.json",
                    "validationStatus": "passed",
                },
                "comparability": {"status": "diagnostic", "reasons": ["test"]},
                "claimability": {"status": "diagnostic", "reasons": ["test"]},
            }
        ]
    }


def test_wgsl_lowering_link_receipt_binds_source_ir_and_backend_hashes() -> None:
    receipt = links.build_receipt(
        evidence=_evidence_for_prefix_sum(),
        evidence_path="bench/out/tint-compiler-evidence.json",
        manifest=_load(MANIFEST_PATH),
        manifest_path="config/wgsl-browser-corpus.json",
    )

    jsonschema.Draft202012Validator(_load(SCHEMA_PATH)).validate(receipt)
    row = receipt["rows"][0]
    assert row["linkStatus"] == "linked"
    assert row["manifestShaderId"] == "webgpu-prefix-sum"
    assert row["doeIrSha256"] == "3" * 64
    assert row["doeBackendOutputSha256"] == "2" * 64
    assert receipt["summary"]["failureCodes"] == []
    assert check_links.check_receipt(receipt) == []


def test_wgsl_lowering_link_receipt_reports_source_hash_mismatch() -> None:
    evidence = _evidence_for_prefix_sum()
    evidence["rows"][0]["sourceSha256"] = "0" * 64

    receipt = links.build_receipt(
        evidence=evidence,
        evidence_path="bench/out/tint-compiler-evidence.json",
        manifest=_load(MANIFEST_PATH),
        manifest_path="config/wgsl-browser-corpus.json",
    )

    assert receipt["rows"][0]["linkStatus"] == "diagnostic"
    assert receipt["summary"]["failureCodes"][0]["code"] == "source_hash_mismatch"


def test_wgsl_lowering_link_receipt_reports_missing_ir_hash() -> None:
    evidence = _evidence_for_prefix_sum()
    evidence["rows"][0]["doe"]["irSha256"] = None

    receipt = links.build_receipt(
        evidence=evidence,
        evidence_path="bench/out/tint-compiler-evidence.json",
        manifest=_load(MANIFEST_PATH),
        manifest_path="config/wgsl-browser-corpus.json",
    )

    codes = {item["code"] for item in receipt["summary"]["failureCodes"]}
    assert "missing_doe_ir_hash" in codes
    assert any(
        item["code"] == "lowering_link_has_diagnostic_rows"
        for item in check_links.check_receipt(receipt)
    )


def test_wgsl_lowering_link_receipt_can_match_by_source_path() -> None:
    evidence = _evidence_for_prefix_sum()
    evidence["rows"][0]["shaderId"] = "evidence-row-alias"

    receipt = links.build_receipt(
        evidence=evidence,
        evidence_path="bench/out/tint-compiler-evidence.json",
        manifest=_load(MANIFEST_PATH),
        manifest_path="config/wgsl-browser-corpus.json",
    )

    assert receipt["rows"][0]["linkStatus"] == "linked"
    assert receipt["rows"][0]["shaderId"] == "evidence-row-alias"
    assert receipt["rows"][0]["manifestShaderId"] == "webgpu-prefix-sum"


def test_wgsl_lowering_link_checker_rejects_summary_drift() -> None:
    receipt = links.build_receipt(
        evidence=_evidence_for_prefix_sum(),
        evidence_path="bench/out/tint-compiler-evidence.json",
        manifest=_load(MANIFEST_PATH),
        manifest_path="config/wgsl-browser-corpus.json",
    )
    receipt["summary"]["linkedRows"] = 0

    assert {
        "code": "summary_count_mismatch",
        "path": "summary.linkedRows",
        "message": "linkedRows must be 1",
    } in check_links.check_receipt(receipt)


def test_wgsl_lowering_link_checker_verifies_sample_files() -> None:
    assert check_links.check_receipt(_load(SAMPLE_PATH), REPO_ROOT) == []


def test_wgsl_lowering_link_checker_rejects_unsafe_source_and_receipt_paths() -> None:
    receipt = _load(SAMPLE_PATH)
    receipt["rows"][0]["sourcePath"] = "../sample-prefix-sum.wgsl"
    receipt["rows"][0]["doeReceiptPath"] = "/tmp/runtime-compile-report.json"

    failures = check_links.check_receipt(receipt, REPO_ROOT)

    assert {
        "code": "unsafe_source_path",
        "path": "rows[0].sourcePath",
        "message": "sourcePath must be repo-relative",
    } in failures
    assert {
        "code": "unsafe_doe_receipt_path",
        "path": "rows[0].doeReceiptPath",
        "message": "doeReceiptPath must be repo-relative",
    } in failures


def test_wgsl_lowering_link_checker_rejects_ambiguous_path_segments() -> None:
    receipt = _load(SAMPLE_PATH)
    receipt["rows"][0]["sourcePath"] = "bench//fixtures/sample-prefix-sum.wgsl"
    receipt["rows"][0]["doeReceiptPath"] = "examples\\runtime-compile-report.sample.json"

    failures = check_links.check_receipt(receipt, REPO_ROOT)

    assert any(item["code"] == "unsafe_source_path" for item in failures)
    assert any(item["code"] == "unsafe_doe_receipt_path" for item in failures)
