#!/usr/bin/env python3
"""Claim-index browser release receipt regressions."""

from __future__ import annotations

import hashlib
import json
import tempfile
from pathlib import Path

from bench.browser.browser_gate import stable_hash
from bench.gates import claim_index_gate as gate
from bench.tests.test_claim_index_gate import (
    _browser_chromium_entry,
    _browser_release_paths,
    _index,
    _schema,
    _write_artifacts,
    _write_browser_release_artifacts,
    _write_json,
)


def _refresh_smoke_report_hashes(report: dict) -> None:
    previous_hash = None
    for row in report["modeResults"]:
        entry = {
            key: value
            for key, value in row.items()
            if key not in {"previousHash", "hash"}
        }
        row["previousHash"] = previous_hash
        row["hash"] = stable_hash(
            {
                "previousHash": previous_hash,
                "entry": entry,
            }
        )
        previous_hash = row["hash"]
    report["reportHash"] = stable_hash(
        {
            key: value
            for key, value in report.items()
            if key != "reportHash"
        }
    )


def _refresh_proof_surface_receipt_ref(proof_surface: dict, receipt_ref: dict) -> None:
    receipt_id = receipt_ref["receiptId"]
    for row in proof_surface["proofPage"]["receiptPayloads"]:
        if row.get("receiptId") == receipt_id:
            row.update(receipt_ref)
    for gallery in proof_surface["galleryPages"]:
        for row in gallery.get("receiptArtifacts", []):
            if row.get("receiptId") == receipt_id:
                row.update(receipt_ref)
    for comparison in proof_surface["comparisonReceipts"]:
        for field in ("dawnReceipt", "doeReceipt"):
            row = comparison.get(field)
            if isinstance(row, dict) and row.get("receiptId") == receipt_id:
                row.update(receipt_ref)


def test_browser_chromium_claim_indexed_release_requires_public_gallery_receipts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-public-gallery-compute.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["contentSha256"] = "0" * 64
        _write_json(receipt_path, receipt)

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["galleryPages"][0]["publicReceipt"]["sha256"] = hashlib.sha256(
            receipt_path.read_bytes()
        ).hexdigest()
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_public_gallery_receipt_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_public_gallery_visible_evidence() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        gallery_path = root / "bench/out/unit/browser-gallery-compute.html"
        gallery_path.write_text(
            "<html><body>compute Doe WebGPU receipt gallery</body></html>",
            encoding="utf-8",
        )

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        row = proof_surface["galleryPages"][0]
        row["artifact"]["sha256"] = hashlib.sha256(gallery_path.read_bytes()).hexdigest()

        receipt_path = root / "bench/out/unit/browser-public-gallery-compute.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["contentSha256"] = row["artifact"]["sha256"]
        receipt["contentLengthBytes"] = gallery_path.stat().st_size
        _write_json(receipt_path, receipt)
        row["publicReceipt"]["sha256"] = hashlib.sha256(receipt_path.read_bytes()).hexdigest()
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_public_gallery_content_incomplete" in codes


