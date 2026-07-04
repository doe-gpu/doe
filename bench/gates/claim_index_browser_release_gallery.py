#!/usr/bin/env python3
"""Public-gallery receipt checks for Chromium claim-index browser releases."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from bench.gates.claim_index_browser_release_receipts import (
    failure,
    sha256_file,
    unsafe_repo_path_reason,
    validate_json_receipt_artifact_file,
)


BROWSER_PUBLIC_GALLERY_RECEIPT_KIND = "browser_public_gallery_receipt"


def receipt_artifact_paths(row: dict[str, Any]) -> list[str]:
    artifacts = row.get("receiptArtifacts")
    if not isinstance(artifacts, list):
        return []
    return [
        artifact["path"]
        for artifact in artifacts
        if isinstance(artifact, dict) and isinstance(artifact.get("path"), str)
    ]


def receipt_artifact_ids(row: dict[str, Any]) -> list[str]:
    artifacts = row.get("receiptArtifacts")
    if not isinstance(artifacts, list):
        return []
    return [
        artifact["receiptId"]
        for artifact in artifacts
        if isinstance(artifact, dict) and isinstance(artifact.get("receiptId"), str)
    ]


def has_duplicate_string(values: Any) -> bool:
    if not isinstance(values, list):
        return False
    seen: set[str] = set()
    for value in values:
        if not isinstance(value, str) or not value:
            continue
        if value in seen:
            return True
        seen.add(value)
    return False


def receipt_artifact_workload_ids(root: Path, row: dict[str, Any]) -> list[str]:
    artifacts = row.get("receiptArtifacts")
    if not isinstance(artifacts, list):
        return []
    workload_ids: list[str] = []
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            continue
        rel_path = artifact.get("path")
        reason = unsafe_repo_path_reason(rel_path)
        if reason:
            continue
        try:
            payload = json.loads((root / rel_path).read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError):
            continue
        if not isinstance(payload, dict):
            continue
        workload_id = payload.get("workloadId")
        if (
            isinstance(workload_id, str)
            and workload_id
            and workload_id not in workload_ids
        ):
            workload_ids.append(workload_id)
    return workload_ids


def public_gallery_receipt_payload(
    root: Path,
    artifact: dict[str, Any],
    proof_surface_path: str,
) -> tuple[dict[str, Any] | None, list[dict[str, str]]]:
    return validate_json_receipt_artifact_file(
        root=root,
        artifact=artifact,
        failure_prefix="browser_release_proof_surface_public_gallery_receipt",
        proof_surface_path=proof_surface_path,
        label="public gallery receipt",
    )


def validate_public_gallery_payload_fields(
    *,
    payload: dict[str, Any],
    row: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    artifact = row.get("artifact")
    artifact_path = artifact.get("path") if isinstance(artifact, dict) else None
    artifact_sha = artifact.get("sha256") if isinstance(artifact, dict) else None
    field_checks: tuple[tuple[Any, Any, str], ...] = (
        (payload.get("schemaVersion"), 1, "schemaVersion must be 1"),
        (
            payload.get("artifactKind"),
            BROWSER_PUBLIC_GALLERY_RECEIPT_KIND,
            "artifactKind must be browser_public_gallery_receipt",
        ),
        (payload.get("category"), row.get("category"), "category must match gallery page"),
        (payload.get("url"), row.get("url"), "URL must match gallery page"),
        (payload.get("method"), "GET", "method must be GET"),
        (payload.get("statusCode"), 200, "statusCode must be 200"),
        (
            payload.get("contentSha256"),
            artifact_sha,
            "contentSha256 must match gallery artifact sha256",
        ),
        (
            payload.get("galleryArtifactPath"),
            artifact_path,
            "galleryArtifactPath must match gallery artifact path",
        ),
        (
            payload.get("workloadContractPath"),
            row.get("workloadContractPath"),
            "workloadContractPath must match gallery page",
        ),
        (payload.get("workloadIds"), row.get("workloadIds"), "workloadIds must match gallery page"),
        (payload.get("receiptIds"), row.get("receiptIds"), "receiptIds must match gallery page"),
        (
            payload.get("receiptArtifactPaths"),
            receipt_artifact_paths(row),
            "receiptArtifactPaths must match gallery receipt artifacts",
        ),
    )
    for actual, expected, message in field_checks:
        if actual == expected:
            continue
        failures.append(
            failure(
                "browser_release_proof_surface_public_gallery_receipt_mismatch",
                proof_surface_path,
                f"public gallery receipt {message}",
            )
        )

    for field in ("receiptId", "observedAt"):
        if not isinstance(payload.get(field), str) or not payload.get(field):
            failures.append(
                failure(
                    "browser_release_proof_surface_public_gallery_receipt_incomplete",
                    proof_surface_path,
                    f"public gallery receipt requires {field}",
                )
            )
    if not (isinstance(payload.get("url"), str) and payload.get("url", "").startswith("https://")):
        failures.append(
            failure(
                "browser_release_proof_surface_public_gallery_receipt_mismatch",
                proof_surface_path,
                "public gallery receipt URL must be HTTPS",
            )
        )
    if not isinstance(payload.get("contentLengthBytes"), int) or payload.get(
        "contentLengthBytes"
    ) <= 0:
        failures.append(
            failure(
                "browser_release_proof_surface_public_gallery_receipt_incomplete",
                proof_surface_path,
                "public gallery receipt requires positive contentLengthBytes",
                )
            )
    return failures


def validate_gallery_receipt_artifact_ids(
    *,
    row: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    artifact_ids = receipt_artifact_ids(row)
    artifact_paths = receipt_artifact_paths(row)
    if (
        has_duplicate_string(row.get("receiptIds"))
        or has_duplicate_string(artifact_ids)
        or has_duplicate_string(artifact_paths)
    ):
        failures.append(
            failure(
                "browser_release_proof_surface_gallery_receipt_duplicate",
                proof_surface_path,
                "gallery receipt IDs and artifact paths must uniquely identify execution receipts",
            )
        )
    if row.get("receiptIds") != artifact_ids:
        failures.append(
            failure(
                "browser_release_proof_surface_gallery_receipt_mismatch",
                proof_surface_path,
                "gallery receiptIds must match linked execution receipt artifact IDs",
            )
        )
    return failures


def validate_gallery_workload_ids(
    *,
    root: Path,
    row: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    workload_ids = receipt_artifact_workload_ids(root, row)
    if not workload_ids or row.get("workloadIds") == workload_ids:
        return []
    return [
        failure(
            "browser_release_proof_surface_gallery_workload_mismatch",
            proof_surface_path,
            "gallery workloadIds must match linked execution receipt payload workload IDs",
        )
    ]


def gallery_visible_fragments(row: dict[str, Any]) -> list[tuple[str, str]]:
    fragments: list[tuple[str, str]] = []
    for field in ("category", "workloadContractPath"):
        value = row.get(field)
        if isinstance(value, str) and value:
            fragments.append((field, value))
    for field in ("workloadIds", "receiptIds"):
        values = row.get(field)
        if not isinstance(values, list):
            continue
        fragments.extend((field, value) for value in values if isinstance(value, str) and value)
    fragments.extend(("receiptArtifacts.path", path) for path in receipt_artifact_paths(row))
    return fragments


def validate_public_gallery_visible_text(
    *,
    text: str,
    row: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for field, fragment in gallery_visible_fragments(row):
        if fragment in text:
            continue
        failures.append(
            failure(
                "browser_release_proof_surface_public_gallery_content_incomplete",
                proof_surface_path,
                f"gallery page artifact must show {field}",
            )
        )
    return failures


def comparison_visible_fragments(row: dict[str, Any]) -> list[tuple[str, str]]:
    fragments: list[tuple[str, str]] = []
    for field in ("comparisonId", "workloadId"):
        value = row.get(field)
        if isinstance(value, str) and value:
            fragments.append((field, value))
    comparison_artifact = row.get("comparisonArtifact")
    if isinstance(comparison_artifact, dict):
        path = comparison_artifact.get("path")
        if isinstance(path, str) and path:
            fragments.append(("comparisonArtifact.path", path))
    runner = row.get("runner")
    if isinstance(runner, dict):
        for field in ("pageArtifactPath", "executionScope"):
            value = runner.get(field)
            if isinstance(value, str) and value:
                fragments.append((f"runner.{field}", value))
        modes = runner.get("modes")
        if isinstance(modes, list):
            fragments.extend(
                ("runner.modes", mode)
                for mode in modes
                if isinstance(mode, str) and mode
            )
        if runner.get("emitsSideBySideReceipts") is True:
            fragments.append(("runner.emitsSideBySideReceipts", "side_by_side_receipts"))
    for field in ("dawnReceipt", "doeReceipt"):
        receipt = row.get(field)
        if not isinstance(receipt, dict):
            continue
        for key in ("receiptId", "path"):
            value = receipt.get(key)
            if isinstance(value, str) and value:
                fragments.append((f"{field}.{key}", value))
    return fragments


def gallery_artifact_text(
    *,
    root: Path,
    row: dict[str, Any],
    proof_surface_path: str,
) -> tuple[str | None, list[dict[str, str]]]:
    artifact = row.get("artifact")
    if not isinstance(artifact, dict):
        return None, []
    rel_path = artifact.get("path")
    reason = unsafe_repo_path_reason(rel_path)
    if reason:
        return None, [
            failure(
                "browser_release_proof_surface_comparison_content_incomplete",
                proof_surface_path,
                reason,
            )
        ]
    artifact_path = root / rel_path
    if not artifact_path.exists():
        return None, [
            failure(
                "browser_release_proof_surface_comparison_content_unavailable",
                proof_surface_path,
                f"{rel_path}: comparison_gallery_artifact_missing",
            )
        ]
    try:
        text = artifact_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return None, [
            failure(
                "browser_release_proof_surface_comparison_content_unavailable",
                proof_surface_path,
                f"{rel_path}: comparison_gallery_artifact_text_failed: {exc}",
            )
        ]
    return text, []


def validate_comparison_visible_text(
    *,
    text: str,
    row: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for field, fragment in comparison_visible_fragments(row):
        if fragment in text:
            continue
        failures.append(
            failure(
                "browser_release_proof_surface_comparison_content_incomplete",
                proof_surface_path,
                f"same-page gallery artifact must show {field}",
            )
        )
    return failures


def validate_claim_indexed_proof_surface_comparison_gallery_content(
    root: Path,
    proof_surface: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    proof_surface_path = f"{entry_path}.browserRelease.proofSurfacePath"
    gallery_by_path = {
        artifact.get("path"): row
        for row in proof_surface.get("galleryPages", [])
        if isinstance(row, dict)
        for artifact in [row.get("artifact")]
        if isinstance(artifact, dict) and isinstance(artifact.get("path"), str)
    }
    comparison_receipts = proof_surface.get("comparisonReceipts")
    if not isinstance(comparison_receipts, list):
        return []

    failures: list[dict[str, str]] = []
    for row in comparison_receipts:
        if not isinstance(row, dict):
            continue
        runner = row.get("runner")
        page_artifact_path = runner.get("pageArtifactPath") if isinstance(runner, dict) else None
        gallery_row = gallery_by_path.get(page_artifact_path)
        if not isinstance(gallery_row, dict):
            failures.append(
                failure(
                    "browser_release_proof_surface_comparison_content_incomplete",
                    proof_surface_path,
                    "same-page comparison runner page must match a gallery artifact",
                )
            )
            continue
        text, text_failures = gallery_artifact_text(
            root=root,
            row=gallery_row,
            proof_surface_path=proof_surface_path,
        )
        failures.extend(text_failures)
        if text is None:
            continue
        failures.extend(
            validate_comparison_visible_text(
                text=text,
                row=row,
                proof_surface_path=proof_surface_path,
            )
        )
    return failures


def validate_public_gallery_content_file(
    *,
    root: Path,
    row: dict[str, Any],
    payload: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    artifact = row.get("artifact")
    if not isinstance(artifact, dict):
        return []
    rel_path = artifact.get("path")
    reason = unsafe_repo_path_reason(rel_path)
    if reason:
        return [
            failure(
                "browser_release_proof_surface_public_gallery_receipt_incomplete",
                proof_surface_path,
                reason,
            )
        ]
    artifact_path = root / rel_path
    if not artifact_path.exists():
        return [
            failure(
                "browser_release_proof_surface_public_gallery_receipt_unavailable",
                proof_surface_path,
                f"{rel_path}: gallery_artifact_missing",
            )
        ]
    failures: list[dict[str, str]] = []
    try:
        actual_sha = sha256_file(artifact_path)
        actual_size = artifact_path.stat().st_size
    except OSError as exc:
        return [
            failure(
                "browser_release_proof_surface_public_gallery_receipt_unavailable",
                proof_surface_path,
                f"{rel_path}: gallery_artifact_read_failed: {exc}",
            )
        ]
    if actual_sha != artifact.get("sha256"):
        failures.append(
            failure(
                "browser_release_proof_surface_public_gallery_receipt_hash_mismatch",
                proof_surface_path,
                f"gallery artifact {rel_path} hash must match proof-surface artifact ref",
            )
        )
    if payload.get("contentLengthBytes") != actual_size:
        failures.append(
            failure(
                "browser_release_proof_surface_public_gallery_receipt_mismatch",
                proof_surface_path,
                "public gallery receipt contentLengthBytes must match gallery artifact size",
            )
        )
    try:
        text = artifact_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return failures + [
            failure(
                "browser_release_proof_surface_public_gallery_receipt_unavailable",
                proof_surface_path,
                f"{rel_path}: gallery_artifact_text_failed: {exc}",
            )
        ]
    failures.extend(
        validate_public_gallery_visible_text(
            text=text,
            row=row,
            proof_surface_path=proof_surface_path,
        )
    )
    return failures


def validate_public_gallery_receipt_artifact(
    *,
    root: Path,
    row: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    proof_surface_path = f"{entry_path}.browserRelease.proofSurfacePath"
    artifact = row.get("publicReceipt")
    if not isinstance(artifact, dict):
        return [
            failure(
                "browser_release_proof_surface_public_gallery_receipt_incomplete",
                proof_surface_path,
                "gallery entries require publicReceipt artifact objects",
            )
        ]
    for field in ("path", "sha256", "kind"):
        if not isinstance(artifact.get(field), str) or not artifact.get(field):
            return [
                failure(
                    "browser_release_proof_surface_public_gallery_receipt_incomplete",
                    proof_surface_path,
                    f"gallery publicReceipt references require {field}",
                )
            ]
    if artifact.get("kind") != BROWSER_PUBLIC_GALLERY_RECEIPT_KIND:
        return [
            failure(
                "browser_release_proof_surface_public_gallery_receipt_incomplete",
                proof_surface_path,
                "gallery publicReceipt references must name browser_public_gallery_receipt artifacts",
            )
        ]

    payload, failures = public_gallery_receipt_payload(root, artifact, proof_surface_path)
    if payload is None:
        return failures
    failures.extend(
        validate_gallery_receipt_artifact_ids(
            row=row,
            proof_surface_path=proof_surface_path,
        )
    )
    failures.extend(
        validate_gallery_workload_ids(
            root=root,
            row=row,
            proof_surface_path=proof_surface_path,
        )
    )
    failures.extend(
        validate_public_gallery_payload_fields(
            payload=payload,
            row=row,
            proof_surface_path=proof_surface_path,
        )
    )
    failures.extend(
        validate_public_gallery_content_file(
            root=root,
            row=row,
            payload=payload,
            proof_surface_path=proof_surface_path,
        )
    )
    return failures


def validate_claim_indexed_proof_surface_public_gallery_receipts(
    root: Path,
    proof_surface: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    gallery_pages = proof_surface.get("galleryPages")
    if not isinstance(gallery_pages, list):
        return []
    failures: list[dict[str, str]] = []
    for row in gallery_pages:
        if not isinstance(row, dict):
            continue
        failures.extend(
            validate_public_gallery_receipt_artifact(
                root=root,
                row=row,
                entry_path=entry_path,
            )
        )
    failures.extend(
        validate_claim_indexed_proof_surface_comparison_gallery_content(
            root,
            proof_surface,
            entry_path,
        )
    )
    return failures
