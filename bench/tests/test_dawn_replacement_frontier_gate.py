#!/usr/bin/env python3
"""Tests for Dawn replacement frontier gate semantics."""

from __future__ import annotations

import copy
import json
from pathlib import Path

from bench.gates import dawn_replacement_frontier_gate as frontier_gate


REPO_ROOT = Path(__file__).resolve().parents[2]
FRONTIER_PATH = REPO_ROOT / "config" / "dawn-replacement-frontier.json"
SCHEMA_PATH = REPO_ROOT / "config" / "dawn-replacement-frontier.schema.json"
CLAIM_INDEX_PATH = REPO_ROOT / "reports" / "claim-index.json"


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _evaluate(frontier: dict) -> dict:
    return frontier_gate.evaluate_frontier(
        frontier,
        _load(SCHEMA_PATH),
        _load(CLAIM_INDEX_PATH),
        REPO_ROOT,
    )


def _frontier() -> dict:
    return _load(FRONTIER_PATH)


def test_dawn_replacement_frontier_passes_gate() -> None:
    assert _evaluate(_frontier())["ok"] is True


def test_dawn_replacement_frontier_requires_all_rows() -> None:
    frontier = _frontier()
    frontier["rows"] = [
        row for row in frontier["rows"] if row["id"] != "native-d3d12-runtime"
    ]

    assert {
        "code": "missing_frontier_row",
        "path": "rows",
        "message": "missing Dawn replacement frontier row: native-d3d12-runtime",
    } in _evaluate(frontier)["failures"]


def test_claim_allowed_rows_require_public_claim_index_entries() -> None:
    frontier = _frontier()
    frontier["rows"][0]["claimIndexEntryIds"] = []

    assert {
        "code": "claim_allowed_missing_claim_index_entry",
        "path": "rows[0].claimIndexEntryIds",
        "message": "claim-allowed rows require at least one public claim-index entry",
    } in _evaluate(frontier)["failures"]


def test_claim_allowed_rows_require_claimable_claim_index_entries() -> None:
    frontier = _frontier()
    frontier["rows"][0]["claimIndexEntryIds"] = ["ort-browser-apple-metal"]

    failures = _evaluate(frontier)["failures"]

    assert any(
        item["code"] == "claim_index_entry_not_claimable"
        and item["path"] == "rows[0].claimIndexEntryIds[0]"
        for item in failures
    )


def test_nonclaim_rows_require_blockers() -> None:
    frontier = _frontier()
    frontier["rows"][1]["blockers"] = []

    assert {
        "code": "nonclaim_row_missing_blocker",
        "path": "rows[1].blockers",
        "message": "non-claimable frontier rows require at least one blocker",
    } in _evaluate(frontier)["failures"]


def test_frontier_requires_defined_blockers() -> None:
    frontier = _frontier()
    frontier["rows"][1]["blockers"] = ["not_defined"]

    failures = _evaluate(frontier)["failures"]

    assert {
        "code": "undefined_blocker",
        "path": "rows[1].blockers[0]",
        "message": "blocker is not defined: not_defined",
    } in failures


def test_frontier_rejects_unused_blocker_definitions() -> None:
    frontier = _frontier()
    frontier["blockerDefinitions"].append(
        {
            "code": "unused_blocker",
            "exitCriteria": "This blocker is not attached to any frontier row.",
            "evidencePaths": ["config/dawn-replacement-frontier.json"],
        }
    )

    assert {
        "code": "unused_blocker_definition",
        "path": "blockerDefinitions",
        "message": "blocker definition is not referenced by any row: unused_blocker",
    } in _evaluate(frontier)["failures"]


def test_frontier_rejects_excluded_scope_terms() -> None:
    frontier = _frontier()
    frontier["rows"][1]["blockers"] = ["cerebras_hardware_receipt"]

    failures = _evaluate(frontier)["failures"]

    assert any(
        item["code"] == "excluded_frontier_scope"
        and item["path"] == "rows[1].blockers[0]"
        for item in failures
    )


def test_frontier_requires_existing_evidence_paths() -> None:
    frontier = _frontier()
    frontier["rows"][1]["evidencePaths"] = ["docs/missing-dawn-proof.md"]

    assert {
        "code": "evidence_path_missing",
        "path": "rows[1].evidencePaths[0]",
        "message": "evidence path does not exist: docs/missing-dawn-proof.md",
    } in _evaluate(frontier)["failures"]


def test_universal_claim_cannot_overstate_frontier() -> None:
    frontier = copy.deepcopy(_frontier())
    frontier["universalClaim"] = {
        "allowed": True,
        "reasonCode": ""
    }

    assert {
        "code": "universal_claim_overstates_frontier",
        "path": "universalClaim.allowed",
        "message": (
            "universal Dawn replacement claims require every product frontier row "
            "to be claim-allowed and every evidence-release row to be covered or "
            "claimable"
        ),
    } in _evaluate(frontier)["failures"]
