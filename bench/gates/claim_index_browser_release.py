#!/usr/bin/env python3
"""Chromium browser-release checks for the public claim index gate."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from bench.gates.claim_index_browser_release_proof import (
    validate_claim_indexed_browser_launch_receipt,
    validate_claim_indexed_launch_matches_proof_surface,
    validate_claim_indexed_proof_surface,
)
from bench.gates import claim_index_browser_release_receipts as receipt_checks
from bench.lib.bench_utils import load_json_object
from bench.tools._public_url import is_public_https_url


OPTIONAL_ARTIFACT_PREFIXES = ("bench/out/",)
BROWSER_CHROMIUM_SURFACE = "browser-chromium"
BROWSER_RELEASE_PATH_KINDS = {
    "runtimeFrontierBundlePath": "browser_runtime_frontier_bundle",
    "releaseArtifactBundlePath": "browser_release_artifact_bundle",
    "releaseArchiveManifestPath": "browser_release_archive_manifest",
    "packageInputsPath": "browser_release_package_inputs_check",
    "provenanceReportPath": "browser_release_candidate_provenance_report",
    "publicDownloadReceiptPath": "browser_public_download_receipt",
    "proofSurfacePath": "browser_published_proof_surface",
    "proofSurfaceCheckPath": "browser_published_proof_surface_check",
    "browserLaunchReceiptPath": "browser_release_launch_receipt",
    "finalizerReportPath": "browser_release_candidate_finalizer",
    "finalizerCheckPath": "browser_release_candidate_finalizer_check",
    "readinessReportPath": "dawn-replacement-readiness-report",
}
BROWSER_RELEASE_ARCHIVE_KIND = "browser_release_archive"
BROWSER_RELEASE_ARCHIVE_MANIFEST_KIND = "browser_release_archive_manifest"
BROWSER_FRONTIER_ROW_ID = "browser-chromium-runtime"
BROWSER_RELEASE_READINESS_PATHS = {
    "runtimeFrontierBundlePath": ("frontierBundleEvidence", "path"),
    "releaseArtifactBundlePath": (
        "frontierBundleEvidence",
        "componentReceipts",
        "releaseArtifactBundle",
        "path",
    ),
    "releaseArchivePath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "publicDownloadReceipt",
        "releaseArchivePath",
    ),
    "releaseArchiveSha256": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "publicDownloadReceipt",
        "contentSha256",
    ),
    "releaseArchiveManifestPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "publicDownloadReceipt",
        "releaseArchiveManifestPath",
    ),
    "releaseArchiveManifestSha256": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "publicDownloadReceipt",
        "releaseArchiveManifestSha256",
    ),
    "downloadUrl": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "publicDownloadReceipt",
        "url",
    ),
    "packageInputsPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "packageInputs",
        "path",
    ),
    "provenanceReportPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "provenanceReport",
        "path",
    ),
    "publicDownloadReceiptPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "publicDownloadReceipt",
        "path",
    ),
    "proofSurfacePath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "publishedProofSurface",
        "path",
    ),
    "proofSurfaceCheckPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "proofSurfaceCheck",
        "path",
    ),
    "browserLaunchReceiptPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "browserLaunchReceipt",
        "path",
    ),
    "finalizerReportPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "finalizerReport",
        "path",
    ),
    "finalizerCheckPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "finalizerCheck",
        "path",
    ),
}
BROWSER_RELEASE_READINESS_SHA_PATHS = {
    "runtimeFrontierBundlePath": (
        "frontierBundleEvidence",
        "sha256",
    ),
    "releaseArtifactBundlePath": (
        "frontierBundleEvidence",
        "componentReceipts",
        "releaseArtifactBundle",
        "sha256",
    ),
    "releaseArchivePath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "publicDownloadReceipt",
        "contentSha256",
    ),
    "releaseArchiveManifestPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "publicDownloadReceipt",
        "releaseArchiveManifestSha256",
    ),
    "packageInputsPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "packageInputs",
        "sha256",
    ),
    "provenanceReportPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "provenanceReport",
        "sha256",
    ),
    "publicDownloadReceiptPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "publicDownloadReceipt",
        "sha256",
    ),
    "proofSurfacePath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "publishedProofSurface",
        "sha256",
    ),
    "proofSurfaceCheckPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "proofSurfaceCheck",
        "sha256",
    ),
    "browserLaunchReceiptPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "browserLaunchReceipt",
        "sha256",
    ),
    "finalizerReportPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "finalizerReport",
        "sha256",
    ),
    "finalizerCheckPath": (
        "frontierBundleEvidence",
        "releaseCandidateEvidence",
        "finalizerCheck",
        "sha256",
    ),
}
BROWSER_RELEASE_BUNDLE_COMPONENTS = {
    "runtimeFrontierBundlePath": (
        "runtimeFrontierBundle",
        "browser_runtime_frontier_bundle",
    ),
    "releaseArchiveManifestPath": (
        "releaseArchiveManifest",
        "browser_release_archive_manifest",
    ),
    "packageInputsPath": (
        "packageInputs",
        "browser_release_package_inputs_check",
    ),
    "publicDownloadReceiptPath": (
        "publicDownloadReceipt",
        "browser_public_download_receipt",
    ),
    "proofSurfacePath": (
        "proofSurface",
        "browser_published_proof_surface",
    ),
    "proofSurfaceCheckPath": (
        "proofSurfaceCheck",
        "browser_published_proof_surface_check",
    ),
    "browserLaunchReceiptPath": (
        "browserLaunchReceipt",
        "browser_release_launch_receipt",
    ),
}
BROWSER_RELEASE_IDENTITY_FIELDS = (
    "browserProduct",
    "platform",
    "browserExecutableArchivePath",
    "browserAppMetadataArchivePath",
    "doeRuntimeArchivePath",
    "dawnFallbackRuntimeArchivePath",
)
BROWSER_RELEASE_MEMBER_PATH_FIELDS = (
    ("browserExecutableArchivePath", "browser executable"),
    ("browserAppMetadataArchivePath", "app metadata"),
    ("doeRuntimeArchivePath", "Doe runtime"),
    ("dawnFallbackRuntimeArchivePath", "Dawn fallback runtime"),
)
BROWSER_RELEASE_PACKAGE_INPUT_IDENTITY_PATHS = {
    "browserProduct": ("browserProduct",),
    "platform": ("platform",),
    "browserExecutableArchivePath": ("inputs", "browserExecutable", "archivePath"),
    "browserAppMetadataArchivePath": ("inputs", "appMetadata", "archivePath"),
    "doeRuntimeArchivePath": ("inputs", "doeRuntime", "archivePath"),
    "dawnFallbackRuntimeArchivePath": ("inputs", "dawnFallbackRuntime", "archivePath"),
}
BROWSER_RELEASE_DIRECT_IDENTITY_PATHS = {
    field: (field,) for field in BROWSER_RELEASE_IDENTITY_FIELDS
}
BROWSER_RELEASE_PROVENANCE_IDENTITY_PATHS = {
    "browserProduct": ("browserProduct",),
    "platform": ("platform",),
    "expectedProvenance.browserProduct": ("expectedProvenance", "browserProduct"),
    "expectedProvenance.platform": ("expectedProvenance", "platform"),
    "expectedProvenance.browserExecutableArchivePath": (
        "expectedProvenance",
        "browserExecutableArchivePath",
    ),
    "expectedProvenance.browserAppMetadataArchivePath": (
        "expectedProvenance",
        "browserAppMetadataArchivePath",
    ),
    "expectedProvenance.doeRuntimeArchivePath": (
        "expectedProvenance",
        "doeRuntimeArchivePath",
    ),
    "expectedProvenance.dawnFallbackRuntimeArchivePath": (
        "expectedProvenance",
        "dawnFallbackRuntimeArchivePath",
    ),
}
BROWSER_RELEASE_PROOF_SURFACE_IDENTITY_PATHS = {
    field: ("proofPage", "releaseProvenance", field)
    for field in BROWSER_RELEASE_IDENTITY_FIELDS
}
BROWSER_RELEASE_ARCHIVE_MANIFEST_IDENTITY_PATHS = {
    "browserProduct": ("browserProduct",),
    "platform": ("platform",),
    "browserExecutableArchivePath": ("members", "browserExecutable", "archivePath"),
    "browserAppMetadataArchivePath": ("members", "appMetadata", "archivePath"),
    "doeRuntimeArchivePath": ("members", "doeRuntime", "archivePath"),
    "dawnFallbackRuntimeArchivePath": (
        "members",
        "dawnFallbackRuntime",
        "archivePath",
    ),
}
BROWSER_RELEASE_PACKAGE_INPUT_ARTIFACTS = {
    "browserExecutable": "browserBinary",
    "doeRuntime": "doeRuntime",
    "dawnFallbackRuntime": "dawnFallbackRuntime",
    "shaderCompiler": "shaderCompiler",
}
BROWSER_RELEASE_ARCHIVE_MANIFEST_MEMBER_ARTIFACTS = {
    "browserExecutable": ("browserBinary", True),
    "doeRuntime": ("doeRuntime", False),
    "dawnFallbackRuntime": ("dawnFallbackRuntime", False),
}



def failure(code: str, path: str, message: str) -> dict[str, str]:
    return {"code": code, "path": path, "message": message}


def is_optional_artifact(path: str) -> bool:
    return any(path.startswith(prefix) for prefix in OPTIONAL_ARTIFACT_PREFIXES)


def unsafe_artifact_path_reason(path: Any, *, suffix: str) -> str:
    if not isinstance(path, str) or not path:
        return "path must be a non-empty string"
    if "\\" in path:
        return "path must use forward slashes"
    if path.startswith("/"):
        return "path must be repository-relative"
    if not path.endswith(suffix):
        return f"path must end in {suffix}"
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return "path must not contain empty, current, or parent segments"
    return ""


def unsafe_path_reason(path: Any) -> str:
    return unsafe_artifact_path_reason(path, suffix=".json")


def unsafe_browser_archive_path_reason(path: Any) -> str:
    return unsafe_artifact_path_reason(path, suffix=".zip")


def unsafe_archive_member_path_reason(path: Any) -> str:
    if not isinstance(path, str) or not path:
        return "archive member path must be a non-empty string"
    if "\\" in path:
        return "archive member path must use forward slashes"
    if path.startswith("/"):
        return "archive member path must be relative"
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return "archive member path must not contain empty, current, or parent segments"
    return ""


def local_artifact_path(root: Path, rel_path: str) -> Path:
    return root / rel_path


def browser_release_path_reason(field: str, path: Any) -> str:
    if field == "releaseArchivePath":
        return unsafe_browser_archive_path_reason(path)
    return unsafe_path_reason(path)


def safe_browser_release_artifact_path(root: Path, field: str, path: Any) -> Path | None:
    if not isinstance(path, str):
        return None
    if browser_release_path_reason(field, path):
        return None
    return local_artifact_path(root, path)


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def release_bundle_identity_sha256(payload: dict[str, Any]) -> str:
    projection = {
        key: value
        for key, value in payload.items()
        if key != "runtimeFrontierBundle"
    }
    encoded = json.dumps(
        projection,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def load_optional_artifact(root: Path, rel_path: str) -> tuple[dict[str, Any] | None, str]:
    artifact_path = local_artifact_path(root, rel_path)
    if not artifact_path.exists():
        if is_optional_artifact(rel_path):
            return None, "missing_optional"
        return None, "missing_required"
    try:
        return load_json_object(artifact_path), ""
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        return None, f"parse_failed: {exc}"


def nested_value(value: Any, path: tuple[str, ...]) -> Any:
    current = value
    for key in path:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def readiness_browser_row(readiness_report: dict[str, Any]) -> dict[str, Any] | None:
    rows = readiness_report.get("rows")
    if not isinstance(rows, list):
        return None
    return next(
        (
            row
            for row in rows
            if isinstance(row, dict) and row.get("id") == BROWSER_FRONTIER_ROW_ID
        ),
        None,
    )


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


def validate_existing_file_hash(
    *,
    root: Path,
    browser_release: dict[str, Any],
    entry_path: str,
    path_field: str,
    hash_field: str,
    failure_code: str,
) -> list[dict[str, str]]:
    rel_path = browser_release.get(path_field)
    expected_hash = browser_release.get(hash_field)
    if not isinstance(rel_path, str) or not isinstance(expected_hash, str):
        return []
    artifact_path = safe_browser_release_artifact_path(root, path_field, rel_path)
    if artifact_path is None:
        return []
    if not artifact_path.exists():
        return []
    try:
        actual_hash = sha256_file(artifact_path)
    except OSError as exc:
        return [
            failure(
                "browser_release_artifact_unavailable",
                f"{entry_path}.browserRelease.{path_field}",
                f"{rel_path}: hash_failed: {exc}",
            )
        ]
    if actual_hash == expected_hash:
        return []
    return [
        failure(
            failure_code,
            f"{entry_path}.browserRelease.{hash_field}",
            (
                f"{rel_path}: browserRelease.{hash_field} must match file hash "
                f"{actual_hash}, got {expected_hash}"
            ),
        )
    ]


def validate_browser_release_archive_file(
    *,
    root: Path,
    browser_release: dict[str, Any],
    entry_path: str,
    claim_indexed: bool,
) -> list[dict[str, str]]:
    rel_path = browser_release.get("releaseArchivePath")
    reason = unsafe_browser_archive_path_reason(rel_path)
    path = f"{entry_path}.browserRelease.releaseArchivePath"
    if reason:
        return [failure("unsafe_browser_release_path", path, reason)]
    if not isinstance(rel_path, str):
        return []

    artifact_path = safe_browser_release_artifact_path(
        root,
        "releaseArchivePath",
        rel_path,
    )
    if artifact_path is None:
        return []
    if not artifact_path.exists():
        if claim_indexed or not is_optional_artifact(rel_path):
            return [
                failure(
                    "browser_release_artifact_unavailable",
                    path,
                    f"{rel_path}: missing_required",
                )
            ]
        return []

    return validate_existing_file_hash(
        root=root,
        browser_release=browser_release,
        entry_path=entry_path,
        path_field="releaseArchivePath",
        hash_field="releaseArchiveSha256",
        failure_code="browser_release_archive_hash_mismatch",
    )


def validate_browser_release_nested_value(
    *,
    artifact: dict[str, Any],
    source_field: str,
    value_path: tuple[str, ...],
    expected: Any,
    claim_field: str,
    failure_code: str,
    entry_path: str,
) -> list[dict[str, str]]:
    actual = nested_value(artifact, value_path)
    if actual == expected:
        return []
    source_path = ".".join((source_field, *value_path))
    return [
        failure(
            failure_code,
            f"{entry_path}.browserRelease.{claim_field}",
            (
                f"{source_path} must match browserRelease.{claim_field}: "
                f"expected {expected!r}, got {actual!r}"
            ),
        )
    ]


def validate_browser_release_identity_object(
    *,
    artifact: dict[str, Any],
    source_field: str,
    object_path: tuple[str, ...],
    expected_values: tuple[tuple[str, Any, str, str], ...],
    entry_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    value = nested_value(artifact, object_path)
    object_label = ".".join((source_field, *object_path))
    if not isinstance(value, dict):
        return [
            failure(
                "browser_release_archive_identity_missing",
                f"{entry_path}.browserRelease.releaseArchivePath",
                f"{object_label} must include browser release archive identity",
            )
        ]
    for key, expected, claim_field, failure_code in expected_values:
        if value.get(key) != expected:
            failures.append(
                failure(
                    failure_code,
                    f"{entry_path}.browserRelease.{claim_field}",
                    (
                        f"{object_label}.{key} must match browserRelease.{claim_field}: "
                        f"expected {expected!r}, got {value.get(key)!r}"
                    ),
                )
            )
    return failures


def validate_artifact_ref_identity(
    *,
    artifact_ref: Any,
    expected_path: Any,
    expected_kind: str,
    root: Path,
    entry_path: str,
    browser_release_field: str,
    failure_code: str,
    missing_message: str,
    mismatch_message: str,
) -> list[dict[str, str]]:
    path = f"{entry_path}.browserRelease.{browser_release_field}"
    if not isinstance(artifact_ref, dict):
        return [failure(failure_code, path, missing_message)]

    failures: list[dict[str, str]] = []
    expected_sha = None
    if isinstance(expected_path, str):
        expected_file = safe_browser_release_artifact_path(
            root,
            "releaseArchivePath" if expected_path.endswith(".zip") else "artifactPath",
            expected_path,
        )
        if expected_file is not None:
            try:
                expected_sha = sha256_file(expected_file)
            except OSError:
                expected_sha = None
    for key, expected in (
        ("path", expected_path),
        ("kind", expected_kind),
    ):
        if artifact_ref.get(key) != expected:
            failures.append(failure(failure_code, path, mismatch_message))
    if expected_sha is not None and artifact_ref.get("sha256") != expected_sha:
        failures.append(failure(failure_code, path, mismatch_message))
    return failures


def validate_release_identity_paths(
    *,
    artifact: Any,
    release_bundle: dict[str, Any],
    identity_paths: dict[str, tuple[str, ...]],
    entry_path: str,
    browser_release_field: str,
    failure_code: str,
    message: str,
) -> list[dict[str, str]]:
    if not isinstance(artifact, dict):
        return []

    failures: list[dict[str, str]] = []
    for identity_field, field_path in identity_paths.items():
        expected_field = identity_field.rsplit(".", 1)[-1]
        expected = release_bundle.get(expected_field)
        actual = nested_value(artifact, field_path)
        if actual == expected:
            continue
        source_path = ".".join(field_path)
        failures.append(
            failure(
                failure_code,
                f"{entry_path}.browserRelease.{browser_release_field}",
                (
                    f"{source_path} must match releaseArtifactBundlePath."
                    f"{expected_field}: expected {expected!r}, got {actual!r}; "
                    f"{message}"
                ),
            )
        )
    return failures


def validate_release_bundle_member_path_uniqueness(
    *,
    release_bundle: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    seen: dict[str, tuple[str, str]] = {}
    for field, label in BROWSER_RELEASE_MEMBER_PATH_FIELDS:
        member_path = release_bundle.get(field)
        if not isinstance(member_path, str) or not member_path:
            continue
        reason = unsafe_archive_member_path_reason(member_path)
        if reason:
            failures.append(
                failure(
                    "browser_release_bundle_member_path_unsafe",
                    f"{entry_path}.browserRelease.releaseArtifactBundlePath",
                    f"release artifact bundle {label} {reason}",
                )
            )
            continue
        previous = seen.get(member_path)
        if previous is not None:
            previous_field, previous_label = previous
            failures.append(
                failure(
                    "browser_release_bundle_member_path_duplicate",
                    f"{entry_path}.browserRelease.releaseArtifactBundlePath",
                    (
                        f"release artifact bundle {field} duplicates "
                        f"{previous_label} archive path from {previous_field}"
                    ),
                )
            )
            continue
        seen[member_path] = (field, label)
    return failures


def validate_release_archive_manifest_archive_members_unique(
    *,
    manifest: dict[str, Any],
    entry_path: str,
) -> list[dict[str, str]]:
    archive_members = manifest.get("archiveMembers")
    if not isinstance(archive_members, list):
        return []
    failures: list[dict[str, str]] = []
    seen: set[str] = set()
    for row in archive_members:
        if not isinstance(row, dict) or not isinstance(row.get("archivePath"), str):
            continue
        archive_path = row["archivePath"]
        reason = unsafe_archive_member_path_reason(archive_path)
        if reason:
            failures.append(
                failure(
                    "browser_release_archive_manifest_member_path_unsafe",
                    f"{entry_path}.browserRelease.releaseArchiveManifestPath",
                    f"release archive manifest archiveMembers {reason}: {archive_path}",
                )
            )
            continue
        if archive_path in seen:
            failures.append(
                failure(
                    "browser_release_archive_manifest_member_duplicate",
                    f"{entry_path}.browserRelease.releaseArchiveManifestPath",
                    (
                        "release archive manifest archiveMembers must not "
                        f"repeat member path: {archive_path}"
                    ),
                )
            )
            continue
        seen.add(archive_path)
    return failures


def validate_claim_indexed_release_identity(
    *,
    release_bundle: dict[str, Any],
    loaded_artifacts: dict[str, dict[str, Any]],
    entry_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    for identity_field in BROWSER_RELEASE_IDENTITY_FIELDS:
        if release_bundle.get(identity_field) is None:
            failures.append(
                failure(
                    "browser_release_bundle_identity_incomplete",
                    f"{entry_path}.browserRelease.releaseArtifactBundlePath",
                    f"release artifact bundle must include {identity_field}",
                )
            )
    failures.extend(
        validate_release_bundle_member_path_uniqueness(
            release_bundle=release_bundle,
            entry_path=entry_path,
        )
    )

    package_inputs = loaded_artifacts.get("packageInputsPath")
    package_rows = package_inputs.get("inputs") if isinstance(package_inputs, dict) else None
    if not isinstance(package_rows, dict):
        failures.append(
            failure(
                "browser_release_package_inputs_artifact_mismatch",
                f"{entry_path}.browserRelease.packageInputsPath",
                "claim-indexed Chromium browser package inputs must bind input artifact rows",
            )
        )
    else:
        for role, bundle_artifact_field in BROWSER_RELEASE_PACKAGE_INPUT_ARTIFACTS.items():
            row = package_rows.get(role)
            bundle_artifact = release_bundle.get(bundle_artifact_field)
            if not isinstance(row, dict) or not isinstance(bundle_artifact, dict):
                failures.append(
                    failure(
                        "browser_release_package_inputs_artifact_mismatch",
                        f"{entry_path}.browserRelease.packageInputsPath",
                        (
                            "claim-indexed Chromium browser package inputs must "
                            f"bind {role} to release bundle {bundle_artifact_field}"
                        ),
                    )
                )
                continue
            for key in ("path", "sha256", "kind"):
                if row.get(key) == bundle_artifact.get(key):
                    continue
                failures.append(
                    failure(
                        "browser_release_package_inputs_artifact_mismatch",
                        f"{entry_path}.browserRelease.packageInputsPath",
                        (
                            f"package inputs {role}.{key} must match "
                            f"releaseArtifactBundlePath.{bundle_artifact_field}.{key}"
                        ),
                    )
                )

    failures.extend(
        validate_release_identity_paths(
            artifact=loaded_artifacts.get("packageInputsPath"),
            release_bundle=release_bundle,
            identity_paths=BROWSER_RELEASE_PACKAGE_INPUT_IDENTITY_PATHS,
            entry_path=entry_path,
            browser_release_field="packageInputsPath",
            failure_code="browser_release_package_inputs_identity_mismatch",
            message="package-input identity must match the release bundle",
        )
    )
    failures.extend(
        validate_release_identity_paths(
            artifact=loaded_artifacts.get("releaseArchiveManifestPath"),
            release_bundle=release_bundle,
            identity_paths=BROWSER_RELEASE_ARCHIVE_MANIFEST_IDENTITY_PATHS,
            entry_path=entry_path,
            browser_release_field="releaseArchiveManifestPath",
            failure_code="browser_release_archive_manifest_identity_mismatch",
            message="release archive manifest identity must match the release bundle",
        )
    )
    manifest = loaded_artifacts.get("releaseArchiveManifestPath")
    source_package_inputs = (
        manifest.get("sourcePackageInputs") if isinstance(manifest, dict) else None
    )
    if isinstance(source_package_inputs, dict):
        package_component = release_bundle.get("packageInputs")
        if not isinstance(package_component, dict) or any(
            source_package_inputs.get(key) != package_component.get(key)
            for key in ("path", "sha256", "kind")
        ):
            failures.append(
                failure(
                    "browser_release_archive_manifest_source_package_inputs_mismatch",
                    f"{entry_path}.browserRelease.releaseArchiveManifestPath",
                    (
                        "release archive manifest sourcePackageInputs must match "
                        "the release bundle packageInputs path, hash, and kind"
                    ),
                )
            )
    if isinstance(manifest, dict):
        failures.extend(
            validate_release_archive_manifest_archive_members_unique(
                manifest=manifest,
                entry_path=entry_path,
            )
        )
        members = manifest.get("members")
        if not isinstance(members, dict):
            failures.append(
                failure(
                    "browser_release_archive_manifest_member_mismatch",
                    f"{entry_path}.browserRelease.releaseArchiveManifestPath",
                    "claim-indexed Chromium browser release archive manifest must bind required members",
                )
            )
        else:
            for role, (
                bundle_artifact_field,
                require_executable,
            ) in BROWSER_RELEASE_ARCHIVE_MANIFEST_MEMBER_ARTIFACTS.items():
                member = members.get(role)
                bundle_artifact = release_bundle.get(bundle_artifact_field)
                if not isinstance(member, dict) or not isinstance(bundle_artifact, dict):
                    failures.append(
                        failure(
                            "browser_release_archive_manifest_member_mismatch",
                            f"{entry_path}.browserRelease.releaseArchiveManifestPath",
                            (
                                "release archive manifest members must bind "
                                f"{role} to release bundle {bundle_artifact_field}"
                            ),
                        )
                    )
                    continue
                member_path = member.get("archivePath")
                reason = unsafe_archive_member_path_reason(member_path)
                if reason:
                    failures.append(
                        failure(
                            "browser_release_archive_manifest_member_path_unsafe",
                            f"{entry_path}.browserRelease.releaseArchiveManifestPath",
                            f"release archive manifest {role}.archivePath {reason}",
                        )
                    )
                if member.get("sha256") != bundle_artifact.get("sha256"):
                    failures.append(
                        failure(
                            "browser_release_archive_manifest_member_mismatch",
                            f"{entry_path}.browserRelease.releaseArchiveManifestPath",
                            (
                                f"release archive manifest {role}.sha256 must match "
                                f"releaseArtifactBundlePath.{bundle_artifact_field}.sha256"
                            ),
                        )
                    )
                if require_executable and member.get("executable") is not True:
                    failures.append(
                        failure(
                            "browser_release_archive_manifest_member_mismatch",
                            f"{entry_path}.browserRelease.releaseArchiveManifestPath",
                            f"release archive manifest {role} must be executable",
                        )
                    )
    failures.extend(
        validate_release_identity_paths(
            artifact=loaded_artifacts.get("publicDownloadReceiptPath"),
            release_bundle=release_bundle,
            identity_paths=BROWSER_RELEASE_DIRECT_IDENTITY_PATHS,
            entry_path=entry_path,
            browser_release_field="publicDownloadReceiptPath",
            failure_code="browser_release_public_download_identity_mismatch",
            message="public download identity must match the release bundle",
        )
    )
    failures.extend(
        validate_release_identity_paths(
            artifact=loaded_artifacts.get("provenanceReportPath"),
            release_bundle=release_bundle,
            identity_paths=BROWSER_RELEASE_PROVENANCE_IDENTITY_PATHS,
            entry_path=entry_path,
            browser_release_field="provenanceReportPath",
            failure_code="browser_release_provenance_identity_mismatch",
            message="provenance identity must match the release bundle",
        )
    )
    failures.extend(
        validate_release_identity_paths(
            artifact=loaded_artifacts.get("proofSurfacePath"),
            release_bundle=release_bundle,
            identity_paths=BROWSER_RELEASE_PROOF_SURFACE_IDENTITY_PATHS,
            entry_path=entry_path,
            browser_release_field="proofSurfacePath",
            failure_code="browser_release_proof_surface_identity_mismatch",
            message="proof-surface release provenance must match the release bundle",
        )
    )
    failures.extend(
        validate_release_identity_paths(
            artifact=loaded_artifacts.get("browserLaunchReceiptPath"),
            release_bundle=release_bundle,
            identity_paths=BROWSER_RELEASE_DIRECT_IDENTITY_PATHS,
            entry_path=entry_path,
            browser_release_field="browserLaunchReceiptPath",
            failure_code="browser_release_launch_identity_mismatch",
            message="browser launch identity must match the release bundle",
        )
    )
    return failures


def validate_browser_release_archive_identity(
    *,
    root: Path,
    browser_release: dict[str, Any],
    loaded_artifacts: dict[str, dict[str, Any]],
    entry_path: str,
    claim_indexed: bool,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    failures.extend(
        validate_browser_release_archive_file(
            root=root,
            browser_release=browser_release,
            entry_path=entry_path,
            claim_indexed=claim_indexed,
        )
    )
    failures.extend(
        validate_existing_file_hash(
            root=root,
            browser_release=browser_release,
            entry_path=entry_path,
            path_field="releaseArchiveManifestPath",
            hash_field="releaseArchiveManifestSha256",
            failure_code="browser_release_archive_manifest_hash_mismatch",
        )
    )

    archive_path = browser_release.get("releaseArchivePath")
    archive_sha = browser_release.get("releaseArchiveSha256")
    manifest_path = browser_release.get("releaseArchiveManifestPath")
    manifest_sha = browser_release.get("releaseArchiveManifestSha256")
    download_url = browser_release.get("downloadUrl")
    if not all(
        isinstance(value, str)
        for value in (archive_path, archive_sha, manifest_path, manifest_sha, download_url)
    ):
        return failures
    if claim_indexed and not is_public_https_url(download_url):
        failures.append(
            failure(
                "browser_release_download_url_not_public",
                f"{entry_path}.browserRelease.downloadUrl",
                "claim-indexed Chromium browser releases require a public HTTPS release archive download URL",
            )
        )

    public_download = loaded_artifacts.get("publicDownloadReceiptPath")
    if public_download is not None:
        for value_path, expected, claim_field, failure_code in (
            (
                ("releaseArchivePath",),
                archive_path,
                "releaseArchivePath",
                "browser_release_archive_path_mismatch",
            ),
            (
                ("contentSha256",),
                archive_sha,
                "releaseArchiveSha256",
                "browser_release_archive_sha_mismatch",
            ),
            (
                ("url",),
                download_url,
                "downloadUrl",
                "browser_release_download_url_mismatch",
            ),
            (
                ("releaseArchiveManifestPath",),
                manifest_path,
                "releaseArchiveManifestPath",
                "browser_release_archive_manifest_path_mismatch",
            ),
            (
                ("releaseArchiveManifestSha256",),
                manifest_sha,
                "releaseArchiveManifestSha256",
                "browser_release_archive_manifest_sha_mismatch",
            ),
        ):
            failures.extend(
                validate_browser_release_nested_value(
                    artifact=public_download,
                    source_field="publicDownloadReceiptPath",
                    value_path=value_path,
                    expected=expected,
                    claim_field=claim_field,
                    failure_code=failure_code,
                    entry_path=entry_path,
                )
            )

    archive_expected = (
        (
            "path",
            archive_path,
            "releaseArchivePath",
            "browser_release_archive_path_mismatch",
        ),
        (
            "sha256",
            archive_sha,
            "releaseArchiveSha256",
            "browser_release_archive_sha_mismatch",
        ),
        (
            "kind",
            BROWSER_RELEASE_ARCHIVE_KIND,
            "releaseArchivePath",
            "browser_release_archive_kind_mismatch",
        ),
        (
            "downloadUrl",
            download_url,
            "downloadUrl",
            "browser_release_download_url_mismatch",
        ),
    )
    manifest_expected = (
        (
            "path",
            manifest_path,
            "releaseArchiveManifestPath",
            "browser_release_archive_manifest_path_mismatch",
        ),
        (
            "sha256",
            manifest_sha,
            "releaseArchiveManifestSha256",
            "browser_release_archive_manifest_sha_mismatch",
        ),
        (
            "kind",
            BROWSER_RELEASE_ARCHIVE_MANIFEST_KIND,
            "releaseArchiveManifestPath",
            "browser_release_archive_manifest_kind_mismatch",
        ),
    )
    for source_field, object_path in (
        ("releaseArtifactBundlePath", ("releaseArchive",)),
        ("provenanceReportPath", ("expectedProvenance", "releaseArchive")),
        ("provenanceReportPath", ("componentArtifacts", "releaseArchive")),
        ("proofSurfacePath", ("proofPage", "releaseProvenance", "releaseArchive")),
        ("browserLaunchReceiptPath", ("releaseArchive",)),
    ):
        artifact = loaded_artifacts.get(source_field)
        if artifact is not None:
            failures.extend(
                validate_browser_release_identity_object(
                    artifact=artifact,
                    source_field=source_field,
                    object_path=object_path,
                    expected_values=archive_expected,
                    entry_path=entry_path,
                )
            )

    for source_field, object_path in (
        ("releaseArtifactBundlePath", ("releaseArchiveManifest",)),
        ("provenanceReportPath", ("expectedProvenance", "releaseArchiveManifest")),
        ("provenanceReportPath", ("componentArtifacts", "releaseArchiveManifest")),
        ("proofSurfacePath", ("proofPage", "releaseProvenance", "releaseArchiveManifest")),
        ("browserLaunchReceiptPath", ("releaseArchiveManifest",)),
    ):
        artifact = loaded_artifacts.get(source_field)
        if artifact is not None:
            failures.extend(
                validate_browser_release_identity_object(
                    artifact=artifact,
                    source_field=source_field,
                    object_path=object_path,
                    expected_values=manifest_expected,
                    entry_path=entry_path,
                )
            )

    return failures


def validate_claim_indexed_browser_release(
    root: Path,
    browser_release: dict[str, Any],
    loaded_artifacts: dict[str, dict[str, Any]],
    entry_path: str,
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []

    runtime_frontier = loaded_artifacts.get("runtimeFrontierBundlePath")
    if runtime_frontier is not None:
        failures.extend(
            require_field(
                runtime_frontier,
                "status",
                "pass",
                "browser_release_runtime_frontier_not_pass",
                f"{entry_path}.browserRelease.runtimeFrontierBundlePath",
                "claim-indexed Chromium browser releases require a passing runtime frontier bundle",
            )
        )
        failures.extend(
            require_field(
                runtime_frontier,
                "claimabilityStatus",
                "claimable",
                "browser_release_runtime_frontier_not_claimable",
                f"{entry_path}.browserRelease.runtimeFrontierBundlePath",
                "claim-indexed Chromium browser releases require claimable runtime frontier evidence",
            )
        )
        summary = runtime_frontier.get("summary")
        if not (
            runtime_frontier.get("claimBlockers") == []
            and runtime_frontier.get("claimBlockerSummary") == []
            and runtime_frontier.get("failures") == []
            and isinstance(summary, dict)
            and summary.get("claimBlockerCount") == 0
            and summary.get("failureCount") == 0
        ):
            failures.append(
                failure(
                    "browser_release_runtime_frontier_not_clean",
                    f"{entry_path}.browserRelease.runtimeFrontierBundlePath",
                    "claim-indexed Chromium browser releases require runtime frontier evidence with no blockers or failures",
                )
            )
        component_receipts = runtime_frontier.get("componentReceipts")
        runtime_identity_summary = (
            component_receipts.get("runtimeIdentity")
            if isinstance(component_receipts, dict)
            else None
        )
        promotion_summary = (
            component_receipts.get("claimPromotionReceipt")
            if isinstance(component_receipts, dict)
            else None
        )
        release_summary = (
            component_receipts.get("releaseArtifactBundle")
            if isinstance(component_receipts, dict)
            else None
        )
        artifact_verification = (
            release_summary.get("artifactVerification")
            if isinstance(release_summary, dict)
            else None
        )
        release_bundle = loaded_artifacts.get("releaseArtifactBundlePath")
        if not (
            isinstance(release_summary, dict)
            and isinstance(release_bundle, dict)
            and release_summary.get("path") == browser_release.get("releaseArtifactBundlePath")
            and release_summary.get("status") == "pass"
            and release_summary.get("artifactKind") == release_bundle.get("artifactKind")
            and release_summary.get("releaseStatus") == "release_candidate"
            and release_summary.get("releaseBundleIdentitySha256")
            == release_bundle_identity_sha256(release_bundle)
            and isinstance(artifact_verification, dict)
            and artifact_verification.get("requiredForClaimable") is True
            and artifact_verification.get("verifyFilesRootProvided") is True
            and artifact_verification.get("verified") is True
        ):
            failures.append(
                failure(
                    "browser_release_runtime_frontier_component_mismatch",
                    f"{entry_path}.browserRelease.runtimeFrontierBundlePath",
                    "claim-indexed Chromium browser runtime frontier must bind the release-candidate artifact bundle component",
                )
            )
        proof_surface = loaded_artifacts.get("proofSurfacePath")
        proof_surface_runtime_identity = (
            proof_surface.get("runtimeIdentityPath") if isinstance(proof_surface, dict) else None
        )
        if not (
            isinstance(runtime_identity_summary, dict)
            and isinstance(proof_surface_runtime_identity, str)
            and runtime_identity_summary.get("path") == proof_surface_runtime_identity
            and runtime_identity_summary.get("status") == "pass"
            and runtime_identity_summary.get("evidenceSource")
            == "runtime_selection_artifact"
            and runtime_identity_summary.get("selectedRuntime") == "doe"
            and runtime_identity_summary.get("doeRuntimeActive") is True
        ):
            failures.append(
                failure(
                    "browser_release_runtime_frontier_runtime_identity_mismatch",
                    f"{entry_path}.browserRelease.runtimeFrontierBundlePath",
                    "claim-indexed Chromium browser runtime frontier must bind the proof-surface Doe runtime identity component",
                )
            )
        release_bundle = loaded_artifacts.get("releaseArtifactBundlePath")
        promotion_paths = set()
        if isinstance(release_bundle, dict):
            promotion_receipts = release_bundle.get("promotionReceipts")
            if isinstance(promotion_receipts, list):
                promotion_paths = {
                    item.get("path")
                    for item in promotion_receipts
                    if isinstance(item, dict) and isinstance(item.get("path"), str)
                }
        promotion_artifact_count = (
            promotion_summary.get("artifactCount") if isinstance(promotion_summary, dict) else None
        )
        if not (
            isinstance(promotion_summary, dict)
            and promotion_summary.get("path") in promotion_paths
            and promotion_summary.get("status") == "pass"
            and promotion_summary.get("promotionStatus") == "promotable"
            and isinstance(promotion_artifact_count, int)
            and not isinstance(promotion_artifact_count, bool)
            and promotion_artifact_count > 0
            and promotion_summary.get("hiddenFallbackPassed") is True
        ):
            failures.append(
                failure(
                    "browser_release_runtime_frontier_promotion_mismatch",
                    f"{entry_path}.browserRelease.runtimeFrontierBundlePath",
                    "claim-indexed Chromium browser runtime frontier must bind a promotable release-bundle promotion receipt component",
                )
            )

    release_bundle = loaded_artifacts.get("releaseArtifactBundlePath")
    if release_bundle is not None:
        failures.extend(
            require_field(
                release_bundle,
                "releaseStatus",
                "release_candidate",
                "browser_release_bundle_not_release_candidate",
                f"{entry_path}.browserRelease.releaseArtifactBundlePath",
                "claim-indexed Chromium browser releases require a release-candidate artifact bundle",
            )
        )
        artifact_verification = release_bundle.get("artifactVerification")
        if not (
            isinstance(artifact_verification, dict)
            and artifact_verification.get("requiredForClaimable") is True
            and artifact_verification.get("verifyFilesRootProvided") is True
            and artifact_verification.get("verified") is True
        ):
            failures.append(
                failure(
                    "browser_release_bundle_not_file_verified",
                    f"{entry_path}.browserRelease.releaseArtifactBundlePath",
                    "claim-indexed Chromium browser releases require verified release-bundle files",
                )
            )
        failures.extend(
            validate_claim_indexed_release_identity(
                release_bundle=release_bundle,
                loaded_artifacts=loaded_artifacts,
                entry_path=entry_path,
            )
        )

    package_inputs = loaded_artifacts.get("packageInputsPath")
    if package_inputs is not None:
        failures.extend(
            require_field(
                package_inputs,
                "status",
                "pass",
                "browser_release_package_inputs_not_pass",
                f"{entry_path}.browserRelease.packageInputsPath",
                "claim-indexed Chromium browser releases require passing package-input preflight",
            )
        )
        failures.extend(
            require_field(
                package_inputs,
                "releaseCandidateEligible",
                True,
                "browser_release_package_inputs_not_candidate_eligible",
                f"{entry_path}.browserRelease.packageInputsPath",
                "claim-indexed Chromium browser releases require release-candidate eligible package inputs",
            )
        )
        failures.extend(
            require_field(
                package_inputs,
                "evidenceMode",
                "release_candidate",
                "browser_release_package_inputs_not_release_candidate",
                f"{entry_path}.browserRelease.packageInputsPath",
                "claim-indexed Chromium browser releases require release-candidate package-input evidence",
            )
        )
        package_summary = package_inputs.get("summary")
        if not (
            package_inputs.get("releaseCandidateBlockers") == []
            and package_inputs.get("failures") == []
            and isinstance(package_summary, dict)
            and package_summary.get("packageable") is True
        ):
            failures.append(
                failure(
                    "browser_release_package_inputs_not_clean",
                    f"{entry_path}.browserRelease.packageInputsPath",
                    "claim-indexed Chromium browser releases require package inputs with no blockers or failures",
                )
            )

    provenance = loaded_artifacts.get("provenanceReportPath")
    if provenance is not None:
        failures.extend(
            require_field(
                provenance,
                "status",
                "pass",
                "browser_release_provenance_not_pass",
                f"{entry_path}.browserRelease.provenanceReportPath",
                "claim-indexed Chromium browser releases require passing release-candidate provenance",
            )
        )
        failures.extend(
            require_field(
                provenance,
                "releaseStatus",
                "release_candidate",
                "browser_release_provenance_not_release_candidate",
                f"{entry_path}.browserRelease.provenanceReportPath",
                "claim-indexed Chromium browser releases require release-candidate provenance status",
            )
        )
        provenance_summary = provenance.get("summary")
        if not (
            provenance.get("failures") == []
            and isinstance(provenance_summary, dict)
            and provenance_summary.get("failureCount") == 0
        ):
            failures.append(
                failure(
                    "browser_release_provenance_not_clean",
                    f"{entry_path}.browserRelease.provenanceReportPath",
                    "claim-indexed Chromium browser releases require provenance reports with no failures",
                )
            )
        component_artifacts = provenance.get("componentArtifacts")
        component_refs = component_artifacts if isinstance(component_artifacts, dict) else {}
        if not isinstance(component_artifacts, dict):
            failures.append(
                failure(
                    "browser_release_provenance_component_identity_mismatch",
                    f"{entry_path}.browserRelease.provenanceReportPath",
                    "claim-indexed Chromium browser provenance reports must bind component artifacts",
                )
            )
        for component_key, browser_field in (
            ("packageInputs", "packageInputsPath"),
            ("publicDownloadReceipt", "publicDownloadReceiptPath"),
            ("proofSurface", "proofSurfacePath"),
            ("proofSurfaceCheck", "proofSurfaceCheckPath"),
            ("browserLaunchReceipt", "browserLaunchReceiptPath"),
        ):
            failures.extend(
                validate_artifact_ref_identity(
                    artifact_ref=component_refs.get(component_key),
                    expected_path=browser_release.get(browser_field),
                    expected_kind=BROWSER_RELEASE_PATH_KINDS[browser_field],
                    root=root,
                    entry_path=entry_path,
                    browser_release_field="provenanceReportPath",
                    failure_code="browser_release_provenance_component_identity_mismatch",
                    missing_message=(
                        "claim-indexed Chromium browser provenance reports must bind "
                        f"componentArtifacts.{component_key}"
                    ),
                    mismatch_message=(
                        "provenance componentArtifacts must match browserRelease "
                        f"{browser_field} path, hash, and kind"
                    ),
                )
            )

    public_download = loaded_artifacts.get("publicDownloadReceiptPath")
    if public_download is not None:
        failures.extend(
            require_field(
                public_download,
                "statusCode",
                200,
                "browser_release_public_download_not_ok",
                f"{entry_path}.browserRelease.publicDownloadReceiptPath",
                "claim-indexed Chromium browser releases require an HTTP 200 public download receipt",
            )
        )
        failures.extend(
            require_field(
                public_download,
                "method",
                "GET",
                "browser_release_public_download_not_get",
                f"{entry_path}.browserRelease.publicDownloadReceiptPath",
                "claim-indexed Chromium browser releases require a GET public download receipt",
            )
        )
        for field in ("receiptId", "observedAt"):
            if not isinstance(public_download.get(field), str) or not public_download.get(field):
                failures.append(
                    failure(
                        "browser_release_public_download_incomplete",
                        f"{entry_path}.browserRelease.publicDownloadReceiptPath",
                        f"claim-indexed Chromium browser public download receipts require {field}",
                    )
                )
        content_length = public_download.get("contentLengthBytes")
        if (
            not isinstance(content_length, int)
            or isinstance(content_length, bool)
            or content_length <= 0
        ):
            failures.append(
                failure(
                    "browser_release_public_download_incomplete",
                    f"{entry_path}.browserRelease.publicDownloadReceiptPath",
                    "claim-indexed Chromium browser public download receipts require positive contentLengthBytes",
                )
            )
        else:
            release_archive_path = browser_release.get("releaseArchivePath")
            if isinstance(release_archive_path, str):
                archive_file = safe_browser_release_artifact_path(
                    root,
                    "releaseArchivePath",
                    release_archive_path,
                )
                if archive_file is None:
                    archive_size = None
                else:
                    try:
                        archive_size = archive_file.stat().st_size
                    except OSError:
                        archive_size = None
                if archive_size is not None and content_length != archive_size:
                    failures.append(
                        failure(
                            "browser_release_public_download_length_mismatch",
                            f"{entry_path}.browserRelease.publicDownloadReceiptPath",
                            "public download receipt contentLengthBytes must match browserRelease.releaseArchivePath bytes",
                        )
                    )

    proof_surface_check = loaded_artifacts.get("proofSurfaceCheckPath")
    if proof_surface_check is not None:
        failures.extend(
            require_field(
                proof_surface_check,
                "status",
                "pass",
                "browser_release_proof_surface_check_not_pass",
                f"{entry_path}.browserRelease.proofSurfaceCheckPath",
                "claim-indexed Chromium browser releases require a passing proof-surface check",
            )
        )
        failures.extend(
            require_field(
                proof_surface_check,
                "verifyFilesRootProvided",
                True,
                "browser_release_proof_surface_check_without_file_verification",
                f"{entry_path}.browserRelease.proofSurfaceCheckPath",
                "claim-indexed Chromium browser releases require proof-surface file verification",
            )
        )
        failures.extend(
            require_field(
                proof_surface_check,
                "requirePublicUrls",
                True,
                "browser_release_proof_surface_check_without_public_urls",
                f"{entry_path}.browserRelease.proofSurfaceCheckPath",
                "claim-indexed Chromium browser releases require public proof-gallery URLs",
            )
        )
        if proof_surface_check.get("failures") != []:
            failures.append(
                failure(
                    "browser_release_proof_surface_check_has_failures",
                    f"{entry_path}.browserRelease.proofSurfaceCheckPath",
                    "claim-indexed Chromium browser releases require proof-surface check reports with no failures",
                )
            )
        proof_surface_path = browser_release.get("proofSurfacePath")
        expected_sha = None
        if isinstance(proof_surface_path, str):
            proof_surface_file = safe_browser_release_artifact_path(
                root,
                "proofSurfacePath",
                proof_surface_path,
            )
            if proof_surface_file is not None:
                try:
                    expected_sha = sha256_file(proof_surface_file)
                except OSError:
                    expected_sha = None
        if proof_surface_check.get("surfacePath") != proof_surface_path:
            failures.append(
                failure(
                    "browser_release_proof_surface_check_identity_mismatch",
                    f"{entry_path}.browserRelease.proofSurfaceCheckPath",
                    "proof-surface check surfacePath must match browserRelease.proofSurfacePath",
                )
            )
        if (
            expected_sha is not None
            and proof_surface_check.get("surfaceSha256") != expected_sha
        ):
            failures.append(
                failure(
                    "browser_release_proof_surface_check_identity_mismatch",
                    f"{entry_path}.browserRelease.proofSurfaceCheckPath",
                    "proof-surface check surfaceSha256 must match browserRelease.proofSurfacePath bytes",
                )
            )

    proof_surface = loaded_artifacts.get("proofSurfacePath")
    if proof_surface is not None:
        failures.extend(
            validate_claim_indexed_proof_surface(
                proof_surface,
                entry_path,
                release_bundle=loaded_artifacts.get("releaseArtifactBundlePath"),
                root=root,
            )
        )
        failures.extend(
            receipt_checks.validate_claim_indexed_proof_surface_receipts(
                root,
                proof_surface,
                entry_path,
                release_bundle=loaded_artifacts.get("releaseArtifactBundlePath"),
            )
        )

    browser_launch = loaded_artifacts.get("browserLaunchReceiptPath")
    if browser_launch is not None:
        failures.extend(validate_claim_indexed_browser_launch_receipt(browser_launch, entry_path))
        proof_surface_path = browser_release.get("proofSurfacePath")
        expected_proof_surface_sha = None
        if isinstance(proof_surface_path, str):
            proof_surface_file = safe_browser_release_artifact_path(
                root,
                "proofSurfacePath",
                proof_surface_path,
            )
            if proof_surface_file is not None:
                try:
                    expected_proof_surface_sha = sha256_file(proof_surface_file)
                except OSError:
                    expected_proof_surface_sha = None
        launch_proof_surface = browser_launch.get("proofSurface")
        if not isinstance(launch_proof_surface, dict):
            failures.append(
                failure(
                    "browser_release_launch_proof_surface_identity_mismatch",
                    f"{entry_path}.browserRelease.browserLaunchReceiptPath",
                    "launch receipt proofSurface must bind the published proof surface",
                )
            )
        else:
            for key, expected, message in (
                (
                    "path",
                    proof_surface_path,
                    "launch receipt proofSurface.path must match browserRelease.proofSurfacePath",
                ),
                (
                    "kind",
                    BROWSER_RELEASE_PATH_KINDS["proofSurfacePath"],
                    "launch receipt proofSurface.kind must identify the published proof surface",
                ),
            ):
                if launch_proof_surface.get(key) != expected:
                    failures.append(
                        failure(
                            "browser_release_launch_proof_surface_identity_mismatch",
                            f"{entry_path}.browserRelease.browserLaunchReceiptPath",
                            message,
                        )
                    )
            if (
                expected_proof_surface_sha is not None
                and launch_proof_surface.get("sha256") != expected_proof_surface_sha
            ):
                failures.append(
                    failure(
                        "browser_release_launch_proof_surface_identity_mismatch",
                        f"{entry_path}.browserRelease.browserLaunchReceiptPath",
                        "launch receipt proofSurface.sha256 must match browserRelease.proofSurfacePath bytes",
                    )
                )
        if proof_surface is not None:
            failures.extend(
                validate_claim_indexed_launch_matches_proof_surface(
                    browser_launch,
                    proof_surface,
                    entry_path,
                    root=root,
                )
            )

    finalizer_report = loaded_artifacts.get("finalizerReportPath")
    if finalizer_report is not None:
        failures.extend(
            require_field(
                finalizer_report,
                "status",
                "pass",
                "browser_release_finalizer_not_pass",
                f"{entry_path}.browserRelease.finalizerReportPath",
                "claim-indexed Chromium browser releases require a passing release-candidate finalizer report",
            )
        )
        summary = finalizer_report.get("summary")
        if finalizer_report.get("failures") != []:
            failures.append(
                failure(
                    "browser_release_finalizer_has_failures",
                    f"{entry_path}.browserRelease.finalizerReportPath",
                    "claim-indexed Chromium browser releases require finalizer reports with no failures",
                )
            )
        if not (isinstance(summary, dict) and summary.get("failureCount") == 0):
            failures.append(
                failure(
                    "browser_release_finalizer_failure_count_nonzero",
                    f"{entry_path}.browserRelease.finalizerReportPath",
                    "claim-indexed Chromium browser releases require finalizer summary.failureCount=0",
                )
            )
        runtime_frontier = loaded_artifacts.get("runtimeFrontierBundlePath")
        if not (
            isinstance(summary, dict)
            and isinstance(runtime_frontier, dict)
            and summary.get("claimabilityStatus")
            == runtime_frontier.get("claimabilityStatus")
        ):
            failures.append(
                failure(
                    "browser_release_finalizer_summary_claimability_mismatch",
                    f"{entry_path}.browserRelease.finalizerReportPath",
                    "claim-indexed Chromium browser finalizer summary claimabilityStatus must match the runtime frontier bundle",
                )
            )
        release_bundle = loaded_artifacts.get("releaseArtifactBundlePath")
        if not (
            isinstance(summary, dict)
            and isinstance(release_bundle, dict)
            and summary.get("releaseBundleIdentitySha256")
            == release_bundle_identity_sha256(release_bundle)
        ):
            failures.append(
                failure(
                    "browser_release_finalizer_summary_release_identity_mismatch",
                    f"{entry_path}.browserRelease.finalizerReportPath",
                    "claim-indexed Chromium browser finalizer summary releaseBundleIdentitySha256 must match the release artifact bundle identity",
                )
            )
        outputs = finalizer_report.get("outputs")
        output_refs = outputs if isinstance(outputs, dict) else {}
        if not isinstance(outputs, dict):
            failures.append(
                failure(
                    "browser_release_finalizer_output_identity_mismatch",
                    f"{entry_path}.browserRelease.finalizerReportPath",
                    "claim-indexed Chromium browser finalizer reports must bind output artifacts",
                )
            )
        for output_key, browser_field in (
            ("releaseArtifactBundle", "releaseArtifactBundlePath"),
            ("runtimeFrontierBundle", "runtimeFrontierBundlePath"),
        ):
            failures.extend(
                validate_artifact_ref_identity(
                    artifact_ref=output_refs.get(output_key),
                    expected_path=browser_release.get(browser_field),
                    expected_kind=BROWSER_RELEASE_PATH_KINDS[browser_field],
                    root=root,
                    entry_path=entry_path,
                    browser_release_field="finalizerReportPath",
                    failure_code="browser_release_finalizer_output_identity_mismatch",
                    missing_message=(
                        "claim-indexed Chromium browser finalizer reports must bind "
                        f"outputs.{output_key}"
                    ),
                    mismatch_message=(
                        "finalizer report outputs must match browserRelease "
                        f"{browser_field} path, hash, and kind"
                    ),
                )
            )
        inputs = finalizer_report.get("inputs")
        input_refs = inputs if isinstance(inputs, dict) else {}
        if not isinstance(inputs, dict):
            failures.append(
                failure(
                    "browser_release_finalizer_input_identity_mismatch",
                    f"{entry_path}.browserRelease.finalizerReportPath",
                    "claim-indexed Chromium browser finalizer reports must bind input artifacts",
                )
            )
        failures.extend(
            validate_artifact_ref_identity(
                artifact_ref=input_refs.get("packageInputs"),
                expected_path=browser_release.get("packageInputsPath"),
                expected_kind=BROWSER_RELEASE_PATH_KINDS["packageInputsPath"],
                root=root,
                entry_path=entry_path,
                browser_release_field="finalizerReportPath",
                failure_code="browser_release_finalizer_input_identity_mismatch",
                missing_message=(
                    "claim-indexed Chromium browser finalizer reports must bind "
                    "inputs.packageInputs"
                ),
                mismatch_message=(
                    "finalizer report inputs.packageInputs must match browserRelease "
                    "packageInputsPath path, hash, and kind"
                ),
            )
        )
        failures.extend(
            validate_artifact_ref_identity(
                artifact_ref=input_refs.get("provenanceReport"),
                expected_path=browser_release.get("provenanceReportPath"),
                expected_kind=BROWSER_RELEASE_PATH_KINDS["provenanceReportPath"],
                root=root,
                entry_path=entry_path,
                browser_release_field="finalizerReportPath",
                failure_code="browser_release_finalizer_input_identity_mismatch",
                missing_message=(
                    "claim-indexed Chromium browser finalizer reports must bind "
                    "inputs.provenanceReport"
                ),
                mismatch_message=(
                    "finalizer report inputs.provenanceReport must match "
                    "browserRelease provenanceReportPath path, hash, and kind"
                ),
            )
        )

    finalizer_check = loaded_artifacts.get("finalizerCheckPath")
    if finalizer_check is not None:
        for field, expected, code, message in (
            (
                "status",
                "pass",
                "browser_release_finalizer_check_not_pass",
                "claim-indexed Chromium browser releases require a passing finalizer-check receipt",
            ),
            (
                "finalizerStatus",
                "pass",
                "browser_release_finalizer_check_status_not_pass",
                "claim-indexed Chromium browser releases require finalizerStatus=pass",
            ),
            (
                "verifyFilesRootProvided",
                True,
                "browser_release_finalizer_check_without_file_verification",
                "claim-indexed Chromium browser releases require finalizer-check file verification",
            ),
            (
                "requirePass",
                True,
                "browser_release_finalizer_check_without_require_pass",
                "claim-indexed Chromium browser releases require the finalizer check to enforce pass status",
            ),
        ):
            failures.extend(
                require_field(
                    finalizer_check,
                    field,
                    expected,
                    code,
                    f"{entry_path}.browserRelease.finalizerCheckPath",
                    message,
                )
            )
        if finalizer_check.get("failures") != []:
            failures.append(
                failure(
                    "browser_release_finalizer_check_has_failures",
                    f"{entry_path}.browserRelease.finalizerCheckPath",
                    "claim-indexed Chromium browser releases require finalizer-check receipts with no failures",
                )
            )
        finalizer_report_path = browser_release.get("finalizerReportPath")
        expected_finalizer_sha = None
        if isinstance(finalizer_report_path, str):
            finalizer_report_file = safe_browser_release_artifact_path(
                root,
                "finalizerReportPath",
                finalizer_report_path,
            )
            if finalizer_report_file is not None:
                try:
                    expected_finalizer_sha = sha256_file(finalizer_report_file)
                except OSError:
                    expected_finalizer_sha = None
        if finalizer_check.get("finalizerReportPath") != finalizer_report_path:
            failures.append(
                failure(
                    "browser_release_finalizer_check_identity_mismatch",
                    f"{entry_path}.browserRelease.finalizerCheckPath",
                    "finalizer-check receipt finalizerReportPath must match browserRelease.finalizerReportPath",
                )
            )
        if (
            expected_finalizer_sha is not None
            and finalizer_check.get("finalizerReportSha256") != expected_finalizer_sha
        ):
            failures.append(
                failure(
                    "browser_release_finalizer_check_identity_mismatch",
                    f"{entry_path}.browserRelease.finalizerCheckPath",
                    "finalizer-check receipt finalizerReportSha256 must match browserRelease.finalizerReportPath bytes",
                )
            )
        if (
            finalizer_check.get("status") == "pass"
            and finalizer_check.get("finalizerStatus") == "pass"
        ):
            outputs = finalizer_check.get("outputs")
            output_refs = outputs if isinstance(outputs, dict) else {}
            if not isinstance(outputs, dict):
                failures.append(
                    failure(
                        "browser_release_finalizer_check_output_identity_mismatch",
                        f"{entry_path}.browserRelease.finalizerCheckPath",
                        "claim-indexed Chromium browser finalizer-check receipts must bind checked output artifacts",
                    )
                )
            for output_key, browser_field in (
                ("releaseArtifactBundle", "releaseArtifactBundlePath"),
                ("runtimeFrontierBundle", "runtimeFrontierBundlePath"),
            ):
                failures.extend(
                    validate_artifact_ref_identity(
                        artifact_ref=output_refs.get(output_key),
                        expected_path=browser_release.get(browser_field),
                        expected_kind=BROWSER_RELEASE_PATH_KINDS[browser_field],
                        root=root,
                        entry_path=entry_path,
                        browser_release_field="finalizerCheckPath",
                        failure_code="browser_release_finalizer_check_output_identity_mismatch",
                        missing_message=(
                            "claim-indexed Chromium browser finalizer-check receipts must bind "
                            f"outputs.{output_key}"
                        ),
                        mismatch_message=(
                            "finalizer-check outputs must match browserRelease "
                            f"{browser_field} path, hash, and kind"
                        ),
                    )
                )
            inputs = finalizer_check.get("inputs")
            input_refs = inputs if isinstance(inputs, dict) else {}
            if not isinstance(inputs, dict):
                failures.append(
                    failure(
                        "browser_release_finalizer_check_input_identity_mismatch",
                        f"{entry_path}.browserRelease.finalizerCheckPath",
                        "claim-indexed Chromium browser finalizer-check receipts must bind checked input artifacts",
                    )
                )
            for input_key, browser_field in (
                ("packageInputs", "packageInputsPath"),
                ("provenanceReport", "provenanceReportPath"),
            ):
                failures.extend(
                    validate_artifact_ref_identity(
                        artifact_ref=input_refs.get(input_key),
                        expected_path=browser_release.get(browser_field),
                        expected_kind=BROWSER_RELEASE_PATH_KINDS[browser_field],
                        root=root,
                        entry_path=entry_path,
                        browser_release_field="finalizerCheckPath",
                        failure_code="browser_release_finalizer_check_input_identity_mismatch",
                        missing_message=(
                            "claim-indexed Chromium browser finalizer-check receipts must bind "
                            f"inputs.{input_key}"
                        ),
                        mismatch_message=(
                            "finalizer-check inputs must match browserRelease "
                            f"{browser_field} path, hash, and kind"
                        ),
                    )
                )

    readiness_report = loaded_artifacts.get("readinessReportPath")
    if readiness_report is not None:
        browser_row = readiness_browser_row(readiness_report)
        if not (
            isinstance(browser_row, dict)
            and browser_row.get("claimAllowed") is True
            and browser_row.get("readinessStatus") == "claimable"
        ):
            failures.append(
                failure(
                    "browser_release_readiness_not_claimable",
                    f"{entry_path}.browserRelease.readinessReportPath",
                    "claim-indexed Chromium browser releases require a claimable browser readiness row",
                )
            )

    return failures


def validate_browser_release_bundle_components(
    *,
    root: Path,
    browser_release: dict[str, Any],
    loaded_artifacts: dict[str, dict[str, Any]],
    entry_path: str,
    claim_indexed: bool,
) -> list[dict[str, str]]:
    release_bundle = loaded_artifacts.get("releaseArtifactBundlePath")
    if release_bundle is None:
        return []

    failures: list[dict[str, str]] = []
    for field, (component_key, expected_kind) in BROWSER_RELEASE_BUNDLE_COMPONENTS.items():
        rel_path = browser_release.get(field)
        if not isinstance(rel_path, str) or field not in loaded_artifacts:
            continue

        component_path = f"{entry_path}.browserRelease.{field}"
        component = release_bundle.get(component_key)
        if not isinstance(component, dict):
            if claim_indexed or component_key in release_bundle:
                failures.append(
                    failure(
                        "browser_release_bundle_component_missing",
                        component_path,
                        (
                            "release artifact bundle must include "
                            f"{component_key} for {field}"
                        ),
                    )
                )
            continue

        artifact_path = safe_browser_release_artifact_path(root, field, rel_path)
        if artifact_path is None:
            continue
        try:
            actual_sha = sha256_file(artifact_path)
        except OSError as exc:
            failures.append(
                failure(
                    "browser_release_artifact_unavailable",
                    component_path,
                    f"{rel_path}: hash_failed: {exc}",
                )
            )
            continue

        for key, expected in (
            ("path", rel_path),
            ("sha256", actual_sha),
            ("kind", expected_kind),
        ):
            if component.get(key) == expected:
                continue
            failures.append(
                failure(
                    "browser_release_bundle_component_mismatch",
                    component_path,
                    (
                        f"releaseArtifactBundlePath.{component_key}.{key} must "
                        f"bind {field}: expected {expected!r}, "
                        f"got {component.get(key)!r}"
                    ),
                )
            )

    return failures


def validate_browser_release_readiness_paths(
    *,
    browser_release: dict[str, Any],
    entry: dict[str, Any],
    entry_path: str,
    readiness_report: dict[str, Any] | None,
) -> list[dict[str, str]]:
    if readiness_report is None:
        return []
    browser_row = readiness_browser_row(readiness_report)
    if browser_row is None:
        return [
            failure(
                "browser_release_readiness_row_missing",
                f"{entry_path}.browserRelease.readinessReportPath",
                "browser release readiness report must include the Chromium browser frontier row",
            )
        ]

    failures: list[dict[str, str]] = []
    for field, readiness_path in BROWSER_RELEASE_READINESS_PATHS.items():
        expected = browser_release.get(field)
        actual = nested_value(browser_row, readiness_path)
        if actual != expected:
            failures.append(
                failure(
                    "browser_release_readiness_path_mismatch",
                    f"{entry_path}.browserRelease.{field}",
                    (
                        f"browser release readiness row must bind {field} "
                        f"to {expected!r}, got {actual!r}"
                    ),
                )
            )

    claim_entries = browser_row.get("claimIndexEntries")
    if not isinstance(claim_entries, list):
        claim_entries = []
    entry_id = entry.get("id")
    readiness_entry = next(
        (
            item
            for item in claim_entries
            if isinstance(item, dict) and item.get("id") == entry_id
        ),
        None,
    )
    if readiness_entry is None:
        failures.append(
            failure(
                "browser_release_readiness_claim_entry_missing",
                f"{entry_path}.browserRelease.readinessReportPath",
                "browser release readiness report must include the matching claim-index entry",
            )
        )
    elif readiness_entry.get("browserRelease") != browser_release:
        failures.append(
            failure(
                "browser_release_readiness_claim_entry_mismatch",
                f"{entry_path}.browserRelease.readinessReportPath",
                "browser release readiness report claim-index entry must bind the same browserRelease paths",
            )
        )

    return failures


def validate_browser_release_readiness_hashes(
    *,
    root: Path,
    browser_release: dict[str, Any],
    entry_path: str,
    readiness_report: dict[str, Any] | None,
) -> list[dict[str, str]]:
    if readiness_report is None:
        return []
    browser_row = readiness_browser_row(readiness_report)
    if browser_row is None:
        return []

    failures: list[dict[str, str]] = []
    for field, readiness_path in BROWSER_RELEASE_READINESS_SHA_PATHS.items():
        rel_path = browser_release.get(field)
        if not isinstance(rel_path, str):
            continue
        artifact_path = safe_browser_release_artifact_path(root, field, rel_path)
        if artifact_path is None:
            continue
        if not artifact_path.exists():
            continue
        expected = nested_value(browser_row, readiness_path)
        try:
            actual = sha256_file(artifact_path)
        except OSError as exc:
            failures.append(
                failure(
                    "browser_release_artifact_unavailable",
                    f"{entry_path}.browserRelease.{field}",
                    f"{rel_path}: hash_failed: {exc}",
                )
            )
            continue
        if actual != expected:
            failures.append(
                failure(
                    "browser_release_readiness_hash_mismatch",
                    f"{entry_path}.browserRelease.{field}",
                    (
                        f"browser release readiness row must hash-bind {field} "
                        f"as {actual}, got {expected!r}"
                    ),
                )
            )

    return failures


def validate_browser_release_artifacts(
    root: Path,
    entry_path: str,
    entry: dict[str, Any],
) -> list[dict[str, str]]:
    failures: list[dict[str, str]] = []
    if entry.get("surface") != BROWSER_CHROMIUM_SURFACE:
        if "browserRelease" in entry:
            failures.append(
                failure(
                    "browser_release_on_non_browser_surface",
                    f"{entry_path}.browserRelease",
                    "browserRelease evidence is only valid for browser-chromium entries",
                )
            )
        return failures

    browser_release = entry.get("browserRelease")
    if not isinstance(browser_release, dict):
        return [
            failure(
                "browser_release_evidence_missing",
                f"{entry_path}.browserRelease",
                "browser-chromium entries require browserRelease evidence paths",
            )
        ]

    claim_indexed = entry.get("claimState") == "claim-indexed"
    loaded_artifacts: dict[str, dict[str, Any]] = {}
    for field, expected_kind in BROWSER_RELEASE_PATH_KINDS.items():
        path = f"{entry_path}.browserRelease.{field}"
        rel_path = browser_release.get(field)
        reason = unsafe_path_reason(rel_path)
        if reason:
            failures.append(failure("unsafe_browser_release_path", path, reason))
            continue
        if not isinstance(rel_path, str):
            continue
        artifact, load_status = load_optional_artifact(root, rel_path)
        if load_status == "missing_optional":
            if claim_indexed:
                failures.append(
                    failure(
                        "browser_release_artifact_unavailable",
                        path,
                        f"{rel_path}: {load_status}",
                    )
                )
            continue
        if load_status:
            failures.append(
                failure(
                    "browser_release_artifact_unavailable",
                    path,
                    f"{rel_path}: {load_status}",
                )
            )
            continue
        if artifact is None:
            continue
        loaded_artifacts[field] = artifact
        if artifact.get("artifactKind") != expected_kind:
            failures.append(
                failure(
                    "browser_release_artifact_kind_mismatch",
                    path,
                    f"{rel_path}: artifactKind must be {expected_kind}",
                )
            )

    readiness_report = loaded_artifacts.get("readinessReportPath")
    failures.extend(
        validate_browser_release_archive_identity(
            root=root,
            browser_release=browser_release,
            loaded_artifacts=loaded_artifacts,
            entry_path=entry_path,
            claim_indexed=claim_indexed,
        )
    )
    failures.extend(
        validate_browser_release_bundle_components(
            root=root,
            browser_release=browser_release,
            loaded_artifacts=loaded_artifacts,
            entry_path=entry_path,
            claim_indexed=claim_indexed,
        )
    )
    failures.extend(
        validate_browser_release_readiness_paths(
            browser_release=browser_release,
            entry=entry,
            entry_path=entry_path,
            readiness_report=readiness_report,
        )
    )
    failures.extend(
        validate_browser_release_readiness_hashes(
            root=root,
            browser_release=browser_release,
            entry_path=entry_path,
            readiness_report=readiness_report,
        )
    )

    if claim_indexed:
        failures.extend(
            validate_claim_indexed_browser_release(
                root,
                browser_release,
                loaded_artifacts,
                entry_path,
            )
        )

    return failures
