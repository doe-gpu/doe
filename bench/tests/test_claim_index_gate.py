#!/usr/bin/env python3
"""Tests for the public claim index gate."""

from __future__ import annotations

import copy
import json
import tempfile
from pathlib import Path

import jsonschema

from bench.gates import claim_index_gate as gate


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "config" / "claim-index.schema.json"
INDEX_PATH = REPO_ROOT / "reports" / "claim-index.json"


def _schema() -> dict:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def _entry() -> dict:
    return {
        "id": "unit-claim",
        "surface": "native",
        "backend": "apple-metal",
        "comparison": "doe-vs-dawn",
        "metricDirection": "lower-is-better",
        "claimState": "claim-indexed",
        "comparisonStatus": "comparable",
        "claimStatus": "claimable",
        "reportPath": "bench/out/unit/compare.json",
        "claimPath": "bench/out/unit/claim.json",
    }


def _index(entry: dict) -> dict:
    return {
        "schemaVersion": 1,
        "kind": "doe-claim-index",
        "description": "unit",
        "entries": [entry],
    }


def _write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


def _write_artifacts(root: Path, *, claim_status: str = "claimable") -> None:
    _write_json(
        root / "bench/out/unit/compare.json",
        {
            "artifactKind": "compare-report",
            "comparisonStatus": "comparable",
        },
    )
    _write_json(
        root / "bench/out/unit/claim.json",
        {
            "artifactKind": "claim-report",
            "comparisonStatus": "comparable",
            "claimStatus": claim_status,
            "pass": claim_status == "claimable",
            "compareReport": {
                "path": "bench/out/unit/compare.json",
                "sha256": "0" * 64,
            },
        },
    )


def test_tracked_claim_index_is_schema_valid_and_gate_clean() -> None:
    schema = _schema()
    payload = json.loads(INDEX_PATH.read_text(encoding="utf-8"))

    jsonschema.Draft202012Validator(schema).validate(payload)
    result = gate.evaluate_index(payload, schema, REPO_ROOT)

    assert result["ok"], result["failures"]


def test_claim_indexed_entry_requires_claim_path_and_claimable_status() -> None:
    schema = _schema()
    entry = _entry()
    entry.pop("claimPath")
    entry["claimStatus"] = "diagnostic"

    result = gate.evaluate_index(_index(entry), schema, REPO_ROOT)
    codes = {item["code"] for item in result["failures"]}

    assert "schema_validation" in codes
    assert "claim_indexed_missing_claim_path" in codes
    assert "claim_indexed_not_claimable" in codes


def test_browser_style_diagnostic_entry_cannot_be_marked_claimable() -> None:
    schema = _schema()
    entry = _entry()
    entry["id"] = "browser-unit"
    entry["surface"] = "browser-ort"
    entry["runtimeHost"] = "browser"
    entry["claimState"] = "diagnostic"
    entry["claimStatus"] = "claimable"
    entry.pop("claimPath")

    result = gate.evaluate_index(_index(entry), schema, REPO_ROOT)
    codes = {item["code"] for item in result["failures"]}

    assert "schema_validation" in codes
    assert "claimable_without_claim_indexed_state" in codes


def test_duplicate_ids_and_parent_paths_fail() -> None:
    schema = _schema()
    entry = _entry()
    duplicate = copy.deepcopy(entry)
    duplicate["reportPath"] = "../bench/out/unit/compare.json"
    payload = _index(entry)
    payload["entries"].append(duplicate)

    result = gate.evaluate_index(payload, schema, REPO_ROOT)
    codes = {item["code"] for item in result["failures"]}

    assert "duplicate_id" in codes
    assert "unsafe_report_path" in codes


def test_local_artifacts_are_checked_when_present() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)

        result = gate.evaluate_index(_index(_entry()), schema, root)

    assert result["ok"], result["failures"]
    assert result["summary"]["localReportCount"] == 1
    assert result["summary"]["localClaimCount"] == 1


def test_local_claim_status_mismatch_fails() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root, claim_status="diagnostic")

        result = gate.evaluate_index(_index(_entry()), schema, root)

    codes = {item["code"] for item in result["failures"]}

    assert "claim_status_mismatch" in codes
    assert "claim_indexed_sidecar_not_passing" in codes
