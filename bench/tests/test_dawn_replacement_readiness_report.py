#!/usr/bin/env python3
"""Tests for the Dawn replacement readiness report builder."""

from __future__ import annotations

import json
import tempfile
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


def test_browser_readiness_uses_frontier_bundle_blockers() -> None:
    report = _report()
    browser_row = next(row for row in report["rows"] if row["id"] == "browser-chromium-runtime")
    blocker_codes = [blocker["code"] for blocker in browser_row["blockers"]]
    bundle_evidence = browser_row["frontierBundleEvidence"]
    release_bundle = bundle_evidence["componentReceipts"]["releaseArtifactBundle"]

    assert browser_row["readinessStatus"] == "blocked"
    assert blocker_codes == ["chromium_release_build_evidence"]
    assert bundle_evidence["path"] == "examples/browser-runtime-frontier-bundle.sample.json"
    assert bundle_evidence["status"] == "pass"
    assert bundle_evidence["claimabilityStatus"] == "blocked"
    assert bundle_evidence["claimBlockerSummary"] == [
        {
            "code": "chromium_release_build_evidence",
            "message": "browser release artifact bundle must be a release_candidate",
            "count": 1,
        }
    ]
    assert release_bundle["releaseStatus"] == "diagnostic"
    assert release_bundle["artifactVerification"] == {
        "requiredForClaimable": True,
        "verifyFilesRootProvided": False,
        "verified": False,
    }


def test_compiler_readiness_uses_frontier_bundle_blockers() -> None:
    report = _report()
    compiler_row = next(row for row in report["rows"] if row["id"] == "wgsl-tint-compiler")
    blocker_codes = [blocker["code"] for blocker in compiler_row["blockers"]]
    bundle_evidence = compiler_row["frontierBundleEvidence"]
    target_validations = bundle_evidence["componentReceipts"]["targetValidations"]

    assert compiler_row["readinessStatus"] == "blocked"
    assert blocker_codes == [
        "claimable_tint_compiler_evidence_report",
        "shader_artifact_validation_for_target_backends",
    ]
    assert bundle_evidence["path"] == "examples/tint-compiler-frontier-bundle.sample.json"
    assert bundle_evidence["status"] == "pass"
    assert bundle_evidence["claimabilityStatus"] == "blocked"
    assert [
        blocker["code"]
        for blocker in bundle_evidence["claimBlockers"]
    ] == [
        "claimable_tint_compiler_evidence_report",
        "claimable_tint_compiler_evidence_report",
        "shader_artifact_validation_for_target_backends",
    ]
    assert bundle_evidence["compilerEvidenceReports"][0]["claimBlockerSummary"] == [
        {
            "code": "claimable_tint_compiler_evidence_report",
            "message": "compiler evidence must be comparable before it can support a Tint replacement claim",
            "count": 1,
        },
        {
            "code": "claimable_tint_compiler_evidence_report",
            "message": "compiler evidence must be claimable before it can support a Tint replacement claim",
            "count": 1,
        },
    ]
    assert target_validations[0]["claimBlockerSummary"] == [
        {
            "code": "tint_result_not_ok",
            "message": "Tint compiler result is not ok: sample_missing_tint_run",
            "count": 1,
        }
    ]
    assert target_validations[0]["claimBlockerSummaryByEvidencePath"] == [
        {
            "evidencePath": "examples/tint-compiler-evidence.sample.json",
            "claimBlockerSummary": [
                {
                    "code": "tint_result_not_ok",
                    "message": "Tint compiler result is not ok: sample_missing_tint_run",
                    "count": 1,
                }
            ],
        }
    ]


def test_compiler_readiness_can_use_custom_frontier_bundle_path() -> None:
    with tempfile.TemporaryDirectory(dir=REPO_ROOT) as tmpdir:
        custom_path = Path(tmpdir) / "compiler-frontier.json"
        custom_rel = custom_path.relative_to(REPO_ROOT)
        bundle = _load(REPO_ROOT / "examples" / "tint-compiler-frontier-bundle.sample.json")
        bundle["claimBlockers"] = [
            blocker
            for blocker in bundle["claimBlockers"]
            if blocker["code"] != "shader_artifact_validation_for_target_backends"
        ]
        bundle["summary"]["claimBlockerCount"] = len(bundle["claimBlockers"])
        target_validation = bundle["componentReceipts"]["targetValidations"][0]
        target_validation["summary"]["claimBlockerCount"] = 0
        target_validation["claimBlockerSummary"] = []
        target_validation["claimBlockerSummaryByEvidencePath"] = [
            {
                "evidencePath": "examples/tint-compiler-evidence.sample.json",
                "claimBlockerSummary": [],
            }
        ]
        custom_path.write_text(json.dumps(bundle, indent=2) + "\n", encoding="utf-8")

        report = report_builder.build_report(
            _load(FRONTIER_PATH),
            _load(SCHEMA_PATH),
            _load(CLAIM_INDEX_PATH),
            REPO_ROOT,
            report_builder.frontier_bundle_config(tint_bundle_path=custom_rel),
        )

    compiler_row = next(row for row in report["rows"] if row["id"] == "wgsl-tint-compiler")
    blocker_codes = [blocker["code"] for blocker in compiler_row["blockers"]]

    assert compiler_row["frontierBundleEvidence"]["path"] == custom_rel.as_posix()
    assert blocker_codes == ["claimable_tint_compiler_evidence_report"]
