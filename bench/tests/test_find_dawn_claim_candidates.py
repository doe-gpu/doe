#!/usr/bin/env python3
"""Tests for Dawn claim candidate auditing."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path
from typing import Any

from bench.tools import find_dawn_claim_candidates as candidate_audit


def _write_json(root: Path, rel_path: str, payload: dict[str, Any]) -> None:
    path = root / rel_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _frontier(
    *,
    native_vulkan_claim_allowed: bool = True,
    wgsl_tint_claim_allowed: bool = True,
) -> dict[str, Any]:
    return {
        "rows": [
            {"id": "native-metal-runtime", "claimAllowed": True},
            {
                "id": "native-vulkan-runtime",
                "claimAllowed": native_vulkan_claim_allowed,
                "blockers": ["fresh_amd_vulkan_release_claim_artifact"],
            },
            {
                "id": "wgsl-tint-compiler",
                "claimAllowed": wgsl_tint_claim_allowed,
                "blockers": ["claimable_tint_compiler_evidence_report"],
            },
        ]
    }


def _claim(
    report_path: str,
    *,
    pass_value: bool = True,
    claim_status: str = "claimable",
    comparison_status: str = "comparable",
) -> dict[str, Any]:
    return {
        "artifactKind": "claim-report",
        "schemaVersion": 1,
        "comparisonStatus": comparison_status,
        "claimStatus": claim_status,
        "pass": pass_value,
        "compareReport": {"path": report_path},
    }


def _compare() -> dict[str, Any]:
    return {
        "artifactKind": "compare-report",
        "schemaVersion": 1,
        "comparisonStatus": "comparable",
    }


def test_audit_marks_indexed_claim_sidecars() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        claim_path = "bench/out/apple-metal/compare/run/dawn-vs-doe.apple.metal.claim.json"
        report_path = "bench/out/apple-metal/compare/run/dawn-vs-doe.apple.metal.compare.json"
        _write_json(root, claim_path, _claim(report_path))
        _write_json(root, report_path, _compare())
        claim_index = {
            "entries": [
                {
                    "id": "native-strict-apple-metal",
                    "claimState": "claim-indexed",
                    "claimPath": claim_path,
                    "reportPath": report_path,
                }
            ]
        }

        report = candidate_audit.build_audit(root, claim_index, _frontier())

        assert report["summary"]["alreadyIndexedCount"] == 1
        assert report["candidates"][0]["promotionStatus"] == "already_indexed"
        assert report["candidates"][0]["indexReady"] is False


def test_audit_finds_unindexed_vulkan_candidate() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        claim_path = "bench/out/amd-vulkan/release/dawn-vs-doe.amd.vulkan.claim.json"
        report_path = "bench/out/amd-vulkan/release/dawn-vs-doe.amd.vulkan.compare.json"
        _write_json(root, claim_path, _claim(report_path))
        _write_json(root, report_path, _compare())

        report = candidate_audit.build_audit(root, {"entries": []}, _frontier())

        assert report["summary"]["indexReadyCount"] == 1
        candidate = report["candidates"][0]
        assert candidate["promotionStatus"] == "index_ready"
        assert candidate["reasons"] == []
        assert candidate["inferredFrontierRows"] == [
            {
                "id": "native-vulkan-runtime",
                "reason": "path-or-target mentions Vulkan",
            }
        ]


def test_audit_blocks_scratch_candidates() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        claim_path = "bench/out/scratch/run/dawn-vs-doe.amd.vulkan.claim.json"
        report_path = "bench/out/scratch/run/dawn-vs-doe.amd.vulkan.compare.json"
        _write_json(root, claim_path, _claim(report_path))
        _write_json(root, report_path, _compare())

        report = candidate_audit.build_audit(root, {"entries": []}, _frontier())

        candidate = report["candidates"][0]
        assert candidate["promotionStatus"] == "blocked"
        assert candidate["indexReady"] is False
        assert candidate["reasons"] == ["scratch_artifact"]


def test_audit_blocks_candidates_for_nonclaimable_frontier_rows() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        claim_path = "bench/out/amd-vulkan/release/dawn-vs-doe.amd.vulkan.claim.json"
        report_path = "bench/out/amd-vulkan/release/dawn-vs-doe.amd.vulkan.compare.json"
        _write_json(root, claim_path, _claim(report_path))
        _write_json(root, report_path, _compare())

        report = candidate_audit.build_audit(
            root,
            {"entries": []},
            _frontier(native_vulkan_claim_allowed=False),
        )

        candidate = report["candidates"][0]
        assert candidate["promotionStatus"] == "blocked"
        assert candidate["indexReady"] is False
        assert candidate["reasons"] == [
            "frontier_row_not_claim_allowed:native-vulkan-runtime"
        ]
        assert candidate["frontierBlockers"] == [
            {
                "id": "native-vulkan-runtime",
                "blockers": ["fresh_amd_vulkan_release_claim_artifact"],
            }
        ]


def test_audit_blocks_claimable_compiler_sidecar_without_compare_report() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        claim_path = "bench/out/compilation/doe-vs-tint.msl.claim.json"
        _write_json(
            root,
            claim_path,
            {
                "artifactKind": "claim-report",
                "schemaVersion": 1,
                "target": "msl",
                "comparisonStatus": "comparable",
                "claimStatus": "claimable",
                "pass": True,
            },
        )

        report = candidate_audit.build_audit(root, {"entries": []}, _frontier())

        candidate = report["candidates"][0]
        assert candidate["promotionStatus"] == "blocked"
        assert candidate["reasons"] == ["missing_compare_report_path"]
        assert candidate["inferredFrontierRows"] == [
            {
                "id": "wgsl-tint-compiler",
                "reason": "path-or-target mentions Tint/compiler output",
            }
        ]