def test_browser_chromium_claim_indexed_release_binds_gallery_receipt_ids_to_artifacts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        row = proof_surface["galleryPages"][0]
        row["receiptIds"] = ["unit-compute-other"]

        gallery_path = root / row["artifact"]["path"]
        gallery_text = gallery_path.read_text(encoding="utf-8").replace(
            "unit-compute-doe",
            "unit-compute-other",
        )
        gallery_path.write_text(gallery_text, encoding="utf-8")
        row["artifact"]["sha256"] = hashlib.sha256(gallery_path.read_bytes()).hexdigest()

        public_receipt_path = root / row["publicReceipt"]["path"]
        public_receipt = json.loads(public_receipt_path.read_text(encoding="utf-8"))
        public_receipt["contentSha256"] = row["artifact"]["sha256"]
        public_receipt["contentLengthBytes"] = gallery_path.stat().st_size
        public_receipt["receiptIds"] = row["receiptIds"]
        _write_json(public_receipt_path, public_receipt)
        row["publicReceipt"]["sha256"] = hashlib.sha256(public_receipt_path.read_bytes()).hexdigest()

        proof_page_path = root / "bench/out/unit/browser-proof-page.html"
        proof_page_text = proof_page_path.read_text(encoding="utf-8") + " unit-compute-other"
        proof_page_path.write_text(proof_page_text, encoding="utf-8")
        proof_page_sha = hashlib.sha256(proof_page_path.read_bytes()).hexdigest()

        receipt_path = root / "bench/out/unit/browser-proof-page-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["contentSha256"] = proof_page_sha
        receipt["contentLengthBytes"] = proof_page_path.stat().st_size
        receipt["recentReceiptIds"].append("unit-compute-other")
        _write_json(receipt_path, receipt)
        proof_surface["proofPage"]["artifact"]["sha256"] = proof_page_sha
        proof_surface["proofPage"]["recentReceiptIds"].append("unit-compute-other")
        proof_surface["proofPage"]["diagnosticReceipt"]["sha256"] = hashlib.sha256(
            receipt_path.read_bytes()
        ).hexdigest()
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_gallery_receipt_mismatch" in codes


def test_browser_chromium_claim_indexed_release_rejects_duplicate_gallery_receipt_artifacts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        row = proof_surface["galleryPages"][0]
        row["receiptIds"].append(row["receiptIds"][0])
        row["receiptArtifacts"].append(dict(row["receiptArtifacts"][0]))

        public_receipt_path = root / row["publicReceipt"]["path"]
        public_receipt = json.loads(public_receipt_path.read_text(encoding="utf-8"))
        public_receipt["receiptIds"] = row["receiptIds"]
        public_receipt["receiptArtifactPaths"] = [
            artifact["path"] for artifact in row["receiptArtifacts"]
        ]
        _write_json(public_receipt_path, public_receipt)
        row["publicReceipt"]["sha256"] = hashlib.sha256(
            public_receipt_path.read_bytes()
        ).hexdigest()

        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_proof_surface_gallery_receipt_duplicate",
        "path": "entries[0].browserRelease.proofSurfacePath",
        "message": "gallery receipt IDs and artifact paths must uniquely identify execution receipts",
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_binds_gallery_workload_ids_to_receipts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        row = proof_surface["galleryPages"][0]
        row["workloadIds"] = ["unit-other-workload"]

        gallery_path = root / row["artifact"]["path"]
        gallery_text = gallery_path.read_text(encoding="utf-8") + " unit-other-workload"
        gallery_path.write_text(gallery_text, encoding="utf-8")
        row["artifact"]["sha256"] = hashlib.sha256(gallery_path.read_bytes()).hexdigest()

        public_receipt_path = root / row["publicReceipt"]["path"]
        public_receipt = json.loads(public_receipt_path.read_text(encoding="utf-8"))
        public_receipt["contentSha256"] = row["artifact"]["sha256"]
        public_receipt["contentLengthBytes"] = gallery_path.stat().st_size
        public_receipt["workloadIds"] = row["workloadIds"]
        _write_json(public_receipt_path, public_receipt)
        row["publicReceipt"]["sha256"] = hashlib.sha256(public_receipt_path.read_bytes()).hexdigest()

        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_gallery_workload_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_gallery_receipts_in_recent_proof_page() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["recentReceiptIds"].remove("unit-tensor-doe")
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_recent_receipts_incomplete" in codes


