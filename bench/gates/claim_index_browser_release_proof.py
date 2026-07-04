#!/usr/bin/env python3
"""Proof-surface and launch checks for Chromium claim-index browser releases."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from bench.tools._public_url import is_public_https_url


def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def nested_value(value: Any, path: tuple[str, ...]) -> Any:
    current = value
    for key in path:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def unsafe_repo_path(path: Any) -> bool:
    if not isinstance(path, str) or not path:
        return True
    if "\\" in path or path.startswith("/"):
        return True
    return any(part in ("", ".", "..") for part in path.split("/"))


def receipt_payload_receipt_id(root: Path | None, artifact: Any) -> str | None:
    if root is None or not isinstance(artifact, dict):
        return None
    rel_path = artifact.get("path")
    if unsafe_repo_path(rel_path):
        return None
    try:
        payload = json.loads((root / rel_path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    receipt_id = payload.get("receiptId")
    return receipt_id if isinstance(receipt_id, str) and receipt_id else None


def load_repo_json_object(root: Path, rel_path: str) -> dict[str, Any] | None:
    try:
        payload = json.loads((root / rel_path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def require_field(
    artifact: dict[str, Any],
    field: str,
    expected: Any,
    failure_code: str,
    path: str,
    message: str,
) -> list[dict[str, str]]:
    if artifact.get(field) == expected:
        return []
    return [failure(failure_code, path, message)]


def require_nested_field(
    artifact: dict[str, Any],
    field_path: tuple[str, ...],
    expected: Any,
    failure_code: str,
    path: str,
    message: str,
) -> list[dict[str, str]]:
    if nested_value(artifact, field_path) == expected:
        return []
    return [failure(failure_code, path, message)]


def require_nested_string(
    artifact: dict[str, Any],
    field_path: tuple[str, ...],
    failure_code: str,
    path: str,
    message: str,
) -> list[dict[str, str]]:
    value = nested_value(artifact, field_path)
    if isinstance(value, str) and value:
        return []
    return [failure(failure_code, path, message)]


BROWSER_GALLERY_CATEGORIES = {
    "benchmark_trace",
    "compute",
    "rendering",
    "shader_edge",
    "tensor",
}
PROOF_DIAGNOSTIC_STATUS_FIELDS = ("tsirStatus", "hostPlanStatus", "cslStatus")
NON_RELEASE_DIAGNOSTIC_STATUS_VALUES = {
    "diagnostic",
    "placeholder",
    "sample",
    "tbd",
    "todo",
    "unknown",
}

RUNTIME_IDENTITY_RELEASE_HASH_BINDINGS = (
    ("browserExecutableSha256", ("browserBinary", "sha256")),
    ("doeLibSha256", ("doeRuntime", "sha256")),
    ("dawnRuntimeSha256", ("dawnFallbackRuntime", "sha256")),
)
RUNTIME_IDENTITY_RELEASE_HASH_MESSAGE = (
    "proof-surface runtime identity artifact hashes must match release bundle "
    "browser/runtime artifacts"
)


def runtime_identity_artifact_identities(
    runtime_identity: dict[str, Any],
) -> list[dict[str, Any]]:
    identities: list[dict[str, Any]] = []
    for field_path in (
        ("provider", "artifactIdentity"),
        ("runtimeSelection", "artifactIdentity"),
    ):
        identity = nested_value(runtime_identity, field_path)
        if isinstance(identity, dict):
            identities.append(identity)
    return identities


def release_bundle_runtime_hashes(release_bundle: dict[str, Any]) -> dict[str, str] | None:
    expected: dict[str, str] = {}
    for runtime_field, release_field_path in RUNTIME_IDENTITY_RELEASE_HASH_BINDINGS:
        value = nested_value(release_bundle, release_field_path)
        if not isinstance(value, str) or not value:
            return None
        expected[runtime_field] = value
    return expected


def artifact_identity_matches_release_hashes(
    artifact_identity: dict[str, Any],
    expected_hashes: dict[str, str],
) -> bool:
    return all(
        artifact_identity.get(field) == expected
        for field, expected in expected_hashes.items()
    )


def validate_proof_surface_runtime_identity_release_hashes(
    proof_surface: dict[str, Any],
    release_bundle: dict[str, Any],
    root: Path,
    entry_path: str,
) -> list[dict[str, str]]:
    path = f"{entry_path}.browserRelease.proofSurfacePath"
    runtime_identity_path = proof_surface.get("runtimeIdentityPath")
    expected_hashes = release_bundle_runtime_hashes(release_bundle)
    if unsafe_repo_path(runtime_identity_path) or expected_hashes is None:
        return [
            failure(
                "browser_release_proof_surface_runtime_identity_release_mismatch",
                path,
                RUNTIME_IDENTITY_RELEASE_HASH_MESSAGE,
            )
        ]

    runtime_identity = load_repo_json_object(root, runtime_identity_path)
    if runtime_identity is None:
        return [
            failure(
                "browser_release_proof_surface_runtime_identity_release_mismatch",
                path,
                RUNTIME_IDENTITY_RELEASE_HASH_MESSAGE,
            )
        ]

    identities = runtime_identity_artifact_identities(runtime_identity)
    if any(
        artifact_identity_matches_release_hashes(identity, expected_hashes)
        for identity in identities
    ):
        return []
    return [
        failure(
            "browser_release_proof_surface_runtime_identity_release_mismatch",
            path,
            RUNTIME_IDENTITY_RELEASE_HASH_MESSAGE,
        )
    ]


def validate_browser_launch_observed_receipts(
    browser_launch: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    observed = browser_launch.get("observedReceiptIds")
    required_receipts = (
        nested_value(browser_launch, ("proofPage", "receiptId")),
        nested_value(browser_launch, ("galleryPage", "receiptId")),
        nested_value(browser_launch, ("comparisonReceipt", "dawnReceiptId")),
        nested_value(browser_launch, ("comparisonReceipt", "doeReceiptId")),
    )
    if not isinstance(observed, list):
        return [
            failure(
                "browser_release_launch_receipt_missing_observed_receipts",
                f"{entry_path}.browserRelease.browserLaunchReceiptPath",
                "claim-indexed Chromium browser releases require observed proof, gallery, Dawn, and Doe receipt IDs",
            )
        ]

    if any(not isinstance(receipt_id, str) or not receipt_id for receipt_id in observed):
        return [
            failure(
                "browser_release_launch_receipt_missing_observed_receipts",
                f"{entry_path}.browserRelease.browserLaunchReceiptPath",
                "claim-indexed Chromium browser releases require observed proof, gallery, Dawn, and Doe receipt IDs",
            )
        ]

    seen_observed_ids: set[str] = set()
    for receipt_id in observed:
        if receipt_id in seen_observed_ids:
            return [
                failure(
                    "browser_release_launch_receipt_duplicate_observed_receipts",
                    f"{entry_path}.browserRelease.browserLaunchReceiptPath",
                    "browser launch observedReceiptIds must uniquely identify observed receipts",
                )
            ]
        seen_observed_ids.add(receipt_id)

    observed_ids = {item for item in observed if isinstance(item, str)}
    missing = [
        item
        for item in required_receipts
        if isinstance(item, str) and item and item not in observed_ids
    ]
    if not missing and all(isinstance(item, str) and item for item in required_receipts):
        expected_observed_ids = {item for item in required_receipts if isinstance(item, str)}
        if observed_ids == expected_observed_ids:
            return []
        return [
            failure(
                "browser_release_launch_receipt_unlinked_observed_receipts",
                f"{entry_path}.browserRelease.browserLaunchReceiptPath",
                "browser launch observedReceiptIds must exactly match proof, gallery, Dawn, and Doe receipt IDs",
            )
        ]
    return [
        failure(
            "browser_release_launch_receipt_missing_observed_receipts",
            f"{entry_path}.browserRelease.browserLaunchReceiptPath",
            "claim-indexed Chromium browser releases require observed proof, gallery, Dawn, and Doe receipt IDs",
        )
    ]


def validate_claim_indexed_browser_launch_receipt(
    browser_launch: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    path = f"{entry_path}.browserRelease.browserLaunchReceiptPath"
    failures: list[dict[str, str]] = []

    for field, expected in (
        ("launchSource", "release_archive"),
        ("runtimeMode", "doe"),
        ("activeRuntime", "doe"),
        ("activeBackend", "webgpu-doe"),
        ("hiddenFallbackAllowed", False),
        ("hiddenFallbackUsed", False),
        ("webgpuAvailable", True),
    ):
        failures.extend(
            require_field(
                browser_launch,
                field,
                expected,
                "browser_release_launch_receipt_not_doe_runtime",
                path,
                "claim-indexed Chromium browser releases require a release-archive Doe WebGPU launch with hidden fallback disabled and unused",
            )
        )

    for field_path, expected, code, message in (
        (
            ("proofPage", "url"),
            "about:doe",
            "browser_release_launch_receipt_without_proof_page",
            "claim-indexed Chromium browser releases require about:doe proof-page launch evidence",
        ),
        (
            ("proofPage", "loaded"),
            True,
            "browser_release_launch_receipt_without_proof_page",
            "claim-indexed Chromium browser releases require a loaded about:doe proof page",
        ),
        (
            ("galleryPage", "loaded"),
            True,
            "browser_release_launch_receipt_without_gallery",
            "claim-indexed Chromium browser releases require a loaded public gallery page",
        ),
        (
            ("comparisonReceipt", "loaded"),
            True,
            "browser_release_launch_receipt_without_same_page_comparison",
            "claim-indexed Chromium browser releases require loaded same-page Dawn/Doe comparison evidence",
        ),
        (
            ("comparisonReceipt", "executionScope"),
            "same_page",
            "browser_release_launch_receipt_without_same_page_comparison",
            "claim-indexed Chromium browser releases require same-page Dawn/Doe comparison evidence",
        ),
        (
            ("comparisonReceipt", "modes"),
            ["dawn", "doe"],
            "browser_release_launch_receipt_without_same_page_comparison",
            "claim-indexed Chromium browser releases require Dawn then Doe comparison modes",
        ),
        (
            ("comparisonReceipt", "emitsSideBySideReceipts"),
            True,
            "browser_release_launch_receipt_without_same_page_comparison",
            "claim-indexed Chromium browser releases require side-by-side Dawn/Doe receipts",
        ),
    ):
        failures.extend(
            require_nested_field(browser_launch, field_path, expected, code, path, message)
        )

    for field_path, code, message in (
        (
            ("proofPage", "artifactPath"),
            "browser_release_launch_receipt_without_proof_page",
            "claim-indexed Chromium browser releases require a proof-page artifact path",
        ),
        (
            ("proofPage", "receiptId"),
            "browser_release_launch_receipt_without_proof_page",
            "claim-indexed Chromium browser releases require a proof-page receipt ID",
        ),
        (
            ("galleryPage", "url"),
            "browser_release_launch_receipt_without_gallery",
            "claim-indexed Chromium browser releases require a hosted gallery URL",
        ),
        (
            ("galleryPage", "artifactPath"),
            "browser_release_launch_receipt_without_gallery",
            "claim-indexed Chromium browser releases require a gallery artifact path",
        ),
        (
            ("galleryPage", "receiptId"),
            "browser_release_launch_receipt_without_gallery",
            "claim-indexed Chromium browser releases require a gallery receipt ID",
        ),
        (
            ("comparisonReceipt", "comparisonId"),
            "browser_release_launch_receipt_without_same_page_comparison",
            "claim-indexed Chromium browser releases require a comparison receipt ID",
        ),
        (
            ("comparisonReceipt", "workloadId"),
            "browser_release_launch_receipt_without_same_page_comparison",
            "claim-indexed Chromium browser releases require a comparison workload ID",
        ),
        (
            ("comparisonReceipt", "pageArtifactPath"),
            "browser_release_launch_receipt_without_same_page_comparison",
            "claim-indexed Chromium browser releases require a comparison page artifact path",
        ),
        (
            ("comparisonReceipt", "comparisonArtifactPath"),
            "browser_release_launch_receipt_without_same_page_comparison",
            "claim-indexed Chromium browser releases require a comparison artifact path",
        ),
        (
            ("comparisonReceipt", "dawnReceiptId"),
            "browser_release_launch_receipt_without_same_page_comparison",
            "claim-indexed Chromium browser releases require a Dawn execution receipt ID",
        ),
        (
            ("comparisonReceipt", "doeReceiptId"),
            "browser_release_launch_receipt_without_same_page_comparison",
            "claim-indexed Chromium browser releases require a Doe execution receipt ID",
        ),
    ):
        failures.extend(require_nested_string(browser_launch, field_path, code, path, message))

    gallery_category = nested_value(browser_launch, ("galleryPage", "category"))
    if gallery_category not in BROWSER_GALLERY_CATEGORIES:
        failures.append(
            failure(
                "browser_release_launch_receipt_without_gallery",
                path,
                "claim-indexed Chromium browser releases require a recognized gallery category",
            )
        )

    gallery_url = nested_value(browser_launch, ("galleryPage", "url"))
    if not is_public_https_url(gallery_url):
        failures.append(
            failure(
                "browser_release_launch_receipt_without_gallery",
                path,
                "claim-indexed Chromium browser releases require a public HTTPS gallery URL",
            )
        )

    failures.extend(validate_browser_launch_observed_receipts(browser_launch, entry_path))
    return failures


def validate_claim_indexed_launch_matches_proof_surface(
    browser_launch: dict[str, Any],
    proof_surface: dict[str, Any],
    entry_path: str,
    *,
    root: Path | None = None,
) -> list[dict[str, str]]:
    path = f"{entry_path}.browserRelease.browserLaunchReceiptPath"
    failures: list[dict[str, str]] = []

    proof_page = browser_launch.get("proofPage")
    proof_surface_page = proof_surface.get("proofPage")
    if isinstance(proof_page, dict) and isinstance(proof_surface_page, dict):
        proof_artifact = proof_surface_page.get("artifact")
        expected_artifact = (
            proof_artifact.get("path") if isinstance(proof_artifact, dict) else None
        )
        for actual, expected, message in (
            (
                proof_page.get("url"),
                proof_surface_page.get("url"),
                "launch proof-page URL must match proof surface",
            ),
            (
                proof_page.get("artifactPath"),
                expected_artifact,
                "launch proof-page artifact must match proof surface",
            ),
        ):
            if actual != expected:
                failures.append(
                    failure("browser_release_launch_proof_surface_mismatch", path, message)
                )
        diagnostic_receipt_id = receipt_payload_receipt_id(
            root,
            proof_surface_page.get("diagnosticReceipt"),
        )
        if (
            isinstance(diagnostic_receipt_id, str)
            and proof_page.get("receiptId") != diagnostic_receipt_id
        ):
            failures.append(
                failure(
                    "browser_release_launch_proof_surface_mismatch",
                    path,
                    "launch proof-page receipt ID must match proof-surface diagnostic receipt payload",
                )
            )

    gallery_page = browser_launch.get("galleryPage")
    gallery_match = None
    if isinstance(gallery_page, dict):
        for row in proof_surface.get("galleryPages", []):
            artifact = row.get("artifact") if isinstance(row, dict) else None
            if isinstance(artifact, dict) and artifact.get("path") == gallery_page.get(
                "artifactPath"
            ):
                gallery_match = row
                break
        if not isinstance(gallery_match, dict):
            failures.append(
                failure(
                    "browser_release_launch_proof_surface_mismatch",
                    path,
                    "launch gallery artifact must match a proof-surface gallery page",
                )
            )
        else:
            for field, message in (
                ("url", "launch gallery URL must match proof surface"),
                ("category", "launch gallery category must match proof surface"),
            ):
                if gallery_page.get(field) != gallery_match.get(field):
                    failures.append(
                        failure(
                            "browser_release_launch_proof_surface_mismatch",
                            path,
                            message,
                        )
                    )
            public_receipt_id = receipt_payload_receipt_id(
                root,
                gallery_match.get("publicReceipt"),
            )
            if (
                isinstance(public_receipt_id, str)
                and gallery_page.get("receiptId") != public_receipt_id
            ):
                failures.append(
                    failure(
                        "browser_release_launch_proof_surface_mismatch",
                        path,
                        "launch gallery receipt ID must match proof-surface public gallery receipt payload",
                    )
                )

    comparison = browser_launch.get("comparisonReceipt")
    comparison_match = None
    if isinstance(comparison, dict):
        for row in proof_surface.get("comparisonReceipts", []):
            if isinstance(row, dict) and row.get("comparisonId") == comparison.get(
                "comparisonId"
            ):
                comparison_match = row
                break
        if not isinstance(comparison_match, dict):
            failures.append(
                failure(
                    "browser_release_launch_proof_surface_mismatch",
                    path,
                    "launch comparison ID must match a proof-surface comparison",
                )
            )
        else:
            runner = comparison_match.get("runner")
            comparison_artifact = comparison_match.get("comparisonArtifact")
            dawn = comparison_match.get("dawnReceipt")
            doe = comparison_match.get("doeReceipt")
            expected_values = (
                (
                    comparison.get("workloadId"),
                    comparison_match.get("workloadId"),
                    "launch comparison workload must match proof surface",
                ),
                (
                    comparison.get("comparisonArtifactPath"),
                    comparison_artifact.get("path")
                    if isinstance(comparison_artifact, dict)
                    else None,
                    "launch comparison artifact must match proof surface",
                ),
                (
                    comparison.get("dawnReceiptId"),
                    dawn.get("receiptId") if isinstance(dawn, dict) else None,
                    "launch Dawn receipt ID must match proof surface",
                ),
                (
                    comparison.get("doeReceiptId"),
                    doe.get("receiptId") if isinstance(doe, dict) else None,
                    "launch Doe receipt ID must match proof surface",
                ),
            )
            if isinstance(runner, dict):
                expected_values += (
                    (
                        comparison.get("pageArtifactPath"),
                        runner.get("pageArtifactPath"),
                        "launch comparison page must match proof surface runner",
                    ),
                    (
                        comparison.get("executionScope"),
                        runner.get("executionScope"),
                        "launch comparison scope must match proof surface runner",
                    ),
                    (
                        comparison.get("modes"),
                        runner.get("modes"),
                        "launch comparison modes must match proof surface runner",
                    ),
                    (
                        comparison.get("emitsSideBySideReceipts"),
                        runner.get("emitsSideBySideReceipts"),
                        "launch comparison side-by-side setting must match proof surface runner",
                    ),
                )
            for actual, expected, message in expected_values:
                if actual != expected:
                    failures.append(
                        failure(
                            "browser_release_launch_proof_surface_mismatch",
                            path,
                            message,
                        )
                    )
            if (
                isinstance(gallery_page, dict)
                and comparison.get("pageArtifactPath") != gallery_page.get("artifactPath")
            ):
                failures.append(
                    failure(
                        "browser_release_launch_proof_surface_mismatch",
                        path,
                        "launch comparison page must match the loaded gallery artifact",
                    )
                )

    diagnostics = nested_value(proof_surface, ("proofPage", "diagnostics"))
    if isinstance(diagnostics, dict) and browser_launch.get("activeBackend") != diagnostics.get(
        "activeBackend"
    ):
        failures.append(
            failure(
                "browser_release_launch_proof_surface_mismatch",
                path,
                "launch activeBackend must match proof-surface diagnostics",
            )
        )

    return failures


def nonempty_list(value: Any) -> bool:
    return isinstance(value, list) and len(value) > 0


def validate_claim_indexed_proof_surface_gallery(
    proof_surface: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    path = f"{entry_path}.browserRelease.proofSurfacePath"
    gallery_pages = proof_surface.get("galleryPages")
    if not isinstance(gallery_pages, list):
        return [
            failure(
                "browser_release_proof_surface_gallery_incomplete",
                path,
                "claim-indexed Chromium browser releases require hosted gallery pages",
            )
        ]

    failures: list[dict[str, str]] = []
    categories = {
        item.get("category")
        for item in gallery_pages
        if isinstance(item, dict) and isinstance(item.get("category"), str)
    }
    missing = sorted(BROWSER_GALLERY_CATEGORIES - categories)
    if missing:
        failures.append(
            failure(
                "browser_release_proof_surface_gallery_incomplete",
                path,
                f"claim-indexed Chromium browser releases require gallery categories: {', '.join(missing)}",
            )
        )

    seen_artifact_paths: set[str] = set()
    seen_gallery_urls: set[str] = set()
    for item in gallery_pages:
        if not isinstance(item, dict):
            failures.append(
                failure(
                    "browser_release_proof_surface_gallery_incomplete",
                    path,
                    "claim-indexed Chromium browser gallery entries must be objects",
                )
            )
            continue
        category = item.get("category")
        if category not in BROWSER_GALLERY_CATEGORIES:
            failures.append(
                failure(
                    "browser_release_proof_surface_gallery_incomplete",
                    path,
                    "claim-indexed Chromium browser gallery entries require recognized categories",
                )
            )
        url = item.get("url")
        if not is_public_https_url(url):
            failures.append(
                failure(
                    "browser_release_proof_surface_gallery_incomplete",
                    path,
                    "claim-indexed Chromium browser gallery entries require public HTTPS URLs",
                )
            )
        elif isinstance(url, str) and url:
            if url in seen_gallery_urls:
                failures.append(
                    failure(
                        "browser_release_proof_surface_gallery_url_duplicate",
                        path,
                        "claim-indexed Chromium browser gallery URLs must be unique",
                    )
                )
            else:
                seen_gallery_urls.add(url)
        artifact = item.get("artifact")
        artifact_path = artifact.get("path") if isinstance(artifact, dict) else None
        if isinstance(artifact_path, str) and artifact_path:
            if artifact_path in seen_artifact_paths:
                failures.append(
                    failure(
                        "browser_release_proof_surface_gallery_identity_duplicate",
                        path,
                        "claim-indexed Chromium browser gallery artifact paths must be unique",
                    )
                )
            else:
                seen_artifact_paths.add(artifact_path)
        for field in ("artifact", "publicReceipt"):
            value = item.get(field)
            if not (
                isinstance(value, dict)
                and isinstance(value.get("path"), str)
                and value.get("path")
                and isinstance(value.get("sha256"), str)
                and value.get("sha256")
            ):
                failures.append(
                    failure(
                        "browser_release_proof_surface_gallery_incomplete",
                        path,
                        f"claim-indexed Chromium browser gallery entries require {field} path/hash evidence",
                    )
                )
        for field in ("workloadIds", "receiptIds", "receiptArtifacts"):
            if not nonempty_list(item.get(field)):
                failures.append(
                    failure(
                        "browser_release_proof_surface_gallery_incomplete",
                        path,
                        f"claim-indexed Chromium browser gallery entries require {field}",
                    )
                )

    return failures


def validate_claim_indexed_proof_surface_comparison(
    proof_surface: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    path = f"{entry_path}.browserRelease.proofSurfacePath"
    comparison_receipts = proof_surface.get("comparisonReceipts")
    if not isinstance(comparison_receipts, list) or not comparison_receipts:
        return [
            failure(
                "browser_release_proof_surface_comparison_incomplete",
                path,
                "claim-indexed Chromium browser releases require same-page Dawn/Doe comparison receipts",
            )
        ]

    failures: list[dict[str, str]] = []
    found_valid_comparison = False
    seen_comparison_ids: set[str] = set()
    seen_comparison_artifact_paths: set[str] = set()
    seen_comparison_receipt_pairs: set[tuple[str, str]] = set()
    gallery_artifact_paths = {
        artifact.get("path")
        for item in proof_surface.get("galleryPages", [])
        if isinstance(item, dict)
        for artifact in (item.get("artifact"),)
        if isinstance(artifact, dict)
        and isinstance(artifact.get("path"), str)
        and artifact.get("path")
    }
    incomplete_message = (
        "claim-indexed Chromium browser comparison entries require comparisonId, "
        "workloadId, runner, comparisonPolicy, comparisonArtifact, Dawn receipt, "
        "and Doe receipt"
    )
    parity_message = (
        "claim-indexed Chromium browser releases require same-page Dawn/Doe "
        "comparison receipts with source, device, command, and fallback parity"
    )

    for item in comparison_receipts:
        if not isinstance(item, dict):
            failures.append(
                failure(
                    "browser_release_proof_surface_comparison_incomplete",
                    path,
                    "claim-indexed Chromium browser comparison entries must be objects",
                )
            )
            continue
        comparison_id = item.get("comparisonId")
        if isinstance(comparison_id, str) and comparison_id:
            if comparison_id in seen_comparison_ids:
                failures.append(
                    failure(
                        "browser_release_proof_surface_comparison_identity_duplicate",
                        path,
                        "claim-indexed Chromium browser comparison IDs must be unique",
                    )
                )
            else:
                seen_comparison_ids.add(comparison_id)
        runner = item.get("runner")
        policy = item.get("comparisonPolicy")
        dawn = item.get("dawnReceipt")
        doe = item.get("doeReceipt")
        comparison_artifact = item.get("comparisonArtifact")
        comparison_artifact_path = (
            comparison_artifact.get("path")
            if isinstance(comparison_artifact, dict)
            else None
        )
        runner_page = runner.get("pageArtifactPath") if isinstance(runner, dict) else None
        if (
            not isinstance(item.get("comparisonId"), str)
            or not item.get("comparisonId")
            or not isinstance(item.get("workloadId"), str)
            or not item.get("workloadId")
            or not isinstance(runner, dict)
            or not isinstance(runner_page, str)
            or not runner_page
            or not isinstance(policy, dict)
            or not isinstance(dawn, dict)
            or not isinstance(doe, dict)
            or not isinstance(comparison_artifact, dict)
        ):
            failures.append(
                failure(
                    "browser_release_proof_surface_comparison_incomplete",
                    path,
                    incomplete_message,
                )
            )
            continue
        if runner_page not in gallery_artifact_paths:
            failures.append(
                failure(
                    "browser_release_proof_surface_comparison_page_unpublished",
                    path,
                    "claim-indexed Chromium browser comparison runner pages must be published gallery artifacts",
                )
            )
        if isinstance(comparison_artifact_path, str) and comparison_artifact_path:
            if comparison_artifact_path in seen_comparison_artifact_paths:
                failures.append(
                    failure(
                        "browser_release_proof_surface_comparison_artifact_duplicate",
                        path,
                        "claim-indexed Chromium browser comparison artifact paths must be unique",
                    )
                )
            else:
                seen_comparison_artifact_paths.add(comparison_artifact_path)
        dawn_receipt_id = dawn.get("receiptId") if isinstance(dawn, dict) else None
        doe_receipt_id = doe.get("receiptId") if isinstance(doe, dict) else None
        if (
            isinstance(dawn_receipt_id, str)
            and dawn_receipt_id
            and isinstance(doe_receipt_id, str)
            and doe_receipt_id
        ):
            receipt_pair = (dawn_receipt_id, doe_receipt_id)
            if receipt_pair in seen_comparison_receipt_pairs:
                failures.append(
                    failure(
                        "browser_release_proof_surface_comparison_receipt_pair_duplicate",
                        path,
                        "claim-indexed Chromium browser comparison receipt pairs must be unique",
                    )
                )
            else:
                seen_comparison_receipt_pairs.add(receipt_pair)
        if (
            isinstance(dawn_receipt_id, str)
            and dawn_receipt_id
            and dawn_receipt_id == doe_receipt_id
        ):
            duplicate_receipt_identity = True
        else:
            duplicate_receipt_identity = False
        dawn_receipt_path = dawn.get("path") if isinstance(dawn, dict) else None
        doe_receipt_path = doe.get("path") if isinstance(doe, dict) else None
        if (
            isinstance(dawn_receipt_path, str)
            and dawn_receipt_path
            and dawn_receipt_path == doe_receipt_path
        ):
            duplicate_receipt_identity = True
        if duplicate_receipt_identity:
            failures.append(
                failure(
                    "browser_release_proof_surface_comparison_receipt_duplicate",
                    path,
                    "claim-indexed Chromium browser comparison rows must link distinct Dawn and Doe execution receipts",
                )
            )
        if (
            runner.get("executionScope") == "same_page"
            and runner.get("modes") == ["dawn", "doe"]
            and runner.get("emitsSideBySideReceipts") is True
            and policy.get("workloadIdentity") == "same_workload_id"
            and policy.get("sourceShaderIdentity") == "same_source_shader_identity"
            and policy.get("adapterDeviceIdentity") == "same_device_identity"
            and policy.get("commandCoverage") == "exact_match"
            and policy.get("fallbackPolicy") == "no_hidden_fallback"
            and isinstance(dawn, dict)
            and isinstance(dawn.get("receiptId"), str)
            and isinstance(doe, dict)
            and isinstance(doe.get("receiptId"), str)
            and isinstance(comparison_artifact, dict)
            and isinstance(comparison_artifact_path, str)
        ):
            found_valid_comparison = True
            continue

        failures.append(
            failure(
                "browser_release_proof_surface_comparison_incomplete",
                path,
                parity_message,
            )
        )

    if found_valid_comparison:
        return failures
    if failures:
        return failures
    return [
        failure(
            "browser_release_proof_surface_comparison_incomplete",
            path,
            parity_message,
        )
    ]


def validate_claim_indexed_proof_surface_recent_receipts(
    proof_surface: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    recent = nested_value(proof_surface, ("proofPage", "recentReceiptIds"))
    if not isinstance(recent, list):
        return []

    failures: list[dict[str, str]] = []
    seen_recent_ids: set[str] = set()
    for receipt_id in recent:
        if not isinstance(receipt_id, str) or not receipt_id:
            continue
        if receipt_id in seen_recent_ids:
            failures.append(
                failure(
                    "browser_release_proof_surface_recent_receipts_duplicate",
                    f"{entry_path}.browserRelease.proofSurfacePath",
                    "proof-page recentReceiptIds must uniquely identify exposed execution receipts",
                )
            )
            break
        seen_recent_ids.add(receipt_id)

    recent_ids = {item for item in recent if isinstance(item, str)}
    required_ids: set[str] = set()
    payloads = nested_value(proof_surface, ("proofPage", "receiptPayloads"))
    if isinstance(payloads, list):
        required_ids.update(
            item["receiptId"]
            for item in payloads
            if isinstance(item, dict) and isinstance(item.get("receiptId"), str)
        )
    gallery_pages = proof_surface.get("galleryPages")
    if isinstance(gallery_pages, list):
        for item in gallery_pages:
            if not isinstance(item, dict):
                continue
            receipt_ids = item.get("receiptIds")
            if isinstance(receipt_ids, list):
                required_ids.update(receipt_id for receipt_id in receipt_ids if isinstance(receipt_id, str))
            artifacts = item.get("receiptArtifacts")
            if isinstance(artifacts, list):
                required_ids.update(
                    artifact["receiptId"]
                    for artifact in artifacts
                    if isinstance(artifact, dict) and isinstance(artifact.get("receiptId"), str)
                )
    comparisons = proof_surface.get("comparisonReceipts")
    if isinstance(comparisons, list):
        for item in comparisons:
            if not isinstance(item, dict):
                continue
            for field in ("dawnReceipt", "doeReceipt"):
                receipt = item.get(field)
                if isinstance(receipt, dict) and isinstance(receipt.get("receiptId"), str):
                    required_ids.add(receipt["receiptId"])

    missing = sorted(required_ids - recent_ids)
    if missing:
        failures.append(
            failure(
                "browser_release_proof_surface_recent_receipts_incomplete",
                f"{entry_path}.browserRelease.proofSurfacePath",
                "proof-page recentReceiptIds must include exposed proof, gallery, and comparison execution receipt IDs",
            )
        )
    unlinked = sorted(recent_ids - required_ids)
    if unlinked:
        failures.append(
            failure(
                "browser_release_proof_surface_recent_receipts_unlinked",
                f"{entry_path}.browserRelease.proofSurfacePath",
                "proof-page recentReceiptIds must be backed by exposed execution receipt artifacts",
            )
        )
    return failures


def validate_claim_indexed_proof_surface_receipt_payload_links(
    proof_surface: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    payloads = nested_value(proof_surface, ("proofPage", "receiptPayloads"))
    if not isinstance(payloads, list):
        return []

    failures: list[dict[str, str]] = []
    seen_receipt_ids: set[str] = set()
    seen_paths: set[str] = set()
    for item in payloads:
        if not isinstance(item, dict):
            continue
        receipt_id = item.get("receiptId")
        if isinstance(receipt_id, str) and receipt_id:
            if receipt_id in seen_receipt_ids:
                failures.append(
                    failure(
                        "browser_release_proof_surface_receipt_payload_duplicate",
                        f"{entry_path}.browserRelease.proofSurfacePath",
                        "proof-page receiptPayloads must uniquely identify execution receipt artifacts",
                    )
                )
                break
            seen_receipt_ids.add(receipt_id)
        artifact_path = item.get("path")
        if isinstance(artifact_path, str) and artifact_path:
            if artifact_path in seen_paths:
                failures.append(
                    failure(
                        "browser_release_proof_surface_receipt_payload_duplicate",
                        f"{entry_path}.browserRelease.proofSurfacePath",
                        "proof-page receiptPayloads must uniquely identify execution receipt artifacts",
                    )
                )
                break
            seen_paths.add(artifact_path)
    return failures


def validate_claim_indexed_proof_surface(
    proof_surface: dict[str, Any],
    entry_path: str,
    *,
    release_bundle: dict[str, Any] | None = None,
    root: Path | None = None,
) -> list[dict[str, str]]:
    path = f"{entry_path}.browserRelease.proofSurfacePath"
    failures: list[dict[str, str]] = []

    for field_path, expected, code, message in (
        (
            ("proofPage", "url"),
            "about:doe",
            "browser_release_proof_surface_without_proof_page",
            "claim-indexed Chromium browser proof surfaces require about:doe diagnostics",
        ),
        (
            ("proofPage", "diagnostics", "activeRuntime"),
            "doe",
            "browser_release_proof_surface_without_doe_diagnostics",
            "claim-indexed Chromium browser proof surfaces require active Doe runtime diagnostics",
        ),
        (
            ("proofPage", "diagnostics", "activeBackend"),
            "webgpu-doe",
            "browser_release_proof_surface_without_doe_diagnostics",
            "claim-indexed Chromium browser proof surfaces require active Doe WebGPU backend diagnostics",
        ),
        (
            ("proofPage", "diagnostics", "webgpuAvailable"),
            True,
            "browser_release_proof_surface_without_doe_diagnostics",
            "claim-indexed Chromium browser proof surfaces require WebGPU available diagnostics",
        ),
        (
            ("proofPage", "diagnostics", "fallbackPolicyState"),
            "hidden_fallback_disabled",
            "browser_release_proof_surface_without_doe_diagnostics",
            "claim-indexed Chromium browser proof surfaces require hidden fallback disabled diagnostics",
        ),
    ):
        failures.extend(
            require_nested_field(proof_surface, field_path, expected, code, path, message)
        )

    for field_path, code, message in (
        (
            ("proofPage", "diagnostics", "compilerPath"),
            "browser_release_proof_surface_without_doe_diagnostics",
            "claim-indexed Chromium browser proof surfaces require compiler path diagnostics",
        ),
        (
            ("proofPage", "diagnostics", "tsirStatus"),
            "browser_release_proof_surface_without_doe_diagnostics",
            "claim-indexed Chromium browser proof surfaces require TSIR status diagnostics",
        ),
        (
            ("proofPage", "diagnostics", "hostPlanStatus"),
            "browser_release_proof_surface_without_doe_diagnostics",
            "claim-indexed Chromium browser proof surfaces require HostPlan status diagnostics",
        ),
        (
            ("proofPage", "diagnostics", "cslStatus"),
            "browser_release_proof_surface_without_doe_diagnostics",
            "claim-indexed Chromium browser proof surfaces require CSL status diagnostics",
        ),
        (
            ("surfaceId",),
            "browser_release_proof_surface_without_identity",
            "claim-indexed Chromium browser proof surfaces require a surface ID",
        ),
        (
            ("runtimeIdentityPath",),
            "browser_release_proof_surface_without_identity",
            "claim-indexed Chromium browser proof surfaces require a runtime identity path",
        ),
        (
            ("proofPage", "artifact", "path"),
            "browser_release_proof_surface_without_proof_page",
            "claim-indexed Chromium browser proof surfaces require a proof-page artifact path",
        ),
        (
            ("proofPage", "diagnosticReceipt", "path"),
            "browser_release_proof_surface_without_proof_page",
            "claim-indexed Chromium browser proof surfaces require a proof-page diagnostic receipt",
        ),
    ):
        failures.extend(require_nested_string(proof_surface, field_path, code, path, message))

    diagnostics = nested_value(proof_surface, ("proofPage", "diagnostics"))
    if isinstance(diagnostics, dict):
        for field in PROOF_DIAGNOSTIC_STATUS_FIELDS:
            value = diagnostics.get(field)
            if (
                not isinstance(value, str)
                or not value
                or value.lower() in NON_RELEASE_DIAGNOSTIC_STATUS_VALUES
            ):
                failures.append(
                    failure(
                        "browser_release_proof_surface_non_release_diagnostic_status",
                        path,
                        (
                            "claim-indexed Chromium browser proof surfaces "
                            f"require concrete {field} diagnostics"
                        ),
                    )
                )

    diagnostics_compiler_path = nested_value(
        proof_surface,
        ("proofPage", "diagnostics", "compilerPath"),
    )
    shader_compiler = (
        release_bundle.get("shaderCompiler") if isinstance(release_bundle, dict) else None
    )
    release_compiler_path = (
        shader_compiler.get("path") if isinstance(shader_compiler, dict) else None
    )
    if (
        isinstance(release_compiler_path, str)
        and release_compiler_path
        and diagnostics_compiler_path != release_compiler_path
    ):
        failures.append(
            failure(
                "browser_release_proof_surface_compiler_identity_mismatch",
                path,
                "proof-surface diagnostics compilerPath must match release bundle shaderCompiler.path",
            )
        )
    if isinstance(release_bundle, dict) and root is not None:
        failures.extend(
            validate_proof_surface_runtime_identity_release_hashes(
                proof_surface,
                release_bundle,
                root,
                entry_path,
            )
        )

    if not nonempty_list(nested_value(proof_surface, ("proofPage", "recentReceiptIds"))):
        failures.append(
            failure(
                "browser_release_proof_surface_without_proof_page",
                path,
                "claim-indexed Chromium browser proof surfaces require recent receipt IDs",
            )
        )
    if not nonempty_list(nested_value(proof_surface, ("proofPage", "receiptPayloads"))):
        failures.append(
            failure(
                "browser_release_proof_surface_without_proof_page",
                path,
                "claim-indexed Chromium browser proof surfaces require receipt payload links",
            )
        )

    failures.extend(validate_claim_indexed_proof_surface_gallery(proof_surface, entry_path))
    failures.extend(validate_claim_indexed_proof_surface_comparison(proof_surface, entry_path))
    failures.extend(
        validate_claim_indexed_proof_surface_receipt_payload_links(
            proof_surface,
            entry_path,
        )
    )
    failures.extend(
        validate_claim_indexed_proof_surface_recent_receipts(proof_surface, entry_path)
    )
    return failures
