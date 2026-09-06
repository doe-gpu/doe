"""Receipts for browser release evidence."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from bench.browser.release.artifacts import (
    failure,
)
from bench.browser.release.comparison_receipts import (
    validate_claim_indexed_proof_surface_comparison_payloads,
)
from bench.browser.release.execution_receipts import (
    proof_surface_execution_receipt_artifacts,
    validate_execution_receipt_artifact,
)
from bench.browser.release.gallery import (
    validate_claim_indexed_proof_surface_public_gallery_receipts,
)
from bench.browser.release.proof_page_receipts import (
    validate_claim_indexed_proof_surface_proof_page_receipt,
)
from bench.browser.release.receipt_state import (
    validate_execution_receipt_reference_consistency,
)


def validate_claim_indexed_proof_surface_execution_receipts(
    root: Path,
    proof_surface: dict[str, Any],
    entry_path: str,
    release_bundle: dict[str, Any] | None,
) -> list[dict[str, str]]:
    refs = proof_surface_execution_receipt_artifacts(proof_surface)
    if not refs:
        return [
            failure(
                "browser_release_proof_surface_receipt_incomplete",
                f"{entry_path}.browserRelease.proofSurfacePath",
                "claim-indexed Chromium proof surfaces require execution receipt artifacts",
            )
        ]

    failures: list[dict[str, str]] = []
    failures.extend(
        validate_execution_receipt_reference_consistency(
            refs,
            proof_surface_path=f"{entry_path}.browserRelease.proofSurfacePath",
        )
    )
    seen: set[tuple[str, str | None]] = set()
    for artifact, expected_runtime in refs:
        key = (artifact.get("path", ""), expected_runtime)
        if key in seen:
            continue
        seen.add(key)
        failures.extend(
            validate_execution_receipt_artifact(
                root=root,
                artifact=artifact,
                expected_runtime=expected_runtime,
                entry_path=entry_path,
            )
        )
    failures.extend(
        validate_claim_indexed_proof_surface_comparison_payloads(
            root,
            proof_surface,
            entry_path,
            release_bundle,
        )
    )
    return failures


def validate_claim_indexed_proof_surface_receipts(
    root: Path,
    proof_surface: dict[str, Any],
    entry_path: str,
    *,
    release_bundle: dict[str, Any] | None = None,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    failures.extend(
        validate_claim_indexed_proof_surface_execution_receipts(
            root,
            proof_surface,
            entry_path,
            release_bundle,
        )
    )
    failures.extend(
        validate_claim_indexed_proof_surface_public_gallery_receipts(
            root,
            proof_surface,
            entry_path,
        )
    )
    failures.extend(
        validate_claim_indexed_proof_surface_proof_page_receipt(
            root,
            proof_surface,
            entry_path,
        )
    )
    return failures