def test_browser_chromium_claim_indexed_release_requires_recent_gallery_receipt_links() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_page_path = root / "bench/out/unit/browser-proof-page.html"
        proof_page_text = proof_page_path.read_text(encoding="utf-8").replace(
            "bench/out/unit/browser-tensor-execution-receipt.json",
            "",
        )
        proof_page_path.write_text(proof_page_text, encoding="utf-8")
        proof_page_sha = hashlib.sha256(proof_page_path.read_bytes()).hexdigest()

        receipt_path = root / "bench/out/unit/browser-proof-page-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["contentSha256"] = proof_page_sha
        receipt["contentLengthBytes"] = proof_page_path.stat().st_size
        _write_json(receipt_path, receipt)

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["artifact"]["sha256"] = proof_page_sha
        proof_surface["proofPage"]["diagnosticReceipt"]["sha256"] = hashlib.sha256(
            receipt_path.read_bytes()
        ).hexdigest()
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_proof_page_content_incomplete" in codes


def test_browser_chromium_claim_indexed_release_rejects_unbacked_recent_receipt_ids() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_page_path = root / "bench/out/unit/browser-proof-page.html"
        proof_page_text = proof_page_path.read_text(encoding="utf-8") + " unit-phantom-receipt"
        proof_page_path.write_text(proof_page_text, encoding="utf-8")
        proof_page_sha = hashlib.sha256(proof_page_path.read_bytes()).hexdigest()

        receipt_path = root / "bench/out/unit/browser-proof-page-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["contentSha256"] = proof_page_sha
        receipt["contentLengthBytes"] = proof_page_path.stat().st_size
        receipt["recentReceiptIds"].append("unit-phantom-receipt")
        _write_json(receipt_path, receipt)

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["artifact"]["sha256"] = proof_page_sha
        proof_surface["proofPage"]["recentReceiptIds"].append("unit-phantom-receipt")
        proof_surface["proofPage"]["diagnosticReceipt"]["sha256"] = hashlib.sha256(
            receipt_path.read_bytes()
        ).hexdigest()
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_recent_receipts_unlinked" in codes


def test_browser_chromium_claim_indexed_release_requires_same_page_gallery_comparison_evidence() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        gallery_path = root / "bench/out/unit/browser-gallery-compute.html"
        gallery_path.write_text(
            "<html><body>compute Doe WebGPU receipt gallery "
            "browser/chromium/contracts/browser-benchmark-superset.contract.md "
            "unit-compute unit-compute-doe "
            "bench/out/unit/browser-compute-execution-receipt.json</body></html>",
            encoding="utf-8",
        )

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        row = proof_surface["galleryPages"][0]
        row["artifact"]["sha256"] = hashlib.sha256(gallery_path.read_bytes()).hexdigest()

        receipt_path = root / "bench/out/unit/browser-public-gallery-compute.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["contentSha256"] = row["artifact"]["sha256"]
        receipt["contentLengthBytes"] = gallery_path.stat().st_size
        _write_json(receipt_path, receipt)
        row["publicReceipt"]["sha256"] = hashlib.sha256(receipt_path.read_bytes()).hexdigest()
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_content_incomplete" in codes


