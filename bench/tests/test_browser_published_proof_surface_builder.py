#!/usr/bin/env python3
"""Tests for browser published proof-surface building."""

from __future__ import annotations

import copy
import hashlib
import json
import unittest
from pathlib import Path

import jsonschema

from bench.tools import build_browser_published_proof_surface as builder
from bench.tools import check_browser_published_proof_surface as proof_check


REPO_ROOT = Path(__file__).resolve().parents[2]
SAMPLE = REPO_ROOT / "examples" / "browser-published-proof-surface.sample.json"
SCHEMA = REPO_ROOT / "config" / "browser-published-proof-surface.schema.json"


def _sample() -> dict:
    return json.loads(SAMPLE.read_text(encoding="utf-8"))


def _gallery_entries(sample: dict) -> list[dict]:
    return [
        {
            "category": row["category"],
            "url": row["url"],
            "artifact": row["artifact"]["path"],
            "publicReceipt": row["publicReceipt"]["path"],
            "workloadContractPath": row["workloadContractPath"],
            "receiptPayloads": [artifact["path"] for artifact in row["receiptArtifacts"]],
        }
        for row in sample["galleryPages"]
    ]


def _comparison_entries(sample: dict) -> list[dict]:
    return [
        {
            "comparisonId": row["comparisonId"],
            "workloadId": row["workloadId"],
            "pageArtifactPath": row["runner"]["pageArtifactPath"],
            "comparisonArtifact": row["comparisonArtifact"]["path"],
            "dawnReceipt": row["dawnReceipt"]["path"],
            "doeReceipt": row["doeReceipt"]["path"],
        }
        for row in sample["comparisonReceipts"]
    ]


def _build_sample_surface(sample: dict) -> dict:
    proof_page = sample["proofPage"]
    return builder.build_surface(
        surface_id=sample["surfaceId"],
        capture_policy_path=sample["capturePolicyPath"],
        runtime_identity_path=sample["runtimeIdentityPath"],
        proof_artifact=Path(proof_page["artifact"]["path"]),
        proof_receipt=Path(proof_page["diagnosticReceipt"]["path"]),
        proof_receipt_payloads=[
            Path(row["path"])
            for row in proof_page["receiptPayloads"]
        ],
        gallery_entries=_gallery_entries(sample),
        comparison_entries=_comparison_entries(sample),
    )


def _write_mutated_proof_artifacts(root: Path, sample: dict, proof_text: str) -> tuple[Path, Path]:
    proof_artifact_path = root / "proof-page.html"
    proof_artifact_path.write_text(proof_text, encoding="utf-8")
    proof_receipt = copy.deepcopy(
        json.loads(
            (REPO_ROOT / sample["proofPage"]["diagnosticReceipt"]["path"]).read_text(
                encoding="utf-8"
            )
        )
    )
    proof_receipt["proofArtifactPath"] = str(proof_artifact_path)
    proof_receipt["contentSha256"] = hashlib.sha256(
        proof_artifact_path.read_bytes()
    ).hexdigest()
    proof_receipt["contentLengthBytes"] = proof_artifact_path.stat().st_size
    proof_receipt_path = root / "proof-page-receipt.json"
    proof_receipt_path.write_text(
        json.dumps(proof_receipt, indent=2) + "\n",
        encoding="utf-8",
    )
    return proof_artifact_path, proof_receipt_path


def _write_mutated_gallery_artifacts(root: Path, gallery: dict, gallery_text: str) -> tuple[Path, Path]:
    gallery_artifact_path = root / "gallery.html"
    gallery_artifact_path.write_text(gallery_text, encoding="utf-8")
    public_receipt = copy.deepcopy(
        json.loads(
            (REPO_ROOT / gallery["publicReceipt"]["path"]).read_text(
                encoding="utf-8"
            )
        )
    )
    public_receipt["galleryArtifactPath"] = str(gallery_artifact_path)
    public_receipt["contentSha256"] = hashlib.sha256(
        gallery_artifact_path.read_bytes()
    ).hexdigest()
    public_receipt["contentLengthBytes"] = gallery_artifact_path.stat().st_size
    public_receipt_path = root / "gallery-public-receipt.json"
    public_receipt_path.write_text(
        json.dumps(public_receipt, indent=2) + "\n",
        encoding="utf-8",
    )
    return gallery_artifact_path, public_receipt_path


