#!/usr/bin/env python3
"""Tests for the Dawn replacement readiness report builder."""

from __future__ import annotations

import json
from pathlib import Path

from bench.tools import build_dawn_replacement_readiness_report as report_builder


REPO_ROOT = Path(__file__).resolve().parents[2]
FRONTIER_PATH = REPO_ROOT / "config" / "dawn-replacement-frontier.json"
SCHEMA_PATH = REPO_ROOT / "config" / "dawn-replacement-frontier.schema.json"
CLAIM_INDEX_PATH = REPO_ROOT / "reports" / "claim-index.json"


def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _report() -> dict:
    return report_builder.build_report(
        _load(FRONTIER_PATH),
        _load(SCHEMA_PATH),
        _load(CLAIM_INDEX_PATH),
        REPO_ROOT,
    )


def test_readiness_report_uses_frontier_gate_result() -> None:
    report = _report()

    assert report["artifactKind"] == "dawn-replacement-readiness-report"
    assert report["gate"]["ok"] is True
    assert report["summary"]["frontierRowCount"] == 11
    assert report["summary"]["productRowCount"] == 10
    assert report["summary"]["claimAllowedProductRowCount"] == 3


def test_readiness_report_preserves_blocker_exit_criteria() -> None:
    report = _report()
    d3d12_row = next(row for row in report["rows"] if row["id"] == "native-d3d12-runtime")
    blocker_codes = {blocker["code"] for blocker in d3d12_row["blockers"]}

    assert d3d12_row["readinessStatus"] == "blocked"
    assert "fresh_windows_d3d12_runtime_artifact" in blocker_codes
    assert all(blocker["exitCriteria"] for blocker in d3d12_row["blockers"])


def test_readiness_report_links_claimable_rows_to_claim_index() -> None:
    report = _report()
    metal_row = next(row for row in report["rows"] if row["id"] == "native-metal-runtime")
    claim_ids = {entry["id"] for entry in metal_row["claimIndexEntries"]}

    assert metal_row["readinessStatus"] == "claimable"
    assert claim_ids == {"native-strict-apple-metal", "native-release-apple-metal"}
    assert all(entry["claimStatus"] == "claimable" for entry in metal_row["claimIndexEntries"])
