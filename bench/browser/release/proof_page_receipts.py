"""Proof page receipts for browser release evidence."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from bench.browser.release.artifacts import (
    failure,
    sha256_file,
    unsafe_repo_path_reason,
    validate_json_receipt_artifact_file,
)
from bench.browser.release.receipt_state import recent_receipt_artifact_paths

BROWSER_PROOF_PAGE_RECEIPT_KIND = "browser_proof_page_receipt"

PROOF_PAGE_VISIBLE_DIAGNOSTIC_FIELDS = (
    "activeRuntime",
    "activeBackend",
    "compilerPath",
    "tsirStatus",
    "hostPlanStatus",
    "cslStatus",
    "fallbackPolicyState",
)


def proof_page_load_type(url: Any) -> str:
    if isinstance(url, str) and url.startswith("file:"):
        return "file"
    return "browser_internal_page"


def validate_proof_page_receipt_payload(
    *,
    payload: dict[str, Any],
    proof_surface: dict[str, Any],
    proof_page: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    artifact = proof_page.get("artifact")
    artifact_path = artifact.get("path") if isinstance(artifact, dict) else None
    artifact_sha = artifact.get("sha256") if isinstance(artifact, dict) else None
    field_checks: tuple[tuple[Any, Any, str], ...] = (
        (payload.get("schemaVersion"), 1, "schemaVersion must be 1"),
        (
            payload.get("artifactKind"),
            BROWSER_PROOF_PAGE_RECEIPT_KIND,
            "artifactKind must be browser_proof_page_receipt",
        ),
        (payload.get("url"), proof_page.get("url"), "URL must match proof page"),
        (
            payload.get("loadType"),
            proof_page_load_type(proof_page.get("url")),
            "loadType must match proof page URL",
        ),
        (payload.get("status"), "loaded", "status must be loaded"),
        (
            payload.get("contentSha256"),
            artifact_sha,
            "contentSha256 must match proof page artifact sha256",
        ),
        (
            payload.get("proofArtifactPath"),
            artifact_path,
            "proofArtifactPath must match proof page artifact path",
        ),
        (
            payload.get("runtimeIdentityPath"),
            proof_surface.get("runtimeIdentityPath"),
            "runtimeIdentityPath must match proof surface",
        ),
        (
            payload.get("diagnostics"),
            proof_page.get("diagnostics"),
            "diagnostics must match proof page diagnostics",
        ),
        (
            payload.get("recentReceiptIds"),
            proof_page.get("recentReceiptIds"),
            "recentReceiptIds must match proof page recentReceiptIds",
        ),
        (
            payload.get("releaseProvenance"),
            proof_page.get("releaseProvenance"),
            "releaseProvenance must match proof page releaseProvenance",
        ),
    )
    for actual, expected, message in field_checks:
        if actual == expected:
            continue
        failures.append(
            failure(
                "browser_release_proof_surface_proof_page_receipt_mismatch",
                proof_surface_path,
                f"proof page receipt {message}",
            )
        )

    for field in ("receiptId", "observedAt"):
        if not isinstance(payload.get(field), str) or not payload.get(field):
            failures.append(
                failure(
                    "browser_release_proof_surface_proof_page_receipt_incomplete",
                    proof_surface_path,
                    f"proof page receipt requires {field}",
                )
            )
    if (
        not isinstance(payload.get("contentLengthBytes"), int)
        or payload.get("contentLengthBytes") <= 0
    ):
        failures.append(
            failure(
                "browser_release_proof_surface_proof_page_receipt_incomplete",
                proof_surface_path,
                "proof page receipt requires positive contentLengthBytes",
            )
        )
    return failures


def validate_proof_page_content_file(
    *,
    root: Path,
    proof_surface: dict[str, Any],
    proof_page: dict[str, Any],
    payload: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    artifact = proof_page.get("artifact")
    if not isinstance(artifact, dict):
        return []
    rel_path = artifact.get("path")
    reason = unsafe_repo_path_reason(rel_path)
    if reason:
        return [
            failure(
                "browser_release_proof_surface_proof_page_receipt_incomplete",
                proof_surface_path,
                reason,
            )
        ]
    artifact_path = root / rel_path
    if not artifact_path.exists():
        return [
            failure(
                "browser_release_proof_surface_proof_page_receipt_unavailable",
                proof_surface_path,
                f"{rel_path}: proof_page_artifact_missing",
            )
        ]
    failures: list[dict[str, str]] = []
    try:
        actual_sha = sha256_file(artifact_path)
        actual_size = artifact_path.stat().st_size
    except OSError as exc:
        return [
            failure(
                "browser_release_proof_surface_proof_page_receipt_unavailable",
                proof_surface_path,
                f"{rel_path}: proof_page_artifact_read_failed: {exc}",
            )
        ]
    if actual_sha != artifact.get("sha256"):
        failures.append(
            failure(
                "browser_release_proof_surface_proof_page_receipt_hash_mismatch",
                proof_surface_path,
                f"proof page artifact {rel_path} hash must match proof-surface artifact ref",
            )
        )
    if payload.get("contentLengthBytes") != actual_size:
        failures.append(
            failure(
                "browser_release_proof_surface_proof_page_receipt_mismatch",
                proof_surface_path,
                "proof page receipt contentLengthBytes must match proof page artifact size",
            )
        )
    try:
        text = artifact_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        return failures + [
            failure(
                "browser_release_proof_surface_proof_page_receipt_unavailable",
                proof_surface_path,
                f"{rel_path}: proof_page_artifact_text_failed: {exc}",
            )
        ]
    failures.extend(
        validate_proof_page_visible_text(
            text=text,
            proof_surface=proof_surface,
            proof_page=proof_page,
            proof_surface_path=proof_surface_path,
        )
    )
    return failures


def validate_proof_page_visible_text(
    *,
    text: str,
    proof_surface: dict[str, Any],
    proof_page: dict[str, Any],
    proof_surface_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    diagnostics = proof_page.get("diagnostics")
    if isinstance(diagnostics, dict):
        for field in PROOF_PAGE_VISIBLE_DIAGNOSTIC_FIELDS:
            value = diagnostics.get(field)
            if isinstance(value, str) and value and value not in text:
                failures.append(
                    failure(
                        "browser_release_proof_surface_proof_page_content_incomplete",
                        proof_surface_path,
                        f"proof page artifact must show diagnostic value: {field}",
                    )
                )
    for field_path, label, fragment in release_provenance_visible_fragments(
        proof_page.get("releaseProvenance")
    ):
        if fragment in text:
            continue
        failures.append(
            failure(
                "browser_release_proof_surface_proof_page_content_incomplete",
                proof_surface_path,
                f"proof page artifact must show {label}: {field_path}",
            )
        )
    recent_receipt_ids = proof_page.get("recentReceiptIds")
    if isinstance(recent_receipt_ids, list):
        for receipt_id in recent_receipt_ids:
            if isinstance(receipt_id, str) and receipt_id and receipt_id not in text:
                failures.append(
                    failure(
                        "browser_release_proof_surface_proof_page_content_incomplete",
                        proof_surface_path,
                        "proof page artifact must show recent receipt IDs",
                    )
                )
    for path in recent_receipt_artifact_paths(proof_surface):
        if path not in text:
            failures.append(
                failure(
                    "browser_release_proof_surface_proof_page_content_incomplete",
                    proof_surface_path,
                    "proof page artifact must link recent receipt payload paths",
                )
            )
    return failures


def release_provenance_visible_fragments(
    provenance: Any,
) -> list[tuple[str, str, str]]:
    if not isinstance(provenance, dict):
        return []
    fragments: list[tuple[str, str, str]] = []
    product = provenance.get("browserProduct")
    if isinstance(product, dict):
        for field, label in (
            ("displayName", "browser product"),
            ("version", "browser version"),
            ("channel", "release channel"),
        ):
            value = product.get(field)
            if isinstance(value, str) and value:
                fragments.append((f"browserProduct.{field}", label, value))
    platform = provenance.get("platform")
    if isinstance(platform, dict):
        for field, label in (
            ("os", "platform OS"),
            ("arch", "platform architecture"),
            ("packageFormat", "package format"),
        ):
            value = platform.get(field)
            if isinstance(value, str) and value:
                fragments.append((f"platform.{field}", label, value))
    for field, label in (
        ("browserExecutableArchivePath", "browser executable member"),
        ("browserAppMetadataArchivePath", "app metadata member"),
        ("doeRuntimeArchivePath", "Doe runtime member"),
        ("dawnFallbackRuntimeArchivePath", "Dawn fallback runtime member"),
    ):
        value = provenance.get(field)
        if isinstance(value, str) and value:
            fragments.append((field, label, value))
    for field, label in (
        ("releaseArchive", "release archive"),
        ("releaseArchiveManifest", "release archive manifest"),
        ("publicDownloadReceipt", "public download receipt"),
    ):
        artifact = provenance.get(field)
        if not isinstance(artifact, dict):
            continue
        for key in ("path", "sha256", "downloadUrl"):
            value = artifact.get(key)
            if isinstance(value, str) and value:
                fragments.append((f"{field}.{key}", label, value))
    return fragments


def validate_claim_indexed_proof_surface_proof_page_receipt(
    root: Path,
    proof_surface: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    proof_surface_path = f"{entry_path}.browserRelease.proofSurfacePath"
    proof_page = proof_surface.get("proofPage")
    if not isinstance(proof_page, dict):
        return []
    artifact = proof_page.get("diagnosticReceipt")
    if not isinstance(artifact, dict):
        return [
            failure(
                "browser_release_proof_surface_proof_page_receipt_incomplete",
                proof_surface_path,
                "proof page requires a diagnosticReceipt artifact object",
            )
        ]
    for field in ("path", "sha256", "kind"):
        if not isinstance(artifact.get(field), str) or not artifact.get(field):
            return [
                failure(
                    "browser_release_proof_surface_proof_page_receipt_incomplete",
                    proof_surface_path,
                    f"proof page diagnosticReceipt references require {field}",
                )
            ]
    if artifact.get("kind") != BROWSER_PROOF_PAGE_RECEIPT_KIND:
        return [
            failure(
                "browser_release_proof_surface_proof_page_receipt_incomplete",
                proof_surface_path,
                "proof page diagnosticReceipt must name browser_proof_page_receipt artifacts",
            )
        ]

    payload, failures = validate_json_receipt_artifact_file(
        root=root,
        artifact=artifact,
        failure_prefix="browser_release_proof_surface_proof_page_receipt",
        proof_surface_path=proof_surface_path,
        label="proof page receipt",
    )
    if payload is None:
        return failures
    failures.extend(
        validate_proof_page_receipt_payload(
            payload=payload,
            proof_surface=proof_surface,
            proof_page=proof_page,
            proof_surface_path=proof_surface_path,
        )
    )
    failures.extend(
        validate_proof_page_content_file(
            root=root,
            proof_surface=proof_surface,
            proof_page=proof_page,
            payload=payload,
            proof_surface_path=proof_surface_path,
        )
    )
    return failures