def test_browser_chromium_claim_indexed_release_requires_hash_bound_comparison_artifact() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        comparison_path = root / "bench/out/unit/browser-smoke-report.json"
        comparison = json.loads(comparison_path.read_text(encoding="utf-8"))
        comparison["mode"] = "dawn"
        _write_json(comparison_path, comparison)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_artifact_hash_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_strict_comparison_artifact_hash_chain() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        comparison_path = root / "bench/out/unit/browser-smoke-report.json"
        comparison = json.loads(comparison_path.read_text(encoding="utf-8"))
        comparison["modeResults"][1]["hash"] = "0" * 64
        _write_json(comparison_path, comparison)
        comparison_sha = hashlib.sha256(comparison_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["comparisonReceipts"][0]["comparisonArtifact"][
            "sha256"
        ] = comparison_sha
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_artifact_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_comparison_artifact_release_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        comparison_path = root / "bench/out/unit/browser-smoke-report.json"
        comparison = json.loads(comparison_path.read_text(encoding="utf-8"))
        comparison["runtimeSelections"][1]["artifactIdentity"]["doeLibSha256"] = "0" * 64
        comparison["reportHash"] = stable_hash(
            {key: value for key, value in comparison.items() if key != "reportHash"}
        )
        _write_json(comparison_path, comparison)
        comparison_sha = hashlib.sha256(comparison_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["comparisonReceipts"][0]["comparisonArtifact"][
            "sha256"
        ] = comparison_sha
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_artifact_release_mismatch" in codes


def test_browser_chromium_claim_indexed_release_binds_comparison_mode_result_to_receipts() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)

        comparison_path = root / "bench/out/unit/browser-smoke-report.json"
        comparison = json.loads(comparison_path.read_text(encoding="utf-8"))
        comparison["modeResults"][1]["runtimeSelection"]["profile"][
            "driver"
        ] = "unit-other-driver"
        _refresh_smoke_report_hashes(comparison)
        _write_json(comparison_path, comparison)
        comparison_sha = hashlib.sha256(comparison_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["comparisonReceipts"][0]["comparisonArtifact"][
            "sha256"
        ] = comparison_sha

        for rel_path in (
            "bench/out/unit/browser-dawn-execution-receipt.json",
            "bench/out/unit/browser-doe-execution-receipt.json",
        ):
            receipt_path = root / rel_path
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            receipt["commandGraph"]["artifactSha256"] = comparison_sha
            _write_json(receipt_path, receipt)
            _refresh_proof_surface_receipt_ref(
                proof_surface,
                {
                    "receiptId": receipt["receiptId"],
                    "path": rel_path,
                    "sha256": hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
                    "kind": "browser_execution_receipt",
                },
            )

        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    assert {
        "code": "browser_release_proof_surface_comparison_payload_mismatch",
        "path": "entries[0].browserRelease.proofSurfacePath",
        "message": (
            "comparison artifact Doe modeResult runtimeSelection.profile.driver "
            "must match Doe execution receipt driver.driver"
        ),
    } in result["failures"]


def test_browser_chromium_claim_indexed_release_requires_receipts_to_bind_comparison_artifact() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-doe-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["commandGraph"]["artifactPath"] = "bench/out/unit/other-smoke-report.json"
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["receiptPayloads"][1]["sha256"] = receipt_sha
        proof_surface["comparisonReceipts"][0]["doeReceipt"]["sha256"] = receipt_sha
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_payload_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_receipt_command_evidence_artifact_hash() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-doe-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["commandGraph"]["artifactSha256"] = "0" * 64
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["receiptPayloads"][1]["sha256"] = receipt_sha
        proof_surface["comparisonReceipts"][0]["doeReceipt"]["sha256"] = receipt_sha
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_payload_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_proof_page_receipt() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-proof-page-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["diagnostics"]["activeBackend"] = "webgpu-other"
        _write_json(receipt_path, receipt)

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["diagnosticReceipt"]["sha256"] = hashlib.sha256(
            receipt_path.read_bytes()
        ).hexdigest()
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_proof_page_receipt_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_execution_receipt_driver_parity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-doe-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["driver"]["driver"] = "different-driver"
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["receiptPayloads"][1]["sha256"] = receipt_sha
        proof_surface["comparisonReceipts"][0]["doeReceipt"]["sha256"] = receipt_sha
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_payload_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_execution_receipt_workload_parity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-doe-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["workloadId"] = "unit-other-workload"
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["receiptPayloads"][1]["sha256"] = receipt_sha
        proof_surface["comparisonReceipts"][0]["doeReceipt"]["sha256"] = receipt_sha
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_payload_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_execution_receipt_command_evidence_parity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-doe-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["commandGraph"]["graphSha256"] = "7" * 64
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["receiptPayloads"][1]["sha256"] = receipt_sha
        proof_surface["comparisonReceipts"][0]["doeReceipt"]["sha256"] = receipt_sha
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_payload_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_execution_receipt_output_kind_parity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-doe-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["frameHash"] = receipt.pop("outputHash")
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["receiptPayloads"][1]["sha256"] = receipt_sha
        proof_surface["comparisonReceipts"][0]["doeReceipt"]["sha256"] = receipt_sha
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_payload_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_comparison_policy_output_identity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["comparisonReceipts"][0]["comparisonPolicy"][
            "outputIdentity"
        ] = "same_frame_hash"
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_payload_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_execution_receipt_entry_point_parity() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-doe-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["sourceShader"]["entryPoint"] = "other_entry"
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["receiptPayloads"][1]["sha256"] = receipt_sha
        proof_surface["comparisonReceipts"][0]["doeReceipt"]["sha256"] = receipt_sha
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_comparison_payload_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_receipt_backend_runtime_binding() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-doe-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["backend"] = "webgpu-other"
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["receiptPayloads"][1]["sha256"] = receipt_sha
        proof_surface["comparisonReceipts"][0]["doeReceipt"]["sha256"] = receipt_sha
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_receipt_backend_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_receipt_lowering_runtime_binding() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-doe-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["loweringPath"] = ["wgsl", "tint", "dawn-native"]
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["receiptPayloads"][1]["sha256"] = receipt_sha
        proof_surface["comparisonReceipts"][0]["doeReceipt"]["sha256"] = receipt_sha
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_receipt_lowering_mismatch" in codes


def test_browser_chromium_claim_indexed_release_rejects_conflicting_receipt_references() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        duplicate_ref = dict(proof_surface["proofPage"]["receiptPayloads"][1])
        duplicate_ref["receiptId"] = "unit-conflicting-doe-receipt"
        proof_surface["proofPage"]["receiptPayloads"].append(duplicate_ref)
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_receipt_reference_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_complete_execution_receipt_command_coverage() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-tensor-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["commandCoverage"]["successCount"] = 0
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        for row in proof_surface["galleryPages"]:
            if row["category"] == "tensor":
                row["receiptArtifacts"][0]["sha256"] = receipt_sha
                break
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_receipt_incomplete" in codes


def test_browser_chromium_claim_indexed_release_rejects_execution_receipt_hidden_fallback() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-tensor-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["runtimeSelectorState"]["fallbackApplied"] = True
        receipt["runtimeSelectorState"]["fallbackReasonCode"] = "selector-fallback"
        receipt["fallbackState"]["hiddenFallbackAllowed"] = True
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        for row in proof_surface["galleryPages"]:
            if row["category"] == "tensor":
                row["receiptArtifacts"][0]["sha256"] = receipt_sha
                break
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_receipt_hidden_fallback" in codes


def test_browser_chromium_claim_indexed_release_requires_execution_receipt_output_sha() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-tensor-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["outputHash"] = "not-a-sha256"
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        for row in proof_surface["galleryPages"]:
            if row["category"] == "tensor":
                row["receiptArtifacts"][0]["sha256"] = receipt_sha
                break
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_receipt_incomplete" in codes


def test_browser_chromium_claim_indexed_release_requires_execution_receipt_wgsl_source_metadata() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-tensor-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["sourceShader"]["language"] = "msl"
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        for row in proof_surface["galleryPages"]:
            if row["category"] == "tensor":
                row["receiptArtifacts"][0]["sha256"] = receipt_sha
                break
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_receipt_source_mismatch" in codes


def test_browser_chromium_claim_indexed_release_rejects_source_sha_alias_drift() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-tensor-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["sourceShader"]["sourceSha256"] = "0" * 64
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        for row in proof_surface["galleryPages"]:
            if row["category"] == "tensor":
                row["receiptArtifacts"][0]["sha256"] = receipt_sha
                break
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_receipt_source_mismatch" in codes


def test_browser_chromium_claim_indexed_release_requires_execution_receipt_command_evidence() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-tensor-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["commandGraph"] = {}
        receipt["flightRecorderRef"] = None
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        for row in proof_surface["galleryPages"]:
            if row["category"] == "tensor":
                row["receiptArtifacts"][0]["sha256"] = receipt_sha
                break
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_receipt_incomplete" in codes


def test_browser_chromium_claim_indexed_release_requires_numeric_execution_receipt_timing() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        receipt_path = root / "bench/out/unit/browser-tensor-execution-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["timing"]["phases"]["submitWaitNs"] = "missing"
        _write_json(receipt_path, receipt)
        receipt_sha = hashlib.sha256(receipt_path.read_bytes()).hexdigest()

        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        for row in proof_surface["galleryPages"]:
            if row["category"] == "tensor":
                row["receiptArtifacts"][0]["sha256"] = receipt_sha
                break
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_receipt_incomplete" in codes


def test_browser_chromium_claim_indexed_release_requires_proof_page_visible_diagnostics() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_page_path = root / "bench/out/unit/browser-proof-page.html"
        proof_page_path.write_text(
            "<html><body>about:doe runtime/zig/zig-out/bin/doe-zig-runtime "
            "diagnostic hidden_fallback_disabled unit-dawn-receipt unit-doe-receipt "
            "bench/out/unit/browser-dawn-execution-receipt.json "
            "bench/out/unit/browser-doe-execution-receipt.json</body></html>",
            encoding="utf-8",
        )
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["artifact"]["sha256"] = hashlib.sha256(
            proof_page_path.read_bytes()
        ).hexdigest()

        receipt_path = root / "bench/out/unit/browser-proof-page-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["contentSha256"] = proof_surface["proofPage"]["artifact"]["sha256"]
        receipt["contentLengthBytes"] = proof_page_path.stat().st_size
        _write_json(receipt_path, receipt)
        proof_surface["proofPage"]["diagnosticReceipt"]["sha256"] = hashlib.sha256(
            receipt_path.read_bytes()
        ).hexdigest()
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_proof_page_content_incomplete" in codes


def test_browser_chromium_claim_indexed_release_requires_proof_page_visible_release_provenance() -> None:
    schema = _schema()
    with tempfile.TemporaryDirectory() as tmpdir:
        root = Path(tmpdir)
        _write_artifacts(root)
        _write_browser_release_artifacts(root)
        proof_page_path = root / "bench/out/unit/browser-proof-page.html"
        proof_page_path.write_text(
            "<html><body>about:doe webgpu-doe "
            "runtime/zig/zig-out/bin/doe-zig-runtime diagnostic "
            "hidden_fallback_disabled unit-dawn-receipt unit-doe-receipt "
            "bench/out/unit/browser-dawn-execution-receipt.json "
            "bench/out/unit/browser-doe-execution-receipt.json</body></html>",
            encoding="utf-8",
        )
        proof_surface_path = root / _browser_release_paths()["proofSurfacePath"]
        proof_surface = json.loads(proof_surface_path.read_text(encoding="utf-8"))
        proof_surface["proofPage"]["artifact"]["sha256"] = hashlib.sha256(
            proof_page_path.read_bytes()
        ).hexdigest()

        receipt_path = root / "bench/out/unit/browser-proof-page-receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        receipt["contentSha256"] = proof_surface["proofPage"]["artifact"]["sha256"]
        receipt["contentLengthBytes"] = proof_page_path.stat().st_size
        _write_json(receipt_path, receipt)
        proof_surface["proofPage"]["diagnosticReceipt"]["sha256"] = hashlib.sha256(
            receipt_path.read_bytes()
        ).hexdigest()
        _write_json(proof_surface_path, proof_surface)

        result = gate.evaluate_index(
            _index(_browser_chromium_entry(claim_state="claim-indexed")),
            schema,
            root,
        )

    codes = {item["code"] for item in result["failures"]}

    assert "browser_release_proof_surface_proof_page_content_incomplete" in codes