class BrowserPublishedProofSurfaceBuilderTests(unittest.TestCase):
    def test_builder_reconstructs_checked_in_sample(self) -> None:
        sample = _sample()

        surface = _build_sample_surface(sample)

        self.assertEqual(surface, sample)
        jsonschema.validate(surface, json.loads(SCHEMA.read_text(encoding="utf-8")))
        self.assertEqual(
            proof_check.check_surface(surface, verify_files_root=REPO_ROOT, root=REPO_ROOT),
            [],
        )

    def test_builder_rejects_stale_proof_page_receipt_hash(self) -> None:
        import tempfile

        sample = _sample()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt = copy.deepcopy(
                json.loads(
                    (REPO_ROOT / sample["proofPage"]["diagnosticReceipt"]["path"]).read_text(
                        encoding="utf-8"
                    )
                )
            )
            receipt["contentSha256"] = "0" * 64
            receipt_path = root / "proof-page-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "contentSha256"):
                builder.build_proof_page(
                    proof_artifact=REPO_ROOT / sample["proofPage"]["artifact"]["path"],
                    proof_receipt=receipt_path,
                    runtime_identity_path=sample["runtimeIdentityPath"],
                    receipt_payloads=[
                        REPO_ROOT / row["path"]
                        for row in sample["proofPage"]["receiptPayloads"]
                    ],
                )

    def test_builder_rejects_failed_proof_page_receipt_status(self) -> None:
        import tempfile

        sample = _sample()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt = copy.deepcopy(
                json.loads(
                    (REPO_ROOT / sample["proofPage"]["diagnosticReceipt"]["path"]).read_text(
                        encoding="utf-8"
                    )
                )
            )
            receipt["status"] = "failed"
            receipt_path = root / "proof-page-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "status must be loaded"):
                builder.build_proof_page(
                    proof_artifact=REPO_ROOT / sample["proofPage"]["artifact"]["path"],
                    proof_receipt=receipt_path,
                    runtime_identity_path=sample["runtimeIdentityPath"],
                    receipt_payloads=[
                        REPO_ROOT / row["path"]
                        for row in sample["proofPage"]["receiptPayloads"]
                    ],
                )

    def test_builder_rejects_wrong_proof_page_receipt_load_type(self) -> None:
        import tempfile

        sample = _sample()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt = copy.deepcopy(
                json.loads(
                    (REPO_ROOT / sample["proofPage"]["diagnosticReceipt"]["path"]).read_text(
                        encoding="utf-8"
                    )
                )
            )
            receipt["loadType"] = "file"
            receipt_path = root / "proof-page-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "loadType must be browser_internal_page"):
                builder.build_proof_page(
                    proof_artifact=REPO_ROOT / sample["proofPage"]["artifact"]["path"],
                    proof_receipt=receipt_path,
                    runtime_identity_path=sample["runtimeIdentityPath"],
                    receipt_payloads=[
                        REPO_ROOT / row["path"]
                        for row in sample["proofPage"]["receiptPayloads"]
                    ],
                )

    def test_builder_rejects_unlinked_proof_page_recent_receipt(self) -> None:
        import tempfile

        sample = _sample()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt = copy.deepcopy(
                json.loads(
                    (REPO_ROOT / sample["proofPage"]["diagnosticReceipt"]["path"]).read_text(
                        encoding="utf-8"
                    )
                )
            )
            receipt["recentReceiptIds"] = ["not-linked"]
            receipt_path = root / "proof-page-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "recentReceiptIds must match"):
                builder.build_proof_page(
                    proof_artifact=REPO_ROOT / sample["proofPage"]["artifact"]["path"],
                    proof_receipt=receipt_path,
                    runtime_identity_path=sample["runtimeIdentityPath"],
                    receipt_payloads=[
                        REPO_ROOT / row["path"]
                        for row in sample["proofPage"]["receiptPayloads"]
                    ],
                )

    def test_builder_rejects_proof_page_active_backend_drift(self) -> None:
        import tempfile

        sample = _sample()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt = copy.deepcopy(
                json.loads(
                    (REPO_ROOT / sample["proofPage"]["diagnosticReceipt"]["path"]).read_text(
                        encoding="utf-8"
                    )
                )
            )
            receipt["diagnostics"]["activeBackend"] = "webgpu"
            receipt_path = root / "proof-page-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "activeBackend"):
                builder.build_proof_page(
                    proof_artifact=REPO_ROOT / sample["proofPage"]["artifact"]["path"],
                    proof_receipt=receipt_path,
                    runtime_identity_path=sample["runtimeIdentityPath"],
                    receipt_payloads=[
                        REPO_ROOT / row["path"]
                        for row in sample["proofPage"]["receiptPayloads"]
                    ],
                )

    def test_builder_rejects_proof_page_webgpu_unavailable(self) -> None:
        import tempfile

        sample = _sample()
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt = copy.deepcopy(
                json.loads(
                    (REPO_ROOT / sample["proofPage"]["diagnosticReceipt"]["path"]).read_text(
                        encoding="utf-8"
                    )
                )
            )
            receipt["diagnostics"]["webgpuAvailable"] = False
            receipt_path = root / "proof-page-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "webgpuAvailable"):
                builder.build_proof_page(
                    proof_artifact=REPO_ROOT / sample["proofPage"]["artifact"]["path"],
                    proof_receipt=receipt_path,
                    runtime_identity_path=sample["runtimeIdentityPath"],
                    receipt_payloads=[
                        REPO_ROOT / row["path"]
                        for row in sample["proofPage"]["receiptPayloads"]
                    ],
                )

    def test_builder_rejects_proof_page_missing_diagnostic_text(self) -> None:
        import tempfile

        sample = _sample()
        proof_text = (
            REPO_ROOT / sample["proofPage"]["artifact"]["path"]
        ).read_text(encoding="utf-8").replace(
            "hidden_fallback_disabled",
            "fallback-not-visible",
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            proof_artifact_path, proof_receipt_path = _write_mutated_proof_artifacts(
                Path(temp_dir),
                sample,
                proof_text,
            )

            with self.assertRaisesRegex(ValueError, "hidden_fallback_disabled"):
                builder.build_proof_page(
                    proof_artifact=proof_artifact_path,
                    proof_receipt=proof_receipt_path,
                    runtime_identity_path=sample["runtimeIdentityPath"],
                    receipt_payloads=[
                        REPO_ROOT / row["path"]
                        for row in sample["proofPage"]["receiptPayloads"]
                    ],
                )

    def test_builder_rejects_proof_page_missing_receipt_link_text(self) -> None:
        import tempfile

        sample = _sample()
        proof_text = (
            REPO_ROOT / sample["proofPage"]["artifact"]["path"]
        ).read_text(encoding="utf-8").replace(
            "examples/browser-doe-execution-receipt.sample.json",
            "examples/hidden-doe-execution-receipt.sample.json",
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            proof_artifact_path, proof_receipt_path = _write_mutated_proof_artifacts(
                Path(temp_dir),
                sample,
                proof_text,
            )

            with self.assertRaisesRegex(ValueError, "browser-doe-execution-receipt"):
                builder.build_proof_page(
                    proof_artifact=proof_artifact_path,
                    proof_receipt=proof_receipt_path,
                    runtime_identity_path=sample["runtimeIdentityPath"],
                    receipt_payloads=[
                        REPO_ROOT / row["path"]
                        for row in sample["proofPage"]["receiptPayloads"]
                    ],
                )

    def test_builder_rejects_stale_gallery_public_receipt_hash(self) -> None:
        import tempfile

        sample = _sample()
        gallery = sample["galleryPages"][0]
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt = copy.deepcopy(
                json.loads(
                    (REPO_ROOT / gallery["publicReceipt"]["path"]).read_text(
                        encoding="utf-8"
                    )
                )
            )
            receipt["contentSha256"] = "0" * 64
            receipt_path = root / "gallery-public-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
            entry = {
                "category": gallery["category"],
                "url": gallery["url"],
                "artifact": str(REPO_ROOT / gallery["artifact"]["path"]),
                "publicReceipt": str(receipt_path),
                "workloadContractPath": gallery["workloadContractPath"],
                "receiptPayloads": [
                    str(REPO_ROOT / artifact["path"])
                    for artifact in gallery["receiptArtifacts"]
                ],
            }

            with self.assertRaisesRegex(ValueError, "contentSha256"):
                builder.build_gallery_page(entry)

    def test_builder_rejects_failed_gallery_public_receipt_status(self) -> None:
        import tempfile

        sample = _sample()
        gallery = sample["galleryPages"][0]
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt = copy.deepcopy(
                json.loads(
                    (REPO_ROOT / gallery["publicReceipt"]["path"]).read_text(
                        encoding="utf-8"
                    )
                )
            )
            receipt["statusCode"] = 500
            receipt_path = root / "gallery-public-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
            entry = {
                "category": gallery["category"],
                "url": gallery["url"],
                "artifact": str(REPO_ROOT / gallery["artifact"]["path"]),
                "publicReceipt": str(receipt_path),
                "workloadContractPath": gallery["workloadContractPath"],
                "receiptPayloads": [
                    str(REPO_ROOT / artifact["path"])
                    for artifact in gallery["receiptArtifacts"]
                ],
            }

            with self.assertRaisesRegex(ValueError, "statusCode must be 200"):
                builder.build_gallery_page(entry)

    def test_builder_rejects_wrong_gallery_public_receipt_method(self) -> None:
        import tempfile

        sample = _sample()
        gallery = sample["galleryPages"][0]
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            receipt = copy.deepcopy(
                json.loads(
                    (REPO_ROOT / gallery["publicReceipt"]["path"]).read_text(
                        encoding="utf-8"
                    )
                )
            )
            receipt["method"] = "HEAD"
            receipt_path = root / "gallery-public-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
            entry = {
                "category": gallery["category"],
                "url": gallery["url"],
                "artifact": str(REPO_ROOT / gallery["artifact"]["path"]),
                "publicReceipt": str(receipt_path),
                "workloadContractPath": gallery["workloadContractPath"],
                "receiptPayloads": [
                    str(REPO_ROOT / artifact["path"])
                    for artifact in gallery["receiptArtifacts"]
                ],
            }

            with self.assertRaisesRegex(ValueError, "method must be GET"):
                builder.build_gallery_page(entry)

    def test_builder_rejects_gallery_missing_workload_text(self) -> None:
        import tempfile

        sample = _sample()
        gallery = sample["galleryPages"][0]
        gallery_text = (
            REPO_ROOT / gallery["artifact"]["path"]
        ).read_text(encoding="utf-8").replace(
            "browser-smoke-compute",
            "browser-smoke-hidden",
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            gallery_artifact_path, public_receipt_path = _write_mutated_gallery_artifacts(
                Path(temp_dir),
                gallery,
                gallery_text,
            )
            entry = {
                "category": gallery["category"],
                "url": gallery["url"],
                "artifact": str(gallery_artifact_path),
                "publicReceipt": str(public_receipt_path),
                "workloadContractPath": gallery["workloadContractPath"],
                "receiptPayloads": [
                    str(REPO_ROOT / artifact["path"])
                    for artifact in gallery["receiptArtifacts"]
                ],
            }

            with self.assertRaisesRegex(ValueError, "browser-smoke-compute"):
                builder.build_gallery_page(entry)

    def test_builder_rejects_gallery_missing_receipt_link_text(self) -> None:
        import tempfile

        sample = _sample()
        gallery = sample["galleryPages"][0]
        gallery_text = (
            REPO_ROOT / gallery["artifact"]["path"]
        ).read_text(encoding="utf-8").replace(
            "examples/browser-doe-execution-receipt.sample.json",
            "examples/hidden-doe-execution-receipt.sample.json",
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            gallery_artifact_path, public_receipt_path = _write_mutated_gallery_artifacts(
                Path(temp_dir),
                gallery,
                gallery_text,
            )
            entry = {
                "category": gallery["category"],
                "url": gallery["url"],
                "artifact": str(gallery_artifact_path),
                "publicReceipt": str(public_receipt_path),
                "workloadContractPath": gallery["workloadContractPath"],
                "receiptPayloads": [
                    str(REPO_ROOT / artifact["path"])
                    for artifact in gallery["receiptArtifacts"]
                ],
            }

            with self.assertRaisesRegex(ValueError, "browser-doe-execution-receipt"):
                builder.build_gallery_page(entry)

    def test_builder_rejects_mismatched_comparison_timing_class(self) -> None:
        import tempfile

        sample = _sample()
        comparison = sample["comparisonReceipts"][0]
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            doe_receipt = copy.deepcopy(
                json.loads((REPO_ROOT / comparison["doeReceipt"]["path"]).read_text(encoding="utf-8"))
            )
            doe_receipt["timing"]["timingClass"] = "different-scope"
            doe_path = root / "doe-receipt.json"
            doe_path.write_text(json.dumps(doe_receipt, indent=2) + "\n", encoding="utf-8")
            entry = {
                "comparisonId": comparison["comparisonId"],
                "workloadId": comparison["workloadId"],
                "pageArtifactPath": comparison["runner"]["pageArtifactPath"],
                "comparisonArtifact": str(REPO_ROOT / comparison["comparisonArtifact"]["path"]),
                "dawnReceipt": str(REPO_ROOT / comparison["dawnReceipt"]["path"]),
                "doeReceipt": str(doe_path),
            }

            with self.assertRaisesRegex(ValueError, "same timing class"):
                builder.build_comparison(entry)

    def test_builder_rejects_comparison_page_outside_gallery(self) -> None:
        sample = _sample()
        sample["comparisonReceipts"][0]["runner"]["pageArtifactPath"] = "examples/not-a-gallery-page.html"

        with self.assertRaisesRegex(ValueError, "pageArtifactPath must match a gallery page artifact"):
            _build_sample_surface(sample)

    def test_builder_rejects_invalid_comparison_smoke_artifact(self) -> None:
        import tempfile

        sample = _sample()
        comparison = sample["comparisonReceipts"][0]
        smoke = copy.deepcopy(
            json.loads((REPO_ROOT / comparison["comparisonArtifact"]["path"]).read_text(encoding="utf-8"))
        )
        smoke["methodology"]["strictMode"] = False
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            smoke_path = root / "comparison-smoke.json"
            smoke_path.write_text(json.dumps(smoke, indent=2) + "\n", encoding="utf-8")
            entry = {
                "comparisonId": comparison["comparisonId"],
                "workloadId": comparison["workloadId"],
                "pageArtifactPath": comparison["runner"]["pageArtifactPath"],
                "comparisonArtifact": str(smoke_path),
                "dawnReceipt": str(REPO_ROOT / comparison["dawnReceipt"]["path"]),
                "doeReceipt": str(REPO_ROOT / comparison["doeReceipt"]["path"]),
            }

            with self.assertRaisesRegex(ValueError, "strict Dawn/Doe smoke report"):
                builder.build_comparison(entry)

    def test_builder_rejects_proof_page_missing_comparison_visibility(self) -> None:
        import tempfile

        sample = _sample()
        proof_text = (
            REPO_ROOT / sample["proofPage"]["artifact"]["path"]
        ).read_text(encoding="utf-8").replace(
            "browser-smoke-compute-dawn-vs-doe",
            "comparison-hidden",
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            proof_artifact_path, proof_receipt_path = _write_mutated_proof_artifacts(
                Path(temp_dir),
                sample,
                proof_text,
            )
            sample["proofPage"]["artifact"]["path"] = str(proof_artifact_path)
            sample["proofPage"]["diagnosticReceipt"]["path"] = str(proof_receipt_path)

            with self.assertRaisesRegex(ValueError, "browser-smoke-compute-dawn-vs-doe"):
                _build_sample_surface(sample)

    def test_builder_rejects_hash_only_execution_receipt(self) -> None:
        import tempfile

        sample = _sample()
        receipt = copy.deepcopy(
            json.loads((REPO_ROOT / sample["comparisonReceipts"][0]["doeReceipt"]["path"]).read_text(encoding="utf-8"))
        )
        del receipt["sourceShader"]["source"]
        with tempfile.TemporaryDirectory() as temp_dir:
            receipt_path = Path(temp_dir) / "doe-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "sourceShader.source"):
                builder.execution_receipt_artifact(receipt_path)

    def test_builder_rejects_source_hash_mismatch(self) -> None:
        import tempfile

        sample = _sample()
        receipt = copy.deepcopy(
            json.loads((REPO_ROOT / sample["comparisonReceipts"][0]["doeReceipt"]["path"]).read_text(encoding="utf-8"))
        )
        receipt["sourceShader"]["sha256"] = "0" * 64
        with tempfile.TemporaryDirectory() as temp_dir:
            receipt_path = Path(temp_dir) / "doe-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "sourceShader.sha256"):
                builder.execution_receipt_artifact(receipt_path)

    def test_builder_rejects_incomplete_execution_command_coverage(self) -> None:
        import tempfile

        sample = _sample()
        receipt = copy.deepcopy(
            json.loads((REPO_ROOT / sample["comparisonReceipts"][0]["doeReceipt"]["path"]).read_text(encoding="utf-8"))
        )
        receipt["commandCoverage"]["successCount"] = 0
        with tempfile.TemporaryDirectory() as temp_dir:
            receipt_path = Path(temp_dir) / "doe-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "successCount must equal commandCount"):
                builder.execution_receipt_artifact(receipt_path)

    def test_builder_rejects_execution_selector_fallback_drift(self) -> None:
        import tempfile

        sample = _sample()
        receipt = copy.deepcopy(
            json.loads((REPO_ROOT / sample["comparisonReceipts"][0]["doeReceipt"]["path"]).read_text(encoding="utf-8"))
        )
        receipt["runtimeSelectorState"]["fallbackApplied"] = True
        receipt["runtimeSelectorState"]["fallbackReasonCode"] = "fallback"
        with tempfile.TemporaryDirectory() as temp_dir:
            receipt_path = Path(temp_dir) / "doe-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "runtimeSelectorState.fallbackApplied must be false"):
                builder.execution_receipt_artifact(receipt_path)

    def test_builder_rejects_execution_fallback_state_drift(self) -> None:
        import tempfile

        sample = _sample()
        receipt = copy.deepcopy(
            json.loads((REPO_ROOT / sample["comparisonReceipts"][0]["doeReceipt"]["path"]).read_text(encoding="utf-8"))
        )
        receipt["fallbackState"]["hiddenFallbackAllowed"] = True
        with tempfile.TemporaryDirectory() as temp_dir:
            receipt_path = Path(temp_dir) / "doe-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "fallbackState.hiddenFallbackAllowed must be false"):
                builder.execution_receipt_artifact(receipt_path)

    def test_builder_rejects_missing_execution_timing_phases(self) -> None:
        import tempfile

        sample = _sample()
        receipt = copy.deepcopy(
            json.loads((REPO_ROOT / sample["comparisonReceipts"][0]["doeReceipt"]["path"]).read_text(encoding="utf-8"))
        )
        receipt["timing"]["phases"] = {}
        with tempfile.TemporaryDirectory() as temp_dir:
            receipt_path = Path(temp_dir) / "doe-receipt.json"
            receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "timing.phases"):
                builder.execution_receipt_artifact(receipt_path)

    def test_builder_rejects_gallery_page_missing_receipt_backend_facts(self) -> None:
        import tempfile

        receipt = json.loads(
            (REPO_ROOT / "examples/browser-doe-execution-receipt.sample.json").read_text(
                encoding="utf-8"
            )
        )
        visible_facts = [
            fragment
            for fragment in builder.receipt_visibility_fragments(receipt)
            if fragment != "webgpu-doe"
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            gallery_path = Path(temp_dir) / "gallery.html"
            gallery_path.write_text(
                (
                    '<!doctype html><h1>compute</h1>'
                    '<a href="contract.md">contract.md</a>'
                    '<a href="receipt.json">receipt.json</a>'
                    + "".join(f"<p>{fragment}</p>" for fragment in visible_facts)
                    + "\n"
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "webgpu-doe"):
                builder.validate_gallery_page_content(
                    gallery_artifact=gallery_path,
                    gallery_page={
                        "category": "compute",
                        "workloadContractPath": "contract.md",
                        "workloadIds": ["browser-smoke-compute"],
                        "receiptIds": ["browser-smoke-compute-doe"],
                        "receiptArtifacts": [{"path": "receipt.json"}],
                    },
                    receipt_payloads=[receipt],
                )

    def test_builder_rejects_mismatched_comparison_source_identity(self) -> None:
        import tempfile

        sample = _sample()
        comparison = sample["comparisonReceipts"][0]
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            doe_receipt = copy.deepcopy(
                json.loads((REPO_ROOT / comparison["doeReceipt"]["path"]).read_text(encoding="utf-8"))
            )
            source = "@compute @workgroup_size(1) fn different() {}"
            doe_receipt["sourceShader"]["source"] = source
            import hashlib

            doe_receipt["sourceShader"]["sha256"] = hashlib.sha256(source.encode("utf-8")).hexdigest()
            doe_path = root / "doe-receipt.json"
            doe_path.write_text(json.dumps(doe_receipt, indent=2) + "\n", encoding="utf-8")
            entry = {
                "comparisonId": comparison["comparisonId"],
                "workloadId": comparison["workloadId"],
                "pageArtifactPath": comparison["runner"]["pageArtifactPath"],
                "comparisonArtifact": str(REPO_ROOT / comparison["comparisonArtifact"]["path"]),
                "dawnReceipt": str(REPO_ROOT / comparison["dawnReceipt"]["path"]),
                "doeReceipt": str(doe_path),
            }

            with self.assertRaisesRegex(ValueError, "same source shader identity"):
                builder.build_comparison(entry)

    def test_builder_rejects_wrong_comparison_runtime_label(self) -> None:
        import tempfile

        sample = _sample()
        comparison = sample["comparisonReceipts"][0]
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            doe_receipt = copy.deepcopy(
                json.loads((REPO_ROOT / comparison["doeReceipt"]["path"]).read_text(encoding="utf-8"))
            )
            doe_receipt["selectedRuntime"] = "dawn"
            doe_receipt["runtimeSelectorState"]["selectedRuntime"] = "dawn"
            doe_receipt["runtimeSelectorState"]["selectionMode"] = "dawn"
            doe_receipt["runtimeSelectorState"]["forcedMode"] = "dawn"
            doe_path = root / "doe-receipt.json"
            doe_path.write_text(json.dumps(doe_receipt, indent=2) + "\n", encoding="utf-8")
            entry = {
                "comparisonId": comparison["comparisonId"],
                "workloadId": comparison["workloadId"],
                "pageArtifactPath": comparison["runner"]["pageArtifactPath"],
                "comparisonArtifact": str(REPO_ROOT / comparison["comparisonArtifact"]["path"]),
                "dawnReceipt": str(REPO_ROOT / comparison["dawnReceipt"]["path"]),
                "doeReceipt": str(doe_path),
            }

            with self.assertRaisesRegex(ValueError, "selectedRuntime must be doe"):
                builder.build_comparison(entry)

    def test_builder_rejects_mismatched_comparison_workload_identity(self) -> None:
        import tempfile

        sample = _sample()
        comparison = sample["comparisonReceipts"][0]
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            doe_receipt = copy.deepcopy(
                json.loads((REPO_ROOT / comparison["doeReceipt"]["path"]).read_text(encoding="utf-8"))
            )
            doe_receipt["workloadId"] = "other-workload"
            doe_path = root / "doe-receipt.json"
            doe_path.write_text(json.dumps(doe_receipt, indent=2) + "\n", encoding="utf-8")
            entry = {
                "comparisonId": comparison["comparisonId"],
                "workloadId": comparison["workloadId"],
                "pageArtifactPath": comparison["runner"]["pageArtifactPath"],
                "comparisonArtifact": str(REPO_ROOT / comparison["comparisonArtifact"]["path"]),
                "dawnReceipt": str(REPO_ROOT / comparison["dawnReceipt"]["path"]),
                "doeReceipt": str(doe_path),
            }

            with self.assertRaisesRegex(ValueError, "same workload identity"):
                builder.build_comparison(entry)

    def test_builder_rejects_comparison_entry_workload_drift(self) -> None:
        sample = _sample()
        comparison = sample["comparisonReceipts"][0]
        entry = {
            "comparisonId": comparison["comparisonId"],
            "workloadId": "other-workload",
            "pageArtifactPath": comparison["runner"]["pageArtifactPath"],
            "comparisonArtifact": str(REPO_ROOT / comparison["comparisonArtifact"]["path"]),
            "dawnReceipt": str(REPO_ROOT / comparison["dawnReceipt"]["path"]),
            "doeReceipt": str(REPO_ROOT / comparison["doeReceipt"]["path"]),
        }

        with self.assertRaisesRegex(ValueError, "workloadId must match"):
            builder.build_comparison(entry)

    def test_builder_rejects_mismatched_comparison_command_coverage(self) -> None:
        import tempfile

        sample = _sample()
        comparison = sample["comparisonReceipts"][0]
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            doe_receipt = copy.deepcopy(
                json.loads((REPO_ROOT / comparison["doeReceipt"]["path"]).read_text(encoding="utf-8"))
            )
            doe_receipt["commandCoverage"] = {
                "commandCount": 2,
                "successCount": 2,
                "dispatchCount": 1,
            }
            doe_path = root / "doe-receipt.json"
            doe_path.write_text(json.dumps(doe_receipt, indent=2) + "\n", encoding="utf-8")
            entry = {
                "comparisonId": comparison["comparisonId"],
                "workloadId": comparison["workloadId"],
                "pageArtifactPath": comparison["runner"]["pageArtifactPath"],
                "comparisonArtifact": str(REPO_ROOT / comparison["comparisonArtifact"]["path"]),
                "dawnReceipt": str(REPO_ROOT / comparison["dawnReceipt"]["path"]),
                "doeReceipt": str(doe_path),
            }

            with self.assertRaisesRegex(ValueError, "same command coverage"):
                builder.build_comparison(entry)

    def test_builder_rejects_mismatched_comparison_driver_identity(self) -> None:
        import tempfile

        sample = _sample()
        comparison = sample["comparisonReceipts"][0]
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            doe_receipt = copy.deepcopy(
                json.loads((REPO_ROOT / comparison["doeReceipt"]["path"]).read_text(encoding="utf-8"))
            )
            doe_receipt["driver"]["driver"] = "other-driver"
            doe_path = root / "doe-receipt.json"
            doe_path.write_text(json.dumps(doe_receipt, indent=2) + "\n", encoding="utf-8")
            entry = {
                "comparisonId": comparison["comparisonId"],
                "workloadId": comparison["workloadId"],
                "pageArtifactPath": comparison["runner"]["pageArtifactPath"],
                "comparisonArtifact": str(REPO_ROOT / comparison["comparisonArtifact"]["path"]),
                "dawnReceipt": str(REPO_ROOT / comparison["dawnReceipt"]["path"]),
                "doeReceipt": str(doe_path),
            }

            with self.assertRaisesRegex(ValueError, "same driver identity"):
                builder.build_comparison(entry)

    def test_builder_rejects_mismatched_comparison_device_identity(self) -> None:
        import tempfile

        sample = _sample()
        comparison = sample["comparisonReceipts"][0]
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            doe_receipt = copy.deepcopy(
                json.loads((REPO_ROOT / comparison["doeReceipt"]["path"]).read_text(encoding="utf-8"))
            )
            doe_receipt["device"]["device"] = "other-device"
            doe_path = root / "doe-receipt.json"
            doe_path.write_text(json.dumps(doe_receipt, indent=2) + "\n", encoding="utf-8")
            entry = {
                "comparisonId": comparison["comparisonId"],
                "workloadId": comparison["workloadId"],
                "pageArtifactPath": comparison["runner"]["pageArtifactPath"],
                "comparisonArtifact": str(REPO_ROOT / comparison["comparisonArtifact"]["path"]),
                "dawnReceipt": str(REPO_ROOT / comparison["dawnReceipt"]["path"]),
                "doeReceipt": str(doe_path),
            }

            with self.assertRaisesRegex(ValueError, "same device identity"):
                builder.build_comparison(entry)


if __name__ == "__main__":
    unittest.main()
